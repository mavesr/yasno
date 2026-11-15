/// contenteditable uses NBSP at line ends to preserve a typed space in HTML.
pub fn matches(actual: &str, word: &str, suffix: &str) -> bool {
    let expected = format!("{word}{suffix}");
    if actual == expected { return true; }
    if suffix.is_empty() || !suffix.chars().all(|c| c == ' ') { return false; }
    actual.replace(['\u{00a0}', '\u{202f}'], " ") == expected
}
