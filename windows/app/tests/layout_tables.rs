//! The reference tables in yasno-core match the real Windows layouts. Runs on Windows
//! only (CI): loads each layout and reads every key through ToUnicodeEx.
#![cfg(windows)]

use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    LoadKeyboardLayoutW, MapVirtualKeyExW, ToUnicodeEx, KLF_NOTELLSHELL, MAPVK_VSC_TO_VK_EX, VK_SHIFT,
};
use yasno_core::layouts;

const KEYS: &[u16] = &[
    0x29, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x2B,
    0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
    0x56, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
];

#[test]
fn reference_tables_match_windows() {
    let mut mismatches = Vec::new();
    for reference in layouts::all() {
        let klid: Vec<u16> = reference.id.encode_utf16().chain(Some(0)).collect();
        let hkl = unsafe { LoadKeyboardLayoutW(klid.as_ptr(), KLF_NOTELLSHELL) };
        assert!(!hkl.is_null(), "cannot load {}", reference.id);
        for &scan in KEYS {
            for shift in [false, true] {
                let vk = unsafe { MapVirtualKeyExW(scan as u32, MAPVK_VSC_TO_VK_EX, hkl) };
                let mut state = [0u8; 256];
                if shift { state[VK_SHIFT as usize] = 0x80; }
                let mut buf = [0u16; 8];
                let r = unsafe { ToUnicodeEx(vk, scan as u32, state.as_ptr(), buf.as_mut_ptr(), 8, 0x4, hkl) };
                let len = if r < 0 { 1 } else { r as usize };
                let actual = String::from_utf16_lossy(&buf[..len]);
                let expected = reference.character(scan, shift, false).unwrap_or("");
                if actual != expected || (r < 0) != reference.is_dead_key(scan, shift, false) {
                    mismatches.push(format!("{} {} scan {scan:#04x} shift {shift}: windows {actual:?} (dead {}), table {expected:?}",
                                            reference.id, reference.name, r < 0));
                }
            }
        }
    }
    assert!(mismatches.is_empty(), "\n{}", mismatches.join("\n"));
}
