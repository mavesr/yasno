//! The settings window, laid out like the Mac MainView: status and the main switch, what
//! Yasno does, typo correction, start at sign-in, exceptions, updates, the count of fixes.
//! Plain Win32 controls in the system font, sized for the screen's DPI.

use std::cell::RefCell;

use windows_sys::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::*;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::HiDpi::GetDpiForSystem;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, SetFocus};

const SS_RIGHT: u32 = 2;
const SS_ETCHEDHORZ: u32 = 16;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use super::{settings, update, wide, with_app};

const MAIN_CLASS: &str = "YasnoSettings";
const EXCEPTIONS_CLASS: &str = "YasnoExceptions";
const DIAGNOSTICS_CLASS: &str = "YasnoDiagnostics";

const ID_STATUS: i32 = 100;
const ID_ENABLED: i32 = 101;
const ID_LAYOUTS: i32 = 102;
const ID_SPELLING: i32 = 103;
const ID_AUTOSTART: i32 = 104;
const ID_EXCEPTIONS: i32 = 105;
const ID_AUTOUPDATE: i32 = 106;
const ID_CHECK: i32 = 107;
const ID_UPDATE_TEXT: i32 = 108;
const ID_DETAIL: i32 = 109;
const ID_COUNT: i32 = 110;
const ID_DIAGNOSTICS: i32 = 111;
const ID_AUTOMATIC: i32 = 112;
const ID_D_TITLE: i32 = 140;
const ID_D_STATUS: i32 = 141;
const ID_D_TOGGLE: i32 = 142;
const ID_D_SHOW: i32 = 143;
const ID_D_SEND: i32 = 144;
const ID_D_REPO_LABEL: i32 = 145;
const ID_D_REPO: i32 = 146;
const ID_D_REPLACE: i32 = 147;
const ID_D_TOKEN: i32 = 148;
const ID_D_SAVE: i32 = 149;
const ID_D_DONE: i32 = 150;
const ID_D_GITHUB: i32 = 151;
const ID_WORDS: i32 = 200;
const ID_APPS: i32 = 201;
const ID_REMOVE: i32 = 202;
const ID_APP_NAME: i32 = 203;
const ID_ADD: i32 = 204;
const ID_DONE: i32 = 205;
/// Static texts from here on are secondary: drawn in grey.
const ID_GREY: i32 = 300;

#[derive(Default)]
struct Ui {
    main: Option<HWND>,
    exceptions: Option<HWND>,
    diagnostics: Option<HWND>,
    font: HFONT,
    bold: HFONT,
    title: HFONT,
    small: HFONT,
    scale: f32,
}

thread_local! {
    static UI: RefCell<Ui> = RefCell::new(Ui::default());
}

fn s(v: i32) -> i32 { UI.with(|u| (v as f32 * u.borrow().scale) as i32) }

fn fonts() {
    UI.with(|u| {
        let mut u = u.borrow_mut();
        if !u.font.is_null() { return; }
        let scale = unsafe { GetDpiForSystem() } as f32 / 96.0;
        u.scale = scale;
        let make = |size: i32, weight: i32| unsafe {
            CreateFontW(-((size as f32 * scale) as i32), 0, 0, 0, weight, 0, 0, 0, DEFAULT_CHARSET as u32, 0, 0,
                        CLEARTYPE_QUALITY as u32, 0, wide("Segoe UI").as_ptr())
        };
        u.font = make(14, 400);
        u.bold = make(14, 600);
        u.title = make(28, 600);
        u.small = make(12, 400);
    });
}

fn font(kind: u8) -> HFONT {
    UI.with(|u| { let u = u.borrow(); match kind { 1 => u.bold, 2 => u.title, 3 => u.small, _ => u.font } })
}

#[allow(clippy::too_many_arguments)]
fn control(parent: HWND, class: &str, text: &str, style: u32, x: i32, y: i32, w: i32, h: i32, id: i32, f: u8) -> HWND {
    unsafe {
        let hwnd = CreateWindowExW(0, wide(class).as_ptr(), wide(text).as_ptr(), WS_CHILD | WS_VISIBLE | style,
                                   s(x), s(y), s(w), s(h), parent, id as usize as HMENU, GetModuleHandleW(std::ptr::null()),
                                   std::ptr::null());
        SendMessageW(hwnd, WM_SETFONT, font(f) as WPARAM, 1);
        hwnd
    }
}

fn label(parent: HWND, text: &str, x: i32, y: i32, w: i32, h: i32, id: i32, f: u8) -> HWND {
    control(parent, "STATIC", text, 0, x, y, w, h, id, f)
}

fn checkbox(parent: HWND, text: &str, x: i32, y: i32, w: i32, id: i32) -> HWND {
    control(parent, "BUTTON", text, BS_AUTOCHECKBOX as u32 | WS_TABSTOP, x, y, w, 24, id, 0)
}

fn button(parent: HWND, text: &str, x: i32, y: i32, w: i32, id: i32) -> HWND {
    control(parent, "BUTTON", text, BS_PUSHBUTTON as u32 | WS_TABSTOP, x, y, w, 28, id, 0)
}

fn item(parent: HWND, id: i32) -> HWND { unsafe { GetDlgItem(parent, id) } }

fn set_text(parent: HWND, id: i32, text: &str) {
    unsafe {
        let h = item(parent, id);
        let mut buf = [0u16; 512];
        let n = GetWindowTextW(h, buf.as_mut_ptr(), buf.len() as i32);
        if String::from_utf16_lossy(&buf[..n.max(0) as usize]) != text { SetWindowTextW(h, wide(text).as_ptr()); }
    }
}

fn get_text(h: HWND) -> String {
    unsafe {
        let n = GetWindowTextLengthW(h);
        let mut buf = vec![0u16; n as usize + 1];
        let n = GetWindowTextW(h, buf.as_mut_ptr(), buf.len() as i32);
        String::from_utf16_lossy(&buf[..n.max(0) as usize])
    }
}

fn set_check(parent: HWND, id: i32, on: bool) {
    unsafe { SendMessageW(item(parent, id), BM_SETCHECK, if on { 1 } else { 0 }, 0); }
}

fn checked(parent: HWND, id: i32) -> bool { unsafe { SendMessageW(item(parent, id), BM_GETCHECK, 0, 0) == 1 } }

fn register(class: &str, proc_: WNDPROC) {
    unsafe {
        let wc = WNDCLASSW {
            lpfnWndProc: proc_, hInstance: GetModuleHandleW(std::ptr::null()), lpszClassName: wide(class).leak().as_ptr(),
            hCursor: LoadCursorW(std::ptr::null_mut(), IDC_ARROW), hbrBackground: GetSysColorBrush(COLOR_WINDOW),
            hIcon: super::app_icon(), ..std::mem::zeroed()
        };
        RegisterClassW(&wc);
    }
}

fn window(class: &str, title: &str, width: i32, height: i32, owner: HWND) -> HWND {
    unsafe {
        let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
        let mut rect = RECT { left: 0, top: 0, right: s(width), bottom: s(height) };
        AdjustWindowRect(&mut rect, style, 0);
        let (w, h) = (rect.right - rect.left, rect.bottom - rect.top);
        let x = (GetSystemMetrics(SM_CXSCREEN) - w) / 2;
        let y = (GetSystemMetrics(SM_CYSCREEN) - h) / 3;
        CreateWindowExW(0, wide(class).as_ptr(), wide(title).as_ptr(), style, x, y, w, h, owner, std::ptr::null_mut(),
                        GetModuleHandleW(std::ptr::null()), std::ptr::null())
    }
}

const WIDTH: i32 = 480;

pub fn show() {
    if let Some(main) = UI.with(|u| u.borrow().main) {
        unsafe { ShowWindow(main, SW_RESTORE); SetForegroundWindow(main); }
        refresh();
        return;
    }
    fonts();
    register(MAIN_CLASS, Some(main_proc));
    let hwnd = window(MAIN_CLASS, "Ясно", WIDTH, 684, std::ptr::null_mut());
    UI.with(|u| u.borrow_mut().main = Some(hwnd));
    let x = 24;
    let inner = WIDTH - 2 * x;
    label(hwnd, "Ясно", 72, 14, 200, 40, ID_GREY - 1, 2);
    label(hwnd, "Ваши слова. Нужная раскладка.", 74, 52, 300, 20, ID_GREY + 1, 0);
    control(hwnd, "STATIC", update::VERSION, SS_RIGHT, WIDTH - x - 100, 22, 100, 18, ID_GREY + 2, 3);
    label(hwnd, "", x, 92, inner - 120, 22, ID_STATUS, 1);
    checkbox(hwnd, "Включено", WIDTH - x - 110, 90, 110, ID_ENABLED);
    label(hwnd, "", x, 116, inner, 18, ID_LAYOUTS + ID_GREY, 3);
    let features = [
        ("Во время набора", "Исправляет уверенно распознанное слово и адрес сайта до пробела. Короткие и неоднозначные слова проверяет при завершении."),
        ("Один короткий Shift", "Преобразует только что набранное слово. После автозамены — отмена. В пустом поле — следующий язык."),
        ("Русский и украинский отдельно", "При неоднозначности — ваш выбор языка; правильные слова сохраняются."),
    ];
    let mut y = 150;
    for (i, (title, text)) in features.iter().enumerate() {
        label(hwnd, title, x, y, inner, 20, 120 + i as i32, 1);
        label(hwnd, text, x, y + 20, inner, 36, ID_GREY + 10 + i as i32, 3);
        y += 64;
    }
    control(hwnd, "STATIC", "", SS_ETCHEDHORZ, x, y, inner, 2, 130, 0);
    y += 14;
    checkbox(hwnd, "Автопереключение", x, y, inner, ID_AUTOMATIC);
    label(hwnd, "", x + 20, y + 24, inner - 20, 18, ID_AUTOMATIC + ID_GREY, 3);
    y += 54;
    checkbox(hwnd, "Исправлять опечатки", x, y, inner, ID_SPELLING);
    label(hwnd, "После пробела · только однозначные варианты · короткий Shift — отменить", x + 20, y + 24, inner - 20, 18, ID_GREY + 20, 3);
    y += 54;
    checkbox(hwnd, "Запускать при входе в Windows", x, y, inner - 140, ID_AUTOSTART);
    button(hwnd, "Исключения…", WIDTH - x - 130, y - 2, 130, ID_EXCEPTIONS);
    y += 40;
    checkbox(hwnd, "Обновлять автоматически", x, y, inner - 160, ID_AUTOUPDATE);
    button(hwnd, "Проверить сейчас", WIDTH - x - 150, y - 2, 150, ID_CHECK);
    label(hwnd, "", x + 20, y + 26, inner - 20, 34, ID_UPDATE_TEXT + ID_GREY, 3);
    y += 66;
    label(hwnd, "", x, y + 4, inner - 160, 20, ID_GREY + 32, 0);
    button(hwnd, "Диагностика…", WIDTH - x - 150, y, 150, ID_DIAGNOSTICS);
    y += 40;
    label(hwnd, "", x, y, inner, 34, ID_DETAIL + ID_GREY, 3);
    y += 40;
    label(hwnd, "На вашем компьютере · ввод записывается только в диагностике", x, y, 320, 18, ID_GREY + 30, 3);
    control(hwnd, "STATIC", "", SS_RIGHT, WIDTH - x - 110, y, 110, 18, ID_COUNT + ID_GREY, 3);
    refresh();
    unsafe {
        ShowWindow(hwnd, SW_SHOW);
        SetForegroundWindow(hwnd);
    }
}

/// Bring the window up to date with the app, if it is open.
pub fn refresh() {
    refresh_diagnostics();
    let Some(main) = UI.with(|u| u.borrow().main) else { return };
    let Some(state) = with_app(|a| (a.status(), a.monitoring(), a.settings.paused, a.layout_names(), a.settings.correct_spelling,
                                     a.settings.automatic_switching, a.settings.automatic_updates, a.update_message.clone(), a.update_busy,
                                     a.detail.clone(), a.corrections(), a.switch_failed())) else { return };
    if let Some(d) = with_app(|a| a.diagnostic.clone()) {
        let text = if d.enabled { format!("Диагностика ввода включена · событий: {}", d.events) } else { "Диагностика ввода выключена".into() };
        set_text(main, ID_GREY + 32, &text);
    }
    let (status, monitoring, paused, layouts, spelling, switching, automatic, message, busy, detail, count, switch_failed) = state;
    let status = if monitoring { format!("●  {status}") } else { format!("○  {status}") };
    set_text(main, ID_STATUS, &status);
    set_check(main, ID_ENABLED, !paused);
    set_text(main, ID_LAYOUTS + ID_GREY, &format!("Українська · Русский · English · Deutsch    ({layouts})"));
    set_check(main, ID_AUTOMATIC, switching);
    set_text(main, ID_AUTOMATIC + ID_GREY, if switching { "Слова переключаются сами во время набора и после пробела" }
                                           else { "Выключено · слово переключает только короткий Shift" });
    set_check(main, ID_SPELLING, spelling && switching);
    // Typos are corrected only as part of automatic switching.
    unsafe { EnableWindow(item(main, ID_SPELLING), switching as i32); }
    set_check(main, ID_AUTOSTART, settings::autostart());
    set_check(main, ID_AUTOUPDATE, automatic);
    unsafe { EnableWindow(item(main, ID_CHECK), (!busy) as i32); }
    let message = if message.is_empty() { "Каждый день в 21:00 с GitHub".to_string() } else { message };
    set_text(main, ID_UPDATE_TEXT + ID_GREY, &message);
    let detail = if !detail.is_empty() { detail }
        else if switch_failed { "Текст исправлен, но это окно не переключило раскладку.".into() }
        else { String::new() };
    set_text(main, ID_DETAIL + ID_GREY, &detail);
    set_text(main, ID_COUNT + ID_GREY, &format!("Исправлено: {count}"));
}

pub fn close() {
    let (main, exceptions, diagnostics) = UI.with(|u| { let u = u.borrow(); (u.main, u.exceptions, u.diagnostics) });
    unsafe {
        if let Some(h) = diagnostics { DestroyWindow(h); }
        if let Some(h) = exceptions { DestroyWindow(h); }
        if let Some(h) = main { DestroyWindow(h); }
    }
}

/// Tab and Enter move between controls of Yasno's windows.
pub fn dialog_message(msg: &MSG) -> bool {
    let (main, exceptions, diagnostics) = UI.with(|u| { let u = u.borrow(); (u.main, u.exceptions, u.diagnostics) });
    for h in [diagnostics, exceptions, main].into_iter().flatten() {
        if unsafe { IsDialogMessageW(h, msg) } != 0 { return true; }
    }
    false
}

fn ctl_color(wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        let id = GetDlgCtrlID(lparam as HWND);
        let dc = wparam as HDC;
        SetBkMode(dc, TRANSPARENT as i32);
        let grey: COLORREF = 0x0070_6a66;
        let accent: COLORREF = 0x0064_6e2b; // the Mac accent, rgb(43, 110, 100)
        SetTextColor(dc, if id >= ID_GREY { grey } else if id == ID_STATUS { accent } else { GetSysColor(COLOR_WINDOWTEXT) });
        GetSysColorBrush(COLOR_WINDOW) as LRESULT
    }
}

unsafe extern "system" fn main_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_PAINT => {
            let mut ps: PAINTSTRUCT = std::mem::zeroed();
            let dc = BeginPaint(hwnd, &mut ps);
            DrawIconEx(dc, s(24), s(20), super::app_icon(), s(40), s(40), 0, std::ptr::null_mut(), DI_NORMAL);
            EndPaint(hwnd, &ps);
            0
        }
        WM_CTLCOLORSTATIC | WM_CTLCOLORBTN => ctl_color(wparam, lparam),
        WM_COMMAND => {
            let id = (wparam & 0xffff) as i32;
            match id {
                ID_ENABLED => { let on = checked(hwnd, ID_ENABLED); with_app(|a| a.set_paused(!on)); }
                ID_AUTOMATIC => { let on = checked(hwnd, ID_AUTOMATIC); with_app(|a| a.set_automatic_switching(on)); }
                ID_SPELLING => { let on = checked(hwnd, ID_SPELLING); with_app(|a| a.set_spelling(on)); }
                ID_AUTOSTART => settings::set_autostart(checked(hwnd, ID_AUTOSTART)),
                ID_AUTOUPDATE => super::set_automatic_updates(checked(hwnd, ID_AUTOUPDATE)),
                ID_CHECK => super::check_for_updates(false),
                ID_EXCEPTIONS => show_exceptions(hwnd),
                ID_DIAGNOSTICS => show_diagnostics(),
                _ => return 0,
            }
            refresh();
            0
        }
        WM_CLOSE => { DestroyWindow(hwnd); 0 }
        WM_DESTROY => {
            UI.with(|u| u.borrow_mut().main = None);
            if let Some(h) = UI.with(|u| u.borrow().exceptions) { DestroyWindow(h); }
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn show_exceptions(owner: HWND) {
    if let Some(h) = UI.with(|u| u.borrow().exceptions) { unsafe { SetForegroundWindow(h); } return; }
    register(EXCEPTIONS_CLASS, Some(exceptions_proc));
    let width = 430;
    let hwnd = window(EXCEPTIONS_CLASS, "Исключения", width, 470, owner);
    UI.with(|u| u.borrow_mut().exceptions = Some(hwnd));
    let x = 24;
    let inner = width - 2 * x;
    label(hwnd, "Не менять эти слова", x, 18, inner, 20, 210, 1);
    control(hwnd, "EDIT", "", (WS_BORDER | WS_VSCROLL | WS_TABSTOP) | (ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN) as u32,
            x, 42, inner, 90, ID_WORDS, 0);
    label(hwnd, "По одному слову в строке. Сохраняются при закрытии окна.", x, 136, inner, 18, ID_GREY + 40, 3);
    label(hwnd, "Не работать в приложениях", x, 166, inner, 20, 211, 1);
    control(hwnd, "LISTBOX", "", WS_BORDER | WS_VSCROLL | WS_TABSTOP | (LBS_NOINTEGRALHEIGHT | LBS_SORT) as u32,
            x, 190, inner - 110, 130, ID_APPS, 0);
    button(hwnd, "Удалить", width - x - 100, 190, 100, ID_REMOVE);
    control(hwnd, "EDIT", "", WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32, x, 330, inner - 110, 26, ID_APP_NAME, 0);
    button(hwnd, "Добавить", width - x - 100, 329, 100, ID_ADD);
    label(hwnd, "Имя программы, например telegram.exe. Текущее приложение можно исключить и через значок Ясно в трее.",
          x, 362, inner, 34, ID_GREY + 41, 3);
    button(hwnd, "Готово", width - x - 100, 420, 100, ID_DONE);
    if let Some((words, apps)) = with_app(|a| (a.settings.ignored_words.join("\r\n"), a.settings.exclusions.clone())) {
        unsafe {
            SetWindowTextW(item(hwnd, ID_WORDS), wide(&words).as_ptr());
            for app in apps { SendMessageW(item(hwnd, ID_APPS), LB_ADDSTRING, 0, wide(&app).as_ptr() as LPARAM); }
        }
    }
    unsafe { ShowWindow(hwnd, SW_SHOW); }
}

fn list_items(list: HWND) -> Vec<String> {
    unsafe {
        let n = SendMessageW(list, LB_GETCOUNT, 0, 0).max(0);
        (0..n).map(|i| {
            let len = SendMessageW(list, LB_GETTEXTLEN, i as usize, 0).max(0) as usize;
            let mut buf = vec![0u16; len + 1];
            SendMessageW(list, LB_GETTEXT, i as usize, buf.as_mut_ptr() as LPARAM);
            String::from_utf16_lossy(&buf[..len])
        }).collect()
    }
}

fn save_exceptions(hwnd: HWND) {
    let words: Vec<String> = get_text(item(hwnd, ID_WORDS)).split(|c: char| c.is_whitespace() || c == ',')
        .map(|w| w.trim().to_lowercase()).filter(|w| !w.is_empty()).collect();
    let apps = list_items(item(hwnd, ID_APPS));
    with_app(|a| { a.set_ignored(words); a.set_exclusions(apps); });
}

unsafe extern "system" fn exceptions_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_CTLCOLORSTATIC | WM_CTLCOLORBTN => ctl_color(wparam, lparam),
        WM_COMMAND => {
            let list = item(hwnd, ID_APPS);
            match (wparam & 0xffff) as i32 {
                ID_REMOVE => {
                    let i = SendMessageW(list, LB_GETCURSEL, 0, 0);
                    if i >= 0 { SendMessageW(list, LB_DELETESTRING, i as usize, 0); }
                }
                ID_ADD => {
                    let name = get_text(item(hwnd, ID_APP_NAME)).trim().to_lowercase();
                    if !name.is_empty() && !list_items(list).contains(&name) {
                        let name = if name.ends_with(".exe") { name } else { format!("{name}.exe") };
                        SendMessageW(list, LB_ADDSTRING, 0, wide(&name).as_ptr() as LPARAM);
                        SetWindowTextW(item(hwnd, ID_APP_NAME), wide("").as_ptr());
                    }
                }
                ID_DONE => { DestroyWindow(hwnd); }
                _ => {}
            }
            0
        }
        WM_CLOSE => { DestroyWindow(hwnd); 0 }
        WM_DESTROY => {
            save_exceptions(hwnd);
            UI.with(|u| u.borrow_mut().exceptions = None);
            refresh();
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// The diagnostics window: on and off, the journals, the repository and the token.
pub fn show_diagnostics() {
    if let Some(h) = UI.with(|u| u.borrow().diagnostics) { unsafe { ShowWindow(h, SW_RESTORE); SetForegroundWindow(h); } return; }
    fonts();
    register(DIAGNOSTICS_CLASS, Some(diagnostics_proc));
    let width = 460;
    let owner = UI.with(|u| u.borrow().main).unwrap_or(std::ptr::null_mut());
    let hwnd = window(DIAGNOSTICS_CLASS, "Диагностика ввода", width, 560, owner);
    UI.with(|u| u.borrow_mut().diagnostics = Some(hwnd));
    let x = 24;
    let inner = width - 2 * x;
    label(hwnd, "Диагностика ввода", x, 18, inner, 22, ID_D_TITLE, 1);
    label(hwnd, "Если в каком-то поле Ясно не переключает слова: включите диагностику, напечатайте там несколько слов \
                 не в той раскладке с пробелом после каждого и выключите её. Журнал покажет, что Ясно решило для каждого слова.",
          x, 44, inner, 52, ID_GREY + 50, 3);
    label(hwnd, "", x, 108, inner - 140, 22, ID_D_STATUS, 0);
    button(hwnd, "", width - x - 130, 104, 130, ID_D_TOGGLE);
    button(hwnd, "Показать журналы", x, 142, 170, ID_D_SHOW);
    button(hwnd, "", x + 180, 142, 150, ID_D_SEND);
    label(hwnd, "", x, 180, inner, 54, ID_GREY + 51, 3);
    control(hwnd, "STATIC", "", SS_ETCHEDHORZ, x, 242, inner, 2, 152, 0);
    label(hwnd, "Отправка на GitHub", x, 254, inner, 20, ID_D_GITHUB, 1);
    label(hwnd, "Журналы отправляются только в приватный репозиторий. Без токена они остаются на этом компьютере.",
          x, 278, inner, 34, ID_GREY + 52, 3);
    label(hwnd, "Репозиторий", x, 324, 100, 20, ID_D_REPO_LABEL, 0);
    control(hwnd, "EDIT", "", WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32, x + 104, 320, inner - 104, 26, ID_D_REPO, 0);
    label(hwnd, "", x, 358, inner, 18, ID_GREY + 53, 3);
    checkbox(hwnd, "Заменить токен", x, 380, inner, ID_D_REPLACE);
    control(hwnd, "EDIT", "", WS_BORDER | WS_TABSTOP | (ES_AUTOHSCROLL | ES_PASSWORD) as u32, x, 408, inner, 26, ID_D_TOKEN, 0);
    label(hwnd, "Fine-grained токен с доступом только к этому репозиторию: Contents — Read and write. \
                 Хранится зашифрованным для вашей учётной записи Windows. Пустое поле удаляет токен.",
          x, 440, inner, 52, ID_GREY + 54, 3);
    button(hwnd, "Сохранить", width - x - 220, 510, 110, ID_D_SAVE);
    button(hwnd, "Готово", width - x - 100, 510, 100, ID_D_DONE);
    if let Some(repo) = with_app(|a| a.settings.diagnostic_repo.clone()) {
        unsafe { SetWindowTextW(item(hwnd, ID_D_REPO), wide(&repo).as_ptr()); }
    }
    unsafe { EnableWindow(item(hwnd, ID_D_TOKEN), 0); }
    refresh_diagnostics();
    unsafe { ShowWindow(hwnd, SW_SHOW); SetForegroundWindow(hwnd); }
}

fn refresh_diagnostics() {
    let Some(hwnd) = UI.with(|u| u.borrow().diagnostics) else { return };
    let Some(d) = with_app(|a| a.diagnostic.clone()) else { return };
    let status = if d.enabled { format!("●  Включена · событий: {}", d.events) } else { "○  Выключена".into() };
    set_text(hwnd, ID_D_STATUS, &status);
    set_text(hwnd, ID_D_TOGGLE, if d.enabled { "Выключить" } else { "Включить…" });
    set_text(hwnd, ID_D_SEND, &if d.busy { "Отправляю…".to_string() } else { format!("Отправить ({})", d.queued) });
    unsafe { EnableWindow(item(hwnd, ID_D_SEND), (d.queued > 0 && !d.busy && d.can_send()) as i32); }
    set_text(hwnd, ID_GREY + 51, &d.message);
    set_text(hwnd, ID_GREY + 53, if d.has_token { "Токен сохранён." } else { "Токен не указан." });
}

unsafe extern "system" fn diagnostics_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_CTLCOLORSTATIC | WM_CTLCOLORBTN => ctl_color(wparam, lparam),
        WM_COMMAND => {
            match (wparam & 0xffff) as i32 {
                ID_D_TOGGLE => super::toggle_diagnostics(hwnd),
                ID_D_SHOW => super::open_journals(),
                ID_D_SEND => super::send_journals(),
                ID_D_REPLACE => {
                    let on = checked(hwnd, ID_D_REPLACE);
                    EnableWindow(item(hwnd, ID_D_TOKEN), on as i32);
                    if on { SetFocus(item(hwnd, ID_D_TOKEN)); }
                }
                ID_D_SAVE => {
                    let repo = get_text(item(hwnd, ID_D_REPO));
                    let token = checked(hwnd, ID_D_REPLACE).then(|| get_text(item(hwnd, ID_D_TOKEN)));
                    match super::save_diagnostic_settings(&repo, token.as_deref()) {
                        Some(problem) => set_text(hwnd, ID_GREY + 51, problem),
                        None => {
                            SetWindowTextW(item(hwnd, ID_D_TOKEN), wide("").as_ptr());
                            set_check(hwnd, ID_D_REPLACE, false);
                            EnableWindow(item(hwnd, ID_D_TOKEN), 0);
                        }
                    }
                    return 0;
                }
                ID_D_DONE => { DestroyWindow(hwnd); return 0; }
                _ => return 0,
            }
            refresh();
            0
        }
        WM_CLOSE => { DestroyWindow(hwnd); 0 }
        WM_DESTROY => {
            // The token typed and not saved is wiped from the control before it goes.
            SetWindowTextW(item(hwnd, ID_D_TOKEN), wide("").as_ptr());
            UI.with(|u| u.borrow_mut().diagnostics = None);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
