import Cocoa
import Carbon
import SwitchCore

final class KeyboardMonitor {
    static let editTag: Int64 = 0x5941534E4F45
    struct Token {
        let text: String
        let suffix: String
        let sourceID: String
        let pid: pid_t
        let revision: UInt64
        var liveConverted = false
        var physicalKeys: [KeyboardLayout.KeyStroke]? = nil
    }
    var onToken: ((Token) -> Void)?
    var onProgress: ((Token) -> Void)?
    var onManual: ((Token?) -> Void)?
    var onFault: (() -> Void)?
    /// A capture was released by a watchdog or a disabled tap, and interception continues.
    var onRecovered: (() -> Void)?
    var onCancelAnalysis: (() -> Void)?
    private var hasFaulted = false // Access under lock, including tap-side reads.
    var faulted: Bool { lock.lock(); defer { lock.unlock() }; return hasFaulted }
    // Layout tables, token and application state belong to main. Only gate/replay
    // routing crosses the tap/worker boundary and every such field is under lock.
    private var activeLayouts: [KeyboardLayout] = [] { didSet { publishReplayLayout() } }
    var layouts: [KeyboardLayout] {
        get { dispatchPrecondition(condition: .onQueue(.main)); return activeLayouts }
        set { dispatchPrecondition(condition: .onQueue(.main)); activeLayouts = newValue }
    }
    private var acceptingInput = false
    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return acceptingInput }
        set {
            dispatchPrecondition(condition: .onQueue(.main))
            lock.lock(); let changed = acceptingInput != newValue; acceptingInput = newValue
            if !newValue { boundaryShiftGesture.reset() }
            lock.unlock()
            if changed && !newValue { reset() }
        }
    }
    private var tap: CFMachPort? { didSet { lock.lock(); activeTap = tap; lock.unlock() } }
    private var activeTap: CFMachPort? // Under lock; the tap thread re-enables a disabled tap.
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop? // Under lock; only for terminal shutdown.
    private var stopped = false
    private var token = ""
    private var physicalKeys: [KeyboardLayout.KeyStroke]? = []
    private var completedToken: Token?
    private var liveConverted = false
    private var sourceID = "" { didSet { publishReplayLayout() } }
    private var pid: pid_t = 0
    private var shiftGesture = ShiftTapGesture()
    private var boundaryShiftGesture = ShiftTapGesture() // Tap-side reservation only; under lock.
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var gated = false
    // The tap reserves a boundary before the main queue can process it. Otherwise a
    // blocked UI thread lets later keys reach a temporarily selected word.
    private var boundaryReserved = false
    private var boundaryCancelled = false
    private var committing = false
    private var draining = false
    private var replayInFlight = false
    private var replaySequence: UInt64 = 0
    private var replayAcknowledgements = 0
    // Captured input must never depend on the main queue being alive. Every gate/replay
    // step records progress; the tap releases input itself once progress stalls.
    private var lastProgress: UInt64 = 0
    private var gateOwner: UInt64?
    private var replayLayout: KeyboardLayout? // Snapshot of the selected layout for tap-side release.
    private var recentFailures: [UInt64] = [] // Main only.
    private let captureTimeout: UInt64
    private let failureWindow: UInt64 = 60_000_000_000
    private let failureBudget: Int
    private let clock: () -> UInt64
    // Key-up is safe to deliver while AX is editing; delaying it turns a short
    // physical press into a long press and can summon the system accent picker.
    private var deliveredKeys: Set<Int64> = []
    private var replayedDowns: [Int64: CGEvent] = [:] // Prepared down metadata, under lock.
    private let replaySource = CGEventSource(stateID: .privateState)
    private var pending: [CGEvent] = []
    private let replayTag: Int64 = 0x5941534E4F
    private let releaseTag: Int64 = 0x5941534E4F52 // Observed physical release, not a replay acknowledgement.
    private let postEvent: (CGEvent) -> Void
    private let currentSourceID: () -> String
    private let currentPID: () -> pid_t
    private let secureInputEnabled: () -> Bool

    init(postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) },
         currentSourceID: @escaping () -> String = KeyboardLayout.currentID,
         currentPID: @escaping () -> pid_t = { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 },
         secureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         captureTimeout: TimeInterval = 1.0, failureBudget: Int = 3,
         clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.postEvent = postEvent
        self.captureTimeout = UInt64(max(captureTimeout, 0.05) * 1_000_000_000)
        self.failureBudget = max(failureBudget, 1)
        self.clock = clock
        self.currentSourceID = currentSourceID
        self.currentPID = currentPID
        self.secureInputEnabled = secureInputEnabled
        if let replaySource { EventReplay.allowLocalInput(replaySource) }
    }

    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    var hasPendingInput: Bool {
        lock.lock(); defer { lock.unlock() }
        return gated || draining || boundaryReserved || replayInFlight || !pending.isEmpty
    }
    var running: Bool { tap != nil }

    /// Hold physical input briefly while an exact AX edit is committed. Replay in order so
    /// typing during the replacement cannot overwrite a temporarily selected word.
    func beginGate(revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !hasFaulted, generation == revision, !gated, !boundaryCancelled else { return false }
        boundaryReserved = false
        gated = true
        committing = false
        gateOwner = revision
        lastProgress = clock()
        return true
    }

    func commitGate(revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard gated, generation == revision else { return false }
        committing = true
        lastProgress = clock()
        return true
    }

    func syncSource(_ id: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard sourceID != id else { return }
        reset()
        sourceID = id
    }

    func syncApplication(_ newPID: pid_t) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard pid != newPID else { return }
        reset()
        pid = newPID
    }

    /// Pass the revision given to beginGate. A gate already released by the watchdog
    /// must not end a newer gate when the stalled worker finally finishes.
    func endGate(revision: UInt64? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        if let revision, gateOwner != revision { lock.unlock(); return }
        gated = false; committing = false; gateOwner = nil
        lastProgress = clock()
        draining = !hasFaulted
        let canDrain = !hasFaulted
        lock.unlock()
        if canDrain { drainNext() }
    }

    /// Keep physical input queued until each older replay has re-entered our tap. Posting
    /// a whole batch and immediately opening the gate lets new HID events overtake it.
    private func drainNext() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        guard !hasFaulted, !gated, !replayInFlight else { lock.unlock(); return }
        guard !pending.isEmpty else { draining = false; lock.unlock(); return }
        let event = pending.removeFirst()
        var batch = [event]
        // Post an already complete physical press together. Waiting for the UI
        // queue between down and up can extend the press by an arbitrary AX stall.
        if event.type == .keyDown {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            // Overlapping typing can put another key's down between this down/up.
            // Releases may pass those queued presses, but never another press of
            // the same key. Character-producing downs retain their exact order.
            if let index = pending.firstIndex(where: {
                ($0.type == .keyDown || $0.type == .keyUp) && $0.getIntegerValueField(.keyboardEventKeycode) == key
            }), pending[index].type == .keyUp {
                batch.append(pending.remove(at: index))
            }
        }
        draining = true; replayInFlight = true; replaySequence &+= 1
        replayAcknowledgements = batch.count
        lastProgress = clock()
        let sequence = replaySequence
        let layout = replayLayout
        lock.unlock()
        for item in batch {
            prepare(item, tag: replayTag, layout: layout)
            postEvent(item)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let missing = self.replayInFlight && self.replaySequence == sequence
            self.lock.unlock()
            guard missing else { return }
            self.failOpen()
        }
    }

    private func publishReplayLayout() {
        let layout = activeLayouts.first { $0.id == sourceID }
        lock.lock(); replayLayout = layout; lock.unlock()
    }

    /// Safe on any thread: the layout is an immutable snapshot taken under lock.
    private func prepare(_ event: CGEvent, tag: Int64, layout: KeyboardLayout?) {
        // A captured event belongs to another event source: mutating its userData field
        // alone can silently retain the original tag. Give the copy our own source.
        if let replaySource { EventReplay.rebind(event, source: replaySource, tag: tag) }
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        if event.type == .keyDown || event.type == .keyUp,
               event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty,
               let layout {
                let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let shift = event.flags.contains(.maskShift)
                if var text = layout.character(key: key, shift: shift) {
                    if event.flags.contains(.maskAlphaShift), text.contains(where: \.isLetter) {
                        text = shift ? text.lowercased() : text.uppercased()
                    }
                    let units = Array(text.utf16)
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                }
        }
    }

    /// Release all captured input. A single transient failure (a tap disabled by the
    /// system after sleep or load, one lost replay, a stalled UI queue) only resets the
    /// current word; interception stops for good only after repeated failures.
    private func failOpen() {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = clock()
        recentFailures = recentFailures.filter { now &- $0 < failureWindow } + [now]
        let permanent = recentFailures.count >= failureBudget
        lock.lock()
        let remaining = pending
        clearCapture()
        generation &+= 1
        if permanent { hasFaulted = true }
        let layout = replayLayout, halted = stopped
        lock.unlock()
        if permanent { enabled = false } else { reset() }
        // A failed replay must never leave the keyboard or mouse captured indefinitely.
        for event in remaining { prepare(event, tag: Self.editTag, layout: layout); postEvent(event) }
        guard !halted else { return }
        if permanent { onFault?() } else { onRecovered?() }
    }

    /// Caller holds lock.
    private func clearCapture() {
        pending = []; gated = false; boundaryReserved = false; boundaryCancelled = false
        draining = false; committing = false; replayInFlight = false; replayAcknowledgements = 0
        gateOwner = nil
    }

    /// Tap thread. Releases captured input without the main queue once no gate or replay
    /// step has progressed for captureTimeout, then reports the failure to main.
    private func releaseIfStalled(postAtTap: ((CGEvent) -> Void)?) -> Bool {
        lock.lock()
        let capturing = gated || draining || boundaryReserved || replayInFlight || !pending.isEmpty
        guard capturing, clock() &- lastProgress > captureTimeout else { lock.unlock(); return false }
        let remaining = pending
        clearCapture()
        generation &+= 1
        let layout = replayLayout
        lock.unlock()
        for event in remaining {
            prepare(event, tag: Self.editTag, layout: layout)
            if let postAtTap { postAtTap(event) } else { postEvent(event) }
        }
        DispatchQueue.main.async { [weak self] in self?.failOpen() }
        return true
    }

    private func replayDelivered() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        replayAcknowledgements -= 1
        let complete = replayAcknowledgements <= 0
        if complete { replayInFlight = false }
        lastProgress = clock()
        lock.unlock()
        guard complete else { return }
        // The current callback must return before forwarding the next queued event.
        DispatchQueue.main.async { [weak self] in self?.drainNext() }
    }

    private func captureIfGated(_ event: CGEvent) -> Bool {
        let tag = event.getIntegerValueField(.eventSourceUserData)
        // Replayed input can reach another word boundary and start a new edit. Remaining
        // replay events must then wait too, rather than invalidating that next correction.
        guard tag != Self.editTag, tag != replayTag else { return false }
        lock.lock(); defer { lock.unlock() }
        if event.type == .keyUp, deliveredKeys.contains(event.getIntegerValueField(.keyboardEventKeycode)) {
            return false
        }
        guard (gated || draining || boundaryReserved), let copy = event.copy() else { return false }
        if (gated || boundaryReserved), event.type != .keyDown && event.type != .keyUp && event.type != .flagsChanged && !committing {
            // Cancel a prepared edit, but replay earlier keys before the click in arrival order.
            // Once Unicode has been submitted, keep the click queued until acknowledgement.
            generation &+= 1
            if boundaryReserved { boundaryCancelled = true }
        }
        pending.append(copy)
        return true
    }

    private func reserveBoundary(_ event: CGEvent) -> Bool {
        let tag = event.getIntegerValueField(.eventSourceUserData)
        guard tag != Self.editTag, tag != replayTag else { return false }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        lock.lock(); defer { lock.unlock() }
        guard acceptingInput, !hasFaulted else { return false }
        let clean = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty
        var shiftTap = false
        if event.type == .flagsChanged {
            if key == 56 || key == 60 {
                let time = TimeInterval(event.timestamp) / 1_000_000_000
                if event.flags.contains(.maskShift) { boundaryShiftGesture.press(key: UInt16(key), at: time, clean: clean) }
                else { shiftTap = boundaryShiftGesture.release(key: UInt16(key), at: time, clean: clean) }
            } else { boundaryShiftGesture.cancel() }
        } else if event.type != .keyUp { boundaryShiftGesture.cancel() }
        let boundary = event.type == .keyDown && key == 49 && clean
        guard boundary || shiftTap, !gated, !draining, !boundaryReserved else { return false }
        boundaryReserved = true; boundaryCancelled = false
        lastProgress = clock()
        return true
    }

    private func finishBoundaryObservation() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        let unused = boundaryReserved
        if unused { boundaryReserved = false; boundaryCancelled = false; draining = !hasFaulted }
        lastProgress = clock()
        lock.unlock()
        if unused { drainNext() }
    }

    func reset() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock(); generation &+= 1; lock.unlock()
        token = ""; physicalKeys = []; completedToken = nil; liveConverted = false; shiftGesture.reset()
        onCancelAnalysis?()
    }

    /// Called on main after a confirmed mid-word replacement and source switch,
    /// before releasing queued keys. Keep the whole word for Shift and Space.
    func resumeAfterLiveCorrection(text: String, sourceID: String, pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.sourceID = sourceID; self.pid = pid
        token = text; completedToken = nil; liveConverted = true
        physicalKeys = nil
    }

    private func snapshot(suffix: String = "", revision: UInt64) -> Token {
        Token(text: token, suffix: suffix, sourceID: sourceID, pid: pid,
              revision: revision, liveConverted: liveConverted, physicalKeys: physicalKeys)
    }

    /// Invoked on the dedicated tap thread; observation and app state stay on main.
    func handleTapEvent(_ type: CGEventType, _ event: CGEvent,
                        postAtTap: ((CGEvent) -> Void)? = nil) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system disables taps after sleep, user switching or load. Re-enable here;
            // waiting for main would leave the tap off while the UI queue is busy.
            lock.lock(); let port = activeTap, halted = stopped; lock.unlock()
            if let port, !halted { CGEvent.tapEnable(tap: port, enable: true) }
            DispatchQueue.main.async { [weak self] in self?.failOpen() }
        } else {
            let tag = event.getIntegerValueField(.eventSourceUserData)
            if tag == Self.editTag { return Unmanaged.passUnretained(event) }
            if tag != replayTag, releaseIfStalled(postAtTap: postAtTap), let postAtTap {
                // Earlier captured input was just posted at this tap; keep this event after it.
                postAtTap(event); return nil
            }
            if captureIfGated(event) { return nil }
            if tag != Self.editTag {
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                lock.lock()
                var down: CGEvent?
                if type == .keyDown {
                    deliveredKeys.insert(key)
                    if tag == replayTag { replayedDowns[key] = event.copy() }
                    else { replayedDowns.removeValue(forKey: key) }
                }
                if type == .keyUp { deliveredKeys.remove(key); down = replayedDowns.removeValue(forKey: key) }
                // Mouse releases and drags only matter to a pending Shift tap. Do not copy and
                // publish each of them (60–120 per second while dragging) to main otherwise.
                let mouseTail = [CGEventType.leftMouseUp, .rightMouseUp, .otherMouseUp,
                                 .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type)
                let quiet = !acceptingInput || (mouseTail && !boundaryShiftGesture.isPressed)
                let idle = quiet && !gated && !draining && !boundaryReserved && tag != replayTag
                // Invalidate delayed analysis as soon as navigation reaches the tap,
                // even while the UI queue has not observed Enter yet.
                if type == .keyDown && [36, 76, 48, 53, 123, 124, 125, 126].contains(key) { generation &+= 1 }
                lock.unlock()
                if let down { EventReplay.matchRelease(event, to: down, tag: tag == replayTag ? replayTag : releaseTag) }
                if idle { return Unmanaged.passUnretained(event) }
            }
            guard let copy = event.copy() else {
                DispatchQueue.main.async { [weak self] in self?.reset() }
                return Unmanaged.passUnretained(event)
            }
            let reserved = reserveBoundary(event)
            // No AX, TIS, application lookup or main-queue wait is allowed here.
            // Browser/UI IPC can otherwise stall the tap and lose hardware input.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.receive(type, copy)
                if copy.getIntegerValueField(.eventSourceUserData) == self.replayTag { self.replayDelivered() }
                if reserved { self.finishBoundaryObservation() }
            }
            // A physical release can arrive after drainNext posted a down but
            // before that down re-enters the tap. It is then already queued here.
            // Forward down/up at the proxy, in that order, without waiting for AX
            // or the main queue. Proxy posts go after this tap and do not recurse.
            if type == .keyDown, copy.getIntegerValueField(.eventSourceUserData) == replayTag,
               let postAtTap {
                let key = copy.getIntegerValueField(.keyboardEventKeycode)
                lock.lock()
                let index = pending.firstIndex {
                    ($0.type == .keyDown || $0.type == .keyUp) && $0.getIntegerValueField(.keyboardEventKeycode) == key
                }
                let release: CGEvent?
                if let index, pending[index].type == .keyUp {
                    release = pending.remove(at: index)
                    deliveredKeys.remove(key)
                    replayedDowns.removeValue(forKey: key)
                } else { release = nil }
                lock.unlock()
                if let release {
                    EventReplay.matchRelease(release, to: event, tag: replayTag)
                    postAtTap(event); postAtTap(release); return nil
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    func start() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard replaySource != nil, !faulted, !stopped else { return false }
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                  .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                  .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { proxy, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
                .handleTapEvent(type, event, postAtTap: { $0.tapPostEvent(proxy) })
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap); self.tap = nil; return false
        }
        runLoopSource = source
        let thread = Thread { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()!
            self.lock.lock()
            guard !self.stopped else { self.lock.unlock(); return }
            self.tapRunLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.lock.unlock()
            CFRunLoopRun()
            self.lock.lock(); self.tapRunLoop = nil; self.lock.unlock()
        }
        thread.name = "local.yasno.event-tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        return true
    }

    /// Terminal cleanup at application exit. Pausing uses the cheap pass-through
    /// path so an outstanding physical release/replay can still be delivered.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        enabled = false
        lock.lock()
        stopped = true
        let remaining = pending, loop = tapRunLoop, layout = replayLayout
        clearCapture()
        lock.unlock()
        for event in remaining { prepare(event, tag: Self.editTag, layout: layout); postEvent(event) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = runLoopSource { CFRunLoopSourceInvalidate(source) }
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
        tap = nil; runLoopSource = nil; tapThread = nil
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        dispatchPrecondition(condition: .onQueue(.main))
        if event.getIntegerValueField(.eventSourceUserData) == Self.editTag { return }
        // Releasing a key pressed before Shift does not make this a Shift chord.
        // In particular Space-up often overlaps the following standalone Shift tap.
        if type == .keyUp { return }
        guard enabled, !secureInputEnabled() else { reset(); return }
        if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp ||
           type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            shiftGesture.cancel()
            return
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown { reset(); return }
        let flags = event.flags
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged {
            guard key == 56 || key == 60 else { shiftGesture.cancel(); return }
            // Preserve physical hold duration even when events were briefly queued for an edit.
            let now = TimeInterval(event.timestamp) / 1_000_000_000
            let clean = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty
            if flags.contains(.maskShift) {
                shiftGesture.press(key: UInt16(key), at: now, clean: clean)
            } else if shiftGesture.release(key: UInt16(key), at: now, clean: clean) {
                // A deliberate manual action supersedes any pending word analysis.
                lock.lock(); generation &+= 1; let revision = generation; lock.unlock()
                let expected = token.isEmpty ? completedToken : snapshot(revision: revision)
                token = ""; physicalKeys = []; completedToken = nil; liveConverted = false; onManual?(expected)
            }
            return
        }
        shiftGesture.cancel()
        // Notifications may arrive after the first key. Reconcile once per word, not on
        // every keystroke, so an external/menu switch cannot leave a stale cached layout.
        if token.isEmpty {
            liveConverted = false
            physicalKeys = []
            syncSource(currentSourceID())
            syncApplication(currentPID())
        }
        lock.lock(); generation &+= 1; let revision = generation; lock.unlock()
        if key != 49 { completedToken = nil }
        guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty,
              pid > 0 else { token = ""; physicalKeys = []; onCancelAnalysis?(); return }
        let currentID = sourceID
        if key == 51 {
            if !token.isEmpty {
                token.removeLast()
                if physicalKeys?.isEmpty == false { physicalKeys?.removeLast() }
                onProgress?(snapshot(revision: revision))
            }
            return
        }
        // Enter may send a message immediately. Never attempt a delayed edit after sending.
        if key == 36 || key == 76 || key == 48 || key == 53 || (123...126).contains(key) {
            token = ""; physicalKeys = []; onCancelAnalysis?(); return
        }
        if key == 49 {
            if !token.isEmpty {
                let completed = snapshot(suffix: " ", revision: revision)
                completedToken = completed
                onToken?(completed)
            } else if let previous = completedToken, previous.suffix.count < 8 {
                completedToken = Token(text: previous.text, suffix: previous.suffix + " ",
                    sourceID: previous.sourceID, pid: previous.pid, revision: revision, liveConverted: previous.liveConverted,
                    physicalKeys: previous.physicalKeys)
            } else { completedToken = nil }
            token = ""; physicalKeys = []; liveConverted = false; return
        }
        // At a session tap Unicode may still reflect the event's source layout, while the
        // application renders it using the selected layout. Decode the physical key ourselves.
        guard let layout = layouts.first(where: { $0.id == currentID }),
              var string = layout.character(key: UInt16(key), shift: flags.contains(.maskShift))
        else { token = ""; return }
        if flags.contains(.maskAlphaShift), string.contains(where: \.isLetter) {
            string = flags.contains(.maskShift) ? string.lowercased() : string.uppercased()
        }
        guard !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              token.count + string.count <= 512 else { token = ""; return }
        token += string
        physicalKeys?.append(.init(key: UInt16(key), shift: flags.contains(.maskShift), capsLock: flags.contains(.maskAlphaShift)))
        onProgress?(snapshot(revision: revision))
    }

    static func insertUnicode(_ text: String, pid: pid_t) -> Bool {
        guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState) else { return false }
        source.userData = editTag
        EventReplay.allowLocalInput(source)
        let units = Array(text.utf16)
        for offset in stride(from: 0, to: units.count, by: 16) {
            let chunk = Array(units[offset..<min(offset + 16, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            for event in [down, up] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: editTag)
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            }
            down.postToPid(pid)
            up.postToPid(pid)
        }
        return true
    }
}
