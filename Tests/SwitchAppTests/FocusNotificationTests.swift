import XCTest
import Cocoa
@testable import SwitchCore
@testable import SwitchApp

/// An application that comes to the front announces its focused element 60–300 ms after the
/// activation notification (TextEdit 45–85 ms, the ChatGPT app up to 310 ms with Stage Manager).
/// A word begun before that announcement used to be dropped with it: its first letters were lost
/// and the word stayed in the wrong layout. The word is kept; only edits that cannot verify the
/// field are refused for it.
@MainActor
final class FocusNotificationTests: XCTestCase {
    private final class Rig {
        let monitor: KeyboardMonitor
        var completed: [KeyboardMonitor.Token] = []
        var progress: [KeyboardMonitor.Token] = []
        var cancellations = 0
        init(layouts: [KeyboardLayout]) {
            var forwarding: ((CGEvent) -> Void)?
            monitor = KeyboardMonitor(postEvent: { forwarding?($0) }, currentSourceID: { layouts[0].id },
                                      currentPID: { 123 }, secureInputEnabled: { false })
            forwarding = { [weak self] event in self?.send(event) }
            monitor.layouts = layouts; monitor.enabled = true
            monitor.onToken = { [weak self] in self?.completed.append($0) }
            monitor.onProgress = { [weak self] in self?.progress.append($0) }
            monitor.onCancelAnalysis = { [weak self] in self?.cancellations += 1 }
        }
        func send(_ event: CGEvent) { _ = monitor.handleTapEvent(event.type, event) }
    }

    private func layouts() throws -> [KeyboardLayout] {
        let installed = KeyboardLayout.installed(enabledOnly: false)
        return try ["ABC", "Russian"].map { suffix in
            try XCTUnwrap(installed.first { $0.id == "com.apple.keylayout." + suffix })
        }
    }
    private var tick: UInt64 = 1_000_000_000
    private func key(_ code: UInt16, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
        event.flags = flags; event.timestamp = tick; tick += 10_000_000
        return event
    }
    private func flush() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    private let privet: [UInt16] = [5, 4, 11, 2, 17, 45] // g h b d t n

    func testFocusNotificationAfterTheFirstKeyKeepsTheWholeWord() async throws {
        let rig = Rig(layouts: try layouts())
        rig.send(try key(privet[0])); await flush()
        let revision = rig.monitor.revision
        rig.monitor.focusChanged()
        XCTAssertNotEqual(rig.monitor.revision, revision, "work in flight for the old focus is invalidated")
        for code in privet.dropFirst() { rig.send(try key(code)) }
        rig.send(try key(49)); await flush(); await flush()
        XCTAssertEqual(rig.completed.map(\.text), ["ghbdtn"])
        XCTAssertEqual(rig.completed.first?.focusMoved, true, "the word is marked: a blind edit cannot verify where its keys went")
    }

    func testTheNextWordIsNotMarked() async throws {
        let rig = Rig(layouts: try layouts())
        rig.send(try key(privet[0])); await flush()
        rig.monitor.focusChanged()
        for code in privet.dropFirst() { rig.send(try key(code)) }
        rig.send(try key(49)); await flush()
        for code in privet { rig.send(try key(code)) }
        rig.send(try key(49)); await flush(); await flush()
        XCTAssertEqual(rig.completed.map(\.text), ["ghbdtn", "ghbdtn"])
        XCTAssertEqual(rig.completed.map(\.focusMoved), [true, false])
    }

    func testFocusNotificationBetweenWordsForgetsTheFinishedWord() async throws {
        let rig = Rig(layouts: try layouts())
        for code in privet { rig.send(try key(code)) }
        rig.send(try key(49)); await flush()
        XCTAssertEqual(rig.completed.map(\.text), ["ghbdtn"])
        rig.monitor.focusChanged()
        XCTAssertEqual(rig.monitor.pendingCount, 0)
        // Backspace after a finished word reopens it only while the word is still at the caret.
        let before = rig.progress.count
        rig.send(try key(51)); await flush(); await flush()
        XCTAssertEqual(rig.progress.count, before, "the finished word is gone from the caret")
    }

    func testResetClearsTheMark() async throws {
        let rig = Rig(layouts: try layouts())
        rig.send(try key(privet[0])); await flush()
        rig.monitor.focusChanged()
        rig.monitor.reset()
        for code in privet { rig.send(try key(code)) }
        rig.send(try key(49)); await flush(); await flush()
        XCTAssertEqual(rig.completed.map(\.focusMoved), [false])
    }

    func testBlindKeystrokeEditIsRefusedForAMarkedWord() throws {
        let (abc, ru) = try (layouts()[0], layouts()[1])
        var token = KeyboardMonitor.Token(text: "ghbdtn", suffix: " ", sourceID: abc.id, pid: 1, revision: 0)
        let suggestion = Suggestion(original: "ghbdtn", replacement: "привет", target: ru, score: 1)
        XCTAssertNotNil(AppModel.keystrokeEdit(for: token, suggestion: suggestion, source: abc, blind: false))
        token.focusMoved = true
        XCTAssertNil(AppModel.keystrokeEdit(for: token, suggestion: suggestion, source: abc, blind: false))
        XCTAssertNil(AppModel.keystrokeEdit(for: token, suggestion: suggestion, source: abc, blind: true))
    }
}
