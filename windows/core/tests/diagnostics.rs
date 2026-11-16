//! The diagnostic journal and its delivery, against a fake GitHub API.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, UNIX_EPOCH};

use serde_json::{json, Map, Value};
use yasno_core::diagnostics::*;

fn folder(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("yasno-diag-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn row(v: Value) -> Map<String, Value> { v.as_object().unwrap().clone() }

fn lines(file: &std::path::Path) -> Vec<Value> {
    std::fs::read_to_string(file).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect()
}

#[test]
fn hashes_encodings_and_times_match_git_and_the_mac() {
    assert_eq!(git_blob_sha1(b"hello\n"), "ce013625030ba8dba906f756967f9e9ca394464a");
    let data: Vec<u8> = (0..300).flat_map(|_| 0u8..=255).collect();
    assert_eq!(git_blob_sha1(&data), "b0ae7e65ee352e982340b7abfee52b373b6d1673");
    assert_eq!(base64(b""), "");
    assert_eq!(base64(b"f"), "Zg==");
    assert_eq!(base64(b"fo"), "Zm8=");
    assert_eq!(base64(b"foo"), "Zm9v");
    assert_eq!(base64("привет".as_bytes()), "0L/RgNC40LLQtdGC");
    assert_eq!(timestamp(UNIX_EPOCH + Duration::from_secs(1_763_294_096)), "2025-11-16T11:54:56Z");
    assert_eq!(timestamp(UNIX_EPOCH + Duration::from_secs(951_782_400 + 86_399)), "2000-02-29T23:59:59Z");
    let id = new_id(1);
    assert_eq!(id.len(), 36);
    assert_ne!(id, new_id(1));
    assert!(valid_repo(DEFAULT_REPO));
    for bad in ["", "owner", "/name", "owner/", "a/b/c", "a/..b", "-a/b", "a b/c", "a/b?x"] { assert!(!valid_repo(bad), "{bad}"); }
    assert!(valid_token("github_pat_0123456789abcdef"));
    assert!(!valid_token("short") && !valid_token("with space 0123456789"));
}

#[test]
fn a_session_is_written_closed_and_queued() {
    let root = folder("session");
    let mut journal = Journal::open(&root).unwrap();
    journal.start("owner/logs", json!({"app": "0.2.1"}), 7).unwrap();
    assert!(journal.record(row(json!({"event": "word", "text": "ghbdtn"}))).unwrap());
    journal.stop("user").unwrap();
    assert!(!journal.record(row(json!({"event": "late"}))).unwrap());
    let queued = journal.files("queue");
    assert_eq!(queued.len(), 1);
    assert!(journal.files("sessions").is_empty());
    let rows = lines(&queued[0]);
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[0]["type"], "meta");
    assert_eq!(rows[0]["platform"], "windows");
    assert_eq!(rows[0]["schema"], 1);
    assert_eq!(rows[0]["versions"]["app"], "0.2.1");
    assert_eq!(rows[1]["type"], "event");
    assert_eq!(rows[1]["event"], "word");
    assert!(rows[1]["ts"].as_str().unwrap().ends_with('Z'));
    assert_eq!(rows[2]["closed_reason"], "user");
    assert_eq!(rows[2]["events"], 1);
    assert_eq!(Journal::repo_of(&queued[0]).as_deref(), Some("owner/logs"));
    let name = format!("{}.jsonl", rows[0]["session_id"].as_str().unwrap());
    assert_eq!(queued[0].file_name().unwrap().to_str().unwrap(), name);
    journal.archive(&queued[0]);
    assert!(journal.files("queue").is_empty());
    assert_eq!(journal.files("sent").len(), 1);
}

#[test]
fn a_full_journal_stops_growing_and_an_interrupted_one_is_closed() {
    let root = folder("limit");
    let mut journal = Journal::open(&root).unwrap();
    journal.start("", json!({}), 1).unwrap();
    let big = "x".repeat(10_000);
    let mut result = Ok(true);
    for _ in 0..200 { result = journal.record(row(json!({"text": big}))); if result.is_err() { break; } }
    assert_eq!(result, Err(Error::Limit));
    let file = journal.files("sessions")[0].clone();
    assert!(std::fs::metadata(&file).unwrap().len() <= MAX_SESSION_BYTES);
    // Yasno stops here, in the middle of a line.
    let mut data = std::fs::read(&file).unwrap();
    data.extend_from_slice(b"{\"cut");
    std::fs::write(&file, data).unwrap();
    let mut next = Journal::open(&root).unwrap();
    next.recover();
    let queued = next.files("queue");
    assert_eq!(queued.len(), 1);
    let rows = lines(&queued[0]);
    assert_eq!(rows.last().unwrap()["closed_reason"], "interrupted");
}

#[test]
fn typed_text_is_replaced_in_a_secret_field() {
    let mut r = row(json!({"text": "hunter2", "replacement": "руттук2", "suffix": " ", "reason": "dead key", "deletions": 3}));
    redact(&mut r, SECRET);
    assert_eq!(r["text"], SECRET);
    assert_eq!(r["replacement"], SECRET);
    assert_eq!(r["suffix"], SECRET);
    assert_eq!(r["reason"], "dead key");
    assert_eq!(r["deletions"], 3);
}

/// GitHub's contents API, as far as delivery uses it.
#[derive(Default)]
struct Fake {
    private: Option<bool>,
    files: HashMap<String, Vec<u8>>,
    commits: HashMap<String, HashMap<String, Vec<u8>>>,
    calls: Vec<String>,
    offline: bool,
}

impl Http for Fake {
    fn call(&mut self, method: &str, path: &str, body: Option<&str>) -> Result<(u16, Vec<u8>), ()> {
        if self.offline { return Err(()); }
        self.calls.push(format!("{method} {path}"));
        let ok = |v: Value| Ok((200, v.to_string().into_bytes()));
        let Some(rest) = path.strip_prefix("/repos/owner/logs") else { return Ok((404, b"{}".to_vec())) };
        if rest.is_empty() {
            return match self.private { Some(p) => ok(json!({"private": p})), None => Ok((404, b"{}".to_vec())) };
        }
        let rest = rest.strip_prefix("/contents/").unwrap();
        let (file, at) = rest.split_once("?ref=").map_or((rest, None), |(f, r)| (f, Some(r)));
        match method {
            "GET" => {
                let store = match at { Some(r) => self.commits.get(r).cloned().unwrap_or_default(), None => self.files.clone() };
                match store.get(file) { Some(d) => ok(json!({"sha": git_blob_sha1(d)})), None => Ok((404, b"{}".to_vec())) }
            }
            "PUT" => {
                let body: Value = serde_json::from_str(body.unwrap()).unwrap();
                assert!(body["message"].as_str().unwrap().starts_with("Diagnostic journal "));
                let content = body["content"].as_str().unwrap().to_string();
                self.files.insert(file.to_string(), decode(&content));
                let commit = format!("c{}", self.commits.len());
                self.commits.insert(commit.clone(), self.files.clone());
                Ok((201, json!({"commit": {"sha": commit}}).to_string().into_bytes()))
            }
            _ => Ok((405, Vec::new())),
        }
    }
}

fn decode(s: &str) -> Vec<u8> {
    const A: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut bits = 0u32;
    let mut n = 0;
    let mut out = Vec::new();
    for c in s.chars().filter(|&c| c != '=') {
        bits = (bits << 6) | A.find(c).unwrap() as u32;
        n += 6;
        if n >= 8 { n -= 8; out.push((bits >> n) as u8); }
    }
    out
}

#[test]
fn a_journal_goes_only_to_a_private_repository_and_is_read_back() {
    let data = "{\"type\":\"meta\"}\nпривет\n".as_bytes();
    let path = "logs/windows/s.jsonl";
    let mut public = Fake { private: Some(false), ..Fake::default() };
    assert_eq!(deliver(&mut public, "owner/logs", path, data), Err(Error::PublicRepo));
    assert!(public.files.is_empty());
    let mut unknown = Fake::default();
    assert_eq!(deliver(&mut unknown, "owner/logs", path, data), Err(Error::Authorization));
    let mut offline = Fake { offline: true, ..Fake::default() };
    assert_eq!(deliver(&mut offline, "owner/logs", path, data), Err(Error::Network));
    assert_eq!(deliver(&mut Fake::default(), "not a repo", path, data), Err(Error::Configuration));

    let mut github = Fake { private: Some(true), ..Fake::default() };
    assert_eq!(deliver(&mut github, "owner/logs", path, data), Ok(()));
    assert_eq!(github.files[path], data);
    assert_eq!(github.calls, vec!["GET /repos/owner/logs", "GET /repos/owner/logs/contents/logs/windows/s.jsonl",
                                  "GET /repos/owner/logs", "PUT /repos/owner/logs/contents/logs/windows/s.jsonl",
                                  "GET /repos/owner/logs/contents/logs/windows/s.jsonl?ref=c0"]);
    // Sent again (the answer was lost): nothing new is written.
    github.calls.clear();
    assert_eq!(deliver(&mut github, "owner/logs", path, data), Ok(()));
    assert!(!github.calls.iter().any(|c| c.starts_with("PUT")));
    assert_eq!(deliver(&mut github, "owner/logs", path, b"other"), Err(Error::Conflict));
}

#[test]
fn the_service_sends_a_finished_session_or_keeps_it() {
    let root = folder("service");
    let mut service = Service::new(&root, "owner/logs".into(), true);
    assert_eq!(service.start(json!({"app": "test"}), row(json!({"layouts": ["00000409"]})), 3), None);
    assert!(service.state.enabled);
    service.record(row(json!({"event": "word", "text": "ghbdtn"})));
    assert_eq!(service.state.events, 2);
    let mut github = Fake { private: Some(true), ..Fake::default() };
    let message = service.stop("user", None, Some(&mut github)).unwrap();
    assert_eq!(message, "Журнал отправлен в owner/logs.");
    assert!(!service.state.enabled);
    assert_eq!(service.state.queued, 0);
    let (name, data) = github.files.iter().next().unwrap();
    assert!(name.starts_with("logs/windows/") && name.ends_with(".jsonl"));
    let text = String::from_utf8(data.clone()).unwrap();
    let events: Vec<Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(events[1]["event"], "session");
    assert_eq!(events[1]["layouts"][0], "00000409");
    assert_eq!(events[2]["text"], "ghbdtn");
    assert_eq!(events[3]["closed_reason"], "user");

    // Without a token the journal stays; a later send takes it.
    let mut local = Service::new(&folder("local"), "owner/logs".into(), false);
    local.start(json!({}), Map::new(), 4);
    let message = local.stop("time limit", Some("Диагностика выключилась сама через 30 минут."), None).unwrap();
    assert!(message.starts_with("Диагностика выключилась сама через 30 минут. Журнал сохранён"), "{message}");
    assert_eq!(local.state.queued, 1);
    local.state.has_token = true;
    let mut offline = Fake { offline: true, ..Fake::default() };
    assert_eq!(local.flush(&mut offline, None).unwrap(), Error::Network.message());
    assert_eq!(local.state.queued, 1);
    let mut github = Fake { private: Some(true), ..Fake::default() };
    assert_eq!(local.flush(&mut github, None).unwrap(), "Журнал отправлен в owner/logs.");
    assert_eq!(local.state.queued, 0);
    assert_eq!(local.flush(&mut github, None).unwrap(), "Отправлять нечего.");
}
