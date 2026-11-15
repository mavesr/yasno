//! The Windows spelling service (`ISpellChecker`), the counterpart of NSSpellChecker in
//! the Mac version. It knows inflected forms the 50k frequency lists miss. A language
//! without an installed dictionary simply answers nothing.

use std::collections::HashMap;
use std::sync::Mutex;

use windows::core::{HSTRING, PWSTR};
use windows::Win32::Globalization::{ISpellChecker, ISpellCheckerFactory, SpellCheckerFactory};
use windows::Win32::System::Com::{CoCreateInstance, CoTaskMemFree, CLSCTX_INPROC_SERVER};
use yasno_core::word_text::{canonical, is_one_edit, is_orthographic_word};
use yasno_core::{Language, Lexicon};

pub struct WindowsLexicon {
    checkers: HashMap<Language, ISpellChecker>,
    known: Mutex<HashMap<(Language, String), bool>>,
    guesses: Mutex<HashMap<(Language, String), Vec<String>>>,
}

// Created on the detector thread after COM is initialized there and used only by it.
// ISpellChecker is free-threaded.
unsafe impl Send for WindowsLexicon {}
unsafe impl Sync for WindowsLexicon {}

fn tag(language: Language) -> &'static str {
    match language { Language::English => "en-US", Language::German => "de-DE", Language::Russian => "ru-RU", Language::Ukrainian => "uk-UA" }
}

impl WindowsLexicon {
    /// Call on a thread with COM initialized.
    pub fn new() -> WindowsLexicon {
        let mut checkers = HashMap::new();
        unsafe {
            if let Ok(factory) = CoCreateInstance::<_, ISpellCheckerFactory>(&SpellCheckerFactory, None, CLSCTX_INPROC_SERVER) {
                for language in Language::ALL {
                    let t = HSTRING::from(tag(language));
                    if factory.IsSupported(&t).map(|b| b.as_bool()).unwrap_or(false) {
                        if let Ok(checker) = factory.CreateSpellChecker(&t) { checkers.insert(language, checker); }
                    }
                }
            }
        }
        WindowsLexicon { checkers, known: Mutex::new(HashMap::new()), guesses: Mutex::new(HashMap::new()) }
    }

    pub fn languages(&self) -> Vec<Language> { self.checkers.keys().copied().collect() }

    fn checker(&self, word: &str, language: Language) -> Option<&ISpellChecker> {
        // The service checks each word of a string separately: им]я would pass as им + я.
        if word.chars().count() > 64 || !is_orthographic_word(word) { return None; }
        self.checkers.get(&language)
    }
}

impl Lexicon for WindowsLexicon {
    fn knows(&self, word: &str, language: Language) -> Option<bool> {
        let checker = self.checker(word, language)?;
        let key = (language, word.to_string());
        if let Some(&v) = self.known.lock().ok()?.get(&key) { return Some(v); }
        let known = unsafe {
            let errors = checker.Check(&HSTRING::from(word)).ok()?;
            let mut error = None;
            // S_FALSE with no error: the word is known.
            errors.Next(&mut error).is_ok() && error.is_none()
        };
        let mut cache = self.known.lock().ok()?;
        if cache.len() >= 100_000 { cache.clear(); }
        cache.insert(key, known);
        Some(known)
    }

    fn one_edit_guesses(&self, word: &str, language: Language) -> Vec<String> {
        let Some(checker) = self.checker(word, language) else { return Vec::new() };
        let key = (language, word.to_string());
        if let Some(v) = self.guesses.lock().ok().and_then(|c| c.get(&key).cloned()) { return v; }
        let mut raw = Vec::new();
        unsafe {
            if let Ok(list) = checker.Suggest(&HSTRING::from(word)) {
                loop {
                    let mut item = [PWSTR::null()];
                    let mut fetched = 0u32;
                    if list.Next(&mut item, Some(&mut fetched)).is_err() || fetched == 0 { break; }
                    if let Ok(s) = item[0].to_string() { raw.push(s); }
                    CoTaskMemFree(Some(item[0].0 as *const _));
                }
            }
        }
        let lower = canonical(&word.to_lowercase());
        // The service suggesting the word itself in capitals means it is a name typed in lowercase.
        let is_name = raw.iter().any(|g| canonical(&g.to_lowercase()) == lower);
        let mut guesses: Vec<String> = Vec::new();
        if !is_name {
            for g in raw {
                let candidate = canonical(&g.to_lowercase());
                if is_one_edit(&lower, &candidate) && !guesses.contains(&candidate) { guesses.push(candidate); }
            }
        }
        if let Ok(mut cache) = self.guesses.lock() {
            if cache.len() >= 20_000 { cache.clear(); }
            cache.insert(key, guesses.clone());
        }
        guesses
    }
}
