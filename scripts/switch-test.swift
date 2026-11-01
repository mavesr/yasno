// Types a word right after switching to application B and checks what Ясно made of it. Each trial
// brings B and then A to the front, switches to B the way a user does, waits the given delay and
// types the case's keys; the field is read back through Accessibility.
//
//   switch-test <A bundle id> <B bundle id> <B window title marker> <delays ms,comma> [repeats] [case] [focus]
//   focus: focused (default) | dom:<id>   (a web field on docs/field-lab.html, focused through AX first)
//   SWITCH=cmdtab (default) | click (into B's field) | stage (B's thumbnail in the Stage Manager strip)
//   B_LAYOUT=<layout suffix>  the layout B remembers; macOS restores it when B comes to the front
//
// Keys typed before B is in front land in A, so A must be a harmless text window (the YasnoLab
// window, an unsaved TextEdit document). Only windows whose title contains the marker are typed into.
// Compile: swiftc -swift-version 5 -O -o /tmp/switch-test scripts/switch-test.swift
import Cocoa
import ApplicationServices
import Carbon

func fail(_ text: String) -> Never { fputs(text + "\n", stderr); exit(2) }
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else { fail("usage: switch-test <A bundle> <B bundle> <B title marker> <delays ms,comma> [repeats] [case] [focus]") }
let aID = args[0], bID = args[1], marker = args[2]
let delays = args[3].split(separator: ",").compactMap { Int($0) }
let repeats = args.count > 4 ? (Int(args[4]) ?? 3) : 3
let caseName = args.count > 5 ? args[5] : "hello"
let focusSpec = args.count > 6 ? args[6] : "focused"
struct Case { let layout: String; let keys: [CGKeyCode]; let typed: String; let expected: String }
let cases: [String: Case] = [
    "hello": Case(layout: "ABC", keys: [5, 4, 11, 2, 17, 45, 49], typed: "ghbdtn ", expected: "привет "),
    "program": Case(layout: "ABC", keys: [5, 4, 38, 32, 4, 3, 9, 9, 3, 49], typed: "ghjuhfvvf ", expected: "программа "),
    "mir": Case(layout: "ABC", keys: [9, 11, 4, 49], typed: "vbh ", expected: "мир "),
    "phrase": Case(layout: "ABC", keys: [5, 4, 11, 2, 17, 45, 49, 9, 11, 4, 49], typed: "ghbdtn vbh ", expected: "привет мир "),
    // No Space: only a live (mid-word) correction can turn these.
    "hello-live": Case(layout: "ABC", keys: [5, 4, 11, 2, 17, 45], typed: "ghbdtn", expected: "привет"),
    "program-live": Case(layout: "ABC", keys: [5, 4, 38, 32, 4, 3, 9, 9, 3], typed: "ghjuhfvvf", expected: "программа"),
]
guard let test = cases[caseName] else { fail("unknown case") }
guard CGPreflightPostEventAccess() else { fail("no permission to post events") }
// Keys posted at a locked screen would go to the password field.
func screenLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    return (session["CGSSessionScreenIsLocked"] as? Int ?? 0) != 0
}
guard !screenLocked() else { fail("the screen is locked") }
let switchMode = ProcessInfo.processInfo.environment["SWITCH"] ?? "cmdtab"
let bLayout = ProcessInfo.processInfo.environment["B_LAYOUT"] ?? test.layout

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
func running(_ id: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id && !$0.isTerminated && $0.processIdentifier > 0 }
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
func focusedElement(_ pid: pid_t) -> AXUIElement? { element(attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)) }
func frontWindow(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    return element(attribute(app, kAXFocusedWindowAttribute)) ?? element(attribute(app, kAXMainWindowAttribute))
}
func windowTitle(_ pid: pid_t) -> String { frontWindow(pid).flatMap { attribute($0, kAXTitleAttribute) as? String } ?? "" }
func normalize(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00a0}", with: " ").replacingOccurrences(of: "\u{200b}", with: "").trimmingCharacters(in: .newlines)
}
func readField(_ pid: pid_t) -> String { normalize(focusedElement(pid).flatMap { attribute($0, kAXValueAttribute) as? String } ?? "<unreadable>") }

let source = CGEventSource(stateID: .privateState)!
func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = [], flagsChanged: Bool = false) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)!
    event.flags = flags
    if flagsChanged { event.type = .flagsChanged }
    event.setIntegerValueField(.eventSourceUserData, value: 0x5941534E4F54)
    event.post(tap: .cghidEventTap)
}
func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
    post(key, down: true, flags: flags); Thread.sleep(forTimeInterval: 0.01); post(key, down: false, flags: flags)
}
func cmdTab() {
    post(55, down: true, flags: .maskCommand, flagsChanged: true); Thread.sleep(forTimeInterval: 0.03)
    post(48, down: true, flags: .maskCommand); Thread.sleep(forTimeInterval: 0.03)
    post(48, down: false, flags: .maskCommand); Thread.sleep(forTimeInterval: 0.03)
    post(55, down: false, flags: [], flagsChanged: true)
}
func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func click(_ point: CGPoint) {
    let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!
    move.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.05)
    let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!
    let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)!
    down.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.04); up.post(tap: .cghidEventTap)
}
/// Switch the way a mouse user does: click into B's focused field (empty, so the caret stays put).
func clickSwitch(_ app: NSRunningApplication) {
    guard let field = focusedElement(app.processIdentifier),
          let position = attribute(field, kAXPositionAttribute), let size = attribute(field, kAXSizeAttribute) else { fail("no field geometry in B") }
    var origin = CGPoint.zero, extent = CGSize.zero
    AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin)
    AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent)
    let point = CGPoint(x: origin.x + min(extent.width / 2, 200), y: origin.y + min(extent.height / 2, 30))
    var hit: AXUIElement?
    AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
    var owner: pid_t = 0
    if let hit { AXUIElementGetPid(hit, &owner) }
    guard owner == app.processIdentifier else { fail("B's field at \(point) is covered by pid \(owner); move the windows apart") }
    click(point)
}
/// Stage Manager: the thumbnail of B's window in the left strip (a small on-screen window owned by B).
func stageThumbnail(_ app: NSRunningApplication) -> CGPoint? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
        guard window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds), rect.width < 300, rect.minX >= 0 else { continue }
        return CGPoint(x: rect.midX, y: rect.midY)
    }
    return nil
}
func stageSwitch(_ app: NSRunningApplication) {
    guard let point = stageThumbnail(app) else { fail("no visible Stage Manager thumbnail of B; keep the windows away from the left strip") }
    click(point)
}
/// Bring an application to the front: through AX (works from a background process with the
/// Accessibility permission), falling back to NSRunningApplication.
func activate(_ app: NSRunningApplication) -> Bool {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let window = frontWindow(app.processIdentifier) { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
    var deadline = Date().addingTimeInterval(1.5)
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier, Date() < deadline { wait(0.01) }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
        app.activate(options: [.activateAllWindows])
        deadline = Date().addingTimeInterval(1.5)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier, Date() < deadline { wait(0.01) }
    }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
}
func selectLayout(_ suffix: String) {
    let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    guard let layout = list.first(where: {
        guard let pointer = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == "com.apple.keylayout." + suffix
    }), TISSelectInputSource(layout) == noErr else { fail("layout \(suffix) unavailable") }
    Thread.sleep(forTimeInterval: 0.15)
}
func currentLayout() -> String {
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else { return "?" }
    return (Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String).replacingOccurrences(of: "com.apple.keylayout.", with: "")
}
/// Empty the focused field of an application that is in front: AXValue when settable, else Select All + Backspace.
func clearField(_ app: NSRunningApplication) {
    guard activate(app), let field = focusedElement(app.processIdentifier) else { return }
    if let text = attribute(field, kAXValueAttribute) as? String, !text.isEmpty {
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
        wait(0.2)
        if let left = attribute(field, kAXValueAttribute) as? String, !left.isEmpty {
            post(55, down: true, flags: .maskCommand, flagsChanged: true); Thread.sleep(forTimeInterval: 0.02)
            press(0, flags: .maskCommand); Thread.sleep(forTimeInterval: 0.02)
            post(55, down: false, flagsChanged: true); Thread.sleep(forTimeInterval: 0.2)
            press(51); wait(0.4)
        }
    }
}
func find(_ pid: pid_t, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    guard let window = frontWindow(pid) else { return nil }
    var queue = [window], visited = 0
    while !queue.isEmpty, visited < 20_000 {
        let next = queue.removeFirst(); visited += 1
        if match(next) { return next }
        queue += (attribute(next, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    return nil
}

_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.prohibited)
guard let a = running(aID), let b = running(bID) else { fail("A or B is not running") }
guard activate(b) else { fail("cannot activate B") }
let titleDeadline = Date().addingTimeInterval(3)
while !windowTitle(b.processIdentifier).contains(marker), Date() < titleDeadline { wait(0.1) }
guard windowTitle(b.processIdentifier).contains(marker) else { fail("B front window is not a test window: \(windowTitle(b.processIdentifier))") }
if focusSpec.hasPrefix("dom:") {
    let id = String(focusSpec.dropFirst(4))
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(b.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    wait(0.3)
    guard let target = find(b.processIdentifier, { attribute($0, "AXDOMIdentifier") as? String == id }) else { fail("field \(id) not found") }
    AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    wait(0.3)
}
guard focusedElement(b.processIdentifier) != nil else { fail("B has no focused field") }
guard activate(a), focusedElement(a.processIdentifier) != nil else { fail("A has no focused field") }
selectLayout(test.layout)
print("A = \(a.localizedName ?? aID), B = \(b.localizedName ?? bID) [\(windowTitle(b.processIdentifier))], case \(caseName): \(test.typed.debugDescription) → \(test.expected.debugDescription), switch: \(switchMode), B layout: \(bLayout)")
var summary: [Int: (ok: Int, bad: Int, other: Int)] = [:]
for delay in delays {
    for trial in 1...repeats {
        // macOS remembers an input source per application: select the layout while each of
        // them is in front, or the previous correction's layout comes back with B.
        clearField(b); wait(0.2); selectLayout(bLayout); wait(0.2)
        clearField(a); wait(0.6)
        selectLayout(test.layout)
        wait(0.3)
        switch switchMode {
        case "click": clickSwitch(b)
        case "stage": stageSwitch(b)
        default: cmdTab()
        }
        let switched = uptime()
        Thread.sleep(forTimeInterval: Double(delay) / 1000)
        let typingStart = uptime()
        for key in test.keys { press(key); Thread.sleep(forTimeInterval: 0.05) }
        wait(1.3)
        let inB = readField(b.processIdentifier), inA = readField(a.processIdentifier)
        let verdict: String
        if inB.hasSuffix(test.expected) || inB == test.expected.trimmingCharacters(in: .whitespaces) { verdict = "corrected" }
        else if inB.hasSuffix(test.typed) || inB == test.typed.trimmingCharacters(in: .whitespaces) { verdict = "NOT corrected" }
        else { verdict = "other" }
        var entry = summary[delay] ?? (0, 0, 0)
        if verdict == "corrected" { entry.ok += 1 } else if verdict == "NOT corrected" { entry.bad += 1 } else { entry.other += 1 }
        summary[delay] = entry
        print(String(format: "delay %4d ms  trial %d  %-13@  B=%@  A=%@  layout after: %@  (first key %.0f ms after the switch)", delay, trial, verdict,
                     inB.debugDescription, inA.debugDescription, currentLayout(), (typingStart - switched) * 1000))
        fflush(stdout)
    }
}
clearField(b); wait(0.2); clearField(a)
selectLayout(test.layout)
print("summary (delay: corrected / not corrected / other)")
for delay in delays { let e = summary[delay] ?? (0, 0, 0); print("  \(delay) ms: \(e.ok) / \(e.bad) / \(e.other)") }
exit(0)
