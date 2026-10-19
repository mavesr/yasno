import Cocoa
import ApplicationServices
import Carbon
import SwitchCore

/// Only edits an exact, re-validated range. Never replaces the entire field or uses the clipboard.
struct AccessibleEditor {
    static let acknowledgementTimeout: TimeInterval = 0.25
    static let operationTimeout: TimeInterval = 0.5
    let element: AXUIElement
    let pid: pid_t

    /// Chromium and Electron build their web AX tree only on request. Arc has a native
    /// shell, so asking only that shell for its focused element can miss the web field.
    /// Only AXManualAccessibility is used: AXEnhancedUserInterface is meant for VoiceOver
    /// and slows window animations and window managers. Never call this on main.
    private static let preparedLock = NSLock()
    private static var prepared: Set<pid_t> = []

    static func prepareApplication(pid: pid_t) {
        preparedLock.lock(); let known = prepared.contains(pid); preparedLock.unlock()
        guard !known else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let attribute = "AXManualAccessibility" as CFString
        // Chromium accepts the attribute without always reporting it as settable.
        let chromium = ["company.thebrowser.Browser", "com.google.Chrome", "com.microsoft.edgemac",
                        "com.brave.Browser", "org.chromium.Chromium"].contains(
                            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")
        var settable = DarwinBoolean(false)
        let supported = AXUIElementIsAttributeSettable(app, attribute, &settable) == .success && settable.boolValue
        guard chromium || supported else { return }
        _ = AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue)
        preparedLock.lock(); prepared.insert(pid); preparedLock.unlock()
    }

    /// Return applications to their default accessibility mode at exit.
    static func releasePreparedApplications() {
        preparedLock.lock(); let pids = prepared; prepared = []; preparedLock.unlock()
        for pid in pids where NSRunningApplication(processIdentifier: pid) != nil {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.12)
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
        }
    }

    static func focused(pid: pid_t) -> AccessibleEditor? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        func focusedElement(of root: AXUIElement) -> AXUIElement? {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
                  let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(raw, to: AXUIElement.self)
        }
        // The system focus follows remote Cocoa views used by browser shells. Never
        // accept an element owned by an unrelated application during a focus race.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        let global = focusedElement(of: system)
        let element: AXUIElement
        if let global, belongsToApplication(global, pid: pid) { element = global }
        else if let local = focusedElement(of: app) { element = local }
        else { return nil }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.12)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole else { return nil }
        return AccessibleEditor(element: element, pid: pid)
    }

    private static func belongsToApplication(_ element: AXUIElement, pid: pid_t) -> Bool {
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success else { return false }
        if owner == pid { return true }
        guard let appURL = NSRunningApplication(processIdentifier: pid)?.bundleURL?.standardizedFileURL,
              let ownerURL = NSRunningApplication(processIdentifier: owner)?.bundleURL?.standardizedFileURL else { return false }
        return ownerURL.path.hasPrefix(appURL.path + "/")
    }

    /// Google Docs and Slides draw the document themselves. Keys go to a hidden field that
    /// holds only zero-width placeholders, never the text, so it can be edited only with
    /// keystrokes. Its frame carries a known class, recognised without waiting for a caret.
    var isCanvasTypingTarget: Bool {
        guard exposesNoText else { return false }
        var current = element
        for _ in 0..<3 {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &raw) == .success,
                  let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
            current = unsafeBitCast(raw, to: AXUIElement.self)
            var classes: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, "AXDOMClassList" as CFString, &classes) == .success,
               (classes as? [String])?.contains("docs-texteventtarget-iframe") == true { return true }
        }
        return false
    }

    /// A text field or area whose value is empty or only invisible placeholders.
    var exposesNoText: Bool {
        var role: CFTypeRef?, raw: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard [kAXTextAreaRole, kAXTextFieldRole].contains(role as? String ?? ""),
              AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let value = raw as? String, value.utf16.count <= 16 else { return false }
        let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
        return value.unicodeScalars.allSatisfy { invisible.contains($0) || $0.properties.isWhitespace }
    }

    var selection: CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }

    /// AX selection/value can lag behind already delivered hardware events in a busy
    /// renderer. Confirm the known typed suffix before choosing a word or switching only.
    func waitForCaret(after token: KeyboardMonitor.Token, deadline operationDeadline: TimeInterval? = nil,
                      stillValid: () -> Bool) -> CFRange? {
        // An unsupported field must not consume the entire caret timeout first.
        guard canSelect else { return nil }
        let count = token.text.utf16.count + token.suffix.utf16.count
        let deadline = min(operationDeadline ?? .infinity, ProcessInfo.processInfo.systemUptime + Self.acknowledgementTimeout)
        var delay: TimeInterval = 0.002 // Back off: each probe is two AX requests to a busy renderer.
        repeat {
            guard ProcessInfo.processInfo.systemUptime < deadline, stillValid(), !IsSecureEventInputEnabled() else { return nil }
            if let caret = selection, caret.length == 0, caret.location >= count,
               let actual = text(in: CFRange(location: caret.location - count, length: count)),
               WordBoundary.matches(actual, word: token.text, suffix: token.suffix) { return caret }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 2, 0.016)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }

    func text(in range: CFRange) -> String? {
        guard range.location >= 0, range.length >= 0, range.length <= 4096 else { return nil }
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                       value, &result) == .success {
            return result as? String
        }
        // Refuse an unbounded full-document IPC fallback. Exact coordinates stay unchanged.
        var count: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
              let number = count as? NSNumber, number.intValue <= 16_384 else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let string = raw as? String else { return nil }
        return TextSafety.substring(string, location: range.location, length: range.length)
    }

    func isFocused() -> Bool {
        guard let current = Self.focused(pid: pid) else { return false }
        return CFEqual(current.element, element)
    }

    private func setSelection(_ range: CFRange) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private var canSelect: Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    typealias EditResult = ReplacementTransaction.Result

    /// 2 → 4 → 8 → 16 ms between AX probes instead of a fixed 4 ms.
    private static func backoff() -> () -> Void {
        var delay: TimeInterval = 0.002
        return {
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 2, 0.016)
        }
    }

    func replace(range: CFRange, expected: String, replacement: String,
                 caret: CFRange, stillValid: () -> Bool, commit: () -> Bool,
                 deadline: TimeInterval? = nil) -> EditResult {
        ReplacementTransaction.run(range: range, expected: expected, replacement: replacement, caret: caret,
            stillValid: stillValid, commit: commit, environment: .init(
                selection: { selection }, text: { text(in: $0) }, focused: { isFocused() },
                canSelect: { canSelect }, select: { setSelection($0) },
                insert: { KeyboardMonitor.insertUnicode($0, pid: pid) }, pause: Self.backoff(), deadline: deadline))
    }
}
