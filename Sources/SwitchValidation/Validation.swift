import Foundation
import CryptoKit
import SwitchCore

public struct ValidationCorpus: Decodable {
    public let schema: Int
    public let provenance: String
    public let words: [String: [String]]
    public let strict: [[String]]
    public let typos: [[String]]
    public let protected: [String]
    public static func load() throws -> Self {
        guard let url = Bundle.module.url(forResource: "corpus", withExtension: "json", subdirectory: "Resources") else {
            throw NSError(domain: "YasnoValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Validation corpus is missing"])
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public static func fingerprint() throws -> String {
        guard let url = Bundle.module.url(forResource: "corpus", withExtension: "json", subdirectory: "Resources") else {
            throw NSError(domain: "YasnoValidation", code: 1)
        }
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ValidationRecord: Codable {
    public let id: String
    public let category: String
    public let required: Bool
    public let input: String
    public let expected: String
    public let actual: String
    public let source: String
    public let target: String?
    public let expectedLayout: String?
    public let outcome: String
    public let microseconds: Double
}

public struct ValidationStatistics: Codable {
    public var total = 0
    public var passed = 0
    public var missed = 0
    public var different = 0
    public var requiredFailures = 0
}

public struct ValidationReport: Codable {
    public let schema: Int
    public let seed: UInt64
    public let profile: String
    public let corpusWords: Int
    public let corpusSHA256: String
    public let layouts: [String]
    public let environment: String
    public var categories: [String: ValidationStatistics] = [:]
    public var total = ValidationStatistics()
    public var samples: [ValidationRecord] = []
    public var p50Microseconds: Double = 0
    public var p95Microseconds: Double = 0
    public var p99Microseconds: Double = 0
    public var durationSeconds: Double = 0
    public var scope = "Offline deterministic engine and physical-key simulation; not browser/AX certification. Generated typo intent can be ambiguous. Manual inference follows opposite-alphabet behavior for valid Cyrillic. Coverage misses are reported, never counted as passed."
}

/// Stable across processes and Swift hash seeds. Never uses system randomness.
public struct ValidationRandom {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
    public mutating func index(_ count: Int) -> Int { Int(next() % UInt64(max(count, 1))) }
}

public struct TypoMutation: Equatable {
    public let kind: String
    public let text: String
    public init(kind: String, text: String) { self.kind = kind; self.text = text }
    public static func all(_ word: String) -> [Self] {
        let characters = Array(word)
        guard characters.count > 2 else { return [] }
        var seen: Set<String> = [word]
        var result: [Self] = []
        func add(_ kind: String, _ value: [Character]) {
            let text = String(value)
            if seen.insert(text).inserted { result.append(.init(kind: kind, text: text)) }
        }
        for i in characters.indices {
            var missing = characters; missing.remove(at: i); add("omission", missing)
            var doubled = characters; doubled.insert(characters[i], at: i); add("duplication", doubled)
            if i + 1 < characters.count {
                var swapped = characters; swapped.swapAt(i, i + 1); add("transposition", swapped)
            }
            // Same-alphabet replacement, including a non-neighbouring wrong key.
            var replaced = characters; replaced[i] = characters[(i + 2) % characters.count]; add("substitution", replaced)
            var inserted = characters; inserted.insert(characters[(i + 1) % characters.count], at: i); add("insertion", inserted)
        }
        return result
    }
}

public final class ValidationSuite {
    public let corpus: ValidationCorpus
    public let detector: Detector
    public let layouts: [KeyboardLayout]
    private var bySuffix: [String: KeyboardLayout]

    public init() throws {
        corpus = try .load(); detector = Detector()
        let installed = KeyboardLayout.installed(enabledOnly: false)
        let required = ["ABC", "Russian", "Ukrainian", "German"]
        var found: [String: KeyboardLayout] = [:]
        for suffix in required {
            guard let layout = installed.first(where: { $0.id == "com.apple.keylayout." + suffix }) else {
                throw NSError(domain: "YasnoValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Required Apple layout missing: \(suffix)"])
            }
            found[suffix] = layout
        }
        bySuffix = found
        layouts = [found["ABC"]!, found["Russian"]!, found["Ukrainian"]!]
    }

    /// Each callback is one complete, named semantic check, not a loop-iteration counter.
    public func run(profile: String = "quick", seed: UInt64 = 20261018, lexiconRoot: URL? = nil,
                    onlyCase: String? = nil, emit: ((ValidationRecord) -> Void)? = nil) throws -> ValidationReport {
        let started = ProcessInfo.processInfo.systemUptime
        var report = ValidationReport(schema: 2, seed: seed, profile: profile,
            corpusWords: corpus.words.values.reduce(0) { $0 + $1.count },
            corpusSHA256: try ValidationCorpus.fingerprint(),
            layouts: bySuffix.values.map(\.id).sorted(), environment: ProcessInfo.processInfo.operatingSystemVersionString)
        var durations: [Double] = []
        var sampleCounts: [String: Int] = [:]
        func record(_ id: String, _ category: String, _ required: Bool, _ input: String, _ expected: String,
                    _ actual: String, _ source: KeyboardLayout, _ target: String?, _ elapsed: Double = 0,
                    expectedLayout: String? = nil) {
            guard onlyCase == nil || onlyCase == id else { return }
            let layoutMatches = expectedLayout == nil || expectedLayout == (target ?? source.id)
            let outcome = expected == actual && layoutMatches ? "passed" : (actual == input && expected != input ? "missed" : "different")
            let item = ValidationRecord(id: id, category: category, required: required, input: input,
                expected: expected, actual: actual, source: source.id, target: target, expectedLayout: expectedLayout,
                outcome: outcome, microseconds: elapsed * 1e6)
            func update(_ value: inout ValidationStatistics) {
                value.total += 1
                if outcome == "passed" { value.passed += 1 }
                else {
                    if outcome == "missed" { value.missed += 1 } else { value.different += 1 }
                    if required { value.requiredFailures += 1 }
                }
            }
            update(&report.total)
            var statistics = report.categories[category] ?? .init(); update(&statistics); report.categories[category] = statistics
            if elapsed > 0 { durations.append(elapsed * 1e6) }
            if outcome != "passed", sampleCounts[category, default: 0] < 30 {
                report.samples.append(item); sampleCounts[category, default: 0] += 1
            }
            emit?(item)
        }
        func check(_ id: String, _ category: String, _ required: Bool, _ input: String, _ expected: String,
                   _ source: KeyboardLayout, _ preferred: KeyboardLayout?, spelling: Bool = false, live: Bool = false,
                   manual: Bool = false, ignored: Set<String> = [], context: String = "") {
            guard onlyCase == nil || onlyCase == id else { return }
            let begin = ProcessInfo.processInfo.systemUptime
            let result: Suggestion?
            if manual {
                result = detector.convertManually(input, source: source, layouts: layouts, preferredTargetID: preferred?.id)
            } else if live {
                result = detector.suggestWhileTyping(input, source: source, layouts: layouts, ignored: ignored,
                    preferredTargetID: preferred?.id, context: context, spellingAware: true)
            } else {
                result = detector.suggestCompleted(input, source: source, layouts: layouts, ignored: ignored,
                    preferredTargetID: preferred?.id, context: context, correctSpelling: spelling)
            }
            record(id, category, required, input, expected, result?.replacement ?? input, source,
                   result?.target.id, ProcessInfo.processInfo.systemUptime - begin,
                   expectedLayout: expected == input ? source.id : preferred?.id)
        }
        for (i, fixture) in corpus.strict.enumerated() {
            let source = bySuffix[fixture[0]]!, target = bySuffix[fixture[1]]!
            for (j, suffix) in ["", "!", ",", "…"].enumerated() {
                for spelling in [false, true] {
                    check("golden/\(i)/\(j)/\(spelling)", "golden-layout", true, fixture[2] + suffix, fixture[3] + suffix, source, target, spelling: spelling)
                }
            }
            check("golden-live/\(i)", "golden-live", true, fixture[2], fixture[3], source, target, live: true)
        }
        for (i, fixture) in corpus.typos.enumerated() {
            let source = bySuffix[fixture[0]]!
            check("typo-golden/\(i)", "golden-spelling", true, fixture[1], fixture[2], source, source, spelling: true)
            check("typo-disabled/\(i)", "spelling-disabled", true, fixture[1], fixture[1], source, source)
            check("typo-excluded/\(i)", "spelling-excluded", true, fixture[1], fixture[1], source, source, spelling: true, ignored: [fixture[1].lowercased()])
        }
        let languageSource = ["ru": bySuffix["Russian"]!, "uk": bySuffix["Ukrainian"]!, "en": bySuffix["ABC"]!, "de": bySuffix["ABC"]!]
        for language in corpus.words.keys.sorted() {
            let target = languageSource[language]!
            let words = corpus.words[language]!
            for (i, word) in words.enumerated() {
                let cases = [word, word.prefix(1).uppercased() + word.dropFirst()]
                for (c, form) in cases.enumerated() {
                    for (p, punctuation) in ["", ",", "!", "."].enumerated() {
                        check("native/\(language)/\(i)/\(c)/\(p)", "native-preservation", true, form + punctuation, form + punctuation, target, target, spelling: true)
                    }
                }
                for length in 1...max(word.count, 1) {
                    let prefix = String(word.prefix(length))
                    check("prefix/\(language)/\(i)/\(length)", "native-prefix", true, prefix, prefix, target, target, live: true)
                }
                for source in layouts where source.id != target.id {
                    guard let wrong = target.convert(word, to: source), wrong != word else { continue }
                    check("coverage/\(language)/\(i)/\(source.id)", "layout-only-coverage", false, wrong, word, source, target)
                    check("default-coverage/\(language)/\(i)/\(source.id)", "layout-coverage", false, wrong, word, source, target, spelling: true)
                    check("manual/\(language)/\(i)/\(source.id)", "manual-coverage", false, wrong, word, source, target, manual: true)
                    check("excluded/\(language)/\(i)/\(source.id)", "exclusions", true, wrong, wrong, source, target, spelling: true, ignored: [wrong.lowercased()])
                    // Deliver one physical key at a time and continue immediately in the
                    // selected layout after a mid-word conversion. No real input is posted.
                    let physical = target.convert(word, to: bySuffix["ABC"]!)
                    if let physical {
                        var current = source, rendered = "", changed = false
                        for key in physical {
                            guard let glyph = bySuffix["ABC"]!.convert(String(key), to: current) else { continue }
                            rendered += glyph
                            if !changed, let result = detector.suggestWhileTyping(rendered, source: current, layouts: layouts, preferredTargetID: target.id, spellingAware: true) {
                                rendered = result.replacement; current = result.target; changed = true
                            }
                        }
                        let final = changed
                            ? detector.suggestSpelling(rendered, source: current, layouts: layouts, preferredTargetID: target.id)
                            : detector.suggestCompleted(rendered, source: current, layouts: layouts, preferredTargetID: target.id, correctSpelling: true)
                        record("stream/\(language)/\(i)/\(source.id)", "physical-stream-coverage", false, wrong, word,
                            final?.replacement ?? rendered, source, final?.target.id ?? current.id, expectedLayout: target.id)
                    }
                }
                // Mutation intent is labelled as coverage, not guaranteed unique spelling.
                if word.count >= 5, word.allSatisfy(\.isLetter) {
                    let mutations = TypoMutation.all(word)
                    let selected = profile == "full" ? mutations : Array(mutations.prefix(5))
                    for (m, mutation) in selected.enumerated() {
                        check("mutation/\(language)/\(i)/\(m)", "typo-\(mutation.kind)-coverage", false,
                            mutation.text, word, target, target, spelling: true)
                        if profile == "full", let source = layouts.first(where: { $0.id != target.id }),
                           let wrong = target.convert(mutation.text, to: source) {
                            check("mixed-typo/\(language)/\(i)/\(m)", "layout-plus-typo-coverage", false,
                                wrong, word, source, target, spelling: true)
                        }
                    }
                }
            }
        }
        for (i, input) in corpus.protected.enumerated() {
            for source in layouts {
                check("protected/\(i)/\(source.id)", "protected-patterns", true, input, input, source, source, spelling: true)
            }
        }
        var random = ValidationRandom(seed: seed)
        let fuzzCount = profile == "full" ? 40_000 : 2_000
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        for i in 0..<fuzzCount {
            let raw = String((0..<(5 + random.index(24))).map { _ in alphabet[random.index(alphabet.count)] })
            for (kind, text) in [("identifier", raw + "_id"), ("number", raw + String(random.index(1000))),
                                 ("email", raw + "@example.com"), ("caps", raw.uppercased()),
                                 ("mixed-case", "a" + raw.uppercased()), ("path", raw + "/x")] {
                check("fuzz/\(i)/\(kind)", "protected-fuzz", true, text, text, bySuffix["ABC"]!, nil, spelling: true)
            }
        }
        let domains = ["com", "org", "net", "dev", "de", "berlin", "museum", "co.uk"]
        for i in 0..<(profile == "full" ? 2_000 : 100) {
            let base = "site-\(i)." + domains[i % domains.count]
            for (d, address) in [base, "sub." + base, "https://" + base + "/path?q=3", base + ":8080/path"].enumerated() {
                for source in [bySuffix["Russian"]!, bySuffix["Ukrainian"]!] {
                    if let wrong = bySuffix["ABC"]!.convert(address, to: source) {
                        check("domain/\(i)/\(d)/\(source.id)", "domains", true, wrong, address, source, bySuffix["ABC"], live: true)
                    }
                }
            }
        }
        if profile == "full" {
            guard let root = lexiconRoot else { throw NSError(domain: "YasnoValidation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Full profile requires --lexicon-root"] ) }
            for language in ["ru", "uk", "en", "de"] {
                let data = try String(contentsOf: root.appendingPathComponent(language + ".txt"), encoding: .utf8)
                let source = languageSource[language]!
                for (i, line) in data.split(separator: "\n").enumerated() {
                    guard let token = line.split(separator: " ").first else { continue }
                    let word = String(token)
                    // A property sweep of production data is explicitly separate from
                    // the independently authored coverage corpus and its expected words.
                    guard detector.rank(word, languages: source.languages) != nil else { continue }
                    check("lexicon/\(language)/\(i)", "lexicon-native-audit", false, word, word, source, source, spelling: true)
                    check("lexicon-prefix/\(language)/\(i)", "lexicon-prefix-audit", true,
                        String(word.prefix(5)), String(word.prefix(5)), source, source, live: true)
                }
            }
        }
        durations.sort()
        func percentile(_ p: Double) -> Double { durations.isEmpty ? 0 : durations[min(durations.count - 1, Int(Double(durations.count - 1) * p))] }
        report.p50Microseconds = percentile(0.5); report.p95Microseconds = percentile(0.95); report.p99Microseconds = percentile(0.99)
        report.durationSeconds = ProcessInfo.processInfo.systemUptime - started
        if let onlyCase, report.total.total == 0 { throw NSError(domain: "YasnoValidation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown case: \(onlyCase)"]) }
        return report
    }
}
