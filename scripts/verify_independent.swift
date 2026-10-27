import SwiftUI
import WebKit

/// Exercises the shipping WKWebView bridge and the real embedded solver.
@main struct IndependentEditorChecks {
    @MainActor static func main() async throws {
        _=NSApplication.shared
        let output=URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let workspace=EngineeringWorkspace();workspace.start()
        for _ in 0..<100 {if workspace.url != nil {break};try await Task.sleep(for:.milliseconds(100))}
        guard let url=workspace.url else{throw CircuitError.message("Asset server unavailable: "+(workspace.error ?? "timeout"))}
        let host=EngineeringBrowser(workspace:workspace,url:url),coordinator=host.makeCoordinator()
        let config=WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(coordinator,contentWorld:.page,name:"circuitStudio")
        let web=WKWebView(frame:NSRect(x:0,y:0,width:1440,height:900),configuration:config)
        web.navigationDelegate=coordinator;web.uiDelegate=coordinator;workspace.webView=web
        let window=NSWindow(contentRect:web.frame,styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Circuit Studio Independent QA";window.contentView=web;window.orderFront(nil)
        web.load(URLRequest(url:url))
        for _ in 0..<200 {if (try? await web.evaluateJavaScript("typeof circuitStudioAgent==='function'")) as? Bool==true{break};try await Task.sleep(for:.milliseconds(100))}
        func js(_ script:String,_ arguments:[String:Any]=[:]) async throws -> Any {try await web.callAsyncJavaScript(script,arguments:arguments,in:nil,contentWorld:.page) as Any}
        var checks:[String]=[]
        func check(_ name:String,_ condition:Bool)throws{guard condition else{throw CircuitError.message("Failed: "+name)};checks.append(name);print("PASS "+name);fflush(nil)}
        guard (try? await web.evaluateJavaScript("typeof circuitStudioAgent")) as? String=="function" else{throw CircuitError.message("Independent editor failed to load ES modules")}
        for _ in 0..<100 {if (try? await js("const {controller:c}=await import('./editor.mjs');return c.app.interactionReady===true")) as? Bool==true{break};try await Task.sleep(for:.milliseconds(50))}
        try check("Pointer and keyboard interaction module installs without syntax errors",(try await js("const {controller:c}=await import('./editor.mjs');return c.app.interactionReady===true")) as? Bool==true)
        let secondWorkspace=EngineeringWorkspace();secondWorkspace.start()
        for _ in 0..<100 {if secondWorkspace.url != nil || secondWorkspace.error != nil {break};try await Task.sleep(for:.milliseconds(100))}
        try check("A second workspace recovers an occupied loopback port",secondWorkspace.url != nil && secondWorkspace.url?.port != workspace.url?.port)
        for example in CircuitTemplate.allCases {
            let circuit=example.make(),data=try CircuitArchive(circuit).encoded()
            let package=output.appendingPathComponent("Legacy-"+example.rawValue+".circuit")
            try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
            try data.write(to:package.appendingPathComponent("document.json"))
            let opened=try workspace.files.openProject(package)
            try Data((opened["text"] as! String).utf8).write(to:output.appendingPathComponent("native-"+example.id+".json"))
            _=try await js("return circuitStudioOpenProjectResult(result)",["result":opened])
            let imported=try await js("""
              const {controller:c}=await import('./editor.mjs');
              const p=c.current().store.project;
              return {unbound:c.current().binding===null,legacy:p.importedFrom==='native-circuit',count:c.cell().components.filter(p=>!p.generatedGround).length,name:p.name};
            """) as! [String:Any]
            try check("Legacy package opens in the new editor: "+example.rawValue,imported["unbound"] as? Bool==true && imported["legacy"] as? Bool==true && imported["count"] as? Int==circuit.components.count && imported["name"] as? String==circuit.title)
            try check("Legacy source remains byte-for-byte unchanged: "+example.rawValue,try Data(contentsOf:package.appendingPathComponent("document.json"))==data)
            if example == .rcFilter {
                await workspace.refreshSimulationDraft();await workspace.runDrawerSimulation()
                let id=try CircuitAIStamp.context(try await workspace.assistantSnapshot()).projectID
                try check("Imported native RC runs a real simulation",workspace.simulationDraft.error==nil && (workspace.simulationResult(id:id)?.result.axis.count ?? 0)>100)
            }
        }
        _=try await js("return await circuitStudioLoadCourseCase('A2-18-rc-01',0)")
        let layout=try await js("""
          const {controller:c}=await import('./editor.mjs');
          circuitStudioSetDrawerInset(432);await new Promise(r=>setTimeout(r,250));c.fit();
          const boxes=[...document.querySelectorAll('[data-component]')].map(e=>e.getBoundingClientRect());
          return {clear:boxes.length>0&&boxes.every(b=>b.right<innerWidth-420&&b.left>250),count:document.querySelectorAll('#library-sections [data-place]').length};
        """) as! [String:Any]
        try check("Original inventory and floating drawer reserve the actual schematic",layout["clear"] as? Bool==true && layout["count"] as? Int==78)
        var stamp=try CircuitAIStamp.context(try await workspace.assistantSnapshot())
        let inspected=try await workspace.agentTool("inspect_circuit",arguments:"{}",stamp:stamp)
        try check("CircuitAI receives an actual schematic PNG",inspected.image?.hasPrefix("data:image/png;base64,")==true)
        await workspace.refreshSimulationDraft()
        workspace.simulationDraft.value.settings.analysis = .tran
        workspace.simulationDraft.value.settings.timeStep="10u";workspace.simulationDraft.value.settings.duration="10m";workspace.simulationDraft.value.settings.startSaving="0";workspace.simulationDraft.value.settings.probes=["IN","OUT"]
        try await workspace.saveSimulationDraft(workspace.simulationDraft.value,projectID:stamp.projectID)
        try Data((try await workspace.assistantSnapshot()).utf8).write(to:output.appendingPathComponent("context-before-run.json"))
        await workspace.runDrawerSimulation()
        try check("Native drawer executes real transient samples: "+(workspace.simulationDraft.error ?? "no error"),workspace.simulationDraft.error==nil && (workspace.simulationResult(id:stamp.projectID)?.result.axis.count ?? 0)>100)
        let probesBefore=workspace.simulationDraft.value.settings.probes
        _=try await js("""
          const {controller:c}=await import('./editor.mjs');circuitStudioPickProbes(true);
          const wire=document.querySelector('[data-wire]');c.pickProbe(wire);
        """)
        for _ in 0..<40 {if workspace.simulationDraft.value.settings.probes != probesBefore{break};try await Task.sleep(for:.milliseconds(50))}
        try check("Clicking a schematic wire updates native observed networks",workspace.simulationDraft.value.settings.probes != probesBefore)
        _=try await js("circuitStudioPickProbes(false)")
        let result=try await workspace.agentTool("run_simulation",arguments:#"{"analysis":"AC analysis","start":"10","stop":"1Meg","points":20,"probes":["OUT"],"plot":{"title":"RC response","xLabel":"Frequency (Hz)","yLabel":"Gain (dB)","legend":{"OUT":"Output"}}}"#,stamp:stamp)
        try check("CircuitAI returns a styled real waveform",result.figure != nil && result.image != nil && result.figure?.options.xLabel=="Frequency (Hz)")
        let history=try await workspace.agentTool("list_simulations",arguments:"{}",stamp:stamp)
        try check("Multiple simulation runs retain immutable results",workspace.simulationHistory(projectID:stamp.projectID).count==2 && history.content.contains("resultId"))
        if let image=result.figure?.png{try image.write(to:output.appendingPathComponent("actual-rc-waveform.png"))}
        for format in ["png","svg"]{
            let image=try await js("return await circuitStudioImageData(format,'virtuoso')",["format":format]) as! [String:Any]
            let bytes=Data(base64Encoded:image["data"] as! String)!
            try check("Actual Virtuoso appearance export "+format,bytes.count>500)
            try bytes.write(to:output.appendingPathComponent("virtuoso-rc."+format))
        }
        let roundtrip=try await js("""
          const {controller:c}=await import('./editor.mjs'),{importProject}=await import('./importer.mjs');
          const p=c.current().store.project;const saved=JSON.stringify({...p,simulationConfiguration:c.current().configuration});
          const reopened=importProject(saved);return {text:saved,same:reopened.cells[0].wires.length===p.cells[0].wires.length&&reopened.simulationConfiguration.settings.analysis==='AC analysis'};
        """) as! [String:Any]
        try check("Save and reopen retain topology and simulation settings",roundtrip["same"] as? Bool==true)
        try Data((roundtrip["text"] as! String).utf8).write(to:output.appendingPathComponent("RC-saved.circuitstudio.json"))
        _=try await js("""
          const {controller:c}=await import('./editor.mjs');c.select(c.cell().components.map(p=>p.id));await c.copySelection();
        """)
        try check("Selection copies a PNG and editable data atomically",NSPasteboard.general.data(forType:.png) != nil && NSPasteboard.general.string(forType:NSPasteboard.PasteboardType("com.circuitstudio.engineering-selection"))?.contains("circuitstudio-selection-v1")==true && NSPasteboard.general.string(forType:.string)==nil && NSPasteboard.general.data(forType:.tiff) != nil)
        let geometryChecks=try await js("""
          const {controller:c}=await import('./editor.mjs');
          const before=c.cell().wires.map(w=>w.points),count=c.cell().wires.length;await c.pasteSelection();
          const copied=c.cell().wires.slice(count);const stable=copied.every((w,i)=>JSON.stringify(w.points)===JSON.stringify(before[i].map(p=>({x:p.x+30,y:p.y+30}))));
          c.current().store.transact('QA move pasted objects',(_,cell)=>c.translateSelection(cell,c.app.selected,{x:40,y:20}));
          const moved=c.cell().wires.slice(count).every((w,i)=>JSON.stringify(w.points)===JSON.stringify(before[i].map(p=>({x:p.x+70,y:p.y+50}))));
          const grid=c.app.grid;circuitStudioEditorCommand('grid');const toggled=c.app.grid!==grid&&document.getElementById('grid-fill').style.display===(grid?'none':'');circuitStudioEditorCommand('grid');
          const {tightSVGDocument}=await import('./renderer.mjs');const svg=await tightSVGDocument(c.cell(),{selection:new Set(copied.map(w=>w.id)),transparent:true});
          const holder=document.createElement('div');holder.innerHTML=svg;document.body.append(holder);const root=holder.querySelector('svg'),v=root.viewBox.baseVal,b=root.querySelector('[data-export-artwork]').getBBox();const centered=Math.abs((v.x+v.width/2)-(b.x+b.width/2))<.1&&Math.abs((v.y+v.height/2)-(b.y+b.height/2))<.1;holder.remove();
          c.beginTextEdit({position:{x:0,y:0}});const field=document.querySelector('#canvas-text-editor textarea');field.value='输出 V_{out}';field.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,isComposing:true}));const composed=!!document.getElementById('canvas-text-editor');c.finishTextEdit();
          const note=c.cell().notes.at(-1);c.beginTextEdit({note});document.querySelector('#canvas-text-editor textarea').value='Cancelled';c.finishTextEdit(false);
          return {stable,moved,toggled,centered,composed,text:note.text,cancelled:c.cell().notes.at(-1).text==='输出 V_{out}'};
        """) as! [String:Any]
        for name in ["stable","moved","toggled","centered","composed","cancelled"]{try check("Editing regression: "+name,geometryChecks[name] as? Bool==true)}
        try check("Chinese inline text commits to the document",geometryChecks["text"] as? String=="输出 V_{out}")
        _=try await js("""
          const {controller:c}=await import('./editor.mjs');circuitStudioSetDrawerInset(0);c.fit();
        """)
        let image=try await web.takeSnapshot(configuration:nil)
        if let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]){try png.write(to:output.appendingPathComponent("independent-editor.png"))}
        _=try await js("return await circuitStudioLoadCourseCase('A1-06-bridge-01',0)")
        stamp=try CircuitAIStamp.context(try await workspace.assistantSnapshot())
        await workspace.refreshSimulationDraft();await workspace.runDrawerSimulation()
        try check("Bridge rectifier solves through the shipping bridge",workspace.simulationDraft.error==nil && (workspace.simulationResult(id:stamp.projectID)?.result.axis.count ?? 0)>100)
        let bridgeImage=try await web.takeSnapshot(configuration:nil)
        if let tiff=bridgeImage.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]){try png.write(to:output.appendingPathComponent("independent-bridge.png"))}
        try JSONSerialization.data(withJSONObject:["passed":checks.count,"checks":checks],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("results.json"))
        window.close();print("Evidence: "+output.path);exit(0)
    }
}
