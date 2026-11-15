import Foundation
import XCTest
import SwitchCore
@testable import YasnoLinux

/// A desktop as Yasno sees it: it receives keys from the virtual keyboard and types them into
/// one text field with the layout selected at that moment, the way a compositor does.
final class FakeDesktop: KeySink, LayoutBackend {
    let name = "Fake"
    let lock = NSLock()
    let specs: [LayoutSpec]
    let tables: [KeyboardLayout]
    private(set) var current: Int
    private(set) var text = ""
    private var held: Set<UInt16> = []
    var capsLock = false
    var app = "org.example.Editor"
    var selections = 0
    var failSelect = false

    init(layouts: [(String, String)], current: Int = 0) {
        specs = layouts.map { LayoutSpec(layout: $0.0, variant: $0.1, name: $0.0) }
        tables = specs.map { XkbTables.layout($0)! }
        self.current = current
    }

    var field: String { lock.lock(); defer { lock.unlock() }; return text }
    func clear() { lock.lock(); text = ""; lock.unlock() }
    var currentLayout: KeyboardLayout { lock.lock(); defer { lock.unlock() }; return tables[current] }

    func key(_ code: UInt16, _ value: Int32) {
        lock.lock(); defer { lock.unlock() }
        if value == 0 { held.remove(code); return }
        if value == 2 { return }
        held.insert(code)
        if code == KeyCodes.capsLock { capsLock.toggle(); return }
        if code == KeyCodes.backspace { if !text.isEmpty { text.removeLast() }; return }
        if code == KeyCodes.enter { text += "\n"; return }
        if KeyCodes.modifiers.contains(code) { return }
        let ctrl = held.contains(KeyCodes.leftCtrl) || held.contains(KeyCodes.rightCtrl)
        guard !ctrl, let mac = KeyCodes.evdevToMac[code] else { return }
        let shift = held.contains(KeyCodes.leftShift) || held.contains(KeyCodes.rightShift)
        if let character = tables[current].character(key: mac, shift: shift, capsLock: capsLock) { text += character }
    }
    func sync() {}

    func layouts() -> [LayoutSpec] { specs }
    func currentIndex() -> Int? { lock.lock(); defer { lock.unlock() }; return current }
    func select(index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failSelect, index >= 0, index < specs.count else { return false }
        current = index; selections += 1
        return true
    }
    func userSelects(_ index: Int) { lock.lock(); current = index; lock.unlock() }
    func focusedApplication() -> (id: String, name: String)? { (app, app) }
}

/// Yasno wired to the fake desktop, with a user who types physical keys.
final class TypingRig {
    let desktop: FakeDesktop
    let hub: InputHub
    let engine: Engine
    let settings: Settings
    var clockOffset: TimeInterval = 0

    static let sharedDetectorLock = NSLock()

    init(layouts: [(String, String)] = [("us", ""), ("ru", ""), ("ua", "")], current: Int = 0, spelling: Bool = true) {
        desktop = FakeDesktop(layouts: layouts, current: current)
        hub = InputHub(sink: desktop)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yasno-test-\(UUID().uuidString).json")
        settings = Settings(url: url)
        settings.update { $0.correctSpelling = spelling }
        let typist = SinkTypist(sink: desktop, hub: hub, keyDelay: 200, settleDelay: 2000, switchDelay: 2000)
        engine = Engine(hub: hub, typist: typist, settings: settings, backend: desktop)
        let loaded = expectationSemaphore()
        engine.loadDetector { loaded.signal() }
        loaded.wait()
        engine.queue.sync {
            engine.reloadLayouts()
            engine.refreshApp()
            engine.apply(allowed: true)
        }
        desktop.capsLock = false
    }

    private func expectationSemaphore() -> DispatchSemaphore { DispatchSemaphore(value: 0) }

    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func event(_ code: UInt16, _ value: Int32) {
        hub.handle(InputEvent(source: .keyboard, type: InputEvent.keyType, code: code, value: value, time: now()))
    }

    /// Press one physical key (with Shift if asked), holding it for `hold` seconds.
    func press(_ code: UInt16, shift: Bool = false, hold: TimeInterval = 0.01, gap: TimeInterval = 0.03) {
        if shift { event(KeyCodes.leftShift, 1); sleep(0.005) }
        event(code, 1); sleep(hold); event(code, 0)
        if shift { sleep(0.003); event(KeyCodes.leftShift, 0) }
        sleep(gap)
    }

    func tapShift() { event(KeyCodes.leftShift, 1); sleep(0.08); event(KeyCodes.leftShift, 0); sleep(0.05) }

    func click() {
        hub.handle(InputEvent(source: .pointer, type: InputEvent.keyType, code: 0x110, value: 1, time: now()))
        hub.handle(InputEvent(source: .pointer, type: InputEvent.keyType, code: 0x110, value: 0, time: now()))
    }

    func sleep(_ seconds: TimeInterval) { if seconds > 0 { usleep(useconds_t(seconds * 1_000_000)) } }

    /// The user means `text` in `layout` and presses its keys, whatever layout is selected.
    func type(_ text: String, meaning layout: KeyboardLayout, gap: ClosedRange<Double> = 0.03...0.06,
              random: inout SystemRandomNumberGenerator) {
        for character in text {
            if character == " " { press(KeyCodes.space, gap: Double.random(in: gap, using: &random)); continue }
            guard let stroke = layout.stroke(for: character), let code = KeyCodes.macToEvdev[stroke.key] else {
                XCTFail("no key for \(character) in \(layout.id)"); continue
            }
            press(code, shift: stroke.shift, gap: Double.random(in: gap, using: &random))
        }
    }

    /// Waits until nothing is held, analysed or typed.
    func settle(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        var quiet = 0
        while Date() < deadline {
            sleep(0.05)
            var busy = hub.hasPendingInput
            engine.queue.sync {}
            engine.worker.sync {}
            engine.queue.sync {}
            busy = busy || hub.hasPendingInput
            quiet = busy ? 0 : quiet + 1
            if quiet >= 4 { return }
        }
    }

    func layout(_ id: String) -> KeyboardLayout { engine.layouts.first { $0.id == id }! }
}
