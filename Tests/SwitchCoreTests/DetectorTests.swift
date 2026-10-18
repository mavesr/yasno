import XCTest
@testable import SwitchCore

final class DetectorTests: XCTestCase {
    let detector = Detector()
    let layouts = KeyboardLayout.installed(enabledOnly: false)
    func layout(_ suffix: String) throws -> KeyboardLayout {
        try XCTUnwrap(layouts.first { $0.id == "com.apple.keylayout." + suffix })
    }

    func testDictionariesPresent() {
        for language in Language.allCases { XCTAssertGreaterThan(detector.counts[language] ?? 0, 25_000) }
    }

    func testRussianAndUkrainianAreSeparate() throws {
        let abc = try layout("ABC")
        let ru = try layout("Russian")
        let uk = try layout("Ukrainian")
        let enabled = [abc, ru, uk]
        XCTAssertEqual(detector.suggest("ghbdtn", source: abc, layouts: enabled)?.replacement, "привет")
        // Apple Ukrainian Legacy places і on B and и on S, unlike Ukrainian PC.
        XCTAssertEqual(detector.suggest("ghsdbn", source: abc, layouts: enabled)?.replacement, "привіт")
        XCTAssertEqual(detector.suggest("lzre.", source: abc, layouts: enabled)?.replacement, "дякую")
    }

    func testEnglishAndGermanUseABC() throws {
        let abc = try layout("ABC")
        let ru = try layout("Russian")
        let enabled = [abc, ru]
        XCTAssertEqual(detector.suggest("руддщ", source: ru, layouts: enabled)?.replacement, "hello")
        XCTAssertEqual(detector.suggest("пгеут", source: ru, layouts: enabled)?.replacement, "guten")
        XCTAssertEqual(detector.suggest("вфтлу", source: ru, layouts: enabled)?.replacement, "danke")
        for word in ["hello", "vielen", "guten", "Danke", "über", "Straße"] {
            XCTAssertNil(detector.suggest(word, source: abc, layouts: enabled), word)
        }
    }

    func testCasePreservation() throws {
        let abc = try layout("ABC")
        XCTAssertEqual(detector.suggest("Ghbdtn", source: abc, layouts: [abc, try layout("Russian"), try layout("Ukrainian")])?.replacement, "Привет")
    }

    func testNeverRewriteValidOrSensitivePatterns() throws {
        let abc = try layout("ABC")
        let ru = try layout("Russian")
        for word in ["test", "hello", "API", "SwiftUI", "user@example.com", "abc123", "foo_bar", "https://abc.de", "x", "ok", "ghbdtn2"] {
            XCTAssertNil(detector.suggest(word, source: abc, layouts: layouts), word)
        }
        for word in ["привет", "мир", "да", "код", "пока"] {
            XCTAssertNil(detector.suggest(word, source: ru, layouts: layouts), word)
        }
        XCTAssertNil(detector.suggest("ghbdtn", source: abc, layouts: layouts, ignored: ["ghbdtn"]))
    }

    func testLayoutRoundTripAndGermanQWERTZ() throws {
        let abc = try layout("ABC")
        let ru = try layout("Russian")
        let de = try layout("German")
        XCTAssertEqual(abc.convert("ghbdtn", to: ru), "привет")
        XCTAssertEqual(ru.convert("Привет", to: abc), "Ghbdtn")
        XCTAssertEqual(abc.convert("y", to: de), "z")
        XCTAssertEqual(abc.convert("z", to: de), "y")
    }

    func testSharedCyrillicWordFollowsManualPreference() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        let input = try XCTUnwrap(ru.convert("доброго", to: abc))
        XCTAssertNil(detector.suggest(input, source: abc, layouts: active))
        XCTAssertEqual(detector.suggest(input, source: abc, layouts: active, preferredTargetID: ru.id)?.target.id, ru.id)
        XCTAssertEqual(detector.suggest(input, source: abc, layouts: active, preferredTargetID: uk.id)?.target.id, uk.id)
    }

    func testCorrectCyrillicTextNeverChangesLanguage() throws {
        let ru = try layout("Russian"), uk = try layout("Ukrainian")
        for (source, words) in [
            (ru, ["привет", "спасибо", "пожалуйста", "сегодня", "доброго", "завтра", "работает", "сообщение"]),
            (uk, ["привіт", "дякую", "вітаю", "сьогодні", "доброго", "завтра", "працює", "повідомлення"])
        ] {
            for word in words {
                XCTAssertNil(detector.suggest(word, source: source, layouts: layouts), word)
                XCTAssertNil(detector.suggest(word + ",", source: source, layouts: layouts), word)
            }
        }
    }

    func testCompletedWordWithPunctuation() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        XCTAssertEqual(detector.suggest("ghbdtn!", source: abc, layouts: [abc, ru, uk])?.replacement, "привет!")
        XCTAssertNil(detector.suggest("hello,", source: abc, layouts: [abc, ru, uk]))
        XCTAssertNil(detector.suggest("guten.", source: abc, layouts: [abc, ru, uk]))
    }

    func testBrowserNonbreakingSpaceBoundary() {
        XCTAssertTrue(WordBoundary.matches("ghbdtn\u{00a0}", word: "ghbdtn", suffix: " "))
        XCTAssertTrue(WordBoundary.matches("ghbdtn\u{202f}", word: "ghbdtn", suffix: " "))
        XCTAssertFalse(WordBoundary.matches("another\u{00a0}", word: "ghbdtn", suffix: " "))
        XCTAssertFalse(WordBoundary.matches("ghbdtn\n", word: "ghbdtn", suffix: " "))
        XCTAssertTrue(WordBoundary.matches("hello \u{00a0}", word: "hello", suffix: "  "))
    }

    func testManualConversionOfValidCyrillicUsesLatin() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        XCTAssertEqual(detector.convertManually("привет мир", source: ru, layouts: active)?.replacement, "ghbdtn vbh")
        XCTAssertEqual(detector.convertManually("привіт", source: uk, layouts: active)?.replacement, "ghsdbn")
    }

    func testManualConversionRecognizesWrongLayout() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        XCTAssertEqual(detector.convertManually("руддщ", source: ru, layouts: active)?.replacement, "hello")
        XCTAssertEqual(detector.convertManually("ghsdbn", source: abc, layouts: active)?.replacement, "привіт")
    }

    func testManualSharedWordRespectsExplicitCyrillicChoice() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let text = try XCTUnwrap(ru.convert("доброго", to: abc))
        XCTAssertEqual(detector.convertManually(text, source: abc, layouts: [abc, ru, uk], preferredTargetID: ru.id)?.target.id, ru.id)
        XCTAssertEqual(detector.convertManually(text, source: abc, layouts: [abc, ru, uk], preferredTargetID: uk.id)?.target.id, uk.id)
    }

    func testTwoLetterUkrainianAfterEnglish() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        XCTAssertEqual(detector.suggest("zr", source: abc, layouts: active)?.replacement, "як")
        XCTAssertEqual(detector.suggest("zr", source: abc, layouts: active)?.target.id, uk.id)
        XCTAssertEqual(detector.suggest("ns", source: abc, layouts: active, preferredTargetID: uk.id)?.replacement, "ти")
    }

    func testLessFrequentRussianInflectionFromUkrainianLayout() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for correct in ["короткими", "программы"] {
            let wrong = try XCTUnwrap(ru.convert(correct, to: uk))
            let result = detector.suggest(wrong, source: uk, layouts: active)
            XCTAssertEqual(result?.replacement, correct, wrong)
            XCTAssertEqual(result?.target.id, ru.id, wrong)
        }
    }

    func testNearbyUkrainianResolvesShortPronounDespiteOlderRussianPreference() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        XCTAssertEqual(detector.suggest("ns", source: abc, layouts: active,
            preferredTargetID: ru.id, context: "привет how are you як ")?.replacement, "ти")
        XCTAssertEqual(detector.suggest("ns!", source: abc, layouts: active,
            preferredTargetID: ru.id, context: "як ")?.replacement, "ти!")
        XCTAssertNil(detector.suggest("ns", source: abc, layouts: active))
        XCTAssertEqual(detector.suggest("ns", source: abc, layouts: active,
            preferredTargetID: ru.id)?.replacement, "ты")
    }

    func testContextDoesNotCrossSentenceOrFieldBoundary() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        XCTAssertNil(detector.suggest("ns", source: abc, layouts: active, context: "як ти. "))
        XCTAssertNil(detector.suggest("ns", source: abc, layouts: active, context: "як ти\n"))
        XCTAssertNil(detector.suggest("ns", source: abc, layouts: active, context: ""))
    }

    func testValidShortWordsArePreservedInEveryLanguage() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for (source, words) in [
            (abc, ["a", "I", "as", "at", "be", "by", "do", "he", "in", "is", "it", "me", "no", "of", "on", "or", "so", "to", "we", "ok", "de", "du", "er", "es", "im", "ja", "zu"]),
            (ru, ["я", "и", "ты", "да", "он", "мы", "вы", "не", "на", "до"]),
            (uk, ["я", "і", "ти", "як", "ми", "ви", "це", "її", "не", "на"])
        ] {
            for word in words {
                XCTAssertNil(detector.suggest(word, source: source, layouts: active,
                    preferredTargetID: ru.id, context: "як ти "), word)
            }
        }
        for word in ["ZR", "NS", "x", "v2", "a_b", "x:y"] {
            XCTAssertNil(detector.suggest(word, source: abc, layouts: active,
                preferredTargetID: uk.id, context: "як ти "), word)
        }
    }

    func testForeignAlphabetEntriesAreNotNativeDictionaryEvidence() {
        XCTAssertNil(detector.rank("ты", languages: [.ukrainian]))
        XCTAssertNil(detector.rank("программы", languages: [.ukrainian]))
        XCTAssertNil(detector.rank("і", languages: [.russian]))
        XCTAssertNil(detector.rank("how", languages: [.russian, .ukrainian]))
        XCTAssertNotNil(detector.rank("Straße", languages: [.german]))
    }

    func testCorrectCyrillicWordsSurviveOppositeLanguageContext() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for (source, words, context) in [
            (ru, ["короткими", "программы", "ты", "привет"], "як ти почуваєш "),
            (uk, ["програми", "проблеми", "короткими", "ти", "привіт"], "привет как дела ")
        ] {
            for word in words {
                XCTAssertNil(detector.suggest(word, source: source, layouts: active, context: context), word)
            }
        }
        // A transposition is an ordinary spelling error, not reversible layout substitution.
        XCTAssertNil(detector.suggest("проргамми", source: uk, layouts: active))
    }

    func testFullMixedLanguagePhraseUsesPhysicalKeysAndKeepsEveryWord() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        var source = abc
        var output = ""
        let intended = [(ru, "привет"), (abc, "how"), (abc, "are"), (abc, "you"),
                        (uk, "як"), (uk, "ти"), (uk, "себе"), (uk, "почуваєш")]
        for (language, word) in intended {
            let keys = try XCTUnwrap(language.convert(word, to: abc))
            let rendered = try XCTUnwrap(abc.convert(keys, to: source))
            if let suggestion = detector.suggest(rendered, source: source, layouts: active,
                preferredTargetID: ru.id, context: output) {
                output += suggestion.replacement + " "
                source = suggestion.target
            } else { output += rendered + " " }
        }
        XCTAssertEqual(output, "привет how are you як ти себе почуваєш ")
        XCTAssertEqual(source.id, uk.id)
    }
}
