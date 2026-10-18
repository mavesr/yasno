import XCTest
import SwitchCore
import SwitchValidation

final class LayoutAndAddressProperties: XCTestCase {
    func testEveryUnambiguousKeyRoundTripsBetweenFiveAppleLayouts() throws {
        let installed = KeyboardLayout.installed(enabledOnly: false)
        let layouts = try ["ABC", "Russian", "Ukrainian", "Ukrainian-PC", "German"].map { suffix in
            try XCTUnwrap(installed.first { $0.id == "com.apple.keylayout." + suffix })
        }
        for source in layouts {
            var positions: [String: [(UInt16, Bool)]] = [:]
            for key in UInt16(0)...50 {
                for shift in [false, true] {
                    if let glyph = source.character(key: key, shift: shift) { positions[glyph, default: []].append((key, shift)) }
                }
            }
            for target in layouts {
                for (glyph, keys) in positions where keys.count == 1 {
                    let (key, shift) = keys[0]
                    guard let expected = target.character(key: key, shift: shift) else { continue }
                    XCTAssertEqual(source.convert(glyph, to: target), expected, "\(source.id) → \(target.id), key \(key), shift \(shift)")
                }
            }
        }
    }

    func testEightyThousandMalformedDomainVariantsAreNeverRecognized() {
        var random = ValidationRandom(seed: 0x444f4d41494e)
        for i in 0..<10_000 {
            let stem = "sample" + String(random.index(1_000_000))
            let malformed = [stem + ".com:0", stem + ".com:65536", stem + ".com:",
                             "-" + stem + ".com", stem + "-.com", stem + "_name.com",
                             stem + "..com", "user@" + stem + ".com"]
            for value in malformed { XCTAssertFalse(WebAddress.recognizes(value), "case \(i): \(value)") }
        }
        XCTAssertTrue(WebAddress.recognizes(String(repeating: "a", count: 63) + ".com"))
        XCTAssertFalse(WebAddress.recognizes(String(repeating: "a", count: 64) + ".com"))
        XCTAssertTrue(WebAddress.recognizes("example.com:65535"))
        XCTAssertFalse(WebAddress.recognizes("example.com:65536"))
    }
}
