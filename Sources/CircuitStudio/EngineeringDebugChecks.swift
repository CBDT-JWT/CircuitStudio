#if DEBUG && os(iOS)
import SwiftUI
import WebKit

/// Simulator-only acceptance of the actual iPad host, file format and solver.
extension EngineeringWorkspace {
    func runIndependentDebugChecks() async {
        guard ProcessInfo.processInfo.arguments.contains("--verify-independent") else{return}
        let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("IndependentAcceptance")
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            var ready=false
            for _ in 0..<200 {
                ready=(try? await webView?.evaluateJavaScript("typeof window.circuitStudioLoadCourseCase==='function'")) as? Bool==true
                if ready{break};try await Task.sleep(for:.milliseconds(100))
            }
            guard ready,let webView else{throw CircuitError.message("Independent editor did not load")}
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
                        const parts=[...document.querySelectorAll('[data-component]')].map(e=>e.getBoundingClientRect());
                        return {width:innerWidth,height:innerHeight,inset:c.app.drawer,visible:parts.length>0&&parts.every(b=>b.left>=0&&b.right<=innerWidth-c.app.drawer+8)};
                    """,arguments:[:],in:nil,contentWorld:.page) as! [String:Any]
                    guard layout["visible"] as? Bool==true else{throw CircuitError.message("iPad drawer obscured the circuit: "+name)}
                    layouts.append(layout.merging(["requestedOrientation":name,"actualOrientation":webView.bounds.width>webView.bounds.height ? "landscape":"portrait"],uniquingKeysWith:{$1}))
                    if let window=webView.window {
                        let image=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
                        try image.pngData()?.write(to:folder.appendingPathComponent(name+".png"))
                    }
                }
            }
            let value:[String:Any]=["status":"passed","sampleCount":result.result.axis.count,"engine":result.result.engine,"layouts":layouts]
            try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("results.json"))
        }catch{
            try? JSONSerialization.data(withJSONObject:["status":"failed","error":String(describing:error)],options:[.prettyPrinted]).write(to:folder.appendingPathComponent("results.json"))
        }
    }
}
#endif
