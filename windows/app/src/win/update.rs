//! Daily self-update from GitHub Releases (tags `win-v…`), like the Mac updater: checked at
//! 21:00, or a few minutes after start when that check was missed. The new executable is
//! verified against its SHA-256 file, put in place of the running one (Windows allows
//! renaming a running executable), started, and this copy quits.

use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use windows_sys::Win32::Networking::WinHttp::*;
use yasno_core::update::{self, Release};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

fn wide(s: &str) -> Vec<u16> { s.encode_utf16().chain(Some(0)).collect() }

struct Handle(*mut core::ffi::c_void);
impl Drop for Handle {
    fn drop(&mut self) { if !self.0.is_null() { unsafe { WinHttpCloseHandle(self.0); } } }
}

/// An HTTPS GET through WinHTTP: the system proxy settings and certificate store apply.
pub fn get(url: &str) -> Result<Vec<u8>, String> {
    let rest = url.strip_prefix("https://").ok_or("not https")?;
    let (host, path) = rest.split_once('/').map(|(h, p)| (h, format!("/{p}"))).unwrap_or((rest, "/".into()));
    unsafe {
        let agent = wide(&format!("Yasno-Windows/{VERSION}"));
        let session = Handle(WinHttpOpen(agent.as_ptr(), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, std::ptr::null(), std::ptr::null(), 0));
        if session.0.is_null() { return Err("WinHttpOpen".into()); }
        WinHttpSetTimeouts(session.0, 15_000, 15_000, 30_000, 60_000);
        let connection = Handle(WinHttpConnect(session.0, wide(host).as_ptr(), 443, 0));
        if connection.0.is_null() { return Err("connect".into()); }
        let request = Handle(WinHttpOpenRequest(connection.0, wide("GET").as_ptr(), wide(&path).as_ptr(), std::ptr::null(),
                                                std::ptr::null(), std::ptr::null(), WINHTTP_FLAG_SECURE));
        if request.0.is_null() { return Err("request".into()); }
        let headers = wide("Accept: application/vnd.github+json, application/octet-stream\r\n");
        if WinHttpSendRequest(request.0, headers.as_ptr(), u32::MAX, std::ptr::null(), 0, 0, 0) == 0
            || WinHttpReceiveResponse(request.0, std::ptr::null_mut()) == 0 {
            return Err("нет связи с GitHub".into());
        }
        let mut status = 0u32;
        let mut size = 4u32;
        WinHttpQueryHeaders(request.0, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, std::ptr::null(),
                            &mut status as *mut u32 as *mut _, &mut size, std::ptr::null_mut());
        if status != 200 { return Err(format!("HTTP {status}")); }
        let mut body = Vec::new();
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let mut read = 0u32;
            if WinHttpReadData(request.0, buf.as_mut_ptr() as *mut _, buf.len() as u32, &mut read) == 0 { return Err("read".into()); }
            if read == 0 { break; }
            body.extend_from_slice(&buf[..read as usize]);
            if body.len() > 64 * 1024 * 1024 { return Err("too large".into()); }
        }
        Ok(body)
    }
}

pub fn newest() -> Result<Option<Release>, String> {
    let body = get(&update::releases_url())?;
    update::newest(&String::from_utf8_lossy(&body), VERSION)
}

fn sibling(exe: &Path, name: &str) -> PathBuf { exe.with_file_name(name) }

/// Download, verify and put the new executable in place. The caller starts it and quits.
pub fn install(release: &Release) -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let expected = update::parse_checksum(&String::from_utf8_lossy(&get(&release.checksum)?)).ok_or("bad checksum file")?;
    let data = get(&release.exe)?;
    let digest: String = Sha256::digest(&data).iter().map(|b| format!("{b:02x}")).collect();
    if digest != expected { return Err("контрольная сумма не совпала".into()); }
    let new = sibling(&exe, "yasno.new.exe");
    let old = sibling(&exe, "yasno.old.exe");
    std::fs::write(&new, &data).map_err(|e| format!("запись: {e}"))?;
    let _ = std::fs::remove_file(&old);
    std::fs::rename(&exe, &old).map_err(|e| format!("замена: {e}"))?;
    if let Err(e) = std::fs::rename(&new, &exe) {
        let _ = std::fs::rename(&old, &exe);
        return Err(format!("замена: {e}"));
    }
    Ok(exe)
}

/// The previous executable stays next to the new one until the next start.
pub fn clean_up() {
    if let Ok(exe) = std::env::current_exe() {
        let _ = std::fs::remove_file(sibling(&exe, "yasno.old.exe"));
        let _ = std::fs::remove_file(sibling(&exe, "yasno.new.exe"));
    }
}

/// Seconds east of UTC now.
pub fn utc_offset() -> i64 {
    use windows_sys::Win32::System::Time::{GetTimeZoneInformation, TIME_ZONE_INFORMATION};
    unsafe {
        let mut tz: TIME_ZONE_INFORMATION = std::mem::zeroed();
        let mode = GetTimeZoneInformation(&mut tz);
        let daylight = if mode == 2 { tz.DaylightBias } else { tz.StandardBias };
        -((tz.Bias + daylight) as i64) * 60
    }
}

pub fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// Milliseconds until the next scheduled check.
pub fn delay(last: Option<i64>) -> u32 {
    let (now, offset) = (now(), utc_offset());
    let seconds = if update::missed_check(last, now, offset) { 300 } else { update::next_check(now, offset) - now };
    (seconds.clamp(60, 86_400) * 1000) as u32
}
