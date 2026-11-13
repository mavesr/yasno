//! Sending keys: Backspace and Unicode text for edits, original keys for replays.

use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE,
    VK_BACK,
};

/// Marks Yasno's own edits so the hook lets them through untouched.
pub const MAGIC: usize = 0x5941_534E; // "YASN"
/// The last event of an edit: held keys may be replayed after it.
pub const MAGIC_END: usize = 0x5941_534F;
/// Keys the user pressed during an edit, sent again after it. The hook treats them
/// as typed by the user.
pub const MAGIC_REPLAY: usize = 0x5941_5350;

fn key(vk: u16, scan: u16, flags: u32, extra: usize) -> INPUT {
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: extra } } }
}

/// Erase `deletions` characters before the caret and type `text`.
pub fn edit(deletions: usize, text: &str) -> Vec<INPUT> {
    let mut inputs = Vec::new();
    for _ in 0..deletions {
        inputs.push(key(VK_BACK, 0, 0, MAGIC));
        inputs.push(key(VK_BACK, 0, KEYEVENTF_KEYUP, MAGIC));
    }
    for unit in text.encode_utf16() {
        inputs.push(key(0, unit, KEYEVENTF_UNICODE, MAGIC));
        inputs.push(key(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, MAGIC));
    }
    if let Some(last) = inputs.last_mut() { last.Anonymous.ki.dwExtraInfo = MAGIC_END; }
    inputs
}

#[derive(Clone, Copy, Debug)]
pub struct Held { pub vk: u16, pub scan: u16, pub up: bool, pub extended: bool }

pub fn replay(held: &[Held]) -> Vec<INPUT> {
    held.iter().map(|h| {
        let flags = if h.up { KEYEVENTF_KEYUP } else { 0 } | if h.extended { KEYEVENTF_EXTENDEDKEY } else { 0 };
        key(h.vk, h.scan, flags, MAGIC_REPLAY)
    }).collect()
}

pub fn send(inputs: &[INPUT]) -> bool {
    if inputs.is_empty() { return true; }
    let sent = unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
    sent as usize == inputs.len()
}
