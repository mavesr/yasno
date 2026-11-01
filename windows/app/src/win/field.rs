//! Which field has the focus, asked through UI Automation on its own thread: a slow or
//! hung application must never delay the keyboard hook. Password fields are never edited.

use std::sync::mpsc::Receiver;

use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::UI::Accessibility::{CUIAutomation, IUIAutomation};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::WindowsAndMessaging::PostMessageW;

/// Answers each focus generation with WM_APP_FIELD(generation, is_password).
pub fn inspector(requests: Receiver<u64>, hwnd: usize, message: u32) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let automation: Option<IUIAutomation> = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok();
        while let Ok(mut generation) = requests.recv() {
            while let Ok(newer) = requests.try_recv() { generation = newer; }
            let password = automation.as_ref()
                .and_then(|a| a.GetFocusedElement().ok())
                .and_then(|e| e.CurrentIsPassword().ok())
                .map(|b| b.as_bool())
                .unwrap_or(false);
            PostMessageW(hwnd as HWND, message, generation as usize, password as isize);
        }
    }
}
