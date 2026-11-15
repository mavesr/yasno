/// An edit made with Backspace and typed text. On Windows this is the main way to replace
/// a word: it works in every field. Only what was just typed is erased: the common prefix
/// (an opening symbol, an unchanged start of the word) stays, so text the user typed
/// before is never touched.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeystrokeEdit {
    /// Characters erased before the caret, one Backspace each.
    pub deletions: usize,
    pub insertion: String,
}

impl KeystrokeEdit {
    pub fn new(typed: &str, replacement: &str, suffix: &str) -> Option<Self> {
        if typed.is_empty() || replacement.is_empty() { return None; }
        // Another layout writes the same text (Russian and Ukrainian): nothing to retype,
        // but the edit still succeeds so that a Shift cycle moves on to the next layout.
        if typed == replacement { return Some(KeystrokeEdit { deletions: 0, insertion: String::new() }); }
        let common = typed.chars().zip(replacement.chars()).take_while(|(a, b)| a == b).count();
        let deletions = typed.chars().count() - common + suffix.chars().count();
        let insertion: String = replacement.chars().skip(common).chain(suffix.chars()).collect();
        Some(KeystrokeEdit { deletions, insertion })
    }
}
