import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Re-encode simulator PNGs as opaque sRGB without changing their size or layout.
// App Store screenshots must not include a transparency channel.
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: original.width, height: original.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fatalError("Cannot decode screenshot: \(path)")
    }
    let rect = CGRect(x: 0, y: 0, width: original.width, height: original.height)
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
    context.draw(original, in: rect)
    let data = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot encode screenshot: \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG encoding failed: \(path)") }
    try (data as Data).write(to: url, options: .atomic)
    print("Opaque screenshot: \(path) (\(original.width)×\(original.height))")
}
