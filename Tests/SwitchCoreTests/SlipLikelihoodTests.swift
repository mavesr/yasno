import XCTest
@testable import SwitchCore

final class SlipLikelihoodTests: XCTestCase {
    let installed = KeyboardLayout.installed(enabledOnly: false)
    func layout(_ suffix: String) throws -> KeyboardLayout {
        try XCTUnwrap(installed.first { $0.id == "com.apple.keylayout." + suffix })
    }

    func testNearbyKeysAndCommonSlipsAreLikelierThanDistantOnes() throws {
        let abc = try layout("ABC"), ru = try layout("Russian")
        func p(_ typed: String, _ intended: String, _ layout: KeyboardLayout) -> Double {
            Detector.slipLikelihood(typed: typed, intended: intended, layout: layout)
        }
        XCTAssertEqual(p("hrllo", "hello", abc), 1)       // r is next to e
        XCTAssertEqual(p("hzllo", "hello", abc), 0.05)    // z is not
        XCTAssertEqual(p("helo", "hello", abc), 0.8)      // a dropped double letter
        XCTAssertEqual(p("hlelo", "hello", abc), 0.7)     // a swap
        XCTAssertEqual(p("helllo", "hello", abc), 0.7)    // a doubled letter
        XCTAssertEqual(p("hellpo", "hello", abc), 0.5)    // p is next to o
        XCTAssertEqual(p("привкт", "привет", ru), 1)      // к is next to е on the Russian layout
        XCTAssertEqual(abc.key(for: "a"), 0)
        XCTAssertEqual(abc.key(for: "A"), 0)
    }

}
