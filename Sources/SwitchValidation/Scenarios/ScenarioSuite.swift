import Foundation
import SwitchCore

public struct WordStatistics: Codable {
    public var words = 0
    public var wrongWords = 0
    public var edits = 0
}

public struct ScenarioReport: Codable {
    public let schema: Int
    public let suite: String
    public let seed: UInt64
    public let profile: String
    public let corpusSHA256: String
    public let layouts: [String]
    public let environment: String
    public var categories: [String: ValidationStatistics] = [:]
    public var words: [String: WordStatistics] = [:]
    public var total = ValidationStatistics()
    public var skipped: [String: Int] = [:]
    /// Wrong changes whose result is itself a dictionary word, per category.
    public var intoOtherWord: [String: Int] = [:]
    public var samples: [ValidationRecord] = []
    public var sessions = 0
    public var durationSeconds: Double = 0
    public var scope = "Key-by-key simulation of real sentences, dictionary words and real misspellings through the shipped correction decision (Detector.mayCorrect/correction). Not an Accessibility or browser test. Coverage misses describe a gap against the intended text, not necessarily a defect."
}

/// Scenario validation at scale: real sentences typed key by key in the right and
/// the wrong layout, with realistic typos, plus every one-slip typo of a large
/// vocabulary and real misspelling lists, each classified by an independent oracle.
public final class ScenarioSuite {
    struct Setup {
        let language: String
        let layouts: [KeyboardLayout]
        let native: KeyboardLayout
        let cyrillic: KeyboardLayout
        let latin: KeyboardLayout
        let preferred: String
        let wrong: [KeyboardLayout]
        let opposite: String?
        let vocabulary: Language
        let simulator: TypingSimulator
        let oracle: SpellingOracle
    }

    struct Budget {
        let sentences: Int
        let vocabulary: Int
        let realWords: Int
        let typosPerWord: Int?
        let realTypos: Int

        static func of(_ profile: String) -> Budget? {
            switch profile {
            case "quick": return Budget(sentences: 300, vocabulary: 300, realWords: 200, typosPerWord: 4, realTypos: 500)
            case "full": return Budget(sentences: 3_000, vocabulary: 3_000, realWords: 3_000, typosPerWord: nil, realTypos: 5_000)
            case "huge": return Budget(sentences: .max, vocabulary: 25_000, realWords: 25_000, typosPerWord: nil, realTypos: .max)
            default: return nil
            }
        }
    }

    let detector = Detector()
    let data: ScenarioData
    private(set) var setups: [Setup] = []
    private var keyboards: [String: PhysicalKeyboard] = [:]

    public init(testData: URL) throws {
        data = try .load(testData)
        let installed = KeyboardLayout.installed(enabledOnly: false)
        func layout(_ suffix: String) throws -> KeyboardLayout {
            guard let found = installed.first(where: { $0.id == "com.apple.keylayout." + suffix }) else {
                throw NSError(domain: "YasnoValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Required Apple layout missing: \(suffix)"])
            }
            return found
        }
        let abc = try layout("ABC"), russian = try layout("Russian"), ukrainian = try layout("Ukrainian"), german = try layout("German")
        for item in [abc, russian, ukrainian, german] { keyboards[item.id] = PhysicalKeyboard(item) }
        // The user's own set (ABC, Russian, Ukrainian Legacy), plus German QWERTZ for German text.
        let common = [abc, russian, ukrainian], germanSet = [german, russian, ukrainian]
        var oracles: [String: SpellingOracle] = [:]
        func oracle(_ languages: [Language]) -> SpellingOracle {
            let key = languages.map(\.rawValue).sorted().joined(separator: "+")
            if let existing = oracles[key] { return existing }
            let created = SpellingOracle(detector: detector, languages: languages)
            oracles[key] = created
            return created
        }
        func setup(_ language: String, _ layouts: [KeyboardLayout], native: KeyboardLayout, cyrillic: KeyboardLayout,
                   latin: KeyboardLayout, wrong: [KeyboardLayout], opposite: String?, vocabulary: Language) -> Setup {
            Setup(language: language, layouts: layouts, native: native, cyrillic: cyrillic, latin: latin,
                  preferred: cyrillic.id, wrong: wrong, opposite: opposite, vocabulary: vocabulary,
                  simulator: TypingSimulator(detector: detector, layouts: layouts), oracle: oracle(native.languages))
        }
        setups = [
            setup("ru", common, native: russian, cyrillic: russian, latin: abc, wrong: [abc, ukrainian], opposite: ukrainian.id, vocabulary: .russian),
            setup("uk", common, native: ukrainian, cyrillic: ukrainian, latin: abc, wrong: [abc, russian], opposite: russian.id, vocabulary: .ukrainian),
            setup("en", common, native: abc, cyrillic: russian, latin: abc, wrong: [russian, ukrainian], opposite: nil, vocabulary: .english),
            setup("de", germanSet, native: german, cyrillic: russian, latin: german, wrong: [russian], opposite: nil, vocabulary: .german),
        ]
    }

    // MARK: - Recording

    /// Results of one slice of work, merged in a fixed order so that output does not
    /// depend on thread scheduling.
    final class Partial {
        var categories: [String: ValidationStatistics] = [:]
        var words: [String: WordStatistics] = [:]
        var failures: [ValidationRecord] = []
        var samples: [ValidationRecord] = []
        var sampleCounts: [String: Int] = [:]
        var skipped: [String: Int] = [:]
        var intoOtherWord: [String: Int] = [:]
        var sessions = 0
        let isWord: (String) -> Bool
        init(isWord: @escaping (String) -> Bool) { self.isWord = isWord }

        /// Every non-passing sentence is written to failures.jsonl. Word-level misses are
        /// counted only (there can be millions); their harmful changes are written.
        func add(id: String, category: String, input: String, expected: String, actual: String,
                 missed alternatives: [String] = [], source: String, target: String?,
                 writeMisses: Bool, words: (total: Int, wrong: Int, edits: Int)? = nil) {
            let outcome = actual == expected ? "passed"
                : (alternatives.contains(actual) || actual == input ? "missed" : "different")
            var statistics = categories[category] ?? .init()
            statistics.total += 1
            if outcome == "passed" { statistics.passed += 1 }
            else if outcome == "missed" { statistics.missed += 1 } else { statistics.different += 1 }
            categories[category] = statistics
            // Turning a word into a different real word is the most misleading failure:
            // it looks plausible, so the user may not notice it.
            if outcome == "different", !actual.contains(" "), isWord(actual) { intoOtherWord[category, default: 0] += 1 }
            if let words {
                var value = self.words[category] ?? .init()
                value.words += words.total; value.wrongWords += words.wrong; value.edits += words.edits
                self.words[category] = value
            }
            guard outcome != "passed" else { return }
            let record = ValidationRecord(id: id, category: category, required: false, input: input,
                expected: expected, actual: actual, source: source, target: target, expectedLayout: nil,
                outcome: outcome, microseconds: 0)
            if outcome == "different" || writeMisses { failures.append(record) }
            if sampleCounts[category, default: 0] < 30 { samples.append(record); sampleCounts[category, default: 0] += 1 }
        }
    }

    private func parallel(_ count: Int, chunk: Int, _ body: (Int, Partial) -> Void) -> [Partial] {
        let chunks = (count + chunk - 1) / chunk
        var results = [Partial?](repeating: nil, count: chunks)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let partial = Partial(isWord: isWord)
            for i in (c * chunk)..<min(count, (c + 1) * chunk) { body(i, partial) }
            lock.lock(); results[c] = partial; lock.unlock()
        }
        return results.compactMap { $0 }
    }

    private func isWord(_ text: String) -> Bool {
        let core = text.trimmingCharacters(in: .punctuationCharacters)
        return !core.isEmpty && detector.rank(core, languages: Language.allCases) != nil
    }

    private static func suffix(_ layout: KeyboardLayout) -> String {
        layout.id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    }

    private static func random(_ seed: UInt64, _ salt: String, _ index: Int) -> ValidationRandom {
        var value = seed
        for byte in salt.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        return ValidationRandom(seed: value &+ UInt64(index) &* 0x9e3779b97f4a7c15)
    }

    private static func wordComparison(_ expected: String, _ actual: String, edits: Int) -> (total: Int, wrong: Int, edits: Int) {
        let e = expected.split(separator: " "), a = actual.split(separator: " ")
        guard e.count == a.count else { return (e.count, e.count, edits) }
        return (e.count, zip(e, a).filter { !WordTextCanonical.same(String($0.0), String($0.1)) }.count, edits)
    }

    private func plainRender(_ steps: [TypingSimulator.Step], in layout: KeyboardLayout) -> String {
        var text = ""
        for step in steps {
            switch step {
            case .key(let stroke): text += layout.character(key: stroke.key, shift: stroke.shift) ?? ""
            case .space: text += " "
            case .ensure: break
            }
        }
        return text
    }

    // MARK: - Run

    public func run(profile: String, seed: UInt64, onlyCase: String? = nil,
                    emit: ((ValidationRecord) -> Void)? = nil) throws -> ScenarioReport {
        guard let budget = Budget.of(profile) else {
            throw NSError(domain: "YasnoValidation", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid profile \(profile)"])
        }
        let started = ProcessInfo.processInfo.systemUptime
        var report = ScenarioReport(schema: 1, suite: "scenarios", seed: seed, profile: profile,
            corpusSHA256: data.fingerprint, layouts: keyboards.keys.sorted(),
            environment: ProcessInfo.processInfo.operatingSystemVersionString)
        var partials: [Partial] = []
        for setup in setups {
            partials += sentenceScenarios(setup, budget: budget, seed: seed, onlyCase: onlyCase)
            partials += wordScenarios(setup, budget: budget, seed: seed, onlyCase: onlyCase)
            partials += realTypoScenarios(setup, budget: budget, onlyCase: onlyCase)
        }
        var sampleCounts: [String: Int] = [:]
        for partial in partials {
            report.sessions += partial.sessions
            for (key, value) in partial.skipped { report.skipped[key, default: 0] += value }
            for (key, value) in partial.intoOtherWord { report.intoOtherWord[key, default: 0] += value }
            for (key, value) in partial.categories {
                var merged = report.categories[key] ?? .init()
                merged.total += value.total; merged.passed += value.passed
                merged.missed += value.missed; merged.different += value.different
                report.categories[key] = merged
                report.total.total += value.total; report.total.passed += value.passed
                report.total.missed += value.missed; report.total.different += value.different
            }
            for (key, value) in partial.words {
                var merged = report.words[key] ?? .init()
                merged.words += value.words; merged.wrongWords += value.wrongWords; merged.edits += value.edits
                report.words[key] = merged
            }
            for record in partial.failures { emit?(record) }
            for record in partial.samples where sampleCounts[record.category, default: 0] < 30 {
                report.samples.append(record); sampleCounts[record.category, default: 0] += 1
            }
        }
        report.durationSeconds = ProcessInfo.processInfo.systemUptime - started
        if let onlyCase, report.total.total == 0 {
            throw NSError(domain: "YasnoValidation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown case: \(onlyCase)"])
        }
        return report
    }

    // MARK: - Real sentences

    private func sentenceScenarios(_ setup: Setup, budget: Budget, seed: UInt64, onlyCase: String?) -> [Partial] {
        let language = setup.language
        let sentences = Array((data.sentences[language] ?? []).prefix(budget.sentences))
        let simulator = setup.simulator
        return parallel(sentences.count, chunk: 64) { n, partial in
            let sentence = sentences[n]
            guard let plan = TypingPlan.make(sentence.text, keyboards: keyboards,
                                             cyrillic: setup.cyrillic.id, latin: setup.latin.id) else {
                partial.skipped["sentence/\(language)", default: 0] += 1
                return
            }
            func wanted(_ id: String) -> Bool { onlyCase == nil || onlyCase == id }
            func layout(_ id: String) -> KeyboardLayout { setup.layouts.first { $0.id == id } ?? setup.native }
            func simulate(_ id: String, _ category: String, steps: [TypingSimulator.Step], start: KeyboardLayout,
                          preferred: String?, expected: String, missed: [String] = [], typed: String) {
                guard wanted(id) else { return }
                let outcome = simulator.type(steps, start: start, preferred: preferred)
                partial.sessions += 1
                let actual = String(outcome.text.dropLast()) // the final Space typed by the plan
                partial.add(id: id, category: category, input: typed, expected: expected,
                            actual: WordTextCanonical.apostrophes(actual), missed: missed,
                            source: start.id, target: outcome.finalLayout, writeMisses: true,
                            words: Self.wordComparison(expected, WordTextCanonical.apostrophes(actual), edits: outcome.edits.count))
            }
            let expected = WordTextCanonical.apostrophes(sentence.text)
            let first = layout(plan.words[0].layout)

            // 1. The user always has the right layout: nothing may change, except that an
            // annotated real misspelling may be corrected.
            var fixedTypos = expected
            for typo in sentence.typos { fixedTypos = fixedTypos.replacingOccurrences(of: typo.typed, with: typo.correct) }
            let native = plan.steps(ensureLayouts: true)
            if wanted("s/\(language)/native/\(n)") {
                let outcome = simulator.type(native, start: first, preferred: setup.preferred)
                partial.sessions += 1
                let actual = WordTextCanonical.apostrophes(String(outcome.text.dropLast()))
                partial.add(id: "s/\(language)/native/\(n)", category: "sentence/native/\(language)",
                            input: expected, expected: actual == fixedTypos ? fixedTypos : expected, actual: actual,
                            source: first.id, target: outcome.finalLayout, writeMisses: true,
                            words: Self.wordComparison(expected, actual, edits: outcome.edits.count))
            }

            // 2. The whole sentence typed from the wrong layout; only the app may switch it.
            let singleScript = !sentence.mixedScript && plan.words.allSatisfy { $0.layout == plan.words[0].layout }
            let plain = plan.steps(ensureLayouts: false)
            if singleScript {
                for wrong in setup.wrong {
                    let name = Self.suffix(wrong)
                    simulate("s/\(language)/wrong-\(name)/\(n)", "sentence/wrong-\(name)/\(language)",
                             steps: plain, start: wrong, preferred: setup.preferred, expected: expected,
                             typed: plainRender(plain, in: wrong).trimmingCharacters(in: .whitespaces))
                }
                // 3. Cyrillic text while the remembered preference is the other Cyrillic language.
                if let opposite = setup.opposite, let wrong = setup.wrong.first {
                    simulate("s/\(language)/opposite-preference/\(n)", "sentence/opposite-preference/\(language)",
                             steps: plain, start: wrong, preferred: opposite, expected: expected,
                             typed: plainRender(plain, in: wrong).trimmingCharacters(in: .whitespaces))
                }
            }

            // 4. One realistic slip in one word, right layout. 5. The same in the first long
            // word while the layout is still wrong.
            var random = Self.random(seed, "sentence-typo-\(language)", n)
            let eligible = plan.words.indices.filter { plan.words[$0].text.filter(\.isLetter).count >= 3 }
            guard !eligible.isEmpty else { return }
            let target = eligible[random.index(eligible.count)]
            let word = plan.words[target]
            if let keyboard = keyboards[word.layout],
               let typo = Typo.sample(word.strokes, keyboard: keyboard, random: &random),
               let typedWord = keyboard.render(typo.strokes) {
                var words = plan.words.map(\.text); words[target] = typedWord
                let withTypo = WordTextCanonical.apostrophes(words.joined(separator: " "))
                simulate("s/\(language)/typo-\(typo.kind.rawValue)/\(n)", "sentence/typo/\(language)",
                         steps: plan.steps(ensureLayouts: true, replacing: target, with: typo.strokes),
                         start: first, preferred: setup.preferred, expected: expected, missed: [withTypo], typed: withTypo)
            }
            if singleScript, let wrong = setup.wrong.first,
               let longIndex = plan.words.indices.first(where: { plan.words[$0].text.filter(\.isLetter).count >= 4 }),
               let keyboard = keyboards[plan.words[longIndex].layout],
               let typo = Typo.sample(plan.words[longIndex].strokes, keyboard: keyboard, random: &random),
               let typedWord = keyboard.render(typo.strokes) {
                var words = plan.words.map(\.text); words[longIndex] = typedWord
                let withTypo = WordTextCanonical.apostrophes(words.joined(separator: " "))
                let steps = plan.steps(ensureLayouts: false, replacing: longIndex, with: typo.strokes)
                simulate("s/\(language)/typo-wrong/\(n)", "sentence/typo-wrong/\(language)",
                         steps: steps, start: wrong, preferred: setup.preferred, expected: expected, missed: [withTypo],
                         typed: plainRender(steps, in: wrong).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    // MARK: - Vocabulary sweep

    private func vocabulary(_ setup: Setup, budget: Budget) -> [String] {
        let keyboard = keyboards[setup.native.id]!
        var seen: Set<String> = []
        var words: [String] = []
        func add(_ word: String) {
            guard word.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "'" }),
                  keyboard.strokes(for: word) != nil, seen.insert(word).inserted else { return }
            words.append(word)
        }
        for (word, _) in detector.vocabulary(setup.vocabulary).sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value })
            .prefix(budget.vocabulary) { add(word) }
        var real = 0
        for sentence in data.sentences[setup.language] ?? [] where real < budget.realWords {
            for raw in sentence.text.split(whereSeparator: { $0 == " " || $0 == "-" }) {
                let word = String(raw).trimmingCharacters(in: .punctuationCharacters).lowercased()
                let before = words.count
                add(WordTextCanonical.apostrophes(word))
                if words.count > before { real += 1 }
            }
        }
        return words
    }

    private func wordScenarios(_ setup: Setup, budget: Budget, seed: UInt64, onlyCase: String?) -> [Partial] {
        let language = setup.language
        let words = vocabulary(setup, budget: budget)
        let keyboard = keyboards[setup.native.id]!
        let simulator = setup.simulator
        guard let wrong = setup.wrong.first else { return [] }
        return parallel(words.count, chunk: 16) { i, partial in
            let word = words[i]
            guard let strokes = keyboard.strokes(for: word) else { return }
            func check(_ id: String, _ category: String, _ strokes: [KeyStroke], start: KeyboardLayout,
                     expected: String, typed: String) {
                guard onlyCase == nil || onlyCase == id else { return }
                let steps = strokes.map { TypingSimulator.Step.key($0) } + [.space]
                let outcome = simulator.type(steps, start: start, preferred: setup.preferred)
                partial.sessions += 1
                let actual = WordTextCanonical.apostrophes(String(outcome.text.dropLast()))
                let plain = plainRender(steps, in: start).trimmingCharacters(in: .whitespaces)
                partial.add(id: id, category: category, input: plain, expected: expected, actual: actual,
                            missed: [typed], source: start.id, target: outcome.finalLayout, writeMisses: false)
                // A corrected word typed again in the layout it ended in must stay as it is:
                // no second change and no switching back and forth.
                guard !outcome.edits.isEmpty, let final = keyboards[outcome.finalLayout],
                      let again = final.strokes(for: actual),
                      let layout = setup.layouts.first(where: { $0.id == outcome.finalLayout }) else { return }
                let repeated = simulator.type(again.map { TypingSimulator.Step.key($0) } + [.space], start: layout, preferred: setup.preferred)
                partial.sessions += 1
                partial.add(id: id + "/again", category: "stability/\(language)", input: actual, expected: actual,
                            actual: WordTextCanonical.apostrophes(String(repeated.text.dropLast())),
                            source: layout.id, target: repeated.finalLayout, writeMisses: false)
            }
            check("w/\(language)/\(i)/clean-native", "word/clean-native/\(language)", strokes,
                start: setup.native, expected: word, typed: word)
            check("w/\(language)/\(i)/clean-wrong", "word/clean-wrong/\(language)", strokes,
                start: wrong, expected: word, typed: word)
            let title = word.prefix(1).uppercased() + word.dropFirst()
            if title != word, let titleStrokes = keyboard.strokes(for: title) {
                check("w/\(language)/\(i)/title-wrong", "word/title-wrong/\(language)", titleStrokes,
                    start: wrong, expected: title, typed: title)
            }
            var typos = Typo.all(strokes, keyboard: keyboard)
            if let limit = budget.typosPerWord, typos.count > limit {
                var random = Self.random(seed, "word-typo-\(language)", i)
                var picked: [Typo] = []
                while picked.count < limit, !typos.isEmpty { picked.append(typos.remove(at: random.index(typos.count))) }
                typos = picked
            }
            for (j, typo) in typos.enumerated() {
                guard let typed = keyboard.render(typo.strokes) else { continue }
                let verdict = setup.oracle.verdict(typed: typed, intended: word)
                let expected = verdict == .validWord ? typed : word
                check("w/\(language)/\(i)/t\(j)/native", "typo/\(verdict.rawValue)/native/\(language)", typo.strokes,
                    start: setup.native, expected: expected, typed: typed)
                check("w/\(language)/\(i)/t\(j)/wrong", "typo/\(verdict.rawValue)/wrong/\(language)", typo.strokes,
                    start: wrong, expected: expected, typed: typed)
            }
            // Two slips in one word: rarely recoverable by a one-edit corrector, but it
            // must never turn into something unrelated.
            var random = Self.random(seed, "double-typo-\(language)", i)
            for d in 0..<2 {
                guard word.count >= 5, let once = Typo.sample(strokes, keyboard: keyboard, random: &random),
                      let twice = Typo.sample(once.strokes, keyboard: keyboard, random: &random),
                      let typed = keyboard.render(twice.strokes), typed != word else { continue }
                let expected = setup.oracle.rank(typed) != nil ? typed : word
                check("w/\(language)/\(i)/d\(d)/native", "double-typo/native/\(language)", twice.strokes,
                      start: setup.native, expected: expected, typed: typed)
                check("w/\(language)/\(i)/d\(d)/wrong", "double-typo/wrong/\(language)", twice.strokes,
                      start: wrong, expected: expected, typed: typed)
            }
        }
    }

    // MARK: - Real misspellings

    private func realTypoScenarios(_ setup: Setup, budget: Budget, onlyCase: String?) -> [Partial] {
        let language = setup.language
        let pairs = Array((data.typos[language] ?? []).filter { $0.typed.lowercased() != $0.correct.lowercased() }
            .prefix(budget.realTypos))
        let keyboard = keyboards[setup.native.id]!
        let simulator = setup.simulator
        guard let wrong = setup.wrong.first else { return [] }
        return parallel(pairs.count, chunk: 64) { k, partial in
            let pair = pairs[k]
            guard let strokes = keyboard.strokes(for: pair.typed) else {
                partial.skipped["real-typo/\(language)", default: 0] += 1
                return
            }
            let verdict = setup.oracle.verdict(typed: pair.typed, intended: pair.correct)
            let expected = verdict == .validWord ? pair.typed : pair.correct
            for (mode, start) in [("native", setup.native), ("wrong", wrong)] {
                let id = "r/\(language)/\(k)/\(mode)"
                guard onlyCase == nil || onlyCase == id else { continue }
                let steps = strokes.map { TypingSimulator.Step.key($0) } + [.space]
                let outcome = simulator.type(steps, start: start, preferred: setup.preferred)
                partial.sessions += 1
                let actual = WordTextCanonical.apostrophes(String(outcome.text.dropLast()))
                let plain = plainRender(steps, in: start).trimmingCharacters(in: .whitespaces)
                partial.add(id: id, category: "real-typo/\(pair.source)/\(verdict.rawValue)/\(mode)/\(language)",
                            input: plain, expected: expected, actual: actual, missed: [pair.typed],
                            source: start.id, target: outcome.finalLayout, writeMisses: false)
            }
        }
    }
}

/// Apostrophe forms differ between layouts (', ’, ʼ); compare text with one form.
enum WordTextCanonical {
    static func apostrophes(_ text: String) -> String {
        String(text.map { "’ʼ‘".contains($0) ? "'" : $0 })
    }
    static func same(_ a: String, _ b: String) -> Bool { apostrophes(a) == apostrophes(b) }
}
