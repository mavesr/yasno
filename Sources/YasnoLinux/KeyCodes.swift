import SwitchCore

/// The core names keys by macOS virtual key codes (its geometry, tables and tests use them).
/// On Linux every evdev key is translated to the Mac code of the same physical position, so
/// the detector sees exactly the keys a Mac sees. ISO: the key left of 1 is Mac 10 (§) and the
/// key left of Z is Mac 50, as KeyboardGeometry places them.
public enum KeyCodes {
    public static let evdevToMac: [UInt16: UInt16] = [
        1: 53, 2: 18, 3: 19, 4: 20, 5: 21, 6: 23, 7: 22, 8: 26, 9: 28, 10: 25, 11: 29, 12: 27, 13: 24, 14: 51,
        15: 48, 16: 12, 17: 13, 18: 14, 19: 15, 20: 17, 21: 16, 22: 32, 23: 34, 24: 31, 25: 35, 26: 33, 27: 30,
        28: 36, 30: 0, 31: 1, 32: 2, 33: 3, 34: 5, 35: 4, 36: 38, 37: 40, 38: 37, 39: 41, 40: 39, 41: 10,
        43: 42, 44: 6, 45: 7, 46: 8, 47: 9, 48: 11, 49: 45, 50: 46, 51: 43, 52: 47, 53: 44, 57: 49, 86: 50,
        // Keypad.
        55: 67, 71: 89, 72: 91, 73: 92, 74: 78, 75: 86, 76: 87, 77: 88, 78: 69, 79: 83, 80: 84, 81: 85,
        82: 82, 83: 65, 96: 76, 98: 75,
        // JIS extra keys.
        89: 94, 124: 93,
        // Navigation: no character in any layout, so they end the word as on a Mac.
        102: 115, 103: 126, 104: 116, 105: 123, 106: 124, 107: 119, 108: 125, 109: 121, 111: 117,
    ]

    public static let macToEvdev: [UInt16: UInt16] = {
        var result: [UInt16: UInt16] = [:]
        for (evdev, mac) in evdevToMac { result[mac] = evdev }
        return result
    }()

    // evdev codes used by the monitor.
    public static let leftShift: UInt16 = 42, rightShift: UInt16 = 54
    public static let leftCtrl: UInt16 = 29, rightCtrl: UInt16 = 97
    public static let leftAlt: UInt16 = 56, rightAlt: UInt16 = 100
    public static let leftMeta: UInt16 = 125, rightMeta: UInt16 = 126
    public static let capsLock: UInt16 = 58
    public static let backspace: UInt16 = 14, space: UInt16 = 57, tab: UInt16 = 15, enter: UInt16 = 28
    public static let modifiers: Set<UInt16> = [42, 54, 29, 97, 56, 100, 125, 126, 58, 69 /* num lock */, 70 /* scroll lock */]

    /// Buttons of mice and touchpads (BTN_LEFT … BTN_TASK, BTN_TOUCH, stylus).
    public static func isPointerButton(_ code: UInt16) -> Bool { (0x110...0x117).contains(code) || code == 0x14a || (0x140...0x14f).contains(code) }
}
