//! The installed keyboard layouts, read from Windows itself with `ToUnicodeEx` for every
//! physical key, as the Mac version reads the Apple tables with `UCKeyTranslate`.

use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyboardLayoutList, MapVirtualKeyExW, ToUnicodeEx, HKL, MAPVK_VSC_TO_VK_EX, VK_CAPITAL, VK_SHIFT,
};
use yasno_core::{KeyEntry, KeyboardLayout, Language};

/// The typing block and the keypad, by scan code.
const KEYS: &[u16] = &[
    0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B,
    0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2B,
    0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x39, 0x56,
];

/// Do not change the keyboard state of this thread (Windows 10 1607 and later): reading
/// a table must not swallow a dead key the user is composing.
const NO_STATE_CHANGE: u32 = 0x4;

pub fn id(hkl: HKL) -> String { format!("{:016X}", hkl as usize) }

pub fn langid(hkl: HKL) -> u16 { (hkl as usize & 0xffff) as u16 }

pub fn installed() -> Vec<(HKL, KeyboardLayout)> {
    unsafe {
        let n = GetKeyboardLayoutList(0, std::ptr::null_mut());
        if n <= 0 { return Vec::new(); }
        let mut list: Vec<HKL> = vec![std::ptr::null_mut(); n as usize];
        let n = GetKeyboardLayoutList(n, list.as_mut_ptr());
        list.truncate(n.max(0) as usize);
        list.into_iter().filter_map(|hkl| read(hkl).map(|l| (hkl, l))).collect()
    }
}

fn read(hkl: HKL) -> Option<KeyboardLayout> {
    let languages = Language::for_windows_langid(langid(hkl))?;
    let mut entries = Vec::new();
    for &scan in KEYS {
        let vk = unsafe { MapVirtualKeyExW(scan as u32, MAPVK_VSC_TO_VK_EX, hkl) };
        if vk == 0 { continue; }
        for caps in [false, true] {
            for shift in [false, true] {
                let mut state = [0u8; 256];
                if shift { state[VK_SHIFT as usize] = 0x80; }
                if caps { state[VK_CAPITAL as usize] = 0x01; }
                let mut buf = [0u16; 8];
                let r = unsafe { ToUnicodeEx(vk, scan as u32, state.as_ptr(), buf.as_mut_ptr(), buf.len() as i32, NO_STATE_CHANGE, hkl) };
                let (len, dead) = if r < 0 { (1, true) } else { (r as usize, false) };
                if len == 0 { continue; }
                let text = String::from_utf16_lossy(&buf[..len.min(buf.len())]);
                entries.push(KeyEntry { key: scan, shift, caps_lock: caps, text, dead });
            }
        }
    }
    let name = languages.iter().map(|l| l.code()).collect::<Vec<_>>().join("+");
    Some(KeyboardLayout::new(id(hkl), name, languages, entries))
}
