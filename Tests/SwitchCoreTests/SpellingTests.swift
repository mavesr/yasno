import XCTest
@testable import SwitchCore

final class SpellingTests: XCTestCase {
    let detector = Detector()
    let installed = KeyboardLayout.installed(enabledOnly: false)
    func layout(_ suffix: String) throws -> KeyboardLayout {
        try XCTUnwrap(installed.first { $0.id == "com.apple.keylayout." + suffix })
    }

    func testExplicitSpellingOptionAndLayoutRepairAreIndependent() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for (source, pairs) in [(ru, [("првиет", "привет"), ("спасиибо", "спасибо"), ("пожалуста", "пожалуйста")]),
                                 (uk, [("привті", "привіт"), ("дякуую", "дякую")]),
                                 (abc, [("helllo", "hello"), ("wrold", "world"), ("recieve", "receive"), ("dannke", "danke")])] {
            for (wrong, correct) in pairs {
                for suffix in ["", ",", ".", "!", "?!", "…"] {
                    XCTAssertEqual(detector.suggestCompleted(wrong + suffix, source: source, layouts: active,
                        preferredTargetID: source.id, correctSpelling: true)?.replacement, correct + suffix)
                    XCTAssertNil(detector.suggestCompleted(wrong + suffix, source: source, layouts: active, correctSpelling: false))
                }
                XCTAssertTrue(detector.maySuggestCompleted(wrong, source: source, layouts: active, correctSpelling: true))
                XCTAssertNil(detector.suggestCompleted(wrong, source: source, layouts: active, ignored: [wrong], correctSpelling: true))
            }
        }
        for enabled in [false, true] {
            XCTAssertEqual(detector.suggestCompleted("ghbdtn", source: abc, layouts: active, correctSpelling: enabled)?.replacement, "привет")
        }
    }

    func testWrongLayoutPlusTypoAndCapitalization() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for (input, source, expected, target) in [("ghdbtn", abc, "привет", ru), ("рудддщ", ru, "hello", abc),
                                                   ("Првиет", ru, "Привет", ru), ("Helllo", abc, "Hello", abc)] {
            let result = detector.suggestCompleted(input, source: source, layouts: active,
                preferredTargetID: target.id, correctSpelling: true)
            XCTAssertEqual(result?.replacement, expected, input)
            XCTAssertEqual(result?.target.id, target.id, input)
        }
    }

    func testCorrectInflectionsAndAmbiguousValidWordsSurviveSpelling() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for (source, words) in [(abc, ["form", "from", "quite", "quiet", "trial", "trail", "herb", "Herb", "permissions", "benutzern", "fensters", "Danek", "API", "SwiftUI"]),
                                  (ru, ["словари", "сообщениям", "системная", "привет", "продумайте"]),
                                  (uk, ["повідомленням", "системна", "клавіші", "браузери"])] {
            for word in words {
                XCTAssertNil(detector.suggestCompleted(word, source: source, layouts: active, correctSpelling: true), word)
            }
        }
        for input in ["hello_world", "helllo2", "helllo@example.com", "https://helllo.com", "HELLLO", "hElllo"] {
            XCTAssertNil(detector.suggestCompleted(input, source: abc, layouts: active, correctSpelling: true))
        }
    }

    func testAddressLikePhysicalPrefixDoesNotOverrideNativeWord() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        for length in 4..."переключаются".count {
            let prefix = String("переключаются".prefix(length))
            XCTAssertNil(detector.suggestWhileTyping(prefix, source: ru, layouts: [abc, ru, uk]), prefix)
        }
    }

    func testPhysicalPunctuationIsNotMisreadAsAnEnglishSpellingAlternative() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        for suffix in ["", "!", ",", "…"] {
            XCTAssertEqual(detector.suggestCompleted("lzre." + suffix, source: abc, layouts: [abc, ru, uk],
                preferredTargetID: uk.id, correctSpelling: true)?.replacement, "дякую" + suffix)
        }
        XCTAssertEqual(detector.suggestWhileTyping("lzre.", source: abc, layouts: [abc, ru, uk],
            preferredTargetID: uk.id, spellingAware: true)?.replacement, "дякую")
        XCTAssertNil(detector.suggestCompleted("Tasttaturen", source: abc, layouts: [abc, ru, uk],
            ignored: ["tasttaturen"], correctSpelling: true))
    }

    func testNativeSpellingCannotOverrideAnExplicitForeignLayoutChoice() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        for (input, source, expected, target) in [("фищму", ru, "above", abc),
                                                   ("правільно", uk, "правильно", ru),
                                                   ("прывит", ru, "привіт", uk)] {
            let result = detector.suggestCompleted(input, source: source, layouts: [abc, ru, uk],
                preferredTargetID: target.id, correctSpelling: true)
            XCTAssertEqual(result?.replacement, expected)
            XCTAssertEqual(result?.target.id, target.id)
        }
        XCTAssertNil(detector.suggestCompleted("фищму", source: ru, layouts: [abc, ru, uk], correctSpelling: true))
    }

    func testPreferredLanguagePrefixPreventsEarlyWrongCyrillicHandoff() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        for correct in ["клавиатура", "клавиатуры", "клавишу", "клавиши", "маленький"] {
            let keys = try XCTUnwrap(ru.convert(correct, to: abc))
            var source = abc, actual = "", converted = false
            for key in keys {
                actual += try XCTUnwrap(abc.convert(String(key), to: source))
                if !converted, let result = detector.suggestWhileTyping(actual, source: source, layouts: [abc, ru, uk], preferredTargetID: ru.id) {
                    actual = result.replacement; source = result.target; converted = true
                }
            }
            if let completed = detector.suggestCompleted(actual, source: source, layouts: [abc, ru, uk], preferredTargetID: ru.id) { actual = completed.replacement }
            XCTAssertEqual(actual, correct)
        }
    }
}
