//! Ports of ShiftTapTests and LayoutCycleTests. Keys are Windows scan codes:
//! 0x2A left Shift, 0x36 right Shift.

use yasno_core::{layouts, KeyboardLayout, LayoutCycle, ShiftTapGesture};

const L: u16 = 0x2A;
const R: u16 = 0x36;

#[test]
fn single_tap_with_either_shift() {
    for key in [L, R] {
        let mut g = ShiftTapGesture::new();
        g.press(key, 1.0, true);
        assert!(g.release(key, 1.12, true));
        assert!(!g.release(key, 1.13, true));
    }
}

#[test]
fn chords_and_other_modifiers_never_switch() {
    let mut g = ShiftTapGesture::new();
    g.press(L, 1.0, true); g.cancel();
    assert!(!g.release(L, 1.2, true));
    g.press(L, 2.0, true);
    assert!(g.release(L, 2.1, true));
    g.press(L, 3.0, false);
    assert!(!g.release(L, 3.1, true));
    g.press(L, 4.0, true);
    assert!(!g.release(L, 4.1, false));
}

#[test]
fn long_hold_overlap_duplicate_and_unmatched() {
    let mut g = ShiftTapGesture::new();
    g.press(L, 1.0, true);
    assert!(!g.release(L, 1.6, true));
    g.press(L, 2.0, true);
    assert!(g.release(L, 2.2, true));
    g.press(L, 3.0, true); g.press(R, 3.05, true); g.press(L, 3.1, true);
    assert!(!g.release(R, 3.15, true));
    g.press(L, 4.0, true); g.press(L, 5.0, true);
    assert!(!g.release(L, 5.1, true));
    assert!(!g.release(L, 6.0, true));
    g.press(L, 7.0, true);
    assert!(!g.release(R, 7.1, true));
    g.press(L, 8.0, true);
    assert!(g.release(L, 8.07, true));
    g.press(L, 8.16, true);
    assert!(g.release(L, 8.23, true));
}

#[test]
fn layout_cycle() {
    let ids: Vec<String> = ["abc", "ru", "uk"].iter().map(|s| s.to_string()).collect();
    let cycle = LayoutCycle::new(&ids, None, None);
    let mut current = "abc".to_string();
    for expected in ["ru", "uk", "abc", "ru", "uk", "abc"] {
        current = cycle.next(&current).unwrap().to_string();
        assert_eq!(current, expected);
    }
    let smart = LayoutCycle::new(&ids, Some("abc"), Some("uk"));
    assert_eq!(smart.next("abc"), Some("uk"));
    assert_eq!(smart.next("uk"), Some("ru"));
    assert_eq!(smart.next("ru"), Some("abc"));
    let dup: Vec<String> = ["abc", "uk", "abc"].iter().map(|s| s.to_string()).collect();
    let c = LayoutCycle::new(&dup, Some("abc"), Some("ru"));
    assert_eq!(c.layout_ids, vec!["abc", "uk"]);
    assert_eq!(LayoutCycle::new(&["abc".to_string(), "abc".to_string()], None, None).next("abc"), None);
}

#[test]
fn cycle_order_and_reconversion() {
    let (abc, ru, uk) = (layouts::us(), layouts::russian(), layouts::ukrainian());
    assert_eq!(abc.convert("ghbdtn", &uk).unwrap(), "привет"); // и is on B in both
    assert_eq!(abc.convert("ghbdtn", &ru).unwrap(), "привет");
    assert_eq!(abc.convert("ghbdtn", &abc).unwrap(), "ghbdtn");
    let order: Vec<&str> = KeyboardLayout::cycle_order(&[&uk, &abc, &ru]).iter().map(|l| l.id.as_str()).collect();
    assert_eq!(order, [abc.id.as_str(), ru.id.as_str(), uk.id.as_str()]);
}

#[test]
fn ukrainian_letters_on_windows_positions() {
    let (abc, uk, uke) = (layouts::us(), layouts::ukrainian(), layouts::ukrainian_enhanced());
    assert_eq!(abc.convert("s]'", &uk).unwrap(), "іїє");
    assert_eq!(uke.character(0x2B, false, false), Some("ґ"));
    assert_eq!(uk.apostrophe_glyph(), "'");
}
