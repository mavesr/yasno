//! First start: Yasno copies itself to %LOCALAPPDATA%\Programs\Yasno, where it can update
//! itself without administrator rights, adds itself to the Start menu and to sign-in, and
//! starts from there. A copy started from Downloads therefore never stays the one running.

use std::path::{Path, PathBuf};

pub fn directory() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("Programs").join("Yasno"))
}

pub fn installed_exe() -> Option<PathBuf> { directory().map(|d| d.join("yasno.exe")) }

fn same(a: &Path, b: &Path) -> bool {
    a.to_string_lossy().to_lowercase() == b.to_string_lossy().to_lowercase()
}

pub fn is_installed_copy() -> bool {
    match (std::env::current_exe(), installed_exe()) { (Ok(a), Some(b)) => same(&a, &b), _ => true }
}

/// Copy this executable into place. An older installed copy that is running keeps its file
/// open: it is renamed aside first, as the updater does.
pub fn install() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let dir = directory().ok_or("LOCALAPPDATA")?;
    let target = dir.join("yasno.exe");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    if target.exists() {
        let old = dir.join("yasno.old.exe");
        let _ = std::fs::remove_file(&old);
        if std::fs::remove_file(&target).is_err() { std::fs::rename(&target, &old).map_err(|e| e.to_string())?; }
    }
    std::fs::copy(&exe, &target).map_err(|e| e.to_string())?;
    let _ = shortcut(&target);
    Ok(target)
}

/// «Ясно» in the Start menu.
fn shortcut(target: &Path) -> windows::core::Result<()> {
    use windows::core::{Interface, HSTRING};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, IPersistFile, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED};
    use windows::Win32::UI::Shell::{IShellLinkW, ShellLink};
    let Some(appdata) = std::env::var_os("APPDATA") else { return Ok(()) };
    let link = PathBuf::from(appdata).join("Microsoft\\Windows\\Start Menu\\Programs\\Ясно.lnk");
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let shell: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
        shell.SetPath(&HSTRING::from(target.as_os_str()))?;
        shell.SetDescription(&HSTRING::from("Ясно — переключатель раскладки"))?;
        let file: IPersistFile = shell.cast()?;
        file.Save(&HSTRING::from(link.as_os_str()), true)?;
    }
    Ok(())
}
