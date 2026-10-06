import AppKit

let size = NSSize(width: 640, height: 400)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.955, green: 0.969, blue: 0.957, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
}
let ink = NSColor(calibratedRed: 0.13, green: 0.23, blue: 0.19, alpha: 1)
let gray = NSColor(calibratedRed: 0.35, green: 0.41, blue: 0.38, alpha: 1)
text("Circuit Studio", x: 44, y: 320, size: 27, weight: .semibold, color: ink)
text("Drag the app into Applications.", x: 44, y: 286, size: 15, color: gray)
let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 290, y: 200)); arrow.line(to: NSPoint(x: 350, y: 200)); arrow.move(to: NSPoint(x: 338, y: 211)); arrow.line(to: NSPoint(x: 350, y: 200)); arrow.line(to: NSPoint(x: 338, y: 189)); arrow.lineWidth = 2.5; ink.setStroke(); arrow.stroke()
text("Draw. Simulate. Explain.", x: 44, y: 55, size: 13, color: gray)
text("macOS 26+  /  Apple Silicon + Intel", x: 44, y: 31, size: 11, color: gray)
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render installer background") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
