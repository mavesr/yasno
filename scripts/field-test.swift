// Types fixed phrases into one test field with real key events and checks what Ясно made of
// them. Only windows whose title contains the given marker are touched (the local field lab,
// an unsaved TextEdit document, a Google document named «Ясно тест»). Never sends Return.
//
//   field-test <bundle id> <window title marker> <focus> [case…]
//   focus: dom:<id> | class:<DOM class> | focused
//
// Fields are read through Accessibility; canvas editors (Google Docs) with Select All + Copy,
// and the clipboard is restored afterwards.
import Cocoa
import Carbon
import ApplicationServices

func fail(_ text: String) -> Never { fputs(text + "\n", stderr); exit(2) }

struct Case {
    let layout: String
    let keys: String      // Physical keys by their ABC (US) characters; "⇧" is a lone Shift tap.
    let expected: String
}
let cases: [String: Case] = [
    "abc-to-ru": Case(layout: "ABC", keys: "ghbdtn vbh ", expected: "привет мир "),
    "ru-to-en": Case(layout: "Russian", keys: "hello world ", expected: "hello world "),
    "symbol-prefix": Case(layout: "ABC", keys: "(ghbdtn ", expected: "(привет "),
    "long-word": Case(layout: "ABC", keys: "ghjuhfvvf ", expected: "программа "),
    "undo": Case(layout: "ABC", keys: "ghbdtn ⇧", expected: "ghbdtn "),
    "manual": Case(layout: "ABC", keys: "ghb⇧", expected: "при"),
    "native-ru": Case(layout: "Russian", keys: "z nen ", expected: "я тут "),
    "native-en": Case(layout: "ABC", keys: "hello world ", expected: "hello world "),
    "fast-phrase": Case(layout: "ABC", keys: "ghbdtn rfr ltkf ", expected: "привет как дела "),
]
let order = ["abc-to-ru", "ru-to-en", "symbol-prefix", "long-word", "undo", "manual", "native-ru", "native-en", "fast-phrase"]

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3 else { fail("usage: field-test <bundle id> <title marker> <focus> [case…]") }
let bundleID = arguments[0], marker = arguments[1], focusSpec = arguments[2]
let selected = arguments.count > 3 ? Array(arguments[3...]) : order
guard selected.allSatisfy({ cases[$0] != nil }) else { fail("Unknown case") }
guard CGPreflightPostEventAccess() else { fail("No permission to post keyboard events") }

// A just-launched application can be listed with pid -1 until the workspace catches up.
func running() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID && !$0.isTerminated && $0.processIdentifier > 0 }
}
var launched = running()
let launchDeadline = Date().addingTimeInterval(2)
while launched == nil, Date() < launchDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)); launched = running() }
guard let app = launched else { fail("\(bundleID) is not running") }
app.activate(options: [.activateAllWindows])
let activation = Date().addingTimeInterval(2)
while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier, Date() < activation {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { fail("Cannot activate \(bundleID)") }
let ax = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
func frontWindow() -> AXUIElement? { element(attribute(ax, kAXFocusedWindowAttribute)) ?? element(attribute(ax, kAXMainWindowAttribute)) }
func windowTitle() -> String { frontWindow().flatMap { attribute($0, kAXTitleAttribute) as? String } ?? "" }
let titleDeadline = Date().addingTimeInterval(3)
while !windowTitle().contains(marker), Date() < titleDeadline { Thread.sleep(forTimeInterval: 0.1) }
guard windowTitle().contains(marker) else { fail("The front window is not a test window: \(windowTitle())") }

func find(_ match: (AXUIElement) -> Bool) -> AXUIElement? {
    guard let window = frontWindow() else { return nil }
    var queue = [window], visited = 0
    while !queue.isEmpty, visited < 20_000 {
        let next = queue.removeFirst(); visited += 1
        if match(next) { return next }
        queue += (attribute(next, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    return nil
}
if focusSpec != "focused" {
    let parts = focusSpec.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { fail("Bad focus spec") }
    let target: AXUIElement?
    switch parts[0] {
    case "dom": target = find { attribute($0, "AXDOMIdentifier") as? String == parts[1] }
    case "class": target = find { (attribute($0, "AXDOMClassList") as? [String])?.contains(parts[1]) == true }
    default: fail("Bad focus spec")
    }
    guard let target else { fail("Field \(focusSpec) not found") }
    AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.3)
}
guard let field = element(attribute(ax, kAXFocusedUIElementAttribute)) else { fail("No focused field") }
fputs("field: \(attribute(field, kAXRoleAttribute) as? String ?? "?") \(attribute(field, "AXDOMIdentifier") as? String ?? "")\n", stderr)

let source = CGEventSource(stateID: .privateState)!
func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
          windowTitle().contains(marker) else { fail("Focus left the test window; stopped") }
    let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)!
    event.flags = flags
    event.setIntegerValueField(.eventSourceUserData, value: 0x5941534E4F54)
    if key == 56 || key == 55 { event.type = .flagsChanged }
    event.post(tap: .cghidEventTap)
}
func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
    // Some browsers act on a shortcut only after seeing the Command key itself go down.
    let command = flags.contains(.maskCommand)
    if command { post(55, down: true, flags: .maskCommand); Thread.sleep(forTimeInterval: 0.02) }
    post(key, down: true, flags: flags); Thread.sleep(forTimeInterval: command ? 0.03 : 0)
    post(key, down: false, flags: flags)
    if command { Thread.sleep(forTimeInterval: 0.02); post(55, down: false) }
}

let letterCodes: [CGKeyCode] = [0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]
var positions: [Character: (CGKeyCode, Bool)] = [" ": (49, false), "/": (44, false), ",": (43, false), ".": (47, false),
                                                 "(": (25, true), ";": (41, false), "'": (39, false)]
for (letter, code) in zip("abcdefghijklmnopqrstuvwxyz", letterCodes) { positions[letter] = (code, false) }

func selectLayout(_ suffix: String) {
    let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    guard let layout = list.first(where: {
        guard let pointer = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == "com.apple.keylayout." + suffix
    }), TISSelectInputSource(layout) == noErr else { fail("Layout \(suffix) is unavailable") }
    Thread.sleep(forTimeInterval: 0.15)
}

// Save every clipboard item to restore it at the end.
let pasteboard = NSPasteboard.general
let savedItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
    Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
}
func restoreClipboard() {
    pasteboard.clearContents()
    let items = savedItems.map { saved -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, data) in saved { item.setData(data, forType: type) }
        return item
    }
    if !items.isEmpty { pasteboard.writeObjects(items) }
}

// Google Docs types into a hidden field that never holds the text: read it via the clipboard.
let canvas: Bool = {
    var current = field
    for _ in 0..<3 {
        guard let parent = element(attribute(current, kAXParentAttribute)) else { return false }
        if (attribute(parent, "AXDOMClassList") as? [String])?.contains("docs-texteventtarget-iframe") == true { return true }
        current = parent
    }
    return false
}()
/// Text of a field that exposes it through Accessibility.
func axText() -> String? { canvas ? nil : attribute(field, kAXValueAttribute) as? String }

func normalize(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00a0}", with: " ").replacingOccurrences(of: "\u{200b}", with: "")
        .trimmingCharacters(in: .newlines)
}
func readField() -> String {
    if let text = axText() { return normalize(text) }
    pasteboard.clearContents()
    let before = pasteboard.changeCount
    press(0, flags: .maskCommand)
    Thread.sleep(forTimeInterval: 0.25)
    press(8, flags: .maskCommand)
    let deadline = Date().addingTimeInterval(1.5)
    while pasteboard.changeCount == before, Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
    let text = pasteboard.string(forType: .string) ?? ""
    press(124) // Collapse the selection to the end.
    Thread.sleep(forTimeInterval: 0.1)
    return normalize(text)
}
func clearField() {
    if let text = axText() {
        guard !text.isEmpty else { return }
        var range = CFRange(location: 0, length: text.utf16.count)
        AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &range)!)
        Thread.sleep(forTimeInterval: 0.15)
    } else {
        press(0, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.25)
    }
    press(51)
    Thread.sleep(forTimeInterval: 0.3)
}

var failures = 0
for name in selected {
    let test = cases[name]!
    clearField()
    selectLayout(test.layout)
    for character in test.keys {
        if character == "⇧" {
            Thread.sleep(forTimeInterval: 0.15)
            post(56, down: true, flags: .maskShift); Thread.sleep(forTimeInterval: 0.07); post(56, down: false)
            continue
        }
        guard let (key, shifted) = positions[character] else { fail("No key for \(character)") }
        if shifted { post(56, down: true, flags: .maskShift) }
        press(key, flags: shifted ? .maskShift : [])
        if shifted { post(56, down: false) }
        Thread.sleep(forTimeInterval: name == "fast-phrase" ? 0.012 : 0.06)
    }
    Thread.sleep(forTimeInterval: 0.8)
    let actual = readField()
    // Editors may trim or keep a trailing space when copying; compare without it.
    let ok = actual.trimmingCharacters(in: .whitespaces) == test.expected.trimmingCharacters(in: .whitespaces)
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")\t\(name)\texpected=\(test.expected.debugDescription)\tactual=\(actual.debugDescription)")
}
clearField()
selectLayout("ABC")
restoreClipboard()
exit(failures == 0 ? 0 : 1)
