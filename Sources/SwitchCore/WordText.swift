import Foundation

/// Orthographic apostrophes are part of words, rather than sentence delimiters.
enum WordText {
    static let suffixPunctuation = Set(".,!?;:…\"'’)]}")
    /// Symbols that open a word (/команда, «цитата, #тег) without being part of it.
    static let prefixPunctuation = Set("/\\([{«\"„“‘'*#-")
    static let apostrophes = Set("'’ʼ‘")

    static func canonical(_ text: String) -> String {
        guard text.contains(where: { $0 != "'" && apostrophes.contains($0) }) else { return text }
        return String(text.map { apostrophes.contains($0) ? "'" : $0 })
    }

    static func coreAndSuffix(_ text: String) -> (core: String, suffix: String) {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard suffixPunctuation.contains(text[previous]) else { break }
            end = previous
        }
        return (String(text[..<end]), String(text[end...]))
    }

    static func isOrthographicWord(_ text: String) -> Bool {
        let chars = Array(text)
        guard !chars.isEmpty else { return false }
        for (i, char) in chars.enumerated() {
            if apostrophes.contains(char) {
                guard i > 0, i + 1 < chars.count, chars[i-1].isLetter, chars[i+1].isLetter else { return false }
            } else if !char.isLetter { return false }
        }
        return true
    }

    /// One insertion, deletion, substitution or swap of neighbouring letters.
    static func isOneEdit(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if x == y { return false }
        if x.count == y.count {
            let diff = x.indices.filter { x[$0] != y[$0] }
            if diff.count == 1 { return true }
            return diff.count == 2 && diff[1] == diff[0] + 1 && x[diff[0]] == y[diff[1]] && x[diff[1]] == y[diff[0]]
        }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        guard long.count == short.count + 1 else { return false }
        var i = 0
        while i < short.count, long[i] == short[i] { i += 1 }
        return Array(long[(i + 1)...]) == Array(short[i...])
    }
}
