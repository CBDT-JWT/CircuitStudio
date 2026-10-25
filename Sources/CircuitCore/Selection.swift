import Foundation

public extension Bounds {
    func intersects(_ other: Bounds) -> Bool { minX <= other.maxX && maxX >= other.minX && minY <= other.maxY && maxY >= other.minY }
    func intersectsSegment(_ a: Point, _ b: Point) -> Bool {
        var low = 0.0, high = 1.0
        let delta = b-a
        for (p,q) in [(-delta.x,a.x-minX),(delta.x,maxX-a.x),(-delta.y,a.y-minY),(delta.y,maxY-a.y)] {
            if abs(p) < 1e-12 { if q < 0 { return false }; continue }
            let t = q/p
            if p < 0 { low = max(low,t) } else { high = min(high,t) }
            if low > high { return false }
        }
        return true
    }
}
public extension Circuit {
    func objects(in rect: Bounds) -> Set<UUID> {
        var ids = Set(components.filter { rect.intersects($0.bodyBounds) || Symbols.componentLabels($0,theme:theme,appearance:appearance).contains { rect.intersects(Symbols.textBounds($0.text)) } }.map(\.id))
        ids.formUnion(figures.filter { rect.intersects($0.bounds) }.map(\.id))
        ids.formUnion(labels.filter { rect.intersects(Symbols.textBounds(DrawingText(text:$0.text,point:$0.position + ($0.isNet ? Point(7,-24) : .zero),size:$0.isNet ? 16 : 20))) }.map(\.id))
        func touched(_ ps: [Point]) -> Bool { zip(ps,ps.dropFirst()).contains { rect.intersectsSegment($0,$1) } }
        ids.formUnion(wires.filter { wire in touched(resolvedPoints(wire)) || powerRailLabel(wire).map { rect.intersects(Symbols.textBounds($0)) } == true }.map(\.id))
        ids.formUnion(figureConnectors.filter { touched(resolvedPoints($0)) }.map(\.id))
        return ids
    }
    /// A detached snapshot with visible geometry resolved before dropping outside pins.
    func selected(_ ids: Set<UUID>) -> Circuit {
        var output = self
        output.components = components.filter { ids.contains($0.id) || ($0.kind == .noConnect && $0.parameters["attachedComponent"].flatMap(UUID.init(uuidString:)).map { ids.contains($0) } == true) }
        output.figures = figures.filter { ids.contains($0.id) }
        let bodies = Set(output.components.map(\.id)+output.figures.map(\.id)+wires.filter { $0.powerNet != nil && ids.contains($0.id) }.map(\.id))
        func inside(_ ref: TerminalRef?) -> Bool { ref.map { bodies.contains($0.componentID) } ?? false }
        output.wires = wires.filter { ids.contains($0.id) || (inside($0.start) && inside($0.end)) }.map {
            var w = $0; w.points = resolvedPoints(w); if !inside(w.start) { w.start = nil }; if !inside(w.end) { w.end = nil }; return w
        }
        output.figureConnectors = figureConnectors.filter { ids.contains($0.id) || (inside($0.start) && inside($0.end)) }.map {
            var c = $0; c.points = resolvedPoints(c); if !inside(c.start) { c.start = nil }; if !inside(c.end) { c.end = nil }; return c
        }
        output.labels = labels.filter { ids.contains($0.id) }
        let selectedPaths = output.wires.flatMap { zip($0.points,$0.points.dropFirst()).map { ($0,$1) } }
        output.junctions = junctions.filter { p in selectedPaths.contains { distanceToSegment(p,$0.0,$0.1)<0.01 } }
        output.handDrawing = nil; output.annotationDrawing = nil
        return output
    }
}
