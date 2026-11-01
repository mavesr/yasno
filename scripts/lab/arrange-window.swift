// Moves and resizes the front window of an application so test windows do not overlap. With Stage
// Manager on, keep test windows at x ≥ 260 so the thumbnail strip stays visible for switch-test.
// usage: arrange-window <bundle id> <x> <y> <width> <height>   (top-left screen coordinates)
import Cocoa
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 5, let x = Double(args[1]), let y = Double(args[2]), let w = Double(args[3]), let h = Double(args[4]) else {
    fputs("usage: arrange-window <bundle id> <x> <y> <width> <height>\n", stderr); exit(2)
}
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == args[0] && $0.processIdentifier > 0 }) else {
    fputs("not running: \(args[0])\n", stderr); exit(1)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
func element(_ name: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, name as CFString, &value) == .success, let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
var windows: CFTypeRef?
AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windows)
guard let window = element(kAXFocusedWindowAttribute) ?? element(kAXMainWindowAttribute) ?? (windows as? [AXUIElement])?.first else {
    fputs("no window\n", stderr); exit(1)
}
var origin = CGPoint(x: x, y: y), size = CGSize(width: w, height: h)
let p = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
let s = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
var title: CFTypeRef?
AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
print("\(app.localizedName ?? args[0]) '\(title as? String ?? "")' position=\(p.rawValue) size=\(s.rawValue)")
