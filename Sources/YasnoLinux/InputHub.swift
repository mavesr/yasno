import Foundation
import SwitchCore
import CYasnoLinux

/// One evdev event, with the device kind it came from.
public struct InputEvent: Equatable {
    public enum Source: Equatable { case keyboard, pointer }
    public let source: Source
    public let type: UInt16   // EV_KEY 1, EV_REL 2
    public let code: UInt16
    public let value: Int32   // keys: 0 up, 1 down, 2 repeat
    public let time: TimeInterval
    public init(source: Source, type: UInt16, code: UInt16, value: Int32, time: TimeInterval) {
        self.source = source; self.type = type; self.code = code; self.value = value; self.time = time
    }
    public static let keyType: UInt16 = 1, relType: UInt16 = 2
    var isKey: Bool { type == Self.keyType }
    var isKeyDown: Bool { isKey && value != 0 }
}

/// Where keys go: the virtual keyboard (uinput) the desktop reads instead of the real ones.
public protocol KeySink: AnyObject {
    func key(_ code: UInt16, _ value: Int32)
    func sync()
}

/// Holds the physical keyboards and forwards their keys, holding them while a correction is
/// typed — the counterpart of the macOS event tap with its gate. Everything here runs under
/// `lock` and never waits for the engine: if the engine stalls, held keys are released after
/// `captureTimeout` by the input thread itself.
public final class InputHub {
    public let lock = NSLock()
    let sink: KeySink
    let clock: () -> TimeInterval
    let captureTimeout: TimeInterval
    /// Called (outside the lock) for every event the engine must observe, with its sequence.
    var observe: ((InputEvent, UInt64, _ boundary: UInt64?) -> Void)?
    /// Called (outside the lock) when held keys had to be released by the watchdog.
    var onStall: (() -> Void)?

    // Under lock.
    private(set) var generation: UInt64 = 0
    private var gated = false
    private var committing = false
    private var gateOwner: UInt64?
    private var boundaryReserved = false
    private var boundaryCancelled = false
    private var boundaryID: UInt64 = 0
    private var pending: [InputEvent] = []
    private var lastProgress: TimeInterval = 0
    private var forwardedSequence: UInt64 = 0
    private var observedSequence: UInt64 = 0
    private var delivered: Set<UInt16> = []
    private var boundaryShift = ShiftTapGesture()
    private var scrolledSinceShift = false
    private var shiftChords: [TimeInterval] = []
    private var faulted = false
    private var stalledReported = false
    var accepting = false { didSet { if !accepting { boundaryShift.reset() } } }
    /// Caps Lock as the desktop shows it (the LED it sets on the virtual keyboard).
    public var capsLock = false

    public init(sink: KeySink, captureTimeout: TimeInterval = 1.0,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink; self.captureTimeout = captureTimeout; self.clock = clock
    }

    public var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    var hasPendingInput: Bool { lock.lock(); defer { lock.unlock() }; return gated || boundaryReserved || !pending.isEmpty }
    var isFaulted: Bool { get { lock.lock(); defer { lock.unlock() }; return faulted } set { lock.lock(); faulted = newValue; lock.unlock() } }

    /// Keys pressed now (forwarded down, not yet released): the desktop sees them held.
    var heldKeys: Set<UInt16> { lock.lock(); defer { lock.unlock() }; return delivered }

    func bump() -> UInt64 { lock.lock(); generation &+= 1; let value = generation; lock.unlock(); return value }

    func markObserved(_ sequence: UInt64) {
        lock.lock(); if sequence > observedSequence { observedSequence = sequence }; lock.unlock()
    }

    /// Whether this Shift release ended a Shift+scroll (a chord, not a tap). Each mark is used once.
    func takeShiftChord(_ time: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let index = shiftChords.firstIndex(of: time) { shiftChords.remove(at: index); return true }
        return false
    }

    private static func clean(_ held: Set<UInt16>) -> Bool {
        held.isDisjoint(with: [KeyCodes.leftCtrl, KeyCodes.rightCtrl, KeyCodes.leftAlt, KeyCodes.rightAlt,
                               KeyCodes.leftMeta, KeyCodes.rightMeta])
    }

    // MARK: Input thread

    /// A physical event. Forwards it or holds it, and hands it to the engine.
    public func handle(_ event: InputEvent) {
        var released: [InputEvent] = []
        var notifications: [(InputEvent, UInt64, UInt64?)] = []
        var stalled = false
        lock.lock()
        if releaseIfStalled(into: &released) { stalled = !stalledReported; stalledReported = true }
        if event.source == .pointer {
            if event.type == InputEvent.relType {
                // REL_WHEEL 8, REL_HWHEEL 6: Shift+scroll is a chord, not a Shift tap.
                if event.code == 8 || event.code == 6 || event.code == 11 || event.code == 12 {
                    boundaryShift.cancel(); scrolledSinceShift = true
                }
                lock.unlock(); flush(released, stalled: stalled); return
            }
            guard event.isKey, KeyCodes.isPointerButton(event.code) else { lock.unlock(); flush(released, stalled: stalled); return }
            boundaryShift.cancel()
            if event.value == 1 {
                // A click moves the caret: an edit not yet typed must not land at the new place.
                if (gated || boundaryReserved), !committing { generation &+= 1; if boundaryReserved { boundaryCancelled = true } }
            }
            lock.unlock()
            flush(released, stalled: stalled)
            observe?(event, 0, nil)
            return
        }
        guard event.isKey else { lock.unlock(); flush(released, stalled: stalled); return }
        if event.code == KeyCodes.leftShift || event.code == KeyCodes.rightShift {
            if event.value == 1 { scrolledSinceShift = false }
            else if event.value == 0, scrolledSinceShift { shiftChords = shiftChords.suffix(255) + [event.time] }
        }
        process(event, notifications: &notifications)
        lock.unlock()
        flush(released, stalled: stalled)
        for (e, s, b) in notifications { observe?(e, s, b) }
    }

    /// Caller holds lock. Forward or hold one keyboard event.
    private func process(_ event: InputEvent, notifications: inout [(InputEvent, UInt64, UInt64?)]) {
        if event.value == 0, delivered.contains(event.code), !pending.contains(where: { $0.code == event.code && $0.value != 0 }) {
            // A release of a key the desktop already has down is never held: holding it would
            // turn a short press into a long one and start key repeat.
            delivered.remove(event.code)
            sink.key(event.code, 0); sink.sync()
            if event.code == KeyCodes.leftShift || event.code == KeyCodes.rightShift {
                let reservation = reserveBoundary(event)
                notifications.append((event, forwardedSequence, reservation))
            } else if KeyCodes.modifiers.contains(event.code) {
                notifications.append((event, forwardedSequence, nil))
            }
            return
        }
        if gated || boundaryReserved || !pending.isEmpty {
            pending.append(event)
            return
        }
        deliver(event, notifications: &notifications)
    }

    /// Caller holds lock; the gate is open.
    private func deliver(_ event: InputEvent, notifications: inout [(InputEvent, UInt64, UInt64?)]) {
        let reservation = reserveBoundary(event)
        if event.isKeyDown, [KeyCodes.enter, 96, 1, 103, 105, 106, 108].contains(event.code) { generation &+= 1 }
        // Tab leaves the field: hold it until the word before it is finished.
        if reservation != nil, event.code == KeyCodes.tab, event.value == 1 {
            pending.insert(event, at: 0); heldTab = true
            notifications.append((event, forwardedSequence, reservation))
            return
        }
        if event.value != 0 { delivered.insert(event.code) } else { delivered.remove(event.code) }
        sink.key(event.code, event.value); sink.sync()
        if event.value != 0 { forwardedSequence &+= 1 }
        // Releases matter only for Shift and the other modifiers (the tap gesture and chords).
        if event.value != 0 || KeyCodes.modifiers.contains(event.code) {
            notifications.append((event, event.value != 0 ? forwardedSequence : 0, reservation))
        }
    }

    /// Caller holds lock. A Space, a Tab or a completed Shift tap: the keys after it wait until
    /// the engine has looked at it, as on the Mac.
    private func reserveBoundary(_ event: InputEvent) -> UInt64? {
        guard accepting, !faulted else { return nil }
        let clean = Self.clean(delivered)
        var shiftTap = false
        if event.code == KeyCodes.leftShift || event.code == KeyCodes.rightShift {
            let key: UInt16 = event.code == KeyCodes.leftShift ? 56 : 60
            if event.value == 1 { boundaryShift.press(key: key, at: event.time, clean: clean) }
            else if event.value == 0 { shiftTap = boundaryShift.release(key: key, at: event.time, clean: clean) }
        } else if event.value != 0 { boundaryShift.cancel() }
        let boundary = event.value == 1 && (event.code == KeyCodes.space || event.code == KeyCodes.tab) && clean
        guard boundary || shiftTap, !gated, !boundaryReserved else { return nil }
        boundaryReserved = true; boundaryCancelled = false; boundaryID &+= 1
        lastProgress = clock()
        return boundaryID
    }

    /// Caller holds lock. Releases held keys once nothing has progressed for captureTimeout.
    private func releaseIfStalled(into released: inout [InputEvent]) -> Bool {
        let capturing = gated || boundaryReserved || !pending.isEmpty
        guard capturing, clock() - lastProgress > captureTimeout else { return false }
        released = pending
        clear()
        generation &+= 1
        return true
    }

    /// Caller holds lock.
    private func clear() {
        boundaryCancelled = boundaryReserved || boundaryCancelled
        pending = []; gated = false; committing = false; gateOwner = nil; boundaryReserved = false; heldTab = false
    }

    private func flush(_ events: [InputEvent], stalled: Bool) {
        guard !events.isEmpty || stalled else { return }
        lock.lock()
        for event in events {
            if event.value != 0 { delivered.insert(event.code) } else { delivered.remove(event.code) }
            sink.key(event.code, event.value)
        }
        sink.sync()
        lock.unlock()
        if stalled { onStall?() }
    }

    /// The watchdog, also called by the input thread when no event arrives.
    public func tick() {
        var released: [InputEvent] = []
        lock.lock()
        let stalled = releaseIfStalled(into: &released) && !stalledReported
        if stalled { stalledReported = true }
        lock.unlock()
        flush(released, stalled: stalled)
    }

    // MARK: Engine side

    /// Hold the keyboard while an edit is typed. Refused when a newer key exists, including one
    /// already forwarded to the desktop but not yet observed: erasing by count would miss it.
    func beginGate(revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !faulted, generation == revision, !gated, !boundaryCancelled, observedSequence == forwardedSequence else { return false }
        boundaryReserved = false
        gated = true; committing = false; gateOwner = revision
        lastProgress = clock()
        stalledReported = false
        return true
    }

    /// The edit starts now: true while the gate is still this revision's.
    func commitGate(revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard gated, generation == revision, gateOwner == revision else { return false }
        committing = true
        lastProgress = clock()
        return true
    }

    func progress() { lock.lock(); lastProgress = clock(); lock.unlock() }

    func endGate(revision: UInt64?) {
        lock.lock()
        if let revision, gateOwner != revision { lock.unlock(); return }
        gated = false; committing = false; gateOwner = nil
        lastProgress = clock()
        lock.unlock()
        drain()
    }

    /// The engine has looked at the event that reserved this boundary.
    func finishBoundary(_ id: UInt64) {
        lock.lock()
        let unused = boundaryReserved && boundaryID == id
        if unused { boundaryReserved = false }
        if boundaryID == id { boundaryCancelled = false }
        lastProgress = clock()
        lock.unlock()
        if unused { drain() }
    }

    /// Replay held keys in order, as if they arrived now, until one of them reserves again.
    func drain() {
        var notifications: [(InputEvent, UInt64, UInt64?)] = []
        lock.lock()
        while !gated, !boundaryReserved, !pending.isEmpty {
            let event = pending.removeFirst()
            if heldTab, event.code == KeyCodes.tab, event.value == 1 {
                // The Tab held until its word was finished: it was observed already.
                heldTab = false
                delivered.insert(event.code); sink.key(event.code, 1); sink.sync(); forwardedSequence &+= 1
                observedSequence = max(observedSequence, forwardedSequence)
                continue
            }
            if event.value == 0, delivered.contains(event.code) {
                delivered.remove(event.code); sink.key(event.code, 0); sink.sync()
                if KeyCodes.modifiers.contains(event.code) {
                    let reservation = (event.code == KeyCodes.leftShift || event.code == KeyCodes.rightShift) ? reserveBoundary(event) : nil
                    notifications.append((event, forwardedSequence, reservation))
                }
                continue
            }
            deliver(event, notifications: &notifications)
        }
        lock.unlock()
        for (e, s, b) in notifications { observe?(e, s, b) }
    }

    private var heldTab = false

    /// Release everything held (a fault or shutdown).
    func releaseAll() {
        lock.lock()
        let remaining = pending
        clear()
        generation &+= 1
        lock.unlock()
        flush(remaining, stalled: false)
    }
}
