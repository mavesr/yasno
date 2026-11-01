// Lists the ordinary windows on the current Space (front to back) and what AX hit-testing finds at a point.
// With Stage Manager on, only the active application's windows are on screen; the rest are thumbnails.
// usage: windows-on-screen [x y]
import Cocoa
import ApplicationServices

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
    let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
    let name = window[kCGWindowName as String] as? String ?? ""
    let bounds = window[kCGWindowBounds as String] as? NSDictionary ?? [:]
    print("\(owner) (\(pid)) '\(name)' \(bounds["X"] ?? 0),\(bounds["Y"] ?? 0) \(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0)")
}
let args = Array(CommandLine.arguments.dropFirst())
if args.count == 2, let x = Float(args[0]), let y = Float(args[1]) {
    var hit: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), x, y, &hit)
    var pid: pid_t = 0
    var role: CFTypeRef?
    if let hit { AXUIElementGetPid(hit, &pid); AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role) }
    print("hit at \(x),\(y): result=\(result.rawValue) pid=\(pid) \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "") role=\(role as? String ?? "?")")
}
