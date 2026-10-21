import XCTest
import SwitchCore
@testable import SwitchApp

final class ReplacementTransactionTests: XCTestCase {
    private final class Editor {
        var value: String
        var selection: CFRange
        var focused = true
        var supported = true
        var valid = true
        var acceptsSelection = true
        var confirmsSelection = true
        var acceptsInsertion = true
        var confirmsInsertion = true
        var clock: TimeInterval = 0
        var selectionCalls = 0
        var insertions = 0
        var commits = 0
        var onSelect: (() -> Void)?
        var onInsert: (() -> Void)?
        init(_ value: String, caret: CFRange) { self.value = value; selection = caret }
        var environment: ReplacementTransaction.Environment {
            .init(selection: { self.selection },
                  text: { TextSafety.substring(self.value, location: $0.location, length: $0.length) },
                  focused: { self.focused }, canSelect: { self.supported }, select: { range in
                    self.selectionCalls += 1
                    guard self.acceptsSelection else { return false }
                    if self.confirmsSelection { self.selection = range }
                    self.onSelect?()
                    return true
                  }, insert: { text in
                    self.insertions += 1
                    guard self.acceptsInsertion else { return false }
                    if self.confirmsInsertion, let range = Range(NSRange(location: self.selection.location, length: self.selection.length), in: self.value) {
                        self.value.replaceSubrange(range, with: text)
                        self.selection = CFRange(location: self.selection.location + text.utf16.count, length: 0)
                    }
                    self.onInsert?()
                    return true
                  }, now: { self.clock }, pause: { self.clock += 0.01 }, timeout: 0.05)
        }
        func run(_ original: String = "ghbdtn", replacement: String = "привет", range: CFRange = CFRange(location: 0, length: 6), caret: CFRange? = nil, commitAllowed: Bool = true) -> ReplacementTransaction.Result {
            ReplacementTransaction.run(range: range, expected: original, replacement: replacement, caret: caret ?? selection,
                stillValid: { self.valid }, commit: { self.commits += 1; return commitAllowed }, environment: environment)
        }
    }

    func testExactReplacementPreservesPrefixSuffixAndUTF16CaretAcrossLengthChanges() {
        let prefixes = ["", "hello ", "👩‍💻 ", "е\u{301} ", "🇺🇦\n", "👨‍👩‍👧‍👦 "]
        let replacements = ["привет", "hello", "пожалуйста", "я", "ещё", "🙂", "über"]
        for prefix in prefixes {
            for replacement in replacements {
                for spaces in 0...8 {
                    for selected in [false, true] {
                        let suffix = String(repeating: " ", count: spaces)
                        let range = CFRange(location: prefix.utf16.count, length: 6)
                        let caret = selected ? range : CFRange(location: prefix.utf16.count + 6 + spaces, length: 0)
                        let editor = Editor(prefix + "ghbdtn" + suffix, caret: caret)
                        XCTAssertEqual(editor.run(replacement: replacement, range: range), .success)
                        XCTAssertEqual(editor.value, prefix + replacement + suffix)
                        XCTAssertEqual(editor.selection.location, prefix.utf16.count + replacement.utf16.count + (selected ? 0 : spaces))
                        XCTAssertEqual(editor.selection.length, 0)
                        XCTAssertEqual(editor.insertions, 1)
                        XCTAssertEqual(editor.commits, 1)
                    }
                }
            }
        }
    }

    func testStaleFocusTextSelectionAndRevisionNeverInsert() {
        for failure in 0..<6 {
            let editor = Editor("ghbdtn ", caret: CFRange(location: 7, length: 0))
            switch failure {
            case 0: editor.focused = false
            case 1: editor.valid = false
            case 2: editor.value = "another "
            case 3: editor.onSelect = { editor.valid = false }
            case 4: editor.onSelect = { editor.focused = false }
            default: editor.onSelect = { editor.value = "changed " }
            }
            XCTAssertEqual(editor.run(), .stale, "failure \(failure)")
            XCTAssertEqual(editor.insertions, 0)
            XCTAssertEqual(editor.commits, 0)
        }
        let editor = Editor("ghbdtn ", caret: CFRange(location: 7, length: 0))
        XCTAssertEqual(editor.run(caret: CFRange(location: 6, length: 0)), .stale)
        XCTAssertEqual(editor.selectionCalls, 0)
    }

    func testUnsupportedAndLyingSelectionSettersFailWithoutPosting() {
        let editor = Editor("ghbdtn ", caret: CFRange(location: 7, length: 0))
        editor.supported = false
        XCTAssertEqual(editor.run(), .unsupported)
        XCTAssertEqual(editor.selectionCalls, 0)
        editor.supported = true; editor.acceptsSelection = false
        XCTAssertEqual(editor.run(), .stale)
        editor.acceptsSelection = true; editor.confirmsSelection = false
        XCTAssertEqual(editor.run(), .stale)
        XCTAssertEqual(editor.insertions, 0)
        XCTAssertLessThan(editor.clock, 0.08)
    }

    func testDeniedCommitOrUnacknowledgedInsertionNeverReportSuccess() {
        for failure in 0..<4 {
            let editor = Editor("ghbdtn ", caret: CFRange(location: 7, length: 0))
            if failure == 1 { editor.acceptsInsertion = false }
            if failure == 2 { editor.confirmsInsertion = false }
            if failure == 3 { editor.onInsert = { editor.focused = false } }
            XCTAssertEqual(editor.run(commitAllowed: failure != 0), .failed)
            XCTAssertEqual(editor.commits, 1)
            XCTAssertEqual(editor.insertions, failure == 0 ? 0 : 1)
            if failure != 3 { XCTAssertEqual(editor.value, "ghbdtn "); XCTAssertEqual(editor.selection.location, 7) }
        }
    }

    func testPrefixReplacementIsNotConfirmedByTheUnchangedWord() {
        // The untouched word already starts with its replacement.
        for (text, original, replacement, caret) in [("helloo ", "helloo", "hello", 7), ("helloo", "helloo", "hello", 6),
                                                      ("приветт ", "приветт", "привет", 8), ("untill ", "untill", "until", 7)] {
            let editor = Editor(text, caret: CFRange(location: caret, length: 0))
            editor.confirmsInsertion = false
            XCTAssertEqual(editor.run(original, replacement: replacement, range: CFRange(location: 0, length: original.utf16.count)),
                           .failed, text)
            XCTAssertEqual(editor.value, text)
            XCTAssertEqual(editor.selection.location, caret)
            XCTAssertEqual(editor.selection.length, 0)
        }
        for (text, original, replacement, caret) in [("helloo ", "helloo", "hello", 7), ("helloo", "helloo", "hello", 6)] {
            let editor = Editor(text, caret: CFRange(location: caret, length: 0))
            XCTAssertEqual(editor.run(original, replacement: replacement, range: CFRange(location: 0, length: original.utf16.count)), .success)
            XCTAssertEqual(editor.value, replacement + text.dropFirst(original.count))
            XCTAssertEqual(editor.selection.location, caret - 1)
        }
    }

    func testDelayedPrefixInsertionIsAwaited() {
        let editor = Editor("helloo ", caret: CFRange(location: 7, length: 0))
        editor.confirmsInsertion = false
        var pending = false
        editor.onInsert = { pending = true }
        var environment = editor.environment
        environment.pause = {
            editor.clock += 0.01
            if pending, editor.clock >= 0.02 {
                editor.value = "hello "; editor.selection = CFRange(location: 5, length: 0); pending = false
            }
        }
        let result = ReplacementTransaction.run(range: CFRange(location: 0, length: 6), expected: "helloo",
            replacement: "hello", caret: CFRange(location: 7, length: 0), stillValid: { true }, commit: { true }, environment: environment)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(editor.value, "hello ")
        XCTAssertEqual(editor.selection.location, 6)
    }

    func testIdenticalTextDoesNotPostAndInvalidCoordinatesAreRejected() {
        let editor = Editor("ghbdtn", caret: CFRange(location: 6, length: 0))
        XCTAssertEqual(editor.run(replacement: "ghbdtn"), .success)
        XCTAssertEqual(editor.insertions, 0); XCTAssertEqual(editor.selectionCalls, 0)
        for range in [CFRange(location: -1, length: 6), CFRange(location: 0, length: 5), CFRange(location: Int.max, length: 6)] {
            XCTAssertEqual(editor.run(range: range), .stale)
        }
    }

    func testAnOperationDeadlineIsSharedAcrossAcknowledgementPhases() {
        let editor = Editor("ghbdtn ", caret: CFRange(location: 7, length: 0))
        editor.confirmsInsertion = false
        editor.onSelect = { if editor.selectionCalls == 1 { editor.clock += 0.04 } }
        var environment = editor.environment
        environment.timeout = 0.25
        environment.deadline = 0.06
        let result = ReplacementTransaction.run(range: CFRange(location: 0, length: 6), expected: "ghbdtn",
            replacement: "привет", caret: editor.selection, stillValid: { true }, commit: { true }, environment: environment)
        XCTAssertEqual(result, .failed)
        XCTAssertLessThanOrEqual(editor.clock, 0.08, "Insertion cannot get a new full timeout after selection consumed the budget")
        XCTAssertEqual(editor.value, "ghbdtn ")
        XCTAssertEqual(editor.selection.location, 7)
    }

    func testExpiredBudgetCannotCommitAfterASlowSelectionSetter() {
        let editor = Editor("ghbdtn ", caret: CFRange(location: 7, length: 0))
        editor.onSelect = { editor.clock += 0.1 }
        var environment = editor.environment; environment.deadline = 0.05
        var committed = false
        let result = ReplacementTransaction.run(range: CFRange(location: 0, length: 6), expected: "ghbdtn",
            replacement: "привет", caret: editor.selection, stillValid: { true }, commit: { committed = true; return true }, environment: environment)
        XCTAssertEqual(result, .stale); XCTAssertFalse(committed); XCTAssertEqual(editor.insertions, 0)
        XCTAssertEqual(editor.value, "ghbdtn ")
    }
}
