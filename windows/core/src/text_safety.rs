use crate::chars::{is_newline, is_whitespace};

pub fn has_left_boundary(context: &str) -> bool {
    match context.chars().last() {
        None => true,
        Some(p) => is_whitespace(p) || "([{\"«“„".contains(p),
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LastWord {
    pub text: String,
    pub trailing_utf16: usize,
}

/// A manual action can inspect the current line, never a preceding line or paragraph.
pub fn last_word(prefix: &str) -> Option<LastWord> {
    let line_start = prefix.char_indices().rev().find(|&(_, c)| is_newline(c)).map(|(i, c)| i + c.len_utf8()).unwrap_or(0);
    let line = &prefix[line_start..];
    let trimmed = line.trim_end_matches(is_whitespace);
    let word_start = trimmed.char_indices().rev().find(|&(_, c)| is_whitespace(c)).map(|(i, c)| i + c.len_utf8()).unwrap_or(0);
    let word = &trimmed[word_start..];
    if word.is_empty() { return None; }
    let trailing = line[trimmed.len()..].encode_utf16().count();
    Some(LastWord { text: word.to_string(), trailing_utf16: trailing })
}

/// After a click/arrow/selection replacement, only the freshly typed fragment
/// belongs to this action if existing word characters surround it.
pub fn manual_word(prefix: &str, recent_text: Option<&str>, recent_suffix: &str, right_context: &str) -> Option<LastWord> {
    let last = last_word(prefix)?;
    if let Some(recent) = recent_text {
        let right_word = right_context.chars().next().is_some_and(|c| c.is_alphabetic() || c.is_numeric());
        if !recent.is_empty() && recent_suffix.is_empty() && prefix.ends_with(recent) && (last.text != recent || right_word) {
            return Some(LastWord { text: recent.to_string(), trailing_utf16: 0 });
        }
    }
    Some(last)
}
