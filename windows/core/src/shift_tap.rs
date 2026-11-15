/// Fires only on release of one briefly held Shift that was never used with another input.
/// The actual modifier events always continue to the application without delay.
#[derive(Default, Clone, Debug)]
pub struct ShiftTapGesture {
    down: Option<(u16, f64)>,
    blocked_until_release: bool,
}

impl ShiftTapGesture {
    pub const MAXIMUM_HOLD: f64 = 0.4;

    pub fn new() -> Self { Self::default() }

    /// A Shift press that a later mouse action could still turn into a chord.
    pub fn is_pressed(&self) -> bool { self.down.is_some() }

    pub fn reset(&mut self) { self.down = None; self.blocked_until_release = false; }

    /// Typing, another modifier, or a mouse action makes this a normal Shift chord.
    pub fn cancel(&mut self) {
        if self.down.is_some() { self.blocked_until_release = true; }
        self.down = None;
    }

    pub fn press(&mut self, key: u16, time: f64, clean: bool) {
        // Overlapping left/right Shift and duplicate down events must not restart a tap.
        if !clean || !time.is_finite() || self.down.is_some() || self.blocked_until_release {
            self.down = None;
            self.blocked_until_release = true;
            return;
        }
        self.down = Some((key, time));
    }

    /// Call only once all Shift keys are released, including an overlapping two-Shift chord.
    pub fn release(&mut self, key: u16, time: f64, clean: bool) -> bool {
        let started = self.down;
        let blocked = self.blocked_until_release;
        self.reset();
        match started {
            Some((k, t)) if clean && !blocked && k == key && time.is_finite() && time >= t
                && time - t <= Self::MAXIMUM_HOLD => true,
            _ => false,
        }
    }
}
