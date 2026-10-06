import Foundation
import CoreGraphics
import CoreText

public enum Primitive: Sendable {
    case line([Point])
    case circle(Point, Double, filled: Bool)
    case polygon([Point], filled: Bool)
}
public struct DrawingText: Sendable { public var text: String; public var point: Point; public var size: Double; public var secondary: Bool = false }
public struct VectorScene: Sendable { public var primitives: [Primitive] = []; public var texts: [DrawingText] = []; public var layers: [VectorLayer] = [] }

public enum Symbols {
    public static func geometry(_ component: Component, theme: SymbolTheme) -> [Primitive] {
        var result: [Primitive] = []
        func line(_ points: Point...) { result.append(.line(points)) }
        func circle(_ center: Point, _ r: Double, fill: Bool = false) { result.append(.circle(center, r, filled: fill)) }
        func arrow(_ start: Point, _ end: Point, shaft: Bool = true) {
            if shaft { line(start, end) }
            let angle = atan2(end.y - start.y, end.x - start.x), size = 7.0
            result.append(.polygon([end, Point(end.x - size * cos(angle - 0.45), end.y - size * sin(angle - 0.45)), Point(end.x - size * cos(angle + 0.45), end.y - size * sin(angle + 0.45))], filled: true))
        }
        switch component.kind {
        case .resistor:
            line(Point(0, -40), Point(0, -24)); line(Point(0, 24), Point(0, 40))
            if theme == .iec { result.append(.polygon([Point(-9, -24), Point(9, -24), Point(9, 24), Point(-9, 24)], filled: false)) }
            else { result.append(.line([Point(0, -24), Point(-8, -20), Point(8, -12), Point(-8, -4), Point(8, 4), Point(-8, 12), Point(8, 20), Point(0, 24)])) }
        case .capacitor, .polarizedCapacitor:
            line(Point(0, -40), Point(0, -5)); line(Point(-16, -5), Point(16, -5)); line(Point(-16, 5), Point(16, 5)); line(Point(0, 5), Point(0, 40))
            if component.kind == .polarizedCapacitor { line(Point(-23, -15), Point(-15, -15)); line(Point(-19, -19), Point(-19, -11)) }
        case .inductor:
            line(Point(0, -40), Point(0, -24)); line(Point(0, 24), Point(0, 40))
            for i in 0..<4 {
                let cy = -18.0 + Double(i) * 12
                result.append(.line((0...16).map { j in let t = Double(j) / 16 * .pi; return Point(10 * sin(t), cy - 6 * cos(t)) }))
            }
        case .voltageSource, .acVoltage, .pulseSource, .currentSource:
            line(Point(0, -40), Point(0, -20)); line(Point(0, 20), Point(0, 40)); circle(.zero, 20)
            switch component.kind {
            case .currentSource: arrow(Point(0, -11), Point(0, 11))
            case .acVoltage: result.append(.line((0...32).map { i in let x = -12 + Double(i) * 24 / 32; return Point(x, -6 * sin((x + 12) / 24 * 2 * .pi)) }))
            case .pulseSource: line(Point(-12, 6), Point(-6, 6), Point(-6, -6), Point(6, -6), Point(6, 6), Point(12, 6))
            default: line(Point(-5, -8), Point(5, -8)); line(Point(0, -13), Point(0, -3)); line(Point(-5, 9), Point(5, 9))
            }
        case .nmos, .pmos:
            let academic = theme == .razavi
            // Ratios measured from Razavi EE215A HO#2 p.3, figure (a)/(b).
            // Fixed pins retain the document grid and existing electrical connections.
            let channelX = academic ? -3.0 : 0.0
            let gateX = academic ? -9.0 : -14.0
            let gateHalf = academic ? 9.0 : 19.0
            let channelHalf = academic ? 12.0 : 22.0
            let branchY = academic ? 8.0 : 20.0
            line(Point(-40, 0), Point(gateX, 0))
            if academic {
                // Short, slightly heavier gate/channel bars match the supplied Razavi reference.
                result.append(.polygon([Point(gateX - 1.5, -gateHalf), Point(gateX + 1.5, -gateHalf), Point(gateX + 1.5, gateHalf), Point(gateX - 1.5, gateHalf)], filled: true))
                result.append(.polygon([Point(channelX - 1.6, -channelHalf), Point(channelX + 1.6, -channelHalf), Point(channelX + 1.6, channelHalf), Point(channelX - 1.6, channelHalf)], filled: true))
            } else { line(Point(gateX, -gateHalf), Point(gateX, gateHalf)); line(Point(0, -channelHalf), Point(0, channelHalf)) }
            line(Point(channelX, -branchY), Point(10, -branchY), Point(10, -40))
            line(Point(channelX, branchY), Point(10, branchY), Point(10, 40))
            // One source arrow, with the source above for PMOS and below for NMOS.
            if component.kind == .nmos { arrow(Point(channelX, branchY), Point(academic ? 7 : 10, branchY)) }
            else { arrow(Point(10, -branchY), Point(0, -branchY)) }
            if theme == .ieee { circle(Point(0, 0), 28) }
            if theme == .iec { line(Point(-3, -22), Point(3, -22)); line(Point(-3, 22), Point(3, 22)) }
            if component.parameters["bulk"] == "external" {
                // Optional B terminal is a dotted guide, never a second polarity arrow.
                for x in stride(from: 1.0, through: 37.0, by: 4.0) { line(Point(x, 0), Point(x + 1.2, 0)) }
                line(Point(38, 0), Point(40, 0))
            }
        case .npn, .pnp:
            if theme == .razavi {
                // Razavi Fundamentals of Microelectronics, Ch.4 slides 118/155:
                // compact heavy base, shallow symmetric branches, long C/E leads.
                let baseX = -3.0, baseHalf = 9.0
                let collector = Point(baseX, -4.5), emitter = Point(baseX, 4.5)
                let emitterElbow = Point(10, 10)
                line(Point(-40, 0), Point(baseX, 0))
                result.append(.polygon([Point(baseX - 1.5, -baseHalf), Point(baseX + 1.5, -baseHalf), Point(baseX + 1.5, baseHalf), Point(baseX - 1.5, baseHalf)], filled: true))
                line(collector, Point(10, -10), Point(10, -40))
                line(emitter, emitterElbow, Point(10, 40))
                let outward = component.kind == .npn
                let tip = emitter + (emitterElbow - emitter) * (outward ? 0.82 : 0.23)
                arrow(outward ? emitter : emitterElbow, tip, shaft: false)
            } else {
                line(Point(-40, 0), Point(-8, 0)); line(Point(-8, -20), Point(-8, 20)); line(Point(-8, -10), Point(10, -24), Point(10, -40)); line(Point(-8, 10), Point(10, 24), Point(10, 40))
                arrow(component.kind == .npn ? Point(-3, 14) : Point(10, 24), component.kind == .npn ? Point(10, 24) : Point(-3, 14))
                if theme == .ieee { circle(.zero, 28) }
            }
        case .diode, .zener, .led:
            line(Point(0, -40), Point(0, -12)); line(Point(0, 12), Point(0, 40)); result.append(.polygon([Point(-12, -12), Point(12, -12), Point(0, 12)], filled: false)); line(Point(-13, 12), Point(13, 12))
            if component.kind == .zener { line(Point(-13, 12), Point(-13, 7)); line(Point(13, 12), Point(13, 17)) }
            if component.kind == .led { arrow(Point(15, -8), Point(26, -19)); arrow(Point(20, 2), Point(31, -9)) }
        case .opAmp:
            result.append(.polygon([Point(-24, -32), Point(-24, 32), Point(30, 0)], filled: false))
            line(Point(-40, -20), Point(-24, -20)); line(Point(-40, 20), Point(-24, 20)); line(Point(30, 0), Point(40, 0)); line(Point(-18, -20), Point(-10, -20)); line(Point(-18, 20), Point(-10, 20)); line(Point(-14, 16), Point(-14, 24))
        case .ground:
            line(Point(0, 0), Point(0, 12)); line(Point(-16, 12), Point(16, 12)); line(Point(-10, 18), Point(10, 18)); line(Point(-4, 24), Point(4, 24))
        case .vdd:
            line(.zero, Point(0, -26)); line(Point(-14, -26), Point(14, -26))
        case .vss:
            line(.zero, Point(0, 26)); line(Point(-14, 26), Point(14, 26))
        case .port:
            line(.zero, Point(12, 0)); result.append(.polygon([Point(12, -8), Point(25, -8), Point(33, 0), Point(25, 8), Point(12, 8)], filled: false))
        }
        func transform(_ p: Point) -> Point { component.world(p) }
        return result.map {
            switch $0 {
            case .line(let p): .line(p.map(transform))
            case .circle(let p, let r, let filled): .circle(transform(p), r, filled: filled)
            case .polygon(let p, let filled): .polygon(p.map(transform), filled: filled)
            }
        }
    }
    public static func scene(_ circuit: Circuit) -> VectorScene {
        var scene = VectorScene()
        for wire in circuit.wires { scene.primitives.append(.line(circuit.resolvedPoints(wire))) }
        for component in circuit.components {
            let primitives = geometry(component, theme: circuit.mode == .publication ? .razavi : circuit.theme)
            scene.primitives += primitives
            if component.kind == .ground { continue }
            // Annotation remains upright, clear of geometry in every orientation.
            let offset: Point
            if component.kind == .vdd || component.kind == .vss {
                let end = component.world(Point(0, component.kind == .vdd ? -26 : 26)) - component.position
                let width = textBounds(DrawingText(text: referenceLabel(component.name), point: .zero, size: 16)).width - 5
                if abs(end.x) > abs(end.y) { offset = Point(end.x > 0 ? end.x + 10 : end.x - width - 10, -11) }
                else { offset = Point(-width / 2, end.y > 0 ? end.y + 5 : end.y - 25) }
            }
            else if component.kind == .opAmp { offset = Point(-18, 44) }
            else if component.kind == .port { offset = Point(45, -11) }
            else {
                // Measure the actual symbol, including LED arrows and transformed pins.
                // Keep both annotation lines upright and outside it after rotation or mirroring.
                let rightEdge = primitives.map { primitive -> Double in
                    switch primitive {
                    case .line(let points), .polygon(let points, _): return points.map(\.x).max() ?? component.position.x
                    case .circle(let center, let radius, _): return center.x + radius
                    }
                }.max() ?? component.position.x
                offset = Point(max(30, rightEdge - component.position.x + 15), -15)
            }
            if component.showName { scene.texts.append(DrawingText(text: referenceLabel(component.name), point: component.position + offset, size: 16)) }
            if component.showValue && !component.valueLabel.isEmpty { scene.texts.append(DrawingText(text: component.valueLabel, point: component.position + offset + Point(0, 24), size: 12, secondary: true)) }
        }
        for label in circuit.labels { scene.texts.append(DrawingText(text: label.text, point: label.position + (label.isNet ? Point(7, -24) : .zero), size: label.isNet ? 16 : 20)) }
        for p in Connectivity(circuit).connectionDots { scene.primitives.append(.circle(p, 3, filled: true)) }
        scene.layers = circuit.figureLayers
        return scene
    }
    public static func referenceLabel(_ text: String) -> String {
        if ["VDD", "VSS", "VCC", "VEE"].contains(text) { return "V_{" + text.dropFirst() + "}" }
        guard let index = text.firstIndex(where: \.isNumber) else { return text }
        return String(text[..<index]) + "_{" + String(text[index...]) + "}"
    }
    public static func drawingBounds(_ circuit: Circuit) -> Bounds {
        let scene = scene(circuit); var points: [Point] = []
        for p in scene.primitives + scene.layers.flatMap(\.primitives) { switch p { case .line(let ps), .polygon(let ps, _): points += ps; case .circle(let c, let r, _): points += [c - Point(r, r), c + Point(r, r)] } }
        for text in scene.texts + scene.layers.flatMap(\.texts) { let bounds = textBounds(text); points += [Point(bounds.minX, bounds.minY), Point(bounds.maxX, bounds.maxY)] }
        return Bounds(points.isEmpty ? [Point(0, 0), Point(600, 400)] : points, padding: 30)
    }
    public static func textBounds(_ text: DrawingText) -> Bounds {
        var width = 0.0
        for run in MathLabel.runs(text.text) { let font = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, text.size * (run.subscripted ? 0.73 : 1), nil); let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]; let line = CTLineCreateWithAttributedString(NSAttributedString(string: run.text, attributes: attributes)); width += CTLineGetTypographicBounds(line, nil, nil, nil) }
        return Bounds([text.point + Point(-2, -2), text.point + Point(width + 3, text.size * 1.5)])
    }
}

public enum CircuitRenderer {
    public static func draw(_ circuit: Circuit, in context: CGContext, dark: Bool = false, lineWidth: Double = 1.6) {
        let scene = Symbols.scene(circuit)
        draw(scene, in: context, dark: dark, lineWidth: lineWidth)
    }
    public static func draw(_ scene: VectorScene, in context: CGContext, dark: Bool = false, lineWidth: Double = 1.6) {
        let ink = dark ? CGColor(gray: 0.91, alpha: 1) : CGColor(gray: 0.12, alpha: 1)
        draw(scene.primitives, texts: scene.texts, in: context, ink: ink, lineWidth: lineWidth)
        for layer in scene.layers {
            context.saveGState()
            if layer.style.dashed { context.setLineDash(phase: 0, lengths: [6, 4]) }
            draw(layer.primitives, texts: layer.texts, in: context, ink: color(layer.style.color) ?? ink, lineWidth: layer.style.width)
            context.restoreGState()
        }
    }
    public static func color(_ hex: String?) -> CGColor? {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return CGColor(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
    private static func draw(_ primitives: [Primitive], texts: [DrawingText], in context: CGContext, ink: CGColor, lineWidth: Double) {
        context.setStrokeColor(ink); context.setFillColor(ink); context.setLineWidth(lineWidth); context.setLineCap(.round); context.setLineJoin(.round)
        for primitive in primitives {
            switch primitive {
            case .line(let points): stroke(points, in: context)
            case .polygon(let points, let filled):
                guard let first = points.first else { continue }; context.beginPath(); context.move(to: CGPoint(x: first.x, y: first.y))
                for p in points.dropFirst() { context.addLine(to: CGPoint(x: p.x, y: p.y)) }; context.closePath(); filled ? context.fillPath() : context.strokePath()
            case .circle(let p, let r, let filled):
                let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
                filled ? context.fillEllipse(in: rect) : context.strokeEllipse(in: rect)
            }
        }
        for text in texts { drawText(text, in: context, color: ink) }
    }
    public static func stroke(_ points: [Point], in context: CGContext) {
        guard let first = points.first else { return }; context.beginPath(); context.move(to: CGPoint(x: first.x, y: first.y))
        for p in points.dropFirst() { context.addLine(to: CGPoint(x: p.x, y: p.y)) }; context.strokePath()
    }
    public static func drawText(_ text: DrawingText, in context: CGContext, color: CGColor) {
        let string = NSMutableAttributedString(string: "")
        for run in MathLabel.runs(text.text) {
            let font = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, text.size * (run.subscripted ? 0.73 : 1), nil)
            let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color, NSAttributedString.Key(kCTBaselineOffsetAttributeName as String): run.subscripted ? -text.size * 0.23 : 0]
            string.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        let line = CTLineCreateWithAttributedString(string)
        context.saveGState(); context.translateBy(x: text.point.x, y: text.point.y + text.size); context.scaleBy(x: 1, y: -1); context.textMatrix = .identity; context.textPosition = .zero; CTLineDraw(line, context); context.restoreGState()
    }
}
