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
        for width in [320,393,600,768,1440] {
            window.setContentSize(NSSize(width:width,height:850))
            try await Task.sleep(for:.milliseconds(150))
            let layout=try await js("""
                const {controller:c}=await import('./editor.mjs');
                if(c.app.library)await c.action('library');
                const controls=[...document.querySelectorAll('#tools>.icon')].map(e=>e.getBoundingClientRect());
                return controls.every(r=>r.left>=0&&r.right<=innerWidth&&r.bottom<document.querySelector('#statusbar').getBoundingClientRect().top&&(innerWidth>600||r.width>=44&&r.height>=44));
            """) as? Bool==true
            try check("Drawing controls fit and retain their touch targets at width \(width)",layout)
        }
        window.setContentSize(NSSize(width:393,height:850))
        try await Task.sleep(for:.milliseconds(150))
        try check("Compact library dismisses after choosing a device",(try await js("""
            const {controller:c}=await import('./editor.mjs');await c.action('show-library');
            document.querySelector('[data-place=resistor]').click();
            return document.querySelector('#library').hidden&&document.querySelector('#library-toggle').getAttribute('aria-expanded')==='false';
        """)) as? Bool==true)
        try check("Keyboard tab navigation activates and focuses the previous document",(try await js("""
            const {controller:c}=await import('./editor.mjs');c.createTab();
            document.querySelector('[role=tab][aria-selected=true]').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true}));
            return c.app.active===0&&document.activeElement?.getAttribute('aria-selected')==='true';
        """)) as? Bool==true)
        window.setContentSize(NSSize(width:1440,height:900))
        try await Task.sleep(for:.milliseconds(150))
        _=try await js("const {controller:c}=await import('./editor.mjs');await c.action('select');await c.action('show-library')")
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
        try check("Selection copies SVG vector data and editable circuit data atomically",NSPasteboard.general.data(forType:NSPasteboard.PasteboardType("public.svg-image")) != nil && NSPasteboard.general.string(forType:NSPasteboard.PasteboardType("com.circuitstudio.engineering-selection"))?.contains("circuitstudio-selection-v1")==true && NSPasteboard.general.string(forType:.string)==nil && NSPasteboard.general.data(forType:.png) == nil)
        let placementChecks=try await js("""
          const {controller:c}=await import('./editor.mjs');const previous=c.app.active,selection=new Set(c.app.selected);c.createTab();
          const canvas=document.getElementById('canvas');
          await c.action('text');canvas.dispatchEvent(new PointerEvent('pointermove',{clientX:500,clientY:300,bubbles:true}));
          const textCrosshair=canvas.classList.contains('placing-crosshair')&&!!document.querySelector('.placement-crosshair');
          document.querySelector('[data-place="rectangle"]').click();canvas.dispatchEvent(new PointerEvent('pointermove',{clientX:520,clientY:320,bubbles:true}));
          const shapeCrosshair=!!document.querySelector('.placement-crosshair')&&!document.querySelector('#interaction g');
          document.activeElement?.blur();canvas.dispatchEvent(new KeyboardEvent('keydown',{key:'p',bubbles:true}));
          const shortcut=c.app.pendingType==='cell-pin';c.place('cell-pin',{x:0,y:0});
          const pin=c.cell().components.at(-1),nameEmpty=pin.parameters.name===''&&c.cell().ports.length===0;
          const net=await import('./model.mjs');const names=net.resolveNets(c.cell());
          const {labelPositions}=await import('./renderer.mjs');const unlabeled=!labelPositions(c.cell())[pin.id+':reference'];
          const {figureBetween}=await import('./editing.mjs'),{polarityEndpoints,transformPoint}=await import('./symbols.mjs');
          const directions=[{x:100,y:0},{x:-100,y:0},{x:0,y:100},{x:0,y:-100},{x:80,y:80},{x:-80,y:80},{x:80,y:-80},{x:-80,y:-80}];
          const polarities=directions.map((d,i)=>{const start={x:(i%4)*220,y:Math.floor(i/4)*220},end={x:start.x+d.x,y:start.y+d.y},part=figureBetween('polarity',start,end);const signs=polarityEndpoints(part.parameters);return {part,start,end,plus:transformPoint(part,signs.plus),minus:transformPoint(part,signs.minus)};});
          const near=(a,b)=>Math.hypot(a.x-b.x,a.y-b.y)<1e-6,positiveFirst=polarities.every(p=>near(p.plus,p.start)&&near(p.minus,p.end));
          c.cell().components=polarities.map(p=>p.part);c.app.pendingType=null;c.app.tool='select';c.render();c.fit();
          const horizontal=[...document.querySelectorAll('[data-polarity-end], [data-inline-parameter="text"]')].every(e=>{const m=e.getCTM();return Math.abs(m.b)<1e-6&&Math.abs(m.c)<1e-6&&m.a>0&&m.d>0;});
          const polarityImage=await circuitStudioImageData('png','current');
          c.app.active=previous;c.app.selected=selection;c.render();c.fit();return {textCrosshair,shapeCrosshair,shortcut,nameEmpty,unlabeled,positiveFirst,horizontal,polarityImage};
        """) as! [String:Any]
        for name in ["textCrosshair","shapeCrosshair","shortcut","nameEmpty","unlabeled","positiveFirst","horizontal"]{try check("Placement regression: "+name,placementChecks[name] as? Bool==true)}
        if let image=placementChecks["polarityImage"] as? [String:Any],let data=image["data"] as? String,let bytes=Data(base64Encoded:data){try bytes.write(to:output.appendingPathComponent("polarity-directions.png"))}
        let interactionChecks=try await js("""
          const {controller:c}=await import('./editor.mjs'),{polarityEndpoints,transformPoint}=await import('./symbols.mjs');
          const previous=c.app.active,selection=new Set(c.app.selected),frames=c.app.showTextFrames,frameSetting=localStorage.getItem('cs-text-frames');c.createTab();c.app.camera={x:0,y:0};c.app.zoom=1.4;c.render();
          const canvas=document.getElementById('canvas'),capture=canvas.setPointerCapture;
          // Synthetic events cannot request native pointer capture; real browser QA covers capture.
          canvas.setPointerCapture=()=>{};
          const pointer=(type,x,y,target=canvas)=>target.dispatchEvent(new PointerEvent(type,{clientX:x,clientY:y,button:0,pointerId:903,pointerType:'mouse',bubbles:true}));
          const near=(a,b)=>Math.hypot(a.x-b.x,a.y-b.y)<1e-6;
          let checks={};try{
            document.querySelector('[data-place="polarity"]').click();pointer('pointerdown',400,250);pointer('pointermove',401,251);pointer('pointerup',401,251);
            const firstClickWaits=c.cell().components.length===0&&!!c.app.figureDraft&&!document.querySelector('#interaction g'),start=c.app.figureDraft?.start;
            pointer('pointermove',800,500);pointer('pointerdown',800,500);pointer('pointerup',800,500);
            const part=c.cell().components.at(-1),ends=polarityEndpoints(part.parameters);
            const twoClicks=firstClickWaits&&c.cell().components.length===1&&!c.app.figureDraft&&near(transformPoint(part,ends.plus),start);
            document.querySelector('[data-place="rectangle"]').click();pointer('pointerdown',400,450);pointer('pointermove',600,650);pointer('pointerup',600,650);
            const dragging=c.cell().components.length===2&&c.cell().components.at(-1).type==='rectangle';
            pointer('pointerdown',400,350);pointer('pointerup',400,350);canvas.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
            const cancelSecondPoint=!c.app.figureDraft&&c.cell().components.length===2;
            await c.action('undo');const undone=c.cell().components.length===1;await c.action('redo');const undoRedo=undone&&c.cell().components.length===2;
            await c.action('text');pointer('pointerdown',433.25,333.75);pointer('pointerup',433.25,333.75);
            document.querySelector('#canvas-text-editor textarea').value='任意位置 V_{out}';c.finishTextEdit();
            const note=c.cell().notes.at(-1),freePosition=near(note.position,{x:433.25/1.4,y:333.75/1.4});
            c.app.showTextFrames=true;c.render();const frameVisible=!!document.querySelector('[data-text-frame]');
            const withFrame=await circuitStudioImageData('png','current'),svg=await circuitStudioImageData('svg','current');
            await c.action('text-frames');const frameHidden=!document.querySelector('[data-text-frame]');
            const withoutFrame=await circuitStudioImageData('png','current'),cleanCapture=withFrame.data===withoutFrame.data&&!atob(svg.data).includes('data-note-hit')&&!atob(svg.data).includes('data-text-frame');
            const hit=document.querySelector('[data-note-hit]'),old={...note.position};pointer('pointerdown',433.25,333.75,hit);pointer('pointermove',452.625,355.375);pointer('pointerup',452.625,355.375);
            const moved=c.cell().notes.find(n=>n.id===note.id),freeMove=near(moved.position,{x:old.x+19.375/1.4,y:old.y+21.625/1.4});
            checks={twoClicks,dragging,cancelSecondPoint,undoRedo,freePosition,frameVisible,frameHidden,cleanCapture,freeMove};
          }finally{canvas.setPointerCapture=capture;c.app.showTextFrames=frames;if(frameSetting===null)localStorage.removeItem('cs-text-frames');else localStorage.setItem('cs-text-frames',frameSetting);c.app.active=previous;c.app.selected=selection;c.render();c.fit();}
          return checks;
        """) as! [String:Any]
        for name in ["twoClicks","dragging","cancelSecondPoint","undoRedo","freePosition","frameVisible","frameHidden","cleanCapture","freeMove"]{try check("Click and text frame regression: "+name,interactionChecks[name] as? Bool==true)}
        let styleChecks=try await js("""
          const {controller:c}=await import('./editor.mjs'),{makeComponent,connectPins,uid,resolveNets,netlist}=await import('./model.mjs'),{importProject}=await import('./importer.mjs');
          const previous=c.app.active,selection=new Set(c.app.selected);c.createTab();let result;
          try{
            const cell=c.cell(),a=makeComponent('resistor',-120,-60,'R1'),b=makeComponent('capacitor',180,-60,'C1'),shape=makeComponent('rectangle',40,120,'',{width:'140',height:'60'}),note={id:uid(),text:'输出 V_{out}',position:{x:-160,y:210},size:20};
            cell.components.push(a,b,shape);connectPins(cell,[{instanceId:a.id,pinName:'1'},{instanceId:b.id,pinName:'1'}]);cell.notes.push(note);const wireID=cell.wires[0].id;
            const netBefore=netlist(c.current().store.project),ids=new Set([a.id,shape.id,wireID,note.id]);c.select([...ids]);c.fit();
            const field=document.getElementById('selection-color-hex');field.value='#2255cc';field.dispatchEvent(new Event('change',{bubbles:true}));
            const line=document.getElementById('selection-line-style');line.value='dashed';line.dispatchEvent(new Event('change',{bubbles:true}));
            const objects=[...c.cell().components,...c.cell().wires,...c.cell().notes].filter(o=>ids.has(o.id)),selectedColor=objects.every(o=>o.color==='#2255cc');
            const component=document.querySelector('g[data-component="'+a.id+'"]'),stroke=component.querySelector('path,polyline,line');
            const dashedStrokes=getComputedStyle(stroke).strokeDasharray.includes('7')&&getComputedStyle(stroke).strokeDasharray.includes('5');
            const colorsWhileSelected=component.getAttribute('color')==='#2255cc'&&document.querySelector('path[data-wire="'+wireID+'"]').getAttribute('stroke')==='#2255cc';
            const netlistUnchanged=netlist(c.current().store.project)===netBefore;
            await c.action('undo');const reverted=c.cell().wires[0].lineStyle!=='dashed';await c.action('redo');const oneUndoRedo=reverted&&c.cell().wires[0].lineStyle==='dashed';
            const revision=c.current().store.project.revision,same=document.getElementById('selection-color-hex');same.value='#2255cc';same.dispatchEvent(new Event('change',{bubbles:true}));const noDuplicateUndo=revision===c.current().store.project.revision;
            c.select([wireID]);await c.action('properties');document.getElementById('object-color').value='#33cc77';document.getElementById('object-line-style').value='solid';document.getElementById('object-form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
            const singleWireStyle=c.cell().wires[0].color==='#33cc77'&&c.cell().wires[0].lineStyle==='solid'&&netlist(c.current().store.project)===netBefore&&!c.cell().wires[0].netName;
            c.beginTextEdit({note:c.cell().notes.find(n=>n.id===note.id)});let textColorField=document.querySelector('#canvas-text-editor [name="textColor"]');textColorField.value='#d02d55';textColorField.dispatchEvent(new Event('input',{bubbles:true}));c.finishTextEdit();
            const textColor=c.cell().notes.find(n=>n.id===note.id).color==='#d02d55'&&document.querySelector('text[data-note="'+note.id+'"]').getAttribute('fill')==='#d02d55';
            c.beginTextEdit({part:c.cell().components.find(p=>p.id===a.id),label:'reference'});textColorField=document.querySelector('#canvas-text-editor [name="textColor"]');textColorField.value='#8b32bb';textColorField.dispatchEvent(new Event('input',{bubbles:true}));c.finishTextEdit();
            const labelColor=c.cell().components.find(p=>p.id===a.id).color==='#2255cc'&&document.querySelector('[data-label-instance="'+a.id+'"][data-label="reference"]').getAttribute('fill')==='#8b32bb'&&document.querySelector('[data-label-instance="'+a.id+'"][data-label="value"]').getAttribute('fill')==='#2255cc';
            const reopened=importProject(JSON.stringify(c.current().store.project)).cells[0],roundTrip=reopened.components.find(p=>p.id===a.id).referenceColor==='#8b32bb'&&reopened.wires[0].color==='#33cc77'&&reopened.notes[0].color==='#d02d55';
            const svg=await circuitStudioImageData('svg','current'),markup=atob(svg.data),exportStyles=markup.includes('#2255cc')&&markup.includes('#33cc77')&&markup.includes('#d02d55')&&markup.includes('#8b32bb')&&markup.includes('stroke-dasharray="7 5"')&&!markup.includes('data-selection="true"');
            const png=await circuitStudioImageData('png','current');c.select([...ids]);await c.copySelection();await c.pasteSelection();const copied=c.cell().components.at(-2),clipboardStyle=copied.color==='#2255cc'&&copied.referenceColor==='#8b32bb'&&copied.lineStyle==='dashed'&&c.cell().wires.at(-1).color==='#33cc77'&&c.cell().notes.at(-1).color==='#d02d55';
            result={selectedColor,dashedStrokes,colorsWhileSelected,netlistUnchanged,oneUndoRedo,noDuplicateUndo,singleWireStyle,textColor,labelColor,roundTrip,exportStyles,clipboardStyle,png,svg};
          }finally{c.app.active=previous;c.app.selected=selection;c.render();c.fit();await c.copySelection();}
          return result;
        """) as! [String:Any]
        for name in ["selectedColor","dashedStrokes","colorsWhileSelected","netlistUnchanged","oneUndoRedo","noDuplicateUndo","singleWireStyle","textColor","labelColor","roundTrip","exportStyles","clipboardStyle"]{try check("Selection style regression: "+name,styleChecks[name] as? Bool==true)}
        for format in ["png","svg"]{if let image=styleChecks[format] as? [String:Any],let data=image["data"] as? String,let bytes=Data(base64Encoded:data){try bytes.write(to:output.appendingPathComponent("selection-styles."+format))}}
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
