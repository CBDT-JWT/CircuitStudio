import Foundation

/// Pencil strokes in canvas coordinates. Recognition never supplies component values.
public struct CircuitInkStroke: Sendable {
    public var points: [Point]
    public init(_ points: [Point]) { self.points = points }
}

public struct CircuitInkComponent: Identifiable, Sendable {
    public var id = UUID()
    public var kind: ComponentKind
    public var position: Point
    public var rotation: Int
    public var value = ""
    public var included = true
    public var anchors: [String: Point]
    public var strokeIndices: [Int] = []
}

public struct CircuitInkResult: Sendable {
    public var components: [CircuitInkComponent]
    public var wires: [Wire]
    public var unrecognizedStrokes: Int
    /// One entry per wire; -1 means a junction inferred from touching leads.
    public var wireStrokeIndices: [Int] = []
    public var wireInkStrokeIndices: [Int] { wireStrokeIndices.filter { $0 >= 0 } }

    /// A PencilKit stroke may have several visible ranges after erasing.
    /// Never remove its unrecognized ranges when converting only one range.
    public static func completeStrokeOrigins(_ origins: [Int], consuming indices: Set<Int>) -> Set<Int>? {
        guard indices.allSatisfy({ origins.indices.contains($0) }) else { return nil }
        let touched = Set(indices.map { origins[$0] })
        guard origins.indices.allSatisfy({ !touched.contains(origins[$0]) || indices.contains($0) }) else { return nil }
        return touched
    }

    /// Unchanged recent components do not have to be recognized again for a
    /// neighboring new symbol or wire to commit. Partly replaced history stays
    /// atomic so its existing component can never lose a raw stroke.
    public static func replacedHistoricalGroups(_ groups: [Set<Int>], consuming origins: Set<Int>) -> Set<Int>? {
        var replaced = Set<Int>()
        for (index, group) in groups.enumerated() {
            let touched = group.intersection(origins)
            if !touched.isEmpty {
                guard group.isSubset(of: origins) else { return nil }
                replaced.insert(index)
            }
        }
        return replaced
    }

    /// A wire can start at a pin and end freely, or branch from the middle of
    /// another wire. It does not need two already placed components to commit.
    public static func connectedWire(_ original: Wire, in circuit: Circuit, tolerance: Double = 16) -> Wire? {
        guard original.points.count >= 2 else { return nil }
        func attachment(_ point: Point) -> (Point, TerminalRef?)? {
            var choices = circuit.components.flatMap { component in component.pins.map { (component.world($0.offset), Optional(TerminalRef(component.id, $0.name))) } }
            for wire in circuit.wires {
                let points = circuit.resolvedPoints(wire)
                for (a, b) in zip(points, points.dropFirst()) {
                    let v = b - a, length = v.x*v.x + v.y*v.y
                    let t = length > 0 ? max(0, min(1, ((point.x-a.x)*v.x + (point.y-a.y)*v.y)/length)) : 0
                    choices.append((a + v*t, nil))
                }
            }
            return choices.filter { $0.0.distance(to: point) <= tolerance }.min { $0.0.distance(to: point) < $1.0.distance(to: point) }
        }
        let a = original.start == nil ? attachment(original.points[0]) : nil
        let b = original.end == nil ? attachment(original.points.last!) : nil
        guard original.start != nil || original.end != nil || a != nil || b != nil else { return nil }
        var wire = original
        if let a { wire.points[0] = a.0; wire.start = a.1 }
        if let b { wire.points[wire.points.count-1] = b.0; wire.end = b.1 }
        return wire
    }

    /// A reviewed draft with blank unknown values, ready for the existing editor.
    public func circuit(includeWires: Bool) throws -> Circuit {
        var result = Circuit(title: "Hand-drawn circuit")
        for candidate in components where candidate.included {
            guard candidate.position.x.isFinite, candidate.position.y.isFinite,
                  [0, 90, 180, 270].contains(candidate.rotation) else { throw CircuitError.message("Invalid recognized component geometry.") }
            _ = result.add(candidate.kind, at: candidate.position)
            let i = result.components.count - 1
            result.components[i].id = candidate.id
            result.components[i].rotation = candidate.rotation
            if result.components[i].parameters["value"] != nil { result.components[i].parameters["value"] = candidate.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard !result.components.isEmpty else { throw CircuitError.message("Select at least one component to import.") }
        if includeWires {
            func valid(_ ref: TerminalRef?) -> TerminalRef? { ref.flatMap { result.position(of: $0) == nil ? nil : $0 } }
            result.wires = wires.map { original in
                let a = valid(original.start), b = valid(original.end)
                let start = a.flatMap { result.position(of: $0) } ?? original.points[0]
                let end = b.flatMap { result.position(of: $0) } ?? original.points[original.points.count - 1]
                // Preserve sketched junction locations; bridge the moved native pins.
                var points = original.points
                if start != points[0] { points = WireRouting.route(from: start, to: points[0]) + points.dropFirst() }
                if end != points.last { points += WireRouting.route(from: points.last!, to: end).dropFirst() }
                return Wire(points: points, start: a, end: b)
            }
        }
        return result
    }
}

/// Conservative geometric recognition of separately drawn standard symbols.
/// Supports rectangular/zigzag resistors, capacitor plates, basic MOS, sources and ground bars.
/// Other symbols and text remain unrecognized for manual editing or cloud review.
public enum CircuitInkRecognizer {
    public static func contains(_ point: Point, in polygon: [Point]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false, previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y), point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x { inside.toggle() }
            previous = current
        }
        return inside
    }
    public static func recognize(_ ink: [CircuitInkStroke], preferredMOS: ComponentKind? = nil) throws -> CircuitInkResult {
        guard ink.count <= 500, ink.reduce(0, { $0 + $1.points.count }) <= 30_000 else { throw CircuitError.message("Split this drawing into smaller circuits (up to 500 strokes).") }
        guard ink.allSatisfy({ $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) < 100_000 && abs($0.y) < 100_000 } }) else { throw CircuitError.message("The drawing contains invalid coordinates.") }
        let strokes = ink.map { simplify($0.points, tolerance: 2.5) }
        let bounds = strokes.map { Bounds($0) }
        var used = Set<Int>(), components: [CircuitInkComponent] = []
        func add(_ kind: ComponentKind, _ position: Point, _ rotation: Int, _ anchors: [String: Point], _ indices: [Int]) {
            components.append(CircuitInkComponent(kind: kind, position: position, rotation: rotation, anchors: anchors, strokeIndices: indices)); used.formUnion(indices)
        }
        // IEC resistors are commonly drawn as a closed rectangle. Recognize
        // the outline before treating its sides as plates or wire candidates.
        // Joining up to four touching strokes also accepts a box drawn by sides.
        var joinsRemaining = 4_000
        struct Rectangle { var center: Point; var horizontal: Bool; var ends: [Point]; var box: Bounds; var tilt: Double }
        func outline(_ original: [Point]) -> Rectangle? {
            guard let longest = zip(original, original.dropFirst()).max(by: { $0.0.distance(to: $0.1) < $1.0.distance(to: $1.1) }) else { return nil }
            let tilt = axisTilt(longest.1 - longest.0)
            guard abs(tilt) <= .pi / 10 else { return nil }
            let points = original.map { rotated($0, by: -tilt) }
            let box = Bounds(points), major = max(box.width, box.height), minor = min(box.width, box.height)
            guard let first = points.first, let last = points.last, points.count >= 5,
                  major >= 18, major <= 260, minor >= 6, major / minor >= 1.65, major / minor <= 8,
                  first.distance(to: last) <= max(5, minor * 0.28),
                  pathLength(points) >= (box.width + box.height) * 1.75,
                  pathLength(points) <= (box.width + box.height) * 2.8 else { return nil }
            let tolerance = max(3, minor * 0.2)
            guard points.allSatisfy({ p in min(abs(p.x - box.minX), abs(p.x - box.maxX), abs(p.y - box.minY), abs(p.y - box.maxY)) <= tolerance }) else { return nil }
            let corners = [Point(box.minX, box.minY), Point(box.maxX, box.minY), Point(box.maxX, box.maxY), Point(box.minX, box.maxY)]
            guard corners.allSatisfy({ corner in points.contains { $0.distance(to: corner) <= max(5, minor * 0.3) } }) else { return nil }
            let horizontal = box.width > box.height
            let ends = horizontal ? [Point(box.minX, box.center.y), Point(box.maxX, box.center.y)] : [Point(box.center.x, box.minY), Point(box.center.x, box.maxY)]
            return Rectangle(center: rotated(box.center, by: tilt), horizontal: horizontal, ends: ends.map { rotated($0, by: tilt) }, box: box, tilt: tilt)
        }
        func rectangle(_ points: [Point]) -> Rectangle? {
            if let result = outline(points) { return result }
            // A pen can trace the lead, circle the box, and retrace the lead
            // without lifting. Only accept extra points on the terminal axes.
            guard points.count >= 6, points.count <= 32 else { return nil }
            for first in 0..<(points.count - 4) {
                for last in (first + 4)..<points.count {
                    guard var result = outline(Array(points[first...last])) else { continue }
                    let normalized = points.map { rotated($0, by: -result.tilt) }, box = result.box
                    let tolerance = max(3, min(box.width, box.height) * 0.15)
                    guard normalized.indices.allSatisfy({ i in
                        if (first...last).contains(i) { return true }
                        let p = normalized[i]
                        if result.horizontal { return abs(p.y - box.center.y) <= tolerance && (p.x <= box.minX + tolerance || p.x >= box.maxX - tolerance) }
                        return abs(p.x - box.center.x) <= tolerance && (p.y <= box.minY + tolerance || p.y >= box.maxY - tolerance)
                    }) else { continue }
                    let span = Bounds(normalized)
                    let ends = result.horizontal ? [Point(span.minX, box.center.y), Point(span.maxX, box.center.y)] : [Point(box.center.x, span.minY), Point(box.center.x, span.maxY)]
                    result.ends = ends.map { rotated($0, by: result.tilt) }
                    return result
                }
            }
            return nil
        }
        func closedBox(_ path: [Point], _ indices: [Int]) throws -> (Rectangle, [Int])? {
            if let box = rectangle(path) { return (box, indices) }
            guard indices.count < 4, joinsRemaining > 0, let end = path.last else { return nil }
            for j in strokes.indices where !used.contains(j) && !indices.contains(j) && strokes[j].count >= 2 && strokes[j].count <= 6 {
                try Task.checkCancellation()
                guard joinsRemaining > 0 else { break }
                let next = strokes[j]
                let reverse = end.distance(to: next.last!) < end.distance(to: next[0])
                let ordered = reverse ? Array(next.reversed()) : next
                guard end.distance(to: ordered[0]) <= 5 else { continue }
                joinsRemaining -= 1
                if let result = try closedBox(path + ordered, indices + [j]) { return result }
            }
            return nil
        }
        for i in strokes.indices where !used.contains(i) {
            try Task.checkCancellation()
            guard let (box, indices) = try closedBox(strokes[i], [i]) else { continue }
            add(.resistor, box.center, box.horizontal ? 270 : 0, ["1": box.ends[0], "2": box.ends[1]], indices)
        }
        // MOS: a separated gate and channel, with drain/source branches on the
        // opposite side. This takes precedence over the two parallel gate bars
        // resembling a capacitor. NMOS is the automatic draft; PMOS can be
        // selected explicitly because channel geometry alone has no polarity.
        // Try a few local handwriting angles, rather than rotating the whole
        // circuit into one frame. Separate symbols may lean in different directions.
        var tiltWeights: [Int: Double] = [:]
        for stroke in strokes {
            for (a, b) in zip(stroke, stroke.dropFirst()) where a.distance(to: b) >= 8 {
                let tilt = axisTilt(b - a)
                if abs(tilt) <= .pi / 10 {
                    let degrees = Int((tilt * 180 / .pi).rounded())
                    if abs(degrees) >= 2 { tiltWeights[degrees, default: 0] += a.distance(to: b) }
                }
            }
        }
        let tilts = [0.0] + tiltWeights.keys.sorted { tiltWeights[$0]! == tiltWeights[$1]! ? $0 < $1 : tiltWeights[$0]! > tiltWeights[$1]! }.prefix(4).map { Double($0) * .pi / 180 }
        for rotation in [0, 90, 180, 270] {
          for tilt in tilts {
            let angle = Double(rotation) * .pi / 180 + tilt
            let oriented = strokes.map { $0.map { rotated($0, by: -angle) } }
            struct Vertical { let index: Int; let x: Double; let low: Double; let high: Double; var length: Double { high - low }; var center: Point { Point(x, (low + high) / 2) } }
            var vertical: [Vertical] = []
            for i in oriented.indices where !used.contains(i) {
                for (a, b) in zip(oriented[i], oriented[i].dropFirst()) {
                    let length = abs(b.y - a.y)
                    if length >= 4, length <= 150, abs(a.x - b.x) <= max(2, length * 0.12), vertical.count < 600 {
                        let segment = Vertical(index: i, x: (a.x + b.x) / 2, low: min(a.y, b.y), high: max(a.y, b.y))
                        // A T-shaped gate often visits the lead midway through
                        // the same stroke. Join its two collinear halves.
                        if let j = vertical.indices.first(where: { vertical[$0].index == i && abs(vertical[$0].x - segment.x) <= 3 && segment.low <= vertical[$0].high + 3 && segment.high >= vertical[$0].low - 3 }) {
                            let previous = vertical[j]
                            vertical[j] = Vertical(index: i, x: (previous.x * previous.length + segment.x * segment.length) / (previous.length + segment.length), low: min(previous.low, segment.low), high: max(previous.high, segment.high))
                        } else { vertical.append(segment) }
                    }
                }
            }
            vertical.removeAll { $0.length < 12 || $0.length > 150 }
            for channel in vertical where !used.contains(channel.index) {
                try Task.checkCancellation()
                guard let gate = vertical.first(where: { gate in gate.index != channel.index && !used.contains(gate.index) && channel.x - gate.x >= 5 && channel.x - gate.x <= 40 && abs(gate.center.y - channel.center.y) <= channel.length * 0.25 && gate.length / channel.length >= 0.6 && gate.length / channel.length <= 1.6 }) else { continue }
                func branch(upper: Bool) -> (Int, Point)? {
                    for i in oriented.indices where i != gate.index && !used.contains(i) {
                        let ps = oriented[i]
                        guard ps.count >= 2, ps.count <= 12, ps.contains(where: { p in abs(p.x - channel.x) <= 4 && abs(p.y - (upper ? channel.low : channel.high)) <= max(5, channel.length * 0.2) }) else { continue }
                        let ends = [ps[0], ps[ps.count - 1]].filter { p in p.x >= channel.x + 6 && (upper ? p.y < channel.center.y - 5 : p.y > channel.center.y + 5) }
                        if let end = ends.max(by: { $0.distance(to: channel.center) < $1.distance(to: channel.center) }) { return (i, end) }
                    }
                    return nil
                }
                let upper = branch(upper: true), lower = branch(upper: false)
                guard upper != nil && lower != nil else { continue }
                var indices: Set<Int> = [gate.index, channel.index, upper!.0, lower!.0]
                var gateAnchor = gate.center
                if let tip = oriented[gate.index].filter({ $0.x < gate.x - 6 && abs($0.y - gate.center.y) <= max(4, gate.length * 0.15) }).min(by: { $0.x < $1.x }) { gateAnchor = tip }
                if let lead = oriented.indices.first(where: { i in
                    guard !used.contains(i), !indices.contains(i), straight(oriented[i]), let a = oriented[i].first, let b = oriented[i].last else { return false }
                    return (a.distance(to: gate.center) < 7 && b.x < gate.x - 6 && abs(b.y - gate.center.y) < 5) || (b.distance(to: gate.center) < 7 && a.x < gate.x - 6 && abs(a.y - gate.center.y) < 5)
                }) {
                    indices.insert(lead)
                    gateAnchor = oriented[lead].min { $0.x < $1.x }!
                }
                let kind: ComponentKind = preferredMOS == .pmos ? .pmos : .nmos
                func world(_ point: Point) -> Point { rotated(point, by: angle) }
                add(kind, world(channel.center), rotation, ["G": world(gateAnchor), "D": world(kind == .pmos ? lower!.1 : upper!.1), "S": world(kind == .pmos ? upper!.1 : lower!.1)], indices.sorted())
            }
          }
        }
        // Ground: three aligned horizontal bars, successively shorter downward.
        let bars = strokes.indices.filter { straight(strokes[$0]) && bounds[$0].width >= 10 && bounds[$0].height / bounds[$0].width < 0.18 }
        for a in bars where !used.contains(a) {
            let candidates = bars.filter { !used.contains($0) && $0 != a && bounds[$0].center.y > bounds[a].center.y + 3 && bounds[$0].center.y < bounds[a].center.y + 35 && abs(bounds[$0].center.x - bounds[a].center.x) < 8 && bounds[$0].width < bounds[a].width * 0.88 }.sorted { bounds[$0].center.y < bounds[$1].center.y }
            guard let b = candidates.first, let c = candidates.dropFirst().first(where: { bounds[$0].width < bounds[b].width * 0.88 }) else { continue }
            let anchor = Point(bounds[a].center.x, bounds[a].center.y - 10)
            add(.ground, anchor, 0, ["1": anchor], [a, b, c])
        }
        // A plate can be a line or a T-shaped stroke with an attached lead.
        let plates = strokes.map { plate($0) }
        for a in strokes.indices where !used.contains(a) {
            guard let plateA = plates[a] else { continue }
            let horizontal = plateA.horizontal, length = plateA.length
            guard length >= 14 else { continue }
            guard let b = strokes.indices.first(where: { index in
                guard index > a, !used.contains(index), let other = plates[index] else { return false }
                let tangent = (plateA.ends[1] - plateA.ends[0]) * (1 / length)
                let otherTangent = (other.ends[1] - other.ends[0]) * (1 / other.length)
                let separation = other.center - plateA.center
                let gap = abs(separation.x * -tangent.y + separation.y * tangent.x)
                let offset = abs(separation.x * tangent.x + separation.y * tangent.y)
                guard other.horizontal == horizontal && abs(tangent.x * otherTangent.x + tangent.y * otherTangent.y) >= cos(.pi / 10), other.length / length >= 0.78 && other.length / length <= 1.28 && gap >= 3 && gap <= min(35, length * 0.65) && offset < max(3, length * 0.22) else { return false }
                // Three sides of an unfinished rectangle are not a capacitor.
                return !strokes.indices.contains { j in
                    guard j != a, j != index, !used.contains(j), straight(strokes[j]), let first = strokes[j].first, let last = strokes[j].last else { return false }
                    let tolerance = max(4, length * 0.08)
                    return (distanceToSegment(first, plateA.ends[0], plateA.ends[1]) < tolerance && distanceToSegment(last, other.ends[0], other.ends[1]) < tolerance) || (distanceToSegment(last, plateA.ends[0], plateA.ends[1]) < tolerance && distanceToSegment(first, other.ends[0], other.ends[1]) < tolerance)
                }
            }) else { continue }
            let plateB = plates[b]!
            let middle = (plateA.center + plateB.center) * 0.5
            let ordered = [plateA, plateB].sorted { horizontal ? $0.center.y < $1.center.y : $0.center.x < $1.center.x }
            add(.capacitor, middle, horizontal ? 0 : 270, ["1": ordered[0].anchor, "2": ordered[1].anchor], [a, b])
        }
        for i in strokes.indices where !used.contains(i) {
            try Task.checkCancellation()
            let points = strokes[i], box = bounds[i]
            guard let first = points.first, let last = points.last, points.count >= 4 else { continue }
            let horizontal = box.width > box.height, major = horizontal ? box.width : box.height, minor = horizontal ? box.height : box.width
            if major >= 30, major / minor >= 1.7, major / minor < 12, first.distance(to: last) > major * 0.7 {
                let projected = points.map { horizontal ? Point($0.x, $0.y) : Point($0.y, $0.x) }
                let segments = zip(projected, projected.dropFirst()).map { $1 - $0 }.filter { abs($0.y) >= minor * 0.28 && abs($0.x) > 1 }
                let reversals = zip(segments, segments.dropFirst()).filter { $0.y * $1.y < 0 }.count
                let direction = last.x == first.x ? (last.y - first.y) : (horizontal ? last.x - first.x : last.y - first.y)
                let backtracks = zip(projected, projected.dropFirst()).filter { ($1.x - $0.x) * direction < -4 }.count
                if reversals >= 3, reversals <= 16, backtracks <= 1 {
                    let ends = [first, last].sorted { horizontal ? $0.x < $1.x : $0.y < $1.y }
                    add(.resistor, box.center, horizontal ? 270 : 0, ["1": ends[0], "2": ends[1]], [i]); continue
                }
            }
            // Circular source, with polarity/type left for review. Interior marks
            // are consumed so a minus sign is never imported as a short circuit.
            if points.count >= 8, major >= 28, major <= 160, major / minor < 1.45, first.distance(to: last) < major * 0.24 {
                let radii = points.map { $0.distance(to: box.center) }, average = radii.reduce(0, +) / Double(radii.count)
                let variation = radii.map { abs($0 - average) }.reduce(0, +) / Double(radii.count) / max(1, average)
                if variation < 0.22 {
                    let inside = strokes.indices.filter { $0 == i || (!used.contains($0) && strokes[$0].allSatisfy { box.contains($0, margin: -3) }) }
                    add(.voltageSource, box.center, 0, ["1": Point(box.center.x, box.minY), "2": Point(box.center.x, box.maxY)], inside)
                }
            }
        }
        // Only axis-aligned paths become wire candidates. Crossing wires receive
        // no inferred junction. Endpoint T junctions use the existing topology.
        var paths: [[Point]] = []
        var wireIndices: [Int] = []
        var unknown = 0
        for i in strokes.indices where !used.contains(i) {
            let points = strokes[i]
            if points.count >= 2, points.count <= 8, pathLength(points) >= 16,
               zip(points, points.dropFirst()).allSatisfy({ a, b in min(abs(a.x - b.x), abs(a.y - b.y)) <= max(3, a.distance(to: b) * 0.12) }) {
                var orthogonal = [points[0]]
                for point in points.dropFirst() { let previous = orthogonal.last!; orthogonal.append(abs(point.x - previous.x) > abs(point.y - previous.y) ? Point(point.x, previous.y) : Point(previous.x, point.y)) }
                paths.append(orthogonal)
                wireIndices.append(i)
            } else { unknown += 1 }
        }
        func attached(_ point: Point) -> (Point, TerminalRef?) {
            let choices = components.flatMap { candidate in candidate.anchors.map { (candidate.id, $0.key, $0.value) } }.filter { $0.2.distance(to: point) <= 14 }.sorted { $0.2.distance(to: point) < $1.2.distance(to: point) }
            if let first = choices.first, choices.count == 1 || choices[1].2.distance(to: point) - first.2.distance(to: point) > 4 { return (first.2, TerminalRef(first.0, first.1)) }
            return (point, nil)
        }
        var wires = paths.map { points -> Wire in
            var points = points
            let a = attached(points[0]), b = attached(points[points.count - 1])
            points[0] = a.0; points[points.count - 1] = b.0
            return Wire(points: points, start: a.1, end: b.1)
        }
        // Snap only nearby free endpoints to another wire, never mid-span
        // crossings. This preserves explicit gaps and unattached symbol marks.
        for i in wires.indices {
            for end in [0, wires[i].points.count - 1] {
                if end == 0 ? wires[i].start != nil : wires[i].end != nil { continue }
                let point = wires[i].points[end]
                var best: (Double, Point)?
                for j in wires.indices where j != i {
                    for (a, b) in zip(wires[j].points, wires[j].points.dropFirst()) {
                        let p = closest(point, a, b), distance = p.distance(to: point)
                        if distance <= 8 && (best == nil || distance < best!.0) { best = (distance, p) }
                    }
                }
                if let best { wires[i].points[end] = best.1 }
            }
        }
        return CircuitInkResult(components: components, wires: wires, unrecognizedStrokes: unknown, wireStrokeIndices: wireIndices)
    }

    private static func straight(_ points: [Point]) -> Bool {
        guard let first = points.first, let last = points.last, first.distance(to: last) >= 8 else { return false }
        return points.allSatisfy { distanceToSegment($0, first, last) < max(3, first.distance(to: last) * 0.06) }
    }
    private struct Plate {
        var horizontal: Bool
        var center: Point
        var length: Double
        var ends: [Point]
        var anchor: Point
    }
    private static func plate(_ points: [Point]) -> Plate? {
        guard let first = points.first, let last = points.last else { return nil }
        if straight(points) {
            guard abs(axisTilt(last - first)) <= .pi / 10 else { return nil }
            let horizontal = abs(last.x - first.x) > abs(last.y - first.y), center = (first + last) * 0.5
            return Plate(horizontal: horizontal, center: center, length: first.distance(to: last), ends: [first, last], anchor: center)
        }
        let angles = [0.0] + zip(points, points.dropFirst()).filter { $0.0.distance(to: $0.1) >= 10 }.map { axisTilt($0.1 - $0.0) }.filter { abs($0) >= .pi / 180 && abs($0) <= .pi / 10 }
        for angle in angles.prefix(13) {
            guard let result = axisPlate(points.map { rotated($0, by: -angle) }) else { continue }
            return Plate(horizontal: result.horizontal, center: rotated(result.center, by: angle), length: result.length, ends: result.ends.map { rotated($0, by: angle) }, anchor: rotated(result.anchor, by: angle))
        }
        return nil
    }
    private static func axisPlate(_ points: [Point]) -> Plate? {
        let box = Bounds(points)
        for horizontal in [true, false] {
            for side in [false, true] {
                let coordinate = horizontal ? (side ? box.maxY : box.minY) : (side ? box.maxX : box.minX)
                let onPlate = points.filter { abs((horizontal ? $0.y : $0.x) - coordinate) <= 3 }
                guard onPlate.count >= 2 else { continue }
                let sorted = onPlate.sorted { horizontal ? $0.x < $1.x : $0.y < $1.y }
                let a = sorted[0], b = sorted[sorted.count - 1], center = (a + b) * 0.5, length = a.distance(to: b)
                guard length >= 14 else { continue }
                let tip = points.max { distanceToSegment($0, a, b) < distanceToSegment($1, a, b) }!
                let leadLength = tip.distance(to: center)
                guard leadLength >= 6, leadLength <= length * 2.5,
                      abs(horizontal ? tip.x - center.x : tip.y - center.y) <= max(3, length * 0.12),
                      points.allSatisfy({ min(distanceToSegment($0, a, b), distanceToSegment($0, center, tip)) <= max(3, length * 0.08) }) else { continue }
                let coverage = zip(points, points.dropFirst()).filter { abs((horizontal ? $0.0.y : $0.0.x) - coordinate) <= 3 && abs((horizontal ? $0.1.y : $0.1.x) - coordinate) <= 3 }.reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
                guard coverage >= length * 0.8 else { continue }
                return Plate(horizontal: horizontal, center: center, length: length, ends: [a, b], anchor: tip)
            }
        }
        return nil
    }
    private static func rotated(_ point: Point, by angle: Double) -> Point {
        Point(point.x * cos(angle) - point.y * sin(angle), point.x * sin(angle) + point.y * cos(angle))
    }
    /// Deviation from the nearest horizontal/vertical direction, in radians.
    private static func axisTilt(_ direction: Point) -> Double {
        let angle = atan2(direction.y, direction.x), quarterTurn = Double.pi / 2
        return angle - (angle / quarterTurn).rounded() * quarterTurn
    }
    private static func pathLength(_ points: [Point]) -> Double { zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
    private static func closest(_ p: Point, _ a: Point, _ b: Point) -> Point {
        let d = b - a, denominator = d.x * d.x + d.y * d.y
        let t = denominator > 0 ? max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / denominator)) : 0
        return a + d * t
    }
    private static func simplify(_ points: [Point], tolerance: Double) -> [Point] {
        guard points.count > 2 else { return points }
        var retained: Set<Int> = [0, points.count - 1], ranges = [(0, points.count - 1)]
        while let (first, last) = ranges.popLast() {
            guard last > first + 1 else { continue }
            var distance = tolerance, index: Int?
            for i in (first + 1)..<last { let d = distanceToSegment(points[i], points[first], points[last]); if d > distance { distance = d; index = i } }
            if let index { retained.insert(index); ranges += [(first, index), (index, last)] }
        }
        return retained.sorted().map { points[$0] }
    }

    public static var example: [CircuitInkStroke] {
        let circle = (0...48).map { i in let angle = Double(i) * 2 * .pi / 48; return Point(150 + 35 * cos(angle), 250 + 35 * sin(angle)) }
        return [CircuitInkStroke(circle), CircuitInkStroke([Point(145, 235), Point(155, 235)]), CircuitInkStroke([Point(150, 230), Point(150, 240)]), CircuitInkStroke([Point(145, 265), Point(155, 265)]),
                CircuitInkStroke([Point(240, 160), Point(250, 145), Point(265, 175), Point(280, 145), Point(295, 175), Point(310, 145), Point(325, 175), Point(335, 160)]),
                CircuitInkStroke([Point(440, 240), Point(500, 240)]), CircuitInkStroke([Point(440, 260), Point(500, 260)]),
                CircuitInkStroke([Point(125, 360), Point(175, 360)]), CircuitInkStroke([Point(133, 372), Point(167, 372)]), CircuitInkStroke([Point(141, 384), Point(159, 384)]),
                CircuitInkStroke([Point(445, 360), Point(495, 360)]), CircuitInkStroke([Point(453, 372), Point(487, 372)]), CircuitInkStroke([Point(461, 384), Point(479, 384)]),
                CircuitInkStroke([Point(150, 215), Point(150, 160), Point(240, 160)]), CircuitInkStroke([Point(335, 160), Point(470, 160), Point(470, 240)]),
                CircuitInkStroke([Point(150, 285), Point(150, 350)]), CircuitInkStroke([Point(470, 260), Point(470, 350)])]
    }
}
