import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum CircuitExport {
    public static func svg(_ circuit: Circuit, transparent: Bool = true) -> String {
        let bounds = circuit.bounds, scene = Symbols.scene(circuit)
        func xml(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        func xy(_ p: Point) -> String { "\(p.x),\(p.y)" }
        let dimensions = circuit.appearance?.widthMM.map { "width=\"\($0)mm\" height=\"\($0 * bounds.height / bounds.width)mm\"" } ?? "width=\"\(bounds.width)\" height=\"\(bounds.height)\""
        var lines = ["<svg xmlns=\"http://www.w3.org/2000/svg\" \(dimensions) viewBox=\"\(bounds.minX) \(bounds.minY) \(bounds.width) \(bounds.height)\">", "<title>\(xml(circuit.title))</title>"]
        var faces = ""
        for (weight,italic,face) in [(400,false,"Regular"),(400,true,"RegularItalic"),(700,false,"Bold"),(700,true,"BoldItalic")] {
            let font = SchematicTypography.font(size:16,bold:weight==700,italic:italic)
            _ = font
            #if SWIFT_PACKAGE
            let fontBundle = Bundle.module
            #else
            let fontBundle = Bundle.main
            #endif
            if let url=fontBundle.url(forResource:"Metropolis-"+face,withExtension:"ttf",subdirectory:"Fonts"),let data=try? Data(contentsOf:url) {
                faces += "@font-face{font-family:CSMetropolis;src:url(data:font/ttf;base64,\(data.base64EncodedString())) format('truetype');font-weight:\(weight);font-style:\(italic ? "italic" : "normal");}"
            }
        }
        if !faces.isEmpty { lines.append("<defs><style>"+faces+"</style></defs>") }
        if !transparent { lines.append("<rect x=\"\(bounds.minX)\" y=\"\(bounds.minY)\" width=\"\(bounds.width)\" height=\"\(bounds.height)\" fill=\"#\(circuit.appearance?.background ?? "ffffff")\"/>") }
        func emit(_ primitives: [Primitive], _ texts: [DrawingText], color: String = "202020", width: Double = 1.6, dashed: Bool = false, textColor: String? = nil) {
        let color = CircuitRenderer.color(color) == nil ? "202020" : color
        lines.append("<g stroke=\"#\(color)\" stroke-width=\"\(width)\" stroke-linecap=\"round\" stroke-linejoin=\"round\" fill=\"none\"\(dashed ? " stroke-dasharray=\"6 4\"" : "")>")
        for primitive in primitives {
            switch primitive {
            case .reference(let path):lines.append(path.svg(color:color))
            case .line(let p): lines.append("<polyline points=\"\(p.map(xy).joined(separator: " "))\"/>")
            case .polygon(let p, let fill): lines.append("<polygon points=\"\(p.map(xy).joined(separator: " "))\" fill=\"\(fill ? "#" + color : "none")\"/>")
            case .circle(let p, let r, let fill): lines.append("<circle cx=\"\(p.x)\" cy=\"\(p.y)\" r=\"\(r)\" fill=\"\(fill ? "#" + color : "none")\"/>")
            }
        }
        lines.append("</g><g fill=\"#\(textColor.flatMap { CircuitRenderer.color($0) == nil ? nil : $0 } ?? color)\" font-family=\"CSMetropolis, Metropolis, Arial, sans-serif\">")
        for text in texts {
            let spans = MathLabel.runs(text.text).map { run in run.subscripted ? "<tspan baseline-shift=\"sub\" font-size=\"73%\" font-style=\"normal\">\(xml(run.text))</tspan>" : "<tspan font-style=\"\(text.italic || text.reference ? "italic" : "normal")\">\(xml(run.text))</tspan>" }.joined()
            lines.append("<text x=\"\(text.point.x)\" y=\"\(text.point.y + text.size)\" font-size=\"\(text.size)\" font-weight=\"\(text.bold ? 700 : 400)\">\(spans)</text>")
        }
        lines.append("</g>")
        }
        emit(scene.primitives, scene.texts)
        for layer in scene.layers { emit(layer.primitives, layer.texts, color: layer.style.color ?? "202020", width: layer.style.width, dashed: layer.style.dashed, textColor: layer.style.textColor) }
        lines.append("</svg>"); return lines.joined(separator: "\n")
    }
    public static func pdf(_ circuit: Circuit, transparent: Bool = true) throws -> Data {
        let bounds = circuit.bounds; let scale=circuit.figurePointScale; let data = NSMutableData(); var page = CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw CircuitError.message("Could not create the PDF.") }
        context.beginPDFPage(nil); if !transparent { context.setFillColor(CircuitRenderer.color(circuit.appearance?.background) ?? CGColor(gray:1,alpha:1));context.fill(page) };context.scaleBy(x:scale,y:scale); context.translateBy(x: -bounds.minX, y: bounds.height + bounds.minY); context.scaleBy(x: 1, y: -1)
        CircuitRenderer.draw(circuit, in: context); context.endPDFPage(); context.closePDF(); return data as Data
    }
    public static func raster(_ circuit: Circuit, scale: Double = 2, transparent: Bool = true, type: UTType = .png) throws -> Data {
        let bounds = circuit.bounds; let scale=scale * circuit.figurePointScale; let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        guard scale > 0, width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 40_000_000 else { throw CircuitError.message("The export is too large. Choose a lower resolution.") }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CircuitError.message("Could not allocate the export image.") }
        if !transparent || type == .jpeg { context.setFillColor(CircuitRenderer.color(circuit.appearance?.background) ?? CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        context.translateBy(x: 0, y: Double(height)); context.scaleBy(x: scale, y: -scale); context.translateBy(x: -bounds.minX, y: -bounds.minY); CircuitRenderer.draw(circuit, in: context)
        guard let image = context.makeImage() else { throw CircuitError.message("Could not render the image.") }
        let data = NSMutableData(); guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { throw CircuitError.message("This image format is unavailable.") }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72 * scale / circuit.figurePointScale, kCGImagePropertyDPIHeight: 72 * scale / circuit.figurePointScale] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CircuitError.message("Could not encode the image.") }; return data as Data
    }
}
