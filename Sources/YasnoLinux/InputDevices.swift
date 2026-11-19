import Foundation
import CYasnoLinux

/// Reads every keyboard and pointer under /dev/input. Keyboards are grabbed (only Yasno sees
/// them) and their keys go through the hub to the virtual keyboard; pointers are only watched,
/// for clicks and scrolling. Runs its own thread and never waits for the engine.
public final class InputDevices {
    struct Device {
        let fd: Int32; let path: String; let kind: Int32; var grabbed: Bool; let name: String
        /// Made by a program through uinput (a key remapper such as xremap or keyd), not hardware.
        let virtual: Bool
        /// Another program holds the device (a key remapper): retried now and then, logged once.
        var busy = false
        var lastTry: TimeInterval = 0
        var downs: [TimeInterval] = []
    }

    /// What the window says about the keyboards.
    public struct Report: Equatable {
        public var grabbed: [String] = []
        /// Keyboards another program holds.
        public var busy: [String] = []
        /// Keyboards this user may not read (a remapper's output without Ясно's udev rule).
        public var unreadable: [String] = []
        /// Another program holds Ясно's own virtual keyboard: reading its output would loop.
        public var selfCaptured = false
        /// A remapper's output came back so fast that it must have been a loop.
        public var looped = false
        /// Keyboards made by programs (key remappers such as xremap).
        public var remappers: [String] = []
    }

    let hub: InputHub
    let sink: UinputSink
    private let lock = NSLock()
    private var devices: [String: Device] = [:]
    private var wantGrab = false
    private var thread: Thread?
    private var wake: [Int32] = [-1, -1]
    private var stopped = false
    private var lastScan: TimeInterval = 0
    public private(set) var keyboardCount = 0
    private var reportValue = Report()
    private var selfPath = ""
    private var loopedPaths: Set<String> = []
    public var report: Report { lock.lock(); defer { lock.unlock() }; return reportValue }

    public init(hub: InputHub, sink: UinputSink) {
        self.hub = hub; self.sink = sink
        var fds: [Int32] = [0, 0]
        if yl_pipe(&fds) == 0 { wake = fds }
    }

    /// Whether this user can read the keyboards and write the virtual keyboard.
    public static var accessible: Bool {
        guard yl_access_ok("/dev/uinput", 1) != 0 else { return false }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/input")) ?? []
        for entry in entries where entry.hasPrefix("event") {
            let fd = yl_open_input("/dev/input/" + entry)
            if fd >= 0 {
                let kind = yl_device_kind(fd)
                _ = yl_close(fd)
                if kind & Int32(YL_KIND_KEYBOARD) != 0 && kind & Int32(YL_KIND_SELF) == 0 { return true }
            }
        }
        return false
    }

    public func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "yasno.input"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    /// Grab while correcting is on; let go while paused, so the keyboard then goes straight to the desktop.
    public func setGrab(_ on: Bool) {
        lock.lock(); wantGrab = on; lock.unlock()
        poke()
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
        poke()
    }

    private func poke() { if wake[1] >= 0 { var byte: UInt8 = 1; _ = write(wake[1], &byte, 1) } }

    private func scan() {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/input")) ?? []
        var unreadable: [String] = [], remappers: [String] = []
        for entry in entries where entry.hasPrefix("event") {
            let path = "/dev/input/" + entry
            guard devices[path] == nil else { continue }
            let fd = yl_open_input(path)
            guard fd >= 0 else {
                if fd == -yl_errno_access(), Self.udevKeyboard(entry) {
                    unreadable.append(Self.sysName(entry))
                    if Self.isVirtual(entry) { remappers.append(Self.sysName(entry)) }
                }
                continue
            }
            let kind = yl_device_kind(fd)
            let isSelf = kind & Int32(YL_KIND_SELF) != 0
            let keyboard = kind & Int32(YL_KIND_KEYBOARD) != 0
            let pointer = kind & Int32(YL_KIND_POINTER) != 0
            guard !isSelf, keyboard || pointer else { _ = yl_close(fd); continue }
            var name = [CChar](repeating: 0, count: 256)
            _ = yl_device_name(fd, &name, 256)
            devices[path] = Device(fd: fd, path: path, kind: kind, grabbed: false, name: String(cString: name),
                                   virtual: Self.isVirtual(entry))
        }
        keyboardCount = devices.values.filter { $0.kind & Int32(YL_KIND_KEYBOARD) != 0 }.count
        if selfPath.isEmpty {
            var buffer = [CChar](repeating: 0, count: 128)
            if yl_uinput_event_path(sink.fd, &buffer, 128) == 0 { selfPath = String(cString: buffer) }
        }
        let captured = devices.values.contains { $0.virtual && $0.kind & Int32(YL_KIND_KEYBOARD) != 0 } && selfCaptured()
        let keyboards = devices.values.filter { $0.kind & Int32(YL_KIND_KEYBOARD) != 0 }
        lock.lock()
        reportValue.unreadable = unreadable.sorted()
        reportValue.selfCaptured = captured
        reportValue.grabbed = keyboards.filter(\.grabbed).map(\.name).sorted()
        reportValue.busy = keyboards.filter(\.busy).map(\.name).sorted()
        reportValue.looped = !loopedPaths.isEmpty
        reportValue.remappers = (remappers + keyboards.filter(\.virtual).map(\.name)).sorted()
        lock.unlock()
    }

    /// Whether another program holds Ясно's own virtual keyboard (xremap without --ignore does).
    /// Then Ясно must not read that program's output: each key would go round forever.
    private func selfCaptured() -> Bool {
        guard !selfPath.isEmpty else { return false }
        let fd = yl_open_input(selfPath)
        guard fd >= 0 else { return false }
        defer { _ = yl_close(fd) }
        let result = yl_grab(fd, 1)
        if result == 0 { _ = yl_grab(fd, 0); return false }
        return result == -yl_errno_busy()
    }

    static func sysName(_ entry: String) -> String {
        let name = (try? String(contentsOfFile: "/sys/class/input/\(entry)/device/name", encoding: .utf8)) ?? entry
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isVirtual(_ entry: String) -> Bool {
        let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/sys/class/input/" + entry)) ?? ""
        return link.contains("/virtual/")
    }

    /// udev marks keyboards in its database, which everyone may read.
    static func udevKeyboard(_ entry: String) -> Bool {
        let number = entry.dropFirst("event".count)
        let data = (try? String(contentsOfFile: "/run/udev/data/c13:\(64 + (Int(number) ?? -1000))", encoding: .utf8)) ?? ""
        return data.contains("E:ID_INPUT_KEYBOARD=1")
    }

    /// A keyboard is taken over only when none of its keys is down: the desktop would otherwise
    /// never see the release and repeat that key forever.
    private func updateGrabs() {
        lock.lock(); let want = wantGrab && !stopped; let captured = reportValue.selfCaptured; lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        for (path, var device) in devices where device.kind & Int32(YL_KIND_KEYBOARD) != 0 {
            // A remapper's output is read only while that remapper leaves Ясно's keyboard alone.
            let allowed = want && !(device.virtual && (captured || loopedPaths.contains(path)))
            if allowed && !device.grabbed {
                if device.busy && now - device.lastTry < 3 { continue }
                guard yl_keys_down(device.fd) == 0 else { continue }
                device.lastTry = now
                let result = yl_grab(device.fd, 1)
                if result != 0 {
                    if !device.busy { trace("grab failed (\(result)): \(device.name)") }
                    device.busy = result == -yl_errno_busy()
                    devices[path] = device
                    continue
                }
                trace("grabbed: \(device.name)")
                device.grabbed = true; device.busy = false
            } else if !allowed && device.grabbed {
                release(&device)
            }
            devices[path] = device
        }
    }

    private func release(_ device: inout Device) {
        // Keys the desktop has down from the virtual keyboard are released there first.
        hub.releaseAll()
        hub.releaseDelivered()
        _ = yl_grab(device.fd, 0)
        trace("released: \(device.name)")
        device.grabbed = false
    }

    /// More key presses in a second than anyone types: the keys are going round between Ясно
    /// and a remapper. That remapper's output is let go for good.
    private func checkLoop(_ path: String) {
        guard var device = devices[path], device.virtual else { return }
        let now = ProcessInfo.processInfo.systemUptime
        device.downs = device.downs.filter { now - $0 < 1 } + [now]
        if device.downs.count > 300 {
            trace("loop through \(device.name): released")
            loopedPaths.insert(path)
            device.downs = []
            if device.grabbed { release(&device) }
            lock.lock(); reportValue.looped = true; lock.unlock()
        }
        devices[path] = device
    }

    private func run() {
        var events = [yl_event](repeating: yl_event(), count: 64)
        while true {
            lock.lock(); let halt = stopped; lock.unlock()
            if halt { break }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastScan > 2 { scan(); lastScan = now }
            updateGrabs()
            let list = Array(devices.values)
            var fds = list.map(\.fd) + [sink.fd]
            if wake[0] >= 0 { fds.append(wake[0]) }
            var ready = [Int32](repeating: 0, count: fds.count)
            _ = yl_poll(fds, Int32(fds.count), 100, &ready)
            hub.tick()
            for (index, device) in list.enumerated() where ready[index] != 0 {
                let count = Int(yl_read_events(device.fd, &events, 64))
                if count < 0 {
                    // Unplugged: its keys that are down on the virtual keyboard are let go too.
                    if device.grabbed { hub.releaseAll(); hub.releaseDelivered() }
                    _ = yl_close(device.fd); devices.removeValue(forKey: device.path); continue
                }
                let keyboard = device.kind & Int32(YL_KIND_KEYBOARD) != 0
                var pointerMoved = false
                for event in events.prefix(count) {
                    if keyboard && device.grabbed && event.type == 1 && !KeyCodes.isPointerButton(event.code) {
                        if device.virtual && event.value == 1 { checkLoop(device.path); if devices[device.path]?.grabbed != true { continue } }
                        hub.handle(InputEvent(source: .keyboard, type: 1, code: event.code, value: event.value, time: event.time))
                        continue
                    }
                    if keyboard && device.grabbed && (event.type == 1 || event.type == 2) {
                        // The pointer part of a grabbed combo device goes straight to the desktop.
                        sink.raw(event.type, event.code, event.value); pointerMoved = true
                    }
                    if event.type == 0, pointerMoved { sink.sync(); pointerMoved = false }
                    if event.type == 1 || event.type == 2 {
                        hub.handle(InputEvent(source: .pointer, type: event.type, code: event.code, value: event.value, time: event.time))
                    }
                }
                if pointerMoved { sink.sync() }
            }
            // LEDs the desktop sets on the virtual keyboard (Caps Lock) go to the real ones.
            if ready[list.count] != 0 {
                let count = Int(yl_read_events(sink.fd, &events, 64))
                for event in events.prefix(max(count, 0)) where event.type == 0x11 {
                    if event.code == 1 { hub.lock.lock(); hub.capsLock = event.value != 0; hub.lock.unlock() }
                    for device in devices.values where device.grabbed {
                        _ = yl_write_event(device.fd, 0x11, event.code, event.value)
                        _ = yl_write_event(device.fd, 0, 0, 0)
                    }
                }
            }
            if wake[0] >= 0, ready.last != 0 { var buffer = [UInt8](repeating: 0, count: 64); _ = read(wake[0], &buffer, 64) }
        }
        hub.releaseAll()
        for device in devices.values { if device.grabbed { _ = yl_grab(device.fd, 0) }; _ = yl_close(device.fd) }
        devices = [:]
    }
}
