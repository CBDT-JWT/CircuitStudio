import Testing
import Foundation
@testable import CircuitCore

@Test func inkRCExampleCreatesReviewableComponentsAndConnections() throws {
    let result = try CircuitInkRecognizer.recognize(CircuitInkRecognizer.example)
    #expect(result.components.count == 5)
    #expect(result.components.filter { $0.kind == .ground }.count == 2)
    #expect(result.components.filter { $0.kind == .resistor }.count == 1)
    #expect(result.components.filter { $0.kind == .capacitor }.count == 1)
    #expect(result.components.filter { $0.kind == .voltageSource }.count == 1)
    #expect(result.wires.count == 4)
    #expect(result.unrecognizedStrokes == 0)
    let circuit = try result.circuit(includeWires: true)
    #expect(circuit.components.filter { !$0.kind.isConnection }.allSatisfy { $0.parameters["value"] == "" })
    #expect(circuit.wires.allSatisfy { $0.start != nil && $0.end != nil })
    #expect(throws: CircuitError.self) { try SPICENetlist.validate(circuit) }
    var complete = circuit
    for i in complete.components.indices where complete.components[i].parameters["value"] != nil {
        complete.components[i].parameters["value"] = complete.components[i].kind == .resistor ? "10k" : complete.components[i].kind == .capacitor ? "10n" : "1"
    }
    try SPICENetlist.validate(complete)
    #expect(try result.circuit(includeWires: false).wires.isEmpty)
}

@Test func inkVerticalPlatesAndResistorRespectRotation() throws {
    let ink = [CircuitInkStroke([Point(0, 0), Point(0, 50)]), CircuitInkStroke([Point(15, 0), Point(15, 50)]),
               CircuitInkStroke([Point(100, 0), Point(85, 15), Point(115, 30), Point(85, 45), Point(115, 60), Point(100, 75)])]
    let result = try CircuitInkRecognizer.recognize(ink)
    #expect(result.components.first { $0.kind == .capacitor }?.rotation == 270)
    #expect(result.components.first { $0.kind == .resistor }?.rotation == 0)
}

@Test func incompleteGroundDoesNotBecomeACapacitor() throws {
    let bars = [CircuitInkStroke([Point(-30, 0), Point(30, 0)]),
                CircuitInkStroke([Point(-21, 10), Point(21, 10)]),
                CircuitInkStroke([Point(-12, 20), Point(12, 20)])]
    #expect(try CircuitInkRecognizer.recognize(Array(bars.prefix(2))).components.isEmpty)
    #expect(try CircuitInkRecognizer.recognize(bars).components.map(\.kind) == [.ground])
}

@Test func inkCrossingsStayUnjoinedAndTextIsNotImported() throws {
    let ink = [CircuitInkStroke([Point(-100, 0), Point(100, 0)]), CircuitInkStroke([Point(0, -100), Point(0, 100)]),
               CircuitInkStroke([Point(200, 0), Point(220, 30), Point(240, 0)])]
    let result = try CircuitInkRecognizer.recognize(ink)
    #expect(result.components.isEmpty)
    #expect(result.wires.count == 2)
    #expect(result.unrecognizedStrokes == 1)
    var circuit = Circuit()
    circuit.wires = result.wires
    #expect(Connectivity(circuit).nets.count == 2)
}

@Test func inkReviewDropsExcludedComponentsAndInvalidPinAttachments() throws {
    var result = try CircuitInkRecognizer.recognize(CircuitInkRecognizer.example)
    let index = try #require(result.components.firstIndex { $0.kind == .capacitor })
    let id = result.components[index].id
    result.components[index].included = false
    let circuit = try result.circuit(includeWires: true)
    #expect(!circuit.components.contains { $0.id == id })
    #expect(circuit.wires.allSatisfy { $0.start?.componentID != id && $0.end?.componentID != id })
    result.components[index].included = true
    result.components[index].kind = .nmos
    let changed = try result.circuit(includeWires: true)
    #expect(changed.wires.allSatisfy { ($0.start?.componentID != id || $0.start?.pin != "1") && ($0.end?.componentID != id || $0.end?.pin != "2") })
}

@Test func inkAndAnnotationsRoundTripWithoutChangingOldDocuments() throws {
    var circuit = Circuit()
    circuit.handDrawing = Data([1, 2, 3]); circuit.annotationDrawing = Data([4, 5, 6])
    let data = try CircuitArchive(circuit).encoded()
    #expect(try CircuitArchive.decode(data).circuit == circuit)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var value = try #require(json["circuit"] as? [String: Any])
    value.removeValue(forKey: "handDrawing"); value.removeValue(forKey: "annotationDrawing"); json["circuit"] = value
    let restored = try CircuitArchive.decode(JSONSerialization.data(withJSONObject: json))
    #expect(restored.circuit.handDrawing == nil && restored.circuit.annotationDrawing == nil)
    #expect(throws: CircuitError.self) { try CircuitInkRecognizer.recognize([CircuitInkStroke([Point(.nan, 0)])]) }
    #expect(throws: CircuitError.self) { try CircuitInkRecognizer.recognize(Array(repeating: CircuitInkStroke([]), count: 501)) }
}

@Test func lassoPolygonHandlesConcaveSelection() {
    let polygon = [Point(0, 0), Point(100, 0), Point(100, 30), Point(30, 30), Point(30, 100), Point(0, 100)]
    #expect(CircuitInkRecognizer.contains(Point(10, 80), in: polygon))
    #expect(!CircuitInkRecognizer.contains(Point(80, 80), in: polygon))
    #expect(!CircuitInkRecognizer.contains(Point(10, 10), in: []))
}

@Test func handwrittenRectangularResistorsAndIncompleteBoxes() throws {
    let sides = [CircuitInkStroke([Point(0, 0), Point(80, 1)]), CircuitInkStroke([Point(80, 1), Point(81, 25)]), CircuitInkStroke([Point(81, 25), Point(1, 24)]), CircuitInkStroke([Point(1, 24), Point(0, 0)])]
    #expect(try CircuitInkRecognizer.recognize(Array(sides.prefix(3))).components.isEmpty)
    let split = try CircuitInkRecognizer.recognize(sides)
    #expect(split.components.map(\.kind) == [.resistor])
    #expect(split.components[0].strokeIndices.count == 4)
    let one = try CircuitInkRecognizer.recognize([CircuitInkStroke([Point(0, 0), Point(80, 1), Point(81, 25), Point(1, 24), Point(0, 0)])])
    #expect(one.components.map(\.kind) == [.resistor])
    #expect(one.components[0].rotation == 270)
    let oval = (0...32).map { i in let a = Double(i) * .pi / 16; return Point(40 * cos(a), 12 * sin(a)) }
    #expect(try CircuitInkRecognizer.recognize([CircuitInkStroke(oval)]).components.isEmpty)
}

@Test func capacitorAcceptsPlatesWithLeads() throws {
    let ts = [CircuitInkStroke([Point(100, -25), Point(100, 0), Point(65, 0), Point(100, 0), Point(100, 25)]), CircuitInkStroke([Point(120, -25), Point(120, 0), Point(155, 0), Point(120, 0), Point(120, 25)])]
    let result = try CircuitInkRecognizer.recognize(ts)
    #expect(result.components.map(\.kind) == [.capacitor])
    #expect(result.components[0].anchors["1"] == Point(65, 0))
    #expect(result.components[0].anchors["2"] == Point(155, 0))
    #expect(result.unrecognizedStrokes == 0)
}

private var mosInk: [CircuitInkStroke] {
    [CircuitInkStroke([Point(-14, -19), Point(-14, 19)]),
     CircuitInkStroke([Point(10, -40), Point(10, -20), Point(0, -20), Point(0, 20), Point(10, 20), Point(10, 40)]),
     CircuitInkStroke([Point(-40, 0), Point(-14, 0)])]
}

@Test func mosGateChannelBranchesRecognizeAtEveryRightAngle() throws {
    for rotation in [0, 90, 180, 270] {
        let strokes = mosInk.map { CircuitInkStroke($0.points.map { $0.transformed(rotation: rotation, flipX: false, flipY: false) }) }
        let result = try CircuitInkRecognizer.recognize(strokes)
        #expect(result.components.map(\.kind) == [.nmos])
        #expect(result.components[0].rotation == rotation)
        #expect(result.components[0].anchors["G"] == Point(-40, 0).transformed(rotation: rotation, flipX: false, flipY: false))
        #expect(result.unrecognizedStrokes == 0)
        let pmos = try CircuitInkRecognizer.recognize(strokes, preferredMOS: .pmos)
        #expect(pmos.components.map(\.kind) == [.pmos])
        #expect(pmos.components[0].anchors["S"] == Point(10, -40).transformed(rotation: rotation, flipX: false, flipY: false))
    }
}

@Test func laterBranchesDisambiguateMOSFromCapacitor() throws {
    let strokes = [CircuitInkStroke([Point(-14, -19), Point(-14, 19)]), CircuitInkStroke([Point(0, -20), Point(0, 20)]), CircuitInkStroke([Point(0, -20), Point(20, -20)]), CircuitInkStroke([Point(0, 20), Point(20, 20)])]
    #expect(try CircuitInkRecognizer.recognize(Array(strokes.prefix(2))).components.map(\.kind) == [.capacitor])
    let complete = try CircuitInkRecognizer.recognize(strokes)
    #expect(complete.components.map(\.kind) == [.nmos])
    #expect(complete.components[0].strokeIndices.count == 4)
}

@Test func severalHandwrittenComponentsRemainSeparate() throws {
    let resistor = CircuitInkStroke([Point(-200, -12), Point(-120, -12), Point(-120, 12), Point(-200, 12), Point(-200, -12)])
    let capacitor = [CircuitInkStroke([Point(175, -8), Point(225, -8)]), CircuitInkStroke([Point(175, 8), Point(225, 8)])]
    let result = try CircuitInkRecognizer.recognize([resistor] + mosInk + capacitor)
    #expect(result.components.count == 3)
    #expect(Set(result.components.map(\.kind)) == [.resistor, .nmos, .capacitor])
    #expect(Set(result.components.map(\.id)).count == 3)
    #expect(result.unrecognizedStrokes == 0)
}

@Test func compactAcademicMOSIsRecognized() throws {
    let ink = [CircuitInkStroke([Point(-9, -9), Point(-9, 9)]), CircuitInkStroke([Point(-3, -12), Point(-3, 12)]), CircuitInkStroke([Point(-3, -8), Point(10, -8), Point(10, -40)]), CircuitInkStroke([Point(-3, 8), Point(10, 8), Point(10, 40)]), CircuitInkStroke([Point(-40, 0), Point(-9, 0)])]
    #expect(try CircuitInkRecognizer.recognize(ink).components.map(\.kind) == [.nmos])
}

@Test func handwrittenMOSAcceptsRetracedGateLead() throws {
    let gate = CircuitInkStroke([Point(-14, -20), Point(-14, 0), Point(-40, 0), Point(-14, 0), Point(-14, 20)])
    let channel = CircuitInkStroke([Point(10, -40), Point(10, -20), Point(0, -20), Point(0, 20), Point(10, 20), Point(10, 40)])
    let result = try CircuitInkRecognizer.recognize([gate, channel])
    #expect(result.components.map(\.kind) == [.nmos])
    #expect(result.components.first?.anchors["G"] == Point(-40, 0))
    #expect(result.unrecognizedStrokes == 0)
}

@Test func modestHandwritingSlantStillRecognizesMOS() throws {
    for degrees in [-12.0, 12.0] {
        let angle = degrees * .pi / 180
        let ink = mosInk.map { stroke in CircuitInkStroke(stroke.points.map { p in
            Point(p.x * cos(angle) - p.y * sin(angle), p.x * sin(angle) + p.y * cos(angle))
        }) }
        #expect(try CircuitInkRecognizer.recognize(ink).components.map(\.kind) == [.nmos])
    }
}

@Test func smallCapacitorAndSlantedResistorAreRecognizedSeparately() throws {
    let angle = 12.0 * .pi / 180
    let resistor = CircuitInkStroke([Point(0, 0), Point(80, 0), Point(80, 24), Point(0, 24), Point(0, 0)].map { p in
        Point(p.x * cos(angle) - p.y * sin(angle), p.x * sin(angle) + p.y * cos(angle))
    })
    let capacitor = [CircuitInkStroke([Point(180, 0), Point(180, 18)]), CircuitInkStroke([Point(188, 0), Point(188, 18)])]
    let result = try CircuitInkRecognizer.recognize([resistor] + capacitor)
    #expect(Set(result.components.map(\.kind)) == [.resistor, .capacitor])
    #expect(result.components.count == 2)
}

@Test func slantedCapacitorWithRetracedLeadsKeepsItsAnchors() throws {
    let angle = -12.0 * .pi / 180
    func tilt(_ p: Point) -> Point { Point(p.x * cos(angle) - p.y * sin(angle), p.x * sin(angle) + p.y * cos(angle)) }
    let ink = [CircuitInkStroke([Point(0, -25), Point(0, 0), Point(-35, 0), Point(0, 0), Point(0, 25)].map(tilt)), CircuitInkStroke([Point(20, -25), Point(20, 0), Point(55, 0), Point(20, 0), Point(20, 25)].map(tilt))]
    let result = try CircuitInkRecognizer.recognize(ink)
    #expect(result.components.map(\.kind) == [.capacitor])
    #expect((result.components.first?.anchors["1"]?.distance(to: tilt(Point(-35, 0))) ?? .infinity) < 0.01)
    #expect((result.components.first?.anchors["2"]?.distance(to: tilt(Point(55, 0))) ?? .infinity) < 0.01)
}

@Test func retracedRectangleWithAttachedLeadRecognizesWithoutDrawingOrderDependency() throws {
    let points = [Point(-30, 12), Point(0, 12), Point(0, 0), Point(80, 0), Point(80, 24), Point(0, 24), Point(0, 12), Point(-30, 12)]
    for reverse in [false, true] {
        let result = try CircuitInkRecognizer.recognize([CircuitInkStroke(reverse ? Array(points.reversed()) : points)])
        #expect(result.components.map(\.kind) == [.resistor])
        #expect(result.components.first?.anchors["1"] == Point(-30, 12))
        #expect(result.unrecognizedStrokes == 0)
    }
}

@Test func handwritingToleranceDoesNotCombineMisalignedPlatesOrEllipticalLoops() throws {
    let skewed = [CircuitInkStroke([Point(0, 0), Point(0, 25)]), CircuitInkStroke([Point(9, 20), Point(9, 45)])]
    #expect(try CircuitInkRecognizer.recognize(skewed).components.isEmpty)
    let angle = 12.0 * .pi / 180
    let oval = (0...32).map { i in let a = Double(i) * .pi / 16, x = 40 * cos(a), y = 12 * sin(a); return Point(x * cos(angle) - y * sin(angle), x * sin(angle) + y * cos(angle)) }
    #expect(try CircuitInkRecognizer.recognize([CircuitInkStroke(oval)]).components.isEmpty)
}

@Test func denseUnevenMOSStrokesSurviveSizeSlantAndDrawingOrderChanges() throws {
    let paths = [[Point(-14, -20), Point(-14, 0), Point(-40, 0), Point(-14, 0), Point(-14, 20)],
                 [Point(10, -40), Point(10, -20), Point(0, -20), Point(0, 20), Point(10, 20), Point(10, 40)]]
    for scale in [0.75, 1.0, 1.6] {
        for degrees in [-12.0, 12.0] {
            for rotation in [0, 90, 180, 270] {
                let angle = (degrees + Double(rotation)) * .pi / 180
                let input = paths.map { path in
                    var points = [path[0]]
                    for (a, b) in zip(path, path.dropFirst()) {
                        let count = max(1, Int(a.distance(to: b) / 2))
                        for i in 1...count {
                            let p = a + (b - a) * (Double(i) / Double(count))
                            let noise = i == count ? Point() : Point(0.7 * sin(Double(i)), 0.7 * cos(Double(i) * 1.3))
                            points.append(p + noise)
                        }
                    }
                    return CircuitInkStroke(points.map { p in Point(scale * (p.x * cos(angle) - p.y * sin(angle)) + 137, scale * (p.x * sin(angle) + p.y * cos(angle)) - 83) })
                }
                let result = try CircuitInkRecognizer.recognize(Array(input.reversed()))
                #expect(result.components.map(\.kind) == [.nmos])
                #expect(result.components.first?.rotation == rotation)
                #expect(result.unrecognizedStrokes == 0)
            }
        }
    }
}
