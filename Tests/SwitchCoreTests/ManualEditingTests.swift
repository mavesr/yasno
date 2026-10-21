import XCTest
@testable import SwitchCore

final class ManualEditingTests: XCTestCase {
    let detector = Detector()
    func layouts() throws -> [KeyboardLayout] {
        let all = KeyboardLayout.installed(enabledOnly: false)
        return try ["ABC", "Russian", "Ukrainian"].map { name in
            try XCTUnwrap(all.first { $0.id == "com.apple.keylayout." + name })
        }
    }

    func testReportedPereklyuchalisInBothAutomaticModesAndManual() throws {
        let active = try layouts(), abc = active[0], ru = active[1]
        XCTAssertEqual(abc.convert("gthtrk.xfkbcm", to: ru), "переключались")
        for word in ["переключались", "переключался", "переключалась", "переключалось",
                     "переключаться", "переключаешься", "переключаемся", "переключаетесь"] {
            let keys = try XCTUnwrap(ru.convert(word, to: abc))
            for suffix in ["", "!"] {
                XCTAssertEqual(detector.suggestCompleted(keys + suffix, source: abc, layouts: active,
                    preferredTargetID: ru.id, correctSpelling: true)?.replacement, word + suffix)
            }
            XCTAssertEqual(detector.suggestWhileTyping(keys, source: abc, layouts: active,
                preferredTargetID: ru.id, spellingAware: true)?.replacement, word)
            XCTAssertEqual(detector.convertManually(keys, source: abc, layouts: active,
                preferredTargetID: ru.id)?.replacement, word)
            XCTAssertNil(detector.suggestCompleted(word, source: ru, layouts: active, correctSpelling: true))
        }
    }

    func testLongPunctuationTailConvertsInBoundedTime() throws {
        let active = try layouts()
        for (text, preferred, expected) in [("q" + String(repeating: ".", count: 4095), nil, "й" + String(repeating: ".", count: 4095)),
                                            ("ghbdtn" + String(repeating: "!", count: 4000), active[1].id,
                                             "привет" + String(repeating: "!", count: 4000))] {
            let start = ProcessInfo.processInfo.systemUptime
            let result = detector.convertManually(text, source: active[0], layouts: active, preferredTargetID: preferred)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.0)
            XCTAssertEqual(result?.replacement, expected)
        }
    }

    func testCapsLockUsesTheLayoutsOwnTable() throws {
        let installed = KeyboardLayout.installed(enabledOnly: false)
        let active = try layouts(), abc = active[0], ru = active[1]
        let german = try XCTUnwrap(installed.first { $0.id == "com.apple.keylayout.German" })
        // On a Mac, Shift does not invert Caps Lock, and ß has no capital form there.
        XCTAssertEqual(abc.render([.init(key: 0, shift: true, capsLock: true)]), "A")
        XCTAssertEqual(abc.render([.init(key: 0, capsLock: true)]), "A")
        XCTAssertEqual(ru.render([.init(key: 17, shift: true, capsLock: true)]), "Е")
        XCTAssertEqual(german.render([.init(key: 27, capsLock: true)]), "ß")
        XCTAssertEqual(abc.render([.init(key: 18, capsLock: true)]), "1")
        XCTAssertEqual(abc.character(key: 0, shift: false), "a")
        XCTAssertEqual(abc.key(for: "A"), 0)
    }

    func testStandaloneSymbolsUsePhysicalConversionInsteadOfSentencePunctuationRules() throws {
        let active = try layouts()
        for source in active {
            for target in active where target.id != source.id {
                for symbol in ["$", "%", "&", "?", "/", ".", ",", ";", ":", "\"", "'", "[", "]", "{", "}", "~", "`", "@", "#", "№", "\\", "|", "<", ">"] {
                    guard let expected = source.convert(symbol, to: target) else { continue }
                    XCTAssertEqual(detector.convertTextManually(symbol, source: source, target: target), expected,
                                   "\(source.id) → \(target.id): \(symbol)")
                }
            }
        }
        XCTAssertEqual(detector.convertManually("комп]ютер", source: active[1], layouts: active,
            preferredTargetID: active[2].id)?.replacement, "комп'ютер")
        XCTAssertEqual(detector.convertTextManually("привет,мир!", source: active[1], target: active[0]), "ghbdtn,vbh!")
    }

    func testEveryTypedSymbolUsesItsActualKeyAcrossAppleLayoutsAndKeepsCycling() throws {
        let all = KeyboardLayout.installed(enabledOnly: false)
        let active = try ["ABC", "Russian", "Ukrainian", "Ukrainian-PC", "German"].map { name in
            try XCTUnwrap(all.first { $0.id == "com.apple.keylayout." + name })
        }
        var checked = 0
        for source in active {
            for key: UInt16 in 0...50 {
                for shift in [false, true] {
                    let keys = [KeyboardLayout.KeyStroke(key: key, shift: shift)]
                    guard let input = source.render(keys), !input.isEmpty,
                          input.allSatisfy({ !$0.isLetter && !$0.isWhitespace && !$0.isNumber }) else { continue }
                    for target in active where target.id != source.id {
                        guard let expected = target.render(keys) else { continue }
                        XCTAssertEqual(detector.convertTextManually(input, source: source, target: target,
                            physicalKeys: keys), expected, "\(source.id) → \(target.id), key \(key), shift \(shift)")
                        checked += 1
                    }
                    let result = try XCTUnwrap(detector.convertManually(input, source: source,
                        layouts: active, physicalKeys: keys))
                    XCTAssertEqual(result.replacement, result.target.render(keys))
                    if active.contains(where: { $0.id != source.id && $0.render(keys) != input }) {
                        XCTAssertNotEqual(result.replacement, input)
                    }
                    // Every following Shift uses the original key, even when two
                    // consecutive Cyrillic layouts display the same symbol.
                    let cycle = LayoutCycle(layoutIDs: KeyboardLayout.cycleOrder(active).map(\.id),
                        startingID: source.id, firstTargetID: result.target.id)
                    var current = source.id
                    for _ in 0..<active.count {
                        current = try XCTUnwrap(cycle.next(after: current))
                        let target = try XCTUnwrap(active.first { $0.id == current })
                        XCTAssertEqual(detector.convertTextManually(input, source: source, target: target,
                            physicalKeys: keys), target.render(keys))
                    }
                    XCTAssertEqual(current, source.id)
                }
            }
        }
        XCTAssertGreaterThan(checked, 400)
    }

    func testDollarAndPercentChangeEvenWithTheOtherCyrillicLayoutPreferred() throws {
        let active = try layouts(), abc = active[0], ru = active[1], uk = active[2]
        let key = [KeyboardLayout.KeyStroke(key: 21, shift: true)] // Shift+4
        XCTAssertEqual(abc.render(key), "$")
        for source in [ru, uk] {
            XCTAssertEqual(source.render(key), "%")
            XCTAssertEqual(detector.convertManually("%", source: source, layouts: active,
                preferredTargetID: source.id == ru.id ? uk.id : ru.id, physicalKeys: key)?.replacement, "$")
        }
        XCTAssertEqual(detector.convertManually("$", source: abc, layouts: active,
            preferredTargetID: ru.id, physicalKeys: key)?.replacement, "%")
    }

    func testFreshLetterInAnExistingWordIsTheOnlyManualEditAtStartMiddleOrEnd() throws {
        let active = try layouts(), abc = active[0]
        for (before, recent, after, expected) in [
            ("g", "g", "ривет", "привет"), ("приd", "d", "ет", "привет"),
            ("привеn", "n", "", "привет"), ("👩‍💻 приd", "d", "ет", "👩‍💻 привет"),
            ("приdt", "dt", "т", "привет"), ("со.", ".", "з", "союз"), ("у;", ";", "ас", "ужас")
        ] {
            let fragment = try XCTUnwrap(TextSafety.manualWord(onCurrentLine: before, recentText: recent, rightContext: after))
            XCTAssertEqual(fragment.text, recent)
            let replacement = try XCTUnwrap(detector.convertManually(fragment.text, source: abc,
                layouts: active, preferredTargetID: active[1].id)?.replacement)
            XCTAssertEqual(String(before.dropLast(fragment.text.count)) + replacement + after, expected)
        }
        XCTAssertEqual(TextSafety.manualWord(onCurrentLine: "ghbdtn", recentText: "ghbdtn")?.text, "ghbdtn")
        XCTAssertEqual(TextSafety.manualWord(onCurrentLine: "ghbdtn  ", recentText: "ghbdtn", recentSuffix: "  ")?.text, "ghbdtn")
        XCTAssertEqual(TextSafety.manualWord(onCurrentLine: "привет g", recentText: "g")?.text, "g")
        XCTAssertNil(TextSafety.manualWord(onCurrentLine: "привет\n ", recentText: "привет"))
        XCTAssertEqual(TextSafety.manualWord(onCurrentLine: "старое", recentText: "other")?.text, "старое")
        // The other Cyrillic layout must not swallow a deliberate letter
        // conversion merely because it displays the same character.
        for source in active {
            for letter in "abcdefghijklmnopqrstuvwxyzабвгдеёжзийклмнопрстуфхцчшщъыьэюяіїєґ" {
                let text = String(letter)
                guard source.convert(text, to: source) == text,
                      active.contains(where: { $0.id != source.id && source.convert(text, to: $0) != text }) else { continue }
                for preferred in active {
                    let result = try XCTUnwrap(detector.convertManually(text, source: source, layouts: active,
                        preferredTargetID: preferred.id))
                    XCTAssertNotEqual(result.replacement, text, "\(source.id): \(text), preferred \(preferred.id)")
                }
            }
        }
    }

    func testNewInflectionsMakeAmbiguousTyposAbstainInsteadOfChoosingTheWrongForm() throws {
        let active = try layouts(), abc = active[0], ru = active[1]
        for (input, alternatives) in [
            ("переключатеся", ["переключается", "переключаться"]),
            ("переключаеся", ["переключаемся", "переключается", "переключался"]),
            ("переключаеяся", ["переключаемся", "переключается"])
        ] {
            for correct in alternatives { XCTAssertNotNil(detector.rank(correct, languages: ru.languages)) }
            XCTAssertNil(detector.suggestCompleted(input, source: ru, layouts: active, correctSpelling: true))
            let keys = try XCTUnwrap(ru.convert(input, to: abc))
            XCTAssertNil(detector.suggestCompleted(keys, source: abc, layouts: active,
                preferredTargetID: ru.id, correctSpelling: true))
        }
    }
}
