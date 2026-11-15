//! Orthographic apostrophes are part of words, rather than sentence delimiters.

use crate::chars::is_letter;

pub const SUFFIX_PUNCTUATION: &str = ".,!?;:…\"'’)]}";
/// Symbols that open a word (/команда, «цитата, #тег) without being part of it.
pub const PREFIX_PUNCTUATION: &str = "/\\([{«\"„“‘'*#-";
pub const APOSTROPHES: &str = "'’ʼ‘";
/// Currency signs after a word (тыс$) are meant as typed: no layout puts them elsewhere.
pub const CLOSING_SYMBOLS: &str = "$€£₽¥¢";

pub fn is_suffix_punctuation(c: char) -> bool { SUFFIX_PUNCTUATION.contains(c) }
pub fn is_prefix_punctuation(c: char) -> bool { PREFIX_PUNCTUATION.contains(c) }
pub fn is_apostrophe(c: char) -> bool { APOSTROPHES.contains(c) }
pub fn is_closing_symbol(c: char) -> bool { CLOSING_SYMBOLS.contains(c) }

pub fn canonical(text: &str) -> String {
    if !text.chars().any(|c| c != '\'' && is_apostrophe(c)) { return text.to_string(); }
    text.chars().map(|c| if is_apostrophe(c) { '\'' } else { c }).collect()
}

pub fn core_and_suffix(text: &str) -> (&str, &str) {
    let core = text.trim_end_matches(is_suffix_punctuation);
    (core, &text[core.len()..])
}

pub fn is_orthographic_word(text: &str) -> bool {
    let chars: Vec<char> = text.chars().collect();
    if chars.is_empty() { return false; }
    for (i, &c) in chars.iter().enumerate() {
        if is_apostrophe(c) {
            if !(i > 0 && i + 1 < chars.len() && is_letter(chars[i - 1]) && is_letter(chars[i + 1])) { return false; }
        } else if !is_letter(c) { return false; }
    }
    true
}

/// One insertion, deletion, substitution or swap of neighbouring letters.
pub fn is_one_edit(a: &str, b: &str) -> bool {
    let x: Vec<char> = a.chars().collect();
    let y: Vec<char> = b.chars().collect();
    if x == y { return false; }
    if x.len() == y.len() {
        let diff: Vec<usize> = (0..x.len()).filter(|&i| x[i] != y[i]).collect();
        if diff.len() == 1 { return true; }
        return diff.len() == 2 && diff[1] == diff[0] + 1 && x[diff[0]] == y[diff[1]] && x[diff[1]] == y[diff[0]];
    }
    let (long, short) = if x.len() > y.len() { (&x, &y) } else { (&y, &x) };
    if long.len() != short.len() + 1 { return false; }
    let mut i = 0;
    while i < short.len() && long[i] == short[i] { i += 1; }
    long[i + 1..] == short[i..]
}
