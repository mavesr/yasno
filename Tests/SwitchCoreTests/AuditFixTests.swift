import XCTest
import CoreGraphics
@testable import SwitchCore

final class AuditFixTests: XCTestCase {
    let detector = Detector()
    let all = KeyboardLayout.installed(enabledOnly: false)
    func layout(_ name: String) throws -> KeyboardLayout {
        try XCTUnwrap(all.first { $0.id == "com.apple.keylayout." + name })
    }

    func testUkrainianApostrophesInBothAppleLayoutsAcrossAutomaticAndManualPaths() throws {
        let abc = try layout("ABC"), ru = try layout("Russian")
        for name in ["Ukrainian", "Ukrainian-PC"] {
            let uk = try layout(name), active = [abc, ru, try layout(name)]
            for canonical in ["ім'я", "сім'я", "п'ять", "дев'ять", "м'ясо", "пам'ять", "здоров'я", "об'єкт",
                              "зв'язок", "обов'язок", "інтерв'ю", "кур'єр", "кар'єра", "п'ятниця", "комп'ютер", "п'ю", "п'є"] {
                let word = canonical.replacingOccurrences(of: "'", with: uk.apostropheGlyph)
                XCTAssertNotNil(detector.rank(word, languages: uk.languages))
                for source in [abc, ru] {
                    let wrong = try XCTUnwrap(uk.convert(word, to: source), "\(name): \(word) → \(source.id)")
                    for suffix in ["", "!", ",", "…"] {
                        XCTAssertEqual(detector.suggestCompleted(wrong + suffix, source: source, layouts: active,
                            preferredTargetID: uk.id, correctSpelling: true)?.replacement, word + suffix, "\(name): \(wrong + suffix)")
                        XCTAssertEqual(detector.convertTextManually(wrong + suffix, source: source, target: uk), word + suffix)
                    }
                    if word.count >= 4 {
                        let live = detector.suggestWhileTyping(wrong, source: source, layouts: active,
                            preferredTargetID: uk.id, spellingAware: true)
                        let russianAlternatives = ["п'ять": "пять", "дев'ять": "девять", "м'ясо": "мясо",
                                                   "пам'ять": "память", "здоров'я": "здоровья", "комп'ютер": "компьютер"]
                        if name == "Ukrainian-PC", source.id == ru.id, let native = russianAlternatives[canonical] {
                            // PC puts the apostrophe on Russian ё. These can also
                            // be real Russian typos; wait for the word boundary.
                            XCTAssertNotNil(detector.rank(native, languages: ru.languages))
                            XCTAssertNil(live)
                        } else { XCTAssertEqual(live?.replacement, word) }
                    }
                }
                for apostrophe in ["'", "’", "ʼ", "‘"] {
                    let native = canonical.replacingOccurrences(of: "'", with: apostrophe)
                    XCTAssertNil(detector.suggestCompleted(native, source: uk, layouts: active, correctSpelling: true))
                    for count in 4...max(4, native.count) {
                        XCTAssertNil(detector.suggestWhileTyping(String(native.prefix(count)), source: uk, layouts: active,
                            preferredTargetID: ru.id, spellingAware: true))
                    }
                }
            }
        }
    }

    func testUnknownManualWordStillConvertsAnEmbeddedApostropheButPreservesSentencePunctuation() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        XCTAssertEqual(detector.convertTextManually("абв]яф", source: ru, target: uk), "абв'яф")
        XCTAssertEqual(detector.convertTextManually("привет,мир!", source: ru, target: abc), "ghbdtn,vbh!")
        XCTAssertEqual(detector.convertTextManually("lzre.!", source: abc, target: uk), "дякую!")
        for mark in ["'", "’", "ʼ", "‘"] {
            let word = "комп" + mark + "ютер"
            XCTAssertEqual(detector.rank(word, languages: [.ukrainian]), detector.rank("комп'ютер", languages: [.ukrainian]))
        }
    }

    func testPreflightOptimizationsPreserveExistenceForEveryPreference() throws {
        let active = try [layout("ABC"), layout("Russian"), layout("Ukrainian")]
        for source in active {
            for word in ["ghbdtn", "ghbdtn!", "lzre.", "lzre.!", "првиет", "helllo", "adnke", "zzqxwordxxx", "ghjlevfq",
                         "переключаеся", "привет", "b", "фссщгтеюфзздуюсщь", "bv`z", "звязок", "пам’ять", "доброго", "SwiftUI",
                         "Пшерги", "bpex", "Bpex", "bpexb", "bpex!", "bpex_", "изуч", "Github"] {
                for spelling in [false, true] {
                    let live = active.contains { $0.id != source.id && detector.suggestWhileTyping(word, source: source,
                        layouts: active, preferredTargetID: $0.id, spellingAware: spelling) != nil }
                    XCTAssertEqual(detector.maySuggestWhileTyping(word, source: source, layouts: active, spellingAware: spelling), live, word)
                    let completed = detector.maySuggest(word, source: source, layouts: active) || (spelling && active.contains {
                        detector.suggestSpelling(word, source: source, layouts: active, preferredTargetID: $0.id) != nil
                    })
                    XCTAssertEqual(detector.maySuggestCompleted(word, source: source, layouts: active, correctSpelling: spelling), completed, word)
                }
            }
        }
    }

    func testSpellingCanRestoreAnApostropheAndKeepsTheUsersTypography() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        XCTAssertEqual(detector.suggestSpelling("звязок", source: uk, layouts: [abc, ru, uk])?.replacement, "зв'язок")
        for style in ["'", "’", "ʼ"] {
            XCTAssertEqual(detector.suggestSpelling("комп" + style + "ютеер", source: uk, layouts: [uk])?.replacement,
                           "комп" + style + "ютер")
        }
        XCTAssertNil(detector.suggestCompleted("звязок", source: uk, layouts: [uk], correctSpelling: false))
        XCTAssertEqual(detector.suggestSpelling("думєш", source: uk, layouts: [abc, ru, uk])?.replacement, "думаєш")
    }

    func testWrongLayoutComputerTyposHaveBothRussianAndUkrainianAnswers() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        for (input, russian, ukrainian) in [("rjvg.nth", "компьютер", "комп'ютер"),
                                           ("rjvgn.nth", "компьютер", "комп'ютер"),
                                           ("rjvg.nthf", "компьютера", "комп'ютера")] {
            XCTAssertNotNil(detector.rank(russian, languages: ru.languages))
            XCTAssertNotNil(detector.rank(ukrainian, languages: uk.languages))
            // Both differ by one edit after mapping. New vocabulary must not
            // introduce an arbitrary spelling/language choice.
            XCTAssertNil(detector.suggestCompleted(input, source: abc, layouts: [abc, ru, uk],
                preferredTargetID: ru.id, correctSpelling: true))
        }
    }

    func testReleaseMetadataComesFromThePreparedDownWithoutChangingPhysicalRelease() throws {
        let original = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let replay = try XCTUnwrap(CGEventSource(stateID: .privateState))
        replay.userData = 1234
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: replay, virtualKey: 17, keyDown: true))
        let up = try XCTUnwrap(CGEvent(keyboardEventSource: original, virtualKey: 17, keyDown: false))
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x0435])
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x0074])
        up.flags = .maskShift; up.timestamp = 123_000_000
        let state = down.getIntegerValueField(.eventSourceStateID)
        EventReplay.matchRelease(up, to: down, tag: 1234)
        var count = 0, units = [UniChar](repeating: 0, count: 16)
        up.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        XCTAssertEqual(Array(units.prefix(count)), [0x0435])
        XCTAssertEqual(up.getIntegerValueField(.eventSourceStateID), state)
        XCTAssertEqual(up.getIntegerValueField(.eventSourceUserData), 1234)
        XCTAssertEqual(up.flags, .maskShift); XCTAssertEqual(up.timestamp, 123_000_000); XCTAssertEqual(up.type, .keyUp)
    }
}
