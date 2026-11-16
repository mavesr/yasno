//! Which field has the focus, asked through UI Automation on its own thread: a slow or
//! hung application must never delay the keyboard hook. Password fields are never edited.

use std::sync::mpsc::Receiver;

use serde_json::{json, Value};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::UI::Accessibility::{CUIAutomation, IUIAutomation, IUIAutomationElement};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::WindowsAndMessaging::PostMessageW;

/// A focus generation to answer; `describe`: diagnostics are on, describe the field too.
pub struct Request { pub generation: u64, pub describe: bool }

/// The answer, posted boxed as WM_APP_FIELD's lparam.
pub struct Field {
    pub generation: u64,
    pub password: bool,
    /// The field's names suggest a secret (a PIN, a token, a one-time code).
    pub secret: bool,
    pub description: Option<Value>,
}

/// Names that suggest a field for a secret, as on the Mac.
const SECRET_HINTS: &[&str] = &["secure", "pass", "secret", "token", "otp", "pin-code", "pincode", "credential", "cvv", "cvc"];

fn describe(element: &IUIAutomationElement, password: bool) -> (Value, bool) {
    unsafe {
        let text = |r: windows::core::Result<windows::core::BSTR>| r.map(|s| s.to_string()).unwrap_or_default();
        let class = text(element.CurrentClassName());
        let id = text(element.CurrentAutomationId());
        let framework = text(element.CurrentFrameworkId());
        let control = element.CurrentControlType().map(|t| t.0).unwrap_or(0);
        let enabled = element.CurrentIsEnabled().map(|b| b.as_bool()).unwrap_or(false);
        let names = format!("{class} {id}").to_lowercase();
        let secret = SECRET_HINTS.iter().any(|h| names.contains(h));
        // UIA control type ids: 50004 Edit, 50030 Document, 50033 Pane, 50003 ComboBox.
        (json!({"password": password, "secret_hint": secret, "class": class, "automation_id": id,
                "framework": framework, "control_type": control, "enabled": enabled}), secret)
    }
}

/// Answers each focus generation with WM_APP_FIELD(generation, Box<Field>).
pub fn inspector(requests: Receiver<Request>, hwnd: usize, message: u32) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let automation: Option<IUIAutomation> = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok();
        while let Ok(mut request) = requests.recv() {
            while let Ok(newer) = requests.try_recv() { request = newer; }
            let element = automation.as_ref().and_then(|a| a.GetFocusedElement().ok());
            let password = element.as_ref().and_then(|e| e.CurrentIsPassword().ok()).map(|b| b.as_bool()).unwrap_or(false);
            let (description, secret) = match (&element, request.describe) {
                (Some(e), true) => { let (d, s) = describe(e, password); (Some(d), s) }
                (None, true) => (Some(json!({"password": password, "automation": automation.is_some(), "focused_element": false})), false),
                _ => (None, false),
            };
            let field = Box::new(Field { generation: request.generation, password, secret, description });
            let raw = Box::into_raw(field);
            if PostMessageW(hwnd as HWND, message, 0, raw as isize) == 0 { drop(Box::from_raw(raw)); }
        }
    }
}
