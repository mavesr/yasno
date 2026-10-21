import Foundation

/// An edit made with Backspace and typed text, for fields that never expose their text
/// (Google Docs and Slides draw the document themselves and type into a hidden field).
/// Only what was just typed is erased: the common prefix (an opening symbol, an unchanged
/// start of the word) stays, so text the user typed before is never touched.
public struct KeystrokeEdit: Equatable {
    /// Characters erased before the caret, one Backspace each.
    public let deletions: Int
    public let insertion: String

    public init(deletions: Int, insertion: String) {
        self.deletions = deletions; self.insertion = insertion
    }

    public init?(typed: String, replacement: String, suffix: String = "") {
        guard !typed.isEmpty, !replacement.isEmpty else { return nil }
        // Another layout writes the same text (Russian and Ukrainian): nothing to retype,
        // but the edit still succeeds so that a Shift cycle moves on to the next layout.
        guard typed != replacement else { deletions = 0; insertion = ""; return }
        let common = zip(typed, replacement).prefix { $0 == $1 }.count
        deletions = typed.count - common + suffix.count
        insertion = String(replacement.dropFirst(common)) + suffix
    }
}
