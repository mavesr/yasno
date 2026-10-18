import Foundation

/// Orthographic apostrophes are part of words, rather than sentence delimiters.
enum WordText {
    static let suffixPunctuation = Set(".,!?;:…\"'’)]}")
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
}
