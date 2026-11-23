//! `yasno.exe --self-test <report>`: the whole Windows path on a real Windows desktop, as CI
//! runs it. Yasno starts as usual (hooks, engine, detector, Windows layouts), a window with
//! an edit control takes the focus, and another thread types into it with SendInput the
//! way a keyboard does (scan codes, Shift pressed and released, keys overlapping when fast).
//! Each case compares the text in the control with what the user meant.

use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
use std::time::Duration;

use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
use windows_sys::Win32::UI::WindowsAndMessaging::*;
use yasno_core::layouts;

use super::{wide, with_app};

pub static READY: AtomicBool = AtomicBool::new(false);
static EDIT: AtomicIsize = AtomicIsize::new(0);
static PASSWORD: AtomicIsize = AtomicIsize::new(0);
static WINDOW: AtomicIsize = AtomicIsize::new(0);
const WM_PREPARE: u32 = WM_APP + 40;
const WM_STATE: u32 = WM_APP + 41;
/// wparam: 1 start diagnostics, 0 stop them, 2 focus the password field, 3 the plain one.
const WM_DIAGNOSE: u32 = WM_APP + 42;
static STATE: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());

const US: &str = "00000409";
const RU: &str = "00000419";
const UK: &str = "00000422";

pub fn load_layouts() {
    for id in [US, RU, UK] {
        unsafe { LoadKeyboardLayoutW(wide(id).as_ptr(), KLF_SUBSTITUTE_OK); }
    }
}

pub fn create_window() {
    unsafe {
        let instance = GetModuleHandleW(std::ptr::null());
        let class = wide("YasnoSelfTest");
        let wc = WNDCLASSW { lpfnWndProc: Some(proc_), hInstance: instance, lpszClassName: class.as_ptr(), ..std::mem::zeroed() };
        RegisterClassW(&wc);
        let hwnd = CreateWindowExW(WS_EX_TOPMOST, class.as_ptr(), wide("Ясно self-test").as_ptr(), WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                   100, 100, 700, 340, std::ptr::null_mut(), std::ptr::null_mut(), instance, std::ptr::null());
        let edit = CreateWindowExW(0, wide("EDIT").as_ptr(), wide("").as_ptr(),
                                   WS_CHILD | WS_VISIBLE | WS_BORDER | (ES_MULTILINE | ES_AUTOVSCROLL) as u32,
                                   10, 10, 660, 240, hwnd, std::ptr::null_mut(), instance, std::ptr::null());
        let password = CreateWindowExW(0, wide("EDIT").as_ptr(), wide("").as_ptr(),
                                       WS_CHILD | WS_VISIBLE | WS_BORDER | (ES_PASSWORD | ES_AUTOHSCROLL) as u32,
                                       10, 260, 660, 28, hwnd, std::ptr::null_mut(), instance, std::ptr::null());
        PASSWORD.store(password as isize, Ordering::SeqCst);
        WINDOW.store(hwnd as isize, Ordering::SeqCst);
        EDIT.store(edit as isize, Ordering::SeqCst);
        SetForegroundWindow(hwnd);
        SetFocus(edit);
    }
}

fn hkl_of(id: &str) -> HKL {
    let lang = u32::from_str_radix(id, 16).unwrap_or(0x409) & 0xffff;
    unsafe {
        let n = GetKeyboardLayoutList(0, std::ptr::null_mut());
        let mut list: Vec<HKL> = vec![std::ptr::null_mut(); n.max(0) as usize];
        GetKeyboardLayoutList(n, list.as_mut_ptr());
        list.into_iter().find(|h| (*h as usize as u32 & 0xffff) == lang).unwrap_or(std::ptr::null_mut())
    }
}

unsafe extern "system" fn proc_(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_PREPARE => {
            // Empty field, the case's layout, nothing remembered from the last case.
            // wparam 1: automatic switching off for this case (not saved in the settings).
            let edit = EDIT.load(Ordering::SeqCst) as HWND;
            SetWindowTextW(edit, wide("").as_ptr());
            SetForegroundWindow(hwnd);
            SetFocus(edit);
            ActivateKeyboardLayout(lparam as HKL, 0);
            with_app(|a| { a.engine.caret_moved(); a.engine.set_automatic(wparam != 1); a.engine.typing.preferred = Some(a.engine.layouts().iter()
                .find(|l| l.id.ends_with(&format!("{:04X}", 0x419))).map(|l| l.id.clone()).unwrap_or_default()); });
            0
        }
        WM_DIAGNOSE => {
            match wparam {
                1 => { with_app(|a| {
                    let versions = serde_json::json!({"app": super::update::VERSION, "self_test": true});
                    let session = a.session();
                    let _ = a.diagnostics.send(super::diagnostics::Command::Start { versions, session });
                }); }
                0 => { with_app(|a| { let _ = a.diagnostics.send(super::diagnostics::Command::Stop { send: false, why: "self-test" }); }); }
                2 => { SetFocus(PASSWORD.load(Ordering::SeqCst) as HWND); }
                _ => { SetFocus(EDIT.load(Ordering::SeqCst) as HWND); }
            }
            0
        }
        WM_STATE => {
            let state = with_app(|a| format!("status={:?} monitoring={} corrections={} detail={:?} diagnostics={}",
                                             a.status(), a.monitoring(), a.corrections(), a.detail,
                                             a.diagnostic.enabled)).unwrap_or_default();
            if let Ok(mut s) = STATE.lock() { *s = state; }
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn key(scan: u16, up: bool) -> INPUT {
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT {
        wVk: 0, wScan: scan, dwFlags: KEYEVENTF_SCANCODE | if up { KEYEVENTF_KEYUP } else { 0 }, time: 0, dwExtraInfo: 0 } } }
}

fn press(inputs: &[INPUT], gap: u64) {
    for i in inputs {
        unsafe { SendInput(1, i, std::mem::size_of::<INPUT>() as i32); }
        std::thread::sleep(Duration::from_millis(gap));
    }
}

/// Physical keys for text on the US layout: ' ' Space, '⇧' a Shift tap, '\n' Enter.
fn strokes(text: &str, overlap: bool) -> Vec<INPUT> {
    let us = layouts::us();
    let mut out = Vec::new();
    let mut pending: Option<INPUT> = None;
    for c in text.chars() {
        let (scan, shift) = match c {
            ' ' => (0x39, false),
            '\n' => (0x1C, false),
            '⇧' => {
                if let Some(p) = pending.take() { out.push(p); }
                out.push(key(0x2A, false));
                out.push(key(0x2A, true));
                continue;
            }
            _ => { let s = us.stroke(c).expect("US key"); (s.key, s.shift) }
        };
        if shift {
            if let Some(p) = pending.take() { out.push(p); }
            out.extend([key(0x2A, false), key(scan, false), key(scan, true), key(0x2A, true)]);
            continue;
        }
        out.push(key(scan, false));
        if let Some(p) = pending.take() { out.push(p); }
        if overlap { pending = Some(key(scan, true)); } else { out.push(key(scan, true)); }
    }
    if let Some(p) = pending { out.push(p); }
    out
}

fn text() -> String {
    let edit = EDIT.load(Ordering::SeqCst) as HWND;
    let mut buf = vec![0u16; 4096];
    let n = unsafe { SendMessageW(edit, WM_GETTEXT, buf.len(), buf.as_mut_ptr() as LPARAM) } as usize;
    String::from_utf16_lossy(&buf[..n])
}

struct Case { name: &'static str, start: &'static str, keys: String, expected: String, manual: bool }

fn cases() -> Vec<Case> {
    let (us, ru, uk) = (layouts::us(), layouts::russian(), layouts::ukrainian());
    let mut v = vec![
        Case { name: "ru on US", start: US, keys: "ghbdtn rfr ltkf ".into(), expected: "привет как дела ".into(), manual: false },
        Case { name: "en on RU", start: RU, keys: "hello world ".into(), expected: "hello world ".into(), manual: false },
        Case { name: "valid en stays", start: US, keys: "hello world ".into(), expected: "hello world ".into(), manual: false },
        Case { name: "shift tap converts", start: US, keys: "ytn⇧".into(), expected: "нет".into(), manual: false },
        Case { name: "shift tap undoes", start: US, keys: "ghbdtn ⇧".into(), expected: "ghbdtn ".into(), manual: false },
        // Automatic switching off: words stay as typed, a short Shift tap still switches one.
        Case { name: "auto off stays", start: US, keys: "ghbdtn rfr ytn ".into(), expected: "ghbdtn rfr ytn ".into(), manual: true },
        Case { name: "auto off shift", start: US, keys: "ghbdtn⇧ vbh ".into(), expected: "привет мир ".into(), manual: true },
    ];
    for (meant, own, start) in [("Привет, мир! Как твои дела? Всё хорошо. ", &ru, US), ("сегодня хорошая погода ", &ru, US),
                                ("дякую дуже гарно ", &uk, US), ("hello world and some more ", &us, RU)] {
        let keys = own.convert(meant, &us).unwrap();
        v.push(Case { name: "sentence", start, keys, expected: meant.to_string(), manual: false });
    }
    v
}

/// Runs on its own thread while the UI thread runs Yasno. Returns the report and success.
pub fn drive() -> (String, bool) {
    for _ in 0..200 { if READY.load(Ordering::SeqCst) { break; } std::thread::sleep(Duration::from_millis(100)); }
    let window = WINDOW.load(Ordering::SeqCst) as HWND;
    let mut report = String::new();
    let mut ok = true;
    let layouts_seen: Vec<String> = with_layouts();
    report += &format!("layouts: {}\n", layouts_seen.join(" "));
    for case in cases() {
        // Slow typing, fast typing, fast with overlapping keys.
        for (gap, overlap, label) in [(60u64, false, "slow"), (8, false, "fast"), (4, true, "overlap")] {
            unsafe { SendMessageW(window, WM_PREPARE, case.manual as WPARAM, hkl_of(case.start) as LPARAM); }
            std::thread::sleep(Duration::from_millis(400));
            press(&strokes(&case.keys, overlap), gap);
            std::thread::sleep(Duration::from_millis(1500));
            let got = text();
            let pass = got == case.expected;
            if !pass {
                unsafe { SendMessageW(window, WM_STATE, 0, 0); }
                report += &format!("     {}\n", STATE.lock().map(|s| s.clone()).unwrap_or_default());
            }
            ok &= pass;
            report += &format!("{} {:<20} {:<8} {:?} -> {:?}{}\n", if pass { "PASS" } else { "FAIL" }, case.name, label,
                               case.keys, got, if pass { String::new() } else { format!(" (expected {:?})", case.expected) });
        }
    }
    let (diagnostics, pass) = diagnostics_case(window);
    report += &diagnostics;
    ok &= pass;
    (report, ok)
}

fn state(window: HWND) -> String {
    unsafe { SendMessageW(window, WM_STATE, 0, 0); }
    STATE.lock().map(|s| s.clone()).unwrap_or_default()
}

fn wait_for(window: HWND, diagnostics: bool) -> bool {
    let want = format!("diagnostics={diagnostics}");
    for _ in 0..50 {
        if state(window).ends_with(&want) { return true; }
        std::thread::sleep(Duration::from_millis(100));
    }
    false
}

/// A diagnostic session on this desktop: a word in the plain field is recorded with what
/// Yasno did, nothing typed into the password field is, and the journal is closed and queued.
fn diagnostics_case(window: HWND) -> (String, bool) {
    let mut report = String::new();
    let mut check = |name: &str, pass: bool, detail: String| {
        report += &format!("{} diagnostics: {name}{}\n", if pass { "PASS" } else { "FAIL" }, if pass { String::new() } else { format!(" ({detail})") });
        pass
    };
    let mut ok = check("token sealed for this user (DPAPI)", super::diagnostics::dpapi_works(), "CryptProtectData".into());
    let queue = super::diagnostics::queue_folder();
    let before: Vec<std::path::PathBuf> = std::fs::read_dir(&queue).into_iter().flatten().flatten().map(|e| e.path()).collect();
    unsafe { SendMessageW(window, WM_PREPARE, 0, hkl_of(US) as LPARAM); }
    unsafe { SendMessageW(window, WM_DIAGNOSE, 1, 0); }
    ok &= check("session starts", wait_for(window, true), state(window));
    std::thread::sleep(Duration::from_millis(600));
    press(&strokes("ghbdtn hello ", false), 40);
    std::thread::sleep(Duration::from_millis(1500));
    let typed = text();
    unsafe { SendMessageW(window, WM_DIAGNOSE, 2, 0); }
    std::thread::sleep(Duration::from_millis(800));
    press(&strokes("zxcvbn ", false), 40);
    std::thread::sleep(Duration::from_millis(800));
    unsafe { SendMessageW(window, WM_DIAGNOSE, 3, 0); }
    std::thread::sleep(Duration::from_millis(300));
    unsafe { SendMessageW(window, WM_DIAGNOSE, 0, 0); }
    ok &= check("session stops", wait_for(window, false), state(window));
    std::thread::sleep(Duration::from_millis(500));
    let journal = std::fs::read_dir(&queue).into_iter().flatten().flatten().map(|e| e.path())
        .find(|p| !before.contains(p) && p.extension().is_some_and(|e| e == "jsonl"));
    let Some(journal) = journal else {
        ok &= check("journal queued", false, format!("nothing new in {}", queue.display()));
        return (report, ok);
    };
    let content = std::fs::read_to_string(&journal).unwrap_or_default();
    let rows: Vec<serde_json::Value> = content.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
    let has = |event: &str, f: &dyn Fn(&serde_json::Value) -> bool| rows.iter().any(|r| r["event"] == event && f(r));
    ok &= check("typed text corrected", typed == "привет hello ", format!("{typed:?}"));
    ok &= check("meta rows", rows.first().is_some_and(|r| r["platform"] == "windows")
                && rows.last().is_some_and(|r| r["closed_reason"] == "self-test"), format!("{} rows", rows.len()));
    ok &= check("session event", has("session", &|r| r["layouts"].is_array()), String::new());
    ok &= check("word recorded", has("word", &|r| r["text"] == "привет"), String::new());
    ok &= check("edit recorded", has("edit", &|r| r["target"].as_str().is_some_and(|t| t.ends_with("0419"))), String::new());
    ok &= check("password field seen", has("field", &|r| r["password"] == true), String::new());
    let leaked = ["zxcvbn", "ячсмить"].iter().any(|w| content.contains(w));
    ok &= check("password text not recorded", !leaked, "typed text found in the journal".into());
    report += &format!("     journal: {} rows, {} bytes\n", rows.len(), content.len());
    if !ok { for r in &rows { report += &format!("     {r}\n"); } }
    let _ = std::fs::remove_file(&journal);
    (report, ok)
}

fn with_layouts() -> Vec<String> {
    super::layouts::installed().iter().map(|(h, l)| format!("{:X}={}", *h as usize, l.name)).collect()
}
