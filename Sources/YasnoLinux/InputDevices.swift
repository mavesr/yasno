import Foundation
import CYasnoLinux

/// Reads every keyboard and pointer under /dev/input. Keyboards are grabbed (only Yasno sees
/// them) and their keys go through the hub to the virtual keyboard; pointers are only watched,
/// for clicks and scrolling. Runs its own thread and never waits for the engine.
public final class InputDevices {
    struct Device { let fd: Int32; let path: String; let kind: Int32; var grabbed: Bool; let name: String }

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
        for entry in entries where entry.hasPrefix("event") {
            let path = "/dev/input/" + entry
            guard devices[path] == nil else { continue }
            let fd = yl_open_input(path)
            guard fd >= 0 else { continue }
            let kind = yl_device_kind(fd)
            let isSelf = kind & Int32(YL_KIND_SELF) != 0
            let keyboard = kind & Int32(YL_KIND_KEYBOARD) != 0
            let pointer = kind & Int32(YL_KIND_POINTER) != 0
            guard !isSelf, keyboard || pointer else { _ = yl_close(fd); continue }
            var name = [CChar](repeating: 0, count: 256)
            _ = yl_device_name(fd, &name, 256)
            devices[path] = Device(fd: fd, path: path, kind: kind, grabbed: false, name: String(cString: name))
        }
        keyboardCount = devices.values.filter { $0.kind & Int32(YL_KIND_KEYBOARD) != 0 }.count
    }

    /// A keyboard is taken over only when none of its keys is down: the desktop would otherwise
    /// never see the release and repeat that key forever.
    private func updateGrabs() {
        lock.lock(); let want = wantGrab && !stopped; lock.unlock()
        for (path, var device) in devices where device.kind & Int32(YL_KIND_KEYBOARD) != 0 {
            if want && !device.grabbed {
                guard yl_keys_down(device.fd) == 0 else { continue }
                guard yl_grab(device.fd, 1) == 0 else { trace("grab failed: \(device.name)"); continue }
                trace("grabbed: \(device.name)")
                device.grabbed = true
            } else if !want && device.grabbed {
                // Keys the desktop has down from the virtual keyboard are released there first.
                hub.releaseAll()
                for key in hub.heldKeys { sink.key(key, 0) }
                sink.sync()
                _ = yl_grab(device.fd, 0)
                trace("released: \(device.name)")
                device.grabbed = false
            }
            devices[path] = device
        }
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
                    _ = yl_close(device.fd); devices.removeValue(forKey: device.path); continue
                }
                let keyboard = device.kind & Int32(YL_KIND_KEYBOARD) != 0
                var pointerMoved = false
                for event in events.prefix(count) {
                    if keyboard && device.grabbed && event.type == 1 && !KeyCodes.isPointerButton(event.code) {
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
