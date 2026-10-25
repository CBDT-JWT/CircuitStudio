import XCTest
import ImageIO
import CoreText
import CryptoKit
@testable import CircuitCore

final class AnalogLibraryTests: XCTestCase {
    func testOriginalVectorSymbolsDoNotRequireReferenceResources() throws {
        for entry in AnalogLibrary.entries {
            if case .component(let kind)=entry.item {
                let component=Component(kind:kind,name:"",position:.zero)
                XCTAssertEqual(component.referenceArtwork,false)
                XCTAssertFalse(Symbols.geometry(component,theme:.razavi).isEmpty,kind.rawValue)
            }
        }
        let component=Component(kind:.currentSource,name:"I1",position:.zero)
        var circuit=Circuit();circuit.components=[component]
        XCTAssertEqual(try CircuitArchive.decode(CircuitArchive(circuit).encoded()).circuit.components[0],component)
    }
    func testCompleteReferenceInventoryAndVectorArtwork() throws {
        XCTAssertEqual(AnalogLibrary.entries.count,78)
        XCTAssertEqual(Set(AnalogLibrary.entries.map(\.id)).count,78)
        for kind in ComponentKind.allCases {
            var c = Circuit(title:kind.title); c.add(kind,at:Point(100,100))
            for rotation in [0,90,180,270] {
                c.components[0].rotation=rotation
                XCTAssertFalse(Symbols.geometry(c.components[0],theme:.razavi).isEmpty,kind.title)
                XCTAssertTrue(c.bounds.width.isFinite && c.bounds.height.isFinite)
                XCTAssertFalse(try CircuitExport.raster(c).isEmpty)
            }
            XCTAssertEqual(try CircuitArchive.decode(CircuitArchive(c).encoded()).circuit,c)
        }
    }
    func testBoxSelectionIncludesWiresArrowsAndLabels() {
        var c=Circuit();c.add(.resistor,at:Point(0,0))
        let w=Wire(points:[Point(80,20),Point(180,20)])
        c.wires=[w];c.figureConnectors=[FigureConnector(from:Point(80,50),to:Point(180,50))]
        c.labels=[CircuitLabel("NOTE",at:Point(110,80),isNet:false)]
        let ids=c.objects(in:Bounds([Point(100,0),Point(150,100)]))
        XCTAssertTrue(ids.contains(w.id));XCTAssertTrue(ids.contains(c.figureConnectors[0].id));XCTAssertTrue(ids.contains(c.labels[0].id));XCTAssertFalse(ids.contains(c.components[0].id))
        XCTAssertFalse(Bounds([Point(0,0),Point(10,10)]).intersectsSegment(Point(-10,9),Point(9,20)))
    }
    func testSelectionPNGIsCroppedAndDetachesOutsideConnections() throws {
        var c=Circuit();let a=c.add(.resistor,at:Point(0,0));let b=c.add(.capacitor,at:Point(100,0));let far=c.add(.nmos,at:Point(3000,3000))
        c.connect(a,"2",b,"1");c.connect(b,"2",far,"G")
        let subset=c.selected([a,b])
        XCTAssertEqual(subset.components.count,2);XCTAssertEqual(subset.wires.count,1)
        XCTAssertLessThan(subset.bounds.width,500)
        let wireOnly=c.selected([c.wires[1].id]);XCTAssertNil(wireOnly.wires[0].start);XCTAssertNil(wireOnly.wires[0].end)
        XCTAssertEqual(wireOnly.wires[0].points,c.resolvedPoints(c.wires[1]))
        let data=try CircuitExport.raster(subset,scale:3,transparent:true)
        let image=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData,nil)!,0,nil)!
        XCTAssertEqual(image.width,Int(ceil(subset.bounds.width*3)))
        XCTAssertTrue([.premultipliedLast,.last].contains(image.alphaInfo))
    }
    func testExtendedNetlistNeverSilentlyDropsDevice() throws {
        for kind in ComponentKind.allCases where !kind.isConnection {
            var c=Circuit();c.add(kind,at:.zero)
            do {
                let netlist=try SPICENetlist.generate(c)
                XCTAssertTrue(netlist.contains(c.components[0].name),kind.title)
            } catch { XCTAssertTrue(kind.needsSimulationModel || [.vcvs,.vccs,.chopper,.spdtSwitch].contains(kind),"Unexpected netlist error for \(kind): \(error)") }
        }
    }
    func testPrivateRelayUsesBearerWithoutProviderKey() throws {
        let request=try CircuitAIService.makeRequest(context:"{}",question:"Explain",language:"中文",configuration:.init(endpoint:"https://example.com/api/",accessToken:"cs_access-code-only"))
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer cs_access-code-only")
        XCTAssertEqual(request.url?.path,"/api/explain")
        XCTAssertThrowsError(try CircuitAIService.makeRequest(context:"{}",question:"Explain",language:"中文",configuration:.init(endpoint:"http://example.com",accessToken:"cs_test")))
    }
    func testReferenceTypefaceIsEmbeddedInCanvasAndSVG() throws {
        XCTAssertEqual(CTFontCopyPostScriptName(SchematicTypography.font(size:16)) as String,"Metropolis-Bold")
        XCTAssertEqual(CTFontCopyPostScriptName(SchematicTypography.font(size:16,italic:true)) as String,"Metropolis-BoldItalic")
        let circuit=CircuitTemplate.commonSource.make()
        let svg=CircuitExport.svg(circuit)
        XCTAssertTrue(svg.contains("data:font/ttf;base64,"));XCTAssertTrue(svg.contains("font-weight=\"700\""))
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try CircuitExport.raster(circuit,scale:3,transparent:false).write(to:root.appendingPathComponent("bold-typography-common-source.png"))
    }

    func testGlobalVDDRunsWithoutDrawingASeparateVoltageSource() throws {
        var c=Circuit();let resistor=c.add(.resistor,at:Point(0,0));let power=c.add(.vdd,at:Point(0,-40));let ground=c.add(.ground,at:Point(0,40))
        c.components[0].parameters["value"]="1k";c.supplyVoltages=["VDD":"3.3","VSS":"0"];c.simulation.analysis = .op
        c.connect(power,"1",resistor,"1");c.connect(ground,"1",resistor,"2")
        try SPICENetlist.validate(c)
        let netlist=try SPICENetlist.generate(c)
        XCTAssertTrue(netlist.contains("V_CSGLOBAL_VDD VDD 0 DC 3.3"))
        let result=try EmbeddedSpice.run(c)
        XCTAssertEqual(result.waveform("VDD")?.values.first?.real ?? -1,3.3,accuracy:0.00001)
        XCTAssertEqual(try CircuitArchive.decode(CircuitArchive(c).encoded()).circuit.supplyVoltages,c.supplyVoltages)
        let existing=c.add(.voltageSource,at:Point(100,0));c.connect(existing,"1",power,"1");c.connect(existing,"2",ground,"1")
        XCTAssertFalse(try SPICENetlist.generate(c).contains("V_CSGLOBAL_VDD"))
    }

}
