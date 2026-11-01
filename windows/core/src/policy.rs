//! Port of Sources/SwitchCore/CorrectionPolicy.swift: one typed word as the app sees it.

use std::collections::HashSet;

use crate::chars::{self, count, is_letter};
use crate::detector::{Detector, Query, Suggestion};
use crate::layout::KeyboardLayout;
use crate::word_text::{canonical, is_closing_symbol, is_prefix_punctuation};

#[derive(Clone)]
pub struct CorrectionRequest<'a> {
    pub text: String,
    pub source: &'a KeyboardLayout,
    pub layouts: Vec<&'a KeyboardLayout>,
    pub ignored: HashSet<String>,
    pub preferred_target_id: Option<String>,
    pub correct_spelling: bool,
    pub while_typing: bool,
    /// The word was already converted while typing and is being continued.
    pub live_converted: bool,
    /// Typing stopped on a word too short to be checked while it is typed.
    pub paused: bool,
}

impl<'a> CorrectionRequest<'a> {
    #[allow(clippy::too_many_arguments)]
    pub fn new(text: &str, source: &'a KeyboardLayout, layouts: &[&'a KeyboardLayout], ignored: &HashSet<String>,
               preferred_target_id: Option<&str>, correct_spelling: bool, while_typing: bool,
               live_converted: bool, paused: bool) -> Self {
        // An exception written with one apostrophe also covers the others.
        let mut all = ignored.clone();
        all.extend(ignored.iter().map(|w| canonical(&w.to_lowercase())));
        CorrectionRequest { text: text.into(), source, layouts: layouts.to_vec(), ignored: all,
                            preferred_target_id: preferred_target_id.map(String::from), correct_spelling,
                            while_typing, live_converted, paused }
    }

    fn with_text(&self, text: &str) -> Self { CorrectionRequest { text: text.into(), ..self.clone() } }

    fn is_ignored(&self) -> bool {
        let lower = self.text.to_lowercase();
        self.ignored.contains(&lower) || self.ignored.contains(&canonical(&lower))
    }

    /// Symbols before a word stay as typed, unless another layout puts a letter on that key.
    fn opening_symbols(&self) -> Option<String> {
        let prefix: String = self.text.chars().take_while(|&c| is_prefix_punctuation(c)).collect();
        if prefix.is_empty() || count(&prefix) >= count(&self.text) { return None; }
        let letter_elsewhere = self.layouts.iter().any(|l| l.id != self.source.id
            && self.source.convert(&prefix, l).is_some_and(|c| c.chars().any(is_letter)));
        if letter_elsewhere { None } else { Some(prefix) }
    }

    /// A currency sign straight after the word stays as typed.
    fn closing_symbols(&self) -> Option<String> {
        let n = self.text.chars().rev().take_while(|&c| is_closing_symbol(c)).count();
        if n == 0 || n >= count(&self.text) { return None; }
        Some(chars::suffix(&self.text, n).to_string())
    }

    fn query(&self) -> Query<'_> {
        Query { ignored: &self.ignored, preferred: self.preferred_target_id.as_deref(), context: "" }
    }
}

impl Detector {
    /// Checked before input is held. False means no correction can follow.
    pub fn may_correct(&self, r: &CorrectionRequest) -> bool {
        if r.is_ignored() { return false; }
        if let Some(prefix) = r.opening_symbols() { return self.may_correct(&r.with_text(chars::drop_first(&r.text, count(&prefix)))); }
        if let Some(suffix) = r.closing_symbols() { return self.may_correct(&r.with_text(chars::drop_last(&r.text, count(&suffix)))); }
        if r.live_converted {
            if r.while_typing || !r.correct_spelling { return false; }
            return self.suggest_spelling(&r.text, r.source, &r.layouts, r.query()).is_some();
        }
        if r.while_typing && r.paused { return self.may_suggest_after_pause(&r.text, r.source, &r.layouts, &r.ignored); }
        if r.while_typing {
            self.may_suggest_while_typing(&r.text, r.source, &r.layouts, &r.ignored, r.correct_spelling)
        } else {
            self.may_suggest_completed(&r.text, r.source, &r.layouts, &r.ignored, r.correct_spelling)
        }
    }

    /// The replacement for the word, given up to 256 characters typed before it.
    pub fn correction<'a>(&self, r: &CorrectionRequest<'a>, context: &str) -> Option<Suggestion<'a>> {
        if r.is_ignored() { return None; }
        if let Some(prefix) = r.opening_symbols() {
            let inner = r.with_text(chars::drop_first(&r.text, count(&prefix)));
            return self.correction(&inner, &format!("{context}{prefix}")).map(|s| Suggestion {
                original: r.text.clone(), replacement: format!("{prefix}{}", s.replacement), target: s.target, score: s.score });
        }
        if let Some(suffix) = r.closing_symbols() {
            let inner = r.with_text(chars::drop_last(&r.text, count(&suffix)));
            return self.correction(&inner, context).map(|s| Suggestion {
                original: r.text.clone(), replacement: s.replacement + &suffix, target: s.target, score: s.score });
        }
        let q = r.query().context(context);
        if r.live_converted {
            if r.while_typing || !r.correct_spelling { return None; }
            return self.suggest_spelling(&r.text, r.source, &r.layouts, q);
        }
        if r.while_typing && r.paused { return self.suggest_after_pause(&r.text, r.source, &r.layouts, q); }
        if r.while_typing {
            self.suggest_while_typing(&r.text, r.source, &r.layouts, q, r.correct_spelling)
        } else {
            self.suggest_completed(&r.text, r.source, &r.layouts, q, r.correct_spelling)
        }
    }
}
