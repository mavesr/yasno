//! Input diagnostics in the format the Mac and Linux versions write (docs/diagnostics.md):
//! one JSON object per line, a `meta` row first and last, `event` rows between them. A
//! session is kept in `sessions/` while it is open, in `queue/` until it is sent, then in
//! `sent/` for a week. Delivery commits it to a private GitHub repository as
//! `logs/windows/<session>.jsonl`; the repository must report itself private before and
//! after the upload, and the file is read back at the new commit.
//!
//! Platform-free: the Windows app supplies the HTTPS client (WinHTTP) and keeps the token.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Map, Value};

pub const DEFAULT_REPO: &str = "mavesr/yasno-diagnostics-logs";
pub const MAX_SESSION_BYTES: u64 = 900_000;
const CLOSING_RESERVE: u64 = 1024;
/// A session ends by itself after half an hour.
pub const SESSION_LIMIT: Duration = Duration::from_secs(30 * 60);
const MAX_QUEUED: usize = 50;
const KEEP_SENT: Duration = Duration::from_secs(7 * 24 * 3600);

/// What replaces text typed in a field that may hold a secret, as on the Mac.
pub const SECRET: &str = "not recorded: field may hold a secret";
/// Fields of a row that hold typed text.
pub const TEXT_KEYS: &[&str] = &["text", "suffix", "replacement", "context_tail", "word"];

/// Replaces every typed text in a row.
pub fn redact(fields: &mut Map<String, Value>, why: &str) {
    for key in TEXT_KEYS {
        if let Some(v) = fields.get_mut(*key) {
            if v.as_str().is_some_and(|s| !s.is_empty()) { *v = Value::String(why.to_string()); }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error { Disk, Limit, Configuration, Network, Authorization, PublicRepo, Conflict }

impl Error {
    pub fn message(self) -> &'static str {
        match self {
            Error::Disk => "Не удалось записать журнал диагностики на диск.",
            Error::Limit => "Журнал диагностики заполнен. Выключите диагностику, чтобы сохранить его.",
            Error::Configuration => "Журнал сохранён на этом компьютере. Чтобы отправлять его на GitHub, укажите токен и приватный репозиторий в окне «Диагностика ввода».",
            Error::Network => "Не удалось отправить журнал: нет связи с GitHub. Он остался на этом компьютере, его можно отправить позже.",
            Error::Authorization => "GitHub не принял токен. Проверьте, что у него есть доступ к репозиторию (Contents: Read and write).",
            Error::PublicRepo => "Репозиторий открытый. Журнал отправляется только в приватный репозиторий.",
            Error::Conflict => "В репозитории уже есть другой файл с таким именем. Журнал остался на этом компьютере.",
        }
    }
}

/// `owner/name` with GitHub's characters only.
pub fn valid_repo(repo: &str) -> bool {
    let ok = |s: &str| !s.is_empty() && s.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'));
    match repo.split_once('/') { Some((o, n)) => ok(o) && ok(n) && !repo.contains(".."), None => false }
}

/// A GitHub token: letters, digits, `_` and `-`.
pub fn valid_token(token: &str) -> bool {
    (10..=255).contains(&token.len()) && token.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// UTC time as ISO 8601, to the second, like the Mac's ISO8601DateFormatter.
pub fn timestamp(time: SystemTime) -> String {
    let secs = time.duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let (days, rest) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rest / 3600, rest % 3600 / 60, rest % 60)
}

/// A random session id in UUID form. `seed` adds what the caller knows (process, time).
pub fn new_id(seed: u64) -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    let half = |n: u64| {
        let mut h = RandomState::new().build_hasher();
        h.write_u64(seed ^ n);
        h.write_u128(SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
        h.finish()
    };
    let (a, b) = (half(1), half(2));
    let b = (b & 0x3fff_ffff_ffff_ffff) | 0x8000_0000_0000_0000;
    let a = (a & 0xffff_ffff_ffff_0fff) | 0x0000_0000_0000_4000;
    format!("{:08x}-{:04x}-{:04x}-{:04x}-{:012x}", a >> 32, (a >> 16) & 0xffff, a & 0xffff, b >> 48, b & 0xffff_ffff_ffff)
}

fn line(row: &Value) -> Vec<u8> {
    // serde_json keeps keys sorted (no preserve_order feature), as the Mac writes them.
    let mut data = serde_json::to_vec(row).unwrap_or_default();
    data.push(b'\n');
    data
}

/// The journals on disk. Used from one thread only.
pub struct Journal {
    root: PathBuf,
    active: Option<PathBuf>,
    count: u64,
}

impl Journal {
    pub fn open(root: &Path) -> Result<Journal, Error> {
        for folder in ["sessions", "queue", "sent"] { fs::create_dir_all(root.join(folder)).map_err(|_| Error::Disk)?; }
        Ok(Journal { root: root.to_path_buf(), active: None, count: 0 })
    }

    pub fn root(&self) -> &Path { &self.root }
    pub fn is_active(&self) -> bool { self.active.is_some() }
    pub fn events(&self) -> u64 { self.count }

    pub fn files(&self, folder: &str) -> Vec<PathBuf> {
        let mut list: Vec<PathBuf> = fs::read_dir(self.root.join(folder)).into_iter().flatten().flatten()
            .map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "jsonl")).collect();
        list.sort();
        list
    }

    fn queued_path(&self, file: &Path) -> PathBuf { self.root.join("queue").join(file.file_name().unwrap_or_default()) }

    /// A session left open when Yasno stopped is closed as interrupted and queued.
    pub fn recover(&mut self) {
        for file in self.files("sessions") {
            if Some(&file) == self.active.as_ref() { continue; }
            let Ok(mut data) = fs::read(&file) else { continue };
            // A line cut off mid-write is dropped.
            let end = data.iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
            data.truncate(end);
            data.extend(line(&json!({"type": "meta", "closed": timestamp(SystemTime::now()), "closed_reason": "interrupted"})));
            if fs::write(&file, &data).is_ok() { let _ = fs::rename(&file, self.queued_path(&file)); }
        }
    }

    pub fn start(&mut self, repo: &str, versions: Value, seed: u64) -> Result<(), Error> {
        if self.active.is_some() { return Ok(()); }
        if self.files("queue").len() >= MAX_QUEUED { return Err(Error::Disk); }
        let id = new_id(seed);
        let file = self.root.join("sessions").join(format!("{id}.jsonl"));
        let meta = json!({"type": "meta", "schema": 1, "session_id": id, "platform": "windows",
                          "started": timestamp(SystemTime::now()), "target_repo": repo, "versions": versions});
        fs::write(&file, line(&meta)).map_err(|_| Error::Disk)?;
        self.active = Some(file);
        self.count = 0;
        Ok(())
    }

    /// Appends an event; false when no session is open.
    pub fn record(&mut self, mut row: Map<String, Value>) -> Result<bool, Error> {
        let Some(active) = &self.active else { return Ok(false) };
        row.insert("type".into(), "event".into());
        row.insert("ts".into(), timestamp(SystemTime::now()).into());
        let data = line(&Value::Object(row));
        let size = fs::metadata(active).map_err(|_| Error::Disk)?.len();
        if size + data.len() as u64 + CLOSING_RESERVE > MAX_SESSION_BYTES { return Err(Error::Limit); }
        let mut file = fs::OpenOptions::new().append(true).open(active).map_err(|_| Error::Disk)?;
        if file.write_all(&data).is_err() {
            let _ = file.set_len(size);
            return Err(Error::Disk);
        }
        self.count += 1;
        Ok(true)
    }

    /// Closes the session and queues it.
    pub fn stop(&mut self, reason: &str) -> Result<(), Error> {
        let Some(active) = self.active.take() else { return Ok(()) };
        let close = line(&json!({"type": "meta", "closed": timestamp(SystemTime::now()), "closed_reason": reason, "events": self.count}));
        let written = fs::OpenOptions::new().append(true).open(&active).and_then(|mut f| { f.write_all(&close)?; f.sync_all() });
        let moved = fs::rename(&active, self.queued_path(&active));
        if written.is_err() || moved.is_err() { return Err(Error::Disk); }
        Ok(())
    }

    /// The repository a queued journal was written for ("" when none was set).
    pub fn repo_of(file: &Path) -> Option<String> {
        let data = fs::read(file).ok()?;
        let first = data.split(|&b| b == b'\n').next()?;
        let meta: Value = serde_json::from_slice(first).ok()?;
        if meta["type"] != "meta" { return None; }
        Some(meta["target_repo"].as_str().unwrap_or("").to_string())
    }

    /// A sent journal stays here for a week, then goes.
    pub fn archive(&self, file: &Path) {
        let target = self.root.join("sent").join(file.file_name().unwrap_or_default());
        let _ = fs::remove_file(&target);
        let _ = fs::rename(file, &target);
        let now = SystemTime::now();
        for item in self.files("sent") {
            let old = fs::metadata(&item).and_then(|m| m.modified()).ok()
                .and_then(|t| now.duration_since(t).ok()).is_some_and(|age| age > KEEP_SENT);
            if old { let _ = fs::remove_file(&item); }
        }
    }
}

/// An authenticated HTTPS call to the GitHub API: `path` starts with `/`. Err: no answer.
pub trait Http {
    fn call(&mut self, method: &str, path: &str, body: Option<&str>) -> Result<(u16, Vec<u8>), ()>;
}

/// The id Git gives this content: what the contents API reports as `sha`.
pub fn git_blob_sha1(data: &[u8]) -> String {
    let mut message = format!("blob {}\0", data.len()).into_bytes();
    message.extend_from_slice(data);
    sha1(&message).iter().map(|b| format!("{b:02x}")).collect()
}

fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 { message.push(0); }
    message.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for block in message.chunks(64) {
        let mut w = [0u32; 80];
        for i in 0..16 { w[i] = u32::from_be_bytes([block[4 * i], block[4 * i + 1], block[4 * i + 2], block[4 * i + 3]]); }
        for i in 16..80 { w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1); }
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | (!b & d), 0x5A82_7999),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6),
            };
            let t = a.rotate_left(5).wrapping_add(f).wrapping_add(e).wrapping_add(k).wrapping_add(wi);
            e = d; d = c; c = b.rotate_left(30); b = a; a = t;
        }
        for (x, y) in h.iter_mut().zip([a, b, c, d, e]) { *x = x.wrapping_add(y); }
    }
    let mut out = [0u8; 20];
    for (i, v) in h.iter().enumerate() { out[4 * i..4 * i + 4].copy_from_slice(&v.to_be_bytes()); }
    out
}

pub fn base64(data: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let n = (u32::from(chunk[0]) << 16) | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8) | u32::from(*chunk.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= chunk.len() { out.push(A[(n >> (18 - 6 * i) & 63) as usize] as char); } else { out.push('='); }
        }
    }
    out
}

fn json_of(body: &[u8]) -> Value { serde_json::from_slice(body).unwrap_or(Value::Null) }

fn private(http: &mut dyn Http, repo: &str) -> Result<(), Error> {
    let (status, body) = http.call("GET", &format!("/repos/{repo}"), None).map_err(|_| Error::Network)?;
    match status {
        401 | 403 | 404 => Err(Error::Authorization),
        200 => match json_of(&body).get("private") {
            Some(Value::Bool(true)) => Ok(()),
            Some(_) => Err(Error::PublicRepo),
            None => Err(Error::Network),
        },
        _ => Err(Error::Network),
    }
}

/// The blob id of the file there now, None when there is none.
fn existing(http: &mut dyn Http, repo: &str, path: &str, at: Option<&str>) -> Result<Option<String>, Error> {
    let query = at.map(|r| format!("?ref={r}")).unwrap_or_default();
    let (status, body) = http.call("GET", &format!("/repos/{repo}/contents/{path}{query}"), None).map_err(|_| Error::Network)?;
    match status {
        404 => Ok(None),
        200 => json_of(&body).get("sha").and_then(Value::as_str).map(|s| Some(s.to_string())).ok_or(Error::Network),
        401 | 403 => Err(Error::Authorization),
        _ => Err(Error::Network),
    }
}

/// Commits `data` as `path` in `repo`. Sending the same journal again is harmless.
pub fn deliver(http: &mut dyn Http, repo: &str, path: &str, data: &[u8]) -> Result<(), Error> {
    if !valid_repo(repo) { return Err(Error::Configuration); }
    let blob = git_blob_sha1(data);
    private(http, repo)?;
    match existing(http, repo, path, None)? {
        Some(sha) if sha == blob => return Ok(()),
        Some(_) => return Err(Error::Conflict),
        None => {}
    }
    private(http, repo)?;
    let name = path.rsplit('/').next().unwrap_or(path);
    let body = json!({"message": format!("Diagnostic journal {name}"), "content": base64(data)}).to_string();
    let (status, answer) = http.call("PUT", &format!("/repos/{repo}/contents/{path}"), Some(&body)).map_err(|_| Error::Network)?;
    match status {
        200 | 201 => {}
        401 | 403 => return Err(Error::Authorization),
        409 | 422 => return if existing(http, repo, path, None)?.as_deref() == Some(blob.as_str()) { Ok(()) } else { Err(Error::Conflict) },
        _ => return Err(Error::Network),
    }
    let commit = json_of(&answer)["commit"]["sha"].as_str().map(str::to_string).ok_or(Error::Network)?;
    if existing(http, repo, path, Some(&commit))?.as_deref() != Some(blob.as_str()) { return Err(Error::Network); }
    Ok(())
}

/// What the window and the tray menu show.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct State {
    pub enabled: bool,
    pub events: u64,
    pub queued: usize,
    pub has_token: bool,
    pub busy: bool,
    pub repo: String,
    pub message: String,
}

impl State {
    pub fn can_send(&self) -> bool { self.has_token && valid_repo(&self.repo) }
}

/// One session at a time, run on its own thread by the app: every call may touch the disk
/// or the network. Each returns the message the person should see now, if any.
pub struct Service {
    journal: Option<Journal>,
    pub state: State,
    write_error_shown: bool,
}

impl Service {
    pub fn new(root: &Path, repo: String, has_token: bool) -> Service {
        let mut journal = Journal::open(root).ok();
        if let Some(j) = journal.as_mut() { j.recover(); }
        let queued = journal.as_ref().map_or(0, |j| j.files("queue").len());
        let message = if journal.is_none() { Error::Disk.message().to_string() } else { String::new() };
        Service { journal, state: State { repo, has_token, queued, message, ..State::default() }, write_error_shown: false }
    }

    pub fn root(&self) -> Option<&Path> { self.journal.as_ref().map(Journal::root) }

    fn report(&mut self, text: String) -> Option<String> {
        self.state.message = text.clone();
        Some(text)
    }

    /// Starts a session; the person has already agreed to the warning. `session` is the
    /// app's state, written as the first event.
    pub fn start(&mut self, versions: Value, session: Map<String, Value>, seed: u64) -> Option<String> {
        if self.state.enabled { return None; }
        let repo = if self.state.can_send() { self.state.repo.clone() } else { String::new() };
        let Some(journal) = self.journal.as_mut() else { return self.report(Error::Disk.message().into()) };
        if let Err(e) = journal.stop("restarted").and_then(|_| journal.start(&repo, versions, seed)) {
            return self.report(e.message().into());
        }
        self.write_error_shown = false;
        self.state.enabled = true;
        self.state.events = 0;
        self.state.message = "Диагностика включена. Напечатайте текст там, где Ясно не срабатывает, потом выключите её.".into();
        let mut row = session;
        row.insert("event".into(), "session".into());
        self.record(row);
        None
    }

    /// Writes one event of the open session.
    pub fn record(&mut self, row: Map<String, Value>) -> Option<String> {
        if !self.state.enabled { return None; }
        let result = self.journal.as_mut().map_or(Err(Error::Disk), |j| j.record(row));
        match result {
            Ok(true) => { self.state.events += 1; None }
            Ok(false) => None,
            Err(e) if !self.write_error_shown => { self.write_error_shown = true; self.report(e.message().into()) }
            Err(_) => None,
        }
    }

    /// Closes the session; `send` with `http` when a token and a repository are set.
    /// `why` goes into the journal; `note` opens the message (the time limit).
    pub fn stop(&mut self, why: &str, note: Option<&str>, http: Option<&mut dyn Http>) -> Option<String> {
        if !self.state.enabled { return None; }
        self.state.enabled = false;
        let failed = self.journal.as_mut().map_or(Err(Error::Disk), |j| j.stop(why)).is_err();
        self.state.queued = self.journal.as_ref().map_or(0, |j| j.files("queue").len());
        if failed { return self.report(Error::Disk.message().into()); }
        match http {
            Some(http) if self.state.can_send() => self.flush(http, note),
            _ => {
                let saved = "Журнал сохранён на этом компьютере (окно Ясно → «Диагностика…» → «Показать журналы»).";
                self.report(note.map_or(saved.to_string(), |n| format!("{n} {saved}")))
            }
        }
    }

    /// Sends every closed journal still here.
    pub fn flush(&mut self, http: &mut dyn Http, note: Option<&str>) -> Option<String> {
        let Some(journal) = self.journal.as_ref() else { return None };
        if !self.state.can_send() { return self.report(Error::Configuration.message().into()); }
        let fallback = self.state.repo.clone();
        let mut sent = 0;
        let mut failure = None;
        for file in journal.files("queue") {
            let target = Journal::repo_of(&file).filter(|r| !r.is_empty()).unwrap_or_else(|| fallback.clone());
            let name = file.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
            let result = fs::read(&file).map_err(|_| Error::Disk)
                .and_then(|data| deliver(http, &target, &format!("logs/windows/{name}"), &data));
            match result {
                Ok(()) => { journal.archive(&file); sent += 1; }
                Err(e) => { failure = Some(e); break; }
            }
        }
        self.state.queued = journal.files("queue").len();
        let result = match failure {
            Some(e) => e.message().to_string(),
            None if sent == 0 => "Отправлять нечего.".into(),
            None => format!("Журнал отправлен в {fallback}."),
        };
        self.report(note.map_or(result.clone(), |n| format!("{n} {result}")))
    }
}
