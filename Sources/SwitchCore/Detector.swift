import Foundation

public struct Suggestion {
    public let original: String
    public let replacement: String
    public let target: KeyboardLayout
    public let score: Double
}

/// Immutable frequency dictionaries. All analysis happens locally, off the event-tap thread.
public final class Detector {
    private struct Storage {
        let ranks: [Language: [String: Int]]
        let sortedWords: [Language: [String]]
        let counts: [Language: Int]
    }
    private static let shared = loadStorage()
    // One reference per instance: hot loops then avoid the static once-check on every lookup.
    private let storage: Storage
    private var ranks: [Language: [String: Int]] { storage.ranks }
    private var sortedWords: [Language: [String]] { storage.sortedWords }
    public var counts: [Language: Int] { storage.counts }

    public init() { storage = Self.shared }

    private static func loadStorage() -> Storage {
        var ranks: [Language: [String: Int]] = [:]
        var sortedWords: [Language: [String]] = [:]
        var counts: [Language: Int] = [:]
        for language in Language.allCases {
            var words: [String: Int] = [:]
            words.reserveCapacity(50_000)
            let native: Set<String>?
            if language == .russian || language == .ukrainian {
                let url = Bundle.module.url(forResource: language.rawValue + "-native", withExtension: "txt", subdirectory: "Resources")
                native = Set((url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "").split(separator: "\n").map(String.init))
            } else { native = nil }
            if let url = Bundle.module.url(forResource: language.rawValue, withExtension: "txt", subdirectory: "Resources"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                for (index, line) in text.split(separator: "\n").enumerated() {
                    if let raw = line.split(separator: " ").first {
                        let word = String(raw).lowercased()
                        if Self.hasNativeLetters(word, language: language), native?.contains(word) ?? true {
                            words[word] = index + 1
                        }
                    }
                }
            }
            // Small, authored additions cover everyday vocabulary missing from subtitles.
            // A line may give a rank: short tech words (ios, app) must rank as common to
            // convert from three keys, where rarer matches are mostly accidents.
            // Supplemental lines load after the base list, so a removal applies to it.
            if let url = Bundle.module.url(forResource: language.rawValue + "-supplemental", withExtension: "txt", subdirectory: "Resources"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let fields = line.split(separator: " ")
                    guard let first = fields.first else { continue }
                    let word = String(first)
                    // "-word" drops a listed word that is mostly typed by accident
                    // in another layout: German 'nen is "тут" typed on ABC.
                    if word.hasPrefix("-") { words.removeValue(forKey: String(word.dropFirst())); continue }
                    guard Self.hasNativeLetters(word, language: language) else { continue }
                    if let authored = fields.dropFirst().first.flatMap({ Int($0) }) {
                        words[word] = min(words[word] ?? .max, authored)
                    } else if words[word] == nil { words[word] = 10_000 }
                }
            }
            ranks[language] = words
            sortedWords[language] = words.keys.sorted()
            counts[language] = words.count
        }
        return Storage(ranks: ranks, sortedWords: sortedWords, counts: counts)
    }

    /// Read-only word → frequency rank table, for validation tools that need to
    /// reason about the same vocabulary independently of the lookup code.
    public func vocabulary(_ language: Language) -> [String: Int] { storage.ranks[language] ?? [:] }

    public func rank(_ word: String, languages: [Language]) -> Int? {
        let lower = WordText.canonical(word.lowercased())
        return rankLowercased(lower, languages: languages)
    }

    func rankLowercased(_ lower: String, languages: [Language]) -> Int? {
        // Called for every spelling neighbor candidate; avoid an array per lookup.
        var best: Int?
        for language in languages {
            if let rank = storage.ranks[language]?[lower], best.map({ rank < $0 }) ?? true { best = rank }
        }
        return best
    }

    /// Frequency corpora miss compounds such as app + store and screen + shot.
    /// Accept exactly two substantial, common words from the SAME language, never
    /// arbitrary syllables, recursive segmentations, abbreviations or identifiers.
    /// This is weaker evidence than dictionary membership and is not used as a rank
    /// by context resolution or for overriding a recognized source word.
    private func isCommonLatinCompound(_ word: String, languages: [Language]) -> Bool {
        let lower = word.lowercased()
        guard (7...32).contains(lower.utf8.count),
              lower.utf8.allSatisfy({ (97...122).contains($0) }) else { return false }
        let letters = Array(lower)
        for language in languages where language == .english || language == .german {
            guard let words = ranks[language] else { continue }
            for split in 3...(letters.count - 3) {
                guard let first = words[String(letters[..<split])], first <= 10_000,
                      let second = words[String(letters[split...])], second <= 10_000,
                      (min(first, second) <= 2_000 || first + second <= 12_500) else { continue }
                return true
            }
        }
        return false
    }

    /// Only reserve physical input if some contextual choice could produce a correction.
    /// Trying each preference preserves ambiguous RU/UK candidates while common valid
    /// words and protected patterns never enter the AX editing queue.
    public func maySuggest(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                           ignored: Set<String> = []) -> Bool {
        layouts.contains { target in
            target.id != source.id && suggest(word, source: source, layouts: layouts,
                ignored: ignored, preferredTargetID: target.id) != nil
        }
    }

    // Subtitle frequency lists contain foreign dialogue and abbreviations. Their presence
    // must not make Latin text Russian, or a word containing ы a valid Ukrainian word.
    private static func hasNativeLetters(_ word: String, language: Language) -> Bool {
        let letters = word.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { scalar in
            switch language {
            case .english, .german:
                return (0x61...0x7a).contains(scalar.value) || (0xc0...0x24f).contains(scalar.value) ||
                       (0x1e00...0x1eff).contains(scalar.value)
            case .russian:
                return (0x430...0x44f).contains(scalar.value) || scalar == "ё"
            case .ukrainian:
                return ((0x430...0x44f).contains(scalar.value) && !"ыэъ".unicodeScalars.contains(scalar)) ||
                       "іїєґ".unicodeScalars.contains(scalar)
            }
        }
    }

    /// Nearby completed words resolve language ambiguity; no persistent input history.
    private func contextualPreference(_ context: String, candidates: [Suggestion]) -> String? {
        contextPreference(context, targets: candidates.map(\.target))
    }

    func contextPreference(_ context: String, targets input: [KeyboardLayout]) -> String? {
        var targets: [KeyboardLayout] = []
        for target in input where !targets.contains(where: { $0.id == target.id }) {
            targets.append(target)
        }
        guard targets.count > 1 else { return targets.first?.id }
        var evidence: [String: Double] = [:]
        let sentence = String(context.reversed().prefix(while: { !".!?\n".contains($0) }).reversed())
        let words = sentence.split(whereSeparator: \.isWhitespace).suffix(6).reversed()
        for (distance, raw) in words.enumerated() {
            let word = String(raw).trimmingCharacters(in: .punctuationCharacters)
            let matches = targets.compactMap { target -> (String, Int)? in
                rank(word, languages: target.languages).map { (target.id, $0) }
            }.sorted { $0.1 < $1.1 }
            guard let best = matches.first else { continue }
            let margin = matches.count > 1 ? log10(Double(matches[1].1) / Double(best.1)) : 2
            guard margin >= 0.9 else { continue }
            evidence[best.0, default: 0] += min(margin, 2) * pow(0.65, Double(distance))
        }
        let ordered = evidence.sorted { $0.value > $1.value }
        guard let best = ordered.first, best.value >= 0.6,
              best.value - (ordered.dropFirst().first?.value ?? 0) >= 0.6 else { return nil }
        return best.key
    }

    private static let wrappers: [Character: Character] = ["\"": "\"", "'": "'", "«": "»", "“": "”", "„": "“", "‘": "’", "(": ")"]

    public func convertTextManually(_ text: String, source: KeyboardLayout, target: KeyboardLayout,
                                    physicalKeys: [KeyboardLayout.KeyStroke]? = nil) -> String? {
        if !text.isEmpty, !text.contains(where: \.isLetter) {
            if let physicalKeys, source.render(physicalKeys) == text { return target.render(physicalKeys) }
            return source.convert(text, to: target)
        }
        if let address = WebAddress.converted(text, source: source, target: target) { return address }
        let sourceCyrillic = source.languages.contains(.russian) || source.languages.contains(.ukrainian)
        var output = "", word = ""
        func convertWord(_ input: String) -> String? {
            let full = source.convert(input, to: target)
            if let full, rank(full, languages: target.languages) != nil { return full }
            var core = input, length = input.count
            // Strip only as much literal punctuation as needed. A preceding dot
            // may still be the physical ю key (lzre.! → дякую!). A currency sign is
            // literal too: nsc$ → тыс$, not тыс%.
            while let last = core.last, WordText.suffixPunctuation.contains(last) || WordText.closingSymbols.contains(last) {
                core.removeLast(); length -= 1
                // No dictionary word is longer than 64: a long run of dots is not converted
                // and looked up again for every dot it loses.
                if length > 0, length <= 64, let translated = source.convert(core, to: target),
                   rank(translated, languages: target.languages) != nil {
                    return translated + input.dropFirst(core.count)
                }
            }
            // Quotes or brackets around a word keep their look: "ghbdtn" → "привет", not ЭприветЭ.
            if !sourceCyrillic, input.count > 2, let open = input.first, let close = input.last,
               Self.wrappers[open] == close,
               let inner = source.convert(String(input.dropFirst().dropLast()), to: target),
               rank(inner, languages: target.languages) != nil {
                return String(open) + inner + String(close)
            }
            if sourceCyrillic {
                var converted = ""
                let chars = Array(input)
                for (i, char) in chars.enumerated() {
                    let embedded = i > 0 && i + 1 < chars.count && chars[i-1].isLetter && chars[i+1].isLetter
                    let mapped = source.convert(String(char), to: target)
                    let apostrophe = WordText.apostrophes.contains(char) || mapped?.contains(where: { WordText.apostrophes.contains($0) }) == true
                    if char.isPunctuation && !(embedded && apostrophe) { converted += String(char) }
                    else { guard let mapped else { return nil }; converted += mapped }
                }
                return converted
            }
            return full
        }
        for character in text {
            if character.isWhitespace {
                guard let converted = convertWord(word) else { return nil }
                output += converted + String(character); word = ""
            } else { word.append(character) }
        }
        guard let converted = convertWord(word) else { return nil }
        return output + converted
    }

    public func convertManually(_ text: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                                preferredTargetID: String? = nil,
                                physicalKeys: [KeyboardLayout.KeyStroke]? = nil) -> Suggestion? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let sourceCyrillic = source.languages.contains(.russian) || source.languages.contains(.ukrainian)
        let sourceRecognized = words.contains {
            rank($0.trimmingCharacters(in: .punctuationCharacters), languages: source.languages) != nil
        }
        let available = layouts.filter { $0.id != source.id }
        let otherAlphabet = available.filter {
            let cyrillic = $0.languages.contains(.russian) || $0.languages.contains(.ukrainian)
            return cyrillic != sourceCyrillic
        }
        // An explicit conversion of already valid Cyrillic should produce Latin keystrokes,
        // rather than manufacturing a different RU/UK spelling that happens to be a word.
        let targets = sourceRecognized && !otherAlphabet.isEmpty ? otherAlphabet : available
        let allCandidates = targets.compactMap { target -> Suggestion? in
            guard let converted = convertTextManually(text, source: source, target: target, physicalKeys: physicalKeys) else { return nil }
            let score = words.reduce(0.0) { sum, word in
                guard let output = convertTextManually(word, source: source, target: target),
                      let rank = rank(output.trimmingCharacters(in: .punctuationCharacters), languages: target.languages) else { return sum }
                return sum + log10(50_001.0 / Double(rank))
            }
            return Suggestion(original: text, replacement: converted, target: target, score: score)
        }
        // A glyph shared by RU and UK must still change on the first tap when
        // another available layout gives a different glyph (e.g. % → $, п → g).
        let changed = allCandidates.filter { $0.replacement != text }
        let candidates = (changed.isEmpty ? allCandidates : changed).sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if ($0.target.id == preferredTargetID) != ($1.target.id == preferredTargetID) { return $0.target.id == preferredTargetID }
            let firstCyrillic = $0.target.languages.contains(.russian) || $0.target.languages.contains(.ukrainian)
            let secondCyrillic = $1.target.languages.contains(.russian) || $1.target.languages.contains(.ukrainian)
            if firstCyrillic != secondCyrillic {
                return sourceCyrillic != firstCyrillic
            }
            return $0.target.id < $1.target.id
        }
        guard let best = candidates.first else { return nil }
        return candidates.first(where: { $0.target.id == preferredTargetID && $0.replacement == best.replacement }) ?? best
    }

    public func suggest(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                        ignored: Set<String> = [], manual: Bool = false,
                        preferredTargetID: String? = nil, context: String = "") -> Suggestion? {
        suggest(word, source: source, layouts: layouts, ignored: ignored, manual: manual,
                preferredTargetID: preferredTargetID, context: context, live: false)
    }

    /// `live` marks an unfinished word: punctuation at its end may still become a letter.
    func suggest(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                 ignored: Set<String> = [], manual: Bool = false,
                 preferredTargetID: String? = nil, context: String = "", live: Bool) -> Suggestion? {
        guard !ignored.contains(word.lowercased()) else { return nil }
        if rank(word, languages: source.languages) == nil,
           let address = suggestAddress(word, source: source, layouts: layouts),
           manual || !isValidNativeText(word, source: source) { return address }
        guard (manual ? 1...128 : 1...64).contains(word.count),
              !word.contains(where: { $0.isNumber }),
              !word.contains(where: { "@/_=".contains($0) }) else { return nil }
        if !manual, word.count == 1 {
            return suggestSingleLetter(word, source: source, layouts: layouts,
                                      preferredTargetID: preferredTargetID, context: context)
        }
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return nil }
        // Preserve valid words. For two-letter strings, a rare dictionary abbreviation
        // (e.g. English "ns") alone is not enough to defeat a common pronoun in context.
        let validLanguages = source.languages
        let baseWord = WordText.coreAndSuffix(word).core
        let sourceRank = [rank(word, languages: validLanguages), rank(baseWord, languages: validLanguages)].compactMap { $0 }.min()
        let short = baseWord.count == 2
        // A recognized full word is evidence of deliberate native input, even when
        // rare (e.g. English herb). Frequency may resolve only short abbreviations.
        if !manual, let sourceRank, sourceRank <= 5_000 || baseWord.count >= 4 { return nil }
        // Avoid touching code identifiers and acronyms. Title case remains supported.
        // A finished word in capitals (HFCNDJHS → РАСТВОРЫ) may convert when it spells a
        // dictionary word; shorter capitals are usually acronyms.
        let capitals = letters.count > 1 && letters == letters.uppercased()
        let capitalWord = capitals && !live && letters.count >= 4
        if !manual {
            if capitals && !capitalWord { return nil }
            if !capitals && letters.dropFirst().contains(where: \.isUppercase) { return nil }
        }

        var candidates: [Suggestion] = []
        for target in layouts where target.id != source.id {
            guard let converted = source.convert(word, to: target), converted != word else { continue }
            // Judge the word without punctuation the target layout puts at its end: the Mac
            // Russian layout types , and . with Shift-6/7, which ABC renders as ^ and &.
            // Literal punctuation typed in the source (ымёя, → імʼя,) stays literal; the
            // fallback below keeps it as typed.
            let (convertedCore, convertedSuffix) = WordText.coreAndSuffix(converted)
            let typedSymbols = !convertedSuffix.isEmpty &&
                !word.suffix(convertedSuffix.count).contains(where: WordText.suffixPunctuation.contains)
            let dictionaryRank = rank(converted, languages: target.languages)
                ?? (typedSymbols && !convertedCore.isEmpty ? rank(convertedCore, languages: target.languages) : nil)
            let candidateRank: Int
            if let dictionaryRank { candidateRank = dictionaryRank }
            else if !live, sourceRank == nil, convertedSuffix.isEmpty || typedSymbols, convertedCore.count >= 5,
                    convertedCore.allSatisfy(\.isLetter) || (target.languages.contains(.ukrainian) && WordText.isOrthographicWord(convertedCore)),
                    SystemLexicon.shared.knows(convertedCore, languages: target.languages) {
                // A valid form outside the frequency list (медучреждениях): weak evidence,
                // below any dictionary word, so every ambiguity rule below still applies.
                // Never for an unfinished word: Павлови is the start of Павловичу, not Павловы.
                candidateRank = 30_000
            } else { continue }
            if !manual {
                let outputLetters = converted.filter(\.isLetter)
                let outputCapitals = outputLetters.count > 1 && outputLetters == outputLetters.uppercased()
                if outputCapitals && !(capitalWord && dictionaryRank.map { $0 <= 20_000 } == true) { continue }
                if !outputCapitals && outputLetters.dropFirst().contains(where: \.isUppercase) { continue }
            }
            let apostropheWord = target.languages.contains(.ukrainian) && converted.contains(where: { WordText.apostrophes.contains($0) }) && WordText.isOrthographicWord(converted)
            let maxRank = manual || apostropheWord ? 50_000 : (word.count == 2 ? 2_000 : (word.count == 3 ? 4_000 : 50_000))
            guard candidateRank <= maxRank else { continue }
            let score = log10(50_001.0 / Double(candidateRank))
            candidates.append(Suggestion(original: word, replacement: converted, target: target, score: score))
        }
        // Unknown compounds are a fallback only: preserve all exact dictionary
        // decisions, recognized source words and RU/UK language disambiguation.
        // Only Cyrillic → Latin qualifies; never invent Cyrillic words by splitting.
        if candidates.isEmpty, sourceRank == nil, !capitals,
           source.languages.contains(where: { $0 == .russian || $0 == .ukrainian }) {
            for target in layouts where target.id != source.id &&
                !target.languages.contains(where: { $0 == .russian || $0 == .ukrainian }) {
                guard let converted = source.convert(word, to: target), converted != word,
                      isCommonLatinCompound(converted, languages: target.languages) else { continue }
                // Keep inferred compounds below strong dictionary evidence. Automatic
                // case/identifier protection above still applies; manual Shift remains
                // available for arbitrary words through convertManually.
                candidates.append(Suggestion(original: word, replacement: converted, target: target,
                                             score: log10(50_001.0 / 40_000.0)))
            }
        }
        // The spelling service knows inflections the frequency list lacks (песках,
        // aufgetretene). Asked only once some conversion is on the table: it is slow.
        if !manual, !candidates.isEmpty, sourceRank == nil, baseWord.count >= 4,
           SystemLexicon.shared.knows(baseWord, languages: validLanguages) { return nil }
        // Between RU and UK the same keys spell both languages: a name or form missing
        // from the list (Анатолій) stays when the sentence so far is in the source language.
        if !manual, sourceRank == nil, Self.isCyrillic(source),
           candidates.contains(where: { Self.isCyrillic($0.target) }),
           contextPreference(context, targets: [source] + candidates.map(\.target)) == source.id {
            candidates.removeAll { Self.isCyrillic($0.target) }
        }
        candidates.sort { $0.score > $1.score }
        guard let best = candidates.first else {
            // A punctuation key may itself represent a Cyrillic letter (e.g. . → ю).
            // Try the complete key sequence first; only then treat punctuation as a suffix.
            // Peel one suffix character at a time. In lzre.! the period belongs
            // to the physical Ukrainian word (ю), whereas ! is punctuation.
            // While typing, the punctuation may still be a letter key (Nfr; → Такж…).
            let core = word.last.map { ".,!?;:…\"'’)]}".contains($0) } == true ? String(word.dropLast()) : word
            if !live, !core.isEmpty, core != word,
               let inner = suggest(core, source: source, layouts: layouts, ignored: ignored, manual: manual,
                                   preferredTargetID: preferredTargetID, context: context) {
                return Suggestion(original: word, replacement: inner.replacement + word.dropFirst(core.count),
                                  target: inner.target, score: inner.score)
            }
            return nil
        }
        if !manual, sourceRank != nil,
           source.languages.contains(where: { $0 == .russian || $0 == .ukrainian }) {
            let original = Suggestion(original: word, replacement: word, target: source, score: 0)
            let contextual = contextualPreference(context, candidates: candidates + [original])
            if contextual == source.id { return nil }
            if baseWord.count >= 4, contextual != best.target.id { return nil }
        }
        if !manual, let sourceRank,
           let targetRank = rank(best.replacement, languages: best.target.languages),
           (targetRank > 2_000 || Double(sourceRank) / Double(targetRank) < (short ? 40 : 20)) { return nil }
        let preference = contextualPreference(context, candidates: candidates) ?? preferredTargetID
        // Identical output in RU/UK is not a reason to change an already active Cyrillic layout.
        let differentOutputs = candidates.filter { $0.replacement != best.replacement }
        if !manual, let second = differentOutputs.first, best.score - second.score < 0.9 {
            // Only resolve near-tied Cyrillic alternatives with an actual language preference.
            // A Latin/Cyrillic ambiguity must still be left alone.
            if candidates.allSatisfy({ $0.target.languages.contains(.russian) || $0.target.languages.contains(.ukrainian) }),
               let preferred = candidates.first(where: { $0.target.id == preference && best.score - $0.score < 0.9 }) {
                return preferred
            }
            return nil
        }
        if let preferred = candidates.first(where: {
            $0.replacement == best.replacement && $0.target.id == preference
        }) { return preferred }
        if !manual, candidates.contains(where: {
            $0.replacement == best.replacement && $0.target.languages != best.target.languages
        }) { return nil }
        return best
    }

    static func isCyrillic(_ layout: KeyboardLayout) -> Bool {
        layout.languages.contains { $0 == .russian || $0 == .ukrainian }
    }

    /// A Cyrillic word whose ю key happens to spell a domain (действующее → ltqcnde.ott,
    /// звертаюсь → pdthnf.cm) is text, not an address.
    private func isValidNativeText(_ word: String, source: KeyboardLayout) -> Bool {
        guard source.languages.contains(where: { $0 == .russian || $0 == .ukrainian }) else { return false }
        let core = WordText.coreAndSuffix(word).core
        guard core.count >= 2, core.allSatisfy(\.isLetter) else { return false }
        // Either Cyrillic language: a Russian word may be typed on the Ukrainian layout.
        let languages: [Language] = [.russian, .ukrainian]
        return rank(core, languages: languages) != nil || SystemLexicon.shared.knows(core, languages: languages)
    }

    /// While a word is still being typed only an unmistakable address converts. A
    /// bare name.tld with a two-letter TLD may be the start of a word whose ю key
    /// made the dot (зароютс → pfhj.nc), so it waits for Space.
    private static func isExplicitAddress(_ output: String) -> Bool {
        let lower = output.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") || lower.contains("/") { return true }
        let host = lower.prefix(while: { !":/?#".contains($0) })
        let labels = host.split(separator: ".")
        return labels.count >= 3 || (labels.last?.count ?? 0) >= 3 ||
            host.contains(where: { $0.isNumber || $0 == "-" })
    }

    private func suggestAddress(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout]) -> Suggestion? {
        guard word.count <= 512 else { return nil }
        for target in layouts where target.id != source.id {
            if let output = WebAddress.converted(word, source: source, target: target) {
                return Suggestion(original: word, replacement: output, target: target, score: 5)
            }
        }
        return nil
    }

    /// A native word may still be incomplete. Do not switch its recognized prefixes
    /// into a foreign word while the user is continuing to type.
    private func isNativePrefix(_ word: String, languages: [Language]) -> Bool {
        let prefix = WordText.canonical(word.lowercased())
        return languages.contains { language in
            guard let words = sortedWords[language] else { return false }
            let low = prefixStart(prefix, in: words)
            return low < words.count && words[low].hasPrefix(prefix)
        }
    }

    private func prefixStart(_ prefix: String, in words: [String]) -> Int {
        var low = 0, high = words.count
        while low < high {
            let middle = low + (high - low) / 2
            if words[middle] < prefix { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// A partial word is weaker evidence than an exact match. Require at least two
    /// common completions in one language, and use it only during live typing.
    /// Return the typed prefix unchanged in length, never an invented completion.
    private func suggestPrefixWhileTyping(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                                          ignored: Set<String>, preferredTargetID: String?, context: String = "") -> Suggestion? {
        let letters = word.filter(\.isLetter)
        guard (4...32).contains(word.count), letters.count >= 4,
              letters != letters.uppercased(), !letters.dropFirst().contains(where: \.isUppercase),
              !word.contains(where: { $0.isNumber || "@/_=".contains($0) }) else { return nil }
        let sourceCyrillic = source.languages.contains { $0 == .russian || $0 == .ukrainian }
        var candidates: [Suggestion] = []
        for target in layouts where target.id != source.id {
            let targetCyrillic = target.languages.contains { $0 == .russian || $0 == .ukrainian }
            guard sourceCyrillic != targetCyrillic,
                  let converted = source.convert(word, to: target), converted != word,
                  converted.allSatisfy(\.isLetter), !ignored.contains(converted.lowercased()),
                  rank(converted, languages: target.languages) == nil else { continue }
            let prefix = WordText.canonical(converted.lowercased())
            let confident = target.languages.contains { language in
                guard let words = sortedWords[language], let ranks = ranks[language] else { return false }
                var index = prefixStart(prefix, in: words), matches = 0
                while index < words.count, words[index].hasPrefix(prefix) {
                    if let rank = ranks[words[index]], rank <= 10_000 {
                        matches += 1
                        if matches == 2 { return true }
                    }
                    index += 1
                }
                return false
            }
            if confident { candidates.append(Suggestion(original: word, replacement: converted, target: target, score: 0)) }
        }
        let preference = contextualPreference(context, candidates: candidates) ?? preferredTargetID
        if let preferred = candidates.first(where: { $0.target.id == preference }) { return preferred }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Text typed on a Ukrainian layout is not switched to Russian while the word is typed,
    /// only once it is complete: a correct Ukrainian form the frequency list lacks (Включіть)
    /// starts like a Russian word (Включит, Включи). Ukrainian typed on the Russian layout
    /// (памъять) still switches early.
    private func liveTargets(_ layouts: [KeyboardLayout], source: KeyboardLayout) -> [KeyboardLayout] {
        guard source.languages.contains(.ukrainian) else { return layouts }
        return layouts.filter { !$0.languages.contains(.russian) }
    }

    public func suggestWhileTyping(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                                   ignored: Set<String> = [], preferredTargetID: String? = nil,
                                   context: String = "", spellingAware: Bool = false) -> Suggestion? {
        let layouts = liveTargets(layouts, source: source)
        guard word.count >= 4, !ignored.contains(word.lowercased()) else { return nil }
        guard !isNativePrefix(word, languages: source.languages) else { return nil }
        if let address = suggestAddress(word, source: source, layouts: layouts) {
            return Self.isExplicitAddress(address.replacement) && !isValidNativeText(word, source: source) ? address : nil
        }
        let exact = suggest(word, source: source, layouts: layouts, ignored: ignored,
                            preferredTargetID: preferredTargetID, context: context, live: true)
        guard let result = exact
            ?? suggestPrefixWhileTyping(word, source: source, layouts: layouts, ignored: ignored,
                                        preferredTargetID: preferredTargetID, context: context) else { return nil }
        // For prefixes, block native typos that the spelling engine could repair.
        // Rare neighbors outside its 20k ceiling (bpex → apex/bex) must not defeat
        // two common target completions. Exact-word ambiguity keeps its old rule.
        if spellingAware, hasNativeSpellingAlternative(word, source: source, replacement: result.replacement,
                                                       maxRank: exact == nil ? 20_000 : .max) { return nil }
        if let preferredTargetID, result.target.id != preferredTargetID,
           let preferred = layouts.first(where: { $0.id == preferredTargetID }),
           preferred.languages.contains(where: { $0 == .russian || $0 == .ukrainian }),
           result.target.languages.contains(where: { $0 == .russian || $0 == .ukrainian }),
           let alternative = source.convert(word, to: preferred),
           isNativePrefix(alternative, languages: preferred.languages) { return nil }
        return result
    }

    public func maySuggestWhileTyping(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                                      ignored: Set<String> = [], spellingAware: Bool = false) -> Bool {
        let layouts = liveTargets(layouts, source: source)
        guard word.count >= 4, !ignored.contains(word.lowercased()),
              !isNativePrefix(word, languages: source.languages) else { return false }
        if let address = suggestAddress(word, source: source, layouts: layouts) {
            return Self.isExplicitAddress(address.replacement) && !isValidNativeText(word, source: source)
        }
        var nativeAlternative: Bool?
        var prefixNativeAlternative: Bool?
        let suffix = WordText.coreAndSuffix(word).suffix
        return layouts.contains { target in
            guard target.id != source.id else { return false }
            let exact = suggest(word, source: source, layouts: layouts, ignored: ignored,
                                preferredTargetID: target.id, live: true)
            guard let result = exact
                    ?? suggestPrefixWhileTyping(word, source: source, layouts: layouts, ignored: ignored,
                                                preferredTargetID: target.id) else { return false }
            if spellingAware, suffix.isEmpty || result.replacement.hasSuffix(suffix) {
                if exact == nil {
                    if prefixNativeAlternative == nil {
                        prefixNativeAlternative = hasNativeSpellingAlternative(word, source: source,
                            replacement: result.replacement, maxRank: 20_000)
                    }
                    if prefixNativeAlternative == true { return false }
                } else {
                    if nativeAlternative == nil {
                        nativeAlternative = hasNativeSpellingAlternative(word, source: source, replacement: result.replacement)
                    }
                    if nativeAlternative == true { return false }
                }
            }
            if result.target.id != target.id,
               target.languages.contains(where: { $0 == .russian || $0 == .ukrainian }),
               result.target.languages.contains(where: { $0 == .russian || $0 == .ukrainian }),
               let alternative = source.convert(word, to: target), isNativePrefix(alternative, languages: target.languages) {
                return false
            }
            return true
        }
    }

    /// Typing stopped on a word too short to switch while it is typed. A search field
    /// (Countries on Unity: гыф → usa) gets no Space to check it, so it is checked as a
    /// complete word, unless it may still grow into a native word (рус → руслан).
    public func suggestAfterPause(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                                  ignored: Set<String> = [], preferredTargetID: String? = nil,
                                  context: String = "") -> Suggestion? {
        guard (2...3).contains(word.count), !isNativePrefix(word, languages: source.languages) else { return nil }
        return suggest(word, source: source, layouts: liveTargets(layouts, source: source), ignored: ignored,
                       preferredTargetID: preferredTargetID, context: context, live: true)
    }

    public func maySuggestAfterPause(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                                     ignored: Set<String> = []) -> Bool {
        layouts.contains { target in
            target.id != source.id && suggestAfterPause(word, source: source, layouts: layouts,
                                                        ignored: ignored, preferredTargetID: target.id) != nil
        }
    }

    /// Frequency corpora include initials (b, f, z). Only actual one-letter words
    /// count here; valid source words remain unchanged, including English a and I.
    private func suggestSingleLetter(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                                     preferredTargetID: String?, context: String) -> Suggestion? {
        func isWord(_ value: String, in languages: [Language]) -> Bool {
            languages.contains { language in
                switch language {
                case .english: return value == "a" || value == "A" || value == "I"
                case .german: return false
                case .russian: return "яиауксвзо".contains(value.lowercased())
                case .ukrainian: return "яіауйвзсоє".contains(value.lowercased())
                }
            }
        }
        guard word.first?.isLetter == true, !isWord(word, in: source.languages) else { return nil }
        let candidates = layouts.compactMap { target -> Suggestion? in
            guard target.id != source.id, let output = source.convert(word, to: target),
                  output != word, isWord(output, in: target.languages) else { return nil }
            return Suggestion(original: word, replacement: output, target: target, score: 1)
        }
        // An initial inside English text (D, P) stays when the context is the source language.
        // Lowercase b, z, f are not words there either: they are и, я, а typed in the wrong layout.
        if word.first?.isUppercase == true, !candidates.isEmpty,
           contextPreference(context, targets: [source] + candidates.map(\.target)) == source.id { return nil }
        let preference = contextualPreference(context, candidates: candidates) ?? preferredTargetID
        if let preferred = candidates.first(where: { $0.target.id == preference }) { return preferred }
        return candidates.count == 1 ? candidates.first : nil
    }
}
