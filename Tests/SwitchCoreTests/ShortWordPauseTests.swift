import XCTest
@testable import SwitchCore

/// A search field (Countries on Unity: гыф → usa) gets no Space after a short word.
final class ShortWordPauseTests: XCTestCase {
    let detector = Detector()
    let layouts = KeyboardLayout.installed(enabledOnly: false)
    func layout(_ suffix: String) throws -> KeyboardLayout {
        try XCTUnwrap(layouts.first { $0.id == "com.apple.keylayout." + suffix })
    }
    func request(_ text: String, _ source: KeyboardLayout, _ active: [KeyboardLayout], paused: Bool) -> CorrectionRequest {
        CorrectionRequest(text: text, source: source, layouts: active, preferredTargetID: nil,
                          correctSpelling: true, whileTyping: true, paused: paused)
    }

    func testShortWordSwitchesOnceTypingStops() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for (input, output, source) in [("гыф", "usa", ru), ("ыуе", "set", ru), ("ыгт", "sun", ru)] {
            XCTAssertNil(detector.correction(request(input, source, active, paused: false), context: ""), input)
            XCTAssertTrue(detector.mayCorrect(request(input, source, active, paused: true)), input)
            XCTAssertEqual(detector.correction(request(input, source, active, paused: true), context: "")?.replacement, output, input)
        }
    }

    func testPauseLeavesNativePrefixesLongWordsAndLettersAlone() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        // Native words and beginnings of native words (рус → руслан, the → there), lone letters
        // and longer words, which live typing already handles.
        for (input, source) in [("рус", ru), ("при", ru), ("the", abc), ("us", abc), ("f", abc), ("z", abc),
                                ("гыфу", ru), ("API", abc), ("ру", ru)] {
            XCTAssertFalse(detector.mayCorrect(request(input, source, active, paused: true)), input)
            XCTAssertNil(detector.correction(request(input, source, active, paused: true), context: ""), input)
        }
    }
}
