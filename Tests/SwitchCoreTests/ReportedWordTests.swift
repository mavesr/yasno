import XCTest
@testable import SwitchCore

final class ReportedWordTests: XCTestCase {
    let detector = Detector()
    let layouts = KeyboardLayout.installed(enabledOnly: false)

    func layout(_ suffix: String) throws -> KeyboardLayout {
        try XCTUnwrap(layouts.first { $0.id == "com.apple.keylayout." + suffix })
    }

    func testBrowserAndAppconnectAutomaticAndManual() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for (input, expected, source, target) in [(",hfepth", "браузер", abc, ru),
                                                 ("фззсщттусе", "appconnect", ru, abc)] {
            XCTAssertTrue(detector.maySuggest(input, source: source, layouts: active))
            XCTAssertEqual(detector.suggest(input, source: source, layouts: active,
                preferredTargetID: target.id)?.replacement, expected)
            XCTAssertEqual(detector.convertManually(input, source: source, layouts: active,
                preferredTargetID: target.id)?.replacement, expected)
        }
        for word in ["браузер", "браузера", "браузеры", "браузером"] {
            XCTAssertNil(detector.suggest(word, source: ru, layouts: active))
        }
    }

    func testProdumayAutomaticallyWhileTypingAndOnWordBoundary() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        XCTAssertEqual(abc.convert("ghjlevfq", to: ru), "продумай")
        for word in ["продумай", "продумайте", "Продумай"] {
            let input = try XCTUnwrap(ru.convert(word, to: abc))
            XCTAssertTrue(detector.maySuggest(input, source: abc, layouts: active), word)
            XCTAssertTrue(detector.maySuggestWhileTyping(input, source: abc, layouts: active), word)
            for suffix in ["", "!"] {
                XCTAssertEqual(detector.suggest(input + suffix, source: abc, layouts: active,
                    preferredTargetID: ru.id)?.replacement, word + suffix)
            }
            XCTAssertEqual(detector.suggestWhileTyping(input, source: abc, layouts: active,
                preferredTargetID: ru.id)?.replacement, word)
            XCTAssertEqual(detector.convertManually(input, source: abc, layouts: active,
                preferredTargetID: ru.id)?.replacement, word)
            XCTAssertNil(detector.suggest(word, source: ru, layouts: active))
        }
        XCTAssertNil(detector.suggestWhileTyping("ghjlevfq", source: abc, layouts: active,
            ignored: ["ghjlevfq"], preferredTargetID: ru.id))
    }

    func testGithubAndIzuchiInAutomaticLiveAndManualModes() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for (source, target, pairs) in [
            (ru, abc, [("Пшерги", "Github"), ("пшерги", "github")]),
            (abc, ru, [("bpexb", "изучи"), ("Bpexb", "Изучи")])
        ] {
            for (input, expected) in pairs {
                for spelling in [false, true] {
                    XCTAssertTrue(detector.maySuggestWhileTyping(input, source: source, layouts: active,
                        spellingAware: spelling), input)
                    XCTAssertEqual(detector.suggestWhileTyping(input, source: source, layouts: active,
                        preferredTargetID: target.id, spellingAware: spelling)?.replacement, expected)
                    for suffix in ["", "!", ",", ".", "…"] {
                        XCTAssertEqual(detector.suggestCompleted(input + suffix, source: source, layouts: active,
                            preferredTargetID: target.id, correctSpelling: spelling)?.replacement, expected + suffix)
                    }
                }
                XCTAssertEqual(detector.convertManually(input, source: source, layouts: active,
                    preferredTargetID: target.id)?.replacement, expected)
                XCTAssertNil(detector.suggestWhileTyping(input, source: source, layouts: active,
                    ignored: [input.lowercased()], preferredTargetID: target.id))
                XCTAssertNil(detector.suggestCompleted(expected, source: target, layouts: active, correctSpelling: true))
            }
        }
    }

    func testIzuchConvertsAsAnUnfinishedWordWithoutInventingAnEnding() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for spelling in [false, true] {
            for (input, expected) in [("bpex", "изуч"), ("Bpex", "Изуч")] {
                XCTAssertTrue(detector.maySuggestWhileTyping(input, source: abc, layouts: active,
                    spellingAware: spelling))
                let result = detector.suggestWhileTyping(input, source: abc, layouts: active,
                    preferredTargetID: ru.id, spellingAware: spelling)
                XCTAssertEqual(result?.replacement, expected)
                XCTAssertEqual(result?.target.id, ru.id)
                XCTAssertEqual(detector.convertManually(input, source: abc, layouts: active,
                    preferredTargetID: ru.id)?.replacement, expected)
                // A prefix is evidence only during typing, never a completed dictionary word.
                XCTAssertNil(detector.suggestCompleted(input, source: abc, layouts: active,
                    preferredTargetID: ru.id, correctSpelling: spelling))
                XCTAssertNil(detector.suggestWhileTyping(expected, source: ru, layouts: active,
                    preferredTargetID: abc.id, spellingAware: spelling))
            }
        }
        XCTAssertNil(detector.rank("изуч", languages: [.russian]))
        for input in ["bpe", "BPEX", "bPex", "bpex1", "bpex_", "bpex!"] {
            XCTAssertNil(detector.suggestWhileTyping(input, source: abc, layouts: active,
                preferredTargetID: ru.id, spellingAware: true), input)
        }
        XCTAssertNil(detector.suggestWhileTyping("bpex", source: abc, layouts: active,
            ignored: ["bpex"], preferredTargetID: ru.id))
        // Unlike bpex's rare apex/bex neighbors, rjul can be a repairable
        // English typo for Raul. Keep that ambiguity while spelling is enabled.
        XCTAssertEqual(detector.suggestWhileTyping("rjul", source: abc, layouts: active,
            preferredTargetID: ru.id, spellingAware: false)?.replacement, "когд")
        XCTAssertNil(detector.suggestWhileTyping("rjul", source: abc, layouts: active,
            preferredTargetID: ru.id, spellingAware: true))
    }

    func testSingleLetterWordsAndManualRoundTrips() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for (input, output) in [("z", "я"), ("b", "и"), ("f", "а")] {
            XCTAssertTrue(detector.maySuggest(input, source: abc, layouts: active))
            XCTAssertEqual(detector.suggest(input, source: abc, layouts: active,
                preferredTargetID: ru.id)?.replacement, output)
            XCTAssertEqual(detector.convertManually(input, source: abc, layouts: active,
                preferredTargetID: ru.id)?.replacement, output)
            XCTAssertEqual(detector.convertManually(output, source: ru, layouts: active)?.replacement, input)
            XCTAssertNil(detector.suggest(output, source: ru, layouts: active))
        }
        XCTAssertEqual(detector.suggest("b", source: abc, layouts: active,
            preferredTargetID: uk.id)?.replacement, "і")
        for word in ["a", "I", "x", "1", "@", "_"] {
            XCTAssertNil(detector.suggest(word, source: abc, layouts: active, preferredTargetID: ru.id), word)
        }
        XCTAssertNil(detector.suggest("z", source: abc, layouts: active, ignored: ["z"], preferredTargetID: ru.id))
    }

    func testSingleLettersUseNearbyLanguageAndPreservePunctuation() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        XCTAssertNil(detector.suggest("b", source: abc, layouts: active))
        XCTAssertEqual(detector.suggest("b", source: abc, layouts: active,
            preferredTargetID: ru.id, context: "як ти ")?.replacement, "і")
        XCTAssertEqual(detector.suggest("b", source: abc, layouts: active,
            preferredTargetID: uk.id, context: "привет как дела ")?.replacement, "и")
        XCTAssertEqual(detector.suggest("z!", source: abc, layouts: active,
            preferredTargetID: ru.id)?.replacement, "я!")
        XCTAssertNil(detector.suggest("a!", source: abc, layouts: active, preferredTargetID: ru.id))
    }
}
