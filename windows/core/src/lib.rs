//! Platform-independent core of Yasno for Windows: a port of the macOS `SwitchCore`
//! target (Sources/SwitchCore). The decision rules follow the Swift code line by line
//! so both versions correct the same words; only the keyboard tables and the system
//! spelling service come from the platform.

pub mod chars;
pub mod detector;
pub mod geometry;
pub mod keystroke_edit;
pub mod language;
pub mod layout;
pub mod layout_cycle;
pub mod layouts;
pub mod lexicon;
pub mod policy;
pub mod shift_tap;
pub mod spelling;
pub mod text_safety;
pub mod web_address;
pub mod word_boundary;
pub mod word_text;

pub use detector::{Detector, Suggestion};
pub use keystroke_edit::KeystrokeEdit;
pub use language::Language;
pub use layout::{KeyEntry, KeyStroke, KeyboardLayout};
pub use layout_cycle::LayoutCycle;
pub use lexicon::{Lexicon, NoLexicon};
pub use policy::CorrectionRequest;
pub use shift_tap::ShiftTapGesture;
