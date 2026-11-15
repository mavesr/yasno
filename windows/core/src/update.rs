//! Self-update from GitHub Releases, the rules of the Mac `Updater` for Windows builds.
//!
//! The Mac updater reads `releases/latest`. Windows releases are tagged `win-v…` and never
//! marked latest, so the two never see each other's builds: this side lists the releases
//! and takes the newest published `win-v` one with its executable.

use serde_json::Value;

pub const REPOSITORY: &str = "mavesr/yasno";
pub const TAG_PREFIX: &str = "win-v";
/// The local hour of the daily check, as on the Mac.
pub const CHECK_HOUR: u64 = 21;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Release {
    pub version: String,
    pub exe: String,
    /// SHA-256 of the executable, a file next to it in the release.
    pub checksum: String,
}

pub fn asset_name(version: &str) -> String { format!("yasno-{version}-x64.exe") }

pub fn releases_url() -> String { format!("https://api.github.com/repos/{REPOSITORY}/releases?per_page=30") }

pub fn components(version: &str) -> Option<Vec<u64>> {
    let parts: Vec<Option<u64>> = version.split('.').map(|p| p.parse().ok()).collect();
    if parts.is_empty() || parts.iter().any(Option::is_none) { return None; }
    Some(parts.into_iter().map(Option::unwrap).collect())
}

pub fn is_newer(candidate: &str, current: &str) -> bool {
    let (Some(new), Some(old)) = (components(candidate), components(current)) else { return false };
    for i in 0..new.len().max(old.len()) {
        let (a, b) = (new.get(i).copied().unwrap_or(0), old.get(i).copied().unwrap_or(0));
        if a != b { return a > b; }
    }
    false
}

fn release(object: &Value) -> Option<Release> {
    if object["draft"].as_bool() == Some(true) || object["prerelease"].as_bool() == Some(true) { return None; }
    let version = object["tag_name"].as_str()?.strip_prefix(TAG_PREFIX)?.to_string();
    components(&version)?;
    let assets = object["assets"].as_array()?;
    let url = |name: &str| assets.iter()
        .find(|a| a["name"].as_str() == Some(name))
        .and_then(|a| a["browser_download_url"].as_str())
        .filter(|u| u.starts_with("https://"))
        .map(str::to_string);
    let name = asset_name(&version);
    Some(Release { exe: url(&name)?, checksum: url(&format!("{name}.sha256"))?, version })
}

/// The newest Windows release newer than `current` in a GitHub releases listing.
pub fn newest(json: &str, current: &str) -> Result<Option<Release>, String> {
    let value: Value = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let list = value.as_array().ok_or("not a list of releases")?;
    let mut best: Option<Release> = None;
    for r in list.iter().filter_map(release) {
        if is_newer(&r.version, current) && best.as_ref().is_none_or(|b| is_newer(&r.version, &b.version)) { best = Some(r); }
    }
    Ok(best)
}

/// The checksum file holds the hex digest, optionally followed by the file name.
pub fn parse_checksum(text: &str) -> Option<String> {
    let digest = text.split_whitespace().next()?.to_ascii_lowercase();
    (digest.len() == 64 && digest.chars().all(|c| c.is_ascii_hexdigit())).then_some(digest)
}

const DAY: i64 = 86_400;

/// The latest `CHECK_HOUR`:00 local at or before `now` (Unix seconds, `offset` east of UTC).
fn latest_check(now: i64, offset: i64) -> i64 {
    let local = now + offset;
    let mut at = local - local.rem_euclid(DAY) + CHECK_HOUR as i64 * 3600;
    if at > local { at -= DAY; }
    at - offset
}

/// The first `CHECK_HOUR`:00 local strictly after `now`.
pub fn next_check(now: i64, offset: i64) -> i64 { latest_check(now, offset) + DAY }

/// A check at `CHECK_HOUR`:00 was missed: the computer was off or Yasno was not running.
pub fn missed_check(last: Option<i64>, now: i64, offset: i64) -> bool {
    last.is_none_or(|last| last < latest_check(now, offset))
}
