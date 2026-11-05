//! Settings in HKCU\Software\Yasno; start at sign-in through the Run key.

use windows_sys::Win32::Foundation::ERROR_SUCCESS;
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegQueryValueExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER,
    KEY_READ, KEY_WRITE, REG_DWORD, REG_OPTION_NON_VOLATILE, REG_SZ,
};

const KEY: &str = "Software\\Yasno";
const RUN: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const RUN_VALUE: &str = "Yasno";

/// Terminals and password managers are left alone by default, as on the Mac.
pub const DEFAULT_EXCLUSIONS: &[&str] = &[
    "windowsterminal.exe", "cmd.exe", "powershell.exe", "pwsh.exe", "conhost.exe", "openconsole.exe",
    "keepass.exe", "keepassxc.exe", "1password.exe", "bitwarden.exe", "mstsc.exe",
];

pub struct Settings {
    pub paused: bool,
    pub correct_spelling: bool,
    pub exclusions: Vec<String>,
    pub ignored_words: Vec<String>,
}

fn wide(s: &str) -> Vec<u16> { s.encode_utf16().chain(Some(0)).collect() }

fn open(path: &str) -> Option<HKEY> {
    let mut key: HKEY = std::ptr::null_mut();
    let r = unsafe { RegCreateKeyExW(HKEY_CURRENT_USER, wide(path).as_ptr(), 0, std::ptr::null(), REG_OPTION_NON_VOLATILE,
                                     KEY_READ | KEY_WRITE, std::ptr::null(), &mut key, std::ptr::null_mut()) };
    (r == ERROR_SUCCESS).then_some(key)
}

fn get_dword(key: HKEY, name: &str) -> Option<u32> {
    let mut value = 0u32;
    let mut size = 4u32;
    let r = unsafe { RegQueryValueExW(key, wide(name).as_ptr(), std::ptr::null(), std::ptr::null_mut(),
                                      &mut value as *mut u32 as *mut u8, &mut size) };
    (r == ERROR_SUCCESS).then_some(value)
}

fn get_string(key: HKEY, name: &str) -> Option<String> {
    let name = wide(name);
    let mut size = 0u32;
    unsafe {
        if RegQueryValueExW(key, name.as_ptr(), std::ptr::null(), std::ptr::null_mut(), std::ptr::null_mut(), &mut size) != ERROR_SUCCESS { return None; }
        let mut buf = vec![0u16; (size as usize).div_ceil(2) + 1];
        if RegQueryValueExW(key, name.as_ptr(), std::ptr::null(), std::ptr::null_mut(), buf.as_mut_ptr() as *mut u8, &mut size) != ERROR_SUCCESS { return None; }
        let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        Some(String::from_utf16_lossy(&buf[..end]))
    }
}

fn set_dword(key: HKEY, name: &str, value: u32) {
    unsafe { RegSetValueExW(key, wide(name).as_ptr(), 0, REG_DWORD, &value as *const u32 as *const u8, 4); }
}

fn set_string(key: HKEY, name: &str, value: &str) {
    let data = wide(value);
    unsafe { RegSetValueExW(key, wide(name).as_ptr(), 0, REG_SZ, data.as_ptr() as *const u8, (data.len() * 2) as u32); }
}

fn list(s: Option<String>) -> Option<Vec<String>> {
    s.map(|s| s.split(';').map(|x| x.trim().to_lowercase()).filter(|x| !x.is_empty()).collect())
}

impl Settings {
    pub fn load() -> Settings {
        let mut s = Settings { paused: false, correct_spelling: true,
                               exclusions: DEFAULT_EXCLUSIONS.iter().map(|s| s.to_string()).collect(), ignored_words: Vec::new() };
        if let Some(key) = open(KEY) {
            if let Some(v) = get_dword(key, "Paused") { s.paused = v != 0; }
            if let Some(v) = get_dword(key, "CorrectSpelling") { s.correct_spelling = v != 0; }
            if let Some(v) = list(get_string(key, "Exclusions")) { s.exclusions = v; }
            if let Some(v) = list(get_string(key, "IgnoredWords")) { s.ignored_words = v; }
            unsafe { RegCloseKey(key); }
        }
        s
    }

    pub fn save(&self) {
        if let Some(key) = open(KEY) {
            set_dword(key, "Paused", self.paused as u32);
            set_dword(key, "CorrectSpelling", self.correct_spelling as u32);
            set_string(key, "Exclusions", &self.exclusions.join(";"));
            set_string(key, "IgnoredWords", &self.ignored_words.join(";"));
            unsafe { RegCloseKey(key); }
        }
    }
}

pub fn autostart() -> bool {
    open(RUN).is_some_and(|key| { let v = get_string(key, RUN_VALUE).is_some(); unsafe { RegCloseKey(key); } v })
}

pub fn set_autostart(enabled: bool) {
    let Some(key) = open(RUN) else { return };
    if enabled {
        if let Ok(exe) = std::env::current_exe() { set_string(key, RUN_VALUE, &format!("\"{}\"", exe.display())); }
    } else {
        unsafe { RegDeleteValueW(key, wide(RUN_VALUE).as_ptr()); }
    }
    unsafe { RegCloseKey(key); }
}
