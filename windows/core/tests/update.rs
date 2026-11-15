use yasno_core::update::*;

fn release(tag: &str, assets: &[&str], draft: bool) -> String {
    let assets: Vec<String> = assets.iter().map(|n| format!(
        r#"{{"name":"{n}","browser_download_url":"https://github.com/mavesr/yasno/releases/download/{tag}/{n}"}}"#)).collect();
    format!(r#"{{"tag_name":"{tag}","draft":{draft},"prerelease":false,"assets":[{}]}}"#, assets.join(","))
}

#[test]
fn only_windows_releases_with_an_executable_and_checksum_are_taken() {
    let list = format!("[{},{},{},{},{}]",
        release("v0.2.27", &["Yasno-0.2.27.zip"], false),
        release("win-v0.3.0", &["yasno-0.3.0-x64.exe"], false), // no checksum
        release("win-v0.2.1", &["yasno-0.2.1-x64.exe", "yasno-0.2.1-x64.exe.sha256"], false),
        release("win-v0.2.5", &["yasno-0.2.5-x64.exe", "yasno-0.2.5-x64.exe.sha256"], true), // draft
        release("win-v0.2.2", &["yasno-0.2.2-x64.exe", "yasno-0.2.2-x64.exe.sha256"], false));
    let r = newest(&list, "0.2.0").unwrap().unwrap();
    assert_eq!(r.version, "0.2.2");
    assert!(r.exe.ends_with("/win-v0.2.2/yasno-0.2.2-x64.exe"));
    assert!(r.checksum.ends_with(".sha256"));
    assert_eq!(newest(&list, "0.2.2").unwrap(), None);
    assert_eq!(newest("[]", "0.2.0").unwrap(), None);
    assert!(newest("{}", "0.2.0").is_err());
}

#[test]
fn versions_compare_by_number() {
    assert!(is_newer("0.2.10", "0.2.9"));
    assert!(is_newer("1.0", "0.9.9"));
    assert!(!is_newer("0.2.0", "0.2"));
    assert!(!is_newer("0.2.x", "0.1"));
}

#[test]
fn checksum_file_formats() {
    let d = "A".repeat(64);
    assert_eq!(parse_checksum(&format!("{d}  yasno-0.2.0-x64.exe\n")), Some("a".repeat(64)));
    assert_eq!(parse_checksum("abc"), None);
}

#[test]
fn the_daily_check_is_at_nine_in_the_evening_local_time() {
    let offset = 3 * 3600; // Kyiv in winter is +2, Moscow +3: any offset works.
    // 2026-11-15 10:00 local.
    let morning = 1_763_190_000 - 1_763_190_000 % 86_400 + 10 * 3600 - offset;
    let next = next_check(morning, offset);
    assert_eq!((next + offset) % 86_400, 21 * 3600);
    assert_eq!(next - morning, 11 * 3600);
    // At 21:30 the next is tomorrow.
    let late = morning + 11 * 3600 + 1800;
    assert_eq!(next_check(late, offset) - late, 23 * 3600 + 1800);
    // Last checked yesterday at 21:00 and it is 10:00: nothing missed. At 21:30: missed.
    let yesterday = next - 86_400;
    assert!(!missed_check(Some(yesterday), morning, offset));
    assert!(missed_check(Some(yesterday), late, offset));
    assert!(missed_check(None, morning, offset));
}
