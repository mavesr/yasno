import XCTest
import CoreGraphics
@testable import SwitchCore

final class AuditRegressionTests: XCTestCase {
    let detector = Detector()
    let layouts = KeyboardLayout.installed(enabledOnly: false)
    func layout(_ suffix: String) throws -> KeyboardLayout {
        try XCTUnwrap(layouts.first { $0.id == "com.apple.keylayout." + suffix })
    }

    func testOrdinaryInputDoesNotNeedAnEditingGate() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let enabled = [abc, ru, uk]
        for word in ["я", "т", "тут", "там", "ты", "привет", "текст"] {
            XCTAssertFalse(detector.maySuggest(word, source: ru, layouts: enabled), word)
        }
        for word in ["hello", "guten", "user@example.com", "abc123", "SwiftUI", "x"] {
            XCTAssertFalse(detector.maySuggest(word, source: abc, layouts: enabled), word)
        }
        XCTAssertFalse(detector.maySuggest("ghbdtn", source: abc, layouts: enabled, ignored: ["ghbdtn"]))
    }

    func testEditingPreflightKeepsContextDependentCorrections() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let enabled = [abc, ru, uk]
        for word in ["ghbdtn", "ghsdbn", "zr", "ns", "gj;fkeqcnf", "yflt.cm", "ghbdtn!"] {
            XCTAssertTrue(detector.maySuggest(word, source: abc, layouts: enabled), word)
        }
        let shared = try XCTUnwrap(ru.convert("доброго", to: abc))
        XCTAssertNil(detector.suggest(shared, source: abc, layouts: enabled))
        XCTAssertTrue(detector.maySuggest(shared, source: abc, layouts: enabled))
    }

    func testRussianOnlyWordsOverrideAnOlderUkrainianPreference() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        for word in ["что", "как", "хорошо", "почему", "пожалуйста", "сегодня", "спасибо", "привет"] {
            XCTAssertNil(detector.rank(word, languages: [.ukrainian]), word)
            let keys = try XCTUnwrap(ru.convert(word, to: abc))
            for preference in [nil, uk.id] {
                let suggestion = detector.suggest(keys, source: abc, layouts: [abc, ru, uk], preferredTargetID: preference)
                XCTAssertEqual(suggestion?.replacement, word)
                XCTAssertEqual(suggestion?.target.id, ru.id)
            }
        }
    }

    func testRussianContextResolvesPronounWithoutDiscardingSharedUkrainianWords() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        XCTAssertEqual(detector.suggest("ns", source: abc, layouts: [abc, ru, uk], preferredTargetID: uk.id,
            context: "привет спасибо хорошо сегодня пожалуйста ")?.replacement, "ты")
        for word in ["доброго", "так", "там", "не", "на", "час", "бил"] {
            XCTAssertNotNil(detector.rank(word, languages: [.ukrainian]), word)
        }
    }

    func testRareSourceAbbreviationsDoNotDefeatCommonTargetWords() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        for (input, source, output, target) in [("dcb", abc, "всі", uk), ("ghb", abc, "при", ru), ("бил", uk, "был", ru)] {
            let result = detector.suggest(input, source: source, layouts: [abc, ru, uk])
            XCTAssertEqual(result?.replacement, output)
            XCTAssertEqual(result?.target.id, target.id)
        }
        let pc = try layout("Ukrainian-PC")
        XCTAssertEqual(detector.suggest("dcs", source: abc, layouts: [abc, pc])?.replacement, "всі")
    }

    func testTitleCaseCyrillicOnSymbolKeysAndYo() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        for word in ["Жизнь", "Был", "Будет", "Большое", "Юрий", "ёлка", "Хорошо"] {
            let keys = try XCTUnwrap(ru.convert(word, to: abc))
            XCTAssertEqual(detector.suggest(keys, source: abc, layouts: [abc, ru, uk], preferredTargetID: ru.id)?.replacement, word, keys)
        }
        for identifier in ["<div>", "x:y", "https://abc.de", "foo_bar", "API", "SwiftUI"] {
            XCTAssertNil(detector.suggest(identifier, source: abc, layouts: [abc, ru, uk]), identifier)
        }
    }

    func testManualConversionPreservesSentencePunctuation() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        XCTAssertEqual(detector.convertManually("привет, мир!", source: ru, layouts: [abc, ru, uk])?.replacement, "ghbdtn, vbh!")
        XCTAssertEqual(detector.convertManually("ghbdtn, vbh!", source: abc, layouts: [abc, ru, uk])?.replacement, "привет, мир!")
        XCTAssertEqual(detector.convertManually("lzre.", source: abc, layouts: [abc, ru, uk])?.replacement, "дякую")
        XCTAssertEqual(detector.convertTextManually("привіт, світе!", source: uk, target: ru), "прывит, свите!")
    }

    func testCompleteWordsWithAmbiguousPhysicalPunctuation() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        for word in ["пожалуйста", "добрый", "нужно", "даже", "тоже", "собой", "надеюсь", "подожди", "между"] {
            let keys = try XCTUnwrap(ru.convert(word, to: abc))
            XCTAssertEqual(detector.suggest(keys, source: abc, layouts: [abc, ru, uk], preferredTargetID: ru.id)?.replacement, word, keys)
        }
    }

    func testPartialWordsAndCodeDoNotHaveALeftBoundary() {
        for prefix in ["butto", "123", "user_", "https://", "name@", "a.", "x:"] {
            XCTAssertFalse(TextSafety.hasLeftBoundary(prefix), prefix)
        }
        for prefix in ["", " ", "\n", "\u{a0}", "(", "«"] {
            XCTAssertTrue(TextSafety.hasLeftBoundary(prefix), prefix)
        }
    }

    func testManualWordSearchDoesNotCrossNewlines() {
        for prefix in ["привет\n", "привет\r\n  ", "привет\n\t"] {
            XCTAssertNil(TextSafety.lastWord(onCurrentLine: prefix))
        }
        XCTAssertEqual(TextSafety.lastWord(onCurrentLine: "привет ")?.text, "привет")
        XCTAssertEqual(TextSafety.lastWord(onCurrentLine: "привет ")?.trailingUTF16, 1)
        XCTAssertEqual(TextSafety.lastWord(onCurrentLine: "привет\n ghbdtn")?.text, "ghbdtn")
    }

    func testUTF16RangesAreExactAndNeverExpandAcrossEmoji() {
        let text = "👩‍💻 привет"
        XCTAssertEqual(TextSafety.substring(text, location: 6, length: 6), "привет")
        XCTAssertNil(TextSafety.substring(text, location: 1, length: 3))
        XCTAssertNil(TextSafety.substring(text, location: -1, length: 2))
        XCTAssertNil(TextSafety.substring(text, location: 6, length: Int.max))
    }

    func testRareNativeUkrainianWordSurvivesStrongUkrainianContext() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        XCTAssertNil(detector.suggest("бил", source: uk, layouts: [abc, ru, uk], context: "від ударів "))
        XCTAssertEqual(detector.suggest("бил", source: uk, layouts: [abc, ru, uk])?.replacement, "был")
    }

    func testReplaySourceChangesTagWithoutChangingKeyOrModifiers() throws {
        let originalSource = try XCTUnwrap(CGEventSource(stateID: .privateState))
        originalSource.userData = 0x5941534e4f54
        let original = try XCTUnwrap(CGEvent(keyboardEventSource: originalSource, virtualKey: 41, keyDown: true))
        original.flags = [.maskShift, .maskAlphaShift]
        original.timestamp = 1_234_000_000
        let copy = try XCTUnwrap(original.copy())
        let replaySource = try XCTUnwrap(CGEventSource(stateID: .privateState))
        EventReplay.rebind(copy, source: replaySource, tag: 0x5941534e4f)
        XCTAssertEqual(copy.getIntegerValueField(.eventSourceUserData), 0x5941534e4f)
        XCTAssertEqual(copy.getIntegerValueField(.keyboardEventKeycode), 41)
        XCTAssertEqual(copy.flags, original.flags)
        XCTAssertEqual(copy.timestamp, original.timestamp)
        XCTAssertEqual(copy.type, .keyDown)
        XCTAssertEqual(original.getIntegerValueField(.eventSourceUserData), 0x5941534e4f54)
    }

    func testReplayedShiftKeepsPhysicalHoldDuration() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true))
        let up = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false))
        down.type = .flagsChanged; up.type = .flagsChanged
        down.flags = .maskShift; up.flags = []
        down.timestamp = 1_000_000_000; up.timestamp = 1_600_000_000
        EventReplay.rebind(down, source: source, tag: 123)
        EventReplay.rebind(up, source: source, tag: 123)
        var gesture = ShiftTapGesture()
        gesture.press(key: 56, at: Double(down.timestamp) / 1e9)
        XCTAssertFalse(gesture.release(key: 56, at: Double(up.timestamp) / 1e9))
        XCTAssertEqual(down.type, .flagsChanged)
        XCTAssertEqual(up.type, .flagsChanged)
    }

    func testSyntheticSourcesExplicitlyPermitHardwareInput() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        EventReplay.allowLocalInput(source)
        XCTAssertEqual(source.localEventsSuppressionInterval, 0)
        for state: CGEventSuppressionState in [.eventSuppressionStateSuppressionInterval, .eventSuppressionStateRemoteMouseDrag] {
            let filter = source.getLocalEventsFilterDuringSuppressionState(state)
            XCTAssertTrue(filter.contains(.permitLocalKeyboardEvents))
            XCTAssertTrue(filter.contains(.permitLocalMouseEvents))
            XCTAssertTrue(filter.contains(.permitSystemDefinedEvents))
        }
    }
}
