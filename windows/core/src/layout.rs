//! A keyboard layout as a table of physical keys. On Windows the app fills it from the
//! installed layout through `ToUnicodeEx`, as the Mac version reads the Apple tables
//! through `UCKeyTranslate`; no hand-written QWERTY assumptions in the rules.
//!
//! Keys are Windows scan codes (set 1), the physical position independent of layout.

use std::collections::{HashMap, HashSet};

use crate::chars::{is_control, is_punctuation, is_whitespace};
use crate::language::Language;
use crate::word_text::is_apostrophe;

const SHIFT: u16 = 0x100;
const CAPS: u16 = 0x200;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct KeyStroke {
    pub key: u16,
    pub shift: bool,
    pub caps_lock: bool,
}

impl KeyStroke {
    pub fn new(key: u16, shift: bool) -> Self { KeyStroke { key, shift, caps_lock: false } }
}

/// What one key types in one modifier state.
#[derive(Clone, Debug)]
pub struct KeyEntry {
    pub key: u16,
    pub shift: bool,
    pub caps_lock: bool,
    pub text: String,
    /// The key only starts a composition (^ then e is ê on German): it types nothing itself.
    pub dead: bool,
}

/// The typing block: these keys win over the keypad when two keys type the same glyph.
pub fn is_main_key(key: u16) -> bool {
    matches!(key, 0x02..=0x0D | 0x10..=0x1B | 0x1E..=0x29 | 0x2B..=0x35 | 0x39 | 0x56 | 0x73 | 0x7D)
}

#[derive(Debug)]
pub struct KeyboardLayout {
    pub id: String,
    pub name: String,
    pub languages: Vec<Language>,
    forward: HashMap<u16, String>,
    reverse: HashMap<String, u16>,
    dead_keys: HashSet<u16>,
    apostrophe_glyph: String,
}

impl PartialEq for KeyboardLayout {
    fn eq(&self, other: &Self) -> bool { self.id == other.id }
}

fn position(key: u16, shift: bool, caps: bool) -> u16 {
    key | if shift { SHIFT } else { 0 } | if caps { CAPS } else { 0 }
}

impl KeyboardLayout {
    pub fn new(id: impl Into<String>, name: impl Into<String>, languages: Vec<Language>,
               entries: impl IntoIterator<Item = KeyEntry>) -> Self {
        let mut entries: Vec<KeyEntry> = entries.into_iter()
            .filter(|e| !e.text.is_empty() && !e.text.chars().any(is_control))
            .collect();
        // Same priority as the Mac version: the main keyboard (unshifted, then shifted
        // symbols) before the keypad; lower key codes first.
        entries.sort_by_key(|e| (!is_main_key(e.key), e.shift, e.key, e.caps_lock));
        let mut forward = HashMap::new();
        let mut reverse = HashMap::new();
        let mut dead_keys = HashSet::new();
        for e in entries {
            let p = position(e.key, e.shift, e.caps_lock);
            if forward.contains_key(&p) { continue; }
            forward.insert(p, e.text.clone());
            if e.dead { dead_keys.insert(p); }
            if !e.caps_lock { reverse.entry(e.text).or_insert(p & !CAPS); }
        }
        let apostrophe_glyph = Self::apostrophe(&forward, &reverse);
        KeyboardLayout { id: id.into(), name: name.into(), languages, forward, reverse, dead_keys, apostrophe_glyph }
    }

    fn apostrophe(forward: &HashMap<u16, String>, reverse: &HashMap<String, u16>) -> String {
        // Prefer a normal, unshifted key before compatibility alternatives.
        let mut keys: Vec<u16> = forward.keys().copied().filter(|&p| p & (SHIFT | CAPS) == 0 && is_main_key(p)).collect();
        keys.sort_unstable();
        for key in keys {
            let glyph = &forward[&key];
            let mut chars = glyph.chars();
            if let (Some(c), None) = (chars.next(), chars.next()) {
                if is_apostrophe(c) { return glyph.clone(); }
            }
        }
        ["'", "ʼ", "’"].iter().find(|g| reverse.contains_key(**g)).unwrap_or(&"'").to_string()
    }

    pub fn apostrophe_glyph(&self) -> &str { &self.apostrophe_glyph }

    pub fn is_cyrillic(&self) -> bool { self.languages.iter().any(|l| l.is_cyrillic()) }

    pub fn has_language(&self, language: Language) -> bool { self.languages.contains(&language) }

    /// The text this key leaves in the field depends on the next key: the application composes it.
    pub fn is_dead_key(&self, key: u16, shift: bool, caps_lock: bool) -> bool {
        self.dead_keys.contains(&position(key, shift, caps_lock))
    }

    /// The key and Shift state that type this character.
    pub fn stroke(&self, c: char) -> Option<KeyStroke> {
        let mut buf = [0u8; 4];
        self.reverse.get(c.encode_utf8(&mut buf) as &str).map(|&p| KeyStroke::new(p & 0xff, p & SHIFT != 0))
    }

    /// The physical key that types this character, ignoring Shift.
    pub fn key(&self, c: char) -> Option<u16> { self.stroke(c).map(|s| s.key) }

    pub fn character(&self, key: u16, shift: bool, caps_lock: bool) -> Option<&str> {
        self.forward.get(&position(key, shift, caps_lock)).map(String::as_str)
    }

    /// Keep the actual key for recently typed symbols: the same glyph may occur on
    /// several keys in one layout and map to different glyphs in another layout.
    pub fn render(&self, strokes: &[KeyStroke]) -> Option<String> {
        let mut output = String::new();
        for s in strokes { output.push_str(self.character(s.key, s.shift, s.caps_lock)?); }
        Some(output)
    }

    pub fn convert(&self, text: &str, target: &KeyboardLayout) -> Option<String> {
        self.convert_with(text, target, false)
    }

    pub fn convert_with(&self, text: &str, target: &KeyboardLayout, preserving_punctuation: bool) -> Option<String> {
        let mut output = String::with_capacity(text.len());
        let mut buf = [0u8; 4];
        for c in text.chars() {
            // Prefer the literal glyph's real key (Ukrainian layouts may have a dedicated
            // U+02BC key). Normalize typography only when this table lacks it.
            let literal: &str = c.encode_utf8(&mut buf);
            let value: &str = if !self.reverse.contains_key(literal) && is_apostrophe(c) { &self.apostrophe_glyph } else { literal };
            if value.chars().all(is_whitespace) || (preserving_punctuation && is_punctuation(c)) {
                output.push_str(value);
            } else if let Some(t) = self.reverse.get(value).and_then(|p| target.forward.get(p)) {
                output.push_str(t);
            } else { return None; }
        }
        Some(output)
    }

    /// Latin layouts first, then Russian, then Ukrainian: the Shift cycle order.
    pub fn cycle_order<'a>(layouts: &[&'a KeyboardLayout]) -> Vec<&'a KeyboardLayout> {
        fn priority(l: &KeyboardLayout) -> u8 {
            if l.has_language(Language::English) { 0 } else if l.has_language(Language::Russian) { 1 }
            else if l.has_language(Language::Ukrainian) { 2 } else { 3 }
        }
        let mut v = layouts.to_vec();
        v.sort_by(|a, b| priority(a).cmp(&priority(b)).then_with(|| a.id.cmp(&b.id)));
        v
    }
}
