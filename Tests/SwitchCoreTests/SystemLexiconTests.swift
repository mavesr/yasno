import XCTest
@testable import SwitchCore

/// Cases found by the scenario suite (docs/scenario-validation.md) on real sentences.
final class SystemLexiconTests: XCTestCase {
    let detector = Detector()
    let installed = KeyboardLayout.installed(enabledOnly: false)
    func layout(_ suffix: String) throws -> KeyboardLayout {
        try XCTUnwrap(installed.first { $0.id == "com.apple.keylayout." + suffix })
    }

    func testValidFormsOutsideTheFrequencyListAreNotRespelled() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let layouts = [abc, ru, uk]
        for word in ["песках", "сочетанием", "бабушек", "заболеваниях", "модулей"] {
            XCTAssertNil(detector.suggestCompleted(word, source: ru, layouts: layouts, correctSpelling: true), word)
        }
        for word in ["українці", "національних", "будівництвом"] {
            XCTAssertNil(detector.suggestCompleted(word, source: uk, layouts: layouts, correctSpelling: true), word)
        }
        for word in ["aufgetretene", "provocations", "libeled"] {
            XCTAssertNil(detector.suggestCompleted(word, source: abc, layouts: layouts, correctSpelling: true), word)
        }
        // A real slip is still repaired.
        XCTAssertEqual(detector.suggestCompleted("сегодян", source: ru, layouts: layouts, correctSpelling: true)?.replacement, "сегодня")
    }

    func testRussianWordsOnTheUkrainianLayoutAreNotRespelledAsUkrainian() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        for word in ["должна", "будешь", "Также"] {
            XCTAssertNil(detector.suggestCompleted(word, source: uk, layouts: [abc, ru, uk], correctSpelling: true), word)
        }
    }

    func testCyrillicWordsAreNotReadAsAddresses() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        XCTAssertNil(detector.suggest("действующее", source: ru, layouts: [abc, ru, uk]))
        XCTAssertNil(detector.suggest("звертаюсь", source: uk, layouts: [abc, ru, uk]))
        XCTAssertNil(detector.suggestWhileTyping("зароютс", source: ru, layouts: [abc, ru, uk]))
        XCTAssertEqual(detector.suggest("нфтвучюкг", source: ru, layouts: [abc, ru])?.replacement, "yandex.ru")
    }

    func testMacRussianCommaAndPeriodDoNotBlockConversion() throws {
        let abc = try layout("ABC"), ru = try layout("Russian")
        // Shift-6 and Shift-7 type , and . on the Mac Russian layout.
        XCTAssertEqual(detector.suggest("Eds^", source: abc, layouts: [abc, ru])?.replacement, "Увы,")
        XCTAssertEqual(detector.suggest("Nfr;t", source: abc, layouts: [abc, ru])?.replacement, "Также")
        // Unfinished: ; is still the ж key, so nothing converts yet.
        XCTAssertNil(detector.suggestWhileTyping("Nfr;", source: abc, layouts: [abc, ru]))
    }

    func testInitialsStayInSourceLanguageContext() throws {
        let abc = try layout("ABC"), ru = try layout("Russian")
        XCTAssertNil(detector.suggest("D", source: abc, layouts: [abc, ru], context: "The report was written by "))
        XCTAssertEqual(detector.suggest("d", source: abc, layouts: [abc, ru], preferredTargetID: ru.id)?.replacement, "в")
        // Lowercase letters are not initials: a Latin word earlier in the sentence does not keep them.
        for (typed, expected) in [("b", "и"), ("z", "я"), ("f", "а")] {
            XCTAssertEqual(detector.suggest(typed, source: abc, layouts: [abc, ru], preferredTargetID: ru.id,
                                            context: "Открой app ")?.replacement, expected, typed)
        }
    }

    func testShortAndRareWordsAreRepaired() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let layouts = [abc, ru, uk]
        // Three- and four-letter words make up most missed slips in real sentences.
        for (typed, expected) in [("тчо", "что"), ("тэо", "это"), ("дял", "для"), ("еещ", "еще"), ("hte", "the")] {
            let source = typed.first!.isASCII ? abc : ru
            XCTAssertEqual(detector.suggestCompleted(typed, source: source, layouts: layouts, correctSpelling: true)?.replacement,
                           expected, typed)
        }
        // Long inflections missing from the frequency list come from the spelling service.
        for (typed, expected) in [("коробкгй", "коробкой"), ("голубхы", "голубых")] {
            XCTAssertEqual(detector.suggestCompleted(typed, source: ru, layouts: layouts, correctSpelling: true)?.replacement,
                           expected, typed)
        }
        // A lowercase name or rare valid form is not respelled.
        XCTAssertNil(detector.suggestCompleted("кошмарит", source: ru, layouts: layouts, correctSpelling: true))
    }

    func testShortTechWordsConvertFromThreeKeys() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        XCTAssertEqual(detector.suggest("шщы", source: ru, layouts: [abc, ru, uk])?.replacement, "ios")
        XCTAssertEqual(detector.suggest("фзз", source: ru, layouts: [abc, ru, uk])?.replacement, "app")
    }
}
