import XCTest
@testable import SwitchCore

final class KeyStrokeLookupTests: XCTestCase {
    func testStrokeTypesTheCharacterInItsLayout() throws {
        let all = KeyboardLayout.installed(enabledOnly: false)
        let abc = try XCTUnwrap(all.first { $0.id == "com.apple.keylayout.ABC" })
        let ru = try XCTUnwrap(all.first { $0.id == "com.apple.keylayout.Russian" })
        XCTAssertEqual(abc.stroke(for: "G"), KeyboardLayout.KeyStroke(key: 5, shift: true))
        XCTAssertEqual(ru.stroke(for: "п"), KeyboardLayout.KeyStroke(key: 5))
        XCTAssertEqual(ru.stroke(for: " "), KeyboardLayout.KeyStroke(key: 49))
        for character in "Привет, мир " {
            let stroke = try XCTUnwrap(ru.stroke(for: character))
            XCTAssertEqual(ru.character(key: stroke.key, shift: stroke.shift), String(character))
        }
    }
}
