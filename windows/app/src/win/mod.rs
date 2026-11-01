//! The Windows shell: one UI thread owns the keyboard and mouse hooks, the tray icon and
//! the typing session; a worker thread runs the detector so the hook never waits for it.
//!
//! The hook only records keys and posts messages. Windows silently removes a low-level
//! hook that answers too slowly, so no detection, no SendInput and no blocking call
//! happens inside a hook callback.

mod field;
mod input;
mod layouts;
mod settings;
mod spell;

use std::cell::RefCell;
use std::collections::HashSet;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Threading::{
    CreateMutexW, GetCurrentProcessId, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
    PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows_sys::Win32::UI::Accessibility::{SetWinEventHook, HWINEVENTHOOK};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
use windows_sys::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NIM_MODIFY, NOTIFYICONDATAW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use yasno_core::typing::{Check, Decision, Edit, Key, Typing};
use yasno_core::{Detector, KeyStroke, KeyboardLayout, ShiftTapGesture};

use input::Held;
use settings::Settings;

const WM_APP_DECISION: u32 = WM_APP + 1;
const WM_APP_TAP: u32 = WM_APP + 2;
const WM_APP_REPLAY: u32 = WM_APP + 3;
const WM_APP_TRAY: u32 = WM_APP + 4;
const WM_APP_FIELD: u32 = WM_APP + 5;
const TIMER_PAUSE: usize = 1;

const MENU_PAUSE: usize = 1;
const MENU_SPELLING: usize = 2;
const MENU_EXCLUDE: usize = 3;
const MENU_AUTOSTART: usize = 4;
const MENU_QUIT: usize = 9;

/// A word is checked as complete after typing stops this long (search fields).
const PAUSE: u32 = 600;
/// Keys typed during an edit are held at most this long.
const FLIGHT_LIMIT: Duration = Duration::from_millis(300);

struct Job {
    check: Check,
    layouts: Arc<Vec<KeyboardLayout>>,
    ignored: Arc<HashSet<String>>,
    preferred: Option<String>,
    correct_spelling: bool,
}

struct App {
    hwnd: HWND,
    hkls: Vec<usize>,
    layouts: Arc<Vec<KeyboardLayout>>,
    ui_detector: Detector,
    worker: Sender<Job>,
    settings: Settings,
    ignored: Arc<HashSet<String>>,
    typing: Typing,
    gesture: ShiftTapGesture,
    shifts_down: HashSet<u32>,
    ctrl: bool,
    alt: bool,
    win: bool,
    caps: bool,
    caps_down: bool,
    in_flight: Option<Instant>,
    held: Vec<Held>,
    /// The layout Yasno just asked the foreground window for, until it reports it.
    expected: Option<(usize, Instant)>,
    excluded: bool,
    /// The last application the user worked in, for the tray menu's exclude item.
    last_app: Option<String>,
    /// The focused field: which focus change it is, and whether it is a password field.
    /// Edits wait until UI Automation has answered for the current field.
    field_generation: u64,
    field_pending: bool,
    field_secure: bool,
    last_focus: (usize, i32, i32),
    inspector: Sender<u64>,
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
}

/// Runs `f` with the app unless it is already in use (a re-entrant callback).
fn with_app<R>(f: impl FnOnce(&mut App) -> R) -> Option<R> {
    APP.with(|cell| cell.try_borrow_mut().ok().and_then(|mut app| app.as_mut().map(f)))
}

fn wide(s: &str) -> Vec<u16> { s.encode_utf16().chain(Some(0)).collect() }

/// `yasno.exe --diagnose`: the layouts and spelling dictionaries Yasno sees, without
/// any user text, in a message box.
fn diagnose() {
    unsafe { let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED); }
    let detector = Detector::default();
    let mut text = String::from("Раскладки:\n");
    for (hkl, layout) in layouts::installed() {
        let langs: Vec<&str> = layout.languages.iter().map(|l| l.code()).collect();
        text += &format!("  {:X}  {}\n", hkl as usize, langs.join(", "));
    }
    let spelling: Vec<&str> = spell::WindowsLexicon::new().languages().iter().map(|l| l.code()).collect();
    text += &format!("Проверка орфографии Windows: {}\n", if spelling.is_empty() { "нет".to_string() } else { spelling.join(", ") });
    let words: Vec<String> = yasno_core::Language::ALL.iter().map(|&l| format!("{} {}", l.code(), detector.count(l))).collect();
    text += &format!("Словари: {}\n", words.join(", "));
    unsafe { MessageBoxW(std::ptr::null_mut(), wide(&text).as_ptr(), wide("Ясно — диагностика").as_ptr(), MB_OK); }
}

pub fn run() {
    if std::env::args().any(|a| a == "--diagnose") { diagnose(); return; }
    unsafe {
        let mutex = CreateMutexW(std::ptr::null(), 0, wide("Local\\YasnoKeyboardSwitcher").as_ptr());
        if GetLastError() == ERROR_ALREADY_EXISTS { CloseHandle(mutex); return; }

        let instance = GetModuleHandleW(std::ptr::null());
        let class = wide("YasnoTray");
        let wc = WNDCLASSW { lpfnWndProc: Some(window_proc), hInstance: instance, lpszClassName: class.as_ptr(),
                             ..std::mem::zeroed() };
        RegisterClassW(&wc);
        let hwnd = CreateWindowExW(0, class.as_ptr(), wide("Ясно").as_ptr(), 0, 0, 0, 0, 0,
                                   HWND_MESSAGE, std::ptr::null_mut(), instance, std::ptr::null());

        let (sender, receiver) = channel::<Job>();
        let target = hwnd as usize;
        std::thread::Builder::new().name("detector".into()).spawn(move || worker(receiver, target)).ok();
        let (inspector, requests) = channel::<u64>();
        std::thread::Builder::new().name("field".into())
            .spawn(move || field::inspector(requests, target, WM_APP_FIELD)).ok();

        let settings = Settings::load();
        let ignored = Arc::new(settings.ignored_words.iter().cloned().collect());
        let (hkls, layouts) = load_layouts();
        APP.with(|cell| *cell.borrow_mut() = Some(App {
            hwnd, hkls, layouts, ui_detector: Detector::default(), worker: sender, settings, ignored,
            typing: Typing::new(), gesture: ShiftTapGesture::new(), shifts_down: HashSet::new(),
            ctrl: false, alt: false, win: false, caps: GetKeyState(VK_CAPITAL as i32) & 1 != 0, caps_down: false,
            in_flight: None, held: Vec::new(), expected: None, excluded: false, last_app: None,
            field_generation: 0, field_pending: true, field_secure: false, last_focus: (0, 0, 0), inspector,
        }));

        add_tray_icon(hwnd);
        SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_proc), instance, 0);
        SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_proc), instance, 0);
        SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, std::ptr::null_mut(), Some(focus_proc), 0, 0, WINEVENT_OUTOFCONTEXT);
        SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS, std::ptr::null_mut(), Some(focus_proc), 0, 0, WINEVENT_OUTOFCONTEXT);
        focus_changed(GetForegroundWindow() as usize, 0, 0);

        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        remove_tray_icon(hwnd);
        CloseHandle(mutex);
    }
}

fn load_layouts() -> (Vec<usize>, Arc<Vec<KeyboardLayout>>) {
    let (hkls, layouts): (Vec<usize>, Vec<KeyboardLayout>) =
        layouts::installed().into_iter().map(|(h, l)| (h as usize, l)).unzip();
    (hkls, Arc::new(layouts))
}

fn worker(jobs: Receiver<Job>, hwnd: usize) {
    unsafe { let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED); }
    let detector = Detector::new(Arc::new(spell::WindowsLexicon::new()));
    // Load the dictionaries now, not on the first word.
    detector.rank("a", &[yasno_core::Language::English]);
    while let Ok(mut job) = jobs.recv() {
        // Only the newest word matters: older checks are already stale.
        while let Ok(newer) = jobs.try_recv() { job = newer; }
        let all: Vec<&KeyboardLayout> = job.layouts.iter().collect();
        let Some(request) = job.check.request(&all, &job.ignored, job.preferred.as_deref(), job.correct_spelling) else { continue };
        if !detector.may_correct(&request) { continue; }
        let Some(s) = detector.correction(&request, &job.check.context) else { continue };
        let decision = Box::new(Decision { version: job.check.version, replacement: s.replacement, target_id: s.target.id.clone() });
        unsafe { PostMessageW(hwnd as HWND, WM_APP_DECISION, 0, Box::into_raw(decision) as LPARAM); }
    }
}

fn foreground_hkl() -> usize {
    unsafe {
        let thread = GetWindowThreadProcessId(GetForegroundWindow(), std::ptr::null_mut());
        GetKeyboardLayout(thread) as usize
    }
}

impl App {
    fn current_layout(&mut self) -> Option<&KeyboardLayout> {
        let actual = foreground_hkl();
        let hkl = match self.expected {
            Some((h, _)) if h == actual => { self.expected = None; actual }
            Some((h, until)) if Instant::now() < until => h,
            _ => { self.expected = None; actual }
        };
        let index = self.hkls.iter().position(|&h| h == hkl)?;
        self.layouts.get(index)
    }

    fn send_check(&self, check: Check) {
        let _ = self.worker.send(Job { check, layouts: self.layouts.clone(), ignored: self.ignored.clone(),
                                       preferred: self.typing.preferred.clone(),
                                       correct_spelling: self.settings.correct_spelling });
    }

    fn feed(&mut self, key: Key) {
        let Some(layout) = self.current_layout().map(|l| l as *const KeyboardLayout) else {
            self.typing.reset();
            return;
        };
        // The layouts live in an Arc this App holds for as long as the call lasts.
        let layout = unsafe { &*layout };
        if let Some(check) = self.typing.key(key, layout) {
            self.send_check(check);
        }
        unsafe { SetTimer(self.hwnd, TIMER_PAUSE, PAUSE, None); }
    }

    /// Returns true when the key must not reach the application.
    fn on_key(&mut self, k: &KBDLLHOOKSTRUCT, down: bool) -> bool {
        match k.dwExtraInfo {
            input::MAGIC => return false,
            input::MAGIC_END => {
                if !down { self.in_flight = None; unsafe { PostMessageW(self.hwnd, WM_APP_REPLAY, 0, 0); } }
                return false;
            }
            _ => {}
        }
        let replayed = k.dwExtraInfo == input::MAGIC_REPLAY;
        let extended = k.flags & LLKHF_EXTENDED != 0;
        if !replayed {
            if let Some(started) = self.in_flight {
                if started.elapsed() < FLIGHT_LIMIT {
                    self.held.push(Held { vk: k.vkCode as u16, scan: k.scanCode as u16, up: !down, extended });
                    return true;
                }
                self.in_flight = None;
                unsafe { PostMessageW(self.hwnd, WM_APP_REPLAY, 0, 0); }
            }
        }
        let vk = k.vkCode as u16;
        match vk {
            VK_LCONTROL | VK_RCONTROL | VK_CONTROL => { self.ctrl = down; self.gesture.cancel(); return false; }
            VK_LMENU | VK_RMENU | VK_MENU => { self.alt = down; self.gesture.cancel(); return false; }
            VK_LWIN | VK_RWIN => { self.win = down; self.gesture.cancel(); return false; }
            _ => {}
        }
        if self.settings.paused || self.excluded { return false; }
        let time = k.time as f64 / 1000.0;
        if matches!(vk, VK_LSHIFT | VK_RSHIFT | VK_SHIFT) {
            let clean = !(self.ctrl || self.alt || self.win);
            if down {
                if self.shifts_down.insert(k.scanCode) { self.gesture.press(k.scanCode as u16, time, clean); }
            } else {
                self.shifts_down.remove(&k.scanCode);
                if self.shifts_down.is_empty() && self.gesture.release(k.scanCode as u16, time, clean) {
                    unsafe { PostMessageW(self.hwnd, WM_APP_TAP, 0, 0); }
                }
            }
            return false;
        }
        if !down {
            if vk == VK_CAPITAL { self.caps_down = false; }
            return false;
        }
        self.gesture.cancel();
        if vk == VK_CAPITAL {
            if !self.caps_down { self.caps = !self.caps; }
            self.caps_down = true;
            return false;
        }
        if self.ctrl || self.alt || self.win { self.feed(Key::Navigation); return false; }
        let key = match vk {
            VK_SPACE => Key::Space,
            VK_RETURN => Key::Enter,
            VK_TAB => Key::Tab,
            VK_BACK => Key::Backspace,
            VK_NUMLOCK | VK_SCROLL | VK_PAUSE | VK_SNAPSHOT => return false,
            _ if extended || (VK_F1..=VK_F24).contains(&vk) || vk == VK_ESCAPE || vk == VK_DELETE || vk == VK_INSERT => Key::Navigation,
            _ => Key::Char(KeyStroke { key: k.scanCode as u16, shift: !self.shifts_down.is_empty(), caps_lock: self.caps }),
        };
        self.feed(key);
        false
    }

    /// Erase and type in the focused field, then switch its layout.
    fn perform(&mut self, edit: Edit) -> Vec<INPUT> {
        if self.field_pending || self.field_secure { self.typing.reset(); return Vec::new(); }
        let inputs = if edit.deletions > 0 || !edit.insertion.is_empty() {
            self.in_flight = Some(Instant::now());
            input::edit(edit.deletions, &edit.insertion)
        } else { Vec::new() };
        if let Some(id) = edit.switch_to {
            if let Some(index) = self.layouts.iter().position(|l| l.id == id) {
                let hkl = self.hkls[index];
                unsafe { PostMessageW(GetForegroundWindow(), WM_INPUTLANGCHANGEREQUEST, 0, hkl as LPARAM); }
                self.expected = Some((hkl, Instant::now() + Duration::from_millis(700)));
            }
        }
        inputs
    }

    fn on_decision(&mut self, decision: &Decision) -> Vec<INPUT> {
        let all: Vec<&KeyboardLayout> = self.layouts.iter().collect();
        match self.typing.apply(decision, &all) { Some(edit) => self.perform(edit), None => Vec::new() }
    }

    fn on_tap(&mut self) -> Vec<INPUT> {
        let layouts = self.layouts.clone();
        let all: Vec<&KeyboardLayout> = layouts.iter().collect();
        let Some(current) = self.current_layout().map(|l| l.id.clone()) else { return Vec::new() };
        let Some(current) = layouts.iter().find(|l| l.id == current) else { return Vec::new() };
        match self.typing.shift_tap(&self.ui_detector, &all, current) { Some(edit) => self.perform(edit), None => Vec::new() }
    }

    fn on_focus(&mut self, hwnd: usize, object: i32, child: i32) {
        // Browsers repeat focus events for the same field; only a real change resets.
        if self.last_focus == (hwnd, object, child) { return; }
        self.last_focus = (hwnd, object, child);
        self.field_generation += 1;
        self.field_pending = true;
        let _ = self.inspector.send(self.field_generation);
        self.typing.reset();
        self.gesture.reset();
        let Some(name) = foreground_process() else { return };
        if name == own_process() { return; }
        self.excluded = self.settings.exclusions.iter().any(|e| *e == name);
        self.last_app = Some(name);
        if unsafe { GetKeyboardLayoutList(0, std::ptr::null_mut()) } as usize != self.hkls.len() {
            let (hkls, layouts) = load_layouts();
            self.hkls = hkls;
            self.layouts = layouts;
        }
    }
}

fn process_name(pid: u32) -> Option<String> {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() { return None; }
        let mut buf = [0u16; 1024];
        let mut size = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, buf.as_mut_ptr(), &mut size);
        CloseHandle(process);
        if ok == 0 { return None; }
        let path = String::from_utf16_lossy(&buf[..size as usize]);
        path.rsplit('\\').next().map(|n| n.to_lowercase())
    }
}

fn foreground_process() -> Option<String> {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(GetForegroundWindow(), &mut pid); }
    process_name(pid)
}

fn own_process() -> String { process_name(unsafe { GetCurrentProcessId() }).unwrap_or_default() }

fn focus_changed(hwnd: usize, object: i32, child: i32) { with_app(|app| app.on_focus(hwnd, object, child)); }

unsafe extern "system" fn keyboard_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let k = &*(lparam as *const KBDLLHOOKSTRUCT);
        let down = wparam == WM_KEYDOWN as WPARAM || wparam == WM_SYSKEYDOWN as WPARAM;
        if with_app(|app| app.on_key(k, down)) == Some(true) { return 1; }
    }
    CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam)
}

unsafe extern "system" fn mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 && matches!(wparam as u32, WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN | WM_XBUTTONDOWN) {
        with_app(|app| { app.gesture.cancel(); app.typing.reset(); });
    }
    CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam)
}

unsafe extern "system" fn focus_proc(_: HWINEVENTHOOK, _: u32, hwnd: HWND, object: i32, child: i32, _: u32, _: u32) {
    focus_changed(hwnd as usize, object, child);
}

unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_APP_DECISION => {
            let decision = Box::from_raw(lparam as *mut Decision);
            let inputs = with_app(|app| app.on_decision(&decision)).unwrap_or_default();
            input::send(&inputs);
            0
        }
        WM_APP_TAP => {
            let inputs = with_app(|app| app.on_tap()).unwrap_or_default();
            input::send(&inputs);
            0
        }
        WM_APP_FIELD => {
            with_app(|app| if wparam as u64 == app.field_generation {
                app.field_pending = false;
                app.field_secure = lparam != 0;
                // Nothing typed into a password field stays in memory.
                if app.field_secure { app.typing.reset(); }
            });
            0
        }
        WM_APP_REPLAY => {
            let held = with_app(|app| std::mem::take(&mut app.held)).unwrap_or_default();
            input::send(&input::replay(&held));
            0
        }
        WM_TIMER if wparam == TIMER_PAUSE => {
            KillTimer(hwnd, TIMER_PAUSE);
            with_app(|app| if let Some(check) = app.typing.pause_check() { app.send_check(check); });
            0
        }
        WM_APP_TRAY => {
            let event = (lparam & 0xffff) as u32;
            if event == WM_RBUTTONUP || event == WM_LBUTTONUP { show_menu(hwnd); }
            0
        }
        WM_COMMAND => {
            on_menu(hwnd, wparam & 0xffff);
            0
        }
        WM_DESTROY => { PostQuitMessage(0); 0 }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn tray_data(hwnd: HWND) -> NOTIFYICONDATAW {
    let mut data: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
    data.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
    data.hWnd = hwnd;
    data.uID = 1;
    data
}

fn tip(paused: bool) -> [u16; 128] {
    let text = if paused { "Ясно — пауза" } else { "Ясно" };
    let mut tip = [0u16; 128];
    for (i, c) in text.encode_utf16().take(127).enumerate() { tip[i] = c; }
    tip
}

fn add_tray_icon(hwnd: HWND) {
    let mut data = tray_data(hwnd);
    data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    data.uCallbackMessage = WM_APP_TRAY;
    unsafe {
        let instance = GetModuleHandleW(std::ptr::null());
        // MAKEINTRESOURCE(1): the icon in res/yasno.rc.
        #[allow(clippy::manual_dangling_ptr)]
        { data.hIcon = LoadIconW(instance, 1 as *const u16); }
        if data.hIcon.is_null() { data.hIcon = LoadIconW(std::ptr::null_mut(), IDI_APPLICATION); }
        data.szTip = tip(with_app(|a| a.settings.paused).unwrap_or(false));
        Shell_NotifyIconW(NIM_ADD, &data);
    }
}

fn update_tray_tip(hwnd: HWND, paused: bool) {
    let mut data = tray_data(hwnd);
    data.uFlags = NIF_TIP;
    data.szTip = tip(paused);
    unsafe { Shell_NotifyIconW(NIM_MODIFY, &data); }
}

fn remove_tray_icon(hwnd: HWND) {
    let data = tray_data(hwnd);
    unsafe { Shell_NotifyIconW(NIM_DELETE, &data); }
}

fn show_menu(hwnd: HWND) {
    let Some((paused, spelling, app, excluded)) = with_app(|a| {
        let app = a.last_app.clone();
        let excluded = app.as_ref().is_some_and(|n| a.settings.exclusions.contains(n));
        (a.settings.paused, a.settings.correct_spelling, app, excluded)
    }) else { return };
    unsafe {
        let menu = CreatePopupMenu();
        let check = |on: bool| if on { MF_CHECKED } else { MF_UNCHECKED };
        AppendMenuW(menu, MF_STRING | check(paused), MENU_PAUSE, wide("Пауза").as_ptr());
        AppendMenuW(menu, MF_STRING | check(spelling), MENU_SPELLING, wide("Исправлять опечатки").as_ptr());
        if let Some(app) = app {
            let label = if excluded { format!("Не исключать {app}") } else { format!("Исключить {app}") };
            AppendMenuW(menu, MF_STRING, MENU_EXCLUDE, wide(&label).as_ptr());
        }
        AppendMenuW(menu, MF_STRING | check(settings::autostart()), MENU_AUTOSTART, wide("Запускать при входе в Windows").as_ptr());
        AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
        AppendMenuW(menu, MF_STRING, MENU_QUIT, wide("Выйти").as_ptr());
        let mut point = POINT { x: 0, y: 0 };
        GetCursorPos(&mut point);
        // The menu closes when the user clicks elsewhere only if its owner is foreground.
        SetForegroundWindow(hwnd);
        TrackPopupMenu(menu, TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd, std::ptr::null());
        DestroyMenu(menu);
    }
}

fn on_menu(hwnd: HWND, id: usize) {
    match id {
        MENU_PAUSE => {
            let paused = with_app(|a| { a.settings.paused = !a.settings.paused; a.typing.reset(); a.settings.save(); a.settings.paused });
            if let Some(p) = paused { update_tray_tip(hwnd, p); }
        }
        MENU_SPELLING => { with_app(|a| { a.settings.correct_spelling = !a.settings.correct_spelling; a.settings.save(); }); }
        MENU_EXCLUDE => {
            with_app(|a| {
                let Some(app) = a.last_app.clone() else { return };
                if let Some(i) = a.settings.exclusions.iter().position(|e| *e == app) { a.settings.exclusions.remove(i); }
                else { a.settings.exclusions.push(app); }
                a.settings.save();
            });
        }
        MENU_AUTOSTART => settings::set_autostart(!settings::autostart()),
        MENU_QUIT => unsafe { DestroyWindow(hwnd); },
        _ => {}
    }
}
