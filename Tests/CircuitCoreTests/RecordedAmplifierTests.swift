import Foundation
import Testing
@testable import CircuitCore

// Approximate stroke centerlines traced from the owner's 2026-10-12 recording.
// This checks the connected grouping regression, not raw PKDrawing/device accuracy.
@Test func recordedAmplifierRecognizesSeparateSymbolsAndPreservesUnknownSource() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Models/CircuitHandwriting.mlmodel")
    let model = try CircuitHandwritingRecognizer(modelURL: ProcessInfo.processInfo.environment["CIRCUIT_HANDWRITING_TEST_MODEL"].map { URL(fileURLWithPath: $0) } ?? url)
    let mos = [
        CircuitInkStroke([Point(556,478),Point(553,482),Point(554,492),Point(556,495)]),
        CircuitInkStroke([Point(563,473),Point(562,478),Point(565,498)]),
        CircuitInkStroke([Point(563,476),Point(579,475)]),
        CircuitInkStroke([Point(565,498),Point(579,495),Point(581,492),Point(583,516),Point(587,537)]),
        CircuitInkStroke([Point(580,474),Point(578,449)])
    ]
    let resistor = [CircuitInkStroke([Point(574,442),Point(573,419),Point(585,418),Point(586,440),Point(583,443),Point(575,443),Point(574,442)]),CircuitInkStroke([Point(577,416),Point(576,399)]),CircuitInkStroke([Point(580,446),Point(580,455),Point(582,473)])]
    let sourceCircle = CircuitInkStroke((0...30).map { i in let t=Double(i)*2 * .pi/30; return Point(504.5+13*cos(t),509+15*sin(t)) })
    let source = [sourceCircle, CircuitInkStroke([Point(507,487),Point(505,509),Point(504,539)]),CircuitInkStroke([Point(499,540),Point(507,539),Point(517,540)]),CircuitInkStroke([Point(503,548),Point(508,548)]),CircuitInkStroke([Point(506,553),Point(508,555)])]
    let gateWire = CircuitInkStroke([Point(505,487),Point(527,487),Point(550,486)])
    let ground = [CircuitInkStroke([Point(579,544),Point(585,541),Point(599,541)]),CircuitInkStroke([Point(585,557),Point(589,558)]),CircuitInkStroke([Point(589,563),Point(590,565),Point(595,564)])]
    let supply = [CircuitInkStroke([Point(563,396),Point(573,395),Point(597,396)]),CircuitInkStroke([Point(560,370),Point(562,380),Point(566,384),Point(572,372)]),CircuitInkStroke([Point(575,384),Point(575,374),Point(581,374),Point(584,378),Point(581,384),Point(575,384)]),CircuitInkStroke([Point(587,385),Point(587,375),Point(594,375),Point(598,380),Point(595,385),Point(587,385)])]
    let all = source+[gateWire]+mos+ground+Array(resistor.prefix(2))+supply+[CircuitInkStroke([Point(583,457),Point(614,454),Point(633,454)])]
    let dense = all.map { stroke -> CircuitInkStroke in
        var points = [stroke.points[0]]
        for (a,b) in zip(stroke.points,stroke.points.dropFirst()) {
            let steps = max(1,Int(ceil(a.distance(to:b) / 2)))
            for i in 1...steps { points.append(a + (b-a) * (Double(i)/Double(steps))) }
        }
        return CircuitInkStroke(points)
    }
    // PencilKit sends sampled paths rather than two-point wire vertices.
    for input in [all,dense] {
        let result = try model.recognize(input)
        #expect(result.components.filter { $0.kind == .nmos }.count == 1)
        #expect(result.components.filter { $0.kind == .resistor }.count == 1)
        #expect(result.components.filter { $0.kind == .ground }.count == 2)
        #expect(result.components.count == 4)
        #expect(!result.wireInkStrokeIndices.contains(1))
        #expect(!result.components.flatMap(\.strokeIndices).contains(0))
        #expect(!result.components.flatMap(\.strokeIndices).contains(1))
        #expect(result.components.filter { $0.kind == .ground }.allSatisfy { $0.rotation == 0 })
        let transistor = try #require(result.components.first { $0.kind == .nmos })
        let load = try #require(result.components.first { $0.kind == .resistor })
        // A resistor is unpolarized: a 180° fit may exchange pin 1 and 2.
        let loadBottom = try #require(load.anchors.max { $0.value.y < $1.value.y }?.key)
        #expect(result.wires.contains { wire in
            [wire.start,wire.end].compactMap { $0 }.contains(TerminalRef(transistor.id,"D")) &&
            [wire.start,wire.end].compactMap { $0 }.contains(TerminalRef(load.id,loadBottom))
        })
        #expect(result.wires.contains { $0.start == TerminalRef(transistor.id,"D") && $0.end == nil && $0.points.last == Point(633,454) })
        #expect(result.wires.contains { wire in
            let refs = [wire.start,wire.end].compactMap { $0 }
            return refs.contains(TerminalRef(transistor.id,"S")) && refs.contains { ref in result.components.contains { $0.id == ref.componentID && $0.kind == .ground } }
        })
    }
}
