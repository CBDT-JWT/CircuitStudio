import AppKit
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
func drawLogo() {
    NSColor(red: 0.08, green: 0.46, blue: 0.41, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    NSColor.white.setStroke(); NSColor.white.setFill()
    let path = NSBezierPath(); path.lineWidth = 36; path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.move(to: NSPoint(x: 190, y: 512)); path.line(to: NSPoint(x: 410, y: 512))
    path.move(to: NSPoint(x: 410, y: 660)); path.line(to: NSPoint(x: 410, y: 364))
    path.move(to: NSPoint(x: 495, y: 694)); path.line(to: NSPoint(x: 495, y: 330))
    path.move(to: NSPoint(x: 495, y: 645)); path.line(to: NSPoint(x: 715, y: 645)); path.line(to: NSPoint(x: 715, y: 815))
    path.move(to: NSPoint(x: 495, y: 379)); path.line(to: NSPoint(x: 715, y: 379)); path.line(to: NSPoint(x: 715, y: 209)); path.stroke()
    for point in [NSPoint(x: 190, y: 512), NSPoint(x: 715, y: 815), NSPoint(x: 715, y: 209)] {
        NSBezierPath(ovalIn: NSRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56)).fill()
    }
}
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(cgContext: cg, flipped: false)
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: Double(pixels) / 1024, y: Double(pixels) / 1024)
    drawLogo()
    NSGraphicsContext.restoreGraphicsState()
    let file = folder.appendingPathComponent("icon-\(pixels).png")
    let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(file.path)") }
}
var images: [[String: String]] = [
    ["filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]
]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        images.append(["filename": "icon-\(size * scale).png", "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let data = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try data.write(to: folder.appendingPathComponent("Contents.json"))
print("Generated opaque iOS and all macOS App Store icon sizes.")
