import XCTest
@testable import CircuitCore

final class PowerRailTests:XCTestCase {
    func testRailProjectsToOneAxisAndBondsPinsAndWireEndsButNotCrossings() throws {
        var c=Circuit();let r=c.add(.resistor,at:Point(40,40))
        c.wires=[Wire(points:[Point(100,-80),Point(100,80)]),Wire(points:[Point(160,60),Point(160,0)])]
        let crossing=c.wires[0],ending=c.wires[1]
        let id=try XCTUnwrap(c.addPowerRail(from:.zero,to:Point(200,30)))
        let rail=try XCTUnwrap(c.wires.first { $0.id == id })
        XCTAssertEqual(rail.points,[.zero,Point(200,0)]);XCTAssertEqual(rail.powerNet,"VDD")
        let topology=Connectivity(c)
        XCTAssertEqual(topology.net(r,"1"),"VDD")
        XCTAssertEqual(topology.nets.first { $0.points.contains(ending.points[0]) }?.name,"VDD")
        XCTAssertNotEqual(topology.nets.first { $0.points.contains(crossing.points[0]) }?.name,"VDD")
        XCTAssertEqual(PowerRailGeometry.endpoint(from:.zero,toward:Point(20,100)),Point(0,100))
        XCTAssertEqual(PowerRailGeometry.endpoint(from:.zero,toward:Point(40,40)),Point(40,0))
        XCTAssertEqual(try CircuitArchive.decode(CircuitArchive(c).encoded()).circuit,c)
    }
    func testRailTapStaysAttachedWhenDeviceOrRailMovesAndResizingBondsNewPins() throws {
        var c=Circuit();let r=c.add(.resistor,at:Point(40,40)),r2=c.add(.resistor,at:Point(240,40))
        let rail=try XCTUnwrap(c.addPowerRail(from:.zero,to:Point(160,0)))
        let lead=try XCTUnwrap(c.wires.first { $0.start == TerminalRef(r,"1") })
        c.components[0].position.y+=80
        XCTAssertEqual(c.resolvedPoints(lead).first,c.components[0].pinPosition("1"))
        XCTAssertEqual(c.resolvedPoints(lead).last,Point(40,0))
        let previous=c
        c.wires[c.wires.firstIndex { $0.id == rail }!].points=[.zero,Point(300,0)]
        c.reconcileRailContacts(rail,previous:previous)
        XCTAssertEqual(c.position(of:c.wires.first { $0.id == lead.id }!.end!),Point(40,0))
        XCTAssertEqual(Connectivity(c).net(r2,"1"),"VDD")
        let index=c.wires.firstIndex { $0.id == rail }!
        c.wires[index].points=c.wires[index].points.map { $0+Point(0,-40) }
        XCTAssertEqual(c.position(of:c.wires.first { $0.id == lead.id }!.end!),Point(40,-40))
    }
    func testGlobalRailSuppliesAnActualCircuitWithoutVoltageSourceArtwork() throws {
        var c=Circuit();let r=c.add(.resistor,at:Point(40,40)),g=c.add(.ground,at:Point(40,100))
        c.supplyVoltages=["VDD":"3.3","VSS":"0"];c.simulation.analysis = .op
        c.components[0].parameters["value"]="1k";c.connect(r,"2",g,"1")
        let rail=try XCTUnwrap(c.addPowerRail(from:.zero,to:Point(200,0)))
        let netlist=try SPICENetlist.generate(c)
        XCTAssertTrue(netlist.contains("V_CSGLOBAL_VDD VDD 0 DC 3.3"))
        let result=try EmbeddedSpice.run(c)
        XCTAssertEqual(result.waveform("VDD")?.values.first?.real ?? -1,3.3,accuracy:0.00001)
        let copy=c.selected([r,g,rail])
        XCTAssertEqual(copy.wires.filter { $0.powerNet != nil }.count,1)
        XCTAssertTrue(copy.wires.contains { $0.end?.componentID == rail })
    }
    func testGateArityUsesOriginalThreeAndFourInputAssets() throws {
        for kind in [ComponentKind.andGate,.orGate,.nandGate,.norGate,.xorGate,.xnorGate] {
            for count in [2,3,4] {
                var c=Component(kind:kind,name:"B1",position:.zero);c.parameters["inputs"]=String(count)
                XCTAssertEqual(c.pins.count,count+1)
                XCTAssertNotNil(c.pins.first { $0.name == "OUT" })
                var circuit=Circuit();circuit.components=[c]
                XCTAssertFalse(try CircuitExport.raster(circuit).isEmpty)
                let netlist=try SPICENetlist.generate(circuit)
                for pin in c.pins where pin.name != "OUT" { XCTAssertTrue(netlist.contains(Connectivity(circuit).net(c.id,pin.name))) }
            }
        }
    }
}
