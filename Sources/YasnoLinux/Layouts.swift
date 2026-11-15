import Foundation
import SwitchCore
import CYasnoLinux

/// One layout of the desktop's list, as XKB names it.
public struct LayoutSpec: Equatable {
    public let layout: String   // "ru"
    public let variant: String  // "" or "phonetic"
    public let name: String     // what the desktop shows
    public init(layout: String, variant: String, name: String) { self.layout = layout; self.variant = variant; self.name = name }
    public var id: String { variant.isEmpty ? "xkb:\(layout)" : "xkb:\(layout)(\(variant))" }
}

public enum XkbTables {
    private static var cache: [String: KeyboardLayout] = [:]
    private static let lock = NSLock()

    /// The XKB keymap of the layout, read through libxkbcommon: the same tables the desktop uses.
    public static func layout(_ spec: LayoutSpec) -> KeyboardLayout? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[spec.id + "\u{1}" + spec.name] { return cached }
        var evdevForMac = [UInt16](repeating: 0, count: 128)
        for (mac, evdev) in KeyCodes.macToEvdev where mac < 128 { evdevForMac[Int(mac)] = evdev }
        var text = [CChar](repeating: 0, count: 1024 * 8)
        var dead = [UInt8](repeating: 0, count: 1024)
        guard yl_xkb_table(spec.layout, spec.variant, evdevForMac, &text, &dead) == 0 else { return nil }
        var table: [UInt16: String] = [:]
        var deadKeys: Set<UInt16> = []
        for position in 0..<1024 {
            let value = text.withUnsafeBufferPointer { buffer -> String in
                String(cString: buffer.baseAddress! + position * 8)
            }
            if !value.isEmpty { table[UInt16(position)] = value }
            if dead[position] != 0 { deadKeys.insert(UInt16(position)) }
        }
        let layout = KeyboardLayout(id: spec.id, name: spec.name, table: table, deadKeys: deadKeys)
        if let layout { cache[spec.id + "\u{1}" + spec.name] = layout }
        return layout
    }
}

/// Descriptions of XKB layouts ("Russian", "English (US)") as compositors such as Sway and
/// Hyprland report them, mapped back to layout codes through the XKB registry.
public enum XkbRegistry {
    public static let shared: [String: (layout: String, variant: String)] = load()

    static func load(path: String = "/usr/share/X11/xkb/rules/evdev.xml") -> [String: (layout: String, variant: String)] {
        guard let data = FileManager.default.contents(atPath: path), let xml = String(data: data, encoding: .utf8) else { return [:] }
        return parse(xml)
    }

    static func parse(_ xml: String) -> [String: (layout: String, variant: String)] {
        var result: [String: (layout: String, variant: String)] = [:]
        // <layout><configItem><name>ru</name>…<description>Russian</description>…</configItem>
        //   <variantList><variant><configItem><name>phonetic</name><description>Russian (phonetic)</description>
        let layouts = xml.components(separatedBy: "<layout>").dropFirst()
        for block in layouts {
            guard let name = first(tag: "name", in: block), let description = first(tag: "description", in: block) else { continue }
            result[description] = (name, "")
            for variant in block.components(separatedBy: "<variant>").dropFirst() {
                guard let variantName = first(tag: "name", in: variant), let variantDescription = first(tag: "description", in: variant) else { continue }
                result[variantDescription] = (name, variantName)
            }
        }
        return result
    }

    private static func first(tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"), let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// How the desktop lists and switches its layouts.
public protocol LayoutBackend: AnyObject {
    var name: String { get }
    func layouts() -> [LayoutSpec]
    func currentIndex() -> Int?
    func select(index: Int) -> Bool
    /// The window that takes the keys: (identifier, display name), when the desktop says.
    func focusedApplication() -> (id: String, name: String)?
    /// A password entry of the desktop itself has the keys, or the session is locked.
    func secure() -> Bool
}

public extension LayoutBackend {
    func secure() -> Bool { false }
}

// MARK: Process helper

enum Shell {
    /// Runs a program found in PATH and returns its standard output, or nil when it fails.
    static func run(_ arguments: [String], timeout: TimeInterval = 2) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        let reader = DispatchQueue(label: "yasno.shell")
        let done = DispatchSemaphore(value: 0)
        reader.async { output = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { process.terminate(); return nil }
        while process.isRunning && Date() < deadline { usleep(1000) }
        // terminationStatus of a process still running is a fatal error in Foundation.
        guard !process.isRunning else { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }
}

// MARK: GNOME (Wayland and X11), through the Yasno GNOME Shell extension

public final class GnomeBackend: LayoutBackend {
    public let name = "GNOME"
    static let bus = "org.gnome.Shell", path = "/io/github/mavesr/Yasno", interface = "io.github.mavesr.Yasno"
    public init() {}

    public static var available: Bool { call("Version") != nil }

    static func call(_ method: String, _ args: String? = nil) -> String? {
        var reply = [CChar](repeating: 0, count: 65536)
        guard yl_dbus_call(0, bus, path, interface, method, args, 1500, &reply, Int32(reply.count)) == 0 else { return nil }
        return String(cString: reply)
    }

    /// Replies are ('json',).
    static func json(_ method: String) -> Any? {
        guard let text = call(method), let string = GVariantText.firstString(text), let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    public func layouts() -> [LayoutSpec] {
        guard let items = Self.json("Sources") as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard (item["type"] as? String) == "xkb", let id = item["id"] as? String else { return nil }
            let parts = id.split(separator: "+", maxSplits: 1).map(String.init)
            return LayoutSpec(layout: parts[0], variant: parts.count > 1 ? parts[1] : "", name: item["name"] as? String ?? id)
        }
    }

    public func currentIndex() -> Int? {
        guard let state = Self.json("State") as? [String: Any] else { return nil }
        return state["current"] as? Int
    }

    public func select(index: Int) -> Bool {
        guard let reply = Self.call("Activate", "(uint32 \(index),)") else { return false }
        return reply.contains("true")
    }

    public func focusedApplication() -> (id: String, name: String)? {
        guard let state = Self.json("State") as? [String: Any], let id = state["app"] as? String, !id.isEmpty else { return nil }
        return (id, state["appName"] as? String ?? id)
    }

    public func secure() -> Bool {
        guard let state = Self.json("State") as? [String: Any] else { return false }
        return state["secret"] as? Bool == true || state["locked"] as? Bool == true
    }
}

// MARK: KDE Plasma (Wayland and X11)

public final class KdeBackend: LayoutBackend {
    public let name = "KDE Plasma"
    public init() {}
    static func call(_ method: String, _ args: String? = nil) -> String? {
        var reply = [CChar](repeating: 0, count: 16384)
        guard yl_dbus_call(0, "org.kde.keyboard", "/Layouts", "org.kde.KeyboardLayouts", method, args, 1500, &reply, Int32(reply.count)) == 0 else { return nil }
        return String(cString: reply)
    }
    public static var available: Bool { call("getLayout") != nil }

    public func layouts() -> [LayoutSpec] {
        // ([('us', '', 'English (US)'), ('ru', '', 'Russian')],)
        guard let text = Self.call("getLayoutsList") else { return [] }
        return GVariantText.tuples(text).compactMap { fields in
            guard fields.count >= 3 else { return nil }
            return LayoutSpec(layout: fields[0], variant: fields[1], name: fields[2])
        }
    }
    public func currentIndex() -> Int? {
        guard let text = Self.call("getLayout") else { return nil }
        return GVariantText.firstInteger(text)
    }
    public func select(index: Int) -> Bool {
        guard let reply = Self.call("setLayout", "(uint32 \(index),)") else { return false }
        return reply.contains("true")
    }
    public func focusedApplication() -> (id: String, name: String)? { nil }
}

// MARK: Sway

public final class SwayBackend: LayoutBackend {
    public let name = "Sway"
    public init() {}
    public static var available: Bool { ProcessInfo.processInfo.environment["SWAYSOCK"] != nil }
    private func keyboard() -> [String: Any]? {
        guard let text = Shell.run(["swaymsg", "-r", "-t", "get_inputs"]), let data = text.data(using: .utf8),
              let inputs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return inputs.first { ($0["type"] as? String) == "keyboard" && ($0["xkb_layout_names"] as? [String])?.isEmpty == false }
    }
    public func layouts() -> [LayoutSpec] {
        guard let names = keyboard()?["xkb_layout_names"] as? [String] else { return [] }
        return names.compactMap { name in XkbRegistry.shared[name].map { LayoutSpec(layout: $0.layout, variant: $0.variant, name: name) } }
    }
    public func currentIndex() -> Int? { keyboard()?["xkb_active_layout_index"] as? Int }
    public func select(index: Int) -> Bool { Shell.run(["swaymsg", "input", "type:keyboard", "xkb_switch_layout", String(index)]) != nil }
    public func focusedApplication() -> (id: String, name: String)? {
        guard let text = Shell.run(["swaymsg", "-r", "-t", "get_tree"]), let data = text.data(using: .utf8),
              let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func find(_ node: [String: Any]) -> [String: Any]? {
            if node["focused"] as? Bool == true { return node }
            for key in ["nodes", "floating_nodes"] {
                for child in node[key] as? [[String: Any]] ?? [] { if let hit = find(child) { return hit } }
            }
            return nil
        }
        guard let node = find(tree) else { return nil }
        let id = node["app_id"] as? String ?? ((node["window_properties"] as? [String: Any])?["class"] as? String) ?? ""
        return id.isEmpty ? nil : (id, id)
    }
}

// MARK: Hyprland

public final class HyprlandBackend: LayoutBackend {
    public let name = "Hyprland"
    public init() {}
    public static var available: Bool { ProcessInfo.processInfo.environment["HYPRLAND_INSTANCE_SIGNATURE"] != nil }
    private func keyboard() -> [String: Any]? {
        guard let text = Shell.run(["hyprctl", "devices", "-j"]), let data = text.data(using: .utf8),
              let devices = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keyboards = devices["keyboards"] as? [[String: Any]] else { return nil }
        return keyboards.first { $0["main"] as? Bool == true } ?? keyboards.first
    }
    public func layouts() -> [LayoutSpec] {
        guard let keyboard = keyboard(), let layouts = keyboard["layout"] as? String else { return [] }
        let variants = (keyboard["variant"] as? String ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return layouts.split(separator: ",").enumerated().map { index, layout in
            let variant = index < variants.count ? variants[index] : ""
            let name = XkbRegistry.shared.first { $0.value.layout == String(layout) && $0.value.variant == variant }?.key ?? String(layout)
            return LayoutSpec(layout: String(layout), variant: variant, name: name)
        }
    }
    public func currentIndex() -> Int? {
        guard let keyboard = keyboard() else { return nil }
        if let index = keyboard["active_layout_index"] as? Int { return index }
        guard let active = keyboard["active_keymap"] as? String else { return nil }
        return layouts().firstIndex { $0.name == active }
    }
    public func select(index: Int) -> Bool { Shell.run(["hyprctl", "switchxkblayout", "all", String(index)]) != nil }
    public func focusedApplication() -> (id: String, name: String)? {
        guard let text = Shell.run(["hyprctl", "activewindow", "-j"]), let data = text.data(using: .utf8),
              let window = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = window["class"] as? String, !id.isEmpty else { return nil }
        return (id, id)
    }
}

// MARK: X11 (XFCE, Cinnamon, MATE, i3, GNOME or KDE on Xorg)

public final class X11Backend: LayoutBackend {
    public let name = "X11"
    public init() {}
    public static var available: Bool { yl_x11_open() != 0 && !rules().layouts.isEmpty }

    /// _XKB_RULES_NAMES: rules, model, layout, variant, options.
    public static func rawRules() -> [String] {
        guard ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"] == nil else { return [] }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = Int(yl_x11_rules(&buffer, Int32(buffer.count)))
        guard length > 0 else { return [] }
        var fields: [String] = []
        var current: [UInt8] = []
        for index in 0..<length {
            let byte = UInt8(bitPattern: buffer[index])
            if byte == 0 { fields.append(String(decoding: current, as: UTF8.self)); current = [] } else { current.append(byte) }
        }
        if !current.isEmpty { fields.append(String(decoding: current, as: UTF8.self)) }
        while fields.count < 5 { fields.append("") }
        return fields
    }

    /// Xorg gives a newly added keyboard (Yasno's virtual one) the server's default layouts
    /// and publishes those. Desktops such as Xfce or Cinnamon set theirs again; a bare window
    /// manager configured with setxkbmap does not, so Yasno puts the user's set back.
    @discardableResult public static func restore(_ saved: [String]) -> Bool {
        guard saved.count >= 5, saved[2].contains(","), rawRules() != saved else { return false }
        var command = ["setxkbmap", "-rules", saved[0], "-layout", saved[2], "-variant", saved[3], "-option", ""]
        if !saved[1].isEmpty { command += ["-model", saved[1]] }
        if !saved[4].isEmpty { command += ["-option", saved[4]] }
        return Shell.run(command, timeout: 5) != nil
    }

    static func rules() -> (layouts: [String], variants: [String]) {
        let fields = rawRules()
        guard !fields.isEmpty else { return ([], []) }
        let layouts = fields.count > 2 ? fields[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init) : []
        let variants = fields.count > 3 ? fields[3].split(separator: ",", omittingEmptySubsequences: false).map(String.init) : []
        return (layouts.filter { !$0.isEmpty }, variants)
    }

    public func layouts() -> [LayoutSpec] {
        let rules = Self.rules()
        return rules.layouts.enumerated().map { index, layout in
            let variant = index < rules.variants.count ? rules.variants[index] : ""
            let name = XkbRegistry.shared.first { $0.value.layout == layout && $0.value.variant == variant }?.key ?? layout
            return LayoutSpec(layout: layout, variant: variant, name: name)
        }
    }
    public func currentIndex() -> Int? { let group = Int(yl_x11_group()); return group >= 0 ? group : nil }
    public func select(index: Int) -> Bool { yl_x11_lock_group(Int32(index)) == 0 && Int(yl_x11_group()) == index }
    public func focusedApplication() -> (id: String, name: String)? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard yl_x11_active_class(&buffer, Int32(buffer.count)) == 0 else { return nil }
        let id = String(cString: buffer)
        return id.isEmpty ? nil : (id, id)
    }
}

/// Minimal reader for the GVariant text that GIO prints.
enum GVariantText {
    static func strings(_ text: String) -> [String] {
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "'" || c == "\"" {
                var value = ""
                var j = text.index(after: index)
                while j < text.endIndex, text[j] != c {
                    if text[j] == "\\", text.index(after: j) < text.endIndex {
                        j = text.index(after: j)
                        let e = text[j]
                        value.append(e == "n" ? "\n" : e == "t" ? "\t" : e)
                    } else { value.append(text[j]) }
                    j = text.index(after: j)
                }
                result.append(value)
                index = j < text.endIndex ? text.index(after: j) : j
            } else { index = text.index(after: index) }
        }
        return result
    }
    static func firstString(_ text: String) -> String? { strings(text).first }
    static func firstInteger(_ text: String) -> Int? {
        let cleaned = text.replacingOccurrences(of: "uint32", with: "").replacingOccurrences(of: "int32", with: "")
        let digits = cleaned.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }
    /// Each parenthesized group of strings: [('a','b','c'), ('d','e','f')] → [[a,b,c],[d,e,f]].
    static func tuples(_ text: String) -> [[String]] {
        var inner = text
        if inner.hasPrefix("(") { inner.removeFirst() }
        var result: [[String]] = []
        var depth = 0, start: String.Index?
        var index = inner.startIndex
        var quote: Character?
        while index < inner.endIndex {
            let c = inner[index]
            if let q = quote { if c == "\\" { index = inner.index(after: index) } else if c == q { quote = nil } }
            else if c == "'" || c == "\"" { quote = c }
            else if c == "(" { depth += 1; if depth == 1 { start = index } }
            else if c == ")" { if depth == 1, let s = start { result.append(strings(String(inner[s...index]))) }; depth -= 1 }
            index = inner.index(after: index)
        }
        return result
    }
}

public enum Backends {
    /// The first backend that answers, in order of how well it knows the desktop.
    public static func detect() -> LayoutBackend? {
        let environment = ProcessInfo.processInfo.environment
        let desktop = (environment["XDG_CURRENT_DESKTOP"] ?? "").uppercased()
        if let forced = environment["YASNO_BACKEND"] {
            switch forced.lowercased() {
            case "gnome": return GnomeBackend()
            case "kde": return KdeBackend()
            case "sway": return SwayBackend()
            case "hyprland": return HyprlandBackend()
            case "x11": return X11Backend()
            default: break
            }
        }
        if desktop.contains("GNOME") || desktop.contains("UNITY") || desktop.contains("UBUNTU") || desktop.contains("POP") {
            if GnomeBackend.available { return GnomeBackend() }
        }
        if desktop.contains("KDE"), KdeBackend.available { return KdeBackend() }
        if SwayBackend.available { return SwayBackend() }
        if HyprlandBackend.available { return HyprlandBackend() }
        if GnomeBackend.available { return GnomeBackend() }
        if KdeBackend.available { return KdeBackend() }
        // GNOME on Wayland without the extension also answers X11 calls through Xwayland, but the
        // group there is not the desktop's layout: never use X11 under Wayland.
        if environment["WAYLAND_DISPLAY"] == nil, X11Backend.available { return X11Backend() }
        return nil
    }

    public static var isGnome: Bool {
        let desktop = (ProcessInfo.processInfo.environment["XDG_CURRENT_DESKTOP"] ?? "").uppercased()
        return desktop.contains("GNOME") || desktop.contains("UNITY") || desktop.contains("UBUNTU")
    }
}
