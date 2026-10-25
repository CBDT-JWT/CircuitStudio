import Foundation
#if canImport(CoreML) && canImport(CoreGraphics)
import CoreML
import CoreGraphics
import CoreVideo

public struct CircuitHandwritingPrediction: Sendable {
    public let label: String
    public let confidence: Double
    public let margin: Double
    public let accepted: Bool
}

/// A trained CNN supplies the symbol class. Geometry is used only to propose
/// nearby stroke groups, fit the orientation of that class and attach wires.
/// There is deliberately no geometric type-recognition fallback.
public final class CircuitHandwritingRecognizer: @unchecked Sendable {
    private let model: MLModel
    private let thresholds: [String: Double]
    private let margin: Double
    private let predictionLock = NSLock()
    private static let bundled: Result<CircuitHandwritingRecognizer, Error> = Result {
        guard let url = Bundle.main.url(forResource: "CircuitHandwriting", withExtension: "mlmodelc") else {
            throw CircuitError.message("Offline handwriting model is missing. Your ink has been preserved.")
        }
        return try CircuitHandwritingRecognizer(modelURL: url)
    }

    public init(modelURL: URL) throws {
        let url = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        let config = MLModelConfiguration(); config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        thresholds = metadata["thresholds"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        margin = Double(metadata["minimum_margin"] ?? "0.2") ?? 0.2
    }

    public static func recognize(_ ink: [CircuitInkStroke], preferredMOS: ComponentKind? = nil) throws -> CircuitInkResult {
        try bundled.get().recognize(ink, preferredMOS: preferredMOS)
    }

    public func classify(_ ink: [CircuitInkStroke]) throws -> CircuitHandwritingPrediction {
        try Self.validate(ink)
        return try classify(pixelBuffer: Self.rasterize(ink))
    }

    /// Also used to verify exported Core ML predictions on held-out real crops.
    public func classify(pixelBuffer: CVPixelBuffer) throws -> CircuitHandwritingPrediction {
        try predictionLock.withLock {
            let features = try MLDictionaryFeatureProvider(dictionary: ["ink": MLFeatureValue(pixelBuffer: pixelBuffer)])
            let result = try model.prediction(from: features)
            guard let name = model.modelDescription.predictedProbabilitiesName,
                  let probabilities = result.featureValue(for: name) else {
                throw CircuitError.message("The offline handwriting model returned no probabilities.")
            }
            let sorted = probabilities.dictionaryValue.compactMap { key, value -> (String, Double)? in
                guard let name = key as? String else { return nil }
                return (name, value.doubleValue)
            }.sorted { $0.1 > $1.1 }
            guard let first = sorted.first else { throw CircuitError.message("Empty handwriting prediction.") }
            let difference = first.1 - (sorted.dropFirst().first?.1 ?? 0)
            return CircuitHandwritingPrediction(label: first.0, confidence: first.1, margin: difference,
                accepted: Self.kind(for: first.0, preferredMOS: nil) != nil && first.1 >= (thresholds[first.0] ?? 0.9) && difference >= margin)
        }
    }

    public static func kind(for label: String, preferredMOS: ComponentKind?) -> ComponentKind? {
        if label == "mos" { return preferredMOS == .pmos ? .pmos : .nmos }
        guard ["resistor", "capacitor", "polarizedCapacitor", "inductor", "diode", "ground", "voltageSource", "acVoltage", "opAmp"].contains(label) else { return nil }
        return ComponentKind(rawValue: label)
    }

    public func recognize(_ ink: [CircuitInkStroke], preferredMOS: ComponentKind? = nil) throws -> CircuitInkResult {
        try Self.validate(ink)
        guard !ink.isEmpty else { return CircuitInkResult(components: [], wires: [], unrecognizedStrokes: 0) }
        let bounds = ink.map { Bounds($0.points) }
        var candidates: [[Int]] = [], seen = Set<[Int]>()
        func propose(_ indices: [Int]) {
            let indices = indices.sorted()
            if !indices.isEmpty, indices.count <= 32, seen.insert(indices).inserted, candidates.count < 160 { candidates.append(indices) }
        }
        // Spatial grouping does not decide what kind of component a shape is.
        let eligible = ink.indices.filter { !ink[$0].points.isEmpty && !(Self.wirePath(ink[$0].points) != nil && Self.length(ink[$0].points) > 140) }
        var visited = Set<Int>()
        for seed in eligible where !visited.contains(seed) {
            var queue = [seed]; visited.insert(seed); var position = 0
            while position < queue.count {
                let i = queue[position]; position += 1
                for j in eligible where !visited.contains(j) && Self.gap(bounds[i], bounds[j]) <= 14 {
                    visited.insert(j); queue.append(j)
                }
            }
            propose(queue)
        }
        // Symbols drawn close together need smaller groups too. A fixed
        // 12-point radius can swallow a small resistor into the adjacent MOS.
        // A bounded budget prevents large drawings from blocking the pen.
        for offset in eligible.indices.reversed() {
            let seed = eligible[offset]
            propose([seed])
            // Ink sequences give short ground bars their own proposal even
            // when a long source lead intersects every spatial neighborhood.
            for count in 2...6 where offset + 1 >= count {
                propose(Array(eligible[(offset + 1 - count)...offset]))
            }
            for radius in [4.0, 8.0, 12.0, 24.0, 38.0] {
                propose(eligible.filter { Self.gap(bounds[seed], bounds[$0]) <= radius })
            }
            if candidates.count >= 160 { break }
        }
        struct Accepted { let indices: [Int]; let kind: ComponentKind; let confidence: Double; var score: Double { confidence + min(0.04, Double(indices.count) * 0.008) } }
        var accepted: [Accepted] = []
        var cache: [[Int]: CircuitHandwritingPrediction] = [:]
        func prediction(_ indices: [Int]) throws -> CircuitHandwritingPrediction {
            if let value = cache[indices] { return value }
            try Task.checkCancellation()
            let value = try classify(indices.map { ink[$0] }); cache[indices] = value; return value
        }
        for indices in candidates {
            try Task.checkCancellation()
            let strokes = indices.map { ink[$0] }, box = Bounds(strokes.flatMap(\.points))
            guard max(box.width, box.height) >= 8 else { continue }
            let prediction = try prediction(indices)
            if prediction.accepted, let kind = Self.kind(for: prediction.label, preferredMOS: preferredMOS) {
                accepted.append(Accepted(indices: indices, kind: kind, confidence: prediction.confidence))
            }
        }
        accepted.sort { $0.score == $1.score ? $0.indices.count > $1.indices.count : $0.score > $1.score }
        // Remove incidental neighboring ink only when the same trained class
        // remains confident. This stops a MOS proposal swallowing ground bars.
        accepted = try accepted.enumerated().map { offset, candidate in
            guard offset < 32 else { return candidate }
            var indices = candidate.indices, confidence = candidate.confidence
            let core = Self.fit(kind: candidate.kind, ink: candidate.indices.map { ink[$0] }).core
            for index in candidate.indices.reversed() where indices.count > 1 && cache.count < 280 {
                let b = bounds[index]
                guard b.maxX < core.minX || b.minX > core.maxX || b.maxY < core.minY || b.minY > core.maxY else { continue }
                let subset = indices.filter { $0 != index }
                let value = try prediction(subset)
                if value.accepted, Self.kind(for: value.label, preferredMOS: preferredMOS) == candidate.kind,
                   value.confidence >= candidate.confidence - 0.02 {
                    indices = subset; confidence = value.confidence
                }
            }
            return Accepted(indices: indices, kind: candidate.kind, confidence: confidence)
        }
        let proposals = accepted
        var cores: [[Int]: Bounds] = [:]
        for candidate in proposals { cores[candidate.indices] = Self.fit(kind: candidate.kind, ink: candidate.indices.map { ink[$0] }).core }
        accepted.removeAll { candidate in proposals.contains { other in
            guard other.kind == candidate.kind else { return false }
            guard other.confidence >= 0.9, other.indices.count < candidate.indices.count, Set(other.indices).isSubset(of: candidate.indices), let core = cores[other.indices] else { return false }
            return candidate.indices.filter { !other.indices.contains($0) }.allSatisfy { index in
                let b = bounds[index]; return b.maxX < core.minX || b.minX > core.maxX || b.maxY < core.minY || b.minY > core.maxY
            }
        } }
        accepted.sort { $0.score == $1.score ? $0.indices.count > $1.indices.count : $0.score > $1.score }
        let shareable = Set(ink.indices.filter { Self.wirePath(ink[$0].points)?.count == 2 })
        var unique = Set<String>()
        accepted = accepted.filter { unique.insert($0.kind.rawValue + ":" + $0.indices.map(String.init).joined(separator:",")).inserted }
        let placements = accepted.map { candidate in Self.fit(kind: candidate.kind, ink: candidate.indices.map { ink[$0] }) }
        func compatible(_ a: Int, _ b: Int) -> Bool {
            let ai = Set(accepted[a].indices), bi = Set(accepted[b].indices)
            if ai.isSubset(of: bi) || bi.isSubset(of: ai) { return false }
            let overlap = ai.intersection(bi)
            guard overlap.isSubset(of: shareable) else { return false }
            for index in overlap {
                guard let path = Self.wirePath(ink[index].points), let first = path.first, let last = path.last else { return false }
                func touches(_ point: Point, _ component: Int) -> Bool { placements[component].anchors.values.contains { $0.distance(to: point) <= 16 } }
                guard (touches(first,a) && touches(last,b)) || (touches(last,a) && touches(first,b)) else { return false }
            }
            return true
        }
        // A locally confident proposal can steal parts of two true symbols.
        // Compare a bounded set of complete assignments rather than letting
        // the first proposal suppress every neighboring component.
        struct Assignment { let indices: [Int]; let score: Double }
        var beam = [Assignment(indices:[],score:0)]
        for i in accepted.indices {
            try Task.checkCancellation()
            let extended = beam.compactMap { state -> Assignment? in
                guard state.indices.allSatisfy({ compatible($0,i) }) else { return nil }
                return Assignment(indices:state.indices+[i],score:state.score+accepted[i].score)
            }
            beam = (beam+extended).sorted { $0.score > $1.score }.prefix(64).map { $0 }
        }
        var used = Set<Int>(), components: [CircuitInkComponent] = []
        for index in beam.first?.indices ?? [] {
            let candidate = accepted[index], placement = placements[index]
            components.append(CircuitInkComponent(kind: candidate.kind, position: placement.position, rotation: placement.rotation,
                anchors: placement.anchors, strokeIndices: candidate.indices))
            used.formUnion(candidate.indices)
        }
        components.sort { ($0.strokeIndices.first ?? 0) < ($1.strokeIndices.first ?? 0) }
        var wires: [Wire] = [], indices: [Int] = []
        let unresolvedClosed = ink.indices.filter { index in
            guard !used.contains(index), ink[index].points.count >= 6, let first = ink[index].points.first, let last = ink[index].points.last else { return false }
            return min(bounds[index].width,bounds[index].height) >= 8 && first.distance(to:last) <= max(4,min(bounds[index].width,bounds[index].height)*0.15)
        }
        func attach(_ point: Point) -> (Point, TerminalRef?) {
            let nearby = components.flatMap { c in c.anchors.map { (c.id, $0.key, $0.value) } }.filter { $0.2.distance(to: point) <= 14 }.sorted { $0.2.distance(to: point) < $1.2.distance(to: point) }
            guard let first = nearby.first, nearby.count == 1 || nearby[1].2.distance(to: point) - first.2.distance(to: point) > 4 else { return (point, nil) }
            return (first.2, TerminalRef(first.0, first.1))
        }
        for i in ink.indices where !used.contains(i) || components.filter({ $0.strokeIndices.contains(i) }).count > 1 {
            guard var points = Self.wirePath(ink[i].points) else { continue }
            // A line through an unresolved source circle is not a wire that
            // shorts its two terminals. Keep that ink until its symbol resolves.
            guard !unresolvedClosed.contains(where: { index in
                ink[index].points.contains { point in zip(points,points.dropFirst()).contains { distanceToSegment(point,$0,$1) <= 3 } }
            }) else { continue }
            let a = attach(points[0]), b = attach(points[points.count - 1]); points[0] = a.0; points[points.count - 1] = b.0
            wires.append(Wire(points: points, start: a.1, end: b.1)); indices.append(i)
        }
        // Component leads can meet without a separate pen stroke. Preserve
        // those sketched junctions when native symbols move their own pins.
        let anchors = components.flatMap { component in component.anchors.map { (TerminalRef(component.id,$0.key),$0.value) } }
        for a in anchors.indices {
            for b in anchors.indices where b > a && anchors[a].0.componentID != anchors[b].0.componentID && anchors[a].1.distance(to: anchors[b].1) <= 8 {
                let start = anchors[a].0, end = anchors[b].0
                if !wires.contains(where: { ($0.start == start && $0.end == end) || ($0.start == end && $0.end == start) }) {
                    wires.append(Wire(points:[anchors[a].1,anchors[b].1],start:start,end:end)); indices.append(-1)
                }
            }
        }
        return CircuitInkResult(components: components, wires: wires, unrecognizedStrokes: ink.count - used.union(indices.filter { $0 >= 0 }).count, wireStrokeIndices: indices)
    }

    private static func validate(_ ink: [CircuitInkStroke]) throws {
        guard ink.count <= 500, ink.reduce(0, { $0 + $1.points.count }) <= 30_000 else { throw CircuitError.message("Split this drawing into smaller circuits (up to 500 strokes).") }
        guard ink.allSatisfy({ $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) < 100_000 && abs($0.y) < 100_000 } }) else { throw CircuitError.message("The drawing contains invalid coordinates.") }
    }
    public static func rasterize(_ ink: [CircuitInkStroke]) throws -> CVPixelBuffer {
        try validate(ink)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 96, 96, kCVPixelFormatType_OneComponent8, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
            throw CircuitError.message("Could not allocate handwriting input.")
        }
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw CircuitError.message("Could not rasterize handwriting.") }
        context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        let box = Bounds(ink.flatMap(\.points)), scale = 78 / max(box.width, box.height)
        context.setStrokeColor(gray: 1, alpha: 1); context.setLineWidth(2.2); context.setLineCap(.round); context.setLineJoin(.round)
        func p(_ point: Point) -> CGPoint { CGPoint(x: 48 + (point.x - box.center.x) * scale, y: 48 + (point.y - box.center.y) * scale) }
        for stroke in ink where stroke.points.count > 1 {
            context.beginPath(); context.move(to: p(stroke.points[0])); for point in stroke.points.dropFirst() { context.addLine(to: p(point)) }; context.strokePath()
        }
        return buffer
    }
    private static func gap(_ a: Bounds, _ b: Bounds) -> Double { hypot(max(0, max(a.minX - b.maxX, b.minX - a.maxX)), max(0, max(a.minY - b.maxY, b.minY - a.maxY))) }
    private static func length(_ path: [Point]) -> Double { zip(path, path.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
    public static func wirePath(_ path: [Point]) -> [Point]? {
        guard path.count >= 2, let first = path.first, let last = path.last, first.distance(to: last) >= 16 else { return nil }
        let span = first.distance(to: last)
        if path.allSatisfy({ distanceToSegment($0, first, last) <= max(3, span * 0.055) }), length(path) <= span * 1.25 { return [first, last] }
        func simplify(_ points: ArraySlice<Point>) -> [Point] {
            guard points.count > 2, let first = points.first, let last = points.last else { return Array(points) }
            guard let index = points.indices.dropFirst().dropLast().max(by: { distanceToSegment(points[$0], first, last) < distanceToSegment(points[$1], first, last) }), distanceToSegment(points[index], first, last) > 2.5 else { return [first, last] }
            return simplify(points[...index]) + simplify(points[index...]).dropFirst()
        }
        let points = simplify(path[...])
        // Only short orthogonal polylines become wire candidates. Neural class
        // recognition has already had first claim on every component stroke.
        guard points.count <= 8, zip(points, points.dropFirst()).allSatisfy({ a, b in min(abs(a.x - b.x), abs(a.y - b.y)) <= max(5, a.distance(to: b) * 0.22) }) else { return nil }
        var result = [first]
        for point in points.dropFirst() { let previous = result.last!; result.append(abs(point.x - previous.x) > abs(point.y - previous.y) ? Point(point.x, previous.y) : Point(previous.x, point.y)) }
        if result.last != last { result.append(last) }
        return result
    }

    private struct Placement { let position: Point; let rotation: Int; let anchors: [String: Point]; let core: Bounds }
    private static func fit(kind: ComponentKind, ink: [CircuitInkStroke]) -> Placement {
        let actual = ink.flatMap(\.points), box = Bounds(actual)
        // Three bare ground bars have no stem. Their taper establishes the
        // orientation, and the long bar is the actual connection location.
        if kind == .ground, ink.count == 3, let longest = ink.max(by: { Bounds($0.points).width + Bounds($0.points).height < Bounds($1.points).width + Bounds($1.points).height }) {
            let longBox = Bounds(longest.points), horizontal = longBox.width >= longBox.height
            let bars = ink.map { Bounds($0.points) }
            let parallel = bars.allSatisfy { horizontal ? $0.height <= max(4,$0.width * 0.3) : $0.width <= max(4,$0.height * 0.3) }
            if parallel {
                let smaller = bars.filter { horizontal ? $0.width < longBox.width * 0.8 : $0.height < longBox.height * 0.8 }
                if smaller.count >= 2 {
                    let taper = smaller.reduce(Point.zero) { $0 + $1.center } * (1 / Double(smaller.count)) - longBox.center
                    let rotation = horizontal ? (taper.y >= 0 ? 0 : 180) : (taper.x >= 0 ? 270 : 90)
                    return Placement(position:longBox.center,rotation:rotation,anchors:["1":longBox.center],core:box)
                }
            }
        }
        // Template fitting is constrained to the neural class; it cannot change
        // a resistor into a MOS. It only estimates rotation and pin locations.
        var best: (Double, Int, Point, [String: Point], Bounds)?
        for rotation in [0, 90, 180, 270] {
            var component = Component(kind: kind, name: "", position: .zero); component.referenceArtwork = nil; component.rotation = rotation
            let template: [Point] = Symbols.geometry(component, theme: .razavi).flatMap { primitive in
                switch primitive {
                case .reference(let path): return path.sampledPoints
                case .line(let points), .polygon(let points, _): return points
                case .circle(let center, let radius, _): return (0..<24).map { i in Point(center.x + radius * cos(Double(i) * .pi / 12), center.y + radius * sin(Double(i) * .pi / 12)) }
                }
            }
            let span = Bounds(template), sx = box.width / span.width, sy = box.height / span.height
            func map(_ p: Point) -> Point { box.center + Point((p.x - span.center.x) * sx, (p.y - span.center.y) * sy) }
            let transformed = template.map(map)
            let stride = max(1, actual.count / 120), samples = actual.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
            let distance = transformed.reduce(0.0) { score, p in score + (samples.map { $0.distance(to: p) }.min() ?? 100) } / Double(max(1, transformed.count))
            let distortion = abs(log(max(0.001, sx / sy))) * 2
            let score = distance + distortion
            if best == nil || score < best!.0 {
                let position = map(.zero)
                let endpoints = ink.flatMap { stroke -> [Point] in
                    guard let first = stroke.points.first, let last = stroke.points.last else { return [] }
                    let bounds = Bounds(stroke.points)
                    // A closed resistor box/source circle has no lead endpoint.
                    if stroke.points.count >= 6, min(bounds.width,bounds.height) >= 8,
                       first.distance(to:last) <= max(4,min(bounds.width,bounds.height)*0.15) { return [] }
                    return [first,last]
                }
                let anchors = Dictionary(uniqueKeysWithValues: component.pins.map { pin in
                    let fitted = map(component.world(pin.offset))
                    let endpoint = endpoints.min { $0.distance(to:fitted) < $1.distance(to:fitted) }
                    // Uneven hand-drawn leads should attach at their observed
                    // ends, rather than at the stretched template's extremes.
                    let tolerance = min(14,max(box.width,box.height) * 0.18)
                    return (pin.name,endpoint.map { $0.distance(to:fitted) <= tolerance ? $0 : fitted } ?? fitted)
                })
                let body = component.bodyBounds
                let core = Bounds([Point(body.minX, body.minY),Point(body.maxX,body.maxY),Point(body.minX,body.maxY),Point(body.maxX,body.minY)].map(map))
                best = (score, rotation, position, anchors, core)
            }
        }
        return Placement(position: best?.2 ?? box.center, rotation: best?.1 ?? 0, anchors: best?.3 ?? [:], core: best?.4 ?? box)
    }
}
#endif
