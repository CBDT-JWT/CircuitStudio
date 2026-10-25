import XCTest
@testable import CircuitCore

final class EngineeringSimulationTests:XCTestCase {
    func testMissingFoundrySubcircuitNamesAreReportedBeforeSpice() throws {
        var settings=SimulationSettings();settings.analysis = .dc;settings.source="V1"
        let source="XM1 OUT IN VDD VDD sky130_fd_pr__pfet_01v8 l=0.15 w=1 nf=1 m=1\nXM2 OUT IN 0 0 sky130_fd_pr__nfet_01v8 l=0.15 w=1 nf=1 m=1\nV1 IN 0 1\nR1 OUT 0 1k"
        XCTAssertThrowsError(try EngineeringSimulation.deck(source,settings:settings,supplies:["VDD":"1.8"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("sky130_fd_pr__nfet_01v8"));XCTAssertTrue(error.localizedDescription.contains("sky130_fd_pr__pfet_01v8"))
        }
    }
    func testHierarchicalRCUsesRealNgspice()throws {
        let source="""
        .subckt leaf IN OUT VSS
        R1 IN OUT 10k
        C1 OUT VSS 10n
        .ends leaf
        V1 VIN 0 DC 1 AC 1
        X1 VIN VOUT 0 leaf
        """
        var settings=SimulationSettings();settings.analysis = .ac;settings.start="10";settings.stop="100k"
        let result=try EmbeddedSpice.run(netlist:source,settings:settings)
        XCTAssertTrue(result.engine.contains("ngspice"))
        let output=try XCTUnwrap(result.waveform("VOUT"))
        for (frequency,value) in zip(result.axis,output.values) {
            let expected=Complex(1)/Complex(1,2*Double.pi*frequency*1e-4)
            XCTAssertEqual(value.real,expected.real,accuracy:1e-7);XCTAssertEqual(value.imaginary,expected.imaginary,accuracy:1e-7)
        }
    }
    func testSupplyRailsNeedNoDrawnSource()throws {
        var settings=SimulationSettings();settings.analysis = .op
        let source="R1 VDD VOUT 10k\nR2 VOUT 0 10k"
        let result=try EmbeddedSpice.run(netlist:source,settings:settings,supplies:["VDD":"1.8"])
        XCTAssertEqual(try XCTUnwrap(result.waveform("VOUT")?.values.first?.real),0.9,accuracy:1e-8)
        let deck=try EngineeringSimulation.deck("V1 VDD 0 2\n"+source,settings:settings,supplies:["VDD":"1.8"])
        XCTAssertFalse(deck.contains("VCS_VDD"))
    }
    func testUnsafeAndInvalidDeckCommandsAreRejected()throws {
        let settings=SimulationSettings()
        for line in [".control\nshell touch /tmp/not-allowed\n.endc",".include /etc/passwd",".lib secret.lib typical",".save all",".op","R1 a 0 `shell`","R1 a 0 1k; shell"] {
            XCTAssertThrowsError(try EngineeringSimulation.deck(line,settings:settings),line)
        }
        XCTAssertThrowsError(try EngineeringSimulation.deck("R1 VDD 0 1k",settings:settings,supplies:["VDD\n.control":"1.8"]))
    }
    func testNativeModelAndDeviceParametersAreRespected()throws {
        var settings=SimulationSettings();settings.analysis = .op
        let source="""
        .param resistance=10k
        .subckt divider IN OUT VSS params: r=resistance
        R1 IN OUT {r}
        R2 OUT VSS {r}
        .ends divider
        V1 VIN 0 2
        XTOP VIN VOUT 0 divider r=20k
        """
        let result=try EmbeddedSpice.run(netlist:source,settings:settings)
        XCTAssertEqual(try XCTUnwrap(result.waveform("VOUT")?.values.first?.real),1,accuracy:1e-8)
    }
    private func request(analysis:Analysis,supplies:String="VDD=1.8\nVSS=0",models:String="") throws -> EngineeringSimulationRequest {
        var settings=SimulationSettings();settings.analysis=analysis;settings.start="10";settings.stop="100k";settings.source="V1";settings.dcStart="0";settings.dcStop="1.8";settings.dcStep="0.1";settings.duration="1m";settings.timeStep="10u"
        let data=try JSONSerialization.data(withJSONObject:["source":["id":"tools-rc","name":"Tools RC","netlist":"V1 VIN 0 DC 1 AC 1\nR1 VIN VOUT 10k\nC1 VOUT 0 10n"],"configuration":["settings":JSONSerialization.jsonObject(with:JSONEncoder().encode(settings)),"supplies":supplies,"models":models]])
        return try JSONDecoder().decode(EngineeringSimulationRequest.self,from:data)
    }
    func testToolsBridgeExecutesAllFourAnalyses() throws {
        for analysis in Analysis.allCases {
            let result=try request(analysis:analysis).run()
            XCTAssertEqual(result.analysis,analysis)
            XCTAssertFalse(result.axis.isEmpty)
            XCTAssertNotNil(result.waveform("VOUT"))
        }
    }
    func testToolsBridgeRejectsConflictingSuppliesAndExternalModels() throws {
        for supplies in ["VDD=1.8\nvdd=3.3","VDD","VDD=garbage"] {
            XCTAssertThrowsError(try request(analysis:.op,supplies:supplies).run())
        }
        XCTAssertThrowsError(try request(analysis:.op,models:".include /etc/passwd").run())
    }

}
