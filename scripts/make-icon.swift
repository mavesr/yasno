import Cocoa
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.13, green: 0.35, blue: 0.32, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p * 0.05, y: p * 0.05, width: p * 0.9, height: p * 0.9), xRadius: p * 0.22, yRadius: p * 0.22).fill()
        let font = NSFont.systemFont(ofSize: p * 0.63, weight: .medium)
        let text = "Я" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedRed: 0.89, green: 0.97, blue: 0.87, alpha: 1)]
        let measured = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (p - measured.width) / 2, y: (p - measured.height) / 2 + p * 0.018), withAttributes: attrs)
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
