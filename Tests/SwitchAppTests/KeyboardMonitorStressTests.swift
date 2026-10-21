import XCTest
import Cocoa
import SwitchCore
@testable import SwitchApp

@MainActor
final class KeyboardMonitorStressTests: XCTestCase {
    private struct Signature: Equatable {
        let type: UInt32
        let key: Int64
        let flags: UInt64
        let timestamp: UInt64
        init(_ event: CGEvent) {
            type = event.type.rawValue; key = event.getIntegerValueField(.keyboardEventKeycode)
            flags = event.flags.rawValue; timestamp = event.timestamp
        }
    }
    private final class Rig {
        var source: String
        var pid: pid_t = 123
        var secure = false
        let monitor: KeyboardMonitor
        var completed: [KeyboardMonitor.Token] = []
        var progress: [KeyboardMonitor.Token] = []
        var manual: [KeyboardMonitor.Token?] = []
        var forwarded: [Signature] = []
        var onForward: (() -> Void)?
        init(layouts: [KeyboardLayout]) {
            source = layouts[0].id
            // The indirection allows the monitor to re-enter its actual replay path.
            var forwarding: ((CGEvent) -> Void)?
            var currentSource: (() -> String)?
            var currentPID: (() -> pid_t)?
            var isSecure: (() -> Bool)?
            monitor = KeyboardMonitor(postEvent: { forwarding?($0) },
                currentSourceID: { currentSource?() ?? "" }, currentPID: { currentPID?() ?? 0 },
                secureInputEnabled: { isSecure?() ?? false })
            forwarding = { [weak self] event in self?.send(event) }
            currentSource = { [weak self] in self?.source ?? "" }
            currentPID = { [weak self] in self?.pid ?? 0 }
            isSecure = { [weak self] in self?.secure ?? false }
            monitor.layouts = layouts; monitor.enabled = true
            monitor.onToken = { [weak self] in self?.completed.append($0) }
            monitor.onProgress = { [weak self] in self?.progress.append($0) }
            monitor.onManual = { [weak self] in self?.manual.append($0) }
        }
        func send(_ event: CGEvent) {
            if monitor.handleTapEvent(event.type, event, postAtTap: { self.forward($0) }) != nil { forward(event) }
        }
        private func forward(_ event: CGEvent) {
            forwarded.append(Signature(event)); onForward?()
        }
    }
    private func layouts() throws -> [KeyboardLayout] {
        let installed = KeyboardLayout.installed(enabledOnly: false)
        return try ["ABC", "Russian", "Ukrainian"].map { suffix in
            try XCTUnwrap(installed.first { $0.id == "com.apple.keylayout." + suffix })
        }
    }
    private var tick: UInt64 = 1_000_000_000
    private func key(_ code: UInt16, flags: CGEventFlags = [], down: Bool = true) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags; event.timestamp = tick; tick += 10_000_000
        return event
    }
    private func shift(_ down: Bool, code: UInt16 = 56, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try key(code, flags: down ? flags.union(.maskShift) : flags, down: down)
        event.type = .flagsChanged
        return event
    }
    private func flush() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func testCapitalLetterChordDoesNotQueueTheFollowingLowercaseLetter() async throws {
        let rig = Rig(layouts: try layouts())
        let events = [try shift(true), try key(0, flags: .maskShift), try key(0, flags: .maskShift, down: false),
                      try shift(false), try key(11), try key(11, down: false)]
        for event in events { rig.send(event) }
        XCTAssertEqual(rig.forwarded, events.map(Signature.init), "No UI turn/replay should be needed after an uppercase chord")
        await flush(); await flush()
        XCTAssertTrue(rig.manual.isEmpty)
    }

    func testLongShiftDoesNotReserveTheFollowingInput() async throws {
        let rig = Rig(layouts: try layouts())
        let down = try shift(true), up = try shift(false)
        up.timestamp = down.timestamp + 600_000_000
        let events = [down, up, try key(11), try key(11, down: false)]
        for event in events { rig.send(event) }
        XCTAssertEqual(rig.forwarded, events.map(Signature.init))
        await flush(); await flush()
        XCTAssertTrue(rig.manual.isEmpty)
    }

    func testNavigationInvalidatesBeforeTheMainQueueObservesItAndCancelsAnalysis() async throws {
        for code: UInt16 in [36, 76, 48, 53, 123, 124, 125, 126] {
            let rig = Rig(layouts: try layouts())
            rig.send(try key(5)); await flush()
            let revision = rig.monitor.revision
            var cancellations = 0
            rig.monitor.onCancelAnalysis = { cancellations += 1 }
            rig.send(try key(code))
            XCTAssertNotEqual(rig.monitor.revision, revision, "physical navigation must invalidate immediately")
            await flush()
            XCTAssertGreaterThan(cancellations, 0)
            XCTAssertFalse(rig.monitor.beginGate(revision: revision))
        }
    }

    func testProxyReleaseKeepsTheNewLayoutUnicodeAndReplaySource() async throws {
        let active = try layouts(), ru = active[1]
        var posted: [CGEvent] = [], forwarded: [CGEvent] = []
        let monitor = KeyboardMonitor(postEvent: { posted.append($0) }, currentSourceID: { ru.id },
            currentPID: { 123 }, secureInputEnabled: { false })
        monitor.layouts = active; monitor.enabled = true; monitor.syncSource(ru.id)
        XCTAssertTrue(monitor.beginGate(revision: monitor.revision))
        let down = try key(17), up = try key(17, down: false)
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x0074])
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x0074])
        XCTAssertNil(monitor.handleTapEvent(.keyDown, down))
        monitor.endGate()
        XCTAssertNil(monitor.handleTapEvent(.keyUp, up))
        XCTAssertNil(monitor.handleTapEvent(.keyDown, posted[0], postAtTap: { forwarded.append($0) }))
        XCTAssertEqual(forwarded.count, 2)
        for event in forwarded {
            var count = 0, units = [UniChar](repeating: 0, count: 16)
            event.keyboardGetUnicodeString(maxStringLength: 16, actualStringLength: &count, unicodeString: &units)
            XCTAssertEqual(Array(units.prefix(count)), [0x0435]) // RU е on physical T
            XCTAssertEqual(event.getIntegerValueField(.eventSourceStateID), posted[0].getIntegerValueField(.eventSourceStateID))
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), posted[0].getIntegerValueField(.eventSourceUserData))
        }
        await flush(); await flush()
        XCTAssertEqual(posted.count, 1)
        XCTAssertFalse(monitor.faulted)
    }

    func testPhysicalReleaseOfReplayedDownDoesNotBecomeAnExtraReplayAcknowledgement() async throws {
        let rig = Rig(layouts: try layouts())
        XCTAssertTrue(rig.monitor.beginGate(revision: rig.monitor.revision))
        rig.send(try key(17))
        rig.monitor.endGate() // down re-enters synchronously through mock postEvent
        rig.send(try key(17, down: false)) // physical release bypasses the gate
        rig.send(try key(4)); rig.send(try key(4, down: false))
        for _ in 0..<6 { await flush() }
        XCTAssertEqual(rig.forwarded.map(\.key), [17, 17, 4, 4])
        XCTAssertFalse(rig.monitor.faulted)
    }

    func testTerminalStopReleasesPendingInputExactlyOnceAndCannotRestart() async throws {
        let rig = Rig(layouts: try layouts())
        XCTAssertTrue(rig.monitor.beginGate(revision: rig.monitor.revision))
        let events = [try key(17), try key(17, down: false)]
        for event in events { rig.send(event) }
        rig.monitor.stop()
        XCTAssertEqual(rig.forwarded, events.map(Signature.init))
        XCTAssertFalse(rig.monitor.enabled); XCTAssertFalse(rig.monitor.running)
        XCTAssertFalse(rig.monitor.start()) // Returns before creating an OS tap.
        rig.monitor.stop()
        XCTAssertEqual(rig.forwarded.count, 2)
        await flush()
    }

    func testReleaseOfAnAlreadyDeliveredKeyNeverWaitsForAnEdit() async throws {
        let rig = Rig(layouts: try layouts())
        let down = try key(17), up = try key(17, down: false)
        rig.send(down); await flush()
        XCTAssertTrue(rig.monitor.beginGate(revision: rig.monitor.revision))
        rig.send(up)
        XCTAssertEqual(rig.forwarded, [down, up].map(Signature.init), "A short physical press must not become a held key while AX is busy")
        rig.monitor.endGate()
        await flush(); await flush()
    }

    func testQueuedPressAndReleaseArePostedWithoutAMainQueueRoundTripBetweenThem() async throws {
        let active = try layouts()
        var posted: [Signature] = []
        let monitor = KeyboardMonitor(postEvent: { posted.append(Signature($0)) }, currentSourceID: { active[0].id },
                                      currentPID: { 123 }, secureInputEnabled: { false })
        monitor.layouts = active; monitor.enabled = true
        XCTAssertTrue(monitor.beginGate(revision: monitor.revision))
        let events = [try key(17), try key(17, down: false)]
        for event in events { XCTAssertNil(monitor.handleTapEvent(event.type, event)) }
        monitor.endGate()
        XCTAssertEqual(posted, events.map(Signature.init), "A renderer/UI stall must not separate a queued down/up pair")
        // Feed acknowledgements back into the mock tap; nothing is posted to macOS.
        for event in events { _ = monitor.handleTapEvent(event.type, event) }
        await flush(); await flush()
        XCTAssertFalse(monitor.faulted)
    }

    func testOverlappingQueuedPressesReleaseEachKeyWithoutWaitingForUI() async throws {
        let active = try layouts()
        var posted: [CGEvent] = []
        let monitor = KeyboardMonitor(postEvent: { posted.append($0) }, currentSourceID: { active[0].id },
            currentPID: { 123 }, secureInputEnabled: { false })
        monitor.layouts = active; monitor.enabled = true
        XCTAssertTrue(monitor.beginGate(revision: monitor.revision))
        let events = [try key(17), try key(4), try key(17, down: false), try key(4, down: false)]
        for event in events { XCTAssertNil(monitor.handleTapEvent(event.type, event)) }
        monitor.endGate()
        XCTAssertEqual(posted.map(Signature.init), [events[0], events[2]].map(Signature.init))
        for event in posted { _ = monitor.handleTapEvent(event.type, event) }
        await flush(); await flush(); await flush()
        XCTAssertEqual(posted.map(Signature.init), [events[0], events[2], events[1], events[3]].map(Signature.init))
        for event in posted.suffix(2) { _ = monitor.handleTapEvent(event.type, event) }
        await flush(); await flush()
        XCTAssertFalse(monitor.faulted)
    }

    func testReleaseArrivingBetweenReplayPostAndTapDeliveryDoesNotWaitForMain() async throws {
        let active = try layouts()
        var posted: [CGEvent] = [], forwarded: [Signature] = []
        let monitor = KeyboardMonitor(postEvent: { posted.append($0) }, currentSourceID: { active[0].id },
            currentPID: { 123 }, secureInputEnabled: { false })
        monitor.layouts = active; monitor.enabled = true
        XCTAssertTrue(monitor.beginGate(revision: monitor.revision))
        let down = try key(17), up = try key(17, down: false)
        XCTAssertNil(monitor.handleTapEvent(down.type, down))
        monitor.endGate()
        XCTAssertEqual(posted.count, 1)
        // WindowServer has not yet delivered the posted down back to the tap.
        XCTAssertNil(monitor.handleTapEvent(up.type, up))
        XCTAssertNil(monitor.handleTapEvent(posted[0].type, posted[0], postAtTap: { forwarded.append(Signature($0)) }))
        XCTAssertEqual(forwarded, [down, up].map(Signature.init))
        await flush(); await flush()
        XCTAssertEqual(posted.count, 1, "The release was delivered through the proxy, not replayed twice")
        XCTAssertFalse(monitor.faulted)
    }

    func testSymbolTokenRetainsShiftAndItsPhysicalKeyForManualConversion() async throws {
        let rig = Rig(layouts: try layouts())
        for event in [try shift(true), try key(21, flags: .maskShift), try key(21, flags: .maskShift, down: false),
                      try shift(false)] { rig.send(event) }
        await flush(); await flush()
        XCTAssertTrue(rig.manual.isEmpty, "Shift+4 itself is a chord, not a manual request")
        rig.send(try shift(true)); rig.send(try shift(false))
        await flush(); await flush()
        let token = try XCTUnwrap(try XCTUnwrap(rig.manual.last))
        XCTAssertEqual(token.text, "$")
        XCTAssertEqual(token.physicalKeys, [.init(key: 21, shift: true)])
        XCTAssertEqual(rig.monitor.layouts[1].render(try XCTUnwrap(token.physicalKeys)), "%")
    }

    func testNavigationThenReplacementPublishesOnlyTheNewLetter() async throws {
        let rig = Rig(layouts: try layouts())
        rig.send(try key(5)); rig.send(try key(4)); rig.send(try key(123)); rig.send(try key(2))
        rig.send(try shift(true)); rig.send(try shift(false))
        await flush(); await flush()
        let token = try XCTUnwrap(try XCTUnwrap(rig.manual.last))
        XCTAssertEqual(token.text, "d")
        XCTAssertEqual(token.physicalKeys, [.init(key: 2)])
    }

    func testTenThousandEventsKeepOrderAcrossOneThousandConsecutiveEdits() async throws {
        let rig = Rig(layouts: try layouts())
        var events: [CGEvent] = []
        for _ in 0..<1_000 {
            for code: UInt16 in [5, 4, 11, 45, 49] { events += [try key(code), try key(code, down: false)] }
        }
        let allForwarded = expectation(description: "all 10000 physical events forwarded exactly once")
        rig.onForward = { if rig.forwarded.count == events.count { allForwarded.fulfill() } }
        var edits = 0
        rig.monitor.onToken = { token in
            rig.completed.append(token)
            XCTAssertTrue(rig.monitor.beginGate(revision: token.revision))
            edits += 1
            DispatchQueue.main.async { rig.monitor.endGate() }
        }
        for event in events { rig.send(event) }
        await fulfillment(of: [allForwarded], timeout: 8)
        await flush()
        XCTAssertEqual(rig.forwarded, events.map(Signature.init))
        XCTAssertEqual(edits, 1_000)
        XCTAssertEqual(rig.completed.count, 1_000)
        XCTAssertFalse(rig.monitor.faulted)
    }

    func testBackspaceCapsLockAndShiftDecodePhysicalState() async throws {
        let rig = Rig(layouts: try layouts())
        for event in [try key(0, flags: .maskAlphaShift), try key(11, flags: [.maskAlphaShift, .maskShift]),
                      try key(8), try key(51), try key(2), try key(49)] { rig.send(event) }
        await flush()
        // A Mac keyboard layout types capitals with Caps Lock and Shift together.
        XCTAssertEqual(rig.completed.last?.text, "ABd")
        XCTAssertEqual(rig.completed.last?.suffix, " ")
    }

    func testNavigationPasteAndMouseDiscardStaleTokens() async throws {
        for code: UInt16 in [36, 76, 48, 53, 123, 124, 125, 126] {
            let rig = Rig(layouts: try layouts())
            rig.send(try key(5)); rig.send(try key(code)); rig.send(try key(49))
            await flush(); await flush()
            XCTAssertTrue(rig.completed.isEmpty, "navigation \(code)")
        }
        for flags: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn] {
            let rig = Rig(layouts: try layouts())
            rig.send(try key(5)); rig.send(try key(9, flags: flags)); rig.send(try key(49))
            await flush(); await flush()
            XCTAssertTrue(rig.completed.isEmpty)
        }
        let rig = Rig(layouts: try layouts())
        rig.send(try key(5))
        let click = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
        rig.send(click); rig.send(try key(49))
        await flush(); await flush()
        XCTAssertTrue(rig.completed.isEmpty)
    }

    func testSourceApplicationPauseAndRevisionInvalidatePendingWork() async throws {
        let active = try layouts(), rig = Rig(layouts: try layouts())
        rig.send(try key(5)); await flush()
        let revision = try XCTUnwrap(rig.progress.last?.revision)
        rig.monitor.syncSource(active[1].id)
        XCTAssertFalse(rig.monitor.beginGate(revision: revision))
        rig.monitor.syncApplication(456)
        XCTAssertFalse(rig.monitor.beginGate(revision: revision))
        rig.monitor.enabled = false
        rig.send(try key(4)); rig.send(try key(49))
        await flush(); await flush()
        XCTAssertTrue(rig.completed.isEmpty)
    }

    func testAllModifierCombinationsAndBothShiftKeysDoNotBecomeManualTap() async throws {
        let masks: [CGEventFlags] = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
        for code: UInt16 in [56, 60] {
            for combination in 1..<16 {
                var flags: CGEventFlags = []
                for (i, mask) in masks.enumerated() where combination & (1 << i) != 0 { flags.formUnion(mask) }
                let rig = Rig(layouts: try layouts())
                rig.send(try shift(true, code: code, flags: flags)); rig.send(try shift(false, code: code, flags: flags))
                await flush(); await flush()
                XCTAssertTrue(rig.manual.isEmpty)
            }
        }
    }

    func testDroppedReplayAcknowledgementFailsOpenAndReleasesRemainingInput() async throws {
        let active = try layouts()
        let fault = expectation(description: "missing replay acknowledgement fails open")
        var posted: [Signature] = []
        let monitor = KeyboardMonitor(postEvent: { posted.append(Signature($0)) }, currentSourceID: { active[0].id }, currentPID: { 123 },
                                      secureInputEnabled: { false }, failureBudget: 1)
        monitor.layouts = active; monitor.enabled = true
        monitor.onFault = { fault.fulfill() }
        XCTAssertTrue(monitor.beginGate(revision: monitor.revision))
        let events = try [key(0), key(0, down: false), key(11), key(11, down: false)]
        for event in events { XCTAssertNil(monitor.handleTapEvent(event.type, event)) }
        monitor.endGate()
        await fulfillment(of: [fault], timeout: 2)
        XCTAssertEqual(posted, events.map(Signature.init))
        XCTAssertTrue(monitor.faulted)
        XCTAssertFalse(monitor.enabled)
        let next = try key(8)
        XCTAssertNotNil(monitor.handleTapEvent(next.type, next))
    }

    func testSecureInputNeverPublishesTokensAndRecoveryStartsFresh() async throws {
        let rig = Rig(layouts: try layouts())
        rig.send(try key(5)); await flush()
        rig.progress.removeAll()
        rig.secure = true
        for event in [try key(4), try key(49), try shift(true), try shift(false)] { rig.send(event) }
        await flush(); await flush()
        XCTAssertTrue(rig.progress.isEmpty)
        XCTAssertTrue(rig.completed.isEmpty)
        XCTAssertTrue(rig.manual.isEmpty)
        rig.secure = false
        rig.send(try key(11)); rig.send(try key(49))
        await flush(); await flush()
        XCTAssertEqual(rig.completed.last?.text, "b")
    }

    func testSingleDroppedAcknowledgementRecoversWithoutDisablingInterception() async throws {
        let active = try layouts()
        let recovered = expectation(description: "transient failure recovers")
        var posted: [Signature] = []
        let monitor = KeyboardMonitor(postEvent: { posted.append(Signature($0)) }, currentSourceID: { active[0].id }, currentPID: { 123 }, secureInputEnabled: { false })
        monitor.layouts = active; monitor.enabled = true
        monitor.onFault = { XCTFail("one lost replay must not disable interception") }
        monitor.onRecovered = { recovered.fulfill() }
        XCTAssertTrue(monitor.beginGate(revision: monitor.revision))
        let events = try [key(0), key(0, down: false), key(11), key(11, down: false)]
        for event in events { XCTAssertNil(monitor.handleTapEvent(event.type, event)) }
        monitor.endGate()
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(posted, events.map(Signature.init))
        XCTAssertFalse(monitor.faulted)
        XCTAssertTrue(monitor.enabled)
        XCTAssertFalse(monitor.hasPendingInput)
    }

    func testRepeatedFailuresWithinTheWindowDisableInterception() async throws {
        let active = try layouts()
        let monitor = KeyboardMonitor(postEvent: { _ in }, currentSourceID: { active[0].id }, currentPID: { 123 }, secureInputEnabled: { false })
        monitor.layouts = active; monitor.enabled = true
        var faults = 0, recoveries = 0
        monitor.onFault = { faults += 1 }
        monitor.onRecovered = { recoveries += 1 }
        let disabled = try key(0)
        for _ in 0..<3 {
            // Only a disable that interrupts captured input is a failure.
            XCTAssertTrue(monitor.beginGate(revision: monitor.revision))
            _ = monitor.handleTapEvent(.tapDisabledByTimeout, disabled); await flush()
        }
        XCTAssertEqual(recoveries, 2)
        XCTAssertEqual(faults, 1)
        XCTAssertTrue(monitor.faulted)
        XCTAssertFalse(monitor.enabled)
    }

    func testStalledMainQueueCannotKeepInputCaptured() async throws {
        let active = try layouts()
        var now: UInt64 = 5_000_000_000
        var posted: [Signature] = [], forwarded: [Signature] = []
        let monitor = KeyboardMonitor(postEvent: { posted.append(Signature($0)) }, currentSourceID: { active[0].id }, currentPID: { 123 },
                                      secureInputEnabled: { false }, captureTimeout: 0.5, clock: { now })
        monitor.layouts = active; monitor.enabled = true
        let recovered = expectation(description: "watchdog reports to main")
        monitor.onRecovered = { recovered.fulfill() }
        XCTAssertTrue(monitor.beginGate(revision: monitor.revision))
        let held = try [key(0), key(0, down: false)]
        for event in held { XCTAssertNil(monitor.handleTapEvent(event.type, event, postAtTap: { forwarded.append(Signature($0)) })) }
        XCTAssertTrue(forwarded.isEmpty, "input is held while the gate makes progress")
        // Main never ends the gate. The next physical event arrives after the timeout.
        now += 600_000_000
        let next = try key(11)
        XCTAssertNil(monitor.handleTapEvent(next.type, next, postAtTap: { forwarded.append(Signature($0)) }))
        XCTAssertEqual(forwarded, (held + [next]).map(Signature.init), "held input is released first, in order, without main")
        XCTAssertTrue(posted.isEmpty)
        XCTAssertFalse(monitor.hasPendingInput)
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertFalse(monitor.faulted)
        XCTAssertTrue(monitor.enabled)
        let after = try key(11, down: false)
        XCTAssertNotNil(monitor.handleTapEvent(after.type, after, postAtTap: { forwarded.append(Signature($0)) }))
    }

    func testStaleEndGateDoesNotReleaseANewerGate() async throws {
        let active = try layouts()
        var now: UInt64 = 5_000_000_000
        let monitor = KeyboardMonitor(postEvent: { _ in }, currentSourceID: { active[0].id }, currentPID: { 123 },
                                      secureInputEnabled: { false }, captureTimeout: 0.5, clock: { now })
        monitor.layouts = active; monitor.enabled = true
        let first = monitor.revision
        XCTAssertTrue(monitor.beginGate(revision: first))
        now += 600_000_000
        let stray = try key(0)
        _ = monitor.handleTapEvent(stray.type, stray, postAtTap: { _ in })
        await flush()
        let second = monitor.revision
        XCTAssertTrue(monitor.beginGate(revision: second))
        monitor.endGate(revision: first) // the stalled worker finishes late
        XCTAssertTrue(monitor.hasPendingInput, "the newer gate must stay closed")
        let typed = try key(11)
        XCTAssertNil(monitor.handleTapEvent(typed.type, typed))
        monitor.endGate(revision: second)
    }

    func testCapsLockWithShiftReplaysTheLayoutsCapital() async throws {
        let active = try layouts(), ru = active[1]
        var posted: [CGEvent] = [], forwarded: [CGEvent] = []
        let monitor = KeyboardMonitor(postEvent: { posted.append($0) }, currentSourceID: { ru.id },
            currentPID: { 123 }, secureInputEnabled: { false })
        monitor.layouts = active; monitor.enabled = true; monitor.syncSource(ru.id)
        XCTAssertTrue(monitor.beginGate(revision: monitor.revision))
        let flags: CGEventFlags = [.maskShift, .maskAlphaShift]
        let down = try key(17, flags: flags), up = try key(17, flags: flags, down: false)
        XCTAssertNil(monitor.handleTapEvent(.keyDown, down))
        monitor.endGate()
        XCTAssertNil(monitor.handleTapEvent(.keyUp, up))
        XCTAssertNil(monitor.handleTapEvent(.keyDown, posted[0], postAtTap: { forwarded.append($0) }))
        XCTAssertEqual(forwarded.count, 2)
        for event in forwarded {
            var count = 0, units = [UniChar](repeating: 0, count: 16)
            event.keyboardGetUnicodeString(maxStringLength: 16, actualStringLength: &count, unicodeString: &units)
            XCTAssertEqual(Array(units.prefix(count)), [0x0415]) // RU Е, not е
        }
        await flush(); await flush()
    }

    func testTapDisabledWithNothingCapturedOnlyStartsANewWord() async throws {
        let rig = Rig(layouts: try layouts())
        var faults = 0, recoveries = 0
        rig.monitor.onFault = { faults += 1 }
        rig.monitor.onRecovered = { recoveries += 1 }
        rig.send(try key(0)); await flush()
        for _ in 0..<3 { _ = rig.monitor.handleTapEvent(.tapDisabledByTimeout, try key(0)); await flush() }
        XCTAssertEqual(faults, 0)
        XCTAssertEqual(recoveries, 0)
        XCTAssertFalse(rig.monitor.faulted)
        XCTAssertTrue(rig.monitor.enabled)
        rig.send(try key(11)); rig.send(try key(49)); await flush(); await flush()
        XCTAssertEqual(rig.completed.last?.text, "b", "keys typed while the tap was off are not part of the word")
    }

    func testFaultLiftsAfterAQuietWindowThatGrowsWithRepeatedFaults() async throws {
        let active = try layouts()
        var now: UInt64 = 5_000_000_000
        let monitor = KeyboardMonitor(postEvent: { _ in }, currentSourceID: { active[0].id }, currentPID: { 123 },
                                      secureInputEnabled: { false }, clock: { now })
        monitor.layouts = active; monitor.enabled = true
        let disabled = try key(0)
        func fault() async {
            for _ in 0..<3 {
                XCTAssertTrue(monitor.beginGate(revision: monitor.revision))
                _ = monitor.handleTapEvent(.tapDisabledByTimeout, disabled); await flush()
            }
            XCTAssertTrue(monitor.faulted)
            XCTAssertFalse(monitor.enabled)
        }
        await fault()
        XCTAssertFalse(monitor.resumeAfterQuietWindow())
        now += 59_000_000_000
        XCTAssertFalse(monitor.resumeAfterQuietWindow())
        now += 1_000_000_000
        XCTAssertTrue(monitor.resumeAfterQuietWindow())
        XCTAssertFalse(monitor.faulted)
        XCTAssertFalse(monitor.resumeAfterQuietWindow())
        monitor.enabled = true
        XCTAssertTrue(monitor.beginGate(revision: monitor.revision))
        monitor.endGate()
        // Another fault soon after waits twice as long.
        await fault()
        now += 60_000_000_000
        XCTAssertFalse(monitor.resumeAfterQuietWindow())
        now += 60_000_000_000
        XCTAssertTrue(monitor.resumeAfterQuietWindow())
    }

    func testOneStalledMainQueueCountsAsOneFailure() async throws {
        let active = try layouts()
        var now: UInt64 = 5_000_000_000
        let monitor = KeyboardMonitor(postEvent: { _ in }, currentSourceID: { active[0].id }, currentPID: { 123 },
                                      secureInputEnabled: { false }, captureTimeout: 0.5, clock: { now })
        monitor.layouts = active; monitor.enabled = true
        var faults = 0, recoveries = 0
        monitor.onFault = { faults += 1 }
        monitor.onRecovered = { recoveries += 1 }
        // The test holds main: words keep arriving and every Space is released by the tap.
        for _ in 0..<3 {
            XCTAssertNotNil(monitor.handleTapEvent(.keyDown, try key(49), postAtTap: { _ in }))
            XCTAssertNil(monitor.handleTapEvent(.keyDown, try key(0), postAtTap: { _ in }))
            now += 600_000_000
            XCTAssertNil(monitor.handleTapEvent(.keyDown, try key(11), postAtTap: { _ in }))
        }
        await flush()
        XCTAssertEqual(faults, 0)
        XCTAssertEqual(recoveries, 1)
        XCTAssertFalse(monitor.faulted)
        XCTAssertTrue(monitor.enabled)
    }

    func testReleasedBoundaryDoesNotOpenAGateWhenMainCatchesUp() async throws {
        let active = try layouts()
        var now: UInt64 = 5_000_000_000
        let monitor = KeyboardMonitor(postEvent: { _ in }, currentSourceID: { active[0].id }, currentPID: { 123 },
                                      secureInputEnabled: { false }, captureTimeout: 0.5, clock: { now })
        monitor.layouts = active; monitor.enabled = true
        var gates: [Bool] = []
        monitor.onToken = { [unowned monitor] in gates.append(monitor.beginGate(revision: $0.revision)) }
        for event in [try key(0), try key(0, down: false), try key(49)] {
            _ = monitor.handleTapEvent(event.type, event, postAtTap: { _ in })
        }
        XCTAssertNil(monitor.handleTapEvent(.keyDown, try key(11), postAtTap: { _ in }))
        now += 600_000_000
        XCTAssertNil(monitor.handleTapEvent(.keyDown, try key(8), postAtTap: { _ in }), "the stalled boundary is released")
        await flush()
        XCTAssertEqual(gates, [false], "keys after this Space already reached the application")
        XCTAssertFalse(monitor.hasPendingInput)
    }

    func testAutorepeatQueuedDuringAnEditIsReleasedAfterItsRepeat() async throws {
        let rig = Rig(layouts: try layouts())
        let down = try key(17), repeated = try key(17), up = try key(17, down: false)
        repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        rig.send(down); await flush()
        XCTAssertTrue(rig.monitor.beginGate(revision: rig.monitor.revision))
        rig.send(repeated); rig.send(up)
        rig.monitor.endGate()
        for _ in 0..<4 { await flush() }
        XCTAssertEqual(rig.forwarded.map(\.type), [CGEventType.keyDown, .keyDown, .keyUp].map(\.rawValue),
                       "a key released before its queued repeat would stay pressed")
        XCTAssertFalse(rig.monitor.hasPendingInput)
        XCTAssertFalse(rig.monitor.faulted)
    }

    private func scroll(momentum: Int64 = 0) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 12, wheel3: 0))
        event.flags = .maskShift
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return event
    }

    func testShiftScrollIsAChordAndScrollingIsNeverTypedOrHeld() async throws {
        XCTAssertNotEqual(KeyboardMonitor.tapEvents & (1 << CGEventType.scrollWheel.rawValue), 0)
        let rig = Rig(layouts: try layouts())
        for event in [try shift(true), try scroll(), try shift(false), try key(11), try key(49)] { rig.send(event) }
        await flush(); await flush()
        XCTAssertTrue(rig.manual.isEmpty, "Shift+scroll scrolls horizontally; it is not a Shift tap")
        XCTAssertEqual(rig.completed.last?.text, "b")
        XCTAssertEqual(rig.forwarded.count, 5)
        // Momentum after a flick is not the user's action: a Shift tap during it still counts.
        let coasting = Rig(layouts: try layouts())
        for event in [try shift(true), try scroll(momentum: 2), try shift(false)] { coasting.send(event) }
        await flush(); await flush()
        XCTAssertEqual(coasting.manual.count, 1)
        // Scrolling during an edit is neither held nor cancels it.
        let gated = Rig(layouts: try layouts())
        XCTAssertTrue(gated.monitor.beginGate(revision: gated.monitor.revision))
        let revision = gated.monitor.revision
        let event = try scroll()
        XCTAssertNotNil(gated.monitor.handleTapEvent(event.type, event))
        XCTAssertEqual(gated.monitor.revision, revision)
        gated.monitor.endGate()
    }

    private func type(_ rig: Rig, _ events: [CGEvent]) async {
        // Flushed one by one: no key waits behind a boundary reservation.
        for event in events { rig.send(event); await flush(); await flush() }
    }

    func testBackspaceOverTheSpaceContinuesTheWord() async throws {
        let rig = Rig(layouts: try layouts())
        await type(rig, try [17, 4, 49, 51, 14, 49].map { try key($0) })
        XCTAssertEqual(rig.completed.map(\.text), ["th", "the"])
        XCTAssertEqual(rig.completed.last?.physicalKeys?.count, 3)
        // Shift then converts the whole word, not only what was typed after Backspace.
        let shifted = Rig(layouts: try layouts())
        await type(shifted, try [5, 4, 49, 51, 11].map { try key($0) } + [try shift(true), try shift(false)])
        XCTAssertEqual((shifted.manual.last ?? nil)?.text, "ghb")
    }

    func testBackspaceKeepsSeparateWordsSeparate() async throws {
        // One of two spaces erased: the next letters are still a new word.
        let spaces = Rig(layouts: try layouts())
        await type(spaces, try [17, 4, 49, 49, 51, 14, 49].map { try key($0) })
        XCTAssertEqual(spaces.completed.map(\.text), ["th", "e"])
        // Option+Backspace erased the word itself.
        let option = Rig(layouts: try layouts())
        await type(option, try [key(17), key(4), key(49), key(51, flags: .maskAlternate), key(51), key(14), key(49)])
        XCTAssertEqual(option.completed.map(\.text), ["th", "e"])
        // A correction replaced the word: the field no longer holds what was typed.
        let corrected = Rig(layouts: try layouts())
        corrected.monitor.onToken = { [unowned corrected] in corrected.completed.append($0); corrected.monitor.reset() }
        await type(corrected, try [17, 4, 49, 51, 14, 49].map { try key($0) })
        XCTAssertEqual(corrected.completed.map(\.text), ["th", "e"])
    }

    func testShiftAfterACorrectionAsksForTheReceiptNotTheTypedWord() async throws {
        // A spelling fix keeps the layout, so only the correction's reset forgets the typed word.
        let corrected = Rig(layouts: try layouts())
        corrected.monitor.onToken = { [unowned corrected] in corrected.completed.append($0); corrected.monitor.reset() }
        await type(corrected, try [5, 4, 49].map { try key($0) } + [try shift(true), try shift(false)])
        XCTAssertEqual(corrected.manual.count, 1)
        XCTAssertNil(try XCTUnwrap(corrected.manual.first))
        let untouched = Rig(layouts: try layouts())
        await type(untouched, try [5, 4, 49].map { try key($0) } + [try shift(true), try shift(false)])
        XCTAssertEqual((untouched.manual.first ?? nil)?.text, "gh")
    }
}
