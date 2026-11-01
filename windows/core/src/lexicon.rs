//! The system spelling service: on the Mac NSSpellChecker, on Windows `ISpellChecker`.
//! It knows inflected forms (песках, українці, aufgetretene) that a 50k frequency list
//! misses. Used as a veto against changing valid text, as weak evidence for a converted
//! word and to confirm a rarer dictionary correction; it never proposes text by itself.

use crate::language::Language;

pub trait Lexicon: Send + Sync {
    /// None when the language's spelling dictionary is not installed or the service is off.
    fn knows(&self, word: &str, language: Language) -> Option<bool>;
    /// The service's suggestions one edit away from the word, lowercased.
    fn one_edit_guesses(&self, word: &str, language: Language) -> Vec<String>;

    fn knows_any(&self, word: &str, languages: &[Language]) -> bool {
        languages.iter().any(|&l| self.knows(word, l) == Some(true))
    }
}

/// No system dictionaries: the frequency lists decide alone (tests, or Windows
/// without the language packs).
pub struct NoLexicon;

impl Lexicon for NoLexicon {
    fn knows(&self, _: &str, _: Language) -> Option<bool> { None }
    fn one_edit_guesses(&self, _: &str, _: Language) -> Vec<String> { Vec::new() }
}
