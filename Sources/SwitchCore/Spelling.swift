import Foundation

extension Detector {
    /// Spelling is deliberately a completed-word operation. It never sees prefixes
    /// through suggestWhileTyping and can be disabled independently of layout repair.
    public func suggestCompleted(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                                 ignored: Set<String> = [], preferredTargetID: String? = nil,
                                 context: String = "", correctSpelling: Bool = false) -> Suggestion? {
        if let layout = suggest(word, source: source, layouts: layouts, ignored: ignored,
                                preferredTargetID: preferredTargetID, context: context) {
            if correctSpelling, hasNativeSpellingAlternative(word, source: source, replacement: layout.replacement) {
                // Text alone cannot distinguish a native typo from a valid foreign
                // word. Context wins; an explicit target preference can resolve a tie.
                let contextual = contextPreference(context, targets: [source, layout.target])
                if contextual == layout.target.id || (contextual == nil && preferredTargetID == layout.target.id) { return layout }
                if contextual == source.id {
                    return suggestSpelling(word, source: source, layouts: [source], ignored: ignored,
                                           preferredTargetID: source.id, context: context)
                }
                return nil
            }
            return layout
        }
        guard correctSpelling else { return nil }
        return suggestSpelling(word, source: source, layouts: layouts, ignored: ignored,
                               preferredTargetID: preferredTargetID, context: context)
    }

    func hasNativeSpellingAlternative(_ word: String, source: KeyboardLayout, replacement: String,
                                      maxRank: Int = .max) -> Bool {
        let (core, suffix) = WordText.coreAndSuffix(word)
        // A symbol at the end may encode a letter, e.g. lzre. → дякую.
        // It is a literal suffix only when the layout result preserves it too.
        guard suffix.isEmpty || replacement.hasSuffix(suffix) else { return false }
        guard (4...32).contains(core.count), WordText.isOrthographicWord(core),
              rank(core, languages: source.languages) == nil else { return false }
        return hasSpellingNeighbor(WordText.canonical(core.lowercased()), languages: source.languages, maxRank: maxRank)
    }

    public func maySuggestCompleted(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                                    ignored: Set<String> = [], correctSpelling: Bool = false) -> Bool {
        if maySuggest(word, source: source, layouts: layouts, ignored: ignored) { return true }
        guard correctSpelling else { return false }
        return spellingSuggestion(word, source: source, layouts: layouts, ignored: ignored,
                                  allowUnresolvedPreference: true) != nil
    }

    public func suggestSpelling(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                                ignored: Set<String> = [], preferredTargetID: String? = nil,
                                context: String = "") -> Suggestion? {
        spellingSuggestion(word, source: source, layouts: layouts, ignored: ignored,
                           preferredTargetID: preferredTargetID, context: context)
    }

    private func spellingSuggestion(_ word: String, source: KeyboardLayout, layouts: [KeyboardLayout],
                                    ignored: Set<String> = [], preferredTargetID: String? = nil,
                                    context: String = "", allowUnresolvedPreference: Bool = false) -> Suggestion? {
        guard !ignored.contains(word.lowercased()), word.count <= 40 else { return nil }
        let (rawCore, suffix) = WordText.coreAndSuffix(word)
        let core = WordText.canonical(rawCore)
        let letters = core.filter(\.isLetter)
        guard (5...32).contains(core.count), !letters.isEmpty,
              core.allSatisfy({ $0.isLetter || ",.;:'[]\\`".contains($0) }),
              letters != letters.uppercased(), !letters.dropFirst().contains(where: \.isUppercase),
              !WebAddress.recognizes(word) else { return nil }
        // Frequency corpora contain a few well-known misspellings. These authored
        // exceptions are distinct from valid-word confusions such as form/from.
        if let correction = Self.commonMisspellings[core.lowercased()],
           rank(correction, languages: source.languages) != nil,
           !ignored.contains(correction) {
            let text = core.first?.isUppercase == true ? correction.prefix(1).uppercased() + correction.dropFirst() : correction
            return Suggestion(original: word, replacement: text + suffix, target: source, score: 1)
        }
        guard rank(core, languages: source.languages) == nil else { return nil }
        struct Candidate {
            let text: String
            let target: KeyboardLayout
            let rank: Int
        }
        var candidates: [Candidate] = []
        for target in layouts {
            // Preserve the source alphabet first. Do not reinterpret ordinary Cyrillic
            // spelling mistakes as the other Cyrillic language without direct evidence.
            let sourceCyrillic = source.languages.contains { $0 == .russian || $0 == .ukrainian }
            let targetCyrillic = target.languages.contains { $0 == .russian || $0 == .ukrainian }
            if target.id != source.id && sourceCyrillic == targetCyrillic { continue }
            guard let rendered = target.id == source.id ? core : source.convert(core, to: target),
                  (rendered.allSatisfy(\.isLetter) || (target.languages.contains(.ukrainian) && WordText.isOrthographicWord(rendered))),
                  rank(rendered, languages: target.languages) == nil else { continue }
            for (text, frequency) in spellingNeighbors(WordText.canonical(rendered.lowercased()), languages: target.languages) {
                candidates.append(Candidate(text: text, target: target, rank: frequency))
            }
        }
        // Merge identical RU/UK output for probability comparison, retaining the chosen
        // layout only when context / explicit preference can resolve that ambiguity.
        candidates.sort { $0.rank == $1.rank ? ($0.text, $0.target.id) < ($1.text, $1.target.id) : $0.rank < $1.rank }
        guard let best = candidates.first, best.rank <= 20_000 else { return nil }
        // Frequency is not proof of intent: even a rare alternative can be the
        // intended inflection. Any other dictionary candidate means abstention.
        guard !candidates.contains(where: { $0.text != best.text }) else { return nil }
        let identical = candidates.filter { $0.text == best.text }
        let contextual = spellingContextPreference(context, candidates: identical.map(\.target)) ?? preferredTargetID
        let chosen: Candidate
        if let preferred = identical.first(where: { $0.target.id == contextual }) { chosen = preferred }
        else if allowUnresolvedPreference || Set(identical.map { $0.target.id }).count == 1 { chosen = best }
        else { return nil }
        let style = rawCore.first(where: { WordText.apostrophes.contains($0) }).map(String.init) ?? chosen.target.apostropheGlyph
        let styled = chosen.text.replacingOccurrences(of: "'", with: style)
        let output = core.first?.isUppercase == true ? styled.prefix(1).uppercased() + styled.dropFirst() : styled
        guard !ignored.contains(output.lowercased()), !ignored.contains(WordText.canonical(output.lowercased())) else { return nil }
        return Suggestion(original: word, replacement: output + suffix, target: chosen.target,
                          score: log10(50_001 / Double(chosen.rank)))
    }

    private static let commonMisspellings = [
        "recieve": "receive", "recieved": "received", "recieving": "receiving",
        "seperate": "separate", "seperately": "separately", "definately": "definitely",
        "occured": "occurred", "occurence": "occurrence", "untill": "until",
        "wierd": "weird", "beleive": "believe", "becuase": "because",
        "accomodation": "accommodation",
        "пожалуста": "пожалуйста", "пожалуйсто": "пожалуйста", "пожайлуста": "пожалуйста",
        "извените": "извините", "извени": "извини", "спосибо": "спасибо"
    ]

    private func spellingContextPreference(_ context: String, candidates: [KeyboardLayout]) -> String? {
        // Reuse the same language evidence as ordinary layout disambiguation.
        contextPreference(context, targets: candidates)
    }

    private static let alphabets: [Language: [Character]] = [
        .russian: Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюя"),
        .ukrainian: Array("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'"),
        .english: Array("abcdefghijklmnopqrstuvwxyz"),
        .german: Array("abcdefghijklmnopqrstuvwxyzäöüß")
    ]
    private static let latinAlphabet = Array("abcdefghijklmnopqrstuvwxyzäöüß")

    /// The visitor can stop as soon as existence is proved, without allocating a
    /// dictionary of every neighbor. Both existence and enumeration use this path.
    private func visitSpellingNeighbors(_ word: String, languages: [Language],
                                        visit: (String, Int) -> Bool) {
        let letters = Array(word)
        let alphabet = languages.count == 1 ? Self.alphabets[languages[0]]! : Self.latinAlphabet
        func consider(_ text: String) -> Bool {
            guard let frequency = rankLowercased(text, languages: languages) else { return false }
            return visit(text, frequency)
        }
        var buffer = letters
        for index in letters.indices {
            buffer.remove(at: index)
            if consider(String(buffer)) { return }
            buffer.insert(letters[index], at: index)
            if index + 1 < letters.count, letters[index] != letters[index + 1] {
                buffer.swapAt(index, index + 1)
                if consider(String(buffer)) { return }
                buffer.swapAt(index, index + 1)
            }
            for letter in alphabet where letter != letters[index] {
                buffer[index] = letter
                if consider(String(buffer)) { return }
            }
            buffer[index] = letters[index]
        }
        for index in 0...letters.count {
            buffer.insert(" ", at: index)
            for letter in alphabet {
                buffer[index] = letter
                if consider(String(buffer)) { return }
            }
            buffer.remove(at: index)
        }
    }

    private func hasSpellingNeighbor(_ word: String, languages: [Language], maxRank: Int) -> Bool {
        var found = false
        visitSpellingNeighbors(word, languages: languages) { _, rank in
            guard rank <= maxRank else { return false }
            found = true
            return true
        }
        return found
    }

    private func spellingNeighbors(_ word: String, languages: [Language]) -> [String: Int] {
        var found: [String: Int] = [:]
        visitSpellingNeighbors(word, languages: languages) { text, rank in found[text] = rank; return false }
        return found
    }
}
