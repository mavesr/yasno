import Foundation
import CYasnoLinux

/// One-time system setup and the files of an installed copy.
public enum Setup {
    public static let rulesPath = "/etc/udev/rules.d/70-yasno.rules"
    public static let modulesPath = "/etc/modules-load.d/yasno.conf"
    public static let extensionUUID = "yasno@mavesr.github.io"
    public static let applicationID = "io.github.mavesr.Yasno"

    /// Keyboards, pointers and the virtual keyboard device belong to the person at the
    /// computer (logind sets the access when they log in), as Steam and keyd arrange it.
    public static let rules = """
    # Ясно (https://github.com/mavesr/yasno): keyboard access for the person at this computer.
    KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
    SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEYBOARD}=="1", TAG+="uaccess"
    SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_MOUSE}=="1", TAG+="uaccess"
    SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_TOUCHPAD}=="1", TAG+="uaccess"

    """

    /// Runs as root (through pkexec or sudo). Returns the exit status.
    public static func installPermissions() -> Int32 {
        guard getuid() == 0 else { fputs("Run as root: sudo yasno --setup-permissions\n", stderr); return 1 }
        do {
            try FileManager.default.createDirectory(atPath: "/etc/udev/rules.d", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: "/etc/modules-load.d", withIntermediateDirectories: true)
            try rules.write(toFile: rulesPath, atomically: true, encoding: .utf8)
            try "uinput\n".write(toFile: modulesPath, atomically: true, encoding: .utf8)
        } catch { fputs("Cannot write the udev rule: \(error)\n", stderr); return 2 }
        _ = Shell.run(["modprobe", "uinput"], timeout: 10)
        _ = Shell.run(["udevadm", "control", "--reload-rules"], timeout: 10)
        _ = Shell.run(["udevadm", "trigger", "--subsystem-match=input", "--subsystem-match=misc", "--action=change"], timeout: 20)
        _ = Shell.run(["udevadm", "settle", "--timeout=5"], timeout: 10)
        print("Ясно: keyboard access is set up.")
        return 0
    }

    public static func removePermissions() -> Int32 {
        guard getuid() == 0 else { return 1 }
        try? FileManager.default.removeItem(atPath: rulesPath)
        try? FileManager.default.removeItem(atPath: modulesPath)
        _ = Shell.run(["udevadm", "control", "--reload-rules"], timeout: 10)
        _ = Shell.run(["udevadm", "trigger", "--subsystem-match=input", "--subsystem-match=misc", "--action=change"], timeout: 20)
        return 0
    }

    public static var executable: String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? CommandLine.arguments[0]
    }

    /// Asks for the administrator password through the desktop (polkit) and sets up access.
    public static func requestPermissions() -> Bool {
        if let status = Shell.run(["pkexec", executable, "--setup-permissions"], timeout: 300) { _ = status; return true }
        return false
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var dataHome: URL {
        if let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !base.isEmpty { return URL(fileURLWithPath: base) }
        return home.appendingPathComponent(".local/share")
    }
    static var configHome: URL {
        if let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !base.isEmpty { return URL(fileURLWithPath: base) }
        return home.appendingPathComponent(".config")
    }

    // MARK: Start at login

    static var autostartFile: URL { configHome.appendingPathComponent("autostart/\(applicationID).desktop") }

    public static var loginEnabled: Bool { FileManager.default.fileExists(atPath: autostartFile.path) }

    public static func setLogin(_ on: Bool) {
        if on {
            let launcher = home.appendingPathComponent(".local/bin/yasno").path
            let exec = FileManager.default.isExecutableFile(atPath: launcher) ? launcher : executable
            let entry = """
            [Desktop Entry]
            Type=Application
            Name=Ясно
            Comment=Исправляет раскладку клавиатуры
            Exec=\(exec) --background
            Icon=yasno
            X-GNOME-Autostart-enabled=true
            NoDisplay=true

            """
            try? FileManager.default.createDirectory(at: autostartFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? entry.write(to: autostartFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: autostartFile)
        }
    }

    // MARK: GNOME extension

    static var extensionDirectory: URL { dataHome.appendingPathComponent("gnome-shell/extensions/\(extensionUUID)") }

    static func gnomeMajor() -> Int? {
        guard let text = Shell.run(["gnome-shell", "--version"], timeout: 5) else { return nil }
        let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }

    /// Copies the bundled extension for this GNOME version and turns it on. GNOME on Wayland
    /// loads a new extension at the next login. Returns false when there is nothing to install.
    @discardableResult public static func installGnomeExtension(resources: URL) -> Bool {
        let major = gnomeMajor() ?? 46
        let source = resources.appendingPathComponent("gnome-extension/\(major >= 45 ? "45" : "42")")
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.appendingPathComponent("extension.js").path) else { return false }
        try? manager.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        for name in ["extension.js", "metadata.json"] {
            let target = extensionDirectory.appendingPathComponent(name)
            let new = try? Data(contentsOf: source.appendingPathComponent(name))
            if let new, (try? Data(contentsOf: target)) != new {
                try? manager.removeItem(at: target)
                try? new.write(to: target)
            }
        }
        if Shell.run(["gnome-extensions", "enable", extensionUUID], timeout: 10) == nil {
            // Not loaded yet (Wayland): list it as enabled for the next login.
            if let current = Shell.run(["gsettings", "get", "org.gnome.shell", "enabled-extensions"], timeout: 5),
               !current.contains(extensionUUID) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                let list = trimmed.hasPrefix("@as") || trimmed == "[]" ? "['\(extensionUUID)']"
                    : trimmed.replacingOccurrences(of: "]", with: ", '\(extensionUUID)']")
                _ = Shell.run(["gsettings", "set", "org.gnome.shell", "enabled-extensions", list], timeout: 5)
            }
        }
        _ = Shell.run(["gsettings", "set", "org.gnome.shell", "disable-user-extensions", "false"], timeout: 5)
        return true
    }

    public static var gnomeExtensionInstalled: Bool {
        FileManager.default.fileExists(atPath: extensionDirectory.appendingPathComponent("extension.js").path)
    }

    /// The folder with resources shipped next to the binary (the GNOME extension, icons).
    public static var resources: URL { URL(fileURLWithPath: executable).deletingLastPathComponent() }
}
