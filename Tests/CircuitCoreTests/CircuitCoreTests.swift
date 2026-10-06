import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import CircuitCore

@Test func engineeringUnitsRespectSPICE() throws {
    #expect(try EngineeringUnits.parse("1M") == 0.001)
    #expect(try EngineeringUnits.parse("1Meg") == 1_000_000)
    #expect(abs(try EngineeringUnits.parse("10 μF") - 10e-6) < 1e-15)
    #expect(abs(try EngineeringUnits.parse("180nm") - 180e-9) < 1e-18)
    #expect(try EngineeringUnits.parse("1e-3") == 0.001)
    #expect(throws: CircuitError.self) { try EngineeringUnits.parse("10garbage") }
}
@Test func mathSubscriptsAndGreek() {
    let runs = MathLabel.runs("V_{OUT} + \\mu g_m")
    #expect(runs.contains { $0.text == "OUT" && $0.subscripted })
    #expect(runs.contains { $0.text == "m" && $0.subscripted })
    #expect(runs.map(\.text).joined().contains("μ"))
    #expect(MathLabel.netName("V_{OUT}") == "VOUT")
}
@Test func namingNeverReusesDeletedNames() {
    var c = Circuit(); _ = c.add(.nmos, at: .zero); let second = c.add(.nmos, at: Point(100, 0)); c.components.removeAll { $0.id == second }; _ = c.add(.nmos, at: Point(200, 0))
    #expect(c.components.map(\.name) == ["M1", "M3"])
}
@Test func crossingsAreSeparateUntilJunctionAdded() {
    var c = Circuit(); c.wires = [Wire(points: [Point(-40, 0), Point(40, 0)]), Wire(points: [Point(0, -40), Point(0, 40)])]
    #expect(Connectivity(c).nets.count == 2)
    c.junctions.append(.zero)
    #expect(Connectivity(c).nets.count == 1)
    #expect(Connectivity(c).connectionDots.contains(.zero))
}
@Test func endpointOnSegmentConnects() {
    var c = Circuit(); c.wires = [Wire(points: [Point(-40, 0), Point(40, 0)]), Wire(points: [Point(0, -40), .zero])]
    #expect(Connectivity(c).nets.count == 1)
    #expect(Connectivity(c).connectionDots.contains(.zero))
}
@Test func matchingNetLabelsJoinRemoteWires() {
    var c = Circuit(); c.wires = [Wire(points: [Point(0, 0), Point(40, 0)]), Wire(points: [Point(200, 0), Point(240, 0)])]
    c.labels = [CircuitLabel("V_{OUT}", at: Point(20, 0)), CircuitLabel("V_OUT", at: Point(220, 0))]
    #expect(Connectivity(c).nets.count == 1)
}
@Test func suppliesDoNotShortVSSIntoGround() {
    var c = Circuit(); _ = c.add(.ground, at: Point(0, 0)); _ = c.add(.vss, at: Point(100, 0))
    #expect(Set(Connectivity(c).nets.map(\.name)) == ["0", "VSS"])
}
@Test func pmosPinsMatchDrawingAndNetlist() throws {
    let c = CircuitTemplate.inverter.make(), p = c.components.first { $0.kind == .pmos }!
    #expect(p.pinPosition("S")!.y < p.position.y)
    #expect(p.pinPosition("D")!.y > p.position.y)
    let netlist = try SPICENetlist.generate(c)
    #expect(netlist.contains("M1 VOUT VIN VDD VDD PMOS"))
    #expect(netlist.contains("M2 VOUT VIN 0 0 NMOS"))
}
@Test func requestedMOSArrowsAndCappedSupplyRails() {
    for kind in [ComponentKind.nmos, .pmos] {
        let c = Component(kind: kind, name: "M1", position: .zero)
        for theme in SymbolTheme.allCases {
            let geometry = Symbols.geometry(c, theme: theme)
            let arrows = geometry.compactMap { p -> [Point]? in if case .polygon(let points, let filled) = p, filled && points.count == 3 { return points }; return nil }
            #expect(arrows.count == 1)
            let sourceY = theme == .razavi ? 8.0 : 20.0
            #expect(arrows.first?.first == (kind == .nmos ? Point(theme == .razavi ? 7 : 10, sourceY) : Point(0, -sourceY)))
            #expect(!geometry.contains { if case .circle(_, let r, _) = $0 { return r == 4 }; return false })
        }
    }
    for kind in [ComponentKind.vdd, .vss] {
        let geometry = Symbols.geometry(Component(kind: kind, name: kind.prefix, position: .zero), theme: .razavi)
        #expect(geometry.count == 2)
        if case .line(let points) = geometry[0] { #expect(points.allSatisfy { $0.x == 0 }); #expect(points.count == 2) }
        else { Issue.record("Supply rail must have a straight vertical stem") }
        if case .line(let cap) = geometry[1], case .line(let stem) = geometry[0] { #expect(cap.count == 2); #expect(cap[0].y == stem.last?.y); #expect(cap[1].y == cap[0].y); #expect(cap[0].x < 0 && cap[1].x > 0) }
        else { Issue.record("Supply rail needs a horizontal cap at its end") }
    }
}
@Test func movedTerminalsStayConnected() {
    var c = CircuitTemplate.commonSource.make(); let id = c.components[0].id; let wire = c.wires.first { $0.start?.componentID == id }!
    c.components[0].position = c.components[0].position + Point(20, 30)
    #expect(c.resolvedPoints(wire).first == c.position(of: wire.start!))
}
@Test func archiveRoundTripAndRejectFutureVersion() throws {
    let c = CircuitTemplate.commonSource.make(); let archive = CircuitArchive(c)
    #expect(try CircuitArchive.decode(archive.encoded()).circuit == c)
    var future = archive; future.formatVersion = 99
    #expect(throws: CircuitError.self) { try CircuitArchive.decode(future.encoded()) }
}
@Test func circuitikzPreservesEditableProperties() throws {
    let c = CircuitTemplate.commonSource.make(), code = try CircuitikZ.export(c)
    #expect(try CircuitikZ.importCode(code) == c)
    #expect(code.contains("node[nmos")); #expect(code.contains("to[R")); #expect(code.contains("\\end{circuitikz}"))
}
@Test func importsSimpleExternalCircuitikz() throws {
    let code = #"\begin{circuitikz} \draw (0,0) to[R,l={10k}] (0,2); \draw (0,0) node[ground]{}; \end{circuitikz}"#
    let c = try CircuitikZ.importCode(code)
    #expect(c.components.count == 2); #expect(c.components.first?.parameters["value"] == "10k")
}
@Test func exportedPDFAndPNGAreReadable() throws {
    let c = CircuitTemplate.commonSource.make(); let pdf = try CircuitExport.pdf(c)
    let document = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)
    #expect(document?.numberOfPages == 1)
    let png = try CircuitExport.raster(c, scale: 2)
    let source = CGImageSourceCreateWithData(png as CFData, nil)
    #expect(source != nil); #expect(CGImageSourceGetCount(source!) == 1)
    #expect(CircuitExport.svg(c).contains("baseline-shift=\"sub\""))
}
@Test func rcACMatchesAnalyticTransferFunction() throws {
    let c = CircuitTemplate.rcFilter.make(); try SPICENetlist.validate(c)
    let result = try LinearSimulator.run(c), output = result.waveform("VOUT")!
    for (f, v) in zip(result.axis, output.values) { let expected = Complex(1) / Complex(1, 2 * .pi * f * 1e-4); #expect(abs(v.real - expected.real) < 1e-8); #expect(abs(v.imaginary - expected.imaginary) < 1e-8) }
}
@Test func dcAndTransientAreComputedFromSources() throws {
    var c = CircuitTemplate.rcFilter.make(); c.simulation.analysis = .dc
    let dc = try LinearSimulator.run(c); #expect(abs(dc.waveform("VOUT")!.values.last!.real - 1.8) < 1e-8)
    c.simulation.analysis = .tran; c.simulation.timeStep = "10u"; c.simulation.duration = "1m"
    let tran = try LinearSimulator.run(c); #expect(tran.axis.count == 101); #expect(tran.waveform("VOUT")!.values.contains { abs($0.real) > 0.1 })
}
@Test func portableSolverRejectsNonlinearDevices() throws {
    #expect(throws: CircuitError.self) { try LinearSimulator.run(CircuitTemplate.commonSource.make()) }
}
@Test func modelLibraryCannotInjectControlCommands() {
    #expect(throws: CircuitError.self) { try SPICENetlist.validatedModels(".control\nshell echo test\n.endc") }
}
@Test(arguments: ComponentKind.allCases) func eachSymbolHasConnectedPinsAndNoClippedLabels(kind: ComponentKind) throws {
    for theme in SymbolTheme.allCases { for rotation in [0, 90, 180, 270] { for mirror in [false, true] {
        var c = Component(kind: kind, name: kind.isConnection ? kind.prefix : kind.prefix + "12", position: Point(100, 100)); c.rotation = rotation; c.flipX = mirror
        if kind.isMOS { c.parameters["bulk"] = "external" }
        let primitives = Symbols.geometry(c, theme: theme)
        for pin in c.pins {
            let position = c.world(pin.offset)
            let isOnLine = primitives.contains { primitive in if case .line(let points) = primitive { return zip(points, points.dropFirst()).contains { distanceToSegment(position, $0, $1) < 0.001 } }; return false }
            #expect(isOnLine, "\(kind) \(theme) \(rotation) pin \(pin.name) is disconnected from its drawing")
        }
        var circuit = Circuit(); circuit.components = [c]; circuit.theme = theme; let b = circuit.bounds
        for text in Symbols.scene(circuit).texts {
            let tb = Symbols.textBounds(text); #expect(b.contains(Point(tb.minX, tb.minY))); #expect(b.contains(Point(tb.maxX, tb.maxY)))
            let samples = primitives.flatMap { primitive -> [Point] in
                switch primitive {
                case .line(let points), .polygon(let points, _):
                    return zip(points, points.dropFirst()).flatMap { a, z in
                        let steps = max(1, Int(a.distance(to: z)))
                        return (0...steps).map { a + (z - a) * (Double($0) / Double(steps)) }
                    }
                case .circle(let center, let radius, _):
                    return (0..<64).map { let angle = Double($0) / 64 * 2 * Double.pi; return center + Point(radius * cos(angle), radius * sin(angle)) }
                }
            }
            #expect(!samples.contains { tb.contains($0) }, "\(kind) \(theme) \(rotation) label overlaps symbol geometry")
        }
    } } }
}
@Test func createIndividualSymbolReviewArtifacts() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification")
    let folder = root.appendingPathComponent("Symbols"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (i, kind) in ComponentKind.allCases.enumerated() {
        var c = Circuit(title: kind.title); var component = Component(kind: kind, name: kind.isConnection ? kind.prefix : kind.prefix + "1", position: Point(100, 100)); if kind.isMOS { component.parameters["bulk"] = "external" }; c.components = [component]
        let base = String(format: "%02d-", i + 1) + kind.rawValue
        try CircuitExport.raster(c, scale: 3, transparent: false).write(to: folder.appendingPathComponent(base + ".png"))
        try CircuitExport.pdf(c).write(to: folder.appendingPathComponent(base + ".pdf"))
        try CircuitExport.svg(c).write(to: folder.appendingPathComponent(base + ".svg"), atomically: true, encoding: .utf8)
    }
    let c = CircuitTemplate.commonSource.make()
    var comparison = Circuit(title: "Razavi MOS symbols")
    for (kind, x) in [(ComponentKind.nmos, 100.0), (.pmos, 330.0)] {
        var device = Component(kind: kind, name: "M1", position: Point(x, 110)); device.parameters["bulk"] = "external"; device.showName = false; device.showValue = false; comparison.components.append(device)
        comparison.labels += [CircuitLabel(kind == .nmos ? "NMOS" : "PMOS", at: Point(x - 18, 0), isNet: false), CircuitLabel("G", at: Point(x - 68, 98), isNet: false), CircuitLabel("B", at: Point(x + 46, 98), isNet: false), CircuitLabel(kind == .nmos ? "D" : "S", at: Point(x + 4, 43), isNet: false), CircuitLabel(kind == .nmos ? "S" : "D", at: Point(x + 4, 154), isNet: false)]
    }
    try CircuitExport.raster(comparison, scale: 3, transparent: false).write(to: root.appendingPathComponent("razavi-mos-comparison.png"))
    try CircuitExport.svg(comparison).write(to: root.appendingPathComponent("razavi-mos-comparison.svg"), atomically: true, encoding: .utf8)
    var bjt = Circuit(title: "Razavi BJT and supply symbols")
    for (kind, x) in [(ComponentKind.npn, 100.0), (.pnp, 300.0)] {
        var device = Component(kind: kind, name: "Q1", position: Point(x, 110)); device.showName = false; device.showValue = false; bjt.components.append(device)
        bjt.labels += [CircuitLabel(kind.title, at: Point(x - 18, 0), isNet: false), CircuitLabel("B", at: Point(x - 65, 98), isNet: false), CircuitLabel("C", at: Point(x + 4, 43), isNet: false), CircuitLabel("E", at: Point(x + 4, 154), isNet: false)]
    }
    bjt.components += [Component(kind: .vdd, name: "V_{DD}", position: Point(475, 150)), Component(kind: .vss, name: "V_{SS}", position: Point(625, 75))]
    try CircuitExport.raster(bjt, scale: 3, transparent: false).write(to: root.appendingPathComponent("razavi-bjt-supplies.png"))
    try CircuitExport.svg(bjt).write(to: root.appendingPathComponent("razavi-bjt-supplies.svg"), atomically: true, encoding: .utf8)
    try CircuitExport.pdf(bjt).write(to: root.appendingPathComponent("razavi-bjt-supplies.pdf"))
    try CircuitExport.pdf(c).write(to: root.appendingPathComponent("common-source.pdf"))
    try CircuitExport.raster(c, scale: 2, transparent: false).write(to: root.appendingPathComponent("common-source.png"))
    try CircuitikZ.export(c).write(to: root.appendingPathComponent("common-source.tex"), atomically: true, encoding: .utf8)
    try SPICENetlist.generate(c).write(to: root.appendingPathComponent("common-source.spice"), atomically: true, encoding: .utf8)
    let package = root.appendingPathComponent("Common Source.circuit")
    if !FileManager.default.fileExists(atPath: package.path) {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try CircuitArchive(c).encoded().write(to: package.appendingPathComponent("document.json"))
        try CircuitExport.raster(c).write(to: package.appendingPathComponent("preview.png"))
    }
}
@Test func legacyDocumentsOpenWithEmptyFigureCollections() throws {
    let archive = CircuitArchive(CircuitTemplate.commonSource.make())
    var json = try #require(JSONSerialization.jsonObject(with: archive.encoded()) as? [String: Any])
    json["formatVersion"] = 1
    var circuit = try #require(json["circuit"] as? [String: Any]); circuit.removeValue(forKey: "figures"); circuit.removeValue(forKey: "figureConnectors"); json["circuit"] = circuit
    let decoded = try CircuitArchive.decode(JSONSerialization.data(withJSONObject: json)).circuit
    #expect(decoded == archive.circuit)
}
@Test func figureConnectorsFollowMovedResizedAndRotatedShapes() throws {
    var c = PaperExample.system.make()
    let arrow = try #require(c.figureConnectors.first)
    let end = try #require(arrow.end), index = try #require(c.figures.firstIndex { $0.id == end.componentID })
    c.figures[index].position = c.figures[index].position + Point(60, 30); c.figures[index].size = Point(200, 100); c.figures[index].rotation = 90
    #expect(c.resolvedPoints(arrow).last == c.figures[index].anchor(end.pin))
    #expect(try CircuitArchive.decode(CircuitArchive(c).encoded()).circuit == c)
}
@Test func paperAnnotationsDoNotChangeElectricalSimulation() throws {
    let original = CircuitTemplate.commonSource.make(); var decorated = original
    let paper = PaperExample.system.make(); decorated.figures = paper.figures; decorated.figureConnectors = paper.figureConnectors
    #expect(try SPICENetlist.generate(original) == SPICENetlist.generate(decorated))
    #expect(Connectivity(original).terminalNets == Connectivity(decorated).terminalNets)
}
@Test func paperFigureVectorExportsRoundTripAndRemainReadable() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/PaperFigures")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (i, example) in PaperExample.allCases.enumerated() {
        let circuit = example.make(), name = ["system", "flowchart", "device"][i]
        let pdf = try CircuitExport.pdf(circuit), svg = CircuitExport.svg(circuit), tex = try CircuitikZ.export(circuit)
        #expect(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages == 1)
        #expect(svg.contains("<polygon")); #expect(!svg.contains("<image")); #expect(svg.contains(example == .system ? "baseline-shift" : "<text"))
        #expect(try CircuitikZ.importCode(tex) == circuit)
        for figure in circuit.figures { for text in figure.texts { let b = Symbols.textBounds(text); #expect(circuit.bounds.contains(Point(b.minX, b.minY))); #expect(circuit.bounds.contains(Point(b.maxX, b.maxY))) } }
        try pdf.write(to: root.appendingPathComponent(name + ".pdf")); try svg.write(to: root.appendingPathComponent(name + ".svg"), atomically: true, encoding: .utf8)
        try CircuitExport.raster(circuit, scale: 2, transparent: false).write(to: root.appendingPathComponent(name + ".png")); try tex.write(to: root.appendingPathComponent(name + ".tex"), atomically: true, encoding: .utf8)
        let package = root.appendingPathComponent(name + ".circuit")
        if !FileManager.default.fileExists(atPath: package.path) { try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true); try CircuitArchive(circuit).encoded().write(to: package.appendingPathComponent("document.json")); try CircuitExport.raster(circuit).write(to: package.appendingPathComponent("preview.png")) }
    }
}
#if os(macOS)
@Test func embeddedSpiceMatchesDesktopForMOSAnalyses() throws {
    var circuit = CircuitTemplate.commonSource.make()
    for analysis in Analysis.allCases {
        circuit.simulation.analysis = analysis
        let result = try SimulationEngine.run(circuit)
        #expect(result.engine == EmbeddedSpice.version)
        let output = try #require(result.waveform("VOUT"))
        #expect(!output.values.isEmpty)
        #expect(output.values.count == result.axis.count)
        if analysis == .op {
            #expect(try #require(result.operatingPoints["M1"]?["id"]) > 0)
            #expect(try #require(result.operatingPoints["M1"]?["gm"]) > 0)
            #expect(abs(try #require(result.operatingPoints["M1"]?["vgs"]) - 0.55) < 1e-9)
        }
        let executable = "/opt/homebrew/bin/ngspice"
        if FileManager.default.isExecutableFile(atPath: executable) {
            let reference = try NgspiceEngine.run(circuit, executable: executable)
            let expected = try #require(reference.waveform("VOUT"))
            #expect(output.values.count == expected.values.count)
            for (value, other) in zip(output.values, expected.values) {
                #expect(abs(value.real - other.real) < 1e-7)
                #expect(abs(value.imaginary - other.imaginary) < 1e-7)
            }
        }
    }
}
#endif
@Test func embeddedSpiceRCMatchesAnalyticResult() throws {
    let result = try SimulationEngine.run(CircuitTemplate.rcFilter.make())
    let output = try #require(result.waveform("VOUT"))
    for (frequency, value) in zip(result.axis, output.values) {
        let expected = Complex(1) / Complex(1, 2 * .pi * frequency * 1e-4)
        #expect(abs(value.real - expected.real) < 1e-9)
        #expect(abs(value.imaginary - expected.imaginary) < 1e-9)
    }
}
@Test func embeddedSpiceRecoversAfterMissingModel() throws {
    var circuit = CircuitTemplate.commonSource.make()
    circuit.components[0].parameters["model"] = "MISSING_MODEL"
    #expect(throws: CircuitError.self) { try SimulationEngine.run(circuit) }
    let result = try SimulationEngine.run(CircuitTemplate.commonSource.make())
    #expect(result.waveform("VOUT") != nil)
}
@Test func embeddedSpiceSimulatesPMOSAndNMOSInverter() throws {
    var circuit = CircuitTemplate.inverter.make(); circuit.simulation.analysis = .dc
    let dc = try SimulationEngine.run(circuit), values = try #require(dc.waveform("VOUT")).values
    #expect(try #require(values.first).real > 1.79)
    #expect(try #require(values.last).real < 0.01)
    circuit.simulation.analysis = .tran
    let transient = try SimulationEngine.run(circuit), output = try #require(transient.waveform("VOUT"))
    #expect(output.values.contains { $0.real > 1.79 })
    #expect(output.values.contains { $0.real < 0.01 })
}
#if os(macOS)
@Test func realNgspiceSimulatesAnalogMOSCircuit() throws {
    let executable = "/opt/homebrew/bin/ngspice"; guard FileManager.default.isExecutableFile(atPath: executable) else { return }
    var c = CircuitTemplate.commonSource.make()
    for analysis in Analysis.allCases {
        c.simulation.analysis = analysis
        let result = try NgspiceEngine.run(c, executable: executable)
        #expect(!result.waveforms.isEmpty); #expect(!result.axis.isEmpty)
        #expect(result.waveform("VOUT") != nil)
        if analysis == .op { #expect(result.operatingPoints["M1"]?["gm"] != nil) }
    }
}
#endif

@Test func canvasModesPersistAndLegacyDocumentsInferPurpose() throws {
    let blank = Circuit()
    #expect(blank.objectIDs.isEmpty)
    #expect(blank.purpose == .schematic)
    for purpose in CanvasPurpose.allCases {
        let original = Circuit(purpose: purpose)
        #expect(try CircuitArchive.decode(CircuitArchive(original).encoded()).circuit == original)
    }
    for original in [CircuitTemplate.commonSource.make(), PaperExample.system.make(), blank] {
        var archive = try #require(JSONSerialization.jsonObject(with: CircuitArchive(original).encoded()) as? [String: Any])
        var circuit = try #require(archive["circuit"] as? [String: Any])
        circuit.removeValue(forKey: "purpose"); archive["circuit"] = circuit; archive["formatVersion"] = 2
        #expect(try CircuitArchive.decode(JSONSerialization.data(withJSONObject: archive)).circuit.purpose == original.purpose)
    }
}
@Test func illustrationCannotGenerateOrRunSimulation() throws {
    var c = CircuitTemplate.commonSource.make(); c.purpose = .illustration
    #expect(throws: CircuitError.self) { try SPICENetlist.generate(c) }
    #expect(throws: CircuitError.self) { try SimulationEngine.run(c) }
    c.purpose = .schematic
    #expect(try SimulationEngine.run(c).axis.count > 0)
}
@Test func illustrationPortsFollowConnectorsAndExportAsVectors() throws {
    var c = Circuit(purpose: .illustration)
    let input = FigureElement(.inputPort, at: .zero)
    let output = FigureElement(.outputPort, at: Point(250, 0))
    c.figures = [input, output]
    c.figureConnectors = [FigureConnector(from: input.anchor("right")!, to: output.anchor("left")!, start: TerminalRef(input.id, "right"), end: TerminalRef(output.id, "left"))]
    c.figures[1].position = Point(350, 90)
    #expect(c.resolvedPoints(c.figureConnectors[0]).last == c.figures[1].anchor("left"))
    for kind in FigureKind.allCases {
        c.figures.append(FigureElement(kind, at: Point(100, 150)))
    }
    #expect(try CircuitArchive.decode(CircuitArchive(c).encoded()).circuit == c)
    #expect(try CircuitExport.pdf(c).starts(with: Data("%PDF".utf8)))
    #expect(CircuitExport.svg(c).contains("I/O"))
    #expect(Connectivity(c).terminalNets.isEmpty)
}
