// Compile with CircuitCore sources and EditorStore to exercise real editing commands.
import SwiftUI
import ImageIO

@main struct EditorVerification {
    @MainActor static func main() async throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) throws {
            guard passed else { throw CircuitError.message("Editor verification failed: \(name)") }
            checks.append(["check": name, "passed": true])
        }
        // Exercise the real chat coordinator beyond the former eight-step cap.
        // Only the provider/tool boundaries are deterministic test doubles.
        let context="{\"schema\":\"circuitstudio-assistant-v1\",\"id\":\"long-task\",\"activeDocumentId\":\"cell\",\"structureRevision\":0,\"documents\":[{\"id\":\"cell\",\"revision\":0}]}"
        var turns=0;var executed=0
        let longChat=EngineeringChat(response:{_,messages,_ in
            turns+=1
            guard messages.count<=40 else { throw CircuitError.message("Unbounded chat context") }
            if turns==26 { return .init(role:"assistant",content:.string("completed long task")) }
            return .init(role:"assistant",tool_calls:[.init(id:"long-\(turns)",type:"function",function:.init(name:"inspect_circuit",arguments:"{}"))])
        },access:{CircuitAIConfiguration(endpoint:"https://example.invalid/",accessToken:"test-only-not-a-real-credential")})
        longChat.send("Complete a long task",snapshot:{context},execute:{_,_,stamp in executed+=1;return .init(content:"{}",image:nil,stamp:stamp)})
        for _ in 0..<1000 { if !longChat.sending { break };try await Task.sleep(for:.milliseconds(5)) }
        try check("CircuitAI continues through 25 tool calls without a round cap",executed==25 && turns==26 && longChat.error==nil && !longChat.sending)
        var stopCalls=0
        let stoppedChat=EngineeringChat(response:{_,_,_ in
            stopCalls+=1;try await Task.sleep(for:.milliseconds(10))
            return .init(role:"assistant",tool_calls:[.init(id:"stop-\(stopCalls)",type:"function",function:.init(name:"inspect_circuit",arguments:"{}"))])
        },access:{CircuitAIConfiguration(endpoint:"https://example.invalid/",accessToken:"test-only-not-a-real-credential")})
        stoppedChat.send("Stop test",snapshot:{context},execute:{_,_,stamp in .init(content:"{}",image:nil,stamp:stamp)})
        for _ in 0..<100 { if stopCalls>=3 { break };try await Task.sleep(for:.milliseconds(5)) }
        stoppedChat.cancel();let atStop=stopCalls;try await Task.sleep(for:.milliseconds(50))
        try check("Unlimited CircuitAI workflow still stops immediately on user cancellation",!stoppedChat.sending && stopCalls==atStop)
        let modelRoot=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:modelRoot) }
        let library=EngineeringModelLibrary(directory:modelRoot)
        let saved=try library.handle(["operation":"save","name":"Test only MOS","text":".model TEST_N NMOS LEVEL=1 VTO=0.4"])
        let reopened=EngineeringModelLibrary(directory:modelRoot)
        let loaded=try reopened.handle(["operation":"read","id":saved["id"]!])
        try check("Shared model library survives workspace replacement",loaded["text"] as? String == ".model TEST_N NMOS LEVEL=1 VTO=0.4")
        _=try reopened.handle(["operation":"save","name":"Same model renamed","text":".model TEST_N NMOS LEVEL=1 VTO=0.4"])
        try check("Shared model packets deduplicate by content",(try library.handle(["operation":"list"])["entries"] as? [[String:String]])?.count == 1)
        var rejectedModel=false
        do { _=try library.handle(["operation":"save","name":"Unsafe","text":".model TEST_N NMOS LEVEL=1\n.control\nshell touch invalid\n.endc"]) } catch { rejectedModel=true }
        try check("Shared models reject executable control commands",rejectedModel)
        var acSettings=SimulationSettings();acSettings.analysis = .ac;acSettings.start="10";acSettings.stop="1Meg";acSettings.points=20;acSettings.probes=["OUT"]
        let rcSource="V1 IN 0 DC 0 AC 1 PULSE(0 1 1u 1n 1n 10u 20u)\nR1 IN OUT 20k\nC1 OUT 0 10n"
        let acResult=try EmbeddedSpice.run(netlist:rcSource,settings:acSettings)
        let acOutput=EngineeringSimulationOutput(source:EngineeringRunSource(id:"figures",name:"RC",netlist:rcSource),settings:acSettings,result:acResult)
        var style=CircuitAIPlotOptions();style.title="RC low-pass";style.xLabel="Frequency (Hz)";style.yLabel="Gain (dB)";style.phaseLabel="Phase (deg)";style.legend=["V(OUT)":"Output"];style.traces=["OUT"]
        let acFigure=try CircuitAIPlotRenderer.figure(acOutput,options:style)
        try acFigure.png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("actual-rc-figure.png"))
        try check("AI figure uses actual AC data and editable axis/legend settings",acFigure.png.count>1000 && acFigure.options.xLabel=="Frequency (Hz)" && acFigure.output.result.axis.count==101)
        var transientSettings=acSettings;transientSettings.analysis = .tran;transientSettings.timeStep="100n";transientSettings.duration="100u"
        let transientResult=try EmbeddedSpice.run(netlist:rcSource,settings:transientSettings)
        let transientOutput=EngineeringSimulationOutput(source:acOutput.source,settings:transientSettings,result:transientResult)
        var transientStyle=CircuitAIPlotOptions();transientStyle.title="Transient";transientStyle.xLabel="Time (s)";transientStyle.yLabel="Output (V)"
        let transientFigure=try CircuitAIPlotRenderer.figure(transientOutput,options:transientStyle)
        try check("Separate analyses retain distinct immutable figures",acFigure.id != transientFigure.id && acFigure.output.result.analysis == .ac && transientFigure.output.result.analysis == .tran)
        let unchanged=acFigure.output.result.axis
        style.legend=["V(OUT)":"Renamed output"];let restyled=try CircuitAIPlotRenderer.figure(acOutput,options:style)
        try check("Restyling labels preserves result identity and samples",restyled.id==acFigure.id && restyled.output.result.axis==unchanged && restyled.png != acFigure.png)
        var badStyle=style;badStyle.traces=["MISSING"]
        var missingRejected=false;do{_=try CircuitAIPlotRenderer.figure(acOutput,options:badStyle)}catch{missingRejected=true}
        try check("Unknown plot traces are rejected rather than replaced",missingRejected)
        var sineSettings=SimulationSettings();sineSettings.analysis = .tran;sineSettings.timeStep="1u";sineSettings.duration="10m";sineSettings.probes=["IN"]
        let sineSource="VIN IN 0 DC 0 SIN(0 2 1k)\nR1 IN 0 1k"
        let sineResult=try EmbeddedSpice.run(netlist:sineSource,settings:sineSettings)
        let spectrum=try CircuitSignalAnalysis.spectrum(sineResult)
        let fftWave=spectrum.waveform("IN")!,peak=fftWave.values.indices.max{fftWave.values[$0].magnitude<fftWave.values[$1].magnitude}!
        try check("FFT of actual adaptive ngspice samples retains 1kHz and 2V peak",abs(spectrum.axis[peak]-1000)<1 && abs(fftWave.values[peak].magnitude-2)<0.01)
        let (_,energy)=try CircuitSignalAnalysis.power(sineResult,positive:"IN",current:"I(VIN)",delivered:true)
        try check("Actual resistor power integrates to the analytical delivered energy",abs(energy.mean-0.002)<1e-5 && abs(energy.integral-0.00002)<1e-7)
        let sineOutput=EngineeringSimulationOutput(source:EngineeringRunSource(id:"fft",name:"Actual sine",netlist:sineSource),settings:sineSettings,result:sineResult)
        var fftStyle=CircuitAIPlotOptions();fftStyle.mode = .spectrum;fftStyle.title="Actual 1kHz sine FFT";fftStyle.xLabel="Frequency (Hz)";fftStyle.yLabel="Amplitude (dB)"
        let fftFigure=try CircuitAIPlotRenderer.figure(sineOutput,options:fftStyle)
        try fftFigure.png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("actual-sine-fft.png"))
        try check("FFT figure keeps the original immutable transient result",fftFigure.output.id==sineOutput.id && fftFigure.output.result.analysis == .tran && fftFigure.png.count>1000)
        let normalized=try CircuitAIImageAttachment.read(acFigure.png,name:"waveform.png")
        let normalizedImage=NSImage(data:normalized.data)
        try check("Image attachments are normalized to bounded JPEG pixels",normalized.data.count<=600_000 && normalizedImage != nil && normalized.data.starts(with:[0xff,0xd8,0xff]))
        var replyStep=0;var sawUpload=false;var preservedUpload=false
        let visualChat=EngineeringChat(response:{_,messages,_ in
            replyStep+=1
            let uploads=messages.filter{$0.imageOrigin=="attachment"}
            if replyStep==1{sawUpload=uploads.count==1}
            if replyStep>1{preservedUpload=uploads.count==1 && messages.contains{$0.imageOrigin=="tool"}}
            if replyStep==3{return .init(role:"assistant",content:.string("Two actual plots"))}
            return .init(role:"assistant",tool_calls:[.init(id:"visual-\(replyStep)",type:"function",function:.init(name:"run_simulation",arguments:"{}"))])
        },access:{CircuitAIConfiguration(endpoint:"https://example.invalid/",accessToken:"test-only-not-a-real-credential")})
        try visualChat.activate(context);visualChat.attach(normalized)
        var plotStep=0
        visualChat.send("Plot AC and transient",snapshot:{context},execute:{_,_,stamp in plotStep+=1;let f=plotStep==1 ? acFigure:transientFigure;return .init(content:"{}",image:"data:image/png;base64,"+f.png.base64EncodedString(),stamp:stamp,figure:f)})
        for _ in 0..<1000{if !visualChat.sending{break};try await Task.sleep(for:.milliseconds(5))}
        try check("User image survives tool image updates",sawUpload && preservedUpload && visualChat.error==nil)
        try check("Final assistant reply carries both simulation figures",visualChat.messages.last?.figures.count==2 && visualChat.messages.last?.role=="assistant")
        let blank = EditorStore(CircuitFile().circuit)
        try check("New document starts blank", blank.circuit.objectIDs.isEmpty && blank.circuit.purpose == .schematic)
        blank.setPurpose(.illustration)
        try check("Illustration has drawing tools only", !blank.supportsSimulation && !blank.availableTools.contains(.wire) && !blank.availableTools.contains(.probe))
        blank.activateTool(.wire)
        try check("Wire shortcut draws illustration connector", blank.tool == .connector)
        blank.activateTool(.label); blank.pointerDown(Point(100, 100))
        try check("Illustration text is not an electrical label", blank.circuit.figures.first?.kind == .text && blank.circuit.labels.isEmpty)
        blank.undo(); blank.undo()
        try check("Undo mode restores schematic", blank.circuit.purpose == .schematic && blank.circuit.objectIDs.isEmpty)
        let original = PaperExample.system.make()
        let ota = original.figures[3], sample = original.figures[4], adc = original.figures[5]
        let editor = EditorStore(original); editor.zoom = 1; editor.offset = .zero
        editor.selection = [ota.id]
        editor.pointerDown(ota.position); editor.pointerDragged(ota.position + Point(60, 30)); editor.pointerUp(ota.position + Point(60, 30))
        try check("Drag shape and attached arrows", editor.circuit.figures[3].position == ota.position + Point(60, 30) && editor.circuit.resolvedPoints(editor.circuit.figureConnectors[1]).last == editor.circuit.figures[3].anchor("left"))
        let moved = editor.circuit
        editor.undo(); try check("Undo / redo move", editor.circuit == original)
        editor.redo(); try check("Redo restores move", editor.circuit == moved)
        let shape = editor.circuit.figures[3], corner = shape.world(Point(shape.size.x / 2, shape.size.y / 2))
        editor.pointerDown(corner); editor.pointerDragged(corner + Point(30, 20)); editor.pointerUp(corner + Point(30, 20))
        let fixed = shape.world(Point(-shape.size.x / 2, -shape.size.y / 2))
        let snappedEnd = (corner + Point(30, 20)).snapped()
        try check("Resize honors grid and preserves attached edge", editor.circuit.figures[3].size == snappedEnd - fixed && editor.circuit.resolvedPoints(editor.circuit.figureConnectors[1]).last == editor.circuit.figures[3].anchor("left"))
        editor.undo(); try check("Undo resize", editor.circuit == moved)
        let arrows = EditorStore(original); arrows.tool = .connector
        let start = ota.anchor("right")!, end = sample.anchor("left")!
        arrows.pointerDown(start); arrows.pointerDragged(end); arrows.pointerUp(end)
        let added = arrows.circuit.figureConnectors.last!
        try check("Draw arrow by dragging between edges", added.start == TerminalRef(ota.id, "right") && added.end == TerminalRef(sample.id, "left") && arrows.circuit.figureConnectors.count == original.figureConnectors.count + 1)
        arrows.cancel(); arrows.selection = [added.id]
        arrows.pointerDown(end); arrows.pointerDragged(adc.anchor("left")!); arrows.pointerUp(adc.anchor("left")!)
        try check("Reconnect arrow endpoint", arrows.circuit.figureConnectors.last!.end == TerminalRef(adc.id, "left"))
        arrows.undo(); try check("Undo endpoint change", arrows.circuit.figureConnectors.last!.end == TerminalRef(sample.id, "left"))
        let copied = EditorStore(original); copied.selection = Set(original.figures.map(\.id)); copied.duplicateSelection()
        let newIDs = Set(copied.circuit.figures.dropFirst(original.figures.count).map(\.id))
        try check("Duplicate remaps internal arrow references", copied.circuit.figureConnectors.count == original.figureConnectors.count * 2 && copied.circuit.figureConnectors.suffix(original.figureConnectors.count).allSatisfy { newIDs.contains($0.start!.componentID) && newIDs.contains($0.end!.componentID) })
        copied.undo(); try check("Undo duplicate", copied.circuit == original)
        let group = EditorStore(original); group.selection = original.objectIDs
        group.pointerDown(ota.position); group.pointerDragged(ota.position + Point(20, 10)); group.pointerUp(ota.position + Point(20, 10))
        try check("Move multiple shapes without detaching arrows", zip(group.circuit.figureConnectors, original.figureConnectors).allSatisfy { $0.start == $1.start && $0.end == $1.end } && group.circuit.figures[3].position == ota.position + Point(20, 10))
        var mixed = CircuitTemplate.commonSource.make(); mixed.figures = [ota]
        let rotated = EditorStore(mixed); rotated.selection = [mixed.components[0].id, ota.id]; rotated.transformSelection("Rotate"); rotated.undo()
        try check("Mixed selection rotation has one undo", rotated.circuit == mixed)
        var wired = Circuit()
        let a = wired.add(.resistor,at:Point(100,100)), b = wired.add(.capacitor,at:Point(260,100))
        wired.wires = [Wire(points:[Point(100,140),Point(180,140),Point(180,60),Point(260,60)],start:TerminalRef(a,"2"),end:TerminalRef(b,"1"))]
        let wireID = wired.wires[0].id
        let office = EditorStore(wired); office.offset = .zero; office.zoom = 1
        office.pointerDown(Point(55,45)); office.pointerDragged(Point(290,155)); office.pointerUp(Point(290,155))
        try check("Box selects components and electrical wires",office.selection == [a,b,wireID])
        let beforeMove = office.circuit
        office.pointerDown(Point(100,100)); office.pointerDragged(Point(140,130)); office.pointerUp(Point(140,130))
        try check("Group move translates internal wire bends",office.circuit.wires[0].points == beforeMove.wires[0].points.map { $0+Point(40,30) })
        office.undo(); try check("Group movement undoes atomically",office.circuit == beforeMove)
        office.transformSelection("Flip horizontal"); office.transformSelection("Flip horizontal")
        try check("Mirror twice restores pins and wire path",office.circuit == beforeMove)
        let wireOnly = EditorStore(wired); wireOnly.selection = [wireID]
        wireOnly.nudge(Point(10,0))
        try check("Nudging a wire detaches its outside pins",wireOnly.circuit.wires[0].start == nil && wireOnly.circuit.wires[0].end == nil)
        let bend = EditorStore(Circuit()); bend.tool = .wire
        bend.pointerDown(.zero); bend.pointerUp(.zero)
        bend.pointerDown(Point(100,0)); bend.pointerUp(Point(100,0)); bend.hover(Point(100,100)); bend.completeWire()
        try check("Wire click retains bends until Enter",bend.circuit.wires.count == 1 && bend.circuit.wires[0].points.first == .zero && bend.circuit.wires[0].points.last == Point(100,100) && bend.circuit.wires[0].points.contains(Point(100,0)))
        let placement = EditorStore(Circuit()); placement.insertKind = .resistor
        placement.pointerDown(Point(100,100)); placement.pointerUp(Point(100,100)); placement.pointerDown(Point(240,100)); placement.pointerUp(Point(240,100))
        try check("Component placement repeats until Escape",placement.circuit.components.count == 2 && placement.insertKind == .resistor)
        placement.cancel();try check("Escape exits repeat placement",placement.insertKind == nil)
        let labels = Symbols.componentLabels(placement.circuit.components[0],theme:.razavi)
        let name = labels.first { !$0.value }!.text.point+Point(3,5)
        let position = placement.circuit.components[0].position
        placement.pointerDown(name); placement.pointerDragged(name+Point(-80,-50)); placement.pointerUp(name+Point(-80,-50))
        try check("Dragging a reference changes its offset, not its device",placement.circuit.components[0].position == position && placement.circuit.components[0].nameOffset == Point(-80,-50) && placement.circuit.components[0].valueOffset == nil)
        placement.undo(); try check("Reference placement has document undo",placement.circuit.components[0].nameOffset == nil)
        let railEditor=EditorStore(Circuit());railEditor.zoom=1;railEditor.offset = .zero;railEditor.insertKind = .powerRail
        railEditor.pointerDown(Point(0,0));railEditor.pointerUp(Point(0,0));railEditor.hover(Point(240,35));railEditor.pointerDown(Point(240,35));railEditor.pointerUp(Point(240,35))
        try check("Power Rail is a two-click axis-constrained conductor, not a symbol",railEditor.circuit.components.isEmpty && railEditor.circuit.wires.first?.powerNet == "VDD" && railEditor.circuit.wires.first?.points == [.zero,Point(240,0)])
        try check("Power Rail placement repeats",railEditor.insertKind == .powerRail)
        railEditor.undo();try check("Rail creation undoes atomically",railEditor.circuit.wires.isEmpty);railEditor.redo()
        railEditor.cancel();let railID=railEditor.circuit.wires[0].id;railEditor.selection=[railID];let railPayload=railEditor.selectionData();let railCopy=EditorStore(Circuit());railCopy.paste(railPayload,displacement:Point(0,100))
        try check("Rail copy preserves conductor type and power net",railCopy.circuit.wires.first?.powerNet == "VDD" && railCopy.circuit.wires.first?.points == [Point(0,100),Point(240,100)])
        var tapped=Circuit();let device=tapped.add(.resistor,at:Point(40,40));let tapRail=tapped.addPowerRail(from:.zero,to:Point(200,0))!
        let tapEditor=EditorStore(tapped);tapEditor.selection=[device,tapRail];let tapCopy=EditorStore(Circuit());tapCopy.paste(tapEditor.selectionData(),displacement:Point(0,200))
        try check("Copied rail taps bind to the copied rail",tapCopy.circuit.wires.contains { $0.end?.componentID == tapCopy.circuit.wires.first(where:{ $0.powerNet != nil })?.id })
        let noConnect=EditorStore(Circuit());let markedDevice=noConnect.circuit.add(.resistor,at:Point(100,100));noConnect.zoom=1;noConnect.offset = .zero;noConnect.insertKind = .noConnect
        noConnect.pointerDown(Point(500,500));noConnect.pointerUp(Point(500,500));try check("NoConn cannot be dropped on blank canvas",noConnect.circuit.components.count == 1)
        let markedPin=noConnect.circuit.position(of:TerminalRef(markedDevice,"1"))!
        noConnect.pointerDown(markedPin);noConnect.pointerUp(markedPin)
        try check("NoConn declares one explicit pin",noConnect.circuit.components.last?.parameters["attachedPin"] == "1" && noConnect.circuit.components.last?.parameters["attachedComponent"] == markedDevice.uuidString)
        noConnect.selection=[markedDevice];noConnect.nudge(Point(40,0));try check("NoConn follows its device",noConnect.circuit.components.last?.position == markedPin+Point(40,0))
        let markedCopy=EditorStore(Circuit());markedCopy.paste(noConnect.selectionData());let copiedOwner=markedCopy.circuit.components.first { $0.kind == .resistor }!
        try check("NoConn copies with its owner and remaps the pin identity",markedCopy.circuit.components.last?.parameters["attachedComponent"] == copiedOwner.id.uuidString)
        noConnect.undo();noConnect.undo();try check("NoConn has document undo",noConnect.circuit.components.count == 1)
        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map { original in let item = NSPasteboardItem(); for type in original.types { if let data=original.data(forType:type) { item.setData(data,forType:type) } }; return item }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(previousItems) }
        office.selection = [a,b]; StudioClipboard.copySelection(office)
        try check("Ordinary Copy includes transparent PNG and editable payload",pasteboard.data(forType:.png) != nil && pasteboard.data(forType:.pdf) != nil && StudioClipboard.selectionData() != nil)
        let target = EditorStore(Circuit()); StudioClipboard.pasteSelection(target)
        try check("Paste keeps internal electrical pin references",target.circuit.components.count == 2 && target.circuit.wires.count == 1 && target.circuit.wires[0].start != nil && target.circuit.wires[0].end != nil)
        let isolated = EditorStore(wired); isolated.selection = [a]; StudioClipboard.copyAs(.png,store:isolated)
        let png = pasteboard.data(forType:.png)!
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData,nil)!,0,nil)!
        try check("Copy as PNG exports only selected objects",image.width == Int(ceil(wired.selected([a]).bounds.width*3)))
        let styled=EditorStore(wired);styled.selection=[a,b,wireID]
        styled.setSelectionAppearance { $0.color="2563eb";$0.fontScale=1.25 }
        try check("Appearance changes apply to a mixed selection",styled.circuit.components.allSatisfy { $0.appearance?.color == "2563eb" } && styled.circuit.wires[0].appearance?.color == "2563eb")
        styled.undo();try check("Appearance edits undo as one document operation",styled.circuit == wired)
        let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("circuitstudio-host-"+UUID().uuidString)
        let suite="com.circuitstudio.hostchecks."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:scratch) }
        let host=EngineeringFiles(directory:scratch,defaults:defaults)
        let ticket=try host.handle("clipboard-prepare",payload:["text":"owned-test-selection"])["ticket"] as! Int
        _=try host.handle("clipboard",payload:["text":"owned-test-selection","png":png.base64EncodedString(),"ticket":ticket])
        try check("Engineering native copy writes PNG and editable content atomically",pasteboard.data(forType:.png) != nil && pasteboard.string(forType:.string) == "owned-test-selection" && pasteboard.string(forType:NSPasteboard.PasteboardType("com.circuitstudio.engineering-selection")) != nil)
        let stale=try host.handle("clipboard-prepare",payload:["text":"owned-test-selection"])["ticket"] as! Int
        pasteboard.clearContents();pasteboard.setString("newer-owned-test-clipboard",forType:.string)
        var refused=false;do { _=try host.handle("clipboard",payload:["png":png.base64EncodedString(),"ticket":stale]) } catch { refused=true }
        try check("A late PNG never overwrites a newer clipboard",refused && pasteboard.string(forType:.string) == "newer-owned-test-clipboard")
        let definition:[String:Any] = ["symbol":["id":"owned-test-resistor","name":"Original resistor","pins":[["name":"1","at":["x":0,"y":-20]],["name":"2","at":["x":0,"y":20]]]]]
        let first=try host.handle("components",payload:["action":"save","body":["id":"owned-test-component","revision":0,"definition":definition]])["entry"] as! [String:Any]
        try check("Engineering component library saves actual source definitions",first["revision"] as? Int == 1)
        refused=false;do { _=try host.handle("components",payload:["action":"save","body":["id":"owned-test-component","revision":0,"definition":definition]]) } catch { refused=true }
        try check("Library revisions prevent overwriting a changed component",refused)
        _=try host.handle("components",payload:["action":"delete","body":["id":"owned-test-component","revision":1]])
        let deleted=try host.handle("components",payload:["action":"read","body":["id":"owned-test-component"]])["entry"] as! [String:Any]
        try check("Component deletion remains recoverable",deleted["status"] as? String == "deleted")
        _=try host.handle("components",payload:["action":"restore","body":["id":"owned-test-component","revision":2]])
        let restored=try EngineeringFiles(directory:scratch,defaults:defaults).handle("components",payload:["action":"list","body":[:]])["entries"] as! [[String:Any]]
        try check("Restored component library survives a new native host",restored[0]["status"] as? String == "shared" && restored[0]["revision"] as? Int == 3)
        var simulation=SimulationSettings();simulation.analysis = .op
        let workspace=EngineeringWorkspace()
        let run=try await workspace.runSimulation(payload:["source":["id":"owned-tools-check","name":"Global rail divider","netlist":"R1 VDD VOUT 10k\nR2 VOUT 0 10k"],"configuration":["settings":JSONSerialization.jsonObject(with:JSONEncoder().encode(simulation)),"models":"","supplies":"VDD=1.8\nVSS=0"]])
        try check("Simulation tools reach real ngspice and present its result",run["summary"] as? String == "Simulation complete" && abs((workspace.simulationOutput?.result.waveform("VOUT")?.values.first?.real ?? -1)-0.9) < 1e-8)
        workspace.simulationOutput=nil
        try workspace.showSimulationResult(id:"owned-tools-check")
        try check("Waveform results reopen for the correct project",workspace.simulationOutput?.source.id == "owned-tools-check")
        refused=false;do { try workspace.showSimulationResult(id:"different-project") } catch { refused=true }
        try check("Another project cannot display a stale waveform",refused)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/circuitstudio-editor-verification.json")
        let data = try JSONSerialization.data(withJSONObject: ["allPassed": true, "checks": checks], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output)
        print("\(checks.count) editor interaction checks passed")
    }
}
