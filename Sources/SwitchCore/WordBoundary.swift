import Foundation

public enum WordBoundary {
    /// contenteditable uses NBSP at line ends to preserve a typed space in HTML.
    public static func matches(_ actual: String, word: String, suffix: String) -> Bool {
        if actual == word + suffix { return true }
        guard !suffix.isEmpty, suffix.allSatisfy({ $0 == " " }) else { return false }
        let normalized = actual.replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{202f}", with: " ")
        return normalized == word + suffix
    }
}
