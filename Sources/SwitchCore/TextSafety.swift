import Foundation

public enum TextSafety {
    public static func hasLeftBoundary(_ context: String) -> Bool {
        guard let previous = context.last else { return true }
        return previous.isWhitespace || "([{\"«“„".contains(previous)
    }

    /// Read exact UTF-16 coordinates or refuse them; never silently expand an edit range.
    public static func substring(_ text: String, location: Int, length: Int) -> String? {
        guard location >= 0, length >= 0, location <= text.utf16.count,
              length <= text.utf16.count - location,
              let range = Range(NSRange(location: location, length: length), in: text) else { return nil }
        // NSString expands some empty ranges to the following composed character.
        // An empty read at a real caret boundary is valid; inside a grapheme it is not.
        if length == 0 {
            return range.lowerBound == text.endIndex || text.indices.contains(range.lowerBound) ? "" : nil
        }
        let exact = NSRange(location: location, length: length)
        guard NSEqualRanges((text as NSString).rangeOfComposedCharacterSequences(for: exact), exact) else { return nil }
        return String(text[range])
    }

    public struct LastWord {
        public let text: String
        public let trailingUTF16: Int
    }

    /// A manual action can inspect the current line, never a preceding line or paragraph.
    public static func lastWord(onCurrentLine prefix: String) -> LastWord? {
        let line = prefix.reversed().prefix(while: { !$0.isNewline })
        let trimmed = line.drop(while: { $0.isWhitespace })
        let word = String(trimmed.prefix(while: { !$0.isWhitespace }).reversed())
        guard !word.isEmpty else { return nil }
        let trailing = String(line).utf16.count - String(trimmed).utf16.count
        return LastWord(text: word, trailingUTF16: trailing)
    }

    /// After a click/arrow/selection replacement, only the freshly typed fragment
    /// belongs to this action if existing word characters surround it.
    public static func manualWord(onCurrentLine prefix: String, recentText: String? = nil,
                                  recentSuffix: String = "", rightContext: String = "") -> LastWord? {
        guard let last = lastWord(onCurrentLine: prefix) else { return nil }
        if let recentText, !recentText.isEmpty, recentSuffix.isEmpty, prefix.hasSuffix(recentText),
           last.text != recentText || rightContext.first.map({ $0.isLetter || $0.isNumber }) == true {
            return LastWord(text: recentText, trailingUTF16: 0)
        }
        return last
    }
}
