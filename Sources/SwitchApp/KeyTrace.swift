import Cocoa
import SwitchCore

/// `--trace-keys`: for 30 seconds, write every key event the three tap locations see to
/// ~/Desktop/Yasno-keys.txt. Only on request, for input that does not reach the monitor
/// (Screen Sharing, remote desktops). The file holds the typed characters; delete it after use.
enum KeyTrace {
    private static var output: FileHandle?
    private static var taps: [CFMachPort] = []

    static func run(seconds: TimeInterval = 30) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Yasno-keys.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        output = try? FileHandle(forWritingTo: url)
        write("Yasno \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") trace; layout \(KeyboardLayout.currentID())")
        write("Input monitoring: \(CGPreflightListenEventAccess()), accessibility: \(AXIsProcessTrusted())")
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        for (location, name) in [(CGEventTapLocation.cghidEventTap, "hid"), (.cgSessionEventTap, "session"),
                                 (.cgAnnotatedSessionEventTap, "annotated")] {
            let label = Unmanaged.passRetained(name as NSString).toOpaque()
            guard let tap = CGEvent.tapCreate(tap: location, place: .tailAppendEventTap, options: .listenOnly,
                    eventsOfInterest: mask, callback: { _, type, event, label in
                        if type.rawValue <= CGEventType.flagsChanged.rawValue, let label {
                            KeyTrace.record(type, event, at: Unmanaged<NSString>.fromOpaque(label).takeUnretainedValue() as String)
                        }
                        return Unmanaged.passUnretained(event)
                    }, userInfo: label) else { write("\(name): tap not created"); continue }
            taps.append(tap)
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        write("Type in the field now. Stops in \(Int(seconds)) s.")
        CFRunLoopRunInMode(.defaultMode, seconds, false)
        write("Done.")
        try? output?.close()
    }

    private static func record(_ type: CGEventType, _ event: CGEvent, at location: String) {
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        let text = String(utf16CodeUnits: units, count: length).unicodeScalars.map { String(format: "U+%04X", $0.value) }
        let kind = type == .keyDown ? "down" : type == .keyUp ? "up" : "flags"
        write([location, kind, "key=\(event.getIntegerValueField(.keyboardEventKeycode))",
               "flags=" + String(event.flags.rawValue, radix: 16),
               "repeat=\(event.getIntegerValueField(.keyboardEventAutorepeat))",
               "keyboard=\(event.getIntegerValueField(.keyboardEventKeyboardType))",
               "userData=\(event.getIntegerValueField(.eventSourceUserData))",
               "sourceState=\(event.getIntegerValueField(.eventSourceStateID))",
               "sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID))",
               "text=" + text.joined(separator: ","), "layout=" + KeyboardLayout.currentID()].joined(separator: " "))
    }

    private static func write(_ line: String) {
        output?.write(Data((line + "\n").utf8))
    }
}
