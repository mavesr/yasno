import XCTest
import SwitchCore
@testable import SwitchValidation

final class ScenarioInfrastructureTests: XCTestCase {
    private func layouts() throws -> (abc: KeyboardLayout, russian: KeyboardLayout, ukrainian: KeyboardLayout) {
        let installed = KeyboardLayout.installed(enabledOnly: false)
        func find(_ suffix: String) throws -> KeyboardLayout {
            try XCTUnwrap(installed.first { $0.id == "com.apple.keylayout." + suffix }, "missing \(suffix)")
        }
        return (try find("ABC"), try find("Russian"), try find("Ukrainian"))
    }

    func testNeighboursFollowTheKeyboardAndAreSymmetric() {
        let f: UInt16 = 3
        XCTAssertEqual(Set(KeyboardGeometry.neighbours[f] ?? []), [15, 17, 2, 5, 8, 9]) // r t d g c v
        for (key, near) in KeyboardGeometry.neighbours {
            for other in near { XCTAssertTrue(KeyboardGeometry.neighbours[other]?.contains(key) == true, "\(key)-\(other)") }
        }
    }

    func testPhysicalKeysRoundTripAndRenderInAnotherLayout() throws {
        let (abc, russian, _) = try layouts()
        let ru = PhysicalKeyboard(russian), en = PhysicalKeyboard(abc)
        let strokes = try XCTUnwrap(ru.strokes(for: "Привет"))
        XCTAssertEqual(ru.render(strokes), "Привет")
        XCTAssertEqual(en.render(strokes), "Ghbdtn")
        XCTAssertNil(en.strokes(for: "привет"))
    }

    func testTyposAreSingleRealisticSlips() throws {
        let (abc, _, _) = try layouts()
        let keyboard = PhysicalKeyboard(abc)
        let word = try XCTUnwrap(keyboard.strokes(for: "hello"))
        let typos = Typo.all(word, keyboard: keyboard)
        let texts = typos.compactMap { keyboard.render($0.strokes) }
        XCTAssertEqual(Set(typos.map(\.kind)), Set(Typo.Kind.allCases))
        XCTAssertEqual(Set(texts).count, texts.count)
        XCTAssertFalse(texts.contains("hello"))
        for expected in ["helo", "hrllo", "hwello", "helllo", "hlelo"] { XCTAssertTrue(texts.contains(expected), expected) }
        XCTAssertFalse(texts.contains("hzllo"), "z is not next to e")
        var first = ValidationRandom(seed: 7), second = ValidationRandom(seed: 7)
        XCTAssertEqual(Typo.sample(word, keyboard: keyboard, random: &first), Typo.sample(word, keyboard: keyboard, random: &second))
    }

    func testOracleFindsEveryOneEditNeighbourIndependently() {
        let oracle = SpellingOracle(ranks: ["hello": 1, "help": 2, "hell": 3, "world": 4, "word": 5])
        XCTAssertEqual(Set(oracle.neighbours("helo").map(\.word)), ["hello", "help", "hell"])
        XCTAssertEqual(oracle.verdict(typed: "wrold", intended: "world"), .recoverable)
        XCTAssertEqual(oracle.verdict(typed: "hell", intended: "hello"), .validWord)
        XCTAssertEqual(oracle.verdict(typed: "helo", intended: "hello"), .ambiguous)
        XCTAssertEqual(oracle.verdict(typed: "wurld", intended: "hello"), .misleading)
        XCTAssertEqual(oracle.verdict(typed: "xyzzy", intended: "hello"), .unreachable)
        XCTAssertTrue(SpellingOracle.isOneEdit("abcd", "abdc"))
        XCTAssertFalse(SpellingOracle.isOneEdit("abcd", "badc"))
    }

    func testSimulatorUsesTheShippedDecisionAndSwitchesLayout() throws {
        let (abc, russian, ukrainian) = try layouts()
        let simulator = TypingSimulator(detector: Detector(), layouts: [abc, russian, ukrainian])
        let keyboards = [abc.id: PhysicalKeyboard(abc), russian.id: PhysicalKeyboard(russian)]
        let plan = try XCTUnwrap(TypingPlan.make("привет как дела", keyboards: keyboards, cyrillic: russian.id, latin: abc.id))
        let wrong = simulator.type(plan.steps(ensureLayouts: false), start: abc, preferred: russian.id)
        XCTAssertEqual(wrong.text, "привет как дела ")
        XCTAssertEqual(wrong.finalLayout, russian.id)
        XCTAssertFalse(wrong.edits.isEmpty)
        let native = simulator.type(plan.steps(ensureLayouts: true), start: russian, preferred: russian.id)
        XCTAssertEqual(native.text, "привет как дела ")
        XCTAssertTrue(native.edits.isEmpty)
        let mixed = try XCTUnwrap(TypingPlan.make("я люблю Python", keyboards: keyboards, cyrillic: russian.id, latin: abc.id))
        XCTAssertEqual(mixed.words.map(\.layout), [russian.id, russian.id, abc.id])
    }

    func testSuiteRunsEndToEndOnASmallCorpus() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yasno-scenarios-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentences = [
            "ru": "t\t-\tПривет, как у тебя дела?\n", "uk": "t\t-\tДякую, все добре.\n",
            "en": "t\t-\tThank you for the help.\nt\t-\tI recieve mail.\trecieve>receive\n", "de": "t\t-\tDas ist gut.\n",
        ]
        for language in ScenarioData.languages {
            try sentences[language]!.write(to: directory.appendingPathComponent("sentences-\(language).tsv"), atomically: true, encoding: .utf8)
            try "".write(to: directory.appendingPathComponent("typos-\(language).tsv"), atomically: true, encoding: .utf8)
        }
        try "првиет\tпривет\t1\ttest\n".write(to: directory.appendingPathComponent("typos-ru.tsv"), atomically: true, encoding: .utf8)
        var emitted: [ValidationRecord] = []
        let report = try ScenarioSuite(testData: directory).run(profile: "quick", seed: 1) { emitted.append($0) }
        XCTAssertEqual(report.categories["sentence/native/ru"]?.passed, 1)
        XCTAssertEqual(report.categories["sentence/wrong-ABC/ru"]?.passed, 1)
        XCTAssertEqual(report.categories["sentence/native/en"]?.passed, 2, "an annotated real typo may be fixed")
        XCTAssertNotNil(report.categories["word/clean-native/uk"])
        XCTAssertEqual(report.categories.keys.filter { $0.hasPrefix("real-typo/test/") }.count, 2)
        XCTAssertTrue(emitted.allSatisfy { $0.outcome != "passed" })
        XCTAssertGreaterThan(report.sessions, 1_000)
        let replay = try ScenarioSuite(testData: directory).run(profile: "quick", seed: 1, onlyCase: "s/ru/native/0")
        XCTAssertEqual(replay.total.total, 1)
    }
}
