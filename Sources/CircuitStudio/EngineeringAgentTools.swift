import SwiftUI
import WebKit

extension EngineeringWorkspace {
    func agentTool(_ name:String,arguments:String,stamp:CircuitAIStamp) async throws -> CircuitAIToolResult {
        let allowed:Set<String>=["inspect_circuit","edit_components","add_component","add_power_rail","connect_pins","delete_components","undo_circuit_edit","apply_foundry_model","run_simulation","view_waveforms","configure_plot","list_simulations"]
        guard allowed.contains(name),arguments.utf8.count<=16_000,let args=try JSONSerialization.jsonObject(with:Data(arguments.utf8)) as? [String:Any],let webView else { throw CircuitError.message("不支持的 CircuitAI 操作。") }
        if name=="apply_foundry_model",args["process"] as? String != "gf180mcu" { throw CircuitError.message("此版本仅内置公开的 GF180MCU 3.3V TT MOS 模型。") }
        let current=try CircuitAIStamp.context(try await assistantSnapshot())
        guard current==stamp else { throw CircuitError.message("电路已改变，请重新读取电路后再操作。") }
        let expected=try JSONSerialization.jsonObject(with:JSONEncoder().encode(stamp))
        if name=="list_simulations" {
            let history=simulationHistory(projectID:stamp.projectID).map { output -> [String:Any] in
                ["resultId":output.id.uuidString,"name":output.source.name,"analysis":output.result.analysis.rawValue,"sampleCount":output.result.axis.count,"settings":(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(output.settings))) ?? [:],"title":figureOptions(output.id.uuidString).title ?? output.source.name]
            }
            return .init(content:String(decoding:try JSONSerialization.data(withJSONObject:["simulations":history]),as:UTF8.self),image:nil,stamp:stamp)
        }
        if ["run_simulation","view_waveforms","configure_plot"].contains(name) {
            let fields=Set(["analysis","probes","start","stop","points","source","dcStart","dcStop","dcStep","timeStep","duration","startSaving","supplies","useTeachingModels","plot","resultId"])
            guard Set(args.keys).isSubset(of:fields) else { throw CircuitError.message("仿真参数无效。") }
            var simulationArgs=args;simulationArgs.removeValue(forKey:"plot");simulationArgs.removeValue(forKey:"resultId")
            guard let payload=try await webView.callAsyncJavaScript("return await window.circuitStudioAgent('simulation_payload', args, expected)",arguments:["args":name=="run_simulation" ? simulationArgs:[:],"expected":expected],in:nil,contentWorld:.page) as? [String:Any] else { throw CircuitError.message("当前电路无法仿真。") }
            if name=="run_simulation" {
                _=try await runSimulation(payload:payload,present:false)
                if try CircuitAIStamp.context(try await assistantSnapshot())==stamp,let configuration=payload["configuration"] {
                    let value=try JSONDecoder().decode(EngineeringSimulationDraft.Value.self,from:JSONSerialization.data(withJSONObject:configuration))
                    try await saveSimulationDraft(value,projectID:stamp.projectID)
                    if simulationDraft.projectID==stamp.projectID{simulationDraft.value=value}
                }
            }
            let selected:EngineeringSimulationOutput?
            if let id=args["resultId"] as? String,name != "run_simulation" {selected=archivedResult(id,projectID:stamp.projectID)}else{selected=simulationResult(id:stamp.projectID)}
            guard let output=selected,let source=payload["source"] as? [String:Any] else { throw CircuitError.message("没有此工程的有效仿真记录，请先运行仿真或读取仿真列表。") }
            let historical=output.source.netlist != source["netlist"] as? String
            guard !historical || args["resultId"] != nil else {throw CircuitError.message("电路已改变，请先运行仿真；要查看历史结果，请指定其 resultId。")}
            guard try CircuitAIStamp.context(try await assistantSnapshot())==stamp else { throw CircuitError.message("仿真期间电路已改变，结果保留为历史记录。") }
            var result=output.result
            var options=figureOptions(output.id.uuidString)
            if let changes=args["plot"] as? [String:Any] {
                let old=try JSONSerialization.jsonObject(with:JSONEncoder().encode(options)) as! [String:Any]
                options=try JSONDecoder().decode(CircuitAIPlotOptions.self,from:JSONSerialization.data(withJSONObject:old.merging(changes,uniquingKeysWith:{$1})))
            }
            if let legend=options.legend {options.legend=Dictionary(legend.map {key,value in (result.waveforms.first{ $0.name.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare("V(\(key))") == .orderedSame }?.name ?? key,value)},uniquingKeysWith:{$1})}
            let figure=try CircuitAIPlotRenderer.figure(output,options:options);updateFigure(figure)
            if options.mode == .spectrum {result=try CircuitAIPlotRenderer.plottedResult(output,options:options)}
            let indices=circuitAISampleIndices(count:result.axis.count,limit:240)
            let traces=Array(result.waveforms.prefix(12)).map { trace -> [String:Any] in
                ["name":trace.name,"real":indices.map{trace.values.indices.contains($0) ? trace.values[$0].real:0},"imaginary":indices.map{trace.values.indices.contains($0) ? trace.values[$0].imaginary:0},"minimum":trace.values.map(\.real).min() ?? 0,"maximum":trace.values.map(\.real).max() ?? 0]
            }
            let body:[String:Any]=["status":"completed","resultId":figure.id,"historical":historical,"sourceAnalysis":output.result.analysis.rawValue,"analysis":result.analysis.rawValue,"engine":result.engine,"sampleCount":result.axis.count,"axisLabel":result.axisLabel,"sampledAxis":indices.map{result.axis[$0]},"traces":traces,"netlist":output.source.netlist,"plot":try JSONSerialization.jsonObject(with:JSONEncoder().encode(options)),"modelNotice":output.modelNotice ?? "使用工程已提供的模型；不保证其来源或工艺精度。","note":"Actual numeric samples; each run and figure retains its own immutable result. Plot styling does not rerun or alter the simulation."]
            try await webView.evaluateJavaScript("window.dispatchEvent(new Event('circuit-studio-simulation-finished'))")
            return .init(content:String(decoding:try JSONSerialization.data(withJSONObject:body),as:UTF8.self),image:"data:image/png;base64,"+figure.png.base64EncodedString(),stamp:stamp,figure:figure)
        }
        guard var value=try await webView.callAsyncJavaScript("return await window.circuitStudioAgent(name, args, expected)",arguments:["name":name=="apply_foundry_model" ? "apply_gf180" : name,"args":args,"expected":expected],in:nil,contentWorld:.page) as? [String:Any] else { throw CircuitError.message("编辑器未返回操作结果。") }
        let image=value.removeValue(forKey:"imageDataURL") as? String
        guard let next=value["stamp"],JSONSerialization.isValidJSONObject(next) else { throw CircuitError.message("操作结果缺少版本信息。") }
        let nextStamp=try JSONDecoder().decode(CircuitAIStamp.self,from:JSONSerialization.data(withJSONObject:next))
        if let receipt=value["receipt"] as? [String:Any],receipt["ok"] as? Bool != true {
            throw CircuitError.message(String(decoding:try JSONSerialization.data(withJSONObject:receipt),as:UTF8.self))
        }
        let data=try JSONSerialization.data(withJSONObject:value)
        guard data.count<=150_000,(image?.utf8.count ?? 0)<=2_000_000 else { throw CircuitError.message("电路图形或连接信息过大，请使用较小的单元。") }
        return .init(content:String(decoding:data,as:UTF8.self),image:image,stamp:nextStamp)
    }
}
