//! Port of Sources/SwitchCore/Spelling.swift: typo correction of completed words.

use std::collections::HashMap;

use crate::chars::{self, count, is_letter, is_uppercase, is_whitespace, letters};
use crate::detector::{Detector, Query, Suggestion};
use crate::geometry;
use crate::language::Language;
use crate::layout::KeyboardLayout;
use crate::web_address;
use crate::word_text::{self, canonical, core_and_suffix, is_apostrophe};

/// How much likelier the best of several close words must be. Chosen on the
/// scenario suite: lower values fix more slips but start changing intended words.
pub const AMBIGUITY_MARGIN: f64 = 30.0;

const COMMON_MISSPELLINGS: [(&str, &str); 19] = [
    ("recieve", "receive"), ("recieved", "received"), ("recieving", "receiving"),
    ("seperate", "separate"), ("seperately", "separately"), ("definately", "definitely"),
    ("occured", "occurred"), ("occurence", "occurrence"), ("untill", "until"),
    ("wierd", "weird"), ("beleive", "believe"), ("becuase", "because"),
    ("accomodation", "accommodation"),
    ("пожалуста", "пожалуйста"), ("пожалуйсто", "пожалуйста"), ("пожайлуста", "пожалуйста"),
    ("извените", "извините"), ("извени", "извини"), ("спосибо", "спасибо"),
];

const COGNATE_LETTERS: [(char, char); 9] = [
    ('ь', '\''), ('ъ', '\''), ('ы', 'и'), ('и', 'і'), ('э', 'е'), ('е', 'є'), ('ё', 'е'), ('г', 'ґ'), ('ї', 'і'),
];

fn alphabet(languages: &[Language]) -> &'static str {
    const LATIN: &str = "abcdefghijklmnopqrstuvwxyzäöüß";
    if languages.len() != 1 { return LATIN; }
    match languages[0] {
        Language::Russian => "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
        Language::Ukrainian => "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'",
        Language::English => "abcdefghijklmnopqrstuvwxyz",
        Language::German => LATIN,
    }
}

#[derive(Clone)]
struct Candidate<'a> {
    text: String,
    target: &'a KeyboardLayout,
    rank: u32,
    typed: String,
}

impl Candidate<'_> {
    /// Frequency (Zipf: 1/rank) times how likely this slip is on the keyboard.
    fn weight(&self) -> f64 { slip_likelihood(&self.typed, &self.text, self.target) / self.rank as f64 }
}

/// Swift `max(by:)`: the first of equally large elements.
fn first_max<'c, 'a>(items: impl Iterator<Item = &'c Candidate<'a>>) -> Option<&'c Candidate<'a>> where 'a: 'c {
    let mut best: Option<&Candidate> = None;
    for c in items { if best.map_or(true, |b| b.weight() < c.weight()) { best = Some(c); } }
    best
}

fn style_apostrophe(text: &str, style: &str) -> String { text.replace('\'', style) }

impl Detector {
    /// Spelling is deliberately a completed-word operation. It never sees prefixes
    /// through suggest_while_typing and can be disabled independently of layout repair.
    pub fn suggest_completed<'a>(&self, word: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout],
                                 q: Query, correct_spelling: bool) -> Option<Suggestion<'a>> {
        if let Some(layout) = self.suggest(word, source, layouts, q) {
            if correct_spelling && self.has_native_spelling_alternative(word, source, &layout.replacement, u32::MAX) {
                // Text alone cannot distinguish a native typo from a valid foreign word.
                // Context wins; an explicit target preference can resolve a tie.
                let contextual = self.context_preference(q.context, &[source, layout.target]);
                if contextual.as_deref() == Some(layout.target.id.as_str())
                    || (contextual.is_none() && q.preferred == Some(layout.target.id.as_str())) { return Some(layout); }
                if contextual.as_deref() == Some(source.id.as_str()) {
                    return self.suggest_spelling(word, source, &[source], q.preferring(&source.id));
                }
                return None;
            }
            return Some(layout);
        }
        if !correct_spelling { return None; }
        self.suggest_spelling(word, source, layouts, q)
    }

    pub(crate) fn has_native_spelling_alternative(&self, word: &str, source: &KeyboardLayout, replacement: &str, max_rank: u32) -> bool {
        let (core, suffix) = core_and_suffix(word);
        // A symbol at the end may encode a letter, e.g. lzre. → дякую.
        if !(suffix.is_empty() || replacement.ends_with(suffix)) { return false; }
        if !(4..=32).contains(&count(core)) || !word_text::is_orthographic_word(core)
            || self.rank(core, &source.languages).is_some() { return false; }
        self.has_spelling_neighbor(&canonical(&core.to_lowercase()), &source.languages, max_rank)
    }

    pub fn may_suggest_completed(&self, word: &str, source: &KeyboardLayout, layouts: &[&KeyboardLayout],
                                 ignored: &std::collections::HashSet<String>, correct_spelling: bool) -> bool {
        if self.may_suggest(word, source, layouts, ignored) { return true; }
        if !correct_spelling { return false; }
        self.spelling_suggestion(word, source, layouts, Query { ignored, preferred: None, context: "" }, true).is_some()
    }

    pub fn suggest_spelling<'a>(&self, word: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout],
                                q: Query) -> Option<Suggestion<'a>> {
        self.spelling_suggestion(word, source, layouts, q, false)
    }

    fn spelling_suggestion<'a>(&self, word: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout],
                               q: Query, allow_unresolved_preference: bool) -> Option<Suggestion<'a>> {
        if q.ignored.contains(&word.to_lowercase()) || count(word) > 40 { return None; }
        let (raw_core, suffix) = core_and_suffix(word);
        // An exception stays one when punctuation follows it.
        if q.ignored.contains(&raw_core.to_lowercase()) { return None; }
        let core = canonical(raw_core);
        let core_letters = letters(&core);
        let core_count = count(&core);
        let capitalized = core.chars().next().is_some_and(is_uppercase);
        if !(3..=32).contains(&core_count) || core_letters.is_empty()
            || !core.chars().all(|c| is_letter(c) || ",.;:'[]\\`".contains(c))
            || core_letters == core_letters.to_uppercase()
            || core_letters.chars().skip(1).any(is_uppercase)
            || web_address::recognizes(word) { return None; }
        // Frequency corpora contain a few well-known misspellings.
        let lower_core = core.to_lowercase();
        if let Some(&(_, correction)) = COMMON_MISSPELLINGS.iter().find(|(w, _)| *w == lower_core) {
            if self.rank(correction, &source.languages).is_some() && !q.ignored.contains(correction) {
                let text = if capitalized { chars::capitalize_first(correction) } else { correction.to_string() };
                return Some(Suggestion { original: word.into(), replacement: text + suffix, target: source, score: 1.0 });
            }
        }
        if self.rank(&core, &source.languages).is_some() { return None; }
        // Valid text is never respelled: a form of another language typed with this alphabet.
        let source_cyrillic = source.is_cyrillic();
        let mut same_alphabet: Vec<Language> = layouts.iter().filter(|l| l.is_cyrillic() == source_cyrillic)
            .flat_map(|l| l.languages.iter().copied()).collect();
        same_alphabet.extend(source.languages.iter().copied());
        if self.rank(&core, &same_alphabet).is_some() { return None; }
        let mut candidates: Vec<Candidate<'a>> = Vec::new();
        for &target in layouts {
            // Preserve the source alphabet first.
            if target.id != source.id && source_cyrillic == target.is_cyrillic() { continue; }
            let rendered = if target.id == source.id { Some(core.clone()) } else { source.convert(&core, target) };
            let Some(rendered) = rendered else { continue };
            if !(rendered.chars().all(is_letter) || (target.has_language(Language::Ukrainian) && word_text::is_orthographic_word(&rendered)))
                || self.rank(&rendered, &target.languages).is_some() { continue; }
            let typed = canonical(&rendered.to_lowercase());
            let neighbors = self.spelling_neighbors(&typed, &target.languages);
            // A valid word in another alphabet is a layout question, not a typo.
            if neighbors.is_empty() || (target.id != source.id && self.lexicon.knows_any(&rendered, &target.languages)) { continue; }
            for (text, rank) in neighbors {
                candidates.push(Candidate { text, target, rank, typed: typed.clone() });
            }
        }
        candidates.sort_by(|a, b| a.rank.cmp(&b.rank).then_with(|| (&a.text, &a.target.id).cmp(&(&b.text, &b.target.id))));
        // Long Russian and Ukrainian inflections the 50k list lacks: accept the spelling
        // service's guess when it is the only one, one natural slip away, and lowercase.
        if candidates.is_empty() && source_cyrillic && core_count >= 6 && !capitalized
            && !self.lexicon.knows_any(raw_core, &same_alphabet) {
            let typed = canonical(&raw_core.to_lowercase());
            let mut guesses: Vec<String> = source.languages.iter().flat_map(|&l| self.lexicon.one_edit_guesses(raw_core, l)).collect();
            guesses.sort();
            guesses.dedup();
            if guesses.len() == 1 {
                let guess = &guesses[0];
                if !q.ignored.contains(guess) && !drops_doubled_letter(&typed, guess)
                    && slip_likelihood(&typed, guess, source) >= 0.5 {
                    let style = raw_core.chars().find(|&c| is_apostrophe(c)).map(String::from)
                        .unwrap_or_else(|| source.apostrophe_glyph().to_string());
                    return Some(Suggestion { original: word.into(), replacement: style_apostrophe(guess, &style) + suffix,
                                             target: source, score: 0.2 });
                }
            }
        }
        let best = candidates.first()?.clone();
        if self.lexicon.knows_any(raw_core, &same_alphabet) { return None; }
        // Frequency is not proof of intent: another candidate means abstention unless the
        // best one is far likelier. RU/UK spellings of one word need the sentence's language.
        if let Some(rival) = first_max(candidates.iter().filter(|c| c.text != best.text)) {
            let leader = first_max(candidates.iter().filter(|c| c.text != rival.text)).unwrap_or(&best);
            let margin = AMBIGUITY_MARGIN * if capitalized { 3.0 } else { 1.0 };
            if leader.text != best.text || leader.weight() < margin * rival.weight() { return None; }
            let counterparts: Vec<&KeyboardLayout> = candidates.iter()
                .filter(|c| c.target.id != best.target.id && are_cognates(&c.text, &best.text)).map(|c| c.target).collect();
            if !counterparts.is_empty() {
                let mut targets = vec![best.target];
                targets.extend(counterparts);
                if self.context_preference(q.context, &targets).as_deref() != Some(best.target.id.as_str()) { return None; }
            }
        }
        // A rarer word needs the spelling service to agree that it is the only close word.
        if best.rank > 20_000 {
            if !(best.rank <= 50_000 && core_count >= 6 && best.target.id == source.id
                && source.languages.iter().any(|&l| self.lexicon.one_edit_guesses(raw_core, l) == [best.text.clone()])) { return None; }
        }
        // A capital inside a sentence marks a name, except for German nouns.
        if capitalized && is_inside_sentence(q.context)
            && !(best.target.has_language(Language::German) && self.rank(&best.text, &[Language::German]).is_some()
                 && (self.rank(&best.text, &[Language::English]).is_none() || self.leans_german(q.context))) { return None; }
        let identical: Vec<&Candidate<'a>> = candidates.iter().filter(|c| c.text == best.text).collect();
        let identical_targets: Vec<&KeyboardLayout> = identical.iter().map(|c| c.target).collect();
        let contextual = self.context_preference(q.context, &identical_targets).or_else(|| q.preferred.map(String::from));
        let mut distinct: Vec<&str> = identical.iter().map(|c| c.target.id.as_str()).collect();
        distinct.sort_unstable();
        distinct.dedup();
        let chosen: &Candidate<'a> = if let Some(p) = identical.iter().find(|c| Some(&c.target.id) == contextual.as_ref()) { p }
            else if allow_unresolved_preference || distinct.len() == 1 { &best }
            else { return None };
        let style = raw_core.chars().find(|&c| is_apostrophe(c)).map(String::from)
            .unwrap_or_else(|| chosen.target.apostrophe_glyph().to_string());
        let styled = style_apostrophe(&chosen.text, &style);
        let output = if capitalized { chars::capitalize_first(&styled) } else { styled };
        let lower_output = output.to_lowercase();
        if q.ignored.contains(&lower_output) || q.ignored.contains(&canonical(&lower_output)) { return None; }
        Some(Suggestion { original: word.into(), replacement: output + suffix, target: chosen.target,
                          score: (50_001.0 / chosen.rank as f64).log10() })
    }

    /// The last words of the sentence are clearly more German than English.
    pub(crate) fn leans_german(&self, context: &str) -> bool {
        let start = context.char_indices().rev().find(|&(_, c)| ".!?\n".contains(c)).map(|(i, c)| i + c.len_utf8()).unwrap_or(0);
        let words: Vec<&str> = context[start..].split(is_whitespace).filter(|w| !w.is_empty()).collect();
        let mut score = 0i32;
        for raw in &words[words.len().saturating_sub(6)..] {
            let word = chars::trim_punctuation(raw);
            let german = self.rank(word, &[Language::German]);
            let english = self.rank(word, &[Language::English]);
            if let Some(g) = german { if english.map_or(true, |e| g * 4 < e) { score += 1; } }
            if let Some(e) = english { if german.map_or(true, |g| e * 4 < g) { score -= 1; } }
        }
        score > 0
    }

    /// The visitor can stop as soon as existence is proved.
    fn visit_spelling_neighbors(&self, word: &str, languages: &[Language], visit: &mut dyn FnMut(&str, u32) -> bool) {
        let letters: Vec<char> = word.chars().collect();
        let alphabet: Vec<char> = alphabet(languages).chars().collect();
        let mut consider = |buffer: &[char]| -> bool {
            let text: String = buffer.iter().collect();
            match self.rank_lowercased(&text, languages) { Some(r) => visit(&text, r), None => false }
        };
        let mut buffer = letters.clone();
        for index in 0..letters.len() {
            buffer.remove(index);
            if consider(&buffer) { return; }
            buffer.insert(index, letters[index]);
            if index + 1 < letters.len() && letters[index] != letters[index + 1] {
                buffer.swap(index, index + 1);
                if consider(&buffer) { return; }
                buffer.swap(index, index + 1);
            }
            for &letter in alphabet.iter().filter(|&&l| l != letters[index]) {
                buffer[index] = letter;
                if consider(&buffer) { return; }
            }
            buffer[index] = letters[index];
        }
        for index in 0..=letters.len() {
            buffer.insert(index, ' ');
            for &letter in &alphabet {
                buffer[index] = letter;
                if consider(&buffer) { return; }
            }
            buffer.remove(index);
        }
    }

    fn has_spelling_neighbor(&self, word: &str, languages: &[Language], max_rank: u32) -> bool {
        let mut found = false;
        self.visit_spelling_neighbors(word, languages, &mut |_, rank| {
            if rank > max_rank { return false; }
            found = true;
            true
        });
        found
    }

    fn spelling_neighbors(&self, word: &str, languages: &[Language]) -> HashMap<String, u32> {
        let mut found = HashMap::new();
        self.visit_spelling_neighbors(word, languages, &mut |text, rank| { found.insert(text.to_string(), rank); false });
        found
    }
}

pub fn is_inside_sentence(context: &str) -> bool {
    match context.chars().rev().find(|&c| !is_whitespace(c)) {
        None => false,
        Some(last) => !".!?…\n".contains(last) && !"\"«“„(".contains(last),
    }
}

/// One word in its Russian and Ukrainian spelling: same length, differing only in
/// letters the two orthographies swap.
pub fn are_cognates(a: &str, b: &str) -> bool {
    let x: Vec<char> = a.chars().collect();
    let y: Vec<char> = b.chars().collect();
    if x.len() != y.len() || x == y { return false; }
    x.iter().zip(&y).all(|(&p, &q)| p == q || COGNATE_LETTERS.iter().any(|&(m, n)| (m == p && n == q) || (m == q && n == p)))
}

/// `intended` is `typed` with one of two equal neighbouring letters removed.
pub fn drops_doubled_letter(typed: &str, intended: &str) -> bool {
    let t: Vec<char> = typed.chars().collect();
    let w: Vec<char> = intended.chars().collect();
    if t.len() != w.len() + 1 { return false; }
    let mut i = 0;
    while i < w.len() && t[i] == w[i] { i += 1; }
    (i > 0 && t[i - 1] == t[i]) || (i + 1 < t.len() && t[i + 1] == t[i])
}

/// Relative likelihood that `typed` came from `intended` by one slip, on this layout.
pub fn slip_likelihood(typed: &str, intended: &str, layout: &KeyboardLayout) -> f64 {
    let t: Vec<char> = typed.chars().collect();
    let w: Vec<char> = intended.chars().collect();
    if t.len().abs_diff(w.len()) > 1 { return 0.0; }
    let near = |a: char, b: char| match (layout.key(a), layout.key(b)) {
        (Some(x), Some(y)) => geometry::are_neighbours(x, y),
        _ => false,
    };
    if t.len() == w.len() {
        let diff: Vec<usize> = (0..t.len()).filter(|&i| t[i] != w[i]).collect();
        if diff.len() == 1 { return if near(t[diff[0]], w[diff[0]]) { 1.0 } else { 0.05 }; }
        return 0.7; // a swap of neighbouring letters
    }
    if t.len() == w.len() + 1 {
        let mut i = 0;
        while i < w.len() && t[i] == w[i] { i += 1; }
        let extra = t[i];
        let before = if i > 0 { Some(t[i - 1]) } else { None };
        let after = t.get(i + 1).copied();
        if Some(extra) == before || Some(extra) == after { return 0.7; }
        if before.is_some_and(|b| near(extra, b)) || after.is_some_and(|a| near(extra, a)) { return 0.5; }
        return 0.05;
    }
    let mut i = 0;
    while i < t.len() && t[i] == w[i] { i += 1; }
    let missing = w[i];
    if (i > 0 && w[i - 1] == missing) || (i + 1 < w.len() && w[i + 1] == missing) { return 0.8; }
    0.4
}
