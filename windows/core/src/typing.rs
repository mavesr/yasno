//! The typing session: what the user typed in the focused field since the last click,
//! focus change or navigation key, and the edits Yasno makes to it. Platform-free: the
//! Windows app feeds it keys from its keyboard hook and performs the edits it returns
//! with Backspace and Unicode input, so every rule here is tested on any platform.

use std::collections::HashSet;

use crate::chars::count;
use crate::detector::Detector;
use crate::keystroke_edit::KeystrokeEdit;
use crate::layout::{KeyStroke, KeyboardLayout};
use crate::layout_cycle::LayoutCycle;
use crate::policy::CorrectionRequest;

/// Up to 256 characters typed before the word, as on the Mac.
const CONTEXT_LIMIT: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    /// A key that types a character in the current layout.
    Char(KeyStroke),
    Space,
    /// Enter and Tab end the word without a correction: Enter may already have sent it.
    Enter,
    Tab,
    Backspace,
    /// Arrows, Home/End, a click, a shortcut, a focus change: the caret may have moved.
    Navigation,
}

/// A word to check off the hook thread.
#[derive(Clone, Debug, PartialEq)]
pub struct Check {
    pub version: u64,
    pub text: String,
    pub layout_id: String,
    pub context: String,
    pub while_typing: bool,
    pub live_converted: bool,
    /// Typing stopped on a two- or three-letter word (search fields get no Space).
    pub paused: bool,
}

impl Check {
    pub fn request<'a>(&self, layouts: &'a [&'a KeyboardLayout], ignored: &HashSet<String>, preferred: Option<&str>,
                       correct_spelling: bool) -> Option<CorrectionRequest<'a>> {
        let source = *layouts.iter().find(|l| l.id == self.layout_id)?;
        Some(CorrectionRequest::new(&self.text, source, layouts, ignored, preferred, correct_spelling,
                                    self.while_typing, self.live_converted, self.paused))
    }
}

/// The detector's answer to a Check.
#[derive(Clone, Debug, PartialEq)]
pub struct Decision {
    pub version: u64,
    pub replacement: String,
    pub target_id: String,
}

/// What the app does in the field: erase, type, then switch the layout.
#[derive(Clone, Debug, PartialEq)]
pub struct Edit {
    pub deletions: usize,
    pub insertion: String,
    pub switch_to: Option<String>,
}

#[derive(Clone, Debug)]
struct Undo { original: String, original_layout: String, replacement: String }

#[derive(Clone, Debug)]
struct ManualCycle { original: String, strokes: Vec<KeyStroke>, source: String, cycle: LayoutCycle, current: String }

#[derive(Default, Debug)]
pub struct Typing {
    strokes: Vec<KeyStroke>,
    text: String,
    suffix: String,
    context: String,
    layout_id: String,
    version: u64,
    live_converted: bool,
    undo: Option<Undo>,
    manual: Option<ManualCycle>,
    /// The Cyrillic layout the user chose last; resolves RU/UK ties.
    pub preferred: Option<String>,
}

impl Typing {
    pub fn new() -> Self { Self::default() }

    pub fn word(&self) -> &str { &self.text }
    pub fn version(&self) -> u64 { self.version }

    /// Forget everything: the caret may be anywhere now.
    pub fn reset(&mut self) {
        let preferred = self.preferred.take();
        *self = Typing { preferred, version: self.version + 1, ..Default::default() };
    }

    fn commit_word(&mut self) {
        self.context.push_str(&self.text);
        self.context.push_str(&self.suffix);
        let n = count(&self.context);
        if n > CONTEXT_LIMIT { self.context = crate::chars::drop_first(&self.context, n - CONTEXT_LIMIT).to_string(); }
        self.strokes.clear();
        self.text.clear();
        self.suffix.clear();
        self.live_converted = false;
    }

    fn check(&self, while_typing: bool) -> Check {
        Check { version: self.version, text: self.text.clone(), layout_id: self.layout_id.clone(),
                context: self.context.clone(), while_typing, live_converted: self.live_converted, paused: false }
    }

    /// Called when typing stopped for 0.6 s: a short unfinished word is checked as complete.
    pub fn pause_check(&self) -> Option<Check> {
        if !self.suffix.is_empty() || self.live_converted || !(2..=3).contains(&count(&self.text)) { return None; }
        Some(Check { paused: true, ..self.check(true) })
    }

    /// One key as the user pressed it, in the layout active at that moment.
    pub fn key(&mut self, key: Key, layout: &KeyboardLayout) -> Option<Check> {
        self.version += 1;
        match key {
            Key::Char(stroke) => {
                let Some(c) = layout.character(stroke.key, stroke.shift, stroke.caps_lock) else { self.reset(); return None };
                if layout.is_dead_key(stroke.key, stroke.shift, stroke.caps_lock) { self.reset(); return None; }
                if !self.suffix.is_empty() { self.commit_word(); }
                if self.text.is_empty() || self.layout_id != layout.id { self.layout_id = layout.id.clone(); }
                self.undo = None;
                self.manual = None;
                self.strokes.push(stroke);
                self.text.push_str(c);
                Some(self.check(true))
            }
            Key::Space => {
                if self.text.is_empty() { self.context.push(' '); return None; }
                if !self.suffix.is_empty() { self.suffix.push(' '); self.undo = None; return None; }
                self.suffix.push(' ');
                self.manual = None;
                Some(self.check(false))
            }
            Key::Enter | Key::Tab => {
                self.commit_word();
                self.context.push(if key == Key::Enter { '\n' } else { '\t' });
                self.undo = None;
                self.manual = None;
                None
            }
            Key::Backspace => {
                self.undo = None;
                self.manual = None;
                if self.suffix.pop().is_some() { return None; }
                if self.text.pop().is_some() { self.strokes.pop(); if self.text.is_empty() { self.live_converted = false; } }
                else { self.context.pop(); }
                None
            }
            Key::Navigation => { self.reset(); None }
        }
    }

    /// The detector's answer, if nothing was typed since the check.
    pub fn apply(&mut self, decision: &Decision, layouts: &[&KeyboardLayout]) -> Option<Edit> {
        if decision.version != self.version || decision.replacement == self.text { return None; }
        let target = layouts.iter().find(|l| l.id == decision.target_id)?;
        let edit = KeystrokeEdit::new(&self.text, &decision.replacement, &self.suffix)?;
        self.undo = Some(Undo { original: self.text.clone(), original_layout: self.layout_id.clone(),
                                replacement: decision.replacement.clone() });
        self.set_word(&decision.replacement, target);
        self.live_converted = self.suffix.is_empty();
        self.version += 1;
        let switch_to = (target.id != self.undo.as_ref().unwrap().original_layout).then(|| target.id.clone());
        Some(Edit { deletions: edit.deletions, insertion: edit.insertion, switch_to })
    }

    fn set_word(&mut self, text: &str, layout: &KeyboardLayout) {
        self.text = text.to_string();
        self.strokes = text.chars().map(|c| layout.stroke(c)).collect::<Option<Vec<_>>>().unwrap_or_default();
        self.layout_id = layout.id.clone();
    }

    /// A short Shift tap: undo the last automatic change, convert the word to the next
    /// layout, or, with no word, switch the layout. `current` is the active layout.
    pub fn shift_tap(&mut self, detector: &Detector, layouts: &[&KeyboardLayout], current: &KeyboardLayout) -> Option<Edit> {
        self.version += 1;
        let ordered: Vec<String> = KeyboardLayout::cycle_order(layouts).iter().map(|l| l.id.clone()).collect();
        if let Some(undo) = self.undo.take() {
            if undo.replacement == self.text {
                let original = layouts.iter().find(|l| l.id == undo.original_layout)?;
                let edit = KeystrokeEdit::new(&self.text, &undo.original, &self.suffix)?;
                let strokes = self.strokes.clone();
                self.set_word(&undo.original, original);
                self.live_converted = false;
                // The next tap continues the full cycle from the original text.
                self.manual = Some(ManualCycle { original: undo.original.clone(), strokes, source: original.id.clone(),
                                                 cycle: LayoutCycle::new(&ordered, Some(&original.id), None),
                                                 current: original.id.clone() });
                self.remember_choice(original);
                return Some(Edit { deletions: edit.deletions, insertion: edit.insertion, switch_to: Some(original.id.clone()) });
            }
        }
        if self.text.is_empty() {
            let next = LayoutCycle::new(&ordered, None, None).next(&current.id)?.to_string();
            if let Some(l) = layouts.iter().find(|l| l.id == next) { self.remember_choice(l); }
            return Some(Edit { deletions: 0, insertion: String::new(), switch_to: Some(next) });
        }
        let source = layouts.iter().find(|l| l.id == self.layout_id).copied().unwrap_or(current);
        let (target, output) = match self.manual.clone() {
            Some(m) => {
                let next = m.cycle.next(&m.current)?.to_string();
                let target = *layouts.iter().find(|l| l.id == next)?;
                let from = *layouts.iter().find(|l| l.id == m.source)?;
                let output = if next == m.source { m.original.clone() } else {
                    let keys = (!m.strokes.is_empty()).then_some(m.strokes.as_slice());
                    detector.convert_text_manually(&m.original, from, target, keys)?
                };
                (target, output)
            }
            None => {
                let keys = (!self.strokes.is_empty()).then_some(self.strokes.as_slice());
                let s = detector.convert_manually(&self.text, source, layouts, self.preferred.as_deref(), keys)?;
                self.manual = Some(ManualCycle { original: self.text.clone(), strokes: self.strokes.clone(),
                                                 source: source.id.clone(),
                                                 cycle: LayoutCycle::new(&ordered, Some(&source.id), Some(&s.target.id)),
                                                 current: source.id.clone() });
                (s.target, s.replacement)
            }
        };
        let edit = KeystrokeEdit::new(&self.text, &output, &self.suffix)?;
        let strokes = self.strokes.clone();
        self.text = output;
        self.strokes = strokes;
        self.layout_id = target.id.clone();
        self.live_converted = false;
        if let Some(m) = self.manual.as_mut() { m.current = target.id.clone(); }
        self.remember_choice(target);
        Some(Edit { deletions: edit.deletions, insertion: edit.insertion, switch_to: Some(target.id.clone()) })
    }

    fn remember_choice(&mut self, layout: &KeyboardLayout) {
        if layout.is_cyrillic() { self.preferred = Some(layout.id.clone()); }
    }
}
