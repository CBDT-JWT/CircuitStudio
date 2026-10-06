import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum CircuitExport {
    public static func svg(_ circuit: Circuit, transparent: Bool = true) -> String {
        let bounds = circuit.bounds, scene = Symbols.scene(circuit)
        func xml(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        func xy(_ p: Point) -> String { "\(p.x),\(p.y)" }
        var lines = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(bounds.width)\" height=\"\(bounds.height)\" viewBox=\"\(bounds.minX) \(bounds.minY) \(bounds.width) \(bounds.height)\">", "<title>\(xml(circuit.title))</title>"]
        if !transparent { lines.append("<rect x=\"\(bounds.minX)\" y=\"\(bounds.minY)\" width=\"\(bounds.width)\" height=\"\(bounds.height)\" fill=\"white\"/>") }
        func emit(_ primitives: [Primitive], _ texts: [DrawingText], color: String = "202020", width: Double = 1.6, dashed: Bool = false) {
        let color = CircuitRenderer.color(color) == nil ? "202020" : color
        lines.append("<g stroke=\"#\(color)\" stroke-width=\"\(width)\" stroke-linecap=\"round\" stroke-linejoin=\"round\" fill=\"none\"\(dashed ? " stroke-dasharray=\"6 4\"" : "")>")
        for primitive in primitives {
            switch primitive {
            case .line(let p): lines.append("<polyline points=\"\(p.map(xy).joined(separator: " "))\"/>")
            case .polygon(let p, let fill): lines.append("<polygon points=\"\(p.map(xy).joined(separator: " "))\" fill=\"\(fill ? "#" + color : "none")\"/>")
            case .circle(let p, let r, let fill): lines.append("<circle cx=\"\(p.x)\" cy=\"\(p.y)\" r=\"\(r)\" fill=\"\(fill ? "#" + color : "none")\"/>")
            }
        }
        lines.append("</g><g fill=\"#\(color)\" font-family=\"Times New Roman, Times, serif\">")
        for text in texts {
            let spans = MathLabel.runs(text.text).map { run in run.subscripted ? "<tspan baseline-shift=\"sub\" font-size=\"73%\">\(xml(run.text))</tspan>" : "<tspan>\(xml(run.text))</tspan>" }.joined()
            lines.append("<text x=\"\(text.point.x)\" y=\"\(text.point.y + text.size)\" font-size=\"\(text.size)\">\(spans)</text>")
        }
        lines.append("</g>")
        }
        emit(scene.primitives, scene.texts)
        for layer in scene.layers { emit(layer.primitives, layer.texts, color: layer.style.color ?? "202020", width: layer.style.width, dashed: layer.style.dashed) }
        lines.append("</svg>"); return lines.joined(separator: "\n")
    }
    public static func pdf(_ circuit: Circuit) throws -> Data {
        let bounds = circuit.bounds; let data = NSMutableData(); var page = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw CircuitError.message("Could not create the PDF.") }
        context.beginPDFPage(nil); context.translateBy(x: -bounds.minX, y: bounds.height + bounds.minY); context.scaleBy(x: 1, y: -1)
        CircuitRenderer.draw(circuit, in: context); context.endPDFPage(); context.closePDF(); return data as Data
    }
    public static func raster(_ circuit: Circuit, scale: Double = 2, transparent: Bool = true, type: UTType = .png) throws -> Data {
        let bounds = circuit.bounds; let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        guard scale > 0, width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 40_000_000 else { throw CircuitError.message("The export is too large. Choose a lower resolution.") }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CircuitError.message("Could not allocate the export image.") }
        if !transparent || type == .jpeg { context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        context.translateBy(x: 0, y: Double(height)); context.scaleBy(x: scale, y: -scale); context.translateBy(x: -bounds.minX, y: -bounds.minY); CircuitRenderer.draw(circuit, in: context)
        guard let image = context.makeImage() else { throw CircuitError.message("Could not render the image.") }
        let data = NSMutableData(); guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { throw CircuitError.message("This image format is unavailable.") }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CircuitError.message("Could not encode the image.") }; return data as Data
    }
}
