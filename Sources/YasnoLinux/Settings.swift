import Foundation

/// Preferences in ~/.config/yasno/settings.json (the Linux counterpart of UserDefaults).
public final class Settings {
    public struct Values: Codable, Equatable {
        public var enabled = true
        public var correctSpelling = true
        public var ignoredWords = ""
        public var excludedApps: [String: String] = Settings.defaultExcludedApps
        public var preferredLayouts: [String: String] = [:]
        public var lastManualCyrillic: String?
        public var automaticUpdates = true
        public var lastUpdateCheck: Date?
        public init() {}
    }

    /// Terminals and password managers, by the identifiers GNOME (desktop file) and X11/Wayland
    /// (window class) give them. Compared without case and without ".desktop".
    public static let defaultExcludedApps: [String: String] = [
        "org.gnome.terminal": "Терминал GNOME", "gnome-terminal-server": "Терминал GNOME", "org.gnome.ptyxis": "Ptyxis",
        "org.gnome.console": "Консоль GNOME", "kgx": "Консоль GNOME", "org.kde.konsole": "Konsole", "konsole": "Konsole",
        "xfce4-terminal": "Терминал Xfce", "kitty": "kitty", "alacritty": "Alacritty", "org.wezfurlong.wezterm": "WezTerm",
        "com.mitchellh.ghostty": "Ghostty", "tilix": "Tilix", "com.gexperts.tilix": "Tilix", "terminator": "Terminator",
        "xterm": "XTerm", "foot": "foot", "1password": "1Password", "org.keepassxc.keepassxc": "KeePassXC", "keepassxc": "KeePassXC",
        "io.github.mavesr.yasno": "Ясно", "yasno": "Ясно",
    ]

    public static func normalize(_ id: String) -> String {
        var value = id.lowercased()
        if value.hasSuffix(".desktop") { value.removeLast(8) }
        return value
    }

    let url: URL
    private(set) public var values: Values
    private let lock = NSLock()

    public init(url: URL = Settings.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let decoded = try? Settings.decoder.decode(Values.self, from: data) {
            values = decoded
        } else { values = Values() }
    }

    public static var configDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let base = environment["XDG_CONFIG_HOME"], !base.isEmpty { return URL(fileURLWithPath: base).appendingPathComponent("yasno") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/yasno")
    }
    public static var defaultURL: URL { configDirectory.appendingPathComponent("settings.json") }

    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()

    public func update(_ change: (inout Values) -> Void) {
        lock.lock()
        change(&values)
        let snapshot = values
        lock.unlock()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Settings.encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }

    public func isExcluded(_ app: String) -> Bool {
        guard !app.isEmpty else { return false }
        let id = Self.normalize(app)
        return values.excludedApps.keys.contains { Self.normalize($0) == id }
    }
}
