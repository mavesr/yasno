import Foundation
import SwitchCore
import CYasnoLinux

/// Presses keys on the virtual keyboard for an edit.
public final class SinkTypist: Typist {
    let sink: KeySink
    weak var hub: InputHub?
    let keyDelay: useconds_t
    let settleDelay: useconds_t
    let switchDelay: useconds_t

    public init(sink: KeySink, hub: InputHub?, keyDelay: useconds_t = 1500, settleDelay: useconds_t = 15_000, switchDelay: useconds_t = 30_000) {
        self.sink = sink; self.hub = hub; self.keyDelay = keyDelay; self.settleDelay = settleDelay; self.switchDelay = switchDelay
    }

    public func settle() { usleep(settleDelay) }
    public func pause() { usleep(switchDelay) }

    /// Shift keys the user holds down right now would change what the edit types.
    private func withoutHeldShift(_ body: () -> Void) {
        let held = (hub?.heldKeys ?? []).intersection([KeyCodes.leftShift, KeyCodes.rightShift])
        for key in held { sink.key(key, 0) }
        if !held.isEmpty { sink.sync(); usleep(keyDelay) }
        body()
        for key in held { sink.key(key, 1) }
        if !held.isEmpty { sink.sync() }
    }

    private func tap(_ code: UInt16, shift: Bool) {
        if shift { sink.key(KeyCodes.leftShift, 1); sink.sync() }
        sink.key(code, 1); sink.sync()
        usleep(keyDelay / 2)
        sink.key(code, 0); sink.sync()
        if shift { sink.key(KeyCodes.leftShift, 0); sink.sync() }
        usleep(keyDelay)
    }

    public func erase(_ count: Int) {
        guard count > 0 else { return }
        withoutHeldShift { for _ in 0..<count { tap(KeyCodes.backspace, shift: false) } }
    }

    public func press(_ strokes: [KeyboardLayout.KeyStroke]) {
        withoutHeldShift {
            for stroke in strokes {
                guard let code = KeyCodes.macToEvdev[stroke.key] else { continue }
                tap(code, shift: stroke.shift)
            }
        }
    }
}

/// The real virtual keyboard.
public final class UinputSink: KeySink {
    public let fd: Int32
    public init?(name: String = "Yasno virtual keyboard") {
        fd = yl_uinput_create(name)
        guard fd >= 0 else { return nil }
    }
    public func key(_ code: UInt16, _ value: Int32) { _ = yl_write_event(fd, 1, code, value) }
    public func sync() { _ = yl_write_event(fd, 0, 0, 0) }
    public func raw(_ type: UInt16, _ code: UInt16, _ value: Int32) { _ = yl_write_event(fd, type, code, value) }
    deinit { yl_uinput_destroy(fd) }
}
