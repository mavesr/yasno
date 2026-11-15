import Foundation
#if canImport(Carbon)
import Carbon
#endif

public enum Language: String, CaseIterable, Codable {
    case english = "en", german = "de", russian = "ru", ukrainian = "uk"
}

/// Uses the installed Apple keyboard tables; no hand-written QWERTY assumptions.
public final class KeyboardLayout {
    public struct KeyStroke: Equatable {
        public let key: UInt16
        public let shift: Bool
        public let capsLock: Bool
        public init(key: UInt16, shift: Bool = false, capsLock: Bool = false) {
            self.key = key; self.shift = shift; self.capsLock = capsLock
        }
    }
    public let id: String
    public let name: String
    public let languages: [Language]
    #if canImport(Carbon)
    public let source: TISInputSource
    private let data: CFData
    #endif
    private var forward: [UInt16: String] = [:]
    private var reverse: [String: UInt16] = [:]
    private var deadKeys: Set<UInt16> = []

    /// The languages a layout writes, from its identifier (an Apple input source ID or an
    /// XKB layout name such as "xkb:ru" or "xkb:us(intl)"). Nil: not a layout Yasno handles.
    public static func languages(forID id: String) -> [Language]? {
        let lower = id.lowercased()
        if lower.hasPrefix("xkb:") {
            let name = String(lower.dropFirst(4))
            let base = name.split(separator: "(").first.map(String.init) ?? name
            let variant = name.contains("(") ? String(name.split(separator: "(")[1].dropLast()) : ""
            switch base {
            case "ua": return [.ukrainian]
            case "ru": return [.russian]
            case "de", "at", "ch": return base == "ch" && variant.hasPrefix("fr") ? nil : [.german, .english]
            case "us", "gb":
                // Dvorak, Colemak and the like move letters: a key typed there is not a QWERTY slip.
                return ["", "intl", "alt-intl", "euro", "extd", "mac", "altgr-intl", "basic"].contains(variant) ? [.english, .german] : nil
            default: return nil
            }
        }
        if lower.contains("ukrainian") { return [.ukrainian] }
        if lower.contains("russian") { return [.russian] }
        if lower.contains("german") { return [.german, .english] }
        if ["com.apple.keylayout.ABC", "com.apple.keylayout.US", "com.apple.keylayout.British",
            "com.apple.keylayout.ABC-Extended", "com.apple.keylayout.USInternational-PC", "com.apple.keylayout.ABC-QWERTZ"].contains(id) {
            // Both languages can be written using the same Latin keyboard.
            return [.english, .german]
        }
        return nil
    }

    /// A layout from ready tables: position (key | 0x100 Shift | 0x200 Caps Lock) → text, and
    /// the positions that are dead keys. Used on Linux, where XKB supplies the tables.
    public init?(id: String, name: String, table: [UInt16: String], deadKeys dead: Set<UInt16> = []) {
        guard let languages = Self.languages(forID: id) else { return nil }
        self.id = id; self.name = name; self.languages = languages
        #if canImport(Carbon)
        return nil
        #else
        let mainKeys = Array(UInt16(0)...50) + [93, 94]
        let otherKeys = (UInt16(0)..<128).filter { !mainKeys.contains($0) }
        for keys in [mainKeys, otherKeys] {
          for shift in [false, true] {
            for key in keys {
              for capsLock in [false, true] {
                let position = key | (shift ? 0x100 : 0)
                let full = position | (capsLock ? 0x200 : 0)
                guard let value = table[full], !value.isEmpty,
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                else { continue }
                forward[full] = value
                if dead.contains(full) { deadKeys.insert(full) }
                if !capsLock, reverse[value] == nil { reverse[value] = position }
              }
            }
          }
        }
        apostropheGlyph = Self.apostrophe(forward: forward, reverse: reverse)
        #endif
    }

    #if canImport(Carbon)
    public init?(source: TISInputSource) {
        guard let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              let namePointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
        else { return nil }
        self.source = source
        id = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        name = Unmanaged<CFString>.fromOpaque(namePointer).takeUnretainedValue() as String
        data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue()
        guard let languages = Self.languages(forID: id) else { return nil }
        self.languages = languages

        let mainKeys = Array(UInt16(0)...50) + [93, 94]
        let otherKeys = (UInt16(0)..<128).filter { !mainKeys.contains($0) }
        for keys in [mainKeys, otherKeys] {
          for shift in [false, true] {
            for key in keys {
              // Caps Lock has its own table: on a Mac Shift does not invert it, and ß stays ß.
              for capsLock in [false, true] {
                guard let value = translate(key: key, shift: shift, capsLock: capsLock),
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                else { continue }
                let position = key | (shift ? 0x100 : 0)
                forward[position | (capsLock ? 0x200 : 0)] = value
                if isDead(key: key, shift: shift, capsLock: capsLock) { deadKeys.insert(position | (capsLock ? 0x200 : 0)) }
                // Prefer the main keyboard, including its shifted symbols, before the keypad.
                if !capsLock, reverse[value] == nil { reverse[value] = position }
              }
            }
          }
        }
        apostropheGlyph = Self.apostrophe(forward: forward, reverse: reverse)
    }

    private func translate(key: UInt16, shift: Bool, capsLock: Bool) -> String? {
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 16)
        let result = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown),
            UInt32(((shift ? shiftKey : 0) | (capsLock ? alphaLock : 0)) >> 8), UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, buffer.count, &length, &buffer)
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }

    /// A key that only starts a composition (' then e is é on US International) types nothing itself.
    private func isDead(key: UInt16, shift: Bool, capsLock: Bool) -> Bool {
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 16)
        let result = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown),
            UInt32(((shift ? shiftKey : 0) | (capsLock ? alphaLock : 0)) >> 8), UInt32(LMGetKbdType()),
            0, &dead, buffer.count, &length, &buffer)
        return result == noErr && length == 0 && dead != 0
    }
    #endif

    /// The text this key leaves in the field depends on the next key: the application composes it.
    public func isDeadKey(key: UInt16, shift: Bool, capsLock: Bool = false) -> Bool {
        deadKeys.contains(key | (shift ? 0x100 : 0) | (capsLock ? 0x200 : 0))
    }

    /// The key and Shift state that type this character.
    public func stroke(for character: Character) -> KeyStroke? {
        reverse[String(character)].map { KeyStroke(key: $0 & 0xff, shift: $0 & 0x100 != 0) }
    }

    /// The physical key that types this character, ignoring Shift.
    public func key(for character: Character) -> UInt16? {
        reverse[String(character)].map { $0 & 0xff }
    }

    public func character(key: UInt16, shift: Bool, capsLock: Bool = false) -> String? {
        forward[key | (shift ? 0x100 : 0) | (capsLock ? 0x200 : 0)]
    }

    /// Computed once at init: convert() asks for it for every apostrophe character.
    private(set) var apostropheGlyph = "'"

    private static func apostrophe(forward: [UInt16: String], reverse: [String: UInt16]) -> String {
        // Prefer a normal, unshifted key before compatibility/JIS alternatives.
        for key in Array(UInt16(0)...50) + [93, 94] {
            if let glyph = forward[key], glyph.count == 1, glyph.first.map({ WordText.apostrophes.contains($0) }) == true { return glyph }
        }
        return ["'", "ʼ", "’"].first { reverse[$0] != nil } ?? "'"
    }

    /// Keep the actual key for recently typed symbols: the same glyph may occur on
    /// several keys in one layout and map to different glyphs in another layout.
    public func render(_ strokes: [KeyStroke]) -> String? {
        var output = ""
        for stroke in strokes {
            guard let value = character(key: stroke.key, shift: stroke.shift, capsLock: stroke.capsLock) else { return nil }
            output += value
        }
        return output
    }

    public func convert(_ text: String, to target: KeyboardLayout, preservingPunctuation: Bool = false) -> String? {
        var output = ""
        for character in text {
            // Prefer the literal glyph's real key (Ukrainian PC has a dedicated
            // U+02BC key). Normalize typography only when this table lacks it.
            let literal = String(character)
            let value = reverse[literal] == nil && WordText.apostrophes.contains(character) ? apostropheGlyph : literal
            if value.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) ||
               (preservingPunctuation && character.isPunctuation) {
                output += value
            } else if let position = reverse[value], let translated = target.forward[position] {
                output += translated
            } else { return nil }
        }
        return output
    }

    #if canImport(Carbon)
    public func select() -> Bool { TISSelectInputSource(source) == noErr }
    #else
    /// Set by the Linux app: selects a layout through the desktop's own switcher.
    public static var selector: ((KeyboardLayout) -> Bool)?
    /// Set by the Linux app: the selected layout's ID and the enabled layouts.
    public static var currentProvider: (() -> String)?
    public static var installedProvider: (() -> [KeyboardLayout])?
    public func select() -> Bool { Self.selector?(self) ?? false }
    #endif

    public static func cycleOrder(_ layouts: [KeyboardLayout]) -> [KeyboardLayout] {
        func priority(_ layout: KeyboardLayout) -> Int {
            if layout.languages.contains(.english) { return 0 }
            if layout.languages.contains(.russian) { return 1 }
            if layout.languages.contains(.ukrainian) { return 2 }
            return 3
        }
        return layouts.sorted {
            let left = priority($0), right = priority($1)
            return left == right ? $0.id < $1.id : left < right
        }
    }

    #if canImport(Carbon)
    public static func currentID() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    public static func installed(enabledOnly: Bool = true) -> [KeyboardLayout] {
        let sources = TISCreateInputSourceList(nil, !enabledOnly).takeRetainedValue() as! [TISInputSource]
        return sources.compactMap(KeyboardLayout.init)
    }
    #else
    public static func currentID() -> String { currentProvider?() ?? "" }

    /// Enabled layouts come from the desktop. All layouts (tests, validation) are the Apple
    /// tables recorded on a Mac, so the Linux build is checked against the same keys as the Mac.
    public static func installed(enabledOnly: Bool = true) -> [KeyboardLayout] {
        if enabledOnly { return installedProvider?() ?? [] }
        return appleReference
    }

    public static let appleReference: [KeyboardLayout] = {
        guard let url = Bundle.module.url(forResource: "apple-layouts", withExtension: "json", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String,
                  let keys = entry["keys"] as? [String: String] else { return nil }
            var table: [UInt16: String] = [:]
            for (position, value) in keys { if let p = UInt16(position) { table[p] = value } }
            let dead = Set((entry["dead"] as? [Int] ?? []).map { UInt16($0) })
            return KeyboardLayout(id: id, name: name, table: table, deadKeys: dead)
        }
    }()
    #endif
}
