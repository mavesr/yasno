//! The input engine: what the keyboard hook does with every key, as the Mac
//! `KeyboardMonitor` does in its event tap. Platform-free, so every rule is tested with a
//! simulated Windows input queue (tests/engine.rs) before it meets a real one.
//!
//! The rules, in the order they matter:
//!
//! * A key reaches the typing model only when it reaches the application. So the word
//!   Yasno knows is always the word in the field, key for key.
//! * When a finished word may be corrected (Space after a word), the keys typed next are
//!   held until the detector has answered and the edit is made, then replayed in order.
//!   A fast typist's next word can no longer overtake the correction or cancel it.
//! * After anything Yasno sends (an edit, replayed keys), every key is held until the last
//!   event sent comes back through the hook: a key pressed before the edit but not yet seen
//!   by the hook would otherwise reach the application ahead of it.
//! * Held letters are replayed as text in the layout Yasno uses for them, not as keys: the
//!   application may not have applied a layout switch yet, and would type them in the old
//!   layout. Until the application reports the new layout, letters go out the same way.
//! * A watchdog never lets input stay held: a check that takes too long, or an edit that
//!   does not come back, releases everything as typed.

use std::collections::{HashSet, VecDeque};
use std::sync::Arc;

use serde_json::{json, Map, Value};

use crate::detector::Detector;
use crate::layout::{KeyStroke, KeyboardLayout};
use crate::shift_tap::ShiftTapGesture;
use crate::typing::{Check, Decision, Edit, Key, Typing};

pub mod vk {
    pub const BACK: u16 = 0x08;
    pub const TAB: u16 = 0x09;
    pub const RETURN: u16 = 0x0D;
    pub const SHIFT: u16 = 0x10;
    pub const CONTROL: u16 = 0x11;
    pub const MENU: u16 = 0x12;
    pub const PAUSE: u16 = 0x13;
    pub const CAPITAL: u16 = 0x14;
    pub const ESCAPE: u16 = 0x1B;
    pub const SPACE: u16 = 0x20;
    pub const SNAPSHOT: u16 = 0x2C;
    pub const INSERT: u16 = 0x2D;
    pub const DELETE: u16 = 0x2E;
    pub const LWIN: u16 = 0x5B;
    pub const RWIN: u16 = 0x5C;
    pub const APPS: u16 = 0x5D;
    pub const F1: u16 = 0x70;
    pub const F24: u16 = 0x87;
    pub const NUMLOCK: u16 = 0x90;
    pub const SCROLL: u16 = 0x91;
    pub const LSHIFT: u16 = 0xA0;
    pub const RSHIFT: u16 = 0xA1;
    pub const LCONTROL: u16 = 0xA2;
    pub const RCONTROL: u16 = 0xA3;
    pub const LMENU: u16 = 0xA4;
    pub const RMENU: u16 = 0xA5;
    pub const PACKET: u16 = 0xE7;
}

/// One keyboard event as the low-level hook reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RawKey {
    pub vk: u16,
    pub scan: u16,
    pub extended: bool,
    pub down: bool,
    /// Milliseconds, the event's own timestamp.
    pub time: u64,
}

/// Who sent an event the hook sees.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// The keyboard, or another program typing for the user.
    User,
    /// Something Yasno sent: an edit or a replayed key.
    Own,
    /// The last event of a batch Yasno sent.
    End(u64),
}

/// What Yasno sends to the application, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Output {
    /// A key as pressed: modifiers, navigation, shortcuts, Space, Enter.
    Key(RawKey),
    /// Characters, typed as text whatever the application's layout.
    Text(String),
    /// Backspaces.
    Erase(usize),
    /// Comes back through the hook once everything before it was delivered.
    End(u64),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Timer {
    /// Typing stopped on a short word (search fields get no Space).
    Pause,
    /// Held input is released if nothing moves it on.
    Watchdog,
}

/// Work for the shell to do, in order.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    Send(Vec<Output>),
    /// Ask the detector. `gated`: input is held until the answer comes.
    Detect { check: Check, gated: bool },
    /// Select this layout in the focused window.
    Switch(String),
    Start(Timer, u64),
    /// The user selected this Cyrillic layout themselves: remember the choice.
    Preferred(String),
}

/// The detector's answer to a Detect.
#[derive(Clone, Debug, PartialEq)]
pub struct Answer {
    pub version: u64,
    pub gated: bool,
    /// The replacement and the layout it is in.
    pub correction: Option<(String, String)>,
    /// Why there is none, for the diagnostic journal.
    pub reason: Option<&'static str>,
}

/// What the shell knows at the moment of a call.
#[derive(Clone, Copy, Debug)]
pub struct Context<'a> {
    pub now: u64,
    /// The layout the focused window uses now, if it is one of ours.
    pub layout: Option<&'a str>,
}

/// A check longer than this releases held keys as typed (the Mac waits up to 1 s).
pub const GATE_LIMIT: u64 = 500;
/// Sent events that have not come back after this are given up.
pub const FLIGHT_LIMIT: u64 = 1000;
/// The application gets this long to apply a layout Yasno selected.
pub const SWITCH_LIMIT: u64 = 1000;
pub const PAUSE: u64 = 600;
const WATCHDOG_TICK: u64 = 100;

#[derive(Clone, Debug)]
struct Gate { version: u64, since: u64, cancelled: bool, word: String }

#[derive(Clone, Debug)]
struct Switch { target: String, since: u64 }

pub struct Engine {
    layouts: Arc<Vec<KeyboardLayout>>,
    detector: Detector,
    pub typing: Typing,
    gesture: ShiftTapGesture,
    shifts: HashSet<u16>,
    ctrl: HashSet<u16>,
    alt: HashSet<u16>,
    win: HashSet<u16>,
    caps: bool,
    caps_down: bool,
    gate: Option<Gate>,
    flight: Option<(u64, u64)>,
    queue: VecDeque<RawKey>,
    /// Keys whose press went out as text: their release must not reach the application.
    as_text: HashSet<u16>,
    switch: Option<Switch>,
    last_layout: Option<String>,
    next_batch: u64,
    effects: Vec<Effect>,
    enabled: bool,
    /// The focused field may be edited: known and not a password field.
    editable: bool,
    /// The detector has loaded its dictionaries: a gate would otherwise wait for the load.
    ready: bool,
    pub corrections: u64,
    /// Why the last edit could not switch the layout, for the settings window.
    pub switch_failed: bool,
    /// Input diagnostics are on: what is decided for each word is noted for the journal.
    diagnostics: bool,
    /// Typed text in notes is replaced by this (a password field, a field not checked yet).
    redact: Option<&'static str>,
    notes: Vec<Map<String, Value>>,
    unknown_layout_noted: bool,
}

impl Engine {
    pub fn new(layouts: Arc<Vec<KeyboardLayout>>) -> Engine {
        Engine {
            layouts, detector: Detector::default(), typing: Typing::new(), gesture: ShiftTapGesture::new(),
            shifts: HashSet::new(), ctrl: HashSet::new(), alt: HashSet::new(), win: HashSet::new(),
            caps: false, caps_down: false, gate: None, flight: None, queue: VecDeque::new(), as_text: HashSet::new(),
            switch: None, last_layout: None, next_batch: 1, effects: Vec::new(), enabled: true, editable: true, ready: true,
            corrections: 0, switch_failed: false, diagnostics: false, redact: None, notes: Vec::new(),
            unknown_layout_noted: false,
        }
    }

    pub fn layouts(&self) -> &Arc<Vec<KeyboardLayout>> { &self.layouts }

    pub fn set_layouts(&mut self, layouts: Arc<Vec<KeyboardLayout>>) {
        self.drop_word("layout list changed");
        self.layouts = layouts;
        self.typing.reset();
    }

    /// Diagnostics on or off (docs/diagnostics.md). Off, nothing is noted.
    pub fn set_diagnostics(&mut self, on: bool) {
        self.diagnostics = on;
        if !on { self.notes.clear(); }
    }

    /// What replaces typed text in notes about the focused field; None records it.
    pub fn set_redact(&mut self, why: Option<&'static str>) { self.redact = why; }

    /// The notes made so far, for the journal, in order.
    pub fn take_notes(&mut self) -> Vec<Map<String, Value>> { std::mem::take(&mut self.notes) }

    /// Notes an event; the fields are built only while diagnostics are on.
    fn note(&mut self, event: &str, fields: impl FnOnce(&Engine) -> Value) {
        if !self.diagnostics { return; }
        let Value::Object(mut row) = fields(self) else { return };
        if let Some(why) = self.redact { crate::diagnostics::redact(&mut row, why); }
        row.insert("event".into(), event.into());
        self.notes.push(row);
    }

    /// The word being typed is given up: the journal says why.
    fn drop_word(&mut self, reason: &str) {
        if !self.typing.in_word() { return; }
        self.note("word_dropped", |e| json!({"reason": reason, "text": e.typing.word(), "layout": e.typing.layout_id()}));
    }

    /// A word checked when it was finished, as every note about it shows it.
    fn word_fields(&self, text: &str, live: bool, extra: Value) -> Value {
        let mut row = json!({"text": text, "layout": self.typing.layout_id(), "live": live});
        if let (Value::Object(row), Value::Object(extra)) = (&mut row, extra) { row.extend(extra); }
        row
    }

    /// The effects produced so far, to perform in order.
    pub fn take_effects(&mut self) -> Vec<Effect> { std::mem::take(&mut self.effects) }

    pub fn set_caps_lock(&mut self, on: bool) { self.caps = on; }
    pub fn set_ready(&mut self, ready: bool) { self.ready = ready; }
    pub fn set_editable(&mut self, editable: bool) {
        self.editable = editable;
        if !editable { self.drop_word("field cannot be edited"); self.typing.reset(); }
    }

    /// Paused, an excluded or elevated application: keys pass untouched and nothing is kept.
    pub fn set_enabled(&mut self, enabled: bool, ctx: Context) {
        if self.enabled == enabled { return; }
        self.enabled = enabled;
        if !enabled {
            self.drop_word("monitoring off");
            self.typing.reset();
            self.gesture.reset();
            self.cancel_gate();
            self.switch = None;
            self.release(ctx);
        }
    }

    pub fn enabled(&self) -> bool { self.enabled }

    /// Input is held or on its way back.
    pub fn busy(&self) -> bool { self.holding() || self.switch.is_some() }

    /// Keys are held, or sent and not back yet.
    pub fn holding(&self) -> bool { self.gate.is_some() || self.flight.is_some() || !self.queue.is_empty() }

    /// Waiting for the window to apply a layout Yasno selected.
    fn switching(&self) -> bool { self.switch.is_some() && !self.switch_failed }

    /// A click: the caret may be anywhere now.
    pub fn caret_moved(&mut self) { self.lose_caret("mouse click"); }

    fn lose_caret(&mut self, reason: &str) {
        self.drop_word(reason);
        self.typing.reset();
        self.gesture.cancel();
        if let Some(g) = self.gate.as_mut() { g.cancelled = true; }
    }

    /// Another field or window has the focus.
    pub fn focus_changed(&mut self, ctx: Context) {
        self.lose_caret("focus changed");
        self.gesture.reset();
        self.switch = None;
        self.last_layout = ctx.layout.map(str::to_string);
    }

    fn layout(&self, id: &str) -> Option<&KeyboardLayout> { self.layouts.iter().find(|l| l.id == id) }

    /// The layout keys are typed in: the one Yasno selected until the window confirms it.
    fn model_layout<'a>(&'a self, ctx: &Context<'a>) -> Option<&'a str> {
        self.switch.as_ref().map(|s| s.target.as_str()).or(ctx.layout)
    }

    fn watch_layout(&mut self, ctx: &Context) {
        if let Some(s) = &self.switch {
            if ctx.layout == Some(s.target.as_str()) {
                self.switch = None;
                self.switch_failed = false;
            } else if ctx.now.saturating_sub(s.since) > SWITCH_LIMIT {
                // The window ignores the request. The rest of the word is still typed in the
                // new layout, as text; the next word starts in the window's own layout.
                if !self.switch_failed {
                    let target = s.target.clone();
                    self.note("layout_not_selected", |_| json!({"target": target, "current": ctx.layout}));
                }
                self.switch_failed = true;
                if !self.typing.in_word() { self.switch = None; }
            }
        }
        if self.switch.is_none() && ctx.layout.map(str::to_string) != self.last_layout {
            // A layout the user selected (not one Yasno asked for) decides RU/UK ties.
            if let Some(id) = ctx.layout {
                if self.last_layout.is_some() && self.layout(id).is_some_and(|l| l.is_cyrillic()) {
                    self.typing.preferred = Some(id.to_string());
                    self.effects.push(Effect::Preferred(id.to_string()));
                }
            }
            self.last_layout = ctx.layout.map(str::to_string);
        }
    }

    fn watchdog(&mut self, ctx: &Context) {
        if let Some(g) = &self.gate {
            if ctx.now.saturating_sub(g.since) > GATE_LIMIT {
                let word = g.word.clone();
                self.gate = None;
                self.note("skipped", |e| e.word_fields(&word, false, json!({"reason": "the check took longer than 0.5 s: keys released as typed"})));
            }
        }
        if let Some((_, since)) = self.flight {
            if ctx.now.saturating_sub(since) > FLIGHT_LIMIT {
                // What was sent did not come back: the field may not hold what the model says.
                self.note("stall", |e| json!({"reason": "keys Yasno sent did not come back within 1 s", "text": e.typing.word()}));
                self.flight = None;
                self.typing.reset();
            }
        }
    }

    /// A key reached the hook. Returns true when it must not reach the application now.
    pub fn key(&mut self, key: RawKey, source: Source, ctx: Context) -> bool {
        match source {
            Source::Own => return false,
            Source::End(id) => {
                if self.flight.is_some_and(|(f, _)| f == id) { self.flight = None; }
                self.release(ctx);
                return true;
            }
            Source::User => {}
        }
        self.watch_layout(&ctx);
        self.watchdog(&ctx);
        if !self.enabled {
            self.track_modifiers(key);
            return false;
        }
        if !key.down && self.queue.is_empty() && self.as_text.remove(&key.scan) { return true; }
        if self.busy() {
            self.queue.push_back(key);
            self.release(ctx);
            self.effects.push(Effect::Start(Timer::Watchdog, WATCHDOG_TICK));
            return true;
        }
        // Nothing is held: the key goes on as pressed, in the layout the window uses.
        let delivered = self.deliver(key, &ctx);
        if matches!(delivered.output, Output::Text(_)) { self.as_text.remove(&key.scan); }
        let mut batch = Vec::new();
        self.finish(delivered, false, &mut batch, &ctx);
        self.send(batch, &ctx);
        false
    }

    pub fn timer(&mut self, timer: Timer, ctx: Context) {
        self.watch_layout(&ctx);
        match timer {
            Timer::Watchdog => {
                self.watchdog(&ctx);
                self.release(ctx);
                if self.holding() || self.switching() { self.effects.push(Effect::Start(Timer::Watchdog, WATCHDOG_TICK)); }
            }
            Timer::Pause => {
                if !self.enabled || self.busy() { return; }
                if let Some(check) = self.typing.pause_check() {
                    self.effects.push(Effect::Detect { check, gated: false });
                }
            }
        }
    }

    /// The detector answered.
    pub fn answer(&mut self, answer: Answer, ctx: Context) {
        self.watch_layout(&ctx);
        let mut batch = Vec::new();
        if answer.gated {
            // No gate: the watchdog released the keys and noted it.
            let Some(gate) = self.gate.clone() else { return };
            if gate.version != answer.version { return; }
            self.gate = None;
            if gate.cancelled {
                self.note("skipped", |e| e.word_fields(&gate.word, false, json!({"reason": "click or focus change during the check"})));
            } else {
                self.correct(&answer, &mut batch, &ctx);
            }
            self.drain(&mut batch, &ctx);
            self.send(batch, &ctx);
        } else {
            // A check made while typing: only if nothing was typed since.
            if self.busy() || answer.version != self.typing.version() { return; }
            self.correct(&answer, &mut batch, &ctx);
            self.send(batch, &ctx);
        }
    }

    fn correct(&mut self, answer: &Answer, batch: &mut Vec<Output>, ctx: &Context) {
        let live = !answer.gated;
        let word = if self.diagnostics { self.typing.word().to_string() } else { String::new() };
        if !self.enabled || !self.editable {
            let reason = if self.enabled { "field cannot be edited" } else { "monitoring off" };
            self.note("skipped", |e| e.word_fields(&word, live, json!({"reason": reason})));
            return;
        }
        let Some((replacement, target)) = answer.correction.clone() else {
            // A check while typing is answered only with a correction.
            if !live {
                let reason = answer.reason.unwrap_or("no correction");
                self.note("no_suggestion", |e| e.word_fields(&word, false, json!({"reason": reason})));
            }
            return;
        };
        let decision = Decision { version: self.typing.version(), replacement, target_id: target };
        let layouts = self.layouts.clone();
        let all: Vec<&KeyboardLayout> = layouts.iter().collect();
        let layout = self.typing.layout_id().to_string();
        if let Some(edit) = self.typing.apply(&decision, &all) {
            self.corrections += 1;
            let deletions = edit.deletions;
            self.note("edit", |_| json!({"result": "sent", "text": word, "layout": layout, "live": live,
                                         "replacement": decision.replacement, "target": decision.target_id,
                                         "deletions": deletions}));
            self.edit(edit, batch, ctx);
        } else {
            self.note("skipped", |e| e.word_fields(&word, live, json!({
                "reason": "the replacement cannot be typed over the word", "replacement": decision.replacement,
                "target": decision.target_id})));
        }
    }

    fn edit(&mut self, edit: Edit, batch: &mut Vec<Output>, ctx: &Context) {
        if edit.deletions > 0 { batch.push(Output::Erase(edit.deletions)); }
        if !edit.insertion.is_empty() { batch.push(Output::Text(edit.insertion)); }
        if let Some(target) = edit.switch_to {
            if self.model_layout(ctx) != Some(target.as_str()) {
                self.effects.push(Effect::Switch(target.clone()));
                self.effects.push(Effect::Start(Timer::Watchdog, WATCHDOG_TICK));
                self.switch = Some(Switch { target, since: ctx.now });
                self.switch_failed = false;
            }
        }
    }

    fn cancel_gate(&mut self) { self.gate = None; }

    /// Send held keys while no check holds them.
    fn release(&mut self, ctx: Context) {
        if self.gate.is_some() || self.queue.is_empty() { return; }
        let mut batch = Vec::new();
        self.drain(&mut batch, &ctx);
        self.send(batch, &ctx);
    }

    fn drain(&mut self, batch: &mut Vec<Output>, ctx: &Context) {
        while self.gate.is_none() {
            let Some(key) = self.queue.pop_front() else { break };
            if !key.down && self.as_text.remove(&key.scan) { continue; }
            if !self.enabled {
                self.track_modifiers(key);
                batch.push(Output::Key(key));
                continue;
            }
            let delivered = self.deliver(key, ctx);
            self.finish(delivered, true, batch, ctx);
        }
    }

    /// Adds a delivered key to the batch with what it started.
    fn finish(&mut self, d: Delivered, send_key: bool, batch: &mut Vec<Output>, ctx: &Context) {
        if send_key { batch.push(d.output); }
        if let Some(edit) = d.edit { self.edit(edit, batch, ctx); }
        if let Some(check) = d.check {
            if !check.while_typing {
                let (text, gated, ready) = (check.text.clone(), d.gated, self.ready);
                self.note("word", |e| e.word_fields(&text, false, json!({
                    "suffix": " ", "live_converted": check.live_converted, "held": gated, "dictionaries_loaded": ready})));
            }
            if d.gated {
                self.gate = Some(Gate { version: check.version, since: ctx.now, cancelled: false, word: check.text.clone() });
                self.effects.push(Effect::Detect { check, gated: true });
                self.effects.push(Effect::Start(Timer::Watchdog, WATCHDOG_TICK));
            } else {
                self.effects.push(Effect::Detect { check, gated: false });
            }
        }
    }

    fn send(&mut self, mut batch: Vec<Output>, ctx: &Context) {
        if batch.is_empty() { return; }
        let id = self.next_batch;
        self.next_batch += 1;
        batch.push(Output::End(id));
        self.flight = Some((id, ctx.now));
        self.effects.push(Effect::Send(batch));
        self.effects.push(Effect::Start(Timer::Watchdog, WATCHDOG_TICK));
    }

    fn track_modifiers(&mut self, key: RawKey) {
        let set = match key.vk {
            vk::LSHIFT | vk::RSHIFT | vk::SHIFT => &mut self.shifts,
            vk::LCONTROL | vk::RCONTROL | vk::CONTROL => &mut self.ctrl,
            vk::LMENU | vk::RMENU | vk::MENU => &mut self.alt,
            vk::LWIN | vk::RWIN => &mut self.win,
            vk::CAPITAL => {
                if key.down && !self.caps_down { self.caps = !self.caps; }
                self.caps_down = key.down;
                return;
            }
            _ => return,
        };
        if key.down { set.insert(key.vk); } else { set.remove(&key.vk); }
    }

    /// The key reaches the application now (as itself or as text): the model follows it.
    fn deliver(&mut self, key: RawKey, ctx: &Context) -> Delivered {
        let raw = Delivered { output: Output::Key(key), check: None, gated: false, edit: None };
        let time = key.time as f64 / 1000.0;
        match key.vk {
            vk::LSHIFT | vk::RSHIFT | vk::SHIFT => {
                let clean = self.ctrl.is_empty() && self.alt.is_empty() && self.win.is_empty();
                let first = self.shifts.is_empty();
                self.track_modifiers(key);
                if key.down {
                    if first { self.gesture.press(key.scan, time, clean); }
                } else if self.shifts.is_empty() && self.gesture.release(key.scan, time, clean) {
                    return Delivered { edit: self.shift_tap(ctx), ..raw };
                }
                return raw;
            }
            vk::LCONTROL | vk::RCONTROL | vk::CONTROL | vk::LMENU | vk::RMENU | vk::MENU | vk::LWIN | vk::RWIN => {
                self.track_modifiers(key);
                self.gesture.cancel();
                // A shortcut may move the caret or change the text.
                if key.down { self.drop_word("shortcut with Ctrl, Alt or Win"); self.typing.reset(); }
                return raw;
            }
            vk::CAPITAL => { self.track_modifiers(key); self.gesture.cancel(); return raw; }
            _ => {}
        }
        if !key.down { return raw; }
        self.gesture.cancel();
        let layouts = self.layouts.clone();
        let layout = self.model_layout(ctx).and_then(|id| layouts.iter().find(|l| l.id == id));
        let Some(layout) = layout else {
            self.drop_word("the window's keyboard layout is not one of Yasno's");
            if !self.unknown_layout_noted {
                self.unknown_layout_noted = true;
                self.note("skipped", |e| json!({"reason": "the window's keyboard layout is not one of Yasno's",
                                                 "window_layout": ctx.layout, "layouts": e.layouts.iter().map(|l| l.id.as_str()).collect::<Vec<_>>()}));
            }
            self.typing.reset();
            return raw;
        };
        self.unknown_layout_noted = false;
        let modified = !(self.ctrl.is_empty() && self.alt.is_empty() && self.win.is_empty());
        let k = match key.vk {
            _ if modified => Key::Navigation,
            vk::SPACE => Key::Space,
            vk::RETURN => Key::Enter,
            vk::TAB => Key::Tab,
            vk::BACK => Key::Backspace,
            vk::NUMLOCK | vk::SCROLL | vk::PAUSE | vk::SNAPSHOT => return raw,
            v if key.extended || (vk::F1..=vk::F24).contains(&v) || v == vk::ESCAPE || v == vk::DELETE
                || v == vk::INSERT || v == vk::APPS => Key::Navigation,
            _ => Key::Char(KeyStroke { key: key.scan, shift: !self.shifts.is_empty(), caps_lock: self.caps }),
        };
        let mut output = Output::Key(key);
        if let Key::Char(s) = k {
            if let Some(text) = layout.character(s.key, s.shift, s.caps_lock) {
                if !layout.is_dead_key(s.key, s.shift, s.caps_lock) && !text.chars().any(char::is_control) {
                    output = Output::Text(text.to_string());
                    self.as_text.insert(key.scan);
                }
            }
            self.effects.push(Effect::Start(Timer::Pause, PAUSE));
        }
        let before = (self.diagnostics && self.typing.in_word())
            .then(|| (self.typing.word().to_string(), self.typing.layout_id().to_string()));
        let check = self.typing.key(k, layout);
        if let Some((word, word_layout)) = before {
            if k != Key::Backspace && !self.typing.word().starts_with(word.as_str()) {
                let reason = match k {
                    Key::Navigation if modified => "shortcut with Ctrl, Alt or Win",
                    Key::Navigation => "navigation key (arrow, Home, End, Esc, Delete, F-key)",
                    Key::Enter => "Enter: the word is not checked",
                    Key::Tab => "Tab: the word is not checked",
                    Key::Char(s) if layout.character(s.key, s.shift, s.caps_lock).is_none() => "key without a character in the layout",
                    Key::Char(s) if layout.is_dead_key(s.key, s.shift, s.caps_lock) => "dead key",
                    Key::Char(_) => "layout changed in the middle of the word",
                    _ => "reset",
                };
                let vk = key.vk;
                self.note("word_dropped", |_| json!({"reason": reason, "text": word, "layout": word_layout, "vk": vk}));
            }
        }
        // Nothing is checked for a field that cannot be edited.
        let check = match check {
            Some(c) if !self.editable => {
                if !c.while_typing {
                    self.note("skipped", |e| e.word_fields(&c.text, false, json!({"reason": "field cannot be edited"})));
                }
                None
            }
            c => c,
        };
        let gated = check.as_ref().is_some_and(|c| !c.while_typing) && self.ready;
        Delivered { output, check, gated, edit: None }
    }

    fn shift_tap(&mut self, ctx: &Context) -> Option<Edit> {
        if !self.editable { return None; }
        let layouts = self.layouts.clone();
        let all: Vec<&KeyboardLayout> = layouts.iter().collect();
        let current = self.model_layout(ctx)?.to_string();
        let current = layouts.iter().find(|l| l.id == current)?;
        let edit = self.typing.shift_tap(&self.detector, &all, current)?;
        if let Some(id) = &edit.switch_to {
            if self.layout(id).is_some_and(|l| l.is_cyrillic()) { self.effects.push(Effect::Preferred(id.clone())); }
        }
        Some(edit)
    }
}

struct Delivered {
    output: Output,
    check: Option<Check>,
    gated: bool,
    edit: Option<Edit>,
}
