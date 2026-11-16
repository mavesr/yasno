//! Input diagnostics on Windows (docs/diagnostics.md). The journal and the delivery live in
//! yasno-core; here they run on their own thread, because writing and sending must never
//! happen in the keyboard hook. The token is kept encrypted for the Windows user (DPAPI) in
//! %LOCALAPPDATA%\Yasno, the journals in %LOCALAPPDATA%\Yasno\Diagnostics.

use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::Instant;

use serde_json::{json, Map, Value};
use windows_sys::Win32::Foundation::{LocalFree, HWND};
use windows_sys::Win32::Security::Cryptography::{CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB};
use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};
use windows_sys::Win32::UI::WindowsAndMessaging::PostMessageW;
use yasno_core::diagnostics::{Http, Service, State, SESSION_LIMIT};

use super::{update, wide};

pub const WARNING: &str = "Пока диагностика включена, Ясно записывает слова, которые вы печатаете, что оно с ними решило и в каком приложении это было. В полях пароля слова не записываются; если поле для пароля необычное, лучше не вводить пароль, пока диагностика включена.\n\nСама выключится через 30 минут. Включить?";

pub enum Command {
    Start { versions: Value, session: Map<String, Value> },
    Record(Map<String, Value>),
    Stop { send: bool, why: &'static str },
    Flush,
    /// The repository changed; `token`: Some to replace the saved one ("" removes it).
    Save { repo: String, token: Option<String> },
    Quit(Sender<()>),
}

/// What the service thread posts back to the UI thread, boxed as the message's lparam.
pub struct Update { pub state: State, pub message: Option<String> }

fn local() -> PathBuf {
    std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(std::env::temp_dir).join("Yasno")
}

pub fn root() -> PathBuf { local().join("Diagnostics") }
pub fn queue_folder() -> PathBuf { root().join("queue") }
fn token_file() -> PathBuf { local().join("diagnostic-token.bin") }

fn crypt(data: &[u8], protect: bool) -> Option<Vec<u8>> {
    unsafe {
        let input = CRYPT_INTEGER_BLOB { cbData: data.len() as u32, pbData: data.as_ptr() as *mut u8 };
        let mut output = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
        let ok = if protect {
            CryptProtectData(&input, wide("Yasno diagnostics").as_ptr(), std::ptr::null(), std::ptr::null(), std::ptr::null(),
                             CRYPTPROTECT_UI_FORBIDDEN, &mut output)
        } else {
            CryptUnprotectData(&input, std::ptr::null_mut(), std::ptr::null(), std::ptr::null(), std::ptr::null(),
                               CRYPTPROTECT_UI_FORBIDDEN, &mut output)
        };
        if ok == 0 || output.pbData.is_null() { return None; }
        let result = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        LocalFree(output.pbData as _);
        Some(result)
    }
}

/// DPAPI seals and opens a token for this Windows user (the self-test checks it).
pub fn dpapi_works() -> bool {
    let sample = b"github_pat_selftest_0123456789";
    crypt(sample, true).filter(|sealed| sealed.as_slice() != sample).and_then(|sealed| crypt(&sealed, false))
        .is_some_and(|open| open == sample)
}

fn load_token() -> Option<String> {
    let data = crypt(&std::fs::read(token_file()).ok()?, false)?;
    String::from_utf8(data).ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty())
}

fn save_token(token: &str) -> bool {
    let file = token_file();
    let _ = std::fs::remove_file(&file);
    if token.is_empty() { return true; }
    let Some(sealed) = crypt(token.as_bytes(), true) else { return false };
    std::fs::create_dir_all(local()).is_ok() && std::fs::write(&file, sealed).is_ok()
}

/// The GitHub API with the saved token.
struct GitHub { token: String }

impl Http for GitHub {
    fn call(&mut self, method: &str, path: &str, body: Option<&str>) -> Result<(u16, Vec<u8>), ()> {
        let headers = format!("Accept: application/vnd.github+json\r\nAuthorization: Bearer {}\r\nX-GitHub-Api-Version: 2022-11-28\r\n{}",
                              self.token, if body.is_some() { "Content-Type: application/json\r\n" } else { "" });
        update::request(method, &format!("https://api.github.com{path}"), &headers, body.map(str::as_bytes))
            .map(|(status, data)| (status as u16, data)).map_err(|_| ())
    }
}

/// Windows' version, from the registry (what winver shows).
pub fn windows_version() -> String {
    let read = |name: &str| -> String {
        let mut buf = [0u16; 128];
        let mut size = (buf.len() * 2) as u32;
        let r = unsafe {
            RegGetValueW(HKEY_LOCAL_MACHINE, wide("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion").as_ptr(), wide(name).as_ptr(),
                         RRF_RT_REG_SZ, std::ptr::null_mut(), buf.as_mut_ptr() as *mut _, &mut size)
        };
        if r != 0 { return String::new(); }
        let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        String::from_utf16_lossy(&buf[..end])
    };
    format!("{} {} (build {})", read("ProductName"), read("DisplayVersion"), read("CurrentBuild")).trim().to_string()
}

/// Starts the service thread. Its state comes back as `message` posted to `hwnd`.
pub fn spawn(hwnd: usize, message: u32, repo: String) -> Sender<Command> {
    let (sender, receiver) = channel::<Command>();
    std::thread::Builder::new().name("diagnostics".into()).spawn(move || run(receiver, hwnd, message, repo)).ok();
    sender
}

fn post(hwnd: usize, message: u32, state: &State, text: Option<String>) {
    let update = Box::into_raw(Box::new(Update { state: state.clone(), message: text }));
    unsafe { if PostMessageW(hwnd as HWND, message, 0, update as isize) == 0 { drop(Box::from_raw(update)); } }
}

fn run(commands: Receiver<Command>, hwnd: usize, message: u32, repo: String) {
    let mut service = Service::new(&root(), repo, load_token().is_some());
    post(hwnd, message, &service.state, None);
    let mut deadline: Option<Instant> = None;
    let seed = u64::from(std::process::id());
    loop {
        let command = match deadline {
            Some(at) => match commands.recv_timeout(at.saturating_duration_since(Instant::now())) {
                Ok(c) => c,
                Err(RecvTimeoutError::Timeout) => {
                    deadline = None;
                    let mut github = load_token().map(|token| GitHub { token });
                    let text = service.stop("time limit", Some("Диагностика выключилась сама через 30 минут."),
                                            github.as_mut().map(|g| g as &mut dyn Http));
                    post(hwnd, message, &service.state, text);
                    continue;
                }
                Err(RecvTimeoutError::Disconnected) => break,
            },
            None => match commands.recv() { Ok(c) => c, Err(_) => break },
        };
        let text = match command {
            Command::Record(row) => service.record(row),
            Command::Start { versions, session } => {
                let text = service.start(versions, session, seed);
                if service.state.enabled { deadline = Some(Instant::now() + SESSION_LIMIT); }
                text
            }
            Command::Stop { send, why } => {
                deadline = None;
                let mut github = if send { load_token().map(|token| GitHub { token }) } else { None };
                if send && github.is_none() && service.state.has_token {
                    // The saved token cannot be read (another Windows user, a restored profile).
                    service.state.has_token = false;
                }
                service.stop(why, None, github.as_mut().map(|g| g as &mut dyn Http))
            }
            Command::Flush => {
                service.state.busy = true;
                post(hwnd, message, &service.state, None);
                let text = match load_token() {
                    Some(token) => service.flush(&mut GitHub { token }, None),
                    None => {
                        service.state.has_token = false;
                        Some(yasno_core::diagnostics::Error::Configuration.message().to_string())
                    }
                };
                service.state.busy = false;
                text
            }
            Command::Save { repo, token } => {
                let saved = token.as_deref().map_or(true, save_token);
                service.state.repo = repo.clone();
                service.state.has_token = load_token().is_some();
                Some(if !saved { "Не удалось сохранить токен.".to_string() }
                     else if service.state.can_send() { format!("Сохранено. Журналы будут отправляться в {repo}.") }
                     else { "Сохранено. Журналы остаются на этом компьютере.".to_string() })
            }
            Command::Quit(done) => {
                service.stop("quit", None, None);
                let _ = done.send(());
                break;
            }
        };
        if let Some(t) = &text { service.state.message = t.clone(); }
        post(hwnd, message, &service.state, text);
    }
}

/// Closes an open session before Yasno quits; it is sent another time.
pub fn shutdown(sender: &Sender<Command>) {
    let (done, wait) = channel();
    if sender.send(Command::Quit(done)).is_ok() { let _ = wait.recv_timeout(std::time::Duration::from_secs(3)); }
}

/// A row as every note carries it.
pub fn row(event: &str, fields: Value, uptime_ms: u64) -> Map<String, Value> {
    let mut row = match fields { Value::Object(m) => m, _ => Map::new() };
    row.insert("event".into(), event.into());
    row.insert("uptime_ms".into(), json!(uptime_ms));
    row
}
