//! Character classes with the meaning Swift's `Character` properties have, so that the
//! ported rules see letters, punctuation and numbers exactly as the Mac version does.

use unicode_general_category::{get_general_category, GeneralCategory as G};

/// Swift `Character.isLetter`: the Alphabetic property.
pub fn is_letter(c: char) -> bool { c.is_alphabetic() }

/// Swift `Character.isPunctuation` / `CharacterSet.punctuationCharacters`: category P*.
pub fn is_punctuation(c: char) -> bool {
    matches!(get_general_category(c),
        G::ConnectorPunctuation | G::DashPunctuation | G::OpenPunctuation | G::ClosePunctuation |
        G::InitialPunctuation | G::FinalPunctuation | G::OtherPunctuation)
}

/// Swift `Character.isNumber`: categories Nd, Nl, No.
pub fn is_number(c: char) -> bool { c.is_numeric() }

pub fn is_uppercase(c: char) -> bool { c.is_uppercase() }

pub fn is_whitespace(c: char) -> bool { c.is_whitespace() }

/// Swift `Character.isNewline`.
pub fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `CharacterSet.letters`: categories L* and M*.
pub fn is_letter_or_mark(c: char) -> bool {
    matches!(get_general_category(c),
        G::UppercaseLetter | G::LowercaseLetter | G::TitlecaseLetter | G::ModifierLetter | G::OtherLetter |
        G::NonspacingMark | G::SpacingMark | G::EnclosingMark)
}

/// `CharacterSet.controlCharacters`: categories Cc and Cf.
pub fn is_control(c: char) -> bool {
    matches!(get_general_category(c), G::Control | G::Format)
}

pub fn count(s: &str) -> usize { s.chars().count() }

pub fn letters(s: &str) -> String { s.chars().filter(|&c| is_letter(c)).collect() }

pub fn upper(s: &str) -> String { s.to_uppercase() }
pub fn lower(s: &str) -> String { s.to_lowercase() }

/// Swift `trimmingCharacters(in: .punctuationCharacters)`.
pub fn trim_punctuation(s: &str) -> &str { s.trim_matches(is_punctuation) }

/// First character uppercased, rest unchanged (Swift `prefix(1).uppercased() + dropFirst()`).
pub fn capitalize_first(s: &str) -> String {
    let mut it = s.chars();
    match it.next() {
        Some(first) => first.to_uppercase().collect::<String>() + it.as_str(),
        None => String::new(),
    }
}

/// The text without its first `n` characters.
pub fn drop_first(s: &str, n: usize) -> &str {
    match s.char_indices().nth(n) { Some((i, _)) => &s[i..], None => "" }
}

/// The text without its last `n` characters.
pub fn drop_last(s: &str, n: usize) -> &str {
    let total = count(s);
    if n >= total { return ""; }
    match s.char_indices().nth(total - n) { Some((i, _)) => &s[..i], None => s }
}

/// The last `n` characters.
pub fn suffix(s: &str, n: usize) -> &str {
    let total = count(s);
    if n >= total { return s; }
    drop_first(s, total - n)
}

/// The first `n` characters.
pub fn prefix(s: &str, n: usize) -> &str {
    match s.char_indices().nth(n) { Some((i, _)) => &s[..i], None => s }
}
