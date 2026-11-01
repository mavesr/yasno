import Cocoa

let width: CGFloat = 660
let height: CGFloat = 440
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1320, pixelsHigh: 880,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let green = NSColor(calibratedRed: 0.13, green: 0.35, blue: 0.32, alpha: 1)
NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.95, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
func centered(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
    let text = value as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    text.draw(at: NSPoint(x: (width - text.size(withAttributes: attrs).width) / 2, y: y), withAttributes: attrs)
}
centered("Ясно", y: 357, size: 36, weight: .semibold, color: green)
centered("Перетащите «Ясно» в папку «Программы»", y: 321, size: 18, color: green)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 302, y: 214))
arrow.line(to: NSPoint(x: 358, y: 214))
arrow.move(to: NSPoint(x: 347, y: 225))
arrow.line(to: NSPoint(x: 358, y: 214))
arrow.line(to: NSPoint(x: 347, y: 203))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
green.withAlphaComponent(0.6).setStroke()
arrow.stroke()
centered("macOS 14+  ·  Apple Silicon", y: 40, size: 12, color: .gray)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
