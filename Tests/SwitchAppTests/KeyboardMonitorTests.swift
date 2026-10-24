import XCTest
import Cocoa
import SwitchCore
@testable import SwitchApp

final class KeyboardMonitorTests: XCTestCase {
    private struct Record: Equatable {
        let type: UInt32
        let key: Int64
        init(_ event: CGEvent) {
            type = event.type.rawValue
            key = event.getIntegerValueField(.keyboardEventKeycode)
        }
    }

    /// Re-enters the real tap/replay path, but never posts anything to macOS or a user app.
    private final class Harness {
        let lock = NSLock()
        let finished: XCTestExpectation
        let expected: [Record]
        var delivered: [Record] = []
        var lookups = 0
        var monitor: KeyboardMonitor!

        init(events: [CGEvent], abc: KeyboardLayout) {
            expected = events.map(Record.init)
            finished = XCTestExpectation(description: "all input delivered in order")
            monitor = KeyboardMonitor(postEvent: { [weak self] event in self?.send(event) },
                currentSourceID: { [weak self] in
                    XCTAssertTrue(Thread.isMainThread)
                    self?.lookups += 1
                    return abc.id
                }, currentPID: { 123 }, secureInputEnabled: { false })
            monitor.layouts = [abc]
            monitor.enabled = true
        }

        func send(_ event: CGEvent) {
            guard monitor.handleTapEvent(event.type, event) != nil else { return }
            lock.lock()
            delivered.append(Record(event))
            let complete = delivered.count == expected.count
            lock.unlock()
            if complete { finished.fulfill() }
        }

        func sendWhileMainIsBlocked(_ events: [CGEvent]) {
            let callbacksFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                for event in events { self.send(event) }
                callbacksFinished.signal()
            }
            // Simulate a long AX/UI call. The event tap must not wait for this thread.
            Thread.sleep(forTimeInterval: 0.35)
            XCTAssertEqual(callbacksFinished.wait(timeout: .now()), .success)
            XCTAssertEqual(lookups, 0)
        }
    }

    private func abc() throws -> KeyboardLayout {
        try XCTUnwrap(KeyboardLayout.installed(enabledOnly: false).first { $0.id == "com.apple.keylayout.ABC" })
    }

    private func key(_ code: UInt16, down: Bool = true) throws -> CGEvent {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        source.userData = 0x54455354
        return try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down))
    }

    func testTapDoesNotWaitForTheMainThreadOrDropReservedInput() throws {
        let events = try [UInt16(6), 45, 49, 6, 45, 49, 45].flatMap { code in
            [try key(code), try key(code, down: false)]
        }
        let harness = Harness(events: events, abc: try abc())
        harness.sendWhileMainIsBlocked(events)
        wait(for: [harness.finished], timeout: 2)
        XCTAssertEqual(harness.delivered, harness.expected)
        XCTAssertFalse(harness.monitor.faulted)
    }

    func testConsecutiveReplayedSpacesCanEachReserveAnEdit() throws {
        let events = try [UInt16(0), 49, 11, 49, 8].flatMap { code in
            [try key(code), try key(code, down: false)]
        }
        let harness = Harness(events: events, abc: try abc())
        var edits = 0
        harness.monitor.onToken = { [weak harness] token in
            guard let harness else { return }
            XCTAssertTrue(harness.monitor.beginGate(revision: token.revision))
            edits += 1
            DispatchQueue.main.async { harness.monitor.endGate() }
        }
        harness.sendWhileMainIsBlocked(events)
        wait(for: [harness.finished], timeout: 2)
        XCTAssertEqual(edits, 2)
        XCTAssertEqual(harness.delivered, harness.expected)
        XCTAssertFalse(harness.monitor.faulted)
    }

    func testTabIsHeldUntilTheWordBeforeItIsEdited() throws {
        let events = try [UInt16(5), 4, 48, 7].flatMap { code in
            [try key(code), try key(code, down: false)]
        }
        let harness = Harness(events: events, abc: try abc())
        var words: [String] = []
        harness.monitor.onToken = { [weak harness] token in
            guard let harness else { return }
            XCTAssertTrue(harness.monitor.beginGate(revision: token.revision))
            words.append(token.text + token.suffix)
            harness.lock.lock()
            XCTAssertFalse(harness.delivered.contains { $0.key == 48 })
            harness.lock.unlock()
            DispatchQueue.main.async { harness.monitor.endGate() }
        }
        harness.sendWhileMainIsBlocked(events)
        wait(for: [harness.finished], timeout: 2)
        XCTAssertEqual(words, ["gh"])
        XCTAssertEqual(harness.delivered, harness.expected)
        XCTAssertFalse(harness.monitor.faulted)
    }

    func testReplayedTabIsHeldUntilTheWordBeforeItIsEdited() throws {
        // The Tab waits in the queue behind the first Space, so it comes back as a replay.
        let events = try [UInt16(0), 49, 5, 4, 48, 7].flatMap { code in
            [try key(code), try key(code, down: false)]
        }
        let harness = Harness(events: events, abc: try abc())
        var words: [String] = []
        harness.monitor.onToken = { [weak harness] token in
            guard let harness else { return }
            XCTAssertTrue(harness.monitor.beginGate(revision: token.revision))
            words.append(token.text + token.suffix)
            harness.lock.lock()
            XCTAssertFalse(harness.delivered.contains { $0.key == 48 }, "Tab reached the next field before \(token.text)")
            harness.lock.unlock()
            DispatchQueue.main.async { harness.monitor.endGate() }
        }
        harness.sendWhileMainIsBlocked(events)
        wait(for: [harness.finished], timeout: 2)
        XCTAssertEqual(words, ["a ", "gh"])
        XCTAssertEqual(harness.delivered, harness.expected)
        XCTAssertFalse(harness.monitor.faulted)
    }

    func testClickCancelsAReservedBoundaryWithoutDroppingFollowingKeys() throws {
        let click = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: .zero, mouseButton: .left))
        let events = [try key(5), try key(49), click, try key(6), try key(45)]
        let harness = Harness(events: events, abc: try abc())
        var attempts = 0
        harness.monitor.onToken = { [weak harness] token in
            guard let harness else { return }
            attempts += 1
            XCTAssertFalse(harness.monitor.beginGate(revision: token.revision))
        }
        harness.sendWhileMainIsBlocked(events)
        wait(for: [harness.finished], timeout: 2)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(harness.delivered, harness.expected)
        XCTAssertFalse(harness.monitor.faulted)
    }

    func testShiftAfterSpaceHoldsFollowingKeysUntilTheManualEditFinishes() throws {
        let down = try key(56), up = try key(56, down: false)
        down.type = .flagsChanged; up.type = .flagsChanged
        down.flags = .maskShift; up.flags = []
        down.timestamp = 1_000_000_000; up.timestamp = 1_070_000_000
        let events = [try key(5), try key(49), down, up, try key(45), try key(45, down: false)]
        let harness = Harness(events: events, abc: try abc())
        var manual = 0
        harness.monitor.onManual = { [weak harness] _ in
            guard let harness else { return }
            XCTAssertTrue(harness.monitor.beginGate(revision: harness.monitor.revision))
            manual += 1
            DispatchQueue.main.async { harness.monitor.endGate() }
        }
        harness.sendWhileMainIsBlocked(events)
        wait(for: [harness.finished], timeout: 2)
        XCTAssertEqual(manual, 1)
        XCTAssertEqual(harness.delivered, harness.expected)
        XCTAssertFalse(harness.monitor.faulted)
    }

    func testReleasingThePreviousSpaceDuringShiftDoesNotCancelTheTap() throws {
        let down = try key(56), up = try key(56, down: false)
        down.type = .flagsChanged; up.type = .flagsChanged
        down.flags = .maskShift; up.flags = []
        down.timestamp = 1_000_000_000; up.timestamp = 1_070_000_000
        let spaceUp = try key(49, down: false)
        spaceUp.flags = .maskShift
        let events = [try key(5), try key(5, down: false), try key(49), down, spaceUp, up, try key(45)]
        let harness = Harness(events: events, abc: try abc())
        var manual = 0
        harness.monitor.onManual = { token in
            XCTAssertEqual(token?.text, "g")
            XCTAssertEqual(token?.suffix, " ")
            manual += 1
        }
        harness.sendWhileMainIsBlocked(events)
        wait(for: [harness.finished], timeout: 2)
        XCTAssertEqual(manual, 1)
        // Space-up intentionally bypasses a queued Shift-down so AX cannot turn
        // Space into a held key. Downs/modifiers retain order and nothing is lost.
        XCTAssertEqual(harness.delivered, [events[0], events[1], events[2], events[4], events[3], events[5], events[6]].map(Record.init))
    }

    func testSingleLetterCorrectionsReserveAndReleaseFollowingInputInOrder() throws {
        let abc = try abc()
        let ru = try XCTUnwrap(KeyboardLayout.installed(enabledOnly: false).first {
            $0.id == "com.apple.keylayout.Russian"
        })
        let detector = Detector()
        let events = try [UInt16(6), 49, 11, 49, 3, 49, 0].flatMap { code in
            [try key(code), try key(code, down: false)]
        }
        let harness = Harness(events: events, abc: abc)
        let completed = expectation(description: "three one-letter words handled")
        var replacements: [String] = []
        harness.monitor.onToken = { [weak harness] token in
            guard let harness else { return }
            XCTAssertTrue(detector.maySuggest(token.text, source: abc, layouts: [abc, ru]))
            XCTAssertTrue(harness.monitor.beginGate(revision: token.revision))
            replacements.append(detector.suggest(token.text, source: abc, layouts: [abc, ru])?.replacement ?? "")
            DispatchQueue.main.async {
                harness.monitor.endGate()
                if replacements.count == 3 { completed.fulfill() }
            }
        }
        harness.sendWhileMainIsBlocked(events)
        wait(for: [completed, harness.finished], timeout: 3)
        XCTAssertEqual(replacements, ["я", "и", "а"])
        XCTAssertEqual(harness.delivered, harness.expected)
        XCTAssertFalse(harness.monitor.faulted)
    }

    func testMidWordHandoffKeepsTheWholeWordAndReplaysInTheNewLayout() throws {
        let abc = try abc()
        let ru = try XCTUnwrap(KeyboardLayout.installed(enabledOnly: false).first {
            $0.id == "com.apple.keylayout.Russian"
        })
        let events = try [UInt16(17), 45, 49].flatMap { code in
            [try key(code), try key(code, down: false)]
        }
        let harness = Harness(events: events, abc: abc)
        harness.monitor.layouts = [abc, ru]
        let completeWord = expectation(description: "whole corrected word reaches boundary")
        harness.monitor.onToken = { token in
            XCTAssertEqual(token.text, "привет")
            XCTAssertEqual(token.sourceID, ru.id)
            XCTAssertEqual(token.suffix, " ")
            XCTAssertTrue(token.liveConverted)
            completeWord.fulfill()
        }
        XCTAssertTrue(harness.monitor.beginGate(revision: harness.monitor.revision))
        harness.monitor.resumeAfterLiveCorrection(text: "прив", sourceID: ru.id, pid: 123)
        harness.sendWhileMainIsBlocked(events)
        harness.monitor.endGate()
        wait(for: [harness.finished, completeWord], timeout: 3)
        XCTAssertEqual(harness.delivered, harness.expected)
        XCTAssertFalse(harness.monitor.faulted)
    }
}
