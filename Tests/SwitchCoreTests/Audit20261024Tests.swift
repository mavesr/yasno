import XCTest
@testable import SwitchCore

/// Cases from the audit of 24 October 2026 (0.2.12).
final class Audit20261024Tests: XCTestCase {
    let detector = Detector()
    let all = KeyboardLayout.installed(enabledOnly: false)
    func layout(_ name: String) throws -> KeyboardLayout {
        try XCTUnwrap(all.first { $0.id == "com.apple.keylayout." + name })
    }

    func testExceptionsHoldWithSymbolsAroundTheWordAndAnyApostrophe() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        func request(_ text: String, _ source: KeyboardLayout, ignored: Set<String>, whileTyping: Bool = false) -> CorrectionRequest {
            CorrectionRequest(text: text, source: source, layouts: active, ignored: ignored,
                              preferredTargetID: nil, correctSpelling: true, whileTyping: whileTyping)
        }
        for (typed, ignored, source) in [("#ghbdtn", "#ghbdtn", abc), ("/helllo", "/helllo", abc), ("nsc$", "nsc$", abc),
                                         ("п’ятницця", "п'ятницця", uk), ("комп’юттер", "комп'юттер", uk),
                                         ("комп'юттер", "комп’юттер", uk), ("пʼятницця", "п'ятницця", uk)] {
            let excluded = request(typed, source, ignored: [ignored])
            XCTAssertFalse(detector.mayCorrect(excluded), typed)
            XCTAssertNil(detector.correction(excluded, context: ""), typed)
        }
        // Without the exception the same words are corrected.
        XCTAssertEqual(detector.correction(request("#ghbdtn", abc, ignored: []), context: "")?.replacement, "#привет")
        XCTAssertEqual(detector.correction(request("nsc$", abc, ignored: []), context: "")?.replacement, "тыс$")
    }

    func testManualConversionKeepsQuotesAroundAWord() throws {
        let abc = try layout("ABC"), ru = try layout("Russian")
        XCTAssertEqual(detector.convertTextManually("\"ghbdtn\"", source: abc, target: ru), "\"привет\"")
        XCTAssertEqual(detector.convertTextManually("'ghbdtn'", source: abc, target: ru), "'привет'")
        XCTAssertEqual(detector.convertTextManually("«ghbdtn»", source: abc, target: ru), "«привет»")
        XCTAssertEqual(detector.convertTextManually("(ghbdtn)", source: abc, target: ru), "(привет)")
        // A quote key that types a letter of a word still converts: 'nj is эnj → это.
        XCTAssertEqual(detector.convertTextManually("'nj", source: abc, target: ru), "это")
        XCTAssertEqual(detector.convertTextManually("\"привет\"", source: ru, target: abc), "\"ghbdtn\"")
    }

    func testEnglishNamesInsideASentenceAreNotRespelledAsGermanNouns() throws {
        let abc = try layout("ABC"), active = [abc, try layout("Russian")]
        for name in ["Nirmal", "Agence"] {
            XCTAssertNil(detector.suggestCompleted(name, source: abc, layouts: active, context: "General ", correctSpelling: true), name)
        }
    }

    func testCorrectUkrainianWordIsNotSwitchedToRussianWhileTyped() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        let word = "Включіть"
        for count in 4...word.count {
            let prefix = String(word.prefix(count))
            for spelling in [false, true] {
                XCTAssertNil(detector.suggestWhileTyping(prefix, source: uk, layouts: active, spellingAware: spelling), prefix)
                XCTAssertFalse(detector.maySuggestWhileTyping(prefix, source: uk, layouts: active, spellingAware: spelling), prefix)
            }
        }
        XCTAssertNil(detector.suggestCompleted(word, source: uk, layouts: active, correctSpelling: true))
        // Text typed in the wrong alphabet still switches while typed.
        XCTAssertEqual(detector.suggestWhileTyping("руддщ", source: uk, layouts: active)?.replacement, "hello")
    }

    func testDeadKeysAreKnownPerLayout() throws {
        let international = try layout("USInternational-PC"), abc = try layout("ABC")
        XCTAssertTrue(international.isDeadKey(key: 39, shift: false))
        XCTAssertFalse(international.isDeadKey(key: 14, shift: false))
        XCTAssertFalse(abc.isDeadKey(key: 39, shift: false))
    }
}
