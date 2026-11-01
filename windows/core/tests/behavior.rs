//! Ports of LiveTypingTests, ReportedWordTests, SpellingTests, ShortWordPauseTests and
//! KeystrokeEditTests on the Windows layouts. Cases that relied on Apple Ukrainian Legacy
//! key positions use the Windows positions (і on S, и on B).

use std::collections::HashSet;
use yasno_core::detector::Query;
use yasno_core::{layouts, web_address, CorrectionRequest, Detector, KeyboardLayout, KeystrokeEdit};

struct Fx { d: Detector, abc: KeyboardLayout, ru: KeyboardLayout, uk: KeyboardLayout, de: KeyboardLayout }
fn fx() -> Fx { Fx { d: Detector::default(), abc: layouts::us(), ru: layouts::russian(), uk: layouts::ukrainian(), de: layouts::german() } }
fn q() -> Query<'static> { Query::default() }
fn set(words: &[&str]) -> HashSet<String> { words.iter().map(|w| w.to_string()).collect() }
fn none() -> HashSet<String> { HashSet::new() }

#[test]
fn addresses_convert_automatically_live_and_manually() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    let long = format!("https://example.com/{}", "a".repeat(200));
    for address in ["account.apple.com", "qzx-service123.org", "example.co.uk", "unknown-brand.dev", "example.museum",
                    "example.berlin", "https://example.com/path?q=3", "example.net:8080/path", long.as_str()] {
        assert!(web_address::recognizes(address), "{address}");
        for source in [&f.ru, &f.uk] {
            let input = f.abc.convert(address, source).unwrap();
            assert!(f.d.may_suggest(&input, source, &all, &none()), "{address}");
            assert_eq!(f.d.suggest(&input, source, &all, q()).unwrap().replacement, address);
            assert_eq!(f.d.suggest_while_typing(&input, source, &all, q(), false).unwrap().replacement, address);
            assert_eq!(f.d.convert_text_manually(&input, source, &f.abc, None).unwrap(), address);
        }
    }
    assert_eq!(f.d.suggest("фссщгте.фззду.сщь", &f.ru, &all, q()).unwrap().replacement, "account.apple.com");
    let ignored = set(&["фссщгтеюфзздуюсщь"]);
    assert!(f.d.suggest("фссщгтеюфзздуюсщь", &f.ru, &all, q().ignoring(&ignored)).is_none());
}

#[test]
fn domain_syntax_rejects_code_email_and_malformed_hosts() {
    let f = fx();
    let long = format!("{}.com", "a".repeat(64));
    for input in ["foo.barDoesNotExist", "user@example.com", "foo_bar.com", "-bad.com", "bad-.com", "bad..com", "x.com:0",
                  "x.com:65536", "x.com:", "ftp://example.com", "x.com hello", "index.html", "127.0.0.1", "x..", long.as_str()] {
        assert!(!web_address::recognizes(input), "{input}");
    }
    for input in ["account.apple.com", "user@example.com", "foo_bar", "https://abc.de"] {
        assert!(f.d.suggest(input, &f.abc, &[&f.abc, &f.ru], q()).is_none(), "{input}");
    }
}

#[test]
fn confident_words_switch_before_space_short_prefixes_wait() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for (input, output, source) in [("ghbdtn", "привет", &f.abc), ("руддщ", "hello", &f.ru),
                                    (",hfepth", "браузер", &f.abc), ("фззсщттусе", "appconnect", &f.ru)] {
        assert!(f.d.may_suggest_while_typing(input, source, &all, &none(), false), "{input}");
        assert_eq!(f.d.suggest_while_typing(input, source, &all, q().preferring(&f.ru.id), false).unwrap().replacement, output);
    }
    for input in ["z", "b", "f", "ns", "ghb", "API", "SwiftUI", "hello", "привет"] {
        let source = if input == "привет" { &f.ru } else { &f.abc };
        assert!(f.d.suggest_while_typing(input, source, &all, q().preferring(&f.ru.id), false).is_none(), "{input}");
    }
}

#[test]
fn typing_simulation_keeps_continuation_after_early_conversion() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for (initial, intended, word) in [(&f.abc, &f.ru, "привет"), (&f.ru, &f.abc, "hello"), (&f.ru, &f.abc, "Github"),
                                      (&f.uk, &f.abc, "Github"), (&f.abc, &f.ru, "изучи"), (&f.abc, &f.ru, "изучить"),
                                      (&f.abc, &f.ru, "изучать"), (&f.abc, &f.ru, "изучите"), (&f.abc, &f.ru, "Изучение"),
                                      (&f.abc, &f.ru, "продумай"), (&f.abc, &f.ru, "продумайте"),
                                      (&f.abc, &f.ru, "переключались"), (&f.abc, &f.ru, "переключалась"),
                                      (&f.ru, &f.abc, "account.apple.com"), (&f.uk, &f.abc, "unknown-brand.dev")] {
        let physical = intended.convert(word, &f.abc).unwrap();
        let (mut source, mut rendered, mut converted) = (initial, String::new(), false);
        for key in physical.chars() {
            rendered += &f.abc.convert(&key.to_string(), source).unwrap();
            if !converted {
                if let Some(r) = f.d.suggest_while_typing(&rendered, source, &all, q().preferring(&f.ru.id), false) {
                    rendered = r.replacement; source = r.target; converted = true;
                }
            }
        }
        assert!(converted, "{word}");
        assert_eq!(rendered, word);
        assert_eq!(source.id, intended.id, "{word}");
    }
}

#[test]
fn native_prefixes_never_change_while_typing() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for (source, word) in [(&f.abc, "information"), (&f.abc, "browser"), (&f.abc, "account"), (&f.ru, "приветствие"),
                           (&f.ru, "использовать"), (&f.uk, "користуватися"), (&f.ru, "переключаются")] {
        let chars: Vec<char> = word.chars().collect();
        for n in 4..=chars.len() {
            let prefix: String = chars[..n].iter().collect();
            assert!(f.d.suggest_while_typing(&prefix, source, &all, q().preferring(&f.ru.id), false).is_none(), "{prefix}");
        }
    }
}

fn decide(f: &Fx, text: &str, source: &KeyboardLayout, layouts: &[&KeyboardLayout], typing: bool, preferred: Option<&str>) -> Option<String> {
    let r = CorrectionRequest::new(text, source, layouts, &none(), preferred, true, typing, false, false);
    if !f.d.may_correct(&r) { return None; }
    f.d.correction(&r, "").map(|s| s.replacement)
}

#[test]
fn reported_words() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    let ru = Some(f.ru.id.as_str());
    // German 'nen on Latin is almost always "тут" typed in the wrong layout.
    assert_eq!(decide(&f, "nen", &f.abc, &all, false, ru).as_deref(), Some("тут"));
    // A currency sign after a word stays as typed.
    assert_eq!(decide(&f, "nsc", &f.abc, &all, false, ru).as_deref(), Some("тыс"));
    assert_eq!(decide(&f, "nsc$", &f.abc, &all, false, ru).as_deref(), Some("тыс$"));
    assert_eq!(f.d.convert_manually("nsc$", &f.abc, &all, ru, None).unwrap().replacement, "тыс$");
    assert_eq!(decide(&f, "ghbdtn$", &f.abc, &all, false, ru).as_deref(), Some("привет$"));
    assert_eq!(decide(&f, "ghbdtn$", &f.abc, &all, true, ru).as_deref(), Some("привет$"));
    assert_eq!(decide(&f, "ghbdtn€", &f.abc, &all, false, ru).as_deref(), Some("привет€"));
    assert_eq!(decide(&f, "cost$", &f.abc, &all, false, ru), None);
    assert_eq!(decide(&f, "$", &f.abc, &all, false, ru), None);
    // Symbols before a word stay, the word converts.
    for (input, expected, source) in [("/вумудщзук", "/developer", &f.ru), ("«руддщ", "«hello", &f.ru),
                                      ("(ghbdtn", "(привет", &f.abc), ("#ghbdtn", "#привет", &f.abc)] {
        assert_eq!(decide(&f, input, source, &all, false, None).as_deref(), Some(expected), "{input}");
    }
    assert_eq!(decide(&f, "[jxe", &f.abc, &all, false, ru).as_deref(), Some("хочу"));
    for (valid, source) in [("(даже", &f.ru), ("(сдела", &f.ru), ("/developer", &f.abc), ("«hello", &f.abc)] {
        assert_eq!(decide(&f, valid, source, &all, true, None), None, "{valid}");
    }
    for valid in ["\"Verfass", "\"Verfassung\"."] {
        assert_eq!(decide(&f, valid, &f.de, &[&f.de, &f.ru], true, None), None, "{valid}");
        assert_eq!(decide(&f, valid, &f.de, &[&f.de, &f.ru], false, None), None, "{valid}");
    }
}

#[test]
fn github_and_izuchi_in_all_modes() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for (source, target, pairs) in [(&f.ru, &f.abc, [("Пшерги", "Github"), ("пшерги", "github")]),
                                    (&f.abc, &f.ru, [("bpexb", "изучи"), ("Bpexb", "Изучи")])] {
        for (input, expected) in pairs {
            for spelling in [false, true] {
                assert!(f.d.may_suggest_while_typing(input, source, &all, &none(), spelling), "{input}");
                assert_eq!(f.d.suggest_while_typing(input, source, &all, q().preferring(&target.id), spelling).unwrap().replacement, expected);
                for suffix in ["", "!", ",", ".", "…"] {
                    let w = format!("{input}{suffix}");
                    assert_eq!(f.d.suggest_completed(&w, source, &all, q().preferring(&target.id), spelling).unwrap().replacement,
                               format!("{expected}{suffix}"), "{w}");
                }
            }
            assert_eq!(f.d.convert_manually(input, source, &all, Some(&target.id), None).unwrap().replacement, expected);
            assert!(f.d.suggest_completed(expected, target, &all, q(), true).is_none());
        }
    }
    for (input, expected) in [("bpex", "изуч"), ("Bpex", "Изуч")] {
        let r = f.d.suggest_while_typing(input, &f.abc, &all, q().preferring(&f.ru.id), true).unwrap();
        assert_eq!((r.replacement.as_str(), r.target.id.as_str()), (expected, f.ru.id.as_str()));
        // A prefix is evidence only during typing, never a completed dictionary word.
        assert!(f.d.suggest_completed(input, &f.abc, &all, q().preferring(&f.ru.id), true).is_none());
    }
}

#[test]
fn spelling_option_and_layout_repair_are_independent() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for (source, pairs) in [(&f.ru, vec![("првиет", "привет"), ("спасиибо", "спасибо"), ("пожалуста", "пожалуйста")]),
                            (&f.uk, vec![("привті", "привіт"), ("дякуую", "дякую")]),
                            (&f.abc, vec![("helllo", "hello"), ("wrold", "world"), ("recieve", "receive"), ("dannke", "danke")])] {
        for (wrong, correct) in pairs {
            let ignored = set(&[wrong]);
            for suffix in ["", ",", ".", "!", "?!", "…"] {
                let w = format!("{wrong}{suffix}");
                assert_eq!(f.d.suggest_completed(&w, source, &all, q().preferring(&source.id), true).unwrap().replacement,
                           format!("{correct}{suffix}"), "{w}");
                assert!(f.d.suggest_completed(&w, source, &all, q(), false).is_none(), "{w}");
                assert!(f.d.suggest_completed(&w, source, &all, q().ignoring(&ignored), true).is_none(), "{w}");
                assert!(!f.d.may_suggest_completed(&w, source, &all, &ignored, true), "{w}");
            }
            assert!(f.d.may_suggest_completed(wrong, source, &all, &none(), true));
        }
    }
    for enabled in [false, true] {
        assert_eq!(f.d.suggest_completed("ghbdtn", &f.abc, &all, q(), enabled).unwrap().replacement, "привет");
    }
}

#[test]
fn wrong_layout_plus_typo_and_capitalization() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for (input, source, expected, target) in [("ghdbtn", &f.abc, "привет", &f.ru), ("рудддщ", &f.ru, "hello", &f.abc),
                                              ("Првиет", &f.ru, "Привет", &f.ru), ("Helllo", &f.abc, "Hello", &f.abc)] {
        let r = f.d.suggest_completed(input, source, &all, q().preferring(&target.id), true).unwrap();
        assert_eq!((r.replacement.as_str(), r.target.id.as_str()), (expected, target.id.as_str()), "{input}");
    }
}

#[test]
fn valid_words_survive_spelling() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for (source, words) in [(&f.abc, vec!["form", "from", "quite", "quiet", "trial", "trail", "herb", "Herb", "permissions",
                                          "benutzern", "fensters", "Danek", "API", "SwiftUI"]),
                            (&f.ru, vec!["словари", "сообщениям", "системная", "привет", "продумайте"]),
                            (&f.uk, vec!["повідомленням", "системна", "клавіші", "браузери"])] {
        for w in words { assert!(f.d.suggest_completed(w, source, &all, q(), true).is_none(), "{w}"); }
    }
    for input in ["hello_world", "helllo2", "helllo@example.com", "https://helllo.com", "HELLLO", "hElllo"] {
        assert!(f.d.suggest_completed(input, &f.abc, &all, q(), true).is_none(), "{input}");
    }
}

#[test]
fn physical_punctuation_is_not_a_spelling_alternative() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for suffix in ["", "!", ",", "…"] {
        assert_eq!(f.d.suggest_completed(&format!("lzre.{suffix}"), &f.abc, &all, q().preferring(&f.uk.id), true).unwrap().replacement,
                   format!("дякую{suffix}"));
    }
    assert_eq!(f.d.suggest_while_typing("lzre.", &f.abc, &all, q().preferring(&f.uk.id), true).unwrap().replacement, "дякую");
}

#[test]
fn native_spelling_cannot_override_explicit_foreign_choice() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for (input, source, expected, target) in [("фищму", &f.ru, "above", &f.abc), ("привыт", &f.ru, "привіт", &f.uk)] {
        let r = f.d.suggest_completed(input, source, &all, q().preferring(&target.id), true).unwrap();
        assert_eq!((r.replacement.as_str(), r.target.id.as_str()), (expected, target.id.as_str()), "{input}");
    }
    assert!(f.d.suggest_completed("фищму", &f.ru, &all, q(), true).is_none());
}

#[test]
fn preferred_language_prefix_prevents_wrong_cyrillic_handoff() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    for correct in ["клавиатура", "клавиатуры", "клавишу", "клавиши", "маленький"] {
        let keys = f.ru.convert(correct, &f.abc).unwrap();
        let (mut source, mut actual, mut converted) = (&f.abc, String::new(), false);
        for key in keys.chars() {
            actual += &f.abc.convert(&key.to_string(), source).unwrap();
            if !converted {
                if let Some(r) = f.d.suggest_while_typing(&actual, source, &all, q().preferring(&f.ru.id), false) {
                    actual = r.replacement; source = r.target; converted = true;
                }
            }
        }
        if let Some(c) = f.d.suggest_completed(&actual, source, &all, q().preferring(&f.ru.id), false) { actual = c.replacement; }
        assert_eq!(actual, correct);
    }
}

#[test]
fn short_word_switches_once_typing_stops() {
    let f = fx();
    let all = [&f.abc, &f.ru, &f.uk];
    let req = |t: &str, s, paused| CorrectionRequest::new(t, s, &all, &none(), None, true, true, false, paused);
    for (input, output) in [("гыф", "usa"), ("ыуе", "set"), ("ыгт", "sun")] {
        assert!(f.d.correction(&req(input, &f.ru, false), "").is_none(), "{input}");
        assert!(f.d.may_correct(&req(input, &f.ru, true)), "{input}");
        assert_eq!(f.d.correction(&req(input, &f.ru, true), "").unwrap().replacement, output);
    }
    for (input, source) in [("рус", &f.ru), ("при", &f.ru), ("the", &f.abc), ("us", &f.abc), ("f", &f.abc), ("z", &f.abc),
                            ("гыфу", &f.ru), ("API", &f.abc), ("ру", &f.ru)] {
        assert!(!f.d.may_correct(&req(input, source, true)), "{input}");
        assert!(f.d.correction(&req(input, source, true), "").is_none(), "{input}");
    }
}

#[test]
fn keystroke_edit() {
    let e = |d, i: &str| Some(KeystrokeEdit { deletions: d, insertion: i.into() });
    assert_eq!(KeystrokeEdit::new("ghbdtn", "привет", " "), e(7, "привет "));
    assert_eq!(KeystrokeEdit::new("/вумудщзук", "/developer", " "), e(10, "developer "));
    assert_eq!(KeystrokeEdit::new("качгулся", "качнулся", ""), e(5, "нулся"));
    assert_eq!(KeystrokeEdit::new("ёж", "ёлка", "  "), e(3, "лка  "));
    assert_eq!(KeystrokeEdit::new("привет", "привет", " "), e(0, ""));
    assert_eq!(KeystrokeEdit::new("", "x", ""), None);
    assert_eq!(KeystrokeEdit::new("x", "", ""), None);
}
