//! The input engine against a simulated Windows: the raw input queue that feeds the
//! low-level hook in order, an application that types keys in its own layout and applies a
//! layout switch only when it gets to the posted request, a detector on another thread that
//! answers late, and a user who types faster than any of them.
//!
//! Every schedule is checked against the same keys typed slowly, one at a time: whatever
//! the timing, the field must end up with the same text. This is what failed in the first
//! Windows build: keys typed during a correction overtook it, and corrections were lost.

use std::collections::{HashSet, VecDeque};
use std::sync::Arc;

use yasno_core::engine::{vk, Answer, Context, Effect, Engine, Output, RawKey, Source, Timer};
use yasno_core::{layouts, CorrectionRequest, Detector, KeyboardLayout};

/// Stable pseudo-random numbers (no system randomness: failures must reproduce).
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 { self.next() % n.max(1) }
}

#[derive(Clone, Debug)]
enum Event { Key(RawKey, Source), Text(String), Back }

/// What the application does with input, like a Win32 edit control.
struct App {
    text: String,
    layout: String,
    requests: VecDeque<String>,
    /// Applies a requested layout only after this many inputs (a busy UI thread).
    lag: usize,
    waited: usize,
    /// Never applies a requested layout (some windows ignore the request).
    deaf: bool,
    shift: HashSet<u16>,
    ctrl: bool,
    caps: bool,
}

impl App {
    fn new(layout: &str) -> App {
        App { text: String::new(), layout: layout.into(), requests: VecDeque::new(), lag: 0, waited: 0, deaf: false,
              shift: HashSet::new(), ctrl: false, caps: false }
    }
    /// The application's message loop runs: posted messages before input.
    fn pump(&mut self) {
        if self.deaf { self.requests.clear(); return; }
        if self.requests.is_empty() { return; }
        if self.waited < self.lag { self.waited += 1; return; }
        while let Some(r) = self.requests.pop_front() { self.layout = r; }
        self.waited = 0;
    }
    fn input(&mut self, e: &Event, layouts: &[KeyboardLayout]) {
        self.pump();
        match e {
            Event::Text(s) => self.text.push_str(s),
            Event::Back => { self.text.pop(); }
            Event::Key(k, _) => {
                match k.vk {
                    vk::LSHIFT | vk::RSHIFT => { if k.down { self.shift.insert(k.vk); } else { self.shift.remove(&k.vk); } return; }
                    vk::LCONTROL | vk::RCONTROL => { self.ctrl = k.down; return; }
                    vk::CAPITAL => { if k.down { self.caps = !self.caps; } return; }
                    _ => {}
                }
                if !k.down || self.ctrl { return; }
                match k.vk {
                    vk::BACK => { self.text.pop(); }
                    vk::SPACE => self.text.push(' '),
                    vk::RETURN => self.text.push('\n'),
                    _ => {
                        let layout = layouts.iter().find(|l| l.id == self.layout).unwrap();
                        if let Some(c) = layout.character(k.scan, !self.shift.is_empty(), self.caps) { self.text.push_str(c); }
                    }
                }
            }
        }
    }
}

enum Posted { Effect(Effect), Answer(Answer) }

struct Sim {
    layouts: Arc<Vec<KeyboardLayout>>,
    engine: Engine,
    detector: Detector,
    app: App,
    rit: VecDeque<Event>,
    posted: VecDeque<Posted>,
    jobs: VecDeque<(yasno_core::typing::Check, bool)>,
    timers: Vec<(Timer, u64)>,
    now: u64,
    user: VecDeque<RawKey>,
}

const US: &str = "00000409";
const RU: &str = "00000419";
const UK: &str = "00000422";
const SPACE: u16 = 0x39;
const BACKSPACE: u16 = 0x0E;
const ENTER: u16 = 0x1C;
const LSHIFT_SCAN: u16 = 0x2A;

fn key(vk_code: u16, scan: u16, down: bool) -> RawKey { RawKey { vk: vk_code, scan, extended: false, down, time: 0 } }

/// Physical keys for text typed on the US layout. '⇧' is a short Shift tap, '⌫' Backspace.
fn keys(text: &str, us: &KeyboardLayout, overlap: bool) -> Vec<RawKey> {
    let mut presses: Vec<(Vec<RawKey>, RawKey)> = Vec::new();
    for c in text.chars() {
        let (downs, up) = match c {
            ' ' => (vec![key(vk::SPACE, SPACE, true)], key(vk::SPACE, SPACE, false)),
            '\n' => (vec![key(vk::RETURN, ENTER, true)], key(vk::RETURN, ENTER, false)),
            '⌫' => (vec![key(vk::BACK, BACKSPACE, true)], key(vk::BACK, BACKSPACE, false)),
            '⇧' => (vec![key(vk::LSHIFT, LSHIFT_SCAN, true)], key(vk::LSHIFT, LSHIFT_SCAN, false)),
            _ => {
                let s = us.stroke(c).unwrap_or_else(|| panic!("no key for {c:?}"));
                let k = (key(0x41, s.key, true), key(0x41, s.key, false));
                if s.shift {
                    presses.push((vec![key(vk::LSHIFT, LSHIFT_SCAN, true), k.0], k.1));
                    presses.push((vec![], key(vk::LSHIFT, LSHIFT_SCAN, false)));
                    continue;
                }
                (vec![k.0], k.1)
            }
        };
        presses.push((downs, up));
    }
    let mut out = Vec::new();
    let mut pending_up: Option<RawKey> = None;
    for (downs, up) in presses {
        let shift_release = downs.is_empty();
        if !overlap || shift_release || up.vk == vk::LSHIFT {
            if let Some(u) = pending_up.take() { out.push(u); }
            out.extend(downs);
            out.push(up);
        } else {
            // The next key goes down before the previous one is up, as fast typists do.
            out.extend(downs);
            if let Some(u) = pending_up.take() { out.push(u); }
            pending_up = Some(up);
        }
    }
    if let Some(u) = pending_up { out.push(u); }
    out
}

impl Sim {
    fn new(layouts: Vec<KeyboardLayout>, start: &str, typed: &str, overlap: bool) -> Sim {
        let layouts = Arc::new(layouts);
        let us = layouts::us();
        let mut engine = Engine::new(layouts.clone());
        engine.focus_changed(Context { now: 0, layout: Some(start) });
        // The user chose Russian before (RU and UK type тест with the same keys).
        engine.typing.preferred = Some(RU.to_string());
        Sim { engine, detector: Detector::default(), app: App::new(start), rit: VecDeque::new(), posted: VecDeque::new(),
              jobs: VecDeque::new(), timers: Vec::new(), now: 0, user: keys(typed, &us, overlap).into(), layouts }
    }

    fn post_effects(&mut self) {
        for e in self.engine.take_effects() { self.posted.push_back(Posted::Effect(e)); }
    }

    /// The raw input thread hands the next event to the hook, then to the application.
    fn deliver_one(&mut self) {
        let Some(e) = self.rit.pop_front() else { return };
        let layout = self.app.layout.clone();
        let ctx = Context { now: self.now, layout: Some(&layout) };
        let swallowed = match &e {
            Event::Key(k, s) => self.engine.key(*k, *s, ctx),
            _ => false,
        };
        self.post_effects();
        if !swallowed { self.app.input(&e, &self.layouts); }
    }

    /// The UI thread handles one posted message.
    fn ui_one(&mut self) {
        let Some(p) = self.posted.pop_front() else { return };
        let layout = self.app.layout.clone();
        let ctx = Context { now: self.now, layout: Some(&layout) };
        match p {
            Posted::Effect(Effect::Send(batch)) => {
                for o in batch {
                    match o {
                        Output::Key(k) => self.rit.push_back(Event::Key(k, Source::Own)),
                        Output::Text(s) => self.rit.push_back(Event::Text(s)),
                        Output::Erase(n) => for _ in 0..n { self.rit.push_back(Event::Back) },
                        Output::End(id) => self.rit.push_back(Event::Key(key(0xE8, 0, false), Source::End(id))),
                    }
                }
            }
            Posted::Effect(Effect::Detect { check, gated }) => self.jobs.push_back((check, gated)),
            Posted::Effect(Effect::Switch(id)) => self.app.requests.push_back(id),
            Posted::Effect(Effect::Start(t, ms)) => {
                self.timers.retain(|(k, _)| *k != t);
                self.timers.push((t, self.now + ms));
            }
            Posted::Effect(Effect::Preferred(_)) => {}
            Posted::Answer(a) => { self.engine.answer(a, ctx); self.post_effects(); }
        }
    }

    fn worker_one(&mut self) {
        let Some((check, gated)) = self.jobs.pop_front() else { return };
        let all: Vec<&KeyboardLayout> = self.layouts.iter().collect();
        let preferred = self.engine.typing.preferred.clone();
        let correction = check.request(&all, &HashSet::new(), preferred.as_deref(), true)
            .filter(|r: &CorrectionRequest| self.detector.may_correct(r))
            .and_then(|r| self.detector.correction(&r, &check.context))
            .map(|s| (s.replacement, s.target.id.clone()));
        let reason = correction.is_none().then_some("no correction");
        self.posted.push_back(Posted::Answer(Answer { version: check.version, gated, correction, reason }));
    }

    fn fire_timers(&mut self) {
        let due: Vec<Timer> = self.timers.iter().filter(|(_, at)| *at <= self.now).map(|(t, _)| *t).collect();
        self.timers.retain(|(_, at)| *at > self.now);
        for t in due {
            let layout = self.app.layout.clone();
            self.engine.timer(t, Context { now: self.now, layout: Some(&layout) });
            self.post_effects();
        }
    }

    fn press(&mut self) {
        if let Some(mut k) = self.user.pop_front() {
            k.time = self.now;
            self.rit.push_back(Event::Key(k, Source::User));
        }
    }

    fn quiet(&self) -> bool { self.rit.is_empty() && self.posted.is_empty() && self.jobs.is_empty() }

    fn settle(&mut self) {
        let mut guard = 0;
        while !self.quiet() || !self.app.requests.is_empty() || self.engine.holding() {
            self.now += 1;
            self.deliver_one();
            self.ui_one();
            self.worker_one();
            self.app.pump();
            self.fire_timers();
            guard += 1;
            assert!(guard < 100_000, "never settles");
        }
    }

    /// Each key handled completely before the next: the behaviour to match.
    fn run_slowly(mut self) -> (String, Sim) {
        while !self.user.is_empty() {
            self.now += 5;
            self.press();
            self.settle();
        }
        self.finish()
    }

    fn finish(mut self) -> (String, Sim) {
        self.settle();
        // Typing stopped: the pause timer may still check a short word.
        self.now += 1000;
        self.fire_timers();
        self.settle();
        (self.app.text.clone(), self)
    }

    /// Every party moves at random: keys arrive while others are being handled.
    fn run_randomly(mut self, rng: &mut Rng, worker_speed: u64) -> (String, Sim) {
        let mut guard = 0;
        while !self.user.is_empty() || !self.quiet() {
            self.now += 1;
            match rng.below(10) {
                0..=2 => self.press(),
                3..=5 => self.deliver_one(),
                6..=7 => self.ui_one(),
                8 => if rng.below(worker_speed) == 0 { self.worker_one() },
                _ => self.app.pump(),
            }
            self.fire_timers();
            guard += 1;
            assert!(guard < 1_000_000);
        }
        self.finish()
    }
}

fn standard() -> Vec<KeyboardLayout> { vec![layouts::us(), layouts::russian(), layouts::ukrainian()] }

fn slow(typed: &str, start: &str) -> String { Sim::new(standard(), start, typed, false).run_slowly().0 }


#[test]
fn slow_typing_corrects_words_typed_in_the_wrong_layout() {
    assert_eq!(slow("ghbdtn rfr ltkf ", US), "привет как дела ");
    assert_eq!(slow("hello world ", RU), "hello world ");
    // Valid words stay.
    assert_eq!(slow("hello world ", US), "hello world ");
    // Russian punctuation is on the Russian keys: ? is the key of «,».
    assert_eq!(slow("ghbdtn? rfr ltkf& ", US), "привет, как дела? ");
}

#[test]
fn the_layout_follows_the_correction() {
    let (text, sim) = Sim::new(standard(), US, "ghbdtn vbh ", false).run_slowly();
    assert_eq!(text, "привет мир ");
    assert_eq!(sim.app.layout, RU);
}

/// The sentences used for timing tests: what the user means, in which language, and the
/// layout the field starts in. The keys are those of the meant text on its own layout.
const MEANT: &[(&str, &str, &str)] = &[
    ("привет как дела ", RU, US),
    // Typed fast, «Ghbdtn?» is checked whole at Space: ? is the comma key of the Windows
    // Russian layout. Typed slowly, the word switches first and the key types a comma.
    ("Привет, мир! Как твои дела? Всё хорошо. ", RU, US),
    ("hello world and some more ", US, RU),
    ("сегодня хорошая погода ", RU, US),
    ("тест на скорость печати, ", RU, US),
    ("Doch, das ist gut ", US, RU),
    ("дякую, це дуже гарно ", UK, US),
];

fn sentences() -> Vec<(String, &'static str, String)> {
    let all = standard();
    let us = layouts::us();
    MEANT.iter().map(|(meant, language, start)| {
        let own = all.iter().find(|l| l.id == *language).unwrap();
        (own.convert(meant, &us).unwrap(), *start, meant.to_string())
    }).collect()
}

#[test]
fn any_timing_gives_the_same_text_as_slow_typing() {
    for (typed, start, expected) in sentences() {
        let reference = slow(&typed, start);
        assert_eq!(reference, expected, "slow: {typed}");
        for seed in 0..40u64 {
            for overlap in [false, true] {
                let mut rng = Rng(seed * 7919 + 13);
                let speed = 1 + seed % 4;
                let (text, _) = Sim::new(standard(), start, &typed, overlap).run_randomly(&mut rng, speed);
                assert_eq!(text, reference, "seed {seed} overlap {overlap}: {typed}");
            }
        }
    }
}

#[test]
fn a_window_that_applies_the_layout_late_still_gets_the_right_letters() {
    for (typed, start, expected) in sentences() {
        for lag in [1, 3, 10, 40] {
            for seed in 0..10u64 {
                let mut rng = Rng(seed + 1000 * lag as u64);
                let mut sim = Sim::new(standard(), start, &typed, seed % 2 == 0);
                sim.app.lag = lag;
                let (text, _) = sim.run_randomly(&mut rng, 2);
                assert_eq!(text, expected, "lag {lag} seed {seed}: {typed}");
            }
        }
    }
}

#[test]
fn a_window_that_ignores_the_layout_switch_keeps_the_field_and_the_model_in_step() {
    // The request is lost: the next word is typed in the old layout and corrected too.
    let mut sim = Sim::new(standard(), US, "ghbdtn rfr ltkf ", false);
    sim.app.deaf = true;
    let (text, sim) = sim.run_slowly();
    assert_eq!(text, "привет как дела ");
    assert_eq!(sim.app.layout, US);
    assert!(sim.engine.switch_failed);
}

#[test]
fn shift_tap_converts_the_word_and_a_second_tap_undoes() {
    assert_eq!(slow("ytn⇧", US), "нет");
    // After an automatic change, Shift brings the typed text back.
    assert_eq!(slow("ghbdtn ⇧", US), "ghbdtn ");
    // In an empty field Shift only switches the layout: the next word is Russian.
    let (text, sim) = Sim::new(standard(), US, "⇧", false).run_slowly();
    assert_eq!(text, "");
    assert_eq!(sim.app.layout, RU);
}

#[test]
fn shift_tap_under_random_timing() {
    for seed in 0..30u64 {
        let mut rng = Rng(seed + 77);
        let (text, _) = Sim::new(standard(), US, "ytn⇧ ghbdtn ⇧", seed % 2 == 1).run_randomly(&mut rng, 2);
        assert_eq!(text, slow("ytn⇧ ghbdtn ⇧", US), "seed {seed}");
    }
}

#[test]
fn backspace_and_enter_keep_the_model_in_step() {
    assert_eq!(slow("ghbdtt⌫n ", US), "привет ");
    assert_eq!(slow("ghbdtn\nrfr ", US), "привет\nкак ");
    for seed in 0..30u64 {
        let mut rng = Rng(seed + 5);
        let typed = "ghbdtt⌫n rfr\nltkf ";
        let (text, _) = Sim::new(standard(), US, typed, seed % 2 == 0).run_randomly(&mut rng, 3);
        assert_eq!(text, slow(typed, US), "seed {seed}");
    }
}

#[test]
fn nothing_is_lost_when_the_detector_never_answers() {
    // A stalled detector: the watchdog releases held keys as typed.
    let mut sim = Sim::new(standard(), US, "ghbdtn rfr ", false);
    let mut guard = 0;
    while !sim.user.is_empty() || !sim.rit.is_empty() || !sim.posted.is_empty() || sim.engine.holding() {
        sim.now += 3;
        sim.press();
        sim.deliver_one();
        sim.ui_one();
        sim.jobs.clear();
        sim.fire_timers();
        guard += 1;
        assert!(guard < 100_000);
    }
    assert_eq!(sim.app.text, "ghbdtn rfr ");
}

#[test]
fn password_fields_and_pause_pass_everything_untouched() {
    let mut sim = Sim::new(standard(), US, "ghbdtn rfr ", true);
    sim.engine.set_editable(false);
    assert_eq!(sim.run_slowly().0, "ghbdtn rfr ");
    let mut sim = Sim::new(standard(), US, "ghbdtn rfr ", true);
    sim.engine.set_enabled(false, Context { now: 0, layout: Some(US) });
    let mut rng = Rng(3);
    assert_eq!(sim.run_randomly(&mut rng, 1).0, "ghbdtn rfr ");
}

#[test]
fn diagnostics_note_each_finished_word_and_what_was_done() {
    use yasno_core::diagnostics::SECRET;
    let mut sim = Sim::new(standard(), US, "ghbdtn hello ", false);
    sim.engine.set_diagnostics(true);
    let (text, mut sim) = sim.run_slowly();
    assert_eq!(text, "привет hello ");
    let notes = sim.engine.take_notes();
    let events: Vec<&str> = notes.iter().map(|n| n["event"].as_str().unwrap()).collect();
    // Both words are converted while typed (live), then checked again after Space.
    assert_eq!(events, vec!["edit", "word", "no_suggestion", "edit", "word", "no_suggestion"], "{notes:?}");
    assert_eq!(notes[0]["text"], "ghbd");
    assert_eq!(notes[0]["layout"], US);
    assert_eq!(notes[0]["replacement"], "прив");
    assert_eq!(notes[0]["target"], RU);
    assert_eq!(notes[0]["live"], true);
    assert_eq!(notes[0]["result"], "sent");
    assert_eq!(notes[1]["text"], "привет");
    assert_eq!(notes[1]["held"], true);
    assert_eq!(notes[1]["live_converted"], true);
    assert_eq!(notes[2]["live"], false);
    assert_eq!(notes[5]["text"], "hello");

    // A click in the middle of a word, and a field that may hold a secret.
    let mut sim = Sim::new(standard(), US, "ghb", false);
    sim.engine.set_diagnostics(true);
    sim.engine.set_redact(Some(SECRET));
    let (_, mut sim) = sim.run_slowly();
    sim.engine.caret_moved();
    let notes = sim.engine.take_notes();
    assert_eq!(notes.len(), 1);
    assert_eq!(notes[0]["event"], "word_dropped");
    assert_eq!(notes[0]["reason"], "mouse click");
    assert_eq!(notes[0]["text"], SECRET);

    // Off, nothing is noted.
    let (_, mut sim) = Sim::new(standard(), US, "ghbdtn ", false).run_slowly();
    assert!(sim.engine.take_notes().is_empty());
}

fn manual(typed: &str, start: &str, overlap: bool, seed: Option<u64>) -> (String, Sim) {
    let mut sim = Sim::new(standard(), start, typed, overlap);
    sim.engine.set_automatic(false);
    match seed {
        None => sim.run_slowly(),
        Some(seed) => { let mut rng = Rng(seed + 401); sim.run_randomly(&mut rng, 1 + seed % 3) }
    }
}

#[test]
fn automatic_switching_off_leaves_words_as_typed() {
    // Nothing is converted while typing, at Space, or after a pause.
    let (text, sim) = manual("ghbdtn rfr ltkf ", US, false, None);
    assert_eq!(text, "ghbdtn rfr ltkf ");
    assert_eq!(sim.app.layout, US);
    assert_eq!(sim.engine.corrections, 0);
    assert_eq!(manual("ytn", US, false, None).0, "ytn");
    assert_eq!(manual("ghbdtn? ", US, false, None).0, "ghbdtn? ");
    // Typos are not corrected either.
    assert_eq!(manual("helo wrold ", US, false, None).0, "helo wrold ");
}

#[test]
fn automatic_switching_off_still_switches_a_word_on_a_short_shift_tap() {
    let (text, sim) = manual("ytn⇧", US, false, None);
    assert_eq!(text, "нет");
    assert_eq!(sim.app.layout, RU);
    // A second tap brings the typed text back.
    assert_eq!(manual("ytn⇧⇧", US, false, None).0, slow("ytn⇧⇧", US));
    // After the switch the next word is typed in the new layout and stays as typed.
    assert_eq!(manual("ghbdtn⇧ vbh ", US, false, None).0, "привет мир ");
    // Shift in an empty field still selects the next language.
    let (text, sim) = manual("⇧", US, false, None);
    assert_eq!(text, "");
    assert_eq!(sim.app.layout, RU);
}

#[test]
fn automatic_switching_off_under_random_timing() {
    for seed in 0..30u64 {
        for typed in ["ghbdtn rfr ltkf ", "ytn⇧ ghbdtn ", "ghbdtn⇧ rfr "] {
            let reference = manual(typed, US, false, None).0;
            let (text, _) = manual(typed, US, seed % 2 == 0, Some(seed));
            assert_eq!(text, reference, "seed {seed}: {typed}");
        }
    }
}

#[test]
fn automatic_switching_turned_off_during_a_check_drops_its_answer() {
    // «ytn» is short: it is checked only when finished, at Space. Switching is turned off
    // while the detector is still working on it.
    assert_eq!(slow("ytn ", US), "нет ");
    let mut sim = Sim::new(standard(), US, "ytn ", false);
    while !sim.user.is_empty() || !sim.rit.is_empty() || !sim.posted.is_empty() {
        sim.now += 5; sim.press(); sim.deliver_one(); sim.ui_one();
    }
    assert!(!sim.jobs.is_empty(), "the check at Space was asked for");
    sim.engine.set_automatic(false);
    let (text, sim) = sim.finish();
    assert_eq!(text, "ytn ");
    assert!(!sim.engine.holding());

    // Turned on again, words are switched as before.
    let mut sim = Sim::new(standard(), US, "ghbdtn ", false);
    sim.engine.set_automatic(false);
    sim.engine.set_automatic(true);
    assert_eq!(sim.run_slowly().0, "привет ");
}

#[test]
fn diagnostics_say_why_a_word_was_left_with_automatic_switching_off() {
    let mut sim = Sim::new(standard(), US, "ghbdtn ", false);
    sim.engine.set_automatic(false);
    sim.engine.set_diagnostics(true);
    let (_, mut sim) = sim.run_slowly();
    let notes = sim.engine.take_notes();
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert_eq!(notes[0]["event"], "skipped");
    assert_eq!(notes[0]["reason"], "automatic switching off");
    assert_eq!(notes[0]["text"], "ghbdtn");
}
