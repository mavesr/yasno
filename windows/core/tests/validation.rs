//! The Mac validation corpus (Sources/SwitchValidation/Resources/corpus.json) run against
//! the Rust detector with the Windows layouts, as `scripts/validate.sh` runs it on the Mac.
//! Inputs typed on Apple layouts are re-typed on the Windows ones (Windows Ukrainian has і
//! on S and и on B): the expected words, not the key strings, are the reference.
//!
//! Categories the Mac marks required must pass completely; coverage categories are
//! reported with their rates and must not fall below the floors measured for this port.

use std::collections::{BTreeMap, HashSet};

use serde_json::Value;
use yasno_core::detector::Query;
use yasno_core::{layouts, Detector, KeyboardLayout};

const CORPUS: &str = include_str!("../../../Sources/SwitchValidation/Resources/corpus.json");

#[derive(Default, Debug)]
struct Stats { total: usize, passed: usize, failures: Vec<String> }

struct Suite { d: Detector, us: KeyboardLayout, ru: KeyboardLayout, uk: KeyboardLayout, stats: BTreeMap<&'static str, Stats> }

#[derive(Clone, Copy, PartialEq)]
enum Mode { Completed { spelling: bool }, Live, Manual }

impl Suite {
    fn layout(&self, apple: &str) -> &KeyboardLayout {
        match apple { "ABC" => &self.us, "Russian" => &self.ru, "Ukrainian" => &self.uk, other => panic!("{other}") }
    }
    fn all(&self) -> Vec<&KeyboardLayout> { vec![&self.us, &self.ru, &self.uk] }

    #[allow(clippy::too_many_arguments)]
    fn check(&mut self, category: &'static str, input: &str, expected: &str, source: &str, preferred: Option<&str>,
             mode: Mode, ignored: &HashSet<String>) {
        let all = self.all();
        let source = all.iter().find(|l| l.id == source).copied().unwrap();
        let q = Query::default().preferring_opt(preferred).ignoring(ignored);
        let result = match mode {
            Mode::Manual => self.d.convert_manually(input, source, &all, preferred, None),
            Mode::Live => self.d.suggest_while_typing(input, source, &all, q, true),
            Mode::Completed { spelling } => self.d.suggest_completed(input, source, &all, q, spelling),
        };
        let actual = result.as_ref().map_or(input.to_string(), |s| s.replacement.clone());
        let layout_ok = expected == input || preferred.is_none() || result.as_ref().is_none_or(|s| Some(s.target.id.as_str()) == preferred);
        let s = self.stats.entry(category).or_default();
        s.total += 1;
        if actual == expected && layout_ok { s.passed += 1; }
        else if s.failures.len() < 12 { s.failures.push(format!("{input:?} -> {actual:?} (expected {expected:?})")); }
    }
}

#[test]
fn mac_validation_corpus_on_windows_layouts() {
    let corpus: Value = serde_json::from_str(CORPUS).unwrap();
    let mut suite = Suite { d: Detector::default(), us: layouts::us(), ru: layouts::russian(), uk: layouts::ukrainian(), stats: BTreeMap::new() };
    let none = HashSet::new();
    let (us, ru, uk) = (suite.us.id.clone(), suite.ru.id.clone(), suite.uk.id.clone());

    for f in corpus["strict"].as_array().unwrap() {
        let f: Vec<&str> = f.as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
        let (source, target) = (suite.layout(f[0]).id.clone(), suite.layout(f[1]).id.clone());
        let expected = f[3];
        let input = suite.layout(f[1]).convert(expected, suite.layout(f[0])).unwrap();
        for suffix in ["", "!", ",", "…"] {
            for spelling in [false, true] {
                suite.check("golden-layout", &format!("{input}{suffix}"), &format!("{expected}{suffix}"), &source, Some(&target),
                            Mode::Completed { spelling }, &none);
            }
        }
        suite.check("golden-live", &input, expected, &source, Some(&target), Mode::Live, &none);
    }
    for f in corpus["typos"].as_array().unwrap() {
        let f: Vec<&str> = f.as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
        let source = suite.layout(f[0]).id.clone();
        suite.check("golden-spelling", f[1], f[2], &source, Some(&source), Mode::Completed { spelling: true }, &none);
        suite.check("spelling-disabled", f[1], f[1], &source, Some(&source), Mode::Completed { spelling: false }, &none);
        let ignored: HashSet<String> = [f[1].to_lowercase()].into();
        suite.check("spelling-excluded", f[1], f[1], &source, Some(&source), Mode::Completed { spelling: true }, &ignored);
    }
    let words = corpus["words"].as_object().unwrap();
    for (language, list) in words {
        let target = match language.as_str() { "ru" => ru.clone(), "uk" => uk.clone(), _ => us.clone() };
        for word in list.as_array().unwrap().iter().map(|w| w.as_str().unwrap()) {
            let capital: String = word.chars().take(1).flat_map(char::to_uppercase).chain(word.chars().skip(1)).collect();
            for form in [word.to_string(), capital] {
                for p in ["", ",", "!", "."] {
                    let text = format!("{form}{p}");
                    suite.check("native-preservation", &text, &text, &target, Some(&target), Mode::Completed { spelling: true }, &none);
                }
            }
            let chars: Vec<char> = word.chars().collect();
            for n in 1..=chars.len() {
                let prefix: String = chars[..n].iter().collect();
                suite.check("native-prefix", &prefix, &prefix, &target, Some(&target), Mode::Live, &none);
            }
            for source in [us.clone(), ru.clone(), uk.clone()] {
                if source == target { continue; }
                let all = suite.all();
                let (t, s) = (all.iter().find(|l| l.id == target).unwrap(), all.iter().find(|l| l.id == source).unwrap());
                let Some(wrong) = t.convert(word, s) else { continue };
                if wrong == word { continue; }
                suite.check("layout-only-coverage", &wrong, word, &source, Some(&target), Mode::Completed { spelling: false }, &none);
                suite.check("layout-coverage", &wrong, word, &source, Some(&target), Mode::Completed { spelling: true }, &none);
                suite.check("manual-coverage", &wrong, word, &source, Some(&target), Mode::Manual, &none);
                let ignored: HashSet<String> = [wrong.to_lowercase()].into();
                suite.check("exclusions", &wrong, &wrong, &source, Some(&target), Mode::Completed { spelling: true }, &ignored);
            }
        }
    }
    for input in corpus["protected"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()) {
        for source in [us.clone(), ru.clone(), uk.clone()] {
            suite.check("protected-patterns", input, input, &source, Some(&source), Mode::Completed { spelling: true }, &none);
        }
    }
    // Generated identifiers, numbers, addresses: never touched (the Mac quick profile).
    let mut state = 20261018u64;
    let mut next = || { state = state.wrapping_add(0x9e37_79b9_7f4a_7c15); let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9); z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb); z ^ (z >> 31) };
    let alphabet: Vec<char> = "abcdefghijklmnopqrstuvwxyz".chars().collect();
    for _ in 0..2000 {
        let len = 5 + (next() % 24) as usize;
        let raw: String = (0..len).map(|_| alphabet[(next() % 26) as usize]).collect();
        let n = next() % 1000;
        for text in [format!("{raw}_id"), format!("{raw}{n}"), format!("{raw}@example.com"), raw.to_uppercase(),
                     format!("a{}", raw.to_uppercase()), format!("{raw}/x")] {
            suite.check("protected-fuzz", &text, &text, &us, None, Mode::Completed { spelling: true }, &none);
        }
    }
    let domains = ["com", "org", "net", "dev", "de", "berlin", "museum", "co.uk"];
    for i in 0..100 {
        let base = format!("site-{i}.{}", domains[i % domains.len()]);
        for address in [base.clone(), format!("sub.{base}"), format!("https://{base}/path?q=3"), format!("{base}:8080/path")] {
            for source in [ru.clone(), uk.clone()] {
                let all = suite.all();
                let s = all.iter().find(|l| l.id == source).unwrap();
                if let Some(wrong) = suite.us.convert(&address, s) {
                    suite.check("domains", &wrong, &address, &source, Some(&us), Mode::Live, &none);
                }
            }
        }
    }

    let required = ["golden-layout", "golden-live", "golden-spelling", "spelling-disabled", "spelling-excluded",
                    "native-preservation", "native-prefix", "exclusions", "protected-patterns", "protected-fuzz", "domains"];
    let mut report = String::new();
    let mut failed = Vec::new();
    for (category, s) in &suite.stats {
        let rate = 100.0 * s.passed as f64 / s.total.max(1) as f64;
        report += &format!("{category:<22} {:>6}/{:<6} {rate:6.2}%\n", s.passed, s.total);
        if required.contains(category) && s.passed != s.total {
            failed.push(format!("{category}: {:?}", s.failures));
        }
    }
    println!("{report}");
    if let Ok(path) = std::env::var("YASNO_VALIDATION_REPORT") { let _ = std::fs::write(path, &report); }
    // Coverage floors: measured for this port with the frequency lists alone (no Windows spelling).
    let floor = |c: &str, min: f64| {
        let s = &suite.stats[c];
        let rate = 100.0 * s.passed as f64 / s.total.max(1) as f64;
        assert!(rate >= min, "{c} fell to {rate:.2}% (floor {min}%): {:?}", s.failures);
    };
    floor("layout-coverage", 99.0);
    floor("layout-only-coverage", 99.0);
    floor("manual-coverage", 99.0);
    assert!(failed.is_empty(), "required categories failed:\n{}", failed.join("\n"));
}
