import XCTest
@testable import SwitchCore

final class KeystrokeEditTests: XCTestCase {
    func testErasesOnlyTheTypedWordAndRetypesTheSuffix() {
        let edit = KeystrokeEdit(typed: "ghbdtn", replacement: "привет", suffix: " ")
        XCTAssertEqual(edit, KeystrokeEdit(deletions: 7, insertion: "привет "))
    }

    func testKeepsTheCommonPrefix() {
        XCTAssertEqual(KeystrokeEdit(typed: "/вумудщзук", replacement: "/developer", suffix: " "),
                       KeystrokeEdit(deletions: 10, insertion: "developer "))
        XCTAssertEqual(KeystrokeEdit(typed: "качгулся", replacement: "качнулся"),
                       KeystrokeEdit(deletions: 5, insertion: "нулся"))
    }

    func testCountsCharactersNotCodeUnits() {
        XCTAssertEqual(KeystrokeEdit(typed: "ёж", replacement: "ёлка", suffix: "  "),
                       KeystrokeEdit(deletions: 3, insertion: "лка  "))
    }

    func testNothingToDo() {
        XCTAssertNil(KeystrokeEdit(typed: "привет", replacement: "привет", suffix: " "))
        XCTAssertNil(KeystrokeEdit(typed: "", replacement: "x"))
    }
}

