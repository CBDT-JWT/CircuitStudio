import Foundation
import CoreGraphics

public enum FigureKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case rectangle = "Block", roundedRectangle = "Rounded block", ellipse = "Ellipse", diamond = "Decision", triangle = "Triangle", text = "Text"
    case inputPort = "Input port", outputPort = "Output port", bidirectionalPort = "Bidirectional port"
    case summingJunction = "Summing junction", parallelogram = "Data / I/O", hexagon = "Preparation", cylinder = "Database"
    public var id: String { rawValue }
    public var icon: String { switch self { case .rectangle: "rectangle"; case .roundedRectangle: "rectangle.roundedtop"; case .ellipse: "circle"; case .diamond: "diamond"; case .triangle: "triangle"; case .text: "textformat"; case .inputPort: "arrow.right.to.line"; case .outputPort: "arrow.left.to.line"; case .bidirectionalPort: "arrow.left.arrow.right"; case .summingJunction: "plus.circle"; case .parallelogram: "rectangle.on.rectangle"; case .hexagon: "hexagon"; case .cylinder: "cylinder" } }
    public var category: String {
        switch self { case .inputPort, .outputPort, .bidirectionalPort, .summingJunction: "Ports & signal flow"; case .diamond, .parallelogram, .hexagon, .cylinder: "Flowchart"; default: "Shapes & text" }
    }
}
public struct FigureStyle: Codable, Hashable, Sendable {
    public var width = 1.6
    public var dashed = false
    /// nil follows the canvas foreground, including Dark Mode.
    public var color: String? = nil
    public var fill: String? = nil
    public init() {}
}
public struct FigureElement: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: FigureKind
    public var position: Point
    public var size = Point(140, 70)
    public var rotation = 0
    public var text: String
    public var fontSize = 18.0
    public var style = FigureStyle()
    public init(_ kind: FigureKind, at position: Point, text: String? = nil) {
        self.kind = kind; self.position = position
        self.text = text ?? (kind == .text ? "V_{OUT}" : kind == .diamond ? "Converged?" : kind == .triangle ? "A" : kind == .ellipse ? "Start" : "Amplifier")
        if kind == .diamond { size = Point(140, 100) }
        if kind == .ellipse { size = Point(100, 60) }
        if kind == .triangle { size = Point(100, 90) }
        if kind == .text { size = Point(160, 40) }
        switch kind {
        case .inputPort: size = Point(100, 40); self.text = text ?? "IN"
        case .outputPort: size = Point(100, 40); self.text = text ?? "OUT"
        case .bidirectionalPort: size = Point(120, 40); self.text = text ?? "I/O"
        case .summingJunction: size = Point(44, 44); self.text = text ?? "+"; fontSize = 24
        case .parallelogram: self.text = text ?? "Data"
        case .hexagon: self.text = text ?? "Initialize"
        case .cylinder: size = Point(110, 100); self.text = text ?? "Storage"
        default: break
        }
    }
    public func world(_ p: Point) -> Point { position + p.transformed(rotation: rotation, flipX: false, flipY: false) }
    public var bounds: Bounds { Bounds([world(Point(-size.x / 2, -size.y / 2)), world(Point(size.x / 2, -size.y / 2)), world(Point(size.x / 2, size.y / 2)), world(Point(-size.x / 2, size.y / 2))]) }
    public var anchors: [Pin] { [Pin("left", Point(-size.x / 2, 0)), Pin("right", Point(size.x / 2, 0)), Pin("top", Point(0, -size.y / 2)), Pin("bottom", Point(0, size.y / 2))] }
    public func anchor(_ name: String) -> Point? { anchors.first { $0.name == name }.map { world($0.offset) } }
    public var outline: [Point] {
        let w = size.x / 2, h = size.y / 2
        let local: [Point]
        switch kind {
        case .text: return []
        case .rectangle: local = [Point(-w, -h), Point(w, -h), Point(w, h), Point(-w, h)]
        case .diamond: local = [Point(0, -h), Point(w, 0), Point(0, h), Point(-w, 0)]
        case .triangle: local = [Point(-w, -h), Point(w, 0), Point(-w, h)]
        case .inputPort: local = [Point(-w, -h), Point(w - h, -h), Point(w, 0), Point(w - h, h), Point(-w, h)]
        case .outputPort: local = [Point(-w, 0), Point(-w + h, -h), Point(w, -h), Point(w, h), Point(-w + h, h)]
        case .bidirectionalPort, .hexagon:
            let inset = min(w * 0.35, h)
            local = [Point(-w, 0), Point(-w + inset, -h), Point(w - inset, -h), Point(w, 0), Point(w - inset, h), Point(-w + inset, h)]
        case .parallelogram: local = [Point(-w + w * 0.3, -h), Point(w, -h), Point(w - w * 0.3, h), Point(-w, h)]
        case .ellipse, .summingJunction: local = (0..<256).map { i in let a = Double(i) / 256 * 2 * Double.pi; return Point(w * cos(a), h * sin(a)) }
        case .cylinder:
            let cap = min(h * 0.28, 14)
            let top = (0...64).map { i in let a = Double.pi + Double(i) / 64 * Double.pi; return Point(w * cos(a), -h + cap + cap * sin(a)) }
            let bottom = (0...64).map { i in let a = Double(i) / 64 * Double.pi; return Point(w * cos(a), h - cap + cap * sin(a)) }
            local = top + bottom
        case .roundedRectangle:
            let r = min(10, min(w, h) / 2)
            let corners = [(Point(w - r, h - r), 0.0), (Point(-w + r, h - r), Double.pi / 2), (Point(-w + r, -h + r), Double.pi), (Point(w - r, -h + r), 3 * Double.pi / 2)]
            local = corners.flatMap { center, start in (0...32).map { i in let a = start + Double(i) / 32 * Double.pi / 2; return center + Point(r * cos(a), r * sin(a)) } }
        }
        return local.map(world)
    }
    public var texts: [DrawingText] {
        let lines = text.components(separatedBy: .newlines)
        var size = fontSize
        if kind != .text {
            let available = max(15, self.size.x - (kind == .diamond ? 50 : 20))
            let widest = lines.map { Symbols.textBounds(DrawingText(text: $0, point: .zero, size: fontSize)).width - 5 }.max() ?? 0
            if widest > available { size = max(8, fontSize * available / widest) }
            size = min(size, max(8, (self.size.y - 16) / Double(max(1, lines.count)) / 1.35))
        }
        let height = Double(lines.count) * size * 1.35
        return lines.enumerated().map { i, line in
            let width = Symbols.textBounds(DrawingText(text: line, point: .zero, size: size)).width - 5
            return DrawingText(text: line, point: position + Point(-width / 2, -height / 2 + Double(i) * size * 1.35), size: size)
        }
    }
}
public enum FigureArrows: String, Codable, CaseIterable, Sendable { case none = "None", end = "End", both = "Both" }
public enum FigureRoute: String, Codable, CaseIterable, Sendable { case straight = "Straight", orthogonal = "Orthogonal" }
public struct FigureConnector: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var points: [Point]
    public var start: TerminalRef?
    public var end: TerminalRef?
    public var arrows: FigureArrows = .end
    public var route: FigureRoute = .straight
    public var text = ""
    public var labelOffset: Point? = nil
    public var style = FigureStyle()
    public init(from a: Point, to b: Point, start: TerminalRef? = nil, end: TerminalRef? = nil) { points = [a, b]; self.start = start; self.end = end }
}
public struct VectorLayer: Sendable {
    public var primitives: [Primitive] = []
    public var texts: [DrawingText] = []
    public var style = FigureStyle()
    public init() {}
}
public extension Circuit {
    var objectIDs: Set<UUID> { Set(components.map(\.id) + wires.map(\.id) + labels.map(\.id) + figures.map(\.id) + figureConnectors.map(\.id)) }
    func resolvedPoints(_ connector: FigureConnector) -> [Point] {
        guard let first = connector.points.first, let last = connector.points.last else { return [] }
        let a = connector.start.flatMap { position(of: $0) } ?? first
        let b = connector.end.flatMap { position(of: $0) } ?? last
        if connector.route == .orthogonal { return WireRouting.route(from: a, to: b, obstacles: figures.map(\.bounds) + components.map(\.bodyBounds)) }
        var points = connector.points; points[0] = a; points[points.count - 1] = b; return points
    }
    var figureLayers: [VectorLayer] {
        var layers: [VectorLayer] = []; var connectors: [VectorLayer] = []
        func academic(_ style: FigureStyle) -> FigureStyle {
            var style = style
            if mode == .publication {
                style.color = nil
                if let fill = style.fill, let rgb = UInt32(fill, radix: 16) { let gray = Int(0.299 * Double((rgb >> 16) & 255) + 0.587 * Double((rgb >> 8) & 255) + 0.114 * Double(rgb & 255)); style.fill = String(format: "%02x%02x%02x", gray, gray, gray) }
            }
            return style
        }
        for connector in figureConnectors {
            let points = resolvedPoints(connector); guard points.count > 1 else { continue }
            var layer = VectorLayer(); layer.style = academic(connector.style); layer.primitives = [.line(points)]
            func arrow(_ from: Point, _ tip: Point) -> Primitive {
                let angle = atan2(tip.y - from.y, tip.x - from.x), size = 9.0 + layer.style.width
                return .polygon([tip, tip - Point(cos(angle - 0.42), sin(angle - 0.42)) * size, tip - Point(cos(angle + 0.42), sin(angle + 0.42)) * size], filled: true)
            }
            if connector.arrows != .none, let last = points.last, let previous = points.dropLast().last(where: { $0.distance(to: last) > 0.01 }) { layer.primitives.append(arrow(previous, last)) }
            if connector.arrows == .both, let first = points.first, let next = points.dropFirst().first(where: { $0.distance(to: first) > 0.01 }) { layer.primitives.append(arrow(next, first)) }
            if !connector.text.isEmpty {
                let a = points[points.count / 2 - 1], b = points[points.count / 2]
                let middle = a + (b - a) * 0.5
                let width = Symbols.textBounds(DrawingText(text: connector.text, point: .zero, size: 14)).width - 5
                let offset = abs(b.y - a.y) > abs(b.x - a.x) ? Point(12, -9) : Point(-width / 2, -24)
                layer.texts = [DrawingText(text: connector.text, point: middle + offset + (connector.labelOffset ?? .zero), size: 14)]
            }
            connectors.append(layer)
        }
        for figure in figures {
            let outline = figure.outline, style = academic(figure.style)
            if !outline.isEmpty, let fill = style.fill { var background = VectorLayer(); background.style.color = fill; background.primitives = [.polygon(outline, filled: true)]; layers.append(background) }
            var layer = VectorLayer(); layer.style = style; layer.texts = figure.texts
            if !outline.isEmpty { layer.primitives = [.polygon(outline, filled: false)] }
            if figure.kind == .cylinder {
                let w = figure.size.x / 2, h = figure.size.y / 2, cap = min(h * 0.28, 14)
                let rim = (0...128).map { i in let a = Double(i) / 128 * 2 * Double.pi; return figure.world(Point(w * cos(a), -h + cap + cap * sin(a))) }
                layer.primitives.append(.line(rim))
            }
            layers.append(layer)
        }
        return layers + connectors
    }
}
