import Foundation

public struct ElectricalNet: Sendable { public var name: String; public var points: [Point]; public var terminals: [TerminalRef] }
public struct Connectivity: Sendable {
    public var nets: [ElectricalNet] = []; public var terminalNets: [TerminalRef: String] = [:]; public var connectionDots: [Point] = []
    public var conflictingLabels: [[String]] = []
    public init(_ circuit: Circuit) {
        var points: [Point] = []; var parents: [Int] = []; var indices: [Point: Int] = [:]
        func index(_ p: Point) -> Int {
            let p = Point((p.x * 1000).rounded() / 1000, (p.y * 1000).rounded() / 1000)
            if let i = indices[p] { return i }; let i = points.count; indices[p] = i; points.append(p); parents.append(i); return i
        }
        func root(_ i: Int) -> Int { var n = i; while parents[n] != n { n = parents[n] }; return n }
        func union(_ a: Int, _ b: Int) { parents[root(b)] = root(a) }
        var terminalIndices: [TerminalRef: Int] = [:]
        for component in circuit.components { for pin in component.pins { terminalIndices[TerminalRef(component.id, pin.name)] = index(component.world(pin.offset)) } }
        var segments: [(Point, Point, Int)] = []; var endpoints: [Point] = []; var degree: [Point: Int] = [:]
        for wire in circuit.wires {
            let ps = circuit.resolvedPoints(wire); guard let first = ps.first, let last = ps.last else { continue }
            let start = index(first); endpoints += [first, last]
            for p in ps { union(start, index(p)) }
            for (a, b) in zip(ps, ps.dropFirst()) { segments.append((a, b, start)); degree[a, default: 0] += 1; degree[b, default: 0] += 1 }
        }
        let touchPoints = endpoints + circuit.junctions + Array(terminalIndices.keys).compactMap { circuit.position(of: $0) } + circuit.labels.filter(\.isNet).map(\.position)
        // Endpoints, terminals and explicit junctions join segments. Bare crossings do not.
        for p in touchPoints {
            let i = index(p); var touched = 0
            for (a, b, s) in segments where distanceToSegment(p, a, b) < 0.01 { union(i, s); touched += 1 }
            if touched > 1 && (circuit.junctions.contains(p) || degree[p, default: 0] >= 3 || segments.contains(where: { p != $0.0 && p != $0.1 && distanceToSegment(p, $0.0, $0.1) < 0.01 })) { connectionDots.append(p) }
        }
        var named: [(String, Int)] = circuit.labels.filter(\.isNet).map { (MathLabel.netName($0.text), index($0.position)) }
        for c in circuit.components where c.kind.isConnection {
            let name = c.kind == .ground ? "0" : MathLabel.netName(c.name)
            named.append((name, index(c.position)))
        }
        var firstNamed: [String: Int] = [:]
        for (name, i) in named where !name.isEmpty { if let first = firstNamed[name] { union(first, i) } else { firstNamed[name] = i } }
        var groups: [Int: [Int]] = [:]
        for i in points.indices { groups[root(i), default: []].append(i) }
        var counter = 1
        for key in groups.keys.sorted() {
            let names = Set(named.filter { root($0.1) == key }.map(\.0)).sorted()
            if names.count > 1 { conflictingLabels.append(names) }
            let name = names.contains("0") ? "0" : names.first ?? "N\(counter)"; if names.isEmpty { counter += 1 }
            let terminals = terminalIndices.filter { root($0.value) == key }.map(\.key)
            nets.append(ElectricalNet(name: name, points: groups[key]!.map { points[$0] }, terminals: terminals))
            for terminal in terminals { terminalNets[terminal] = name }
        }
        connectionDots = Array(Set(connectionDots + circuit.junctions))
    }
    public func net(_ component: UUID, _ pin: String) -> String { terminalNets[TerminalRef(component, pin)] ?? "0" }
}
