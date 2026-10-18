import Foundation
import SwitchCore

/// Independent view of what a one-edit spelling corrector can know. It finds every
/// dictionary word at Damerau–Levenshtein distance one through a deletion index,
/// not by generating neighbours as the engine does, so an engine bug in candidate
/// generation shows up as a disagreement instead of being repeated here.
final class SpellingOracle {
    enum Verdict: String {
        /// The typed text is itself a dictionary word: nothing to correct.
        case validWord = "valid-word"
        /// The intended word is the only dictionary word one edit away.
        case recoverable
        /// A single different word is one edit away: a corrector would pick it.
        case misleading
        /// Several words are one edit away, the intended one among them.
        case ambiguous
        /// The intended word is not one edit away or not in the dictionary.
        case unreachable
    }

    private let ranks: [String: Int]
    private let index: [String: [String]]

    init(ranks: [String: Int]) {
        self.ranks = ranks
        var index: [String: [String]] = [:]
        index.reserveCapacity(ranks.count * 8)
        for word in ranks.keys {
            for key in Self.deletions(word) { index[key, default: []].append(word) }
        }
        self.index = index
    }

    convenience init(detector: Detector, languages: [Language]) {
        var merged: [String: Int] = [:]
        for language in languages {
            for (word, rank) in detector.vocabulary(language) where merged[word].map({ rank < $0 }) ?? true {
                merged[word] = rank
            }
        }
        self.init(ranks: merged)
    }

    func rank(_ word: String) -> Int? { ranks[word.lowercased()] }

    /// All dictionary words one edit from the text, with ranks, most frequent first.
    func neighbours(_ text: String) -> [(word: String, rank: Int)] {
        let query = text.lowercased()
        var found: Set<String> = []
        for word in index[query] ?? [] { found.insert(word) }                      // a letter was left out
        for deletion in Self.deletions(query) {
            if ranks[deletion] != nil { found.insert(deletion) }                    // a letter was added
            for word in index[deletion] ?? [] where Self.isOneEdit(query, word) {   // replaced or swapped
                found.insert(word)
            }
        }
        found.remove(query)
        return found.compactMap { word in ranks[word].map { (word, $0) } }
            .sorted { $0.rank == $1.rank ? $0.word < $1.word : $0.rank < $1.rank }
    }

    func verdict(typed: String, intended: String) -> Verdict {
        if ranks[typed.lowercased()] != nil { return .validWord }
        let candidates = neighbours(typed)
        let target = intended.lowercased()
        guard candidates.contains(where: { $0.word == target }) else {
            return candidates.count == 1 ? .misleading : .unreachable
        }
        return candidates.count == 1 ? .recoverable : .ambiguous
    }

    static func deletions(_ word: String) -> [String] {
        let characters = Array(word)
        guard characters.count > 1 else { return [] }
        return characters.indices.map { i in
            var copy = characters; copy.remove(at: i); return String(copy)
        }
    }

    /// Exact optimal-string-alignment distance of one: substitution or adjacent swap
    /// between equal-length words.
    static func isOneEdit(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard x.count == y.count, x != y else { return false }
        let diff = x.indices.filter { x[$0] != y[$0] }
        if diff.count == 1 { return true }
        return diff.count == 2 && diff[1] == diff[0] + 1 && x[diff[0]] == y[diff[1]] && x[diff[1]] == y[diff[0]]
    }
}
