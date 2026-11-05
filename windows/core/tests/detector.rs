//! Port of Tests/SwitchCoreTests/DetectorTests.swift on the Windows layouts. Inputs that
//! depend on key positions are adjusted: Windows Ukrainian has і on S and и on B, the
//! reverse of Apple Ukrainian Legacy.

use std::collections::HashSet;
use yasno_core::detector::Query;
use yasno_core::{layouts, word_boundary, Detector, KeyboardLayout, Language};

struct Fx { d: Detector, abc: KeyboardLayout, ru: KeyboardLayout, uk: KeyboardLayout, de: KeyboardLayout }
fn fx() -> Fx { Fx { d: Detector::default(), abc: layouts::us(), ru: layouts::russian(), uk: layouts::ukrainian(), de: layouts::german() } }
fn q() -> Query<'static> { Query::default() }

#[test]
fn dictionaries_present() {
    let d = Detector::default();
    for l in Language::ALL { assert!(d.count(l) > 25_000, "{l:?}"); }
}

#[test]
fn russian_and_ukrainian_are_separate() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    assert_eq!(f.d.suggest("ghbdtn", &f.abc, &all, q()).unwrap().replacement, "привет");
    assert_eq!(f.d.suggest("ghbdsn", &f.abc, &all, q()).unwrap().replacement, "привіт");
    assert_eq!(f.d.suggest("lzre.", &f.abc, &all, q()).unwrap().replacement, "дякую");
}

#[test]
fn english_and_german_use_latin() {
    let f = fx();
    let all = [&f.abc, &f.ru];
    assert_eq!(f.d.suggest("руддщ", &f.ru, &all, q()).unwrap().replacement, "hello");
    assert_eq!(f.d.suggest("пгеут", &f.ru, &all, q()).unwrap().replacement, "guten");
    assert_eq!(f.d.suggest("вфтлу", &f.ru, &all, q()).unwrap().replacement, "danke");
    for w in ["hello", "vielen", "guten", "Danke", "über", "Straße"] { assert!(f.d.suggest(w, &f.abc, &all, q()).is_none(), "{w}"); }
}

#[test]
fn case_preservation() {
    let f = fx();
    assert_eq!(f.d.suggest("Ghbdtn", &f.abc, &[&f.abc, &f.ru, &f.uk], q()).unwrap().replacement, "Привет");
}

#[test]
fn never_rewrite_valid_or_sensitive_patterns() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk, &f.de];
    for w in ["test", "hello", "API", "SwiftUI", "user@example.com", "abc123", "foo_bar", "https://abc.de", "x", "ok", "ghbdtn2"] {
        assert!(f.d.suggest(w, &f.abc, &all, q()).is_none(), "{w}");
    }
    for w in ["привет", "мир", "да", "код", "пока"] { assert!(f.d.suggest(w, &f.ru, &all, q()).is_none(), "{w}"); }
    let ignored: HashSet<String> = ["ghbdtn".to_string()].into();
    assert!(f.d.suggest("ghbdtn", &f.abc, &all, q().ignoring(&ignored)).is_none());
}

#[test]
fn layout_round_trip_and_german_qwertz() {
    let f = fx();
    assert_eq!(f.abc.convert("ghbdtn", &f.ru).unwrap(), "привет");
    assert_eq!(f.ru.convert("Привет", &f.abc).unwrap(), "Ghbdtn");
    assert_eq!(f.abc.convert("y", &f.de).unwrap(), "z");
    assert_eq!(f.abc.convert("z", &f.de).unwrap(), "y");
}

#[test]
fn shared_cyrillic_word_follows_manual_preference() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    let input = f.ru.convert("доброго", &f.abc).unwrap();
    assert!(f.d.suggest(&input, &f.abc, &all, q()).is_none());
    assert_eq!(f.d.suggest(&input, &f.abc, &all, q().preferring(&f.ru.id)).unwrap().target.id, f.ru.id);
    assert_eq!(f.d.suggest(&input, &f.abc, &all, q().preferring(&f.uk.id)).unwrap().target.id, f.uk.id);
}

#[test]
fn correct_cyrillic_text_never_changes_language() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk, &f.de];
    for (source, words) in [
        (&f.ru, ["привет", "спасибо", "пожалуйста", "сегодня", "доброго", "завтра", "работает", "сообщение"]),
        (&f.uk, ["привіт", "дякую", "вітаю", "сьогодні", "доброго", "завтра", "працює", "повідомлення"]),
    ] {
        for w in words {
            assert!(f.d.suggest(w, source, &all, q()).is_none(), "{w}");
            assert!(f.d.suggest(&format!("{w},"), source, &all, q()).is_none(), "{w},");
        }
    }
}

#[test]
fn completed_word_with_punctuation() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    assert_eq!(f.d.suggest("ghbdtn!", &f.abc, &all, q()).unwrap().replacement, "привет!");
    assert!(f.d.suggest("hello,", &f.abc, &all, q()).is_none());
    assert!(f.d.suggest("guten.", &f.abc, &all, q()).is_none());
}

#[test]
fn browser_nonbreaking_space_boundary() {
    assert!(word_boundary::matches("ghbdtn\u{00a0}", "ghbdtn", " "));
    assert!(word_boundary::matches("ghbdtn\u{202f}", "ghbdtn", " "));
    assert!(!word_boundary::matches("another\u{00a0}", "ghbdtn", " "));
    assert!(!word_boundary::matches("ghbdtn\n", "ghbdtn", " "));
    assert!(word_boundary::matches("hello \u{00a0}", "hello", "  "));
}

#[test]
fn manual_conversion() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    assert_eq!(f.d.convert_manually("привет мир", &f.ru, &all, None, None).unwrap().replacement, "ghbdtn vbh");
    assert_eq!(f.d.convert_manually("привіт", &f.uk, &all, None, None).unwrap().replacement, "ghbdsn");
    assert_eq!(f.d.convert_manually("руддщ", &f.ru, &all, None, None).unwrap().replacement, "hello");
    assert_eq!(f.d.convert_manually("ghbdsn", &f.abc, &all, None, None).unwrap().replacement, "привіт");
    let text = f.ru.convert("доброго", &f.abc).unwrap();
    assert_eq!(f.d.convert_manually(&text, &f.abc, &all, Some(&f.ru.id), None).unwrap().target.id, f.ru.id);
    assert_eq!(f.d.convert_manually(&text, &f.abc, &all, Some(&f.uk.id), None).unwrap().target.id, f.uk.id);
}

#[test]
fn two_letter_ukrainian_after_english() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    let s = f.d.suggest("zr", &f.abc, &all, q()).unwrap();
    assert_eq!((s.replacement.as_str(), s.target.id.as_str()), ("як", f.uk.id.as_str()));
    // ти on Windows Ukrainian is n + b (и is on B).
    assert_eq!(f.d.suggest("nb", &f.abc, &all, q().preferring(&f.uk.id)).unwrap().replacement, "ти");
}

#[test]
fn less_frequent_russian_inflection_from_ukrainian_layout() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    // короткими types the same on Windows RU and UK (и is on B in both), so only программы applies.
    for correct in ["программы"] {
        let wrong = f.ru.convert(correct, &f.uk).unwrap();
        let r = f.d.suggest(&wrong, &f.uk, &all, q()).unwrap();
        assert_eq!(r.replacement, correct);
        assert_eq!(r.target.id, f.ru.id);
    }
}

#[test]
fn context_does_not_cross_sentence_or_field_boundary() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    // On Windows "ns" is ты (RU) only; "nb" is ти (UK) / ти (RU ти is not a word).
    for ctx in ["як ти. ", "як ти\n", ""] {
        let r = f.d.suggest("nb", &f.abc, &all, q().context(ctx));
        assert!(r.as_ref().map_or(true, |s| s.target.id == f.uk.id), "{ctx:?}");
    }
}

#[test]
fn valid_short_words_are_preserved() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for (source, words) in [
        (&f.abc, vec!["a", "I", "as", "at", "be", "by", "do", "he", "in", "is", "it", "me", "no", "of", "on", "or", "so", "to", "we", "ok", "de", "du", "er", "es", "im", "ja", "zu"]),
        (&f.ru, vec!["я", "и", "ты", "да", "он", "мы", "вы", "не", "на", "до"]),
        (&f.uk, vec!["я", "і", "ти", "як", "ми", "ви", "це", "її", "не", "на"]),
    ] {
        for w in words { assert!(f.d.suggest(w, source, &all, q().preferring(&f.ru.id).context("як ти ")).is_none(), "{w}"); }
    }
    for w in ["ZR", "NS", "x", "v2", "a_b", "x:y"] {
        assert!(f.d.suggest(w, &f.abc, &all, q().preferring(&f.uk.id).context("як ти ")).is_none(), "{w}");
    }
}

#[test]
fn foreign_alphabet_entries_are_not_native_evidence() {
    let d = Detector::default();
    assert!(d.rank("ты", &[Language::Ukrainian]).is_none());
    assert!(d.rank("программы", &[Language::Ukrainian]).is_none());
    assert!(d.rank("і", &[Language::Russian]).is_none());
    assert!(d.rank("how", &[Language::Russian, Language::Ukrainian]).is_none());
    assert!(d.rank("Straße", &[Language::German]).is_some());
}

#[test]
fn correct_cyrillic_words_survive_opposite_language_context() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for w in ["короткими", "программы", "ты", "привет"] { assert!(f.d.suggest(w, &f.ru, &all, q().context("як ти почуваєш ")).is_none(), "{w}"); }
    for w in ["програми", "проблеми", "короткими", "ти", "привіт"] { assert!(f.d.suggest(w, &f.uk, &all, q().context("привет как дела ")).is_none(), "{w}"); }
    assert!(f.d.suggest("проргамми", &f.uk, &all, q()).is_none());
}

#[test]
fn full_mixed_language_phrase_uses_physical_keys() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    let mut source = &f.abc;
    let mut output = String::new();
    for (lang, word) in [(&f.ru, "привет"), (&f.abc, "how"), (&f.abc, "are"), (&f.abc, "you"),
                         (&f.uk, "як"), (&f.uk, "ти"), (&f.uk, "себе"), (&f.uk, "почуваєш")] {
        let keys = lang.convert(word, &f.abc).unwrap();
        let rendered = f.abc.convert(&keys, source).unwrap();
        match f.d.suggest(&rendered, source, &all, q().preferring(&f.ru.id).context(&output)) {
            Some(s) => { output += &format!("{} ", s.replacement); source = s.target; }
            None => output += &format!("{rendered} "),
        }
    }
    assert_eq!(output, "привет how are you як ти себе почуваєш ");
    assert_eq!(source.id, f.uk.id);
}

#[test]
fn web_addresses() {
    let f = fx();
    let all = [&f.abc, &f.ru];
    assert_eq!(f.d.suggest("фссщгтеюфзздуюсщь", &f.ru, &all, q()).unwrap().replacement, "account.apple.com");
}

#[test]
fn compound_latin_word() {
    let f = fx();
    let all = [&f.abc, &f.ru];
    assert_eq!(f.d.suggest("фззыещку", &f.ru, &all, q()).unwrap().replacement, "appstore");
}
