// Closes the windows of an application whose title contains the marker, through the AX close button.
// Meant for the stand's own windows only (TextEdit asks about unsaved changes, nothing is discarded).
// usage: close-windows <bundle id> <title marker>
import Cocoa
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else { fputs("usage: close-windows <bundle id> <title marker>\n", stderr); exit(2) }
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == args[0] && $0.processIdentifier > 0 }) else {
    fputs("not running: \(args[0])\n", stderr); exit(1)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
var raw: CFTypeRef?
AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &raw)
var closed = 0
for window in (raw as? [AXUIElement]) ?? [] {
    var title: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
    guard (title as? String)?.contains(args[1]) == true else { continue }
    var button: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button,
          CFGetTypeID(button) == AXUIElementGetTypeID() else { continue }
    let result = AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString)
    print("closed '\(title as? String ?? "")' result=\(result.rawValue)")
    closed += 1
}
print("windows closed: \(closed)")
