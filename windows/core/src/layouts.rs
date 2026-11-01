//! Reference tables of the standard Windows layouts Yasno supports. The app reads the
//! installed layouts through `ToUnicodeEx` at run time; these tables serve the tests on
//! any platform and are checked against the real Windows tables in CI
//! (`windows/app/tests/layout_tables.rs`). AltGr levels are ignored, as Option is on the Mac.

use crate::language::Language;
use crate::layout::{KeyEntry, KeyboardLayout};

const ROW0: [u16; 13] = [0x29, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D];
const ROW1: [u16; 13] = [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x2B];
const ROW2: [u16; 11] = [0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28];
const ROW3: [u16; 11] = [0x56, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35];

/// Rows as (normal, shifted) strings, one character per key in ROW0..ROW3 order.
struct Table { rows: [(&'static str, &'static str); 4], dead: &'static [(u16, bool)] }

fn entries(table: &Table) -> Vec<KeyEntry> {
    let keys: [&[u16]; 4] = [&ROW0, &ROW1, &ROW2, &ROW3];
    let mut out = Vec::new();
    for (row, (normal, shifted)) in keys.iter().zip(table.rows.iter()) {
        let normal: Vec<char> = normal.chars().collect();
        let shifted: Vec<char> = shifted.chars().collect();
        assert_eq!(normal.len(), row.len());
        assert_eq!(shifted.len(), row.len());
        for (i, &key) in row.iter().enumerate() {
            let (n, s) = (normal[i], shifted[i]);
            // Windows Caps Lock acts as Shift on letter keys (CAPLOK) and Shift then gives lowercase.
            let caps_letter = n.is_alphabetic() && n.to_uppercase().eq(std::iter::once(s));
            for (shift, caps, c) in [(false, false, n), (true, false, s),
                                     (false, true, if caps_letter { s } else { n }),
                                     (true, true, if caps_letter { n } else { s })] {
                out.push(KeyEntry { key, shift, caps_lock: caps, text: c.to_string(),
                                    dead: table.dead.contains(&(key, shift)) });
            }
        }
    }
    for caps in [false, true] {
        for shift in [false, true] {
            out.push(KeyEntry { key: 0x39, shift, caps_lock: caps, text: " ".into(), dead: false });
        }
    }
    out
}

const US: Table = Table { rows: [
    ("`1234567890-=", "~!@#$%^&*()_+"),
    ("qwertyuiop[]\\", "QWERTYUIOP{}|"),
    ("asdfghjkl;'", "ASDFGHJKL:\""),
    ("\\zxcvbnm,./", "|ZXCVBNM<>?"),
], dead: &[] };

const RUSSIAN: Table = Table { rows: [
    ("ё1234567890-=", "Ё!\"№;%:?*()_+"),
    ("йцукенгшщзхъ\\", "ЙЦУКЕНГШЩЗХЪ/"),
    ("фывапролджэ", "ФЫВАПРОЛДЖЭ"),
    ("\\ячсмитьбю.", "/ЯЧСМИТЬБЮ,"),
], dead: &[] };

const UKRAINIAN: Table = Table { rows: [
    ("'1234567890-=", "₴!\"№;%:?*()_+"),
    ("йцукенгшщзхї\\", "ЙЦУКЕНГШЩЗХЇ/"),
    ("фівапролджє", "ФІВАПРОЛДЖЄ"),
    ("\\ячсмитьбю.", "/ЯЧСМИТЬБЮ,"),
], dead: &[] };

const UKRAINIAN_ENHANCED: Table = Table { rows: [
    ("'1234567890-=", "₴!\"№;%:?*()_+"),
    ("йцукенгшщзхїґ", "ЙЦУКЕНГШЩЗХЇҐ"),
    ("фівапролджє", "ФІВАПРОЛДЖЄ"),
    ("\\ячсмитьбю.", "/ЯЧСМИТЬБЮ,"),
], dead: &[] };

const GERMAN: Table = Table { rows: [
    ("^1234567890ß´", "°!\"§$%&/()=?`"),
    ("qwertzuiopü+#", "QWERTZUIOPÜ*'"),
    ("asdfghjklöä", "ASDFGHJKLÖÄ"),
    ("<yxcvbnm,.-", ">YXCVBNM;:_"),
], dead: &[(0x29, false), (0x0D, false), (0x0D, true)] };

pub fn us() -> KeyboardLayout { KeyboardLayout::new("00000409", "US", vec![Language::English, Language::German], entries(&US)) }
pub fn russian() -> KeyboardLayout { KeyboardLayout::new("00000419", "Russian", vec![Language::Russian], entries(&RUSSIAN)) }
pub fn ukrainian() -> KeyboardLayout { KeyboardLayout::new("00000422", "Ukrainian", vec![Language::Ukrainian], entries(&UKRAINIAN)) }
pub fn ukrainian_enhanced() -> KeyboardLayout {
    KeyboardLayout::new("00020422", "Ukrainian (Enhanced)", vec![Language::Ukrainian], entries(&UKRAINIAN_ENHANCED))
}
pub fn german() -> KeyboardLayout { KeyboardLayout::new("00000407", "German", vec![Language::German, Language::English], entries(&GERMAN)) }

/// Every reference layout, keyed by its Windows layout id (KLID).
pub fn all() -> Vec<KeyboardLayout> { vec![us(), russian(), ukrainian(), ukrainian_enhanced(), german()] }
