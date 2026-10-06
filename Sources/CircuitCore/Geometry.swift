import Foundation

public struct Point: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double = 0, _ y: Double = 0) { self.x = x; self.y = y }
    public static let zero = Point()
    public static func + (a: Point, b: Point) -> Point { Point(a.x + b.x, a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(a.x - b.x, a.y - b.y) }
    public static func * (a: Point, b: Double) -> Point { Point(a.x * b, a.y * b) }
    public func distance(to b: Point) -> Double { hypot(x - b.x, y - b.y) }
    public func snapped(_ grid: Double = 10) -> Point { Point((x / grid).rounded() * grid, (y / grid).rounded() * grid) }
    public func transformed(rotation: Int, flipX: Bool, flipY: Bool) -> Point {
        let p = Point(flipX ? -x : x, flipY ? -y : y)
        switch ((rotation % 360) + 360) % 360 {
        case 90: return Point(-p.y, p.x)
        case 180: return Point(-p.x, -p.y)
        case 270: return Point(p.y, -p.x)
        default: return p
        }
    }
}

public struct Bounds: Sendable {
    public var minX: Double; public var minY: Double; public var maxX: Double; public var maxY: Double
    public init(_ points: [Point], padding: Double = 0) {
        minX = (points.map(\.x).min() ?? 0) - padding
        minY = (points.map(\.y).min() ?? 0) - padding
        maxX = (points.map(\.x).max() ?? 600) + padding
        maxY = (points.map(\.y).max() ?? 400) + padding
    }
    public var width: Double { max(1, maxX - minX) }
    public var height: Double { max(1, maxY - minY) }
    public var center: Point { Point((minX + maxX) / 2, (minY + maxY) / 2) }
    public func contains(_ p: Point, margin: Double = 0) -> Bool {
        p.x >= minX - margin && p.x <= maxX + margin && p.y >= minY - margin && p.y <= maxY + margin
    }
}

public func distanceToSegment(_ p: Point, _ a: Point, _ b: Point) -> Double {
    let dx = b.x - a.x, dy = b.y - a.y
    let length = dx * dx + dy * dy
    if length < 0.0001 { return p.distance(to: a) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
    return p.distance(to: Point(a.x + t * dx, a.y + t * dy))
}

public enum WireRouting {
    /// Scores Manhattan candidates against component bodies and text bounds.
    public static func route(from a: Point, to b: Point, obstacles: [Bounds] = []) -> [Point] {
        if abs(a.x - b.x) < 0.01 || abs(a.y - b.y) < 0.01 { return [a, b] }
        var candidates = [[a, Point(b.x, a.y), b], [a, Point(a.x, b.y), b]]
        let midX = ((a.x + b.x) / 20).rounded() * 10
        let midY = ((a.y + b.y) / 20).rounded() * 10
        candidates += [[a, Point(midX, a.y), Point(midX, b.y), b], [a, Point(a.x, midY), Point(b.x, midY), b]]
        for offset in [-60.0, 60.0, -100.0, 100.0] {
            candidates.append([a, Point(midX + offset, a.y), Point(midX + offset, b.y), b])
            candidates.append([a, Point(a.x, midY + offset), Point(b.x, midY + offset), b])
        }
        func score(_ points: [Point]) -> Double {
            var score = Double(points.count) * 12
            for (s, e) in zip(points, points.dropFirst()) {
                score += s.distance(to: e)
                for rect in obstacles where !rect.contains(a) && !rect.contains(b) {
                    let samples = max(1, Int(s.distance(to: e) / 5))
                    for i in 0...samples where rect.contains(s + (e - s) * (Double(i) / Double(samples)), margin: 8) { score += 200 }
                }
            }
            return score
        }
        return candidates.min { score($0) < score($1) } ?? [a, b]
    }
}
