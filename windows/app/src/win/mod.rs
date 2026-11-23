//! The Windows shell around the engine in yasno-core. One UI thread owns the keyboard and
//! mouse hooks, the tray icon, the settings window and the engine; a worker thread runs the
//! detector so the hook never waits for it.
//!
//! The hook only asks the engine what to do with a key and posts the rest to itself:
//! Windows removes a low-level hook that answers too slowly, so nothing slow happens there.

mod diagnostics;
mod field;
mod input;
mod install;
mod layouts;
mod selftest;
mod settings;
mod spell;
mod update;
mod window;

use std::cell::RefCell;
use std::collections::HashSet;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;

use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HANDLE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows_sys::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Threading::{
    CreateMutexW, GetCurrentProcess, GetCurrentProcessId, OpenProcess, OpenProcessToken, QueryFullProcessImageNameW,
    WaitForSingleObject, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows_sys::Win32::UI::Accessibility::{SetWinEventHook, HWINEVENTHOOK};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
use windows_sys::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_TIP, NIIF_INFO, NIM_ADD, NIM_DELETE, NIM_MODIFY, NOTIFYICONDATAW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use serde_json::{json, Map, Value};
use yasno_core::diagnostics::{State as DiagnosticState, SECRET};
use yasno_core::engine::{Answer, Context, Effect, Engine, RawKey, Timer};
use yasno_core::typing::Check;
use yasno_core::{Detector, KeyboardLayout};

use settings::Settings;

const WM_APP_FLUSH: u32 = WM_APP + 1;
const WM_APP_ANSWER: u32 = WM_APP + 2;
const WM_APP_TRAY: u32 = WM_APP + 4;
const WM_APP_FIELD: u32 = WM_APP + 5;
const WM_APP_READY: u32 = WM_APP + 6;
const WM_APP_SHOW: u32 = WM_APP + 7;
const WM_APP_UPDATE: u32 = WM_APP + 8;
const WM_APP_QUIT: u32 = WM_APP + 9;
const WM_APP_DIAGNOSTICS: u32 = WM_APP + 10;
const TIMER_PAUSE: usize = 1;
const TIMER_WATCHDOG: usize = 2;
const TIMER_UPDATE: usize = 3;
const TIMER_REFRESH: usize = 4;

const MENU_OPEN: usize = 1;
const MENU_PAUSE: usize = 2;
const MENU_EXCLUDE: usize = 3;
const MENU_UPDATE: usize = 4;
const MENU_DIAGNOSTICS: usize = 5;
const MENU_DIAGNOSTIC_SETTINGS: usize = 6;
const MENU_AUTOMATIC: usize = 7;
const MENU_QUIT: usize = 9;

const CLASS: &str = "YasnoTray";

struct Job {
    check: Check,
    gated: bool,
    layouts: Arc<Vec<KeyboardLayout>>,
    ignored: Arc<HashSet<String>>,
    preferred: Option<String>,
    correct_spelling: bool,
}

pub struct App {
    hwnd: HWND,
    hkls: Vec<usize>,
    /// Every layout Windows had at the last check, supported or not.
    system_hkls: Vec<usize>,
    engine: Engine,
    worker: Sender<Job>,
    pub settings: Settings,
    ignored: Arc<HashSet<String>>,
    outbox: Vec<Effect>,
    flush_posted: bool,
    target: Option<layouts::Target>,
    excluded: bool,
    elevated: bool,
    /// The application the user worked in last, for the exclude command.
    pub last_app: Option<String>,
    field_generation: u64,
    last_focus: (usize, i32, i32),
    inspector: Sender<field::Request>,
    /// The diagnostic service, on its own thread, and its last reported state.
    diagnostics: Sender<diagnostics::Command>,
    pub diagnostic: DiagnosticState,
    pub update_busy: bool,
    /// Automatic checks in a row that could not reach GitHub.
    update_retries: u8,
    pub update_message: String,
    pub detail: String,
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
}

/// Runs `f` with the app unless it is already in use (a re-entrant callback).
pub fn with_app<R>(f: impl FnOnce(&mut App) -> R) -> Option<R> {
    APP.with(|cell| cell.try_borrow_mut().ok().and_then(|mut app| app.as_mut().map(f)))
}

pub fn wide(s: &str) -> Vec<u16> { s.encode_utf16().chain(Some(0)).collect() }

/// `yasno.exe --diagnose`: the layouts and spelling dictionaries Yasno sees, without
/// any user text, in a message box.
fn diagnose() {
    unsafe { let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED); }
    let detector = Detector::default();
    let mut text = format!("Ясно {}\nРаскладки:\n", update::VERSION);
    for (hkl, layout) in layouts::installed() {
        let langs: Vec<&str> = layout.languages.iter().map(|l| l.code()).collect();
        text += &format!("  {:X}  {}\n", hkl as usize, langs.join(", "));
    }
    if let Some(t) = layouts::foreground() { text += &format!("Сейчас: {:X}\n", layouts::current(t) as usize); }
    let spelling: Vec<&str> = spell::WindowsLexicon::new().languages().iter().map(|l| l.code()).collect();
    text += &format!("Проверка орфографии Windows: {}\n", if spelling.is_empty() { "нет".to_string() } else { spelling.join(", ") });
    let words: Vec<String> = yasno_core::Language::ALL.iter().map(|&l| format!("{} {}", l.code(), detector.count(l))).collect();
    text += &format!("Словари: {}\n", words.join(", "));
    text += &format!("Папка: {}\n", std::env::current_exe().map(|p| p.display().to_string()).unwrap_or_default());
    unsafe { MessageBoxW(std::ptr::null_mut(), wide(&text).as_ptr(), wide("Ясно — диагностика").as_ptr(), MB_OK); }
}

fn running_instance() -> HWND {
    unsafe { FindWindowExW(HWND_MESSAGE, std::ptr::null_mut(), wide(CLASS).as_ptr(), std::ptr::null()) }
}

fn start(exe: &std::path::Path, args: &[&str]) -> bool {
    std::process::Command::new(exe).args(args).spawn().is_ok()
}

pub fn run() {
    let args: Vec<String> = std::env::args().collect();
    let has = |a: &str| args.iter().any(|x| x == a);
    if has("--diagnose") { diagnose(); return; }
    if let Some(i) = args.iter().position(|a| a == "--self-test") {
        let report = args.get(i + 1).cloned().unwrap_or_else(|| "yasno-self-test.txt".into());
        selftest::load_layouts();
        unsafe { main_loop(std::ptr::null_mut(), false, Some(report)); }
        return;
    }
    update::clean_up();
    // A copy started from Downloads installs itself and hands over to the installed one.
    if !has("--portable") && !install::is_installed_copy() {
        match install::install() {
            Ok(exe) => {
                settings::set_autostart_for(&exe);
                let old = running_instance();
                if !old.is_null() { unsafe { PostMessageW(old, WM_APP_QUIT, 0, 0); } }
                if start(&exe, &["--updated"]) { return; }
            }
            Err(e) => unsafe {
                MessageBoxW(std::ptr::null_mut(), wide(&format!("Не удалось установить Ясно: {e}\nЯсно запустится отсюда.")).as_ptr(),
                            wide("Ясно").as_ptr(), MB_OK | MB_ICONWARNING);
            },
        }
    }
    unsafe {
        let mutex = CreateMutexW(std::ptr::null(), 1, wide("Local\\YasnoKeyboardSwitcher").as_ptr());
        if GetLastError() == ERROR_ALREADY_EXISTS {
            if has("--updated") {
                // The previous version is quitting: wait until it has.
                let r = WaitForSingleObject(mutex, 20_000);
                if r != 0 && r != 0x80 { CloseHandle(mutex); return; }
            } else {
                let other = running_instance();
                if !other.is_null() { PostMessageW(other, WM_APP_SHOW, 0, 0); }
                CloseHandle(mutex);
                return;
            }
        }
        main_loop(mutex, !has("--background"), None);
    }
}

unsafe fn main_loop(mutex: HANDLE, show_window: bool, self_test: Option<String>) {
    let instance = GetModuleHandleW(std::ptr::null());
    let class = wide(CLASS);
    let wc = WNDCLASSW { lpfnWndProc: Some(window_proc), hInstance: instance, lpszClassName: class.as_ptr(), ..std::mem::zeroed() };
    RegisterClassW(&wc);
    let hwnd = CreateWindowExW(0, class.as_ptr(), wide("Ясно").as_ptr(), 0, 0, 0, 0, 0,
                               HWND_MESSAGE, std::ptr::null_mut(), instance, std::ptr::null());

    let (sender, receiver) = channel::<Job>();
    let target = hwnd as usize;
    std::thread::Builder::new().name("detector".into()).spawn(move || worker(receiver, target)).ok();
    let (inspector, requests) = channel::<field::Request>();
    std::thread::Builder::new().name("field".into())
        .spawn(move || field::inspector(requests, target, WM_APP_FIELD)).ok();

    let settings = Settings::load();
    let ignored = Arc::new(settings.ignored_words.iter().cloned().collect());
    let diagnostic = DiagnosticState { repo: settings.diagnostic_repo.clone(), ..DiagnosticState::default() };
    let diagnostic_service = diagnostics::spawn(target, WM_APP_DIAGNOSTICS, settings.diagnostic_repo.clone());
    let (hkls, layouts) = load_layouts();
    let mut engine = Engine::new(layouts);
    engine.set_ready(false);
    engine.set_automatic(settings.automatic_switching);
    engine.set_caps_lock(GetKeyState(VK_CAPITAL as i32) & 1 != 0);
    engine.typing.preferred = settings.preferred.clone();
    APP.with(|cell| *cell.borrow_mut() = Some(App {
        hwnd, hkls, system_hkls: layouts::system_list().into_iter().map(|h| h as usize).collect(), engine, worker: sender, settings, ignored, outbox: Vec::new(), flush_posted: false, target: None,
        excluded: false, elevated: false, last_app: None, field_generation: 0, last_focus: (0, 0, 0), inspector,
        update_busy: false, update_retries: 0, update_message: String::new(), detail: String::new(), diagnostics: diagnostic_service, diagnostic,
    }));

    add_tray_icon(hwnd);
    SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_proc), instance, 0);
    SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_proc), instance, 0);
    SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, std::ptr::null_mut(), Some(focus_proc), 0, 0, WINEVENT_OUTOFCONTEXT);
    SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS, std::ptr::null_mut(), Some(focus_proc), 0, 0, WINEVENT_OUTOFCONTEXT);
    focus_changed(GetForegroundWindow() as usize, 0, 0);
    SetTimer(hwnd, TIMER_REFRESH, 5000, None);
    schedule_update(hwnd);
    if show_window { window::show(); }
    if let Some(path) = self_test {
        SELF_TEST.store(true, std::sync::atomic::Ordering::SeqCst);
        selftest::create_window();
        let target = hwnd as usize;
        std::thread::spawn(move || {
            let (report, ok) = selftest::drive();
            let _ = std::fs::write(&path, &report);
            SELF_TEST_FAILED.store(!ok, std::sync::atomic::Ordering::SeqCst);
            PostMessageW(target as HWND, WM_APP_QUIT, 0, 0);
        });
    }

    let mut msg: MSG = std::mem::zeroed();
    while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
        if !window::dialog_message(&msg) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    remove_tray_icon(hwnd);
    // An open diagnostic session is closed and kept, to be sent another time.
    if let Some(service) = with_app(|a| a.diagnostics.clone()) { diagnostics::shutdown(&service); }
    if !mutex.is_null() { CloseHandle(mutex); }
    if SELF_TEST_FAILED.load(std::sync::atomic::Ordering::SeqCst) { std::process::exit(1); }
}

static SELF_TEST_FAILED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static SELF_TEST: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn load_layouts() -> (Vec<usize>, Arc<Vec<KeyboardLayout>>) {
    let (hkls, layouts): (Vec<usize>, Vec<KeyboardLayout>) =
        layouts::installed().into_iter().map(|(h, l)| (h as usize, l)).unzip();
    (hkls, Arc::new(layouts))
}

fn worker(jobs: Receiver<Job>, hwnd: usize) {
    unsafe { let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED); }
    let detector = Detector::new(Arc::new(spell::WindowsLexicon::new()));
    // Load the dictionaries now, not on the first word; until then nothing waits for them.
    detector.rank("a", &[yasno_core::Language::English]);
    unsafe { PostMessageW(hwnd as HWND, WM_APP_READY, 0, 0); }
    while let Ok(first) = jobs.recv() {
        let mut batch = vec![first];
        while let Ok(more) = jobs.try_recv() { batch.push(more); }
        // Every held check is answered (input waits for it); of the others only the newest matters,
        // and none that a held check after it overtakes: the engine ignores that answer anyway, and
        // computing it first kept the keys after Space waiting for a whole extra check.
        let last_gated = batch.iter().rposition(|j| j.gated);
        let newest_live = batch.iter().rposition(|j| !j.gated).filter(|&i| last_gated.is_none_or(|g| i > g));
        for (i, job) in batch.into_iter().enumerate() {
            if !job.gated && Some(i) != newest_live { continue; }
            // A panic in one check must not kill the thread: every later word would then wait
            // for the watchdog and stay uncorrected until Ясно is restarted.
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let all: Vec<&KeyboardLayout> = job.layouts.iter().collect();
                match job.check.request(&all, &job.ignored, job.preferred.as_deref(), job.correct_spelling) {
                    None => (None, Some("layout not known")),
                    Some(r) if !detector.may_correct(&r) => (None, Some("dictionaries see no other layout")),
                    Some(r) => match detector.correction(&r, &job.check.context) {
                        Some(s) => (Some((s.replacement, s.target.id.clone())), None),
                        None => (None, Some("no correction")),
                    },
                }
            }));
            let (correction, reason) = outcome.unwrap_or((None, Some("the check failed")));
            if correction.is_none() && !job.gated { continue; }
            let answer = Box::new(Answer { version: job.check.version, gated: job.gated, correction, reason });
            unsafe { PostMessageW(hwnd as HWND, WM_APP_ANSWER, 0, Box::into_raw(answer) as LPARAM); }
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

fn token_elevated(process: HANDLE) -> Option<bool> {
    unsafe {
        let mut token: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(process, TOKEN_QUERY, &mut token) == 0 { return None; }
        let mut elevation: TOKEN_ELEVATION = std::mem::zeroed();
        let mut size = 0u32;
        let ok = GetTokenInformation(token, TokenElevation, &mut elevation as *mut _ as *mut _,
                                     std::mem::size_of::<TOKEN_ELEVATION>() as u32, &mut size);
        CloseHandle(token);
        (ok != 0).then_some(elevation.TokenIsElevated != 0)
    }
}

/// Windows drops input that a normal program sends to an administrator's window. Held
/// keys would be lost there, so Yasno stays out of such windows.
fn is_elevated(pid: u32) -> bool {
    if token_elevated(unsafe { GetCurrentProcess() }) == Some(true) { return false; }
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() { return true; }
        let elevated = token_elevated(process).unwrap_or(true);
        CloseHandle(process);
        elevated
    }
}

fn own_process() -> String { process_name(unsafe { GetCurrentProcessId() }).unwrap_or_default() }

impl App {
    fn layout_id(&mut self) -> Option<String> {
        let target = layouts::foreground()?;
        self.target = Some(target);
        let hkl = layouts::current(target) as usize;
        self.hkls.iter().position(|&h| h == hkl).map(|i| self.engine.layouts()[i].id.clone())
    }

    fn now() -> u64 { unsafe { windows_sys::Win32::System::SystemInformation::GetTickCount64() } }

    /// Collect the engine's effects; outside the hook they are performed right away.
    /// Its notes go to the diagnostic journal (a channel: nothing is written here).
    fn collect(&mut self) {
        self.outbox.extend(self.engine.take_effects());
        for mut row in self.engine.take_notes() {
            if !self.diagnostic.enabled { continue; }
            row.insert("uptime_ms".into(), json!(Self::now()));
            row.insert("app".into(), json!(self.last_app));
            let _ = self.diagnostics.send(diagnostics::Command::Record(row));
        }
    }

    /// Notes an event of the app itself (focus, layouts, monitoring) while diagnostics are on.
    fn note(&self, event: &str, fields: impl FnOnce() -> Value) {
        if !self.diagnostic.enabled { return; }
        let _ = self.diagnostics.send(diagnostics::Command::Record(diagnostics::row(event, fields(), Self::now())));
    }

    /// The state of Yasno when a diagnostic session starts, its first event.
    fn session(&self) -> Map<String, Value> {
        let layouts: Vec<Value> = self.engine.layouts().iter().zip(&self.hkls).map(|(l, h)| json!({
            "id": l.id, "name": l.name, "hkl": format!("{h:X}"),
            "languages": l.languages.iter().map(|x| x.code()).collect::<Vec<_>>()})).collect();
        let installed = unsafe { GetKeyboardLayoutList(0, std::ptr::null_mut()) };
        let row = json!({"status": self.status(), "monitoring": self.monitoring(), "paused": self.settings.paused,
                         "layouts": layouts, "installed_layouts": installed, "exclusions": self.settings.exclusions,
                         "ignored_words": self.settings.ignored_words.len(), "correct_spelling": self.settings.correct_spelling,
                         "automatic_switching": self.settings.automatic_switching,
                         "preferred": self.engine.typing.preferred, "app": self.last_app, "excluded": self.excluded,
                         "elevated_window": self.elevated, "yasno_elevated": token_elevated(unsafe { GetCurrentProcess() }),
                         "corrections": self.corrections()});
        diagnostics::row("session", row, Self::now())
    }

    /// A report from the diagnostic service.
    fn diagnostic_update(&mut self, update: diagnostics::Update) {
        let started = update.state.enabled && !self.diagnostic.enabled;
        self.diagnostic = update.state;
        self.engine.set_diagnostics(self.diagnostic.enabled);
        if started {
            // The field Yasno sees now, described for the journal.
            self.field_generation += 1;
            let _ = self.inspector.send(field::Request { generation: self.field_generation, describe: true });
        }
        if let Some(text) = update.message { show_balloon(self.hwnd, &text); }
    }

    fn flush(&mut self) {
        self.collect();
        let effects = std::mem::take(&mut self.outbox);
        for e in effects {
            match e {
                Effect::Send(batch) => {
                    if !input::send(&batch) {
                        self.detail = "Windows не приняла ввод от Ясно в этом окне.".into();
                        let elevated = self.elevated;
                        self.note("edit", || json!({"result": "failed", "reason": "Windows rejected input sent by Yasno (SendInput)",
                                                    "elevated_window": elevated}));
                    }
                }
                Effect::Detect { check, gated } => {
                    let _ = self.worker.send(Job { check, gated, layouts: self.engine.layouts().clone(), ignored: self.ignored.clone(),
                                                   preferred: self.engine.typing.preferred.clone(),
                                                   correct_spelling: self.settings.correct_spelling });
                }
                Effect::Switch(id) => {
                    if let (Some(i), Some(target)) = (self.engine.layouts().iter().position(|l| l.id == id), self.target) {
                        layouts::select(target, self.hkls[i] as HKL);
                    }
                }
                Effect::Start(Timer::Pause, ms) => unsafe { SetTimer(self.hwnd, TIMER_PAUSE, ms as u32, None); },
                Effect::Start(Timer::Watchdog, ms) => unsafe { SetTimer(self.hwnd, TIMER_WATCHDOG, ms as u32, None); },
                Effect::Preferred(id) => {
                    if self.settings.preferred.as_deref() != Some(id.as_str()) {
                        self.settings.preferred = Some(id);
                        self.settings.save();
                    }
                }
            }
        }
    }

    /// Called from the hook: returns true when the key must not reach the application.
    fn on_key(&mut self, k: &KBDLLHOOKSTRUCT, down: bool) -> bool {
        let source = input::source(k.dwExtraInfo);
        let key = RawKey { vk: k.vkCode as u16, scan: k.scanCode as u16, extended: k.flags & LLKHF_EXTENDED != 0,
                           down, time: k.time as u64 };
        let layout = if source == yasno_core::engine::Source::User { self.layout_id() } else { None };
        let swallow = self.engine.key(key, source, Context { now: Self::now(), layout: layout.as_deref() });
        self.collect();
        if !self.outbox.is_empty() && !self.flush_posted {
            self.flush_posted = true;
            unsafe { PostMessageW(self.hwnd, WM_APP_FLUSH, 0, 0); }
        }
        swallow
    }

    fn context_call(&mut self, f: impl FnOnce(&mut Engine, Context)) {
        let layout = self.layout_id();
        f(&mut self.engine, Context { now: Self::now(), layout: layout.as_deref() });
        self.flush();
    }

    pub fn status(&self) -> &'static str {
        if self.settings.paused { "На паузе" }
        else if self.hkls.len() < 2 { "Нужны две раскладки" }
        else if self.excluded { "Пауза в этом приложении" }
        else if self.elevated { "Окно администратора: Windows не даёт в нём исправлять" }
        else if !self.settings.automatic_switching { "Работает · только по Shift" }
        else { "Готово к работе" }
    }

    pub fn monitoring(&self) -> bool { self.engine.enabled() }
    pub fn corrections(&self) -> u64 { self.engine.corrections }
    pub fn layout_names(&self) -> String {
        self.engine.layouts().iter().map(|l| l.name.clone()).collect::<Vec<_>>().join(" · ")
    }
    pub fn switch_failed(&self) -> bool { self.engine.switch_failed }

    fn apply_state(&mut self) {
        let enabled = !self.settings.paused && !self.excluded && !self.elevated && self.hkls.len() >= 2;
        let was = self.engine.enabled();
        self.context_call(|e, ctx| e.set_enabled(enabled, ctx));
        if was != enabled {
            let (paused, excluded, elevated, layouts) = (self.settings.paused, self.excluded, self.elevated, self.hkls.len());
            self.note("monitor", || json!({"enabled": enabled, "status": self.status(), "paused": paused, "excluded": excluded,
                                           "elevated_window": elevated, "layouts": layouts}));
        }
    }

    pub fn set_paused(&mut self, paused: bool) {
        self.settings.paused = paused;
        self.settings.save();
        self.apply_state();
        update_tray_tip(self.hwnd, paused);
    }

    pub fn set_automatic_switching(&mut self, on: bool) {
        self.settings.automatic_switching = on;
        self.settings.save();
        self.engine.set_automatic(on);
        self.note("automatic_switching", || json!({"on": on}));
    }

    pub fn set_spelling(&mut self, on: bool) {
        self.settings.correct_spelling = on;
        self.settings.save();
        self.engine.typing.reset();
    }

    pub fn set_ignored(&mut self, words: Vec<String>) {
        self.ignored = Arc::new(words.iter().cloned().collect());
        self.settings.ignored_words = words;
        self.settings.save();
    }

    pub fn set_exclusions(&mut self, apps: Vec<String>) {
        self.settings.exclusions = apps;
        self.settings.save();
        self.excluded = self.last_app.as_ref().is_some_and(|a| self.settings.exclusions.contains(a));
        self.apply_state();
    }

    fn reload_layouts_if_changed(&mut self) {
        // The whole list Windows has, not only Ясно's layouts: a Belarusian layout next to RU/EN
        // made the counts differ forever and the tables were rebuilt (and the word dropped) every
        // 5 s; one layout replaced by another kept the count and was never noticed.
        let system: Vec<usize> = layouts::system_list().into_iter().map(|h| h as usize).collect();
        if system != self.system_hkls {
            self.system_hkls = system;
            let (hkls, layouts) = load_layouts();
            if hkls == self.hkls { return; }
            self.hkls = hkls;
            self.engine.set_layouts(layouts);
            self.collect();
            self.note("layouts", || json!({"layouts": self.engine.layouts().iter().map(|l| json!({"id": l.id, "name": l.name}))
                .collect::<Vec<_>>()}));
            self.apply_state();
        }
    }

    fn on_focus(&mut self, hwnd: usize, object: i32, child: i32) {
        // Browsers repeat focus events for the same field; only a real change resets.
        if self.last_focus == (hwnd, object, child) { return; }
        self.last_focus = (hwnd, object, child);
        self.field_generation += 1;
        let _ = self.inspector.send(field::Request { generation: self.field_generation, describe: self.diagnostic.enabled });
        // The word typed before belongs to the field left behind: noted with its own rules.
        self.context_call(|e, ctx| e.focus_changed(ctx));
        // Until UI Automation has said what the new field is, nothing typed there is recorded.
        self.engine.set_redact(Some("not recorded: field not checked yet"));
        self.engine.set_editable(false);
        self.reload_layouts_if_changed();
        let Some(target) = layouts::foreground() else { self.note("focus", || json!({"window": false})); return };
        let Some(name) = process_name(target.pid) else {
            self.note("focus", || json!({"process": null, "reason": "process not readable: an administrator's window"}));
            self.elevated = true;
            self.apply_state();
            return;
        };
        if self.diagnostic.enabled {
            if self.last_app.as_deref() != Some(name.as_str()) {
                self.note("app", || json!({"app": name, "previous": self.last_app}));
            }
            let window = window_info(target);
            let hkl = layouts::current(target) as usize;
            let known = self.hkls.contains(&hkl);
            self.note("focus", || {
                let mut row = window;
                row["process"] = json!(name);
                row["layout"] = json!(format!("{hkl:X}"));
                row["known_layout"] = json!(known);
                row
            });
        }
        if name == own_process() {
            // Yasno's own windows are left alone, except the self-test field, which stands in for any app.
            self.excluded = !SELF_TEST.load(std::sync::atomic::Ordering::SeqCst);
            self.elevated = false;
            self.apply_state();
            return;
        }
        self.excluded = self.settings.exclusions.contains(&name);
        self.elevated = is_elevated(target.pid);
        if self.excluded || self.elevated {
            let (excluded, elevated) = (self.excluded, self.elevated);
            self.note("skipped", || json!({"reason": if excluded { "application excluded" } else { "administrator's window" },
                                           "app": name, "excluded": excluded, "elevated_window": elevated}));
        }
        self.last_app = Some(name);
        self.engine.set_caps_lock(unsafe { GetKeyState(VK_CAPITAL as i32) } & 1 != 0);
        self.apply_state();
    }
}

/// The window with the keyboard focus, as Win32 sees it: classes, caret, process.
fn window_info(target: layouts::Target) -> Value {
    unsafe {
        let class = |h: HWND| -> String {
            if h.is_null() { return String::new(); }
            let mut buf = [0u16; 128];
            let n = GetClassNameW(h, buf.as_mut_ptr(), buf.len() as i32);
            String::from_utf16_lossy(&buf[..n.max(0) as usize])
        };
        let mut info: GUITHREADINFO = std::mem::zeroed();
        info.cbSize = std::mem::size_of::<GUITHREADINFO>() as u32;
        let ok = GetGUIThreadInfo(target.thread, &mut info) != 0;
        let focus = if ok { info.hwndFocus } else { std::ptr::null_mut() };
        let password = !focus.is_null() && (GetWindowLongW(focus, GWL_STYLE) as u32 & ES_PASSWORD as u32) != 0
            && class(focus).eq_ignore_ascii_case("edit");
        json!({"window_class": class(target.window as HWND), "focus_class": class(focus), "caret": ok && !info.hwndCaret.is_null(),
               "es_password": password, "pid": target.pid})
    }
}

fn focus_changed(hwnd: usize, object: i32, child: i32) {
    with_app(|app| app.on_focus(hwnd, object, child));
    window::refresh();
}

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
        with_app(|app| app.engine.caret_moved());
    }
    CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam)
}

unsafe extern "system" fn focus_proc(_: HWINEVENTHOOK, _: u32, hwnd: HWND, object: i32, child: i32, _: u32, _: u32) {
    focus_changed(hwnd as usize, object, child);
}

fn schedule_update(hwnd: HWND) {
    let Some((automatic, last)) = with_app(|a| (a.settings.automatic_updates, a.settings.last_update_check)) else { return };
    unsafe {
        if automatic { SetTimer(hwnd, TIMER_UPDATE, update::delay(last), None); } else { KillTimer(hwnd, TIMER_UPDATE); }
    }
}

pub fn set_automatic_updates(on: bool) {
    let Some(hwnd) = with_app(|a| { a.settings.automatic_updates = on; a.settings.save(); a.hwnd }) else { return };
    schedule_update(hwnd);
}

/// `Offline`: an automatic check could not reach GitHub (the network not up yet after wake).
enum UpdateResult { Current, Installed(String, std::path::PathBuf), Failed(String), Offline }

/// An automatic check that could not reach GitHub is retried after an hour, at most this many
/// times, instead of waiting for the next 21:00.
const UPDATE_RETRIES: u8 = 3;

/// Check (and install) on another thread; the result comes back as WM_APP_UPDATE.
pub fn check_for_updates(automatic: bool) {
    let Some(hwnd) = with_app(|a| {
        if a.update_busy { return None; }
        a.update_busy = true;
        a.update_message = "Проверка обновлений…".into();
        Some(a.hwnd as usize)
    }).flatten() else { return };
    window::refresh();
    std::thread::spawn(move || {
        let result = match update::newest() {
            Ok(None) => UpdateResult::Current,
            Ok(Some(release)) => match update::install(&release) {
                Ok(exe) => UpdateResult::Installed(release.version, exe),
                Err(e) => UpdateResult::Failed(format!("Обновление {}: {e}", release.version)),
            },
            Err(_) if automatic => UpdateResult::Offline,
            Err(e) => UpdateResult::Failed(format!("Не удалось проверить обновления: {e}")),
        };
        unsafe { PostMessageW(hwnd as HWND, WM_APP_UPDATE, 0, Box::into_raw(Box::new(result)) as LPARAM); }
    });
}

unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_APP_FLUSH => {
            with_app(|app| { app.flush_posted = false; app.flush(); });
            0
        }
        WM_APP_ANSWER => {
            let answer = Box::from_raw(lparam as *mut Answer);
            with_app(|app| app.context_call(|e, ctx| e.answer(*answer, ctx)));
            0
        }
        WM_APP_READY => {
            with_app(|app| app.engine.set_ready(true));
            selftest::READY.store(true, std::sync::atomic::Ordering::SeqCst);
            0
        }
        WM_APP_FIELD => {
            let field = Box::from_raw(lparam as *mut field::Field);
            with_app(|app| if field.generation == app.field_generation {
                // Nothing typed into a password field is kept, edited or recorded.
                app.engine.set_redact((field.password || field.secret).then_some(SECRET));
                app.engine.set_editable(!field.password);
                if let Some(description) = field.description { app.note("field", || description); }
            });
            0
        }
        WM_APP_DIAGNOSTICS => {
            let update = Box::from_raw(lparam as *mut diagnostics::Update);
            with_app(|app| app.diagnostic_update(*update));
            window::refresh();
            0
        }
        WM_TIMER => {
            match wparam {
                TIMER_PAUSE => { KillTimer(hwnd, TIMER_PAUSE); with_app(|app| app.context_call(|e, ctx| e.timer(Timer::Pause, ctx))); }
                TIMER_WATCHDOG => { KillTimer(hwnd, TIMER_WATCHDOG); with_app(|app| app.context_call(|e, ctx| e.timer(Timer::Watchdog, ctx))); }
                TIMER_UPDATE => { KillTimer(hwnd, TIMER_UPDATE); check_for_updates(true); }
                TIMER_REFRESH => { with_app(|app| app.reload_layouts_if_changed()); window::refresh(); }
                _ => {}
            }
            0
        }
        WM_APP_UPDATE => {
            let result = Box::from_raw(lparam as *mut UpdateResult);
            let retry = with_app(|a| {
                a.update_busy = false;
                if matches!(*result, UpdateResult::Offline) && a.update_retries < UPDATE_RETRIES {
                    // Not recorded as a check: the next one comes in an hour, not tomorrow at 21:00.
                    a.update_retries += 1;
                    return true;
                }
                a.update_retries = 0;
                a.settings.last_update_check = Some(update::now());
                a.settings.save();
                a.update_message = match &*result {
                    UpdateResult::Current => "Установлена последняя версия.".into(),
                    UpdateResult::Installed(v, _) => format!("Установлена версия {v}. Перезапуск…"),
                    UpdateResult::Failed(e) => e.clone(),
                    UpdateResult::Offline => String::new(),
                };
                false
            }).unwrap_or(false);
            window::refresh();
            if retry { SetTimer(hwnd, TIMER_UPDATE, 3_600_000, None); return 0; }
            if let UpdateResult::Installed(_, exe) = *result {
                if start(&exe, &["--updated", "--background"]) { DestroyWindow(hwnd); return 0; }
            }
            schedule_update(hwnd);
            0
        }
        WM_APP_SHOW => { window::show(); 0 }
        WM_APP_QUIT => { DestroyWindow(hwnd); 0 }
        WM_APP_TRAY => {
            let event = (lparam & 0xffff) as u32;
            if event == WM_LBUTTONUP { window::show(); }
            if event == WM_RBUTTONUP { show_menu(hwnd); }
            0
        }
        WM_COMMAND => { on_menu(hwnd, wparam & 0xffff); 0 }
        WM_DESTROY => { window::close(); PostQuitMessage(0); 0 }
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
    let text = if paused { "Ясно — на паузе" } else { "Ясно" };
    let mut tip = [0u16; 128];
    for (i, c) in text.encode_utf16().take(127).enumerate() { tip[i] = c; }
    tip
}

pub fn app_icon() -> HICON {
    unsafe {
        let instance = GetModuleHandleW(std::ptr::null());
        // MAKEINTRESOURCE(1): the icon in res/yasno.rc.
        #[allow(clippy::manual_dangling_ptr)]
        let icon = LoadIconW(instance, 1 as *const u16);
        if icon.is_null() { LoadIconW(std::ptr::null_mut(), IDI_APPLICATION) } else { icon }
    }
}

fn add_tray_icon(hwnd: HWND) {
    let mut data = tray_data(hwnd);
    data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    data.uCallbackMessage = WM_APP_TRAY;
    data.hIcon = app_icon();
    data.szTip = tip(with_app(|a| a.settings.paused).unwrap_or(false));
    unsafe { Shell_NotifyIconW(NIM_ADD, &data); }
}

fn update_tray_tip(hwnd: HWND, paused: bool) {
    let mut data = tray_data(hwnd);
    data.uFlags = NIF_TIP;
    data.szTip = tip(paused);
    unsafe { Shell_NotifyIconW(NIM_MODIFY, &data); }
}

/// A notification from the tray icon, for messages the window may not be showing.
fn show_balloon(hwnd: HWND, text: &str) {
    let mut data = tray_data(hwnd);
    data.uFlags = NIF_INFO;
    data.dwInfoFlags = NIIF_INFO;
    for (i, c) in "Ясно — диагностика ввода".encode_utf16().take(63).enumerate() { data.szInfoTitle[i] = c; }
    for (i, c) in text.encode_utf16().take(255).enumerate() { data.szInfo[i] = c; }
    unsafe { Shell_NotifyIconW(NIM_MODIFY, &data); }
}

/// Diagnostics on (after the person agreed to the warning) or off; the journal is sent.
pub fn toggle_diagnostics(owner: HWND) {
    let Some(enabled) = with_app(|a| a.diagnostic.enabled) else { return };
    if enabled {
        with_app(|a| { let _ = a.diagnostics.send(diagnostics::Command::Stop { send: true, why: "user" }); });
        return;
    }
    // The app is not borrowed while the box is open: the hooks keep running.
    let answer = unsafe {
        MessageBoxW(owner, wide(diagnostics::WARNING).as_ptr(), wide("Ясно — диагностика ввода").as_ptr(),
                    MB_OKCANCEL | MB_ICONINFORMATION | MB_SETFOREGROUND)
    };
    if answer != IDOK { return; }
    with_app(|a| {
        let versions = json!({"app": update::VERSION, "windows": diagnostics::windows_version(), "platform": "windows",
                              "arch": std::env::consts::ARCH});
        let session = a.session();
        let _ = a.diagnostics.send(diagnostics::Command::Start { versions, session });
    });
}

pub fn send_journals() {
    with_app(|a| { let _ = a.diagnostics.send(diagnostics::Command::Flush); });
}

/// Saves the repository and, when `token` is Some, the token ("" removes it). The message
/// says what is wrong, or None when it was accepted.
pub fn save_diagnostic_settings(repo: &str, token: Option<&str>) -> Option<&'static str> {
    let repo = repo.trim();
    if !repo.is_empty() && !yasno_core::diagnostics::valid_repo(repo) {
        return Some("Репозиторий указывается так: владелец/имя, например mavesr/yasno-diagnostics-logs.");
    }
    let token = token.map(str::trim);
    if token.is_some_and(|t| !t.is_empty() && !yasno_core::diagnostics::valid_token(t)) {
        return Some("Это не похоже на токен GitHub.");
    }
    with_app(|a| {
        a.settings.diagnostic_repo = repo.to_string();
        a.settings.save();
        a.diagnostic.repo = repo.to_string();
        let _ = a.diagnostics.send(diagnostics::Command::Save { repo: repo.to_string(), token: token.map(str::to_string) });
    });
    None
}

pub fn open_journals() {
    let folder = diagnostics::queue_folder();
    let _ = std::fs::create_dir_all(&folder);
    let _ = std::process::Command::new("explorer.exe").arg(&folder).spawn();
}

fn remove_tray_icon(hwnd: HWND) {
    let data = tray_data(hwnd);
    unsafe { Shell_NotifyIconW(NIM_DELETE, &data); }
}

fn show_menu(hwnd: HWND) {
    let Some((status, paused, app, excluded, diagnosing, automatic)) = with_app(|a| {
        let app = a.last_app.clone();
        let excluded = app.as_ref().is_some_and(|n| a.settings.exclusions.contains(n));
        (a.status(), a.settings.paused, app, excluded, a.diagnostic.enabled, a.settings.automatic_switching)
    }) else { return };
    unsafe {
        let menu = CreatePopupMenu();
        AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, wide(status).as_ptr());
        AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
        AppendMenuW(menu, MF_STRING, MENU_OPEN, wide("Открыть Ясно…").as_ptr());
        AppendMenuW(menu, MF_STRING, MENU_PAUSE, wide(if paused { "Включить" } else { "Приостановить" }).as_ptr());
        AppendMenuW(menu, MF_STRING | if automatic { MF_CHECKED } else { MF_UNCHECKED }, MENU_AUTOMATIC,
                    wide("Автопереключение").as_ptr());
        if let Some(app) = app {
            let label = if excluded { format!("Снова работать в {app}") } else { format!("Не работать в {app}") };
            AppendMenuW(menu, MF_STRING, MENU_EXCLUDE, wide(&label).as_ptr());
        }
        AppendMenuW(menu, MF_STRING, MENU_UPDATE, wide("Проверить обновления").as_ptr());
        AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
        let label = if diagnosing { "Выключить диагностику ✓" } else { "Включить диагностику ввода" };
        AppendMenuW(menu, MF_STRING, MENU_DIAGNOSTICS, wide(label).as_ptr());
        AppendMenuW(menu, MF_STRING, MENU_DIAGNOSTIC_SETTINGS, wide("Диагностика ввода…").as_ptr());
        AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
        AppendMenuW(menu, MF_STRING, MENU_QUIT, wide("Завершить Ясно").as_ptr());
        let mut point = POINT { x: 0, y: 0 };
        GetCursorPos(&mut point);
        // The menu closes when the user clicks elsewhere only if its owner is foreground.
        SetForegroundWindow(hwnd);
        TrackPopupMenu(menu, TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd, std::ptr::null());
        DestroyMenu(menu);
    }
}

pub fn toggle_exclusion() {
    with_app(|a| {
        let Some(app) = a.last_app.clone() else { return };
        let mut list = a.settings.exclusions.clone();
        if let Some(i) = list.iter().position(|e| *e == app) { list.remove(i); } else { list.push(app); }
        a.set_exclusions(list);
    });
    window::refresh();
}

fn on_menu(hwnd: HWND, id: usize) {
    match id {
        MENU_OPEN => window::show(),
        MENU_PAUSE => { with_app(|a| { let p = !a.settings.paused; a.set_paused(p); }); window::refresh(); }
        MENU_AUTOMATIC => {
            with_app(|a| { let on = !a.settings.automatic_switching; a.set_automatic_switching(on); });
            window::refresh();
        }
        MENU_EXCLUDE => toggle_exclusion(),
        MENU_UPDATE => { window::show(); check_for_updates(false); }
        MENU_DIAGNOSTICS => { toggle_diagnostics(std::ptr::null_mut()); window::refresh(); }
        MENU_DIAGNOSTIC_SETTINGS => window::show_diagnostics(),
        MENU_QUIT => unsafe { DestroyWindow(hwnd); },
        _ => {}
    }
}
