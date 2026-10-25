import SwiftUI
import WebKit

@main struct CircuitAIVerification {
    @MainActor static func main() async throws {
        _=NSApplication.shared
        let evidence=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
        let secret=FileHandle.standardInput.readDataToEndOfFile()
        let config=try JSONSerialization.jsonObject(with:secret) as! [String:String]
        let configuration=CircuitAIConfiguration(endpoint:config["endpoint"]!,accessToken:config["token"]!)
        let workspace=EngineeringWorkspace();workspace.start()
        for _ in 0..<100 { if workspace.url != nil { break };try await Task.sleep(for:.milliseconds(100)) }
        guard let url=workspace.url else { throw CircuitError.message("Asset server did not start") }
        let browser=EngineeringBrowser(workspace:workspace,url:url);let coordinator=browser.makeCoordinator()
        let wc=WKWebViewConfiguration();wc.userContentController.addScriptMessageHandler(coordinator,contentWorld:.page,name:"circuitStudio")
        let web=WKWebView(frame:NSRect(x:0,y:0,width:1280,height:800),configuration:wc);web.navigationDelegate=coordinator;web.uiDelegate=coordinator;workspace.webView=web
        web.load(URLRequest(url:url))
        var ready=false
        for _ in 0..<200 {
            ready=(try? await web.evaluateJavaScript("typeof window.circuitStudioAgent === 'function' && typeof window.circuitStudioLoadExample === 'function'")) as? Bool == true
            if ready { break };try await Task.sleep(for:.milliseconds(100))
        }
        guard ready else { throw CircuitError.message("Engineering editor did not load") }
        _=try await web.callAsyncJavaScript("return await window.circuitStudioLoadExample('rc')",arguments:[:],in:nil,contentWorld:.page)
        for _ in 0..<100 { if (try? await workspace.assistantSnapshot().contains("rc_lowpass"))==true { break };try await Task.sleep(for:.milliseconds(100)) }
        var context=try await workspace.assistantSnapshot();var stamp=try CircuitAIStamp.context(context)
        let layout=try await web.callAsyncJavaScript("""
          window.circuitStudioCloseTools();window.circuitStudioSetDrawerInset(0);await new Promise(resolve=>setTimeout(resolve,200));
          const canvas=document.querySelector('[data-testid="schematic-canvas"]');
          const before=canvas.getBoundingClientRect().width;
          window.circuitStudioCloseTools();window.circuitStudioSetDrawerInset(432);
          await new Promise(resolve=>setTimeout(resolve,100));
          const after=canvas.getBoundingClientRect();
          const parts=[...document.querySelectorAll('[data-canvas-hit-kind="instance"]')].map(x=>x.getBoundingClientRect()).filter(r=>r.width+r.height>0);
          const clear=parts.length>0 && parts.every(r=>r.right<=innerWidth-432+2 && r.left>=after.left-2);
          const reserved=document.getElementById('cs-native-drawer-inset').getBoundingClientRect().width;
          const column=document.querySelector('.editor-right-dock');
          window.circuitStudioSetDrawerInset(0);
          return {before,after:after.width,canvasKeptWidth:Math.abs(after.width-before)<1,allComponentsVisible:clear,inset:reserved,propertiesHaveNoColumn:getComputedStyle(column).display==='contents'};
        """,arguments:[:],in:nil,contentWorld:.page) as! [String:Any]
        guard layout["canvasKeptWidth"] as? Bool==true,layout["allComponentsVisible"] as? Bool==true,layout["propertiesHaveNoColumn"] as? Bool==true,layout["inset"] as? Double==432 else {throw CircuitError.message("Floating drawer layout failed: "+String(describing:layout))}
        try JSONSerialization.data(withJSONObject:layout,options:[.prettyPrinted,.sortedKeys]).write(to:evidence.appendingPathComponent("floating-drawer-layout.json"))
        await workspace.refreshSimulationDraft()
        guard workspace.simulationDraft.projectID==stamp.projectID else{throw CircuitError.message("Native drawer did not load the active project's settings")}
        workspace.simulationDraft.value.settings.analysis = .ac
        workspace.simulationDraft.value.settings.start="10";workspace.simulationDraft.value.settings.stop="1Meg";workspace.simulationDraft.value.settings.points=20;workspace.simulationDraft.value.settings.probes=["in","out"]
        try await workspace.saveSimulationDraft(workspace.simulationDraft.value,projectID:stamp.projectID)
        await workspace.refreshSimulationDraft()
        guard workspace.simulationDraft.value.settings.points==20 else{throw CircuitError.message("Native drawer settings did not persist")}
        await workspace.runDrawerSimulation()
        guard workspace.simulationDraft.error==nil,workspace.simulationResult(id:stamp.projectID)?.result.axis.count==101 else{throw CircuitError.message("Native drawer actual simulation failed: "+(workspace.simulationDraft.error ?? "no result"))}
        var wrongProjectRejected=false
        do {try await workspace.saveSimulationDraft(workspace.simulationDraft.value,projectID:"different-project")}catch{wrongProjectRejected=true}
        guard wrongProjectRejected else{throw CircuitError.message("Native drawer overwrote a different project")}

        for format in ["svg","png"] {
            let image=try await web.callAsyncJavaScript("return await window.circuitStudioImageData(format,'virtuoso')",arguments:["format":format],in:nil,contentWorld:.page) as! [String:Any]
            guard let bytes=Data(base64Encoded:image["data"] as! String),bytes.count>500 else{throw CircuitError.message("Empty Virtuoso export")}
            if format=="svg" {let svg=String(decoding:bytes,as:UTF8.self);guard svg.contains("#00d9df"),svg.contains("#40ff60"),svg.contains("#050505") else{throw CircuitError.message("Screenshot palette missing")}}
            try bytes.write(to:evidence.appendingPathComponent("virtuoso-circuit."+format))
        }
        let originalProbes=workspace.simulationDraft.value.settings.probes
        let selected=try await web.callAsyncJavaScript("""
          window.circuitStudioPickProbes(true);
          const route=document.querySelector('[data-testid^="route-hit-"]');
          route.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0}));
          await new Promise(resolve=>setTimeout(resolve,100));
          return document.querySelectorAll('.cs-probe-selected').length;
        """,arguments:[:],in:nil,contentWorld:.page) as! Int
        guard workspace.simulationDraft.value.settings.probes != originalProbes else{throw CircuitError.message("Graph probe pick did not update native settings")}
        _=try await web.callAsyncJavaScript("document.querySelector('[data-testid^=\"route-hit-\"]').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0}));await new Promise(resolve=>setTimeout(resolve,100));window.circuitStudioPickProbes(false);",arguments:[:],in:nil,contentWorld:.page)
        guard Set(workspace.simulationDraft.value.settings.probes)==Set(originalProbes) else{throw CircuitError.message("Second graph pick did not toggle the probe")}
        try JSONSerialization.data(withJSONObject:["graphPickToggled":true,"highlightedRoutesAfterFirstPick":selected,"svgAndPNG":true]).write(to:evidence.appendingPathComponent("graph-probe-and-export.json"))
        if CommandLine.arguments.contains("--layout-only"){print("Floating drawer geometry, native settings persistence, project isolation and actual ngspice solve passed.");exit(0)}
        var tools:[String]=[];var wire=[CircuitAIMessage(role:"user",content:.string("请先查看电路图，再把 R1 的电阻改成 20k，其他元件保持不变。运行 AC 扫描 10 Hz 到 1Meg Hz，每十倍频 20 点，观测 in 和 out。读取实际波形图和数值，然后用 Markdown 标题和表格简洁报告结果。无需询问确认。"))]
        var answer="";var images=0
        for _ in 0..<8 {
            let message=try await CircuitAIService.agent(context:context,messages:wire,configuration:configuration);wire.append(message)
            guard let call=message.tool_calls?.first else { answer=message.content?.string ?? "";break }
            guard call.function.name != "ask_user" else { throw CircuitError.message("Unexpected clarification for explicit RC request") }
            let result=try await workspace.agentTool(call.function.name,arguments:call.function.arguments,stamp:stamp);stamp=result.stamp;tools.append(call.function.name)
            wire.append(.init(role:"tool",content:.string(result.content),tool_call_id:call.id))
            if let image=result.image {
                images+=1
                wire.removeAll { if case .array?=$0.content { return $0.role=="user" };return false }
                let parts:[CircuitAIJSON]=[.object(["type":.string("text"),"text":.string("实际工具图形，请结合数值和连接读取。")]),.object(["type":.string("image_url"),"image_url":.object(["url":.string(image)])])]
                wire.append(.init(role:"user",content:.array(parts)))
                if let bytes=Data(base64Encoded:String(image.split(separator:",",maxSplits:1)[1])) { try bytes.write(to:evidence.appendingPathComponent("tool-image-\(images).png")) }
            }
            context=try await workspace.assistantSnapshot()
        }
        guard tools.contains("edit_components"),tools.contains("run_simulation"),!answer.isEmpty,let output=workspace.simulationResult(id:stamp.projectID),output.source.netlist.contains("R1 in out 20k") else { throw CircuitError.message("RC tool loop did not finish") }
        try Data(answer.utf8).write(to:evidence.appendingPathComponent("answer.md"))
        let outputTrace=output.result.waveform("out")!;let sample=output.result.axis.enumerated().min(by:{abs($0.element-1000)<abs($1.element-1000)})!.offset
        let expected=Complex(1)/Complex(1,2*Double.pi*output.result.axis[sample]*2e-4)
        guard abs(outputTrace.values[sample].real-expected.real)<1e-6 else { throw CircuitError.message("Actual RC solve mismatch") }
        // Exercise real provider planning for multiple immutable analyses and styled figures.
        var figureWire=[CircuitAIMessage(role:"user",content:.string("请对当前 RC 电路分别运行真实 AC 和 Transient 两种仿真，不修改电路。AC 从 10 到 1Meg Hz，每十倍频 20 点，观察 out，图标题 AC response，X 轴 Frequency (Hz)，Y 轴 Gain (dB)，图例 Output。Transient 步长 100n，时长 100u，观察 out，图标题 Transient response，X 轴 Time (s)，Y 轴 Output (V)，图例 Output。无论瞬态是否为平线，都使用实际结果。两次仿真各自返回图片，简短说明。不要询问。"))]
        var figures:[CircuitAIFigure]=[];var figureTools:[String]=[];var figureAnswer=""
        for _ in 0..<14 {
            let response=try await CircuitAIService.agent(context:context,messages:figureWire,configuration:configuration);figureWire.append(response)
            guard let call=response.tool_calls?.first else {figureAnswer=response.content?.string ?? "";break}
            guard call.function.name != "ask_user" else {throw CircuitError.message("Unexpected clarification for explicit multiple analyses")}
            let result=try await workspace.agentTool(call.function.name,arguments:call.function.arguments,stamp:stamp);stamp=result.stamp;figureTools.append(call.function.name)
            figureWire.append(.init(role:"tool",content:.string(result.content),tool_call_id:call.id))
            if let figure=result.figure {figures.removeAll{$0.id==figure.id};figures.append(figure);try figure.png.write(to:evidence.appendingPathComponent("multi-"+figure.output.result.analysis.rawValue+".png"))}
            if let image=result.image {
                figureWire.removeAll {if case .array?=$0.content{return $0.role=="user"};return false}
                figureWire.append(.init(role:"user",content:.array([.object(["type":.string("text"),"text":.string("实际工具图形。")]),.object(["type":.string("image_url"),"image_url":.object(["url":.string(image)])])])) )
            }
            context=try await workspace.assistantSnapshot()
        }
        guard Set(figures.map{$0.output.result.analysis.rawValue}).isSuperset(of:["AC analysis","Transient"]),!figureAnswer.isEmpty else {throw CircuitError.message("Multiple actual analyses did not finish")}
        let acFigure=figures.first{$0.output.result.analysis == .ac}!,tranFigure=figures.first{$0.output.result.analysis == .tran}!
        guard acFigure.id != tranFigure.id,acFigure.options.xLabel=="Frequency (Hz)",tranFigure.options.xLabel=="Time (s)",acFigure.options.legend?.values.contains("Output")==true else {throw CircuitError.message("Provider plot labels were not applied")}
        let restyleArguments=String(decoding:try JSONSerialization.data(withJSONObject:["resultId":acFigure.id,"plot":["title":"Restyled historical AC","xLabel":"Frequency / Hz","legend":["out":"Retained output"]]]),as:UTF8.self)
        let restyled=try await workspace.agentTool("configure_plot",arguments:restyleArguments,stamp:stamp)
        guard restyled.figure?.id==acFigure.id,restyled.figure?.output.result.axis==acFigure.output.result.axis,restyled.figure?.options.title=="Restyled historical AC",workspace.simulationResult(id:stamp.projectID)?.id==tranFigure.output.id else {throw CircuitError.message("Restyling reran or replaced the latest simulation")}
        try Data(figureAnswer.utf8).write(to:evidence.appendingPathComponent("multi-analysis-answer.md"))
        // The secret-to-the-prompt digits occur only in the uploaded fixture pixels.
        let fixture=NSImage(size:NSSize(width:800,height:300));fixture.lockFocus();NSColor.white.setFill();NSBezierPath(rect:NSRect(x:0,y:0,width:800,height:300)).fill()
        ("7429" as NSString).draw(at:NSPoint(x:180,y:80),withAttributes:[.font:NSFont.systemFont(ofSize:130,weight:.bold),.foregroundColor:NSColor.black]);fixture.unlockFocus()
        let attachment=try CircuitAIImageAttachment.read(fixture.tiffRepresentation!,name:"visual-fixture.jpg")
        let visionParts:[CircuitAIJSON]=[.object(["type":.string("text"),"text":.string("只返回附图里从左到右的四位数字。不读取、不修改当前电路，也不调用工具。")]),.object(["type":.string("image_url"),"image_url":.object(["url":.string(attachment.dataURL)])])]
        let visionReply=try await CircuitAIService.agent(context:context,messages:[.init(role:"user",content:.array(visionParts),imageOrigin:"attachment")],configuration:configuration)
        let visionAnswer=visionReply.content?.string ?? ""
        guard (visionReply.tool_calls ?? []).isEmpty,visionAnswer.contains("7429") else {throw CircuitError.message("Actual provider could not read uploaded image pixels: "+visionAnswer)}
        try attachment.data.write(to:evidence.appendingPathComponent("uploaded-visual-fixture.jpg"));try Data(visionAnswer.utf8).write(to:evidence.appendingPathComponent("vision-answer.md"))
        // Ask an intentionally under-specified request and require an actual card tool.
        var clarification=[CircuitAIMessage(role:"user",content:.string("帮我优化这个电路。"))];var card:CircuitAIQuestion?
        for _ in 0..<4 {
            let response=try await CircuitAIService.agent(context:context,messages:clarification,configuration:configuration);clarification.append(response)
            guard let call=response.tool_calls?.first else { break }
            if call.function.name=="ask_user" { card=try CircuitAIQuestion.decode(call.function.arguments);break }
            guard call.function.name=="inspect_circuit" else { throw CircuitError.message("Ambiguous request attempted a mutation") }
            let result=try await workspace.agentTool(call.function.name,arguments:call.function.arguments,stamp:stamp)
            clarification.append(.init(role:"tool",content:.string(result.content),tool_call_id:call.id))
        }
        guard let card else { throw CircuitError.message("Ambiguous request did not produce a question card") }
        func groundCount(_ value:String)throws->Int {
            let object=try JSONSerialization.jsonObject(with:Data(value.utf8)) as! [String:Any]
            let docs=object["documents"] as! [[String:Any]]
            return docs.flatMap{$0["instances"] as? [[String:Any]] ?? []}.filter{$0["symbolId"] as? String=="ground"}.count
        }
        let beforeGround=try groundCount(context)
        var powerWire=[CircuitAIMessage(role:"user",content:.string("请先查看电路。在当前单元左侧空白处 x=-160,y=0 放置一个真实接地符号，并从 x=-200,y=-80 到 x=-120,y=-80 画一条名为 VDD 的真实电源轨。二者暂时不要接入已有电路。不需要修改任何已有元件，也不需要仿真。直接使用工具完成。"))]
        var powerTools:[String]=[];var powerAnswer=""
        for _ in 0..<12 {
            let response=try await CircuitAIService.agent(context:context,messages:powerWire,configuration:configuration);powerWire.append(response)
            guard let call=response.tool_calls?.first else {powerAnswer=response.content?.string ?? "";break}
            guard ["inspect_circuit","add_component","add_power_rail"].contains(call.function.name) else {throw CircuitError.message("Unexpected power authoring tool: "+call.function.name)}
            let result=try await workspace.agentTool(call.function.name,arguments:call.function.arguments,stamp:stamp);stamp=result.stamp;powerTools.append(call.function.name)
            powerWire.append(.init(role:"tool",content:.string(result.content),tool_call_id:call.id))
            context=try await workspace.assistantSnapshot()
        }
        guard powerTools.contains("add_component"),powerTools.contains("add_power_rail"),try groundCount(context)==beforeGround+1,!powerAnswer.isEmpty else {throw CircuitError.message("Actual ground/rail authoring failed")}
        let inspection=try await workspace.agentTool("inspect_circuit",arguments:"{}",stamp:stamp)
        try Data(inspection.content.utf8).write(to:evidence.appendingPathComponent("power-tools-inspection.json"))
        try Data(powerAnswer.utf8).write(to:evidence.appendingPathComponent("power-answer.md"))
        let summary:[String:Any]=["tools":tools,"imagesSent":images,"actualSamples":output.result.axis.count,"nativeDrawerSettingsAndActualSolve":"passed","nativeDrawerProjectIsolation":"passed","actualEngine":output.result.engine,"editedNetlist":output.source.netlist,"complexRCCheck":"passed","clarificationQuestion":card.question,"clarificationOptions":card.options.map(\.label),"answerFile":"answer.md","multipleAnalysisTools":figureTools,"multipleAnalysisResultIds":figures.map(\.id),"editablePlotLabels":"passed","restyleWithoutSolve":"passed","uploadedImagePixels":"passed","powerAuthoringTools":powerTools,"additionalGroundMarkers":1,"powerAnswerFile":"power-answer.md"]
        try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:evidence.appendingPathComponent("results.json"))
        print("CircuitAI live server/editor test passed: \(tools.joined(separator:", ")); \(output.result.axis.count) real samples; question card returned.")
        withExtendedLifetime(coordinator) {}
        exit(0)
    }
}
