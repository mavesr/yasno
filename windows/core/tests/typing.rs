//! The typing session as the Windows app drives it: keys in, edits out.

use std::collections::HashSet;
use yasno_core::typing::{Decision, Edit, Key, Typing};
use yasno_core::{layouts, Detector, KeyStroke, KeyboardLayout};

struct Field<'a> {
    t: Typing, text: String, layout: &'a KeyboardLayout, layouts: Vec<&'a KeyboardLayout>, d: &'a Detector,
}

impl<'a> Field<'a> {
    fn new(d: &'a Detector, layouts: Vec<&'a KeyboardLayout>) -> Self {
        Field { t: Typing::new(), text: String::new(), layout: layouts[0], layouts, d }
    }
    fn perform(&mut self, e: Edit) {
        for _ in 0..e.deletions { self.text.pop(); }
        self.text.push_str(&e.insertion);
        if let Some(id) = e.switch_to { self.layout = self.layouts.iter().find(|l| l.id == id).unwrap(); }
    }
    fn decide(&mut self, check: yasno_core::typing::Check) {
        let req = check.request(&self.layouts, &HashSet::new(), self.t.preferred.as_deref(), true).unwrap();
        if !self.d.may_correct(&req) { return; }
        if let Some(s) = self.d.correction(&req, &check.context) {
            let decision = Decision { version: check.version, replacement: s.replacement, target_id: s.target.id.clone() };
            if let Some(e) = self.t.apply(&decision, &self.layouts) { self.perform(e); }
        }
    }
    /// Type physical keys given as text on the US layout.
    fn keys(&mut self, us: &KeyboardLayout, physical: &str) {
        for c in physical.chars() {
            let key = match c {
                ' ' => Key::Space,
                '\n' => Key::Enter,
                '\u{8}' => Key::Backspace,
                _ => Key::Char(us.stroke(c).unwrap()),
            };
            match key {
                Key::Char(s) => self.text.push_str(self.layout.character(s.key, s.shift, false).unwrap()),
                Key::Space => self.text.push(' '),
                Key::Enter => self.text.push('\n'),
                Key::Backspace => { self.text.pop(); }
                _ => {}
            }
            if let Some(check) = self.t.key(key, self.layout) { self.decide(check); }
        }
    }
    fn tap(&mut self) {
        let current = self.layout;
        if let Some(e) = self.t.shift_tap(self.d, &self.layouts, current) { self.perform(e); }
    }
}

#[test]
fn phrase_typed_in_wrong_layouts_comes_out_right() {
    let d = Detector::default();
    let (us, ru, uk) = (layouts::us(), layouts::russian(), layouts::ukrainian());
    let mut f = Field::new(&d, vec![&us, &ru, &uk]);
    f.keys(&us, "ghbdtn rfr ltkf ");
    assert_eq!(f.text, "привет как дела ");
    assert_eq!(f.layout.id, ru.id);
    // The same physical keys for "hello" are typed on the Russian layout now.
    f.keys(&us, "hello ");
    assert_eq!(f.text, "привет как дела hello ");
    assert_eq!(f.layout.id, us.id);
}

#[test]
fn live_conversion_keeps_the_rest_of_the_word() {
    let d = Detector::default();
    let (us, ru, uk) = (layouts::us(), layouts::russian(), layouts::ukrainian());
    let mut f = Field::new(&d, vec![&us, &ru, &uk]);
    f.keys(&us, "gthtrk.xfkbcm");
    assert_eq!(f.text, "переключались");
    assert_eq!(f.layout.id, ru.id);
}

#[test]
fn shift_tap_undoes_then_cycles() {
    let d = Detector::default();
    let (us, ru, uk) = (layouts::us(), layouts::russian(), layouts::ukrainian());
    let mut f = Field::new(&d, vec![&us, &ru, &uk]);
    f.keys(&us, "ghbdtn ");
    assert_eq!(f.text, "привет ");
    f.tap();
    assert_eq!(f.text, "ghbdtn ");
    assert_eq!(f.layout.id, us.id);
    f.tap();
    assert_eq!(f.text, "привет ");
    assert_eq!(f.layout.id, ru.id);
    f.tap();
    assert_eq!(f.layout.id, uk.id);
    assert_eq!(f.text, "привет "); // the same keys spell the same on Windows Ukrainian
}

#[test]
fn shift_tap_converts_a_valid_word_and_switches_an_empty_field() {
    let d = Detector::default();
    let (us, ru, uk) = (layouts::us(), layouts::russian(), layouts::ukrainian());
    let mut f = Field::new(&d, vec![&us, &ru, &uk]);
    f.keys(&us, "test");
    f.tap();
    assert_eq!(f.text, "еуые");
    assert_eq!(f.layout.id, ru.id);
    let mut empty = Field::new(&d, vec![&us, &ru, &uk]);
    empty.tap();
    assert_eq!(empty.layout.id, ru.id);
    empty.tap();
    assert_eq!(empty.layout.id, uk.id);
    empty.tap();
    assert_eq!(empty.layout.id, us.id);
}

#[test]
fn late_answer_is_dropped_and_navigation_forgets_the_word() {
    let d = Detector::default();
    let us = layouts::us();
    let mut t = Typing::new();
    for c in "ghbdtn".chars() { t.key(Key::Char(us.stroke(c).unwrap()), &us); }
    let check = t.key(Key::Space, &us).unwrap();
    t.key(Key::Char(KeyStroke::new(0x22, false)), &us); // typed on before the answer came
    let stale = Decision { version: check.version, replacement: "привет".into(), target_id: "00000419".into() };
    assert!(t.apply(&stale, &[&us]).is_none());
    t.key(Key::Navigation, &us);
    assert_eq!(t.word(), "");
    let _ = d;
}

#[test]
fn backspace_edits_the_word() {
    let d = Detector::default();
    let (us, ru) = (layouts::us(), layouts::russian());
    let mut f = Field::new(&d, vec![&us, &ru]);
    f.keys(&us, "ghbx\u{8}dtn ");
    assert_eq!(f.text, "привет ");
}

#[test]
fn short_word_converts_after_a_pause() {
    let d = Detector::default();
    let (us, ru, uk) = (layouts::us(), layouts::russian(), layouts::ukrainian());
    let mut f = Field::new(&d, vec![&us, &ru, &uk]);
    f.layout = &ru;
    f.keys(&us, "usa");
    assert_eq!(f.text, "гыф");
    let check = f.t.pause_check().unwrap();
    f.decide(check);
    assert_eq!(f.text, "usa");
    assert_eq!(f.layout.id, us.id);
}
