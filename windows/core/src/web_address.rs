//! Syntax recognition only. Never resolves a hostname or contacts a website.

use std::collections::HashSet;
use std::sync::OnceLock;

use crate::layout::KeyboardLayout;

static TLDS: &str = include_str!("../../../Sources/SwitchCore/Resources/tlds-alpha-by-domain.txt");

fn top_level_domains() -> &'static HashSet<String> {
    static SET: OnceLock<HashSet<String>> = OnceLock::new();
    SET.get_or_init(|| TLDS.lines().filter(|l| !l.starts_with('#') && !l.is_empty()).map(|l| l.to_lowercase()).collect())
}

pub fn recognizes(text: &str) -> bool {
    if !(4..=512).contains(&text.len()) || text.chars().any(char::is_whitespace) || text.contains('@')
        || !text.bytes().all(|b| b > 32 && b < 127) { return false; }
    let lower = text.to_lowercase();
    let address = if lower.starts_with("https://") { &text[8..] }
        else if lower.starts_with("http://") { &text[7..] }
        else if lower.contains("://") { return false; }
        else { text };
    let authority: &str = address.split(['/', '?', '#']).next().unwrap_or("");
    let parts: Vec<&str> = authority.split(':').collect();
    if !(1..=2).contains(&parts.len()) { return false; }
    if parts.len() == 2 {
        let port = parts[1];
        if port.is_empty() || !port.bytes().all(|b| b.is_ascii_digit()) { return false; }
        match port.parse::<u32>() { Ok(p) if (1..=65_535).contains(&p) => {}, _ => return false }
    }
    let host = parts[0].to_lowercase();
    if host.len() > 253 { return false; }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2 || !top_level_domains().contains(*labels.last().unwrap()) { return false; }
    labels.iter().all(|label| {
        (1..=63).contains(&label.len()) && !label.starts_with('-') && !label.ends_with('-')
            && label.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    })
}

pub fn converted(text: &str, source: &KeyboardLayout, target: &KeyboardLayout) -> Option<String> {
    if !source.is_cyrillic() || !target.languages.iter().any(|l| !l.is_cyrillic())
        || !text.chars().any(|c| (0x400..=0x4ff).contains(&(c as u32))) { return None; }
    // Both physical punctuation (ю → .) and deliberately typed literal dots occur.
    for preserve in [false, true] {
        if let Some(output) = source.convert_with(text, target, preserve) {
            if recognizes(&output) { return Some(output); }
        }
    }
    None
}
