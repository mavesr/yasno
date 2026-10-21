import XCTest
@testable import SwitchCore
@testable import SwitchApp

final class KeystrokeCorrectionTests: XCTestCase {
    private func layouts() throws -> (abc: KeyboardLayout, ru: KeyboardLayout) {
        let installed = KeyboardLayout.installed(enabledOnly: false)
        let abc = try XCTUnwrap(installed.first { $0.id == "com.apple.keylayout.ABC" })
        let ru = try XCTUnwrap(installed.first { $0.id == "com.apple.keylayout.Russian" })
        return (abc, ru)
    }

    private func edit(_ typed: String, _ replacement: String, target: KeyboardLayout, source: KeyboardLayout,
                      blind: Bool) -> KeystrokeEdit? {
        let token = KeyboardMonitor.Token(text: typed, suffix: " ", sourceID: source.id, pid: 1, revision: 0)
        let suggestion = Suggestion(original: typed, replacement: replacement, target: target, score: 1)
        return AppModel.keystrokeEdit(for: token, suggestion: suggestion, source: source, blind: blind)
    }

    func testLayoutRepairIsTypedInBothBuilds() throws {
        let (abc, ru) = try layouts()
        for blind in [false, true] {
            XCTAssertEqual(edit("ghbdtn", "привет", target: ru, source: abc, blind: blind),
                           KeystrokeEdit(deletions: 7, insertion: "привет "))
        }
    }

    func testSpellingFixIsLeftToTheApplicationsOwnAutocorrect() throws {
        // The field may already read "until " or "occurred ": erasing by count would mangle it.
        let (abc, _) = try layouts()
        for blind in [false, true] {
            XCTAssertNil(edit("untill", "until", target: abc, source: abc, blind: blind))
            XCTAssertNil(edit("occured", "occurred", target: abc, source: abc, blind: blind))
        }
    }

    func testLoneLetterIsConvertedOnlyWhereTheFieldIsKnown() throws {
        // In the App Store build R then Space may be a canvas shortcut: Backspace would delete the selection.
        let (abc, ru) = try layouts()
        XCTAssertNil(edit("r", "к", target: ru, source: abc, blind: true))
        XCTAssertEqual(edit("r", "к", target: ru, source: abc, blind: false), KeystrokeEdit(deletions: 2, insertion: "к "))
    }
}
