//! Sending what the engine asks for with SendInput, in one call per batch: Windows never
//! interleaves other input into one SendInput call.

use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE,
    VK_BACK,
};
use yasno_core::engine::{Output, Source};

/// Marks Yasno's own events so the hook lets them through untouched.
pub const OWN: usize = 0x5941_534E; // "YASN"
/// The last event of a batch carries its number under this tag.
const END: usize = 0x5945_0000_0000_0000;
const END_MASK: usize = 0xFFFF_0000_0000_0000;
/// An unassigned virtual key: the end marker, never delivered (the hook keeps it).
const VK_END: u16 = 0xE8;

pub fn source(extra: usize) -> Source {
    if extra == OWN { Source::Own }
    else if extra & END_MASK == END { Source::End((extra & !END_MASK) as u64) }
    else { Source::User }
}

fn key(vk: u16, scan: u16, flags: u32, extra: usize) -> INPUT {
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: extra } } }
}

pub fn inputs(batch: &[Output]) -> Vec<INPUT> {
    let mut out = Vec::new();
    for o in batch {
        match o {
            Output::Key(k) => {
                let flags = if k.down { 0 } else { KEYEVENTF_KEYUP } | if k.extended { KEYEVENTF_EXTENDEDKEY } else { 0 };
                out.push(key(k.vk, k.scan, flags, OWN));
            }
            Output::Erase(n) => for _ in 0..*n {
                out.push(key(VK_BACK, 0x0E, 0, OWN));
                out.push(key(VK_BACK, 0x0E, KEYEVENTF_KEYUP, OWN));
            },
            Output::Text(s) => for unit in s.encode_utf16() {
                out.push(key(0, unit, KEYEVENTF_UNICODE, OWN));
                out.push(key(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, OWN));
            },
            Output::End(id) => out.push(key(VK_END, 0, KEYEVENTF_KEYUP, END | (*id as usize & !END_MASK))),
        }
    }
    out
}

pub fn send(batch: &[Output]) -> bool {
    let inputs = inputs(batch);
    if inputs.is_empty() { return true; }
    let sent = unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
    sent as usize == inputs.len()
}
