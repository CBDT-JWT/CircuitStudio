import AppKit
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
func drawLogo(in context: CGContext, mac: Bool) {
    let bounds = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let tile = mac ? bounds.insetBy(dx: 58, dy: 58) : bounds
    let outline = NSBezierPath(roundedRect: tile, xRadius: mac ? 199 : 0, yRadius: mac ? 199 : 0)
    NSGraphicsContext.saveGraphicsState()
    if mac {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(red: 0, green: 0.17, blue: 0.15, alpha: 0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -9)
        shadow.shadowBlurRadius = 26
        shadow.set()
        NSColor(red: 0.04, green: 0.24, blue: 0.22, alpha: 1).setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
    }
    outline.addClip()
    let light = NSColor(srgbRed: 0.10, green: 0.53, blue: 0.46, alpha: 1)
    let dark = NSColor(srgbRed: 0.025, green: 0.25, blue: 0.24, alpha: 1)
    NSGradient(starting: light, ending: dark)!.draw(in: tile, angle: -62)
    if mac {
        NSColor.white.withAlphaComponent(0.20).setStroke()
        let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 3, dy: 3), xRadius: 196, yRadius: 196)
        rim.lineWidth = 4
        rim.stroke()
    }
    if mac {
        context.translateBy(x: 51, y: 51)
        context.scaleBy(x: 0.90, y: 0.90)
    }
    let mint = NSColor(srgbRed: 0.69, green: 0.99, blue: 0.87, alpha: 1)
    let white = NSColor(srgbRed: 0.96, green: 1, blue: 0.99, alpha: 1)
    let gate = NSBezierPath()
    gate.move(to: NSPoint(x: 222, y: 512))
    gate.line(to: NSPoint(x: 400, y: 512))
    gate.move(to: NSPoint(x: 400, y: 652))
    gate.line(to: NSPoint(x: 400, y: 372))
    let channel = NSBezierPath()
    channel.move(to: NSPoint(x: 526, y: 669))
    channel.line(to: NSPoint(x: 526, y: 355))
    channel.move(to: NSPoint(x: 526, y: 640))
    channel.line(to: NSPoint(x: 761, y: 640))
    channel.line(to: NSPoint(x: 761, y: 777))
    channel.move(to: NSPoint(x: 526, y: 384))
    channel.line(to: NSPoint(x: 761, y: 384))
    channel.line(to: NSPoint(x: 761, y: 247))
    for path in [gate, channel] {
        path.lineWidth = 59
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
    }
    mint.setStroke()
    gate.stroke()
    white.setStroke()
    channel.stroke()
    for (center, color) in [(NSPoint(x: 222, y: 512), mint),
                           (NSPoint(x: 761, y: 777), white),
                           (NSPoint(x: 761, y: 247), white)] {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 41, y: center.y - 41, width: 82, height: 82)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ pixels: Int, mac: Bool) {
    let alpha: CGImageAlphaInfo = mac ? .premultipliedLast : .noneSkipLast
    let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: alpha.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    cg.scaleBy(x: Double(pixels) / 1024, y: Double(pixels) / 1024)
    drawLogo(in: cg, mac: mac)
    NSGraphicsContext.restoreGraphicsState()
    let name = mac ? "icon-\(pixels).png" : "icon-ios-1024.png"
    let file = folder.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(file.path)") }
}
for pixels in [16, 32, 64, 128, 256, 512, 1024] { render(pixels, mac: true) }
render(1024, mac: false)
var images: [[String: String]] = [
    ["filename": "icon-ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]
]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        images.append(["filename": "icon-\(size * scale).png", "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let data = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try data.write(to: folder.appendingPathComponent("Contents.json"))
print("Generated opaque iOS and all macOS App Store icon sizes.")
