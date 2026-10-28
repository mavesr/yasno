import XCTest
import SwitchCore
@testable import SwitchApp

/// Fixes from the 25 October audit (0.2.18).
final class Audit20261025Tests: XCTestCase {
    private func russian() throws -> KeyboardLayout {
        try XCTUnwrap(KeyboardLayout.installed(enabledOnly: false).first { $0.id == "com.apple.keylayout.Russian" })
    }

    // M-02: the layout is selected before anything is erased; a refusal leaves the word as typed.
    func testRemoteScreenSelectsTheLayoutBeforeErasingTheWord() throws {
        let ru = try russian()
        let edit = try XCTUnwrap(KeystrokeEdit(typed: "ghbdtn", replacement: "привет", suffix: " "))
        var steps: [String] = []
        let typed = AppModel.typeOnRemoteScreen(edit, in: ru,
            select: { steps.append("select"); return true }, erase: { steps.append("erase"); return true },
            pause: { steps.append("pause") }, type: { steps.append("type \($0.count)"); return true })
        XCTAssertTrue(typed)
        XCTAssertEqual(steps, ["select", "erase", "pause", "type 7"])
    }

    func testRemoteScreenRefusedLayoutLeavesTheWordAlone() throws {
        let ru = try russian()
        let edit = try XCTUnwrap(KeystrokeEdit(typed: "ghbdtn", replacement: "привет", suffix: " "))
        var erased = false
        let typed = AppModel.typeOnRemoteScreen(edit, in: ru,
            select: { false }, erase: { erased = true; return true }, pause: {}, type: { _ in XCTFail("typed after a refused layout"); return true })
        XCTAssertFalse(typed)
        XCTAssertFalse(erased, "the word must stay as typed when the layout cannot be selected")
    }

    func testRemoteScreenUntypeableReplacementChangesNothing() throws {
        let ru = try russian()
        // A Latin q is on no key of the Russian layout.
        let edit = try XCTUnwrap(KeystrokeEdit(typed: "ghbdtn", replacement: "приqет", suffix: ""))
        var touched = false
        let typed = AppModel.typeOnRemoteScreen(edit, in: ru,
            select: { touched = true; return true }, erase: { touched = true; return true }, pause: {}, type: { _ in touched = true; return true })
        XCTAssertFalse(typed)
        XCTAssertFalse(touched)
    }

    // P14: a replacement is posted in chunks of at most 16 UTF-16 units without splitting a character.
    func testUnicodeChunksKeepSurrogatePairsTogether() {
        let text = "123456789012345😀x" // 15 units, then a 2-unit emoji, then x
        let chunks = KeyboardMonitor.unicodeChunks(text)
        XCTAssertEqual(chunks.map(\.count), [15, 3])
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
        XCTAssertEqual(KeyboardMonitor.unicodeChunks("").count, 0)
        XCTAssertEqual(KeyboardMonitor.unicodeChunks("привет ").map(\.count), [7])
        XCTAssertEqual(KeyboardMonitor.unicodeChunks(String(repeating: "a", count: 33)).map(\.count), [16, 16, 1])
    }
}
