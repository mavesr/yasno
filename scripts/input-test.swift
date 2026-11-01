// Integration driver for the local browser test page. Never sends Return or submits a form.
import Cocoa
import Carbon
import ApplicationServices

func fail(_ text: String) -> Never { fputs(text + "\n", stderr); exit(1) }
let argument = CommandLine.arguments.dropFirst().first ?? ""
let mixedKeys: [CGKeyCode] = [5,4,11,2,17,45,49, 4,31,13,49, 0,15,14,49, 16,31,32,49,
    6,15,49, 45,1,49, 8,17,43,17,49, 5,38,7,14,2,3,39,34,49]
let nativeKeys: [CGKeyCode] = [6,49,45,14,45,49,6,49,45,3,9,49,45,1,49,
    45,14,45,49,6,49,45,3,9,49,45,17,15,8,45,49,6,49,45,14,45,49]
let nativeText = "я тут я там ты тут я там текст я тут "
let samples: [String: [CGKeyCode]] = [
    "hello": [4,14,37,37,31,49], "guten": [5,32,17,14,45,49],
    "russian": [5,4,11,2,17,45,49], "ukrainian": [5,4,1,2,11,45,49],
    "thanks": [37,6,15,14,47,49], "shared": [37,38,43,4,38,32,38,49],
    "manual-word": [37,38,43,4,38,32,38],
    "mixed-phrase": mixedKeys, "mixed-fast": mixedKeys,
    "short-uk": [6,15,49,45,1,49], "short-ns": [45,1,49],
    "inflections": [15,38,4,38,45,15,11,9,11,49, 5,4,38,32,4,3,9,9,1,49],
    "programs": [5,4,38,32,4,3,9,9,1,49],
    "keep-uk": [5,4,1,2,11,45,49], "keep-ru": [5,4,11,2,17,45,49],
    "rapid": [5,4,11,2,17,45,49,9,11,4,49], "password": [5,4,11,2,17,45,49]
]
let gestureTests = ["shift", "right-shift", "shift-hold", "shift-capital", "right-shift-capital", "shift-selection", "shift-modifier", "shift-control-first", "shift-both"]
let asciiFixtures = ["audit-prefix": "gj;", "audit-rest": "fkeqcnf ",
    "audit-words": "gj;fkeqcnf lj,hsq ye;yj lf;t nj;t cj,jq yflt.cm ",
    "audit-wsi": "dcb ", "audit-pri": "ghb ", "audit-byl": ",sk ",
    "audit-capitals": ":bpym <sk <eltn <jkmijt >hbq \\krf {jhjij ", "audit-suffix": "ns ",
    "compound-appstore": "appstore "]
let expectedText = ["expect-mixed": "привет how are you як ти себе почуваєш ",
    "expect-russian": "привет ", "expect-undo-russian": "ghbdtn ", "expect-capital": "H",
    "expect-short": "як ти ", "expect-inflections": "короткими программы ", "expect-programs": "программы ",
    "expect-rapid": "привет мир ", "expect-prefix": "gj;", "expect-please": "пожалуйста ",
    "expect-audit-words": "пожалуйста добрый нужно даже тоже собой надеюсь ",
    "expect-wsi": "всі ", "expect-pri": "при ", "expect-byl": "был ",
    "expect-capitals": "Жизнь Был Будет Большое Юрий ёлка Хорошо ",
    "expect-buttons": "buttons ", "expect-newline": "привет\n", "expect-valid-space": "Я использую ",
    "expect-punctuation": "ghbdtn, vbh", "expect-appstore": "appstore ", "expect-raw-appstore": "фззыещку "]
guard ["inspect", "clear", "stress-compounds", "stress-mixed", "stress-native", "stress-overlap", "stress-correction-overlap", "stress-manual-space", "expect-selection", "switch-layout", "double-shift", "select-abc", "select-ru", "select-uk", "expect-abc", "expect-ru", "expect-uk"].contains(argument) || asciiFixtures[argument] != nil || expectedText[argument] != nil || gestureTests.contains(argument) || samples[argument] != nil else { fail("Unknown test") }
guard CGPreflightPostEventAccess() else { fail("The test driver has no permission to post keyboard events") }
// Keys posted at a locked screen would go to the password field.
let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
guard (session["CGSSessionScreenIsLocked"] as? Int ?? 0) == 0 else { fail("The screen is locked") }
if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.google.Chrome" {
    guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else { fail("Chrome is not running") }
    chrome.activate(options: [.activateAllWindows])
    let deadline = Date().addingTimeInterval(1)
    while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.google.Chrome", Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}
guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.google.Chrome" else { fail("Chrome must be frontmost") }
let ax = AXUIElementCreateApplication(app.processIdentifier)
var window: CFTypeRef?
guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { fail("Cannot read the focused window") }
let axWindow = unsafeBitCast(window, to: AXUIElement.self)
var title: CFTypeRef?
AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &title)
guard (title as? String)?.contains("Ясно — проверка раскладки") == true else { fail("Only the Yasno local test window is allowed") }
var focused: CFTypeRef?
guard AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { fail("Focus a test text field") }
let field = unsafeBitCast(focused, to: AXUIElement.self)
var role: CFTypeRef?, subrole: CFTypeRef?
AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &role)
AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole)
let secure = subrole as? String == kAXSecureTextFieldSubrole
if argument == "password" { print("Password test metadata:", role as? String ?? "nil", subrole as? String ?? "nil", "secure input", IsSecureEventInputEnabled()) }
let normalField = [kAXTextFieldRole, kAXTextAreaRole].contains(role as? String ?? "") && !secure
guard argument == "password" ? (secure || IsSecureEventInputEnabled()) : normalField else { fail("Focus the appropriate local test field") }
let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
let currentID = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(current,kTISPropertyInputSourceID)!).takeUnretainedValue() as String
print("Test field input source:", currentID)
if argument == "inspect" {
    var value: CFTypeRef?, selection: CFTypeRef?
    AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
    AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selection)
    var range = CFRange()
    if let selection, CFGetTypeID(selection) == AXValueGetTypeID() {
        AXValueGetValue(unsafeBitCast(selection, to: AXValue.self), .cfRange, &range)
    }
    print("Local test value:", String(reflecting: value as? String ?? ""), "selection:", range.location, range.length)
    exit(0)
}
if let expected = expectedText[argument] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
          let text = value as? String else { fail("Cannot read the local test field") }
    let normalized = text.replacingOccurrences(of: "\u{00a0}", with: " ").replacingOccurrences(of: "\u{202f}", with: " ")
    guard normalized == expected else { fail("Unexpected local test text: " + normalized) }
    print("Local test text verified:", argument)
    exit(0)
}
if argument == "expect-selection" {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
          let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { fail("Cannot read test selection") }
    var range = CFRange()
    guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range), range.length == 1 else { fail("Shift+Arrow did not select one character") }
    print("Shift+Arrow selection verified")
    exit(0)
}
if let suffix = ["expect-abc": "ABC", "expect-ru": "Russian", "expect-uk": "Ukrainian"][argument] {
    guard currentID == "com.apple.keylayout." + suffix else { fail("Unexpected input source; expected " + suffix) }
    print("Input source verified:", suffix)
    exit(0)
}
if let suffix = ["select-abc": "ABC", "select-ru": "Russian", "select-uk": "Ukrainian"][argument] {
    let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    guard let layout = list.first(where: {
        guard let pointer = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == "com.apple.keylayout." + suffix
    }), TISSelectInputSource(layout) == noErr else { fail("Test layout is unavailable") }
    print("Selected test layout:", suffix)
    exit(0)
}
if ["russian", "ukrainian", "thanks", "shared", "manual-word", "rapid", "password", "mixed-phrase", "mixed-fast", "short-uk", "short-ns"].contains(argument), currentID != "com.apple.keylayout.ABC" { fail("Select ABC for this test") }
if ["inflections", "programs"].contains(argument), currentID != "com.apple.keylayout.Ukrainian" { fail("Select Ukrainian for this test") }
if ["hello", "guten"].contains(argument), !currentID.contains("Russian"), !currentID.contains("Ukrainian") { fail("Select a Cyrillic layout for this test") }
if argument == "keep-uk", !currentID.contains("Ukrainian") { fail("Select Ukrainian for this test") }
if argument == "keep-ru", !currentID.contains("Russian") { fail("Select Russian for this test") }
if asciiFixtures[argument] != nil {
    let required = argument == "compound-appstore" ? "Russian" : (argument == "audit-byl" ? "Ukrainian" : "ABC")
    guard currentID == "com.apple.keylayout." + required else { fail("Select the required layout for the fixed fixture") }
}
guard let source = CGEventSource(stateID: .privateState) else { fail("No event source") }
func post(_ key: CGKeyCode, down: Bool, shift: Bool = false, control: Bool = false, command: Bool = false) {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { fail("Focus changed; test aborted") }
    if down {
        var latestFocus: CFTypeRef?, latestTitle: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &latestFocus)
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &latestTitle)
        guard let latestFocus, CFEqual(latestFocus, field),
              (latestTitle as? String)?.contains("Ясно — проверка раскладки") == true else { fail("Local test field lost focus") }
    }
    let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)!
    event.flags = shift ? [.maskShift] : []
    if control { event.flags.insert(.maskControl) }
    if command { event.flags.insert(.maskCommand) }
    event.setIntegerValueField(.eventSourceUserData, value: 0x5941534E4F54)
    if [CGKeyCode(56), 60, 59].contains(key) { event.type = .flagsChanged }
    event.post(tap: .cghidEventTap)
}
func clearTestField() {
    post(0, down: true, command: true); post(0, down: false, command: true)
    // A busy renderer applies Select All asynchronously. Confirm the selection before
    // sending Backspace so fixture setup cannot race the keyboard behavior under test.
    let selectDeadline = Date().addingTimeInterval(1.5)
    var selected = false
    repeat {
        var raw: CFTypeRef?, value: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &raw)
        AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
        var range = CFRange()
        if let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range)
        }
        if let text = value as? String {
            selected = (range.location == 0 && range.length == text.utf16.count && range.length > 0) ||
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !selected { Thread.sleep(forTimeInterval: 0.01) }
    } while !selected && Date() < selectDeadline
    guard selected else { fail("Test field did not finish Select All") }
    post(51, down: true); post(51, down: false)
    let clearDeadline = Date().addingTimeInterval(1.5)
    var cleared = false
    repeat {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
        cleared = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
        if !cleared { Thread.sleep(forTimeInterval: 0.01) }
    } while !cleared && Date() < clearDeadline
    guard cleared else { fail("Test field did not finish clearing") }
}
if argument == "clear" {
    clearTestField()
} else if argument == "stress-compounds" {
    let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    let codes: [CGKeyCode] = [0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]
    let positions = Dictionary(uniqueKeysWithValues: zip("abcdefghijklmnopqrstuvwxyz", codes))
    let words = ["appstore", "dropbox", "screenshot", "playstore", "smartwatch", "clouddrive"]
    for iteration in 0..<12 {
        clearTestField()
        let suffix = iteration < 6 ? "Russian" : "Ukrainian"
        let word = words[iteration % words.count]
        guard let layout = sources.first(where: {
            guard let pointer = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
            return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == "com.apple.keylayout." + suffix
        }), TISSelectInputSource(layout) == noErr else { fail("Cannot select fixture layout") }
        Thread.sleep(forTimeInterval: 0.04)
        // Continue immediately after Space to verify ordering across the correction.
        let expected = word + " hello "
        for character in expected {
            let key = character == " " ? CGKeyCode(49) : positions[character]!
            post(key, down: true); post(key, down: false)
            Thread.sleep(forTimeInterval: 0.008)
        }
        let deadline = Date().addingTimeInterval(1.5)
        var rendered = ""
        repeat {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
            rendered = (value as? String ?? "").replacingOccurrences(of: "\u{00a0}", with: " ")
            if rendered == expected { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        guard rendered == expected else { fail("Compound iteration \(iteration + 1) failed: " + rendered) }
        print("Compound iteration", iteration + 1, suffix, word, "passed")
    }
} else if argument == "stress-manual-space" {
    let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    func select(_ suffix: String) {
        guard let target = sources.first(where: {
            guard let pointer = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
            return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == "com.apple.keylayout." + suffix
        }), TISSelectInputSource(target) == noErr else { fail("Cannot select fixture layout") }
    }
    let fixtures: [(String, [CGKeyCode], String, [CGKeyCode])] = [
        ("ABC", [4,14,37,37,31,49], "руддщ я тут ", [6,49,45,14,45,49]),
        ("ABC", [12,6,12,7,12,6,49], "йяйчйя я тут ", [6,49,45,14,45,49]),
        ("Russian", [5,4,11,2,17,45,49], "ghbdtn hello ", [4,14,37,37,31,49])
    ]
    for iteration in 1...18 {
        let fixture = fixtures[(iteration - 1) % fixtures.count]
        clearTestField()
        select(fixture.0)
        Thread.sleep(forTimeInterval: 0.04)
        for key in fixture.1.dropLast() {
            post(key, down: true); post(key, down: false)
            Thread.sleep(forTimeInterval: 0.008)
        }
        let overlappingSpace = iteration.isMultiple(of: 2)
        post(49, down: true)
        if !overlappingSpace { post(49, down: false) }
        post(56, down: true, shift: true)
        if overlappingSpace { post(49, down: false, shift: true) }
        Thread.sleep(forTimeInterval: 0.04)
        post(56, down: false)
        // Start typing immediately; no artificial wait for the manual conversion.
        for key in fixture.3 {
            post(key, down: true); post(key, down: false)
            Thread.sleep(forTimeInterval: 0.008)
        }
        let deadline = Date().addingTimeInterval(1.5)
        var rendered = ""
        repeat {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
            rendered = (value as? String ?? "").replacingOccurrences(of: "\u{00a0}", with: " ")
            if rendered == fixture.2 { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        guard rendered == fixture.2 else { fail("Manual-after-space iteration \(iteration) failed: " + rendered) }
        print("Manual-after-space iteration", iteration, "passed")
    }
} else if argument == "stress-native" || argument == "stress-overlap" || argument == "stress-correction-overlap" {
    guard currentID == "com.apple.keylayout.Russian" else { fail("Select Russian for the native-input test") }
    let correcting = argument == "stress-correction-overlap"
    let keys = correcting ? [CGKeyCode(5),4,11,2,17,45,49,6,49,45,49] + nativeKeys : nativeKeys
    let expected = correcting ? "привет я т " + nativeText : nativeText
    let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    let abc = sources.first {
        guard let pointer = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == "com.apple.keylayout.ABC"
    }!
    for iteration in 1...25 {
        clearTestField()
        if correcting { guard TISSelectInputSource(abc) == noErr else { fail("Cannot select ABC") }; Thread.sleep(forTimeInterval: 0.04) }
        var held: CGKeyCode?
        for key in keys {
            if held == key { post(key, down: false); held = nil }
            post(key, down: true)
            Thread.sleep(forTimeInterval: 0.006)
            if let held { post(held, down: false) }
            if argument != "stress-native" { held = key }
            else { post(key, down: false); held = nil }
            Thread.sleep(forTimeInterval: 0.006)
        }
        if let held { post(held, down: false) }
        let deadline = Date().addingTimeInterval(1.5)
        var rendered = ""
        repeat {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
            rendered = (value as? String ?? "").replacingOccurrences(of: "\u{00a0}", with: " ")
            if rendered == expected { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        guard rendered == expected else { fail("Native-input iteration \(iteration) failed: " + rendered) }
        print("Native-input iteration", iteration, "passed")
        Thread.sleep(forTimeInterval: 0.04)
    }
} else if argument == "stress-mixed" {
    let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
    let abc = list.first { source in
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String == "com.apple.keylayout.ABC"
    }!
    for iteration in 1...12 {
        clearTestField()
        guard TISSelectInputSource(abc) == noErr else { fail("Cannot select test ABC") }
        Thread.sleep(forTimeInterval: 0.04)
        for key in mixedKeys {
            post(key, down: true); post(key, down: false)
            Thread.sleep(forTimeInterval: 0.015)
        }
        let deadline = Date().addingTimeInterval(1)
        var rendered = ""
        repeat {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
            rendered = (value as? String ?? "").replacingOccurrences(of: "\u{00a0}", with: " ")
            if rendered == expectedText["expect-mixed"] { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        guard rendered == expectedText["expect-mixed"] else { fail("Stress iteration \(iteration) failed: " + rendered) }
        print("Stress iteration", iteration, "passed")
    }
} else if let fixture = asciiFixtures[argument] {
    let codes: [CGKeyCode] = [0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]
    var positions: [Character: (CGKeyCode, Bool)] = [:]
    for (letter, code) in zip("abcdefghijklmnopqrstuvwxyz", codes) { positions[letter] = (code, false) }
    for (letter, code) in [(Character(" "), CGKeyCode(49)), (";",41), (",",43), (".",47), ("`",50), ("\\",42), ("[",33), ("]",30)] { positions[letter] = (code, false) }
    for (letter, code) in [(Character(":"), CGKeyCode(41)), ("<",43), (">",47), ("{",33)] { positions[letter] = (code, true) }
    for character in fixture {
        guard let (key, shifted) = positions[character] else { fail("Invalid fixed audit fixture") }
        post(key, down: true, shift: shifted); post(key, down: false, shift: shifted)
        Thread.sleep(forTimeInterval: argument == "audit-words" ? 0.015 : 0.06)
    }
    Thread.sleep(forTimeInterval: 0.12)
} else if gestureTests.contains(argument) {
    let key: CGKeyCode = argument.hasPrefix("right-") ? 60 : 56
    if argument == "shift-control-first" { post(59, down: true, control: true) }
    post(key, down: true, shift: true, control: argument == "shift-control-first")
    Thread.sleep(forTimeInterval: argument == "shift-hold" ? 0.6 : 0.07)
    if argument == "shift-capital" || argument == "right-shift-capital" {
        post(4, down: true, shift: true)
        post(4, down: false, shift: true)
    } else if argument == "shift-selection" {
        post(123, down: true, shift: true)
        post(123, down: false, shift: true)
    } else if argument == "shift-modifier" {
        post(59, down: true, shift: true, control: true)
        post(59, down: false, shift: true)
    } else if argument == "shift-both" {
        post(60, down: true, shift: true)
        post(56, down: false, shift: true)
        post(60, down: false)
    }
    if argument != "shift-both" { post(key, down: false, control: argument == "shift-control-first") }
    if argument == "shift-control-first" { post(59, down: false) }
    Thread.sleep(forTimeInterval: 0.12)
} else if argument == "switch-layout" {
    post(59, down: true, control: true)
    post(49, down: true, control: true)
    post(49, down: false, control: true)
    post(59, down: false)
} else if argument == "double-shift" {
    for _ in 0..<2 {
        post(56, down: true, shift: true)
        Thread.sleep(forTimeInterval: 0.07)
        post(56, down: false)
        Thread.sleep(forTimeInterval: 0.09)
    }
} else {
    for key in samples[argument]! {
        post(key, down: true)
        post(key, down: false)
        Thread.sleep(forTimeInterval: argument == "mixed-fast" ? 0.015 : (argument == "rapid" ? (key == 49 ? 0.04 : 0.015) : 0.08))
    }
}
print("System-key test sent:", argument)
