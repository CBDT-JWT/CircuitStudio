import Foundation
import Testing
@testable import CircuitCore

@Test func handDrawnWireCanStartAtOnePinAndKeepItsFreeEnd() throws {
    var circuit = Circuit(title: "Wire")
    let id = circuit.add(.resistor, at: Point(100, 100))
    let component = try #require(circuit.components.first)
    let pin = try #require(component.pins.first)
    let start = component.world(pin.offset)
    let original = Wire(points: [start + Point(2, 3), Point(210, 42)])
    let wire = try #require(CircuitInkResult.connectedWire(original, in: circuit))
    #expect(wire.start == TerminalRef(id, pin.name))
    #expect(wire.points[0] == start)
    #expect(wire.end == nil)
    #expect(wire.points.last == original.points.last)
    #expect(CircuitInkResult.connectedWire(Wire(points: [Point(400,400),Point(470,405)]), in: circuit) == nil)
}

@Test func handDrawnWireCanBranchFromAnExistingSegment() throws {
    var circuit = Circuit(title: "Junction")
    circuit.wires = [Wire(points: [Point(0,50),Point(100,50)])]
    let branch = try #require(CircuitInkResult.connectedWire(Wire(points: [Point(48,54),Point(50,110)]), in: circuit))
    #expect(branch.points[0] == Point(48,50))
    #expect(branch.points.last == Point(50,110))
    #expect(branch.start == nil && branch.end == nil)
}

@Test func handDrawnWireStraightensSlantAndKeepsBentEndpoints() throws {
    let slanted = [Point(0,0),Point(20,4),Point(45,7),Point(80,12)]
    #expect(CircuitHandwritingRecognizer.wirePath(slanted) == [slanted.first!,slanted.last!])
    let bent = [Point(0,0),Point(20,3),Point(60,8),Point(63,35),Point(67,70)]
    let path = try #require(CircuitHandwritingRecognizer.wirePath(bent))
    #expect(path.first == bent.first && path.last == bent.last)
    #expect(path.count >= 3)
    #expect(CircuitHandwritingRecognizer.wirePath([Point(0,0),Point(30,40),Point(-20,45),Point(40,5)]) == nil)
}

@Test func neighboringNewInkDoesNotRequireUntouchedHistoryToMatchAgain() {
    #expect(CircuitInkResult.replacedHistoricalGroups([[0,1],[2,3]], consuming: [2,3,4]) == [1])
    #expect(CircuitInkResult.replacedHistoricalGroups([[0,1],[2,3]], consuming: [4]) == [])
    #expect(CircuitInkResult.replacedHistoricalGroups([[0,1],[2,3]], consuming: [0,2,3,4]) == nil)
    #expect(CircuitInkResult.replacedHistoricalGroups([[0,1],[2,3]], consuming: [0,1,2,3,4]) == [0,1])
}
