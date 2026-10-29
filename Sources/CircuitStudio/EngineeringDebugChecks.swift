#if DEBUG && os(iOS)
import SwiftUI
import WebKit

/// Simulator-only acceptance of the actual iPad host, file format and solver.
extension EngineeringWorkspace {
    func runIndependentDebugChecks() async {
        let routing=ProcessInfo.processInfo.arguments.contains("--verify-routing")
        guard routing || ProcessInfo.processInfo.arguments.contains("--verify-independent") else{return}
        let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("IndependentAcceptance")
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            var ready=false
            for _ in 0..<200 {
                ready=(try? await webView?.evaluateJavaScript("typeof window.circuitStudioLoadCourseCase==='function'")) as? Bool==true
                if ready{break};try await Task.sleep(for:.milliseconds(100))
            }
            guard ready,let webView else{throw CircuitError.message("Independent editor did not load")}
            var routingChecks:[String]=[]
            if routing {
                let circuit=CircuitTemplate.rcFilter.make(),original=try CircuitArchive(circuit).encoded()
                let legacy=folder.appendingPathComponent("Legacy RC.circuit")
                try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true)
                try original.write(to:legacy.appendingPathComponent("document.json"))
                await openExternalProject(legacy)
                guard error==nil else{throw CircuitError.message(error!)}
                let legacyState=try await webView.callAsyncJavaScript("const {controller:c}=await import('./editor.mjs');return {imported:c.current().store.project.importedFrom==='native-circuit',unbound:c.current().binding===null,project:c.current().store.project}",arguments:[:],in:nil,contentWorld:.page) as! [String:Any]
                guard legacyState["imported"] as? Bool==true,legacyState["unbound"] as? Bool==true,try Data(contentsOf:legacy.appendingPathComponent("document.json"))==original else{throw CircuitError.message("Legacy input was not safely imported")}
                routingChecks.append("Files/Handoff URL handler imports .circuit in the new editor without overwriting it")
                let saved=folder.appendingPathComponent("RC.circuitstudio.json")
                try JSONSerialization.data(withJSONObject:legacyState["project"]!).write(to:saved)
                await openExternalProject(saved)
                let rebound=try await webView.callAsyncJavaScript("const {controller:c}=await import('./editor.mjs');return c.current().binding!==null&&c.current().savedRevision===c.current().store.project.revision",arguments:[:],in:nil,contentWorld:.page) as? Bool
                guard error==nil,rebound==true else{throw CircuitError.message("Saved engineering JSON did not reopen with its file binding")}
                routingChecks.append("Saved .circuitstudio.json reopens as a bound project instead of importing again")
                fileCommand("new")
                let blank=try await webView.callAsyncJavaScript("const {controller:c}=await import('./editor.mjs');return c.current().store.project.schema==='circuitstudio-project-v1'&&c.cell().components.length===0&&c.current().binding===null",arguments:[:],in:nil,contentWorld:.page) as? Bool
                guard blank==true else{throw CircuitError.message("New command did not use the engineering editor")}
                routingChecks.append("The shared New command creates an engineering project")
            }
            _=try await webView.callAsyncJavaScript("return await circuitStudioLoadCourseCase('A1-06-bridge-01',0)",arguments:[:],in:nil,contentWorld:.page)
            await refreshSimulationDraft();await runDrawerSimulation()
            let stamp=try CircuitAIStamp.context(try await assistantSnapshot())
            guard simulationDraft.error==nil,let result=simulationResult(id:stamp.projectID),result.result.axis.count>100 else{throw CircuitError.message(simulationDraft.error ?? "No native samples")}
            showDrawer=true;drawerTab = .simulation
            try await Task.sleep(for:.milliseconds(500))
            var layouts:[[String:Any]]=[]
            if let scene=webView.window?.windowScene {
                for (name,orientation) in [("landscape",UIInterfaceOrientationMask.landscapeRight),("portrait",UIInterfaceOrientationMask.portrait)] {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations:orientation))
                    try await Task.sleep(for:.milliseconds(1100))
                    let layout=try await webView.callAsyncJavaScript("""
                        const {controller:c}=await import('./editor.mjs');c.fit();
                        const {boundsFor}=await import('./model.mjs'),b=boundsFor(c.cell()),a=c.screen(b),z=c.screen({x:b.x+b.width,y:b.y+b.height});
                        const expectedBottom=innerWidth<=600?Math.min(500,Math.max(180,innerHeight*.62))+32:0;
                        return {width:innerWidth,height:innerHeight,inset:c.app.drawer,bottomInset:c.app.drawerBottom,expectedBottom,visible:a.x>=0&&z.x<=innerWidth-c.app.drawer+8&&a.y>=0&&z.y<=innerHeight-c.app.drawerBottom+8&&Math.abs(c.app.drawerBottom-expectedBottom)<2};
                    """,arguments:[:],in:nil,contentWorld:.page) as! [String:Any]
                    guard layout["visible"] as? Bool==true else{throw CircuitError.message("iPad drawer obscured the circuit: "+name)}
                    layouts.append(layout.merging(["requestedOrientation":name,"actualOrientation":webView.bounds.width>webView.bounds.height ? "landscape":"portrait"],uniquingKeysWith:{$1}))
                    if let window=webView.window {
                        let image=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
                        try image.pngData()?.write(to:folder.appendingPathComponent(name+".png"))
                    }
                }
            }
            let value:[String:Any]=["status":"passed","sampleCount":result.result.axis.count,"engine":result.result.engine,"layouts":layouts,"routingChecks":routingChecks]
            try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("results.json"))
        }catch{
            try? JSONSerialization.data(withJSONObject:["status":"failed","error":String(describing:error)],options:[.prettyPrinted]).write(to:folder.appendingPathComponent("results.json"))
        }
    }
}
#endif
