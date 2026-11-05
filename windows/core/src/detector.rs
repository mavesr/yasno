//! Port of Sources/SwitchCore/Detector.swift. Keep the two in step: every rule here has
//! the same name and order as in the Swift file, so a fix on one side maps to the other.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock};

use crate::chars::{self, count, is_letter, is_number, is_punctuation, is_uppercase, is_whitespace, letters};
use crate::language::Language;
use crate::layout::{KeyStroke, KeyboardLayout};
use crate::lexicon::{Lexicon, NoLexicon};
use crate::web_address;
use crate::word_text::{self, canonical, core_and_suffix, is_apostrophe};

#[derive(Clone, Debug)]
pub struct Suggestion<'a> {
    pub original: String,
    pub replacement: String,
    pub target: &'a KeyboardLayout,
    pub score: f64,
}

/// What surrounds a word: exceptions, the layout the user chose last, the text before it.
#[derive(Clone, Copy, Debug)]
pub struct Query<'q> {
    pub ignored: &'q HashSet<String>,
    pub preferred: Option<&'q str>,
    pub context: &'q str,
}

pub fn no_exceptions() -> &'static HashSet<String> {
    static EMPTY: OnceLock<HashSet<String>> = OnceLock::new();
    EMPTY.get_or_init(HashSet::new)
}

impl Default for Query<'_> {
    fn default() -> Self { Query { ignored: no_exceptions(), preferred: None, context: "" } }
}

impl<'q> Query<'q> {
    pub fn preferring(self, id: &'q str) -> Self { Query { preferred: Some(id), ..self } }
    pub fn preferring_opt(self, id: Option<&'q str>) -> Self { Query { preferred: id, ..self } }
    pub fn context(self, context: &'q str) -> Self { Query { context, ..self } }
    pub fn ignoring(self, ignored: &'q HashSet<String>) -> Self { Query { ignored, ..self } }
}

struct Storage {
    ranks: HashMap<Language, HashMap<String, u32>>,
    sorted_words: HashMap<Language, Vec<String>>,
}

static EN: &str = include_str!("../../../Sources/SwitchCore/Resources/en.txt");
static DE: &str = include_str!("../../../Sources/SwitchCore/Resources/de.txt");
static RU: &str = include_str!("../../../Sources/SwitchCore/Resources/ru.txt");
static UK: &str = include_str!("../../../Sources/SwitchCore/Resources/uk.txt");
static RU_NATIVE: &str = include_str!("../../../Sources/SwitchCore/Resources/ru-native.txt");
static UK_NATIVE: &str = include_str!("../../../Sources/SwitchCore/Resources/uk-native.txt");
static EN_SUP: &str = include_str!("../../../Sources/SwitchCore/Resources/en-supplemental.txt");
static DE_SUP: &str = include_str!("../../../Sources/SwitchCore/Resources/de-supplemental.txt");
static RU_SUP: &str = include_str!("../../../Sources/SwitchCore/Resources/ru-supplemental.txt");
static UK_SUP: &str = include_str!("../../../Sources/SwitchCore/Resources/uk-supplemental.txt");

fn lines(text: &str) -> impl Iterator<Item = &str> {
    text.split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l)).filter(|l| !l.is_empty())
}

fn storage() -> &'static Storage {
    static STORAGE: OnceLock<Storage> = OnceLock::new();
    STORAGE.get_or_init(|| {
        let mut ranks = HashMap::new();
        let mut sorted_words = HashMap::new();
        for language in Language::ALL {
            let (base, native, supplemental) = match language {
                Language::English => (EN, None, EN_SUP),
                Language::German => (DE, None, DE_SUP),
                Language::Russian => (RU, Some(RU_NATIVE), RU_SUP),
                Language::Ukrainian => (UK, Some(UK_NATIVE), UK_SUP),
            };
            let native: Option<HashSet<&str>> = native.map(|t| lines(t).collect());
            let mut words: HashMap<String, u32> = HashMap::with_capacity(60_000);
            for (index, line) in lines(base).enumerate() {
                let Some(raw) = line.split(' ').find(|s| !s.is_empty()) else { continue };
                let word = raw.to_lowercase();
                if has_native_letters(&word, language) && native.as_ref().map_or(true, |n| n.contains(word.as_str())) {
                    words.insert(word, index as u32 + 1);
                }
            }
            // Small, authored additions cover everyday vocabulary missing from subtitles.
            // A line may give a rank; "-word" drops a listed word typed mostly by accident.
            for line in lines(supplemental) {
                let mut fields = line.split(' ').filter(|s| !s.is_empty());
                let Some(word) = fields.next() else { continue };
                if let Some(removed) = word.strip_prefix('-') { words.remove(removed); continue; }
                if !has_native_letters(word, language) { continue; }
                if let Some(authored) = fields.next().and_then(|f| f.parse::<u32>().ok()) {
                    let current = words.get(word).copied().unwrap_or(u32::MAX);
                    words.insert(word.to_string(), current.min(authored));
                } else {
                    words.entry(word.to_string()).or_insert(10_000);
                }
            }
            let mut sorted: Vec<String> = words.keys().cloned().collect();
            sorted.sort_unstable();
            sorted_words.insert(language, sorted);
            ranks.insert(language, words);
        }
        Storage { ranks, sorted_words }
    })
}

/// Subtitle frequency lists contain foreign dialogue and abbreviations. Their presence
/// must not make Latin text Russian, or a word containing ы a valid Ukrainian word.
fn has_native_letters(word: &str, language: Language) -> bool {
    let lower = word.to_lowercase();
    let mut any = false;
    for s in lower.chars().filter(|&c| chars::is_letter_or_mark(c)) {
        any = true;
        let v = s as u32;
        let ok = match language {
            Language::English | Language::German =>
                (0x61..=0x7a).contains(&v) || (0xc0..=0x24f).contains(&v) || (0x1e00..=0x1eff).contains(&v),
            Language::Russian => (0x430..=0x44f).contains(&v) || s == 'ё',
            Language::Ukrainian => ((0x430..=0x44f).contains(&v) && !"ыэъ".contains(s)) || "іїєґ".contains(s),
        };
        if !ok { return false; }
    }
    any
}

const WRAPPERS: [(char, char); 7] = [('"', '"'), ('\'', '\''), ('«', '»'), ('“', '”'), ('„', '“'), ('‘', '’'), ('(', ')')];


pub struct Detector {
    storage: &'static Storage,
    pub(crate) lexicon: Arc<dyn Lexicon>,
}

impl Default for Detector {
    fn default() -> Self { Detector::new(Arc::new(NoLexicon)) }
}

impl Detector {
    pub fn new(lexicon: Arc<dyn Lexicon>) -> Self { Detector { storage: storage(), lexicon } }

    pub fn count(&self, language: Language) -> usize { self.storage.ranks[&language].len() }

    /// Read-only word → frequency rank table, for validation tools.
    pub fn vocabulary(&self, language: Language) -> &HashMap<String, u32> { &self.storage.ranks[&language] }

    pub fn rank(&self, word: &str, languages: &[Language]) -> Option<u32> {
        self.rank_lowercased(&canonical(&word.to_lowercase()), languages)
    }

    pub(crate) fn rank_lowercased(&self, lower: &str, languages: &[Language]) -> Option<u32> {
        let mut best: Option<u32> = None;
        for language in languages {
            if let Some(&r) = self.storage.ranks[language].get(lower) {
                if best.map_or(true, |b| r < b) { best = Some(r); }
            }
        }
        best
    }

    /// Frequency corpora miss compounds such as app + store and screen + shot.
    /// Accept exactly two substantial, common words from the SAME language.
    fn is_common_latin_compound(&self, word: &str, languages: &[Language]) -> bool {
        let lower = word.to_lowercase();
        if !(7..=32).contains(&lower.len()) || !lower.bytes().all(|b| b.is_ascii_lowercase()) { return false; }
        for language in languages.iter().filter(|l| matches!(l, Language::English | Language::German)) {
            let words = &self.storage.ranks[language];
            for split in 3..=(lower.len() - 3) {
                let (Some(&first), Some(&second)) = (words.get(&lower[..split]), words.get(&lower[split..])) else { continue };
                if first <= 10_000 && second <= 10_000 && (first.min(second) <= 2_000 || first + second <= 12_500) { return true; }
            }
        }
        false
    }

    /// Only reserve physical input if some contextual choice could produce a correction.
    pub fn may_suggest(&self, word: &str, source: &KeyboardLayout, layouts: &[&KeyboardLayout], ignored: &HashSet<String>) -> bool {
        layouts.iter().any(|target| target.id != source.id
            && self.suggest(word, source, layouts, Query { ignored, preferred: Some(&target.id), context: "" }).is_some())
    }

    /// Nearby completed words resolve language ambiguity; no persistent input history.
    pub(crate) fn context_preference(&self, context: &str, input: &[&KeyboardLayout]) -> Option<String> {
        let mut targets: Vec<&KeyboardLayout> = Vec::new();
        for t in input { if !targets.iter().any(|x| x.id == t.id) { targets.push(t); } }
        if targets.len() <= 1 { return targets.first().map(|t| t.id.clone()); }
        let mut evidence: HashMap<String, f64> = HashMap::new();
        let sentence_start = context.char_indices().rev().find(|&(_, c)| ".!?\n".contains(c)).map(|(i, c)| i + c.len_utf8()).unwrap_or(0);
        let sentence = &context[sentence_start..];
        let words: Vec<&str> = sentence.split(is_whitespace).filter(|w| !w.is_empty()).collect();
        let recent = &words[words.len().saturating_sub(6)..];
        for (distance, raw) in recent.iter().rev().enumerate() {
            let word = chars::trim_punctuation(raw);
            let mut matches: Vec<(&str, u32)> = targets.iter()
                .filter_map(|t| self.rank(word, &t.languages).map(|r| (t.id.as_str(), r))).collect();
            matches.sort_by_key(|m| m.1);
            let Some(&best) = matches.first() else { continue };
            let margin = if matches.len() > 1 { (matches[1].1 as f64 / best.1 as f64).log10() } else { 2.0 };
            if margin < 0.9 { continue; }
            *evidence.entry(best.0.to_string()).or_insert(0.0) += margin.min(2.0) * 0.65f64.powi(distance as i32);
        }
        let mut ordered: Vec<(String, f64)> = evidence.into_iter().collect();
        ordered.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
        let best = ordered.first()?;
        let second = ordered.get(1).map_or(0.0, |s| s.1);
        if best.1 >= 0.6 && best.1 - second >= 0.6 { Some(best.0.clone()) } else { None }
    }

    fn contextual_preference(&self, context: &str, candidates: &[Suggestion]) -> Option<String> {
        let targets: Vec<&KeyboardLayout> = candidates.iter().map(|c| c.target).collect();
        self.context_preference(context, &targets)
    }

    pub fn convert_text_manually(&self, text: &str, source: &KeyboardLayout, target: &KeyboardLayout,
                                 physical_keys: Option<&[KeyStroke]>) -> Option<String> {
        if !text.is_empty() && !text.chars().any(is_letter) {
            if let Some(keys) = physical_keys {
                if source.render(keys).as_deref() == Some(text) { return target.render(keys); }
            }
            return source.convert(text, target);
        }
        if let Some(address) = web_address::converted(text, source, target) { return Some(address); }
        let source_cyrillic = source.is_cyrillic();
        let convert_word = |input: &str| -> Option<String> {
            let full = source.convert(input, target);
            if let Some(f) = &full { if self.rank(f, &target.languages).is_some() { return full; } }
            // Strip only as much literal punctuation as needed. A preceding dot may still
            // be the physical ю key (lzre.! → дякую!). A currency sign is literal too.
            let mut core = input;
            let mut length = count(input);
            while let Some(last) = core.chars().last() {
                if !(word_text::is_suffix_punctuation(last) || word_text::is_closing_symbol(last)) { break; }
                core = &core[..core.len() - last.len_utf8()];
                length -= 1;
                if length > 0 && length <= 64 {
                    if let Some(translated) = source.convert(core, target) {
                        if self.rank(&translated, &target.languages).is_some() { return Some(translated + &input[core.len()..]); }
                    }
                }
            }
            // Quotes or brackets around a word keep their look: "ghbdtn" → "привет".
            let ch: Vec<char> = input.chars().collect();
            if !source_cyrillic && ch.len() > 2 {
                let (open, close) = (ch[0], ch[ch.len() - 1]);
                if WRAPPERS.iter().any(|&(o, c)| o == open && c == close) {
                    let inner: String = ch[1..ch.len() - 1].iter().collect();
                    if let Some(inner) = source.convert(&inner, target) {
                        if self.rank(&inner, &target.languages).is_some() { return Some(format!("{open}{inner}{close}")); }
                    }
                }
            }
            if source_cyrillic {
                let mut converted = String::new();
                for (i, &c) in ch.iter().enumerate() {
                    let embedded = i > 0 && i + 1 < ch.len() && is_letter(ch[i - 1]) && is_letter(ch[i + 1]);
                    let mapped = source.convert(&c.to_string(), target);
                    let apostrophe = is_apostrophe(c) || mapped.as_ref().is_some_and(|m| m.chars().any(is_apostrophe));
                    if is_punctuation(c) && !(embedded && apostrophe) { converted.push(c); }
                    else { converted.push_str(&mapped?); }
                }
                return Some(converted);
            }
            full
        };
        let mut output = String::new();
        let mut word = String::new();
        for c in text.chars() {
            if is_whitespace(c) {
                output.push_str(&convert_word(&word)?);
                output.push(c);
                word.clear();
            } else { word.push(c); }
        }
        output.push_str(&convert_word(&word)?);
        Some(output)
    }

    pub fn convert_manually<'a>(&self, text: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout],
                                preferred: Option<&str>, physical_keys: Option<&[KeyStroke]>) -> Option<Suggestion<'a>> {
        let words: Vec<&str> = text.split(is_whitespace).filter(|w| !w.is_empty()).collect();
        let source_cyrillic = source.is_cyrillic();
        let source_recognized = words.iter().any(|w| self.rank(chars::trim_punctuation(w), &source.languages).is_some());
        let available: Vec<&'a KeyboardLayout> = layouts.iter().copied().filter(|l| l.id != source.id).collect();
        let other_alphabet: Vec<&'a KeyboardLayout> = available.iter().copied().filter(|l| l.is_cyrillic() != source_cyrillic).collect();
        // An explicit conversion of already valid Cyrillic should produce Latin keystrokes.
        let targets = if source_recognized && !other_alphabet.is_empty() { other_alphabet } else { available };
        let all: Vec<Suggestion<'a>> = targets.iter().filter_map(|&target| {
            let converted = self.convert_text_manually(text, source, target, physical_keys)?;
            let score = words.iter().fold(0.0, |sum, w| {
                match self.convert_text_manually(w, source, target, None)
                    .and_then(|o| self.rank(chars::trim_punctuation(&o), &target.languages)) {
                    Some(r) => sum + (50_001.0 / r as f64).log10(),
                    None => sum,
                }
            });
            Some(Suggestion { original: text.into(), replacement: converted, target, score })
        }).collect();
        // A glyph shared by RU and UK must still change on the first tap when
        // another available layout gives a different glyph (e.g. % → $, п → g).
        let changed: Vec<Suggestion<'a>> = all.iter().filter(|s| s.replacement != text).cloned().collect();
        let mut candidates = if changed.is_empty() { all } else { changed };
        candidates.sort_by(|a, b| {
            use std::cmp::Ordering;
            if a.score != b.score { return b.score.partial_cmp(&a.score).unwrap_or(Ordering::Equal); }
            let (ap, bp) = (Some(a.target.id.as_str()) == preferred, Some(b.target.id.as_str()) == preferred);
            if ap != bp { return if ap { Ordering::Less } else { Ordering::Greater }; }
            let (ac, bc) = (a.target.is_cyrillic(), b.target.is_cyrillic());
            if ac != bc { return if source_cyrillic != ac { Ordering::Less } else { Ordering::Greater }; }
            a.target.id.cmp(&b.target.id)
        });
        let best = candidates.first()?.clone();
        Some(candidates.iter().find(|c| Some(c.target.id.as_str()) == preferred && c.replacement == best.replacement)
            .cloned().unwrap_or(best))
    }

    pub fn suggest<'a>(&self, word: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout], q: Query) -> Option<Suggestion<'a>> {
        self.suggest_full(word, source, layouts, q, false, false)
    }

    pub fn suggest_manual<'a>(&self, word: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout], q: Query) -> Option<Suggestion<'a>> {
        self.suggest_full(word, source, layouts, q, true, false)
    }

    /// `live` marks an unfinished word: punctuation at its end may still become a letter.
    pub(crate) fn suggest_full<'a>(&self, word: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout],
                                   q: Query, manual: bool, live: bool) -> Option<Suggestion<'a>> {
        if q.ignored.contains(&word.to_lowercase()) { return None; }
        if self.rank(word, &source.languages).is_none() {
            if let Some(address) = self.suggest_address(word, source, layouts) {
                if manual || !self.is_valid_native_text(word, source) { return Some(address); }
            }
        }
        let length = count(word);
        if !(1..=if manual { 128 } else { 64 }).contains(&length) || word.chars().any(is_number)
            || word.chars().any(|c| "@/_=".contains(c)) { return None; }
        if !manual && length == 1 { return self.suggest_single_letter(word, source, layouts, q); }
        let letters = letters(word);
        if letters.is_empty() { return None; }
        // Preserve valid words. For two-letter strings, a rare dictionary abbreviation
        // alone is not enough to defeat a common pronoun in context.
        let valid_languages = &source.languages;
        let base_word = core_and_suffix(word).0;
        let base_count = count(base_word);
        let source_rank = [self.rank(word, valid_languages), self.rank(base_word, valid_languages)].into_iter().flatten().min();
        let short = base_count == 2;
        // A recognized full word is evidence of deliberate native input, even when rare.
        if !manual { if let Some(sr) = source_rank { if sr <= 5_000 || base_count >= 4 { return None; } } }
        // Avoid touching code identifiers and acronyms. Title case remains supported.
        let letter_count = count(&letters);
        let capitals = letter_count > 1 && letters == letters.to_uppercase();
        let capital_word = capitals && !live && letter_count >= 4;
        if !manual {
            if capitals && !capital_word { return None; }
            if !capitals && letters.chars().skip(1).any(is_uppercase) { return None; }
        }

        let mut candidates: Vec<Suggestion<'a>> = Vec::new();
        for &target in layouts.iter().filter(|t| t.id != source.id) {
            let Some(converted) = source.convert(word, target) else { continue };
            if converted == word { continue; }
            // Judge the word without punctuation the target layout puts at its end;
            // literal punctuation typed in the source stays literal.
            let (converted_core, converted_suffix) = core_and_suffix(&converted);
            let suffix_count = count(converted_suffix);
            let typed_symbols = !converted_suffix.is_empty()
                && !chars::suffix(word, suffix_count).chars().any(word_text::is_suffix_punctuation);
            let dictionary_rank = self.rank(&converted, &target.languages).or_else(|| {
                if typed_symbols && !converted_core.is_empty() { self.rank(converted_core, &target.languages) } else { None }
            });
            let candidate_rank = if let Some(r) = dictionary_rank { r }
                else if !live && source_rank.is_none() && (converted_suffix.is_empty() || typed_symbols) && count(converted_core) >= 5
                    && (converted_core.chars().all(is_letter)
                        || (target.has_language(Language::Ukrainian) && word_text::is_orthographic_word(converted_core)))
                    && self.lexicon.knows_any(converted_core, &target.languages) {
                    // A valid form outside the frequency list: weak evidence, below any dictionary word.
                    30_000
                } else { continue };
            if !manual {
                let output_letters = letters_of(&converted);
                let output_capitals = count(&output_letters) > 1 && output_letters == output_letters.to_uppercase();
                if output_capitals && !(capital_word && dictionary_rank.is_some_and(|r| r <= 20_000)) { continue; }
                if !output_capitals && output_letters.chars().skip(1).any(is_uppercase) { continue; }
            }
            let apostrophe_word = target.has_language(Language::Ukrainian) && converted.chars().any(is_apostrophe)
                && word_text::is_orthographic_word(&converted);
            let max_rank = if manual || apostrophe_word { 50_000 } else if length == 2 { 2_000 } else if length == 3 { 4_000 } else { 50_000 };
            if candidate_rank > max_rank { continue; }
            let score = (50_001.0 / candidate_rank as f64).log10();
            candidates.push(Suggestion { original: word.into(), replacement: converted, target, score });
        }
        // Unknown compounds are a fallback only. Only Cyrillic → Latin qualifies.
        if candidates.is_empty() && source_rank.is_none() && !capitals && source.is_cyrillic() {
            for &target in layouts.iter().filter(|t| t.id != source.id && !t.is_cyrillic()) {
                let Some(converted) = source.convert(word, target) else { continue };
                if converted == word || !self.is_common_latin_compound(&converted, &target.languages) { continue; }
                candidates.push(Suggestion { original: word.into(), replacement: converted, target,
                                             score: (50_001.0f64 / 40_000.0).log10() });
            }
        }
        // The spelling service knows inflections the frequency list lacks. Asked only once
        // some conversion is on the table: it is slow.
        if !manual && !candidates.is_empty() && source_rank.is_none() && base_count >= 4
            && self.lexicon.knows_any(base_word, valid_languages) { return None; }
        // Between RU and UK the same keys spell both languages: a name or form missing from
        // the list stays when the sentence so far is in the source language.
        if !manual && source_rank.is_none() && source.is_cyrillic() && candidates.iter().any(|c| c.target.is_cyrillic()) {
            let mut targets: Vec<&KeyboardLayout> = vec![source];
            targets.extend(candidates.iter().map(|c| c.target));
            if self.context_preference(q.context, &targets).as_deref() == Some(source.id.as_str()) {
                candidates.retain(|c| !c.target.is_cyrillic());
            }
        }
        candidates.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap());
        let Some(best) = candidates.first().cloned() else {
            // A punctuation key may itself represent a Cyrillic letter (e.g. . → ю).
            // Try the complete key sequence first; only then treat punctuation as a suffix.
            let last = word.chars().last();
            let core = if last.is_some_and(|c| ".,!?;:…\"'’)]}".contains(c)) { chars::drop_last(word, 1) } else { word };
            if !live && !core.is_empty() && core != word {
                if let Some(inner) = self.suggest_full(core, source, layouts, q, manual, false) {
                    return Some(Suggestion { original: word.into(), replacement: inner.replacement + &word[core.len()..],
                                             target: inner.target, score: inner.score });
                }
            }
            return None;
        };
        if !manual && source_rank.is_some() && source.is_cyrillic() {
            let original = Suggestion { original: word.into(), replacement: word.into(), target: source, score: 0.0 };
            let mut all = candidates.clone();
            all.push(original);
            let contextual = self.contextual_preference(q.context, &all);
            if contextual.as_deref() == Some(source.id.as_str()) { return None; }
            if base_count >= 4 && contextual.as_deref() != Some(best.target.id.as_str()) { return None; }
        }
        if !manual {
            if let (Some(sr), Some(tr)) = (source_rank, self.rank(&best.replacement, &best.target.languages)) {
                if tr > 2_000 || (sr as f64 / tr as f64) < if short { 40.0 } else { 20.0 } { return None; }
            }
        }
        let preference = self.contextual_preference(q.context, &candidates).or_else(|| q.preferred.map(String::from));
        // Identical output in RU/UK is not a reason to change an already active Cyrillic layout.
        if !manual {
            if let Some(second) = candidates.iter().find(|c| c.replacement != best.replacement) {
                if best.score - second.score < 0.9 {
                    // Only resolve near-tied Cyrillic alternatives with an actual language preference.
                    if candidates.iter().all(|c| c.target.is_cyrillic()) {
                        if let Some(p) = candidates.iter().find(|c| Some(&c.target.id) == preference.as_ref() && best.score - c.score < 0.9) {
                            return Some(p.clone());
                        }
                    }
                    return None;
                }
            }
        }
        if let Some(p) = candidates.iter().find(|c| c.replacement == best.replacement && Some(&c.target.id) == preference.as_ref()) {
            return Some(p.clone());
        }
        if !manual && candidates.iter().any(|c| c.replacement == best.replacement && c.target.languages != best.target.languages) {
            return None;
        }
        Some(best)
    }

    /// A Cyrillic word whose ю key happens to spell a domain is text, not an address.
    fn is_valid_native_text(&self, word: &str, source: &KeyboardLayout) -> bool {
        if !source.is_cyrillic() { return false; }
        let core = core_and_suffix(word).0;
        if count(core) < 2 || !core.chars().all(is_letter) { return false; }
        // Either Cyrillic language: a Russian word may be typed on the Ukrainian layout.
        let languages = [Language::Russian, Language::Ukrainian];
        self.rank(core, &languages).is_some() || self.lexicon.knows_any(core, &languages)
    }

    /// While a word is still being typed only an unmistakable address converts.
    fn is_explicit_address(output: &str) -> bool {
        let lower = output.to_lowercase();
        if lower.contains("://") || lower.starts_with("www.") || lower.contains('/') { return true; }
        let host: &str = lower.split([':', '/', '?', '#']).next().unwrap_or("");
        let labels: Vec<&str> = host.split('.').filter(|l| !l.is_empty()).collect();
        labels.len() >= 3 || labels.last().map_or(0, |l| count(l)) >= 3
            || host.chars().any(|c| is_number(c) || c == '-')
    }

    fn suggest_address<'a>(&self, word: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout]) -> Option<Suggestion<'a>> {
        if count(word) > 512 { return None; }
        for &target in layouts.iter().filter(|t| t.id != source.id) {
            if let Some(output) = web_address::converted(word, source, target) {
                return Some(Suggestion { original: word.into(), replacement: output, target, score: 5.0 });
            }
        }
        None
    }

    /// A native word may still be incomplete. Do not switch its recognized prefixes.
    pub(crate) fn is_native_prefix(&self, word: &str, languages: &[Language]) -> bool {
        let prefix = canonical(&word.to_lowercase());
        languages.iter().any(|l| {
            let words = &self.storage.sorted_words[l];
            let low = prefix_start(&prefix, words);
            low < words.len() && words[low].starts_with(&prefix)
        })
    }

    /// A partial word is weaker evidence than an exact match. Require at least two
    /// common completions in one language. Return the typed prefix, never a completion.
    fn suggest_prefix_while_typing<'a>(&self, word: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout],
                                       q: Query) -> Option<Suggestion<'a>> {
        let letters = letters(word);
        if !(4..=32).contains(&count(word)) || count(&letters) < 4 || letters == letters.to_uppercase()
            || letters.chars().skip(1).any(is_uppercase)
            || word.chars().any(|c| is_number(c) || "@/_=".contains(c)) { return None; }
        let source_cyrillic = source.is_cyrillic();
        let mut candidates: Vec<Suggestion<'a>> = Vec::new();
        for &target in layouts.iter().filter(|t| t.id != source.id) {
            if source_cyrillic == target.is_cyrillic() { continue; }
            let Some(converted) = source.convert(word, target) else { continue };
            if converted == word || !converted.chars().all(is_letter) || q.ignored.contains(&converted.to_lowercase())
                || self.rank(&converted, &target.languages).is_some() { continue; }
            let prefix = canonical(&converted.to_lowercase());
            let confident = target.languages.iter().any(|l| {
                let words = &self.storage.sorted_words[l];
                let ranks = &self.storage.ranks[l];
                let mut index = prefix_start(&prefix, words);
                let mut matches = 0;
                while index < words.len() && words[index].starts_with(&prefix) {
                    if ranks.get(&words[index]).is_some_and(|&r| r <= 10_000) {
                        matches += 1;
                        if matches == 2 { return true; }
                    }
                    index += 1;
                }
                false
            });
            if confident { candidates.push(Suggestion { original: word.into(), replacement: converted, target, score: 0.0 }); }
        }
        let preference = self.contextual_preference(q.context, &candidates).or_else(|| q.preferred.map(String::from));
        if let Some(p) = candidates.iter().find(|c| Some(&c.target.id) == preference.as_ref()) { return Some(p.clone()); }
        if candidates.len() == 1 { candidates.pop() } else { None }
    }

    /// Text typed on a Ukrainian layout is not switched to Russian while the word is typed.
    fn live_targets<'a>(layouts: &[&'a KeyboardLayout], source: &KeyboardLayout) -> Vec<&'a KeyboardLayout> {
        if !source.has_language(Language::Ukrainian) { return layouts.to_vec(); }
        layouts.iter().copied().filter(|l| !l.has_language(Language::Russian)).collect()
    }

    pub fn suggest_while_typing<'a>(&self, word: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout],
                                    q: Query, spelling_aware: bool) -> Option<Suggestion<'a>> {
        let layouts = Self::live_targets(layouts, source);
        if count(word) < 4 || q.ignored.contains(&word.to_lowercase()) { return None; }
        if self.is_native_prefix(word, &source.languages) { return None; }
        if let Some(address) = self.suggest_address(word, source, &layouts) {
            return (Self::is_explicit_address(&address.replacement) && !self.is_valid_native_text(word, source)).then_some(address);
        }
        let exact = self.suggest_full(word, source, &layouts, q, false, true);
        let exact_found = exact.is_some();
        let result = exact.or_else(|| self.suggest_prefix_while_typing(word, source, &layouts, q))?;
        // For prefixes, block native typos that the spelling engine could repair.
        if spelling_aware && self.has_native_spelling_alternative(word, source, &result.replacement,
                                                                  if exact_found { u32::MAX } else { 20_000 }) { return None; }
        if let Some(preferred_id) = q.preferred {
            if result.target.id != preferred_id {
                if let Some(preferred) = layouts.iter().find(|l| l.id == preferred_id) {
                    if preferred.is_cyrillic() && result.target.is_cyrillic() {
                        if let Some(alt) = source.convert(word, preferred) {
                            if self.is_native_prefix(&alt, &preferred.languages) { return None; }
                        }
                    }
                }
            }
        }
        Some(result)
    }

    pub fn may_suggest_while_typing(&self, word: &str, source: &KeyboardLayout, layouts: &[&KeyboardLayout],
                                    ignored: &HashSet<String>, spelling_aware: bool) -> bool {
        let layouts = Self::live_targets(layouts, source);
        if count(word) < 4 || ignored.contains(&word.to_lowercase()) || self.is_native_prefix(word, &source.languages) { return false; }
        if let Some(address) = self.suggest_address(word, source, &layouts) {
            return Self::is_explicit_address(&address.replacement) && !self.is_valid_native_text(word, source);
        }
        let mut native_alternative: Option<bool> = None;
        let mut prefix_native_alternative: Option<bool> = None;
        let suffix = core_and_suffix(word).1;
        layouts.iter().any(|target| {
            if target.id == source.id { return false; }
            let q = Query { ignored, preferred: Some(&target.id), context: "" };
            let exact = self.suggest_full(word, source, &layouts, q, false, true);
            let exact_found = exact.is_some();
            let Some(result) = exact.or_else(|| self.suggest_prefix_while_typing(word, source, &layouts, q)) else { return false };
            if spelling_aware && (suffix.is_empty() || result.replacement.ends_with(suffix)) {
                if !exact_found {
                    let alt = *prefix_native_alternative.get_or_insert_with(||
                        self.has_native_spelling_alternative(word, source, &result.replacement, 20_000));
                    if alt { return false; }
                } else {
                    let alt = *native_alternative.get_or_insert_with(||
                        self.has_native_spelling_alternative(word, source, &result.replacement, u32::MAX));
                    if alt { return false; }
                }
            }
            if result.target.id != target.id && target.is_cyrillic() && result.target.is_cyrillic() {
                if let Some(alt) = source.convert(word, target) {
                    if self.is_native_prefix(&alt, &target.languages) { return false; }
                }
            }
            true
        })
    }

    /// Typing stopped on a word too short to switch while it is typed (search fields get
    /// no Space): checked as a complete word, unless it may still grow into a native word.
    pub fn suggest_after_pause<'a>(&self, word: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout],
                                   q: Query) -> Option<Suggestion<'a>> {
        if !(2..=3).contains(&count(word)) || self.is_native_prefix(word, &source.languages) { return None; }
        self.suggest_full(word, source, &Self::live_targets(layouts, source), q, false, true)
    }

    pub fn may_suggest_after_pause(&self, word: &str, source: &KeyboardLayout, layouts: &[&KeyboardLayout],
                                   ignored: &HashSet<String>) -> bool {
        layouts.iter().any(|t| t.id != source.id
            && self.suggest_after_pause(word, source, layouts, Query { ignored, preferred: Some(&t.id), context: "" }).is_some())
    }

    /// Frequency corpora include initials (b, f, z). Only actual one-letter words count.
    fn suggest_single_letter<'a>(&self, word: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout],
                                 q: Query) -> Option<Suggestion<'a>> {
        fn is_word(value: &str, languages: &[Language]) -> bool {
            let lower = value.to_lowercase();
            languages.iter().any(|l| match l {
                Language::English => value == "a" || value == "A" || value == "I",
                Language::German => false,
                Language::Russian => count(&lower) == 1 && "яиауксвзо".contains(lower.as_str()),
                Language::Ukrainian => count(&lower) == 1 && "яіауйвзсоє".contains(lower.as_str()),
            })
        }
        let first = word.chars().next()?;
        if !is_letter(first) || is_word(word, &source.languages) { return None; }
        let candidates: Vec<Suggestion<'a>> = layouts.iter().filter_map(|&target| {
            if target.id == source.id { return None; }
            let output = source.convert(word, target)?;
            (output != word && is_word(&output, &target.languages))
                .then(|| Suggestion { original: word.into(), replacement: output, target, score: 1.0 })
        }).collect();
        // An initial inside English text (D, P) stays when the context is the source language.
        if is_uppercase(first) && !candidates.is_empty() {
            let mut targets: Vec<&KeyboardLayout> = vec![source];
            targets.extend(candidates.iter().map(|c| c.target));
            if self.context_preference(q.context, &targets).as_deref() == Some(source.id.as_str()) { return None; }
        }
        let preference = self.contextual_preference(q.context, &candidates).or_else(|| q.preferred.map(String::from));
        if let Some(p) = candidates.iter().find(|c| Some(&c.target.id) == preference.as_ref()) { return Some(p.clone()); }
        if candidates.len() == 1 { candidates.into_iter().next() } else { None }
    }
}

fn letters_of(s: &str) -> String { letters(s) }

fn prefix_start(prefix: &str, words: &[String]) -> usize {
    words.partition_point(|w| w.as_str() < prefix)
}
