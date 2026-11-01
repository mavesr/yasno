// Prints what the test stand sees: session lock state, frontmost app, and per bundle id the
// windows, focused element and its value length (no typed text is printed).
// usage: ax-info <bundle id>...
import Cocoa
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
print("trusted=\(AXIsProcessTrusted()) post=\(CGPreflightPostEventAccess()) listen=\(CGPreflightListenEventAccess())")
print("screenLocked=\(session["CGSSessionScreenIsLocked"] ?? "nil") onConsole=\(session["kCGSSessionOnConsoleKey"] ?? "nil")")
print("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") pid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
let systemwide = AXUIElementCreateSystemWide()
if let app = element(attribute(systemwide, kAXFocusedApplicationAttribute)) {
    var pid: pid_t = 0; AXUIElementGetPid(app, &pid)
    print("systemwide focused application pid=\(pid)")
}
for id in CommandLine.arguments.dropFirst() {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == id }
    if apps.isEmpty { print("\(id): not running"); continue }
    for app in apps {
        let pid = app.processIdentifier
        let ax = AXUIElementCreateApplication(pid)
        print("\(id): pid=\(pid) active=\(app.isActive) hidden=\(app.isHidden) policy=\(app.activationPolicy.rawValue)")
        let windows = (attribute(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        print("  windows=\(windows.count) frontmostAttr=\(attribute(ax, kAXFrontmostAttribute) ?? "nil" as CFTypeRef)")
        for window in windows {
            let title = attribute(window, kAXTitleAttribute) as? String ?? ""
            let main = attribute(window, kAXMainAttribute) as? Bool ?? false
            let focused = attribute(window, kAXFocusedAttribute) as? Bool ?? false
            let minimized = attribute(window, kAXMinimizedAttribute) as? Bool ?? false
            print("    window '\(title)' main=\(main) focused=\(focused) minimized=\(minimized)")
        }
        if let focused = element(attribute(ax, kAXFocusedUIElementAttribute)) {
            let role = attribute(focused, kAXRoleAttribute) as? String ?? "?"
            let subrole = attribute(focused, kAXSubroleAttribute) as? String ?? "-"
            let value = attribute(focused, kAXValueAttribute) as? String
            let identifier = attribute(focused, kAXIdentifierAttribute) as? String ?? "-"
            var range: CFTypeRef?
            let rangeStatus = AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &range)
            print("  focused role=\(role) subrole=\(subrole) id=\(identifier) valueChars=\(value.map { String($0.count) } ?? "nil") selectedRange=\(rangeStatus.rawValue)")
        } else { print("  focused element: none") }
    }
}
