import Foundation
import Carbon

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
    public let source: TISInputSource
    private let data: CFData
    private var forward: [UInt16: String] = [:]
    private var reverse: [String: UInt16] = [:]

    public init?(source: TISInputSource) {
        guard let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              let namePointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
        else { return nil }
        self.source = source
        id = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        name = Unmanaged<CFString>.fromOpaque(namePointer).takeUnretainedValue() as String
        data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue()
        let lower = id.lowercased()
        if lower.contains("ukrainian") { languages = [.ukrainian] }
        else if lower.contains("russian") { languages = [.russian] }
        else if lower.contains("german") { languages = [.german, .english] }
        else if ["com.apple.keylayout.ABC", "com.apple.keylayout.US", "com.apple.keylayout.British",
                 "com.apple.keylayout.ABC-Extended", "com.apple.keylayout.USInternational-PC", "com.apple.keylayout.ABC-QWERTZ"].contains(id) {
            // Both languages can be written using the same Latin keyboard.
            languages = [.english, .german]
        } else { return nil }

        let mainKeys = Array(UInt16(0)...50) + [93, 94]
        let otherKeys = (UInt16(0)..<128).filter { !mainKeys.contains($0) }
        for keys in [mainKeys, otherKeys] {
          for shift in [false, true] {
            for key in keys {
                guard let value = translate(key: key, shift: shift),
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                else { continue }
                let position = key | (shift ? 0x100 : 0)
                forward[position] = value
                // Prefer the main keyboard, including its shifted symbols, before the keypad.
                if reverse[value] == nil { reverse[value] = position }
            }
          }
        }
    }

    private func translate(key: UInt16, shift: Bool) -> String? {
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 16)
        let result = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown),
            shift ? UInt32(shiftKey >> 8) : 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, buffer.count, &length, &buffer)
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }

    public func character(key: UInt16, shift: Bool) -> String? {
        forward[key | (shift ? 0x100 : 0)]
    }

    var apostropheGlyph: String {
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
            guard var value = character(key: stroke.key, shift: stroke.shift) else { return nil }
            if stroke.capsLock, value.contains(where: \.isLetter) {
                value = stroke.shift ? value.lowercased() : value.uppercased()
            }
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

    public func select() -> Bool { TISSelectInputSource(source) == noErr }

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

    public static func currentID() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    public static func installed(enabledOnly: Bool = true) -> [KeyboardLayout] {
        let sources = TISCreateInputSourceList(nil, !enabledOnly).takeRetainedValue() as! [TISInputSource]
        return sources.compactMap(KeyboardLayout.init)
    }
}
