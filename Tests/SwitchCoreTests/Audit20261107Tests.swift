import XCTest
import CoreGraphics
import SwitchCore

/// Findings of the 2026-11-07 audit that were confirmed and fixed (docs/audit-2026-11-07.md).
final class Audit20261107Tests: XCTestCase {
    /// A key event posted by another program can carry more text than the 16 units read back.
    /// The release gets exactly those units: a count past the buffer would read beyond it.
    func testLongTextOfTheDownReachesTheReleaseCutToTheBuffer() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
        let up = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false))
        let text = Array(String(repeating: "абвгдежзий", count: 4).utf16)
        XCTAssertEqual(text.count, 40)
        down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
        EventReplay.matchRelease(up, to: down, tag: 1234)
        var count = 0, units = [UniChar](repeating: 0, count: 64)
        up.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        XCTAssertEqual(Array(units.prefix(count)), Array(text.prefix(16)))
        XCTAssertEqual(up.getIntegerValueField(.eventSourceUserData), 1234)
    }
}
