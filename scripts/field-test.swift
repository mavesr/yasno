// Types fixed phrases into one test field with real key events and checks what Ясно made of
// them. Only windows whose title contains the given marker are touched (the local field lab,
// the YasnoLab window, an unsaved TextEdit document, a Google document named «Ясно тест»).
// Never sends Return.
//
//   field-test <bundle id | pid:N> <window title marker> <focus> [case… | @set…]
//   focus: dom:<DOM id> | class:<DOM class> | id:<accessibility identifier> | focused
//   sets:  @basic   every case a field that shows its text can take (the default)
//          @text    @basic plus Tab and a caret in the middle of a line (multi-line text views)
//          @secure  the password case alone: the word must stay as typed and the layout unchanged
//
// Keys are physical keys named by their ABC (US) characters; an uppercase letter or ! ( ) is typed
// with Shift. ⇧ is a lone Shift tap, ⌫ Backspace, ← Left arrow, ⇥ Tab, ⏸ a 0.8 s pause and
// ⌨ a switch to the Russian layout in the middle of the word, as if the user pressed the shortcut.
// After the first correction the layout is the right one, so the following words are typed as
// the user would type them: `vbh` on the Russian layout is already «мир».
//
// Fields are read through Accessibility; canvas editors (Google Docs) with Select All + Copy,
// and the clipboard is restored afterwards. Only the fixed sample words are ever printed.
import Cocoa
import Carbon
import ApplicationServices

func fail(_ text: String) -> Never { fputs(text + "\n", stderr); exit(2) }

struct Case {
    let layout: String
    let keys: String
    let expected: String
    var gap: TimeInterval = 0.06   // pause after each key
}
let cases: [String: Case] = [
    "abc-to-ru": Case(layout: "ABC", keys: "ghbdtn vbh ", expected: "привет мир "),
    "abc-to-uk": Case(layout: "ABC", keys: "ghsdbn ", expected: "привіт "),
    "ru-to-en": Case(layout: "Russian", keys: "hello world ", expected: "hello world "),
    "address": Case(layout: "Russian", keys: "account.apple.com ", expected: "account.apple.com "),
    "symbol-prefix": Case(layout: "ABC", keys: "(ghbdtn ", expected: "(привет "),
    "long-word": Case(layout: "ABC", keys: "ghjuhfvvf ", expected: "программа "),
    "capital": Case(layout: "ABC", keys: "Ghbdtn ", expected: "Привет "),
    "caps": Case(layout: "ABC", keys: "GHBDTN ", expected: "GHBDTN "),
    "punctuation": Case(layout: "ABC", keys: "ghbdtn! (vbh) ", expected: "привет! (мир) "),
    "code": Case(layout: "ABC", keys: "ghb123 ", expected: "ghb123 "),
    "backspace": Case(layout: "ABC", keys: "ghbdtm⌫n ", expected: "привет "),
    "slow": Case(layout: "ABC", keys: "ghbdtn ", expected: "привет ", gap: 0.3),
    "pause": Case(layout: "ABC", keys: "ghb⏸dtn ", expected: "привет "),
    "undo": Case(layout: "ABC", keys: "ghbdtn ⇧", expected: "ghbdtn "),
    "manual": Case(layout: "ABC", keys: "ghb⇧", expected: "при"),
    "native-ru": Case(layout: "Russian", keys: "z nen ", expected: "я тут "),
    "native-en": Case(layout: "ABC", keys: "hello world ", expected: "hello world "),
    "fast-phrase": Case(layout: "ABC", keys: "ghbdtn rfr ltkf ", expected: "привет как дела ", gap: 0.012),
    "switch-mid-word": Case(layout: "ABC", keys: "ghb⌨dtn ", expected: "ghbвет "),
    "tab": Case(layout: "ABC", keys: "ghbdtn⇥vbh ", expected: "привет\tмир "),
    "mid-line": Case(layout: "ABC", keys: "aaa bbb←←←ghbdtn ", expected: "aaa привет bbb"),
    "secure": Case(layout: "ABC", keys: "ghbdtn ", expected: "ghbdtn "),
]
let basic = ["abc-to-ru", "abc-to-uk", "ru-to-en", "address", "symbol-prefix", "long-word", "capital", "caps",
             "punctuation", "code", "backspace", "slow", "pause", "undo", "manual", "native-ru", "native-en",
             "fast-phrase", "switch-mid-word"]
let sets: [String: [String]] = ["@basic": basic, "@text": basic + ["tab", "mid-line"], "@secure": ["secure"]]

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3 else { fail("usage: field-test <bundle id> <title marker> <focus> [case… | @set…]") }
let bundleID = arguments[0], marker = arguments[1], focusSpec = arguments[2]
let selected = (arguments.count > 3 ? Array(arguments[3...]) : ["@basic"]).flatMap { sets[$0] ?? [$0] }
guard selected.allSatisfy({ cases[$0] != nil }) else { fail("Unknown case") }
guard CGPreflightPostEventAccess() else { fail("No permission to post keyboard events") }
// Keys posted at a locked screen would go to the password field.
let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
guard (session["CGSSessionScreenIsLocked"] as? Int ?? 0) == 0 else { fail("The screen is locked") }

// A just-launched application can be listed with pid -1 until the workspace catches up.
func running() -> NSRunningApplication? {
    if bundleID.hasPrefix("pid:"), let pid = pid_t(bundleID.dropFirst(4)) { return NSRunningApplication(processIdentifier: pid) }
    return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID && !$0.isTerminated && $0.processIdentifier > 0 }
}
var launched = running()
let launchDeadline = Date().addingTimeInterval(2)
while launched == nil, Date() < launchDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)); launched = running() }
guard let app = launched else { fail("\(bundleID) is not running") }
let ax = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
// NSRunningApplication.activate is advisory on recent macOS; raising through Accessibility works.
app.activate(options: [.activateAllWindows])
AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
let activation = Date().addingTimeInterval(2)
while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier, Date() < activation {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { fail("Cannot activate \(bundleID)") }

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
    case "id": target = find { attribute($0, kAXIdentifierAttribute) as? String == parts[1] }
    default: fail("Bad focus spec")
    }
    guard let target else { fail("Field \(focusSpec) not found") }
    AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.3)
}
guard let field = element(attribute(ax, kAXFocusedUIElementAttribute)) else { fail("No focused field") }
fputs("field: \(attribute(field, kAXRoleAttribute) as? String ?? "?") \(attribute(field, kAXSubroleAttribute) as? String ?? "") "
      + "\(attribute(field, "AXDOMIdentifier") as? String ?? attribute(field, kAXIdentifierAttribute) as? String ?? "")\n", stderr)

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
                                                 "(": (25, true), ")": (29, true), "!": (18, true), ";": (41, false),
                                                 "'": (39, false), "←": (123, false), "⌫": (51, false), "⇥": (48, false)]
for (letter, code) in zip("abcdefghijklmnopqrstuvwxyz", letterCodes) {
    positions[letter] = (code, false)
    positions[Character(letter.uppercased())] = (code, true)
}
for (digit, code) in zip("1234567890", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29] as [CGKeyCode]) { positions[digit] = (code, false) }

func selectLayout(_ suffix: String) {
    let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    guard let layout = list.first(where: {
        guard let pointer = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == "com.apple.keylayout." + suffix
    }), TISSelectInputSource(layout) == noErr else { fail("Layout \(suffix) is unavailable") }
    Thread.sleep(forTimeInterval: 0.15)
}
func currentLayout() -> String {
    let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let pointer = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else { return "?" }
    let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    return id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
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
/// Edit-menu command by its ⌘ key. Chrome may ignore synthesized ⌘ shortcuts; the menu works.
func menuCommand(_ character: String) {
    var queue = element(attribute(ax, kAXMenuBarAttribute)).map { [$0] } ?? [], visited = 0
    while !queue.isEmpty, visited < 3_000 {
        let item = queue.removeFirst(); visited += 1
        if attribute(item, "AXMenuItemCmdChar") as? String == character,
           (attribute(item, "AXMenuItemCmdModifiers") as? Int) == 0,
           attribute(item, kAXEnabledAttribute) as? Bool != false {
            AXUIElementPerformAction(item, kAXPressAction as CFString); return
        }
        queue += (attribute(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    press(character == "A" ? 0 : 8, flags: .maskCommand)
}
func readField() -> String {
    if let text = axText() { return normalize(text) }
    pasteboard.clearContents()
    let before = pasteboard.changeCount
    menuCommand("A")
    Thread.sleep(forTimeInterval: 0.25)
    menuCommand("C")
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
        menuCommand("A")
        Thread.sleep(forTimeInterval: 0.25)
    }
    press(51)
    // Backspace after a finished word reopens it in Ясно (the user erased the Space after it);
    // here it erased a selection instead. An arrow key makes Ясно forget the word, as it would
    // for a user who moved the caret.
    Thread.sleep(forTimeInterval: 0.1)
    press(124)
    Thread.sleep(forTimeInterval: 0.3)
}
func cyrillic(_ text: String) -> Bool { text.contains { ("а"..."я").contains($0) || ("А"..."Я").contains($0) || "іїєІЇЄёЁ".contains($0) } }

var failures = 0
for name in selected {
    let test = cases[name]!
    clearField()
    selectLayout(test.layout)
    for character in test.keys {
        switch character {
        case "⇧":
            Thread.sleep(forTimeInterval: 0.15)
            post(56, down: true, flags: .maskShift); Thread.sleep(forTimeInterval: 0.07); post(56, down: false)
            continue
        case "⏸": Thread.sleep(forTimeInterval: 0.8); continue
        case "⌨": selectLayout("Russian"); continue
        default: break
        }
        guard let (key, shifted) = positions[character] else { fail("No key for \(character)") }
        if shifted { post(56, down: true, flags: .maskShift) }
        press(key, flags: shifted ? .maskShift : [])
        if shifted { post(56, down: false) }
        Thread.sleep(forTimeInterval: test.gap)
    }
    Thread.sleep(forTimeInterval: 0.8)
    let actual = readField()
    let layout = currentLayout()
    let ok: Bool
    if name == "secure" {
        // A password field shows bullets; the word must not have been converted and the layout must stand.
        ok = !cyrillic(actual) && layout == test.layout
    } else {
        // Editors may trim or keep a trailing space when copying; compare without it.
        ok = actual.trimmingCharacters(in: .whitespaces) == test.expected.trimmingCharacters(in: .whitespaces)
    }
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")\t\(name)\texpected=\(test.expected.debugDescription)\tactual=\(actual.debugDescription)\tlayout=\(layout)")
}
clearField()
selectLayout("ABC")
restoreClipboard()
exit(failures == 0 ? 0 : 1)
