//! Ясно for Windows 11: switches the keyboard layout when a word was typed in the wrong
//! one, like the macOS app. The decisions come from `yasno-core`; this crate is the
//! Windows shell around it: keyboard hook, layout tables, edits and the tray icon.

#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod win;

#[cfg(windows)]
fn main() { win::run(); }

#[cfg(not(windows))]
fn main() {
    eprintln!("Yasno for Windows runs only on Windows. The shared logic is tested with `cargo test -p yasno-core`.");
}
