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

    /// The App Store build runs in the App Sandbox, which refuses AX requests to other
    /// applications (kAXErrorCannotComplete) while posting keys still works. There every
    /// field is treated like a canvas target: the word is erased and retyped with keystrokes.
    static let blind = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// Chromium and Electron build their web AX tree only on request. Arc has a native
    /// shell, so asking only that shell for its focused element can miss the web field.
    /// AXManualAccessibility is preferred: AXEnhancedUserInterface is meant for VoiceOver
    /// and slows window animations and window managers. Never call this on main.
    private static let preparedLock = NSLock()
    private static var prepared: [pid_t: CFString] = [:]

    static func prepareApplication(pid: pid_t) {
        guard !blind else { return }
        preparedLock.lock(); let known = prepared[pid]; preparedLock.unlock()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        // Another copy of Ясно (a test build) turns the mode off when it quits, and the field
        // disappears again: an application prepared earlier is checked each time it comes forward.
        if let known {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, known, &value) == .success,
                  (value as? Bool) == false else { return }
            _ = AXUIElementSetAttributeValue(app, known, kCFBooleanTrue)
            return
        }
        let running = NSRunningApplication(processIdentifier: pid)
        var settable = DarwinBoolean(false)
        let supported = AXUIElementIsAttributeSettable(app, "AXManualAccessibility" as CFString, &settable) == .success
            && settable.boolValue
        guard let attribute = attribute(bundleID: running?.bundleIdentifier, bundleURL: running?.bundleURL,
                                        manualSettable: supported) else { return }
        // The shell may report an error even though it switched modes; the mode is what counts.
        _ = AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue)
        preparedLock.lock(); prepared[pid] = attribute; preparedLock.unlock()
    }

    /// The attribute that makes this application build its web AX tree, or nil for a native one.
    /// The ChatGPT app refuses AXManualAccessibility and builds the tree only for
    /// AXEnhancedUserInterface; only the shells listed here get it. A busy Electron app may not
    /// answer the settable query in time, and AXManualAccessibility is right for every Electron.
    static func attribute(bundleID: String?, bundleURL: URL?, manualSettable: Bool) -> CFString? {
        // Chromium accepts the attribute without always reporting it as settable.
        let chromium = ["company.thebrowser.Browser", "com.google.Chrome", "com.microsoft.edgemac",
                        "com.brave.Browser", "org.chromium.Chromium"].contains(bundleID ?? "")
        if chromium || manualSettable { return "AXManualAccessibility" as CFString }
        guard let bundleURL, embedsChromium(bundleURL) else { return nil }
        let enhancedOnly = ["com.openai.codex"].contains(bundleID ?? "")
        return (enhancedOnly ? "AXEnhancedUserInterface" : "AXManualAccessibility") as CFString
    }

    /// Chromium keeps its renderer helpers inside the bundle: next to the frameworks in
    /// Electron, inside the Chromium framework in Chrome-style shells.
    static func embedsChromium(_ bundle: URL) -> Bool {
        let files = FileManager.default
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        guard let entries = try? files.contentsOfDirectory(atPath: frameworks.path) else { return false }
        func hasRenderer(_ names: [String]) -> Bool { names.contains { $0.hasSuffix("(Renderer).app") } }
        if hasRenderer(entries) { return true }
        return entries.filter { $0.hasSuffix(".framework") }.contains { framework in
            let helpers = frameworks.appendingPathComponent(framework).appendingPathComponent("Helpers")
            return hasRenderer((try? files.contentsOfDirectory(atPath: helpers.path)) ?? [])
        }
    }

    /// A terminated process must not count as prepared: the system reuses its pid.
    static func forgetPreparedApplication(pid: pid_t) {
        preparedLock.lock(); prepared.removeValue(forKey: pid); preparedLock.unlock()
    }

    /// Return applications to their default accessibility mode at exit.
    static func releasePreparedApplications() {
        preparedLock.lock(); let apps = prepared; prepared = [:]; preparedLock.unlock()
        for (pid, attribute) in apps where NSRunningApplication(processIdentifier: pid) != nil {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.12)
            _ = AXUIElementSetAttributeValue(app, attribute, kCFBooleanFalse)
        }
    }

    /// Spotlight (Siri on newer macOS) takes the keyboard without becoming the frontmost
    /// application: the menu bar still names the application below, but keys reach its field.
    static let overlayBundleIDs: Set<String> = ["com.apple.Spotlight", "com.apple.campo"]

    /// The application that receives typed keys: an open overlay, else the frontmost one.
    static func typingApplication() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        guard !blind else { return front }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var raw: CFTypeRef?
        var pid: pid_t = 0
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID(),
              AXUIElementGetPid(unsafeBitCast(raw, to: AXUIElement.self), &pid) == .success,
              pid != front?.processIdentifier,
              let overlay = NSRunningApplication(processIdentifier: pid),
              overlayBundleIDs.contains(overlay.bundleIdentifier ?? "") else { return front }
        return overlay
    }

    static func focused(pid: pid_t) -> AccessibleEditor? {
        guard typingApplication()?.processIdentifier == pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // No field can be inspected: the application stands in for its focused field.
        if blind || showsRemoteScreen(pid: pid) { return AccessibleEditor(element: app, pid: pid) }
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
        guard typingApplication()?.processIdentifier == pid else { return nil }
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

    /// Screen Sharing shows another Mac. Nothing in it can be read here, and the keys reach the
    /// other Mac as the characters this Mac's layout gives them: the word is corrected here with
    /// keystrokes, and the layout selected here decides what is typed there.
    static let remoteScreenBundleIDs: Set<String> = ["com.apple.ScreenSharing"]

    static func showsRemoteScreen(pid: pid_t) -> Bool {
        remoteScreenBundleIDs.contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")
    }

    var showsRemoteScreen: Bool { Self.showsRemoteScreen(pid: pid) }

    /// Open and Save panels run in an AppKit service. Their fields appear in the host
    /// application's AX tree, but keys posted to the host never reach them.
    static let panelServiceBundleIDs: Set<String> = ["com.apple.appkit.xpc.openAndSavePanelService"]

    /// The panel keeps the input source it had when it opened: a layout selected for the
    /// session never reaches its field, so only the words themselves can be corrected there.
    static func takesKeysInPanel(receiver: pid_t, pid: pid_t) -> Bool { receiver != pid }

    /// The process that takes keys for this field: the panel service drawing the window the
    /// field is in, else the application itself. Two AX requests and the whole window list
    /// (several milliseconds): ask once per edit, on the worker, never on main.
    var keyReceiver: pid_t {
        // No panel service process, no panel: the common case costs no AX and no window list.
        guard Self.panelServiceBundleIDs.contains(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }) else { return pid }
        var raw: CFTypeRef?
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &raw) == .success,
              let position = raw, CFGetTypeID(position) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &raw) == .success,
              let extent = raw, CFGetTypeID(extent) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(extent, to: AXValue.self), .cgSize, &size),
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return pid }
        return Self.inputPID(at: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2), pid: pid,
                             windows: windows) { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    }

    /// The host shows the panel in a window of its own; the service keeps an offscreen window
    /// of the same frame, listed in front of the host's or behind it. Windows come front to
    /// back: the host's topmost visible one under the point holds the field.
    static func inputPID(at point: CGPoint, pid: pid_t, windows: [[String: Any]],
                         bundleID: (pid_t) -> String?) -> pid_t {
        let ordinary = windows.compactMap { window -> (owner: pid_t, frame: CGRect, visible: Bool)? in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return (owner, frame, window[kCGWindowIsOnscreen as String] as? Bool == true)
        }
        guard let host = ordinary.first(where: { $0.owner == pid && $0.visible && $0.frame.contains(point) }),
              let panel = ordinary.first(where: { $0.owner != pid && $0.frame == host.frame
                  && panelServiceBundleIDs.contains(bundleID($0.owner) ?? "") }) else { return pid }
        return panel.owner
    }

    /// Google Docs and Slides draw the document themselves. Keys go to a hidden field that
    /// holds only zero-width placeholders, never the text, so it can be edited only with
    /// keystrokes. Its frame carries a known class, recognised without waiting for a caret.
    var isCanvasTypingTarget: Bool {
        if Self.blind || showsRemoteScreen { return true }
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
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return Self.showsNoText(role: role as? String, characterCount: {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &raw) == .success
            else { return nil }
            return (raw as? NSNumber)?.intValue
        }, value: {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success else { return nil }
            return raw as? String
        })
    }

    /// The count is asked first: a long document is not copied over AX just to be discarded.
    static func showsNoText(role: String?, characterCount: () -> Int?, value: () -> String?) -> Bool {
        guard [kAXTextAreaRole, kAXTextFieldRole].contains(role ?? "") else { return false }
        if let count = characterCount(), count > 16 { return false }
        guard let value = value(), value.utf16.count <= 16 else { return false }
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

    /// `receiver` is this field's keyReceiver, read once by the caller.
    func replace(range: CFRange, expected: String, replacement: String,
                 caret: CFRange, stillValid: () -> Bool, commit: () -> Bool,
                 deadline: TimeInterval? = nil, receiver: pid_t) -> EditResult {
        let inputPID = receiver
        return ReplacementTransaction.run(range: range, expected: expected, replacement: replacement, caret: caret,
            stillValid: stillValid, commit: commit, environment: .init(
                selection: { selection }, text: { text(in: $0) }, focused: { isFocused() },
                canSelect: { canSelect }, select: { setSelection($0) },
                insert: { KeyboardMonitor.insertUnicode($0, pid: inputPID) }, pause: Self.backoff(), deadline: deadline))
    }
}
