import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

@MainActor @Observable final class EngineeringSimulationDraft {
    struct Value:Codable,Equatable {
        var settings=SimulationSettings()
        var supplies="VDD=1.8\nVSS=0"
        var models=""
    }
    var value=Value()
    var projectID=""
    var loading=false
    var running=false
    var error:String?
    var pickingProbes=false
    var notice=""
}
extension EngineeringWorkspace {
    func refreshSimulationDraft() async {
        let draft=simulationDraft
        guard !draft.running else{return}
        draft.loading=true;draft.error=nil
        defer{draft.loading=false}
        do {
            let stamp=try CircuitAIStamp.context(try await assistantSnapshot())
            guard let value=try await webView?.callAsyncJavaScript("return window.circuitStudioSimulationConfiguration(id)",arguments:["id":stamp.projectID],in:nil,contentWorld:.page) else{throw CircuitError.message("无法读取仿真设置。")}
            let decoded=try JSONDecoder().decode(EngineeringSimulationDraft.Value.self,from:JSONSerialization.data(withJSONObject:value))
            guard try CircuitAIStamp.context(try await assistantSnapshot()).projectID==stamp.projectID else{return}
            draft.value=decoded;draft.projectID=stamp.projectID;draft.notice=""
        }catch{draft.error=error.localizedDescription}
    }
    func saveSimulationDraft(_ value:EngineeringSimulationDraft.Value,projectID:String) async throws {
        guard !projectID.isEmpty else{return}
        let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))
        _=try await webView?.callAsyncJavaScript("return window.circuitStudioSimulationConfiguration(id,configuration)",arguments:["id":projectID,"configuration":encoded],in:nil,contentWorld:.page)
    }
    func runDrawerSimulation() async {
        let draft=simulationDraft
        guard !draft.running else{return}
        do {
            let current=try CircuitAIStamp.context(try await assistantSnapshot())
            if draft.projectID != current.projectID {await refreshSimulationDraft()}
            guard draft.projectID==current.projectID else{throw CircuitError.message("请重新打开当前工程的仿真设置。")}
            draft.running=true;draft.error=nil
            defer{draft.running=false}
            try await saveSimulationDraft(draft.value,projectID:current.projectID)
            let expected=try JSONSerialization.jsonObject(with:JSONEncoder().encode(current))
            guard let payload=try await webView?.callAsyncJavaScript("return await window.circuitStudioAgent('simulation_payload',{},expected)",arguments:["expected":expected],in:nil,contentWorld:.page) as? [String:Any] else{throw CircuitError.message("当前电路无法仿真。")}
            _=try await runSimulation(payload:payload,present:false)
            guard try CircuitAIStamp.context(try await assistantSnapshot())==current else{throw CircuitError.message("电路已改变，此次结果已保留为历史记录，请重新仿真。")}
            if let config=payload["configuration"] {
                draft.value=try JSONDecoder().decode(EngineeringSimulationDraft.Value.self,from:JSONSerialization.data(withJSONObject:config))
                try await saveSimulationDraft(draft.value,projectID:current.projectID)
            }
            draft.notice="仿真完成，曲线来自本地 ngspice。"
        }catch{draft.error=(error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription}
    }
}
struct EngineeringSimulationDrawer:View {
    let workspace:EngineeringWorkspace
    @State private var importingModels=false
    @State private var figure:CircuitAIFigure?
    @State private var packets:[Packet]=[]
    @State private var personal:[[String:String]]=[]
    @State private var selected=""
    @State private var modelName=""
    struct Packet:Decodable,Identifiable {var id:String;var name:String;var process:String;var corner:String;var path:String;var notice:String;var sha256:String}
    var body:some View {
        @Bindable var draft=workspace.simulationDraft
        VStack(spacing:0) {
            HStack {VStack(alignment:.leading,spacing:3){Text("仿真").font(.headline);Text(workspace.chat.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)};Spacer();Image(systemName:"waveform.path").foregroundStyle(StudioStyle.accent)}.padding(18)
            if draft.loading {Spacer();ProgressView("读取仿真设置…");Spacer()}
            else {
                Form {
                    if let example=workspace.courseExamples[workspace.chat.projectID] {
                        Section("课程示例") {
                            Text(example.title).font(.callout.weight(.medium))
                            ForEach(example.runs.indices,id:\.self){i in Button(example.runs[i].title){draft.value.settings=example.runs[i].settings}}
                            Button("查看作业说明"){workspace.showCourseExamples=true}
                        }
                    }
                    Section("分析") {
                        Picker("类型",selection:$draft.value.settings.analysis) {Text("OP 工作点").tag(Analysis.op);Text("AC 交流分析").tag(Analysis.ac);Text("DC 直流扫描").tag(Analysis.dc);Text("TRAN 瞬态分析").tag(Analysis.tran)}
                        switch draft.value.settings.analysis {
                        case .op:Text("计算节点电压和支路电流。").font(.caption).foregroundStyle(.secondary)
                        case .ac:analysisField("起始频率 (Hz)",text:$draft.value.settings.start);analysisField("终止频率 (Hz)",text:$draft.value.settings.stop);analysisField("每十倍频点数",text:Binding(get:{String(draft.value.settings.points)},set:{if let value=Int($0){draft.value.settings.points=value}}))
                        case .dc:analysisField("扫描电源",text:$draft.value.settings.source);analysisField("起始电压",text:$draft.value.settings.dcStart);analysisField("终止电压",text:$draft.value.settings.dcStop);analysisField("步进",text:$draft.value.settings.dcStep)
                        case .tran:analysisField("时间步长 (s)",text:$draft.value.settings.timeStep);analysisField("仿真时长 (s)",text:$draft.value.settings.duration);analysisField("开始记录时间 (s)",text:Binding(get:{draft.value.settings.startSaving ?? "0"},set:{draft.value.settings.startSaving=$0}));Text("在此时间之前仍计算启动过程，之后记录波形。").font(.caption).foregroundStyle(.secondary)
                        }
                        analysisField("观测网络",text:Binding(get:{draft.value.settings.probes.joined(separator:", ")},set:{draft.value.settings.probes=$0.split(separator:",").map{String($0).trimmingCharacters(in:.whitespaces)}}))
                        Button(draft.pickingProbes ? "完成图中选择":"在图中选择观测网络") {
                            let enabled = !draft.pickingProbes
                            Task {do {_ = try await workspace.webView?.callAsyncJavaScript("window.circuitStudioPickProbes(enabled)",arguments:["enabled":enabled],in:nil,contentWorld:.page);draft.pickingProbes=enabled}catch{draft.error=(error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription}}
                        }.accessibilityIdentifier("pick-simulation-probes")
                        if draft.pickingProbes {Text("点击导线、网络标签或引脚，可连续选择；再点一次移除。Esc 完成。").font(.caption).foregroundStyle(StudioStyle.accent)}
                        Text("支持 10k、1u、100Meg；多个网络以英文逗号分隔。").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("全局电源") {
                        TextEditor(text:$draft.value.supplies).font(.system(.callout,design:.monospaced)).frame(height:54).accessibilityLabel("全局电源")
                        Text("同名电源轨共用电压，无需单独放置电压源。").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        DisclosureGroup("共享模型库") {
                            Picker("模型包",selection:$selected) {
                                Text("选择工艺和工艺角…").tag("")
                                ForEach(packets){p in Text(p.process+" · "+p.name+" · "+p.corner).tag(p.id)}
                                ForEach(personal,id:\.["id"]){entry in Text(entry["name"] ?? "个人模型").tag("mine:"+(entry["id"] ?? ""))}
                            }
                            Button("载入当前工程",action:loadModel).disabled(selected.isEmpty)
                            TextField("另存模型名称",text:$modelName)
                            Button("保存到我的模型库",action:saveModel).disabled(modelName.trimmingCharacters(in:.whitespaces).isEmpty || draft.value.models.isEmpty)
                            Text("载入模型包保留现有器件绑定；个人模型可跨工程使用。").font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("器件模型") {
                            TextEditor(text:$draft.value.models).font(.system(.caption,design:.monospaced)).frame(height:170).accessibilityLabel("器件模型")
                            Button("导入模型文件…",action:importModels)
                            Button("应用真实 GF180MCU 3.3V TT 模型") {Task {await applyGF180()}}
                            Text("GF180 会切换当前单元的 MOS 模型，并将过小的 L 调整到 280nm。电源不变，可撤销。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let figure {
                        Section("仿真曲线") {
                            CircuitAIFigureCard(figure:figure){updated in self.figure=updated;workspace.updateFigure(updated)}
                            if figure.output.result.analysis == .tran {
                                Button("FFT 频谱") {do{var options=figure.options;options.mode = .spectrum;options.title=figure.output.source.name+" · FFT";options.xLabel="Frequency (Hz)";options.yLabel="Amplitude (dB)";self.figure=try CircuitAIPlotRenderer.figure(figure.output,options:options)}catch{draft.error=error.localizedDescription}}
                                CircuitWaveformMeasurements(output:figure.output)
                            }
                            Button("展开波形") {do{try workspace.showSimulationResult(id:draft.projectID)}catch{draft.error=error.localizedDescription}}
                        }
                    }
                    if let error=draft.error {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
                    if !draft.notice.isEmpty {Text(draft.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
                }.formStyle(.grouped).textFieldStyle(.roundedBorder).disabled(draft.running)
            }
            Divider()
            Button {Task{await workspace.runDrawerSimulation()}} label:{HStack{if draft.running{ProgressView().controlSize(.small)};Text(draft.running ? "正在仿真…":"运行仿真");Spacer();Text("⌘↵").foregroundStyle(.secondary)}.padding(.vertical,5)}.buttonStyle(.borderedProminent).disabled(draft.loading || draft.running || draft.projectID != workspace.chat.projectID).padding(16)
        }
        .fileImporter(isPresented:$importingModels,allowedContentTypes:[.plainText,.data]){result in do{try appendModels(try result.get())}catch{draft.error=error.localizedDescription}}
        .task(id:workspace.chat.projectID) {await workspace.refreshSimulationDraft();refreshLibrary()}
        .task(id:draft.value) {
            let id=draft.projectID,value=draft.value
            do {try await Task.sleep(for:.milliseconds(250));try Task.checkCancellation();if !draft.loading,!id.isEmpty{try await workspace.saveSimulationDraft(value,projectID:id)}}catch is CancellationError {}catch{draft.error=error.localizedDescription}
        }
        .onDisappear {draft.pickingProbes=false;workspace.webView?.evaluateJavaScript("window.circuitStudioPickProbes?.(false)",completionHandler:nil);let value=draft.value,id=draft.projectID;Task{try? await workspace.saveSimulationDraft(value,projectID:id)}}
        .task(id:workspace.simulationResult(id:workspace.chat.projectID)?.id) {
            if let output=workspace.simulationResult(id:workspace.chat.projectID){figure=try? CircuitAIPlotRenderer.figure(output,options:workspace.figureOptions(output.id.uuidString))}else{figure=nil}
        }
    }
    @ViewBuilder private func analysisField(_ title:String,text:Binding<String>)->some View {
        #if os(iOS)
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title,text:text).textInputAutocapitalization(.never).autocorrectionDisabled()
        }.padding(.vertical,2)
        #else
        TextField(title,text:text)
        #endif
    }
    private func refreshLibrary() {
        do {
            if let url=Bundle.main.url(forResource:"EngineeringEditor",withExtension:nil)?.appendingPathComponent("pdk/catalog.json") {packets=try JSONDecoder().decode([Packet].self,from:Data(contentsOf:url))}
            personal=(try workspace.modelLibrary.handle(["operation":"list"])["entries"] as? [[String:String]]) ?? []
        }catch{workspace.simulationDraft.error=error.localizedDescription}
    }
    private func loadModel() {
        let draft=workspace.simulationDraft
        do {
            if selected.hasPrefix("mine:") {let value=try workspace.modelLibrary.handle(["operation":"read","id":String(selected.dropFirst(5))]);draft.value.models=value["text"] as? String ?? "";draft.notice="已载入个人模型。"}
            else {
                guard let packet=packets.first(where:{$0.id==selected}),let root=Bundle.main.url(forResource:"EngineeringEditor",withExtension:nil) else{throw CircuitError.message("请选择模型包。")}
                let data=try Data(contentsOf:root.appendingPathComponent("pdk/"+packet.path));let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
                guard digest==packet.sha256,let text=String(data:data,encoding:.utf8) else{throw CircuitError.message("模型文件校验失败。")}
                draft.value.models=text;draft.notice=packet.notice
            }
            draft.error=nil
        }catch{draft.error=error.localizedDescription}
    }
    private func saveModel() {
        do{_=try workspace.modelLibrary.handle(["operation":"save","name":modelName,"text":workspace.simulationDraft.value.models]);refreshLibrary();modelName="";workspace.simulationDraft.notice="已保存到我的模型库。"}catch{workspace.simulationDraft.error=error.localizedDescription}
    }
    private func importModels() {
        #if os(macOS)
        let panel=NSOpenPanel();panel.allowedContentTypes=[.plainText,.data];panel.canChooseDirectories=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do{try appendModels(url)}catch{workspace.simulationDraft.error=error.localizedDescription}
        #else
        importingModels=true
        #endif
    }
    private func appendModels(_ url:URL)throws {
        let scoped=url.startAccessingSecurityScopedResource();defer{if scoped{url.stopAccessingSecurityScopedResource()}}
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size<=6_000_000 else{throw CircuitError.message("模型文件需小于 6MB。")}
        let text=try String(contentsOf:url,encoding:.utf8);guard !text.contains("\0"),(workspace.simulationDraft.value.models+text).utf8.count<=6_000_000 else{throw CircuitError.message("模型内容无效或总量超过 6MB。")};workspace.simulationDraft.value.models+="\n"+text
    }
    private func applyGF180() async {
        do{let stamp=try CircuitAIStamp.context(try await workspace.assistantSnapshot());_=try await workspace.agentTool("apply_foundry_model",arguments:"{\"process\":\"gf180mcu\"}",stamp:stamp);await workspace.refreshSimulationDraft()}catch{workspace.simulationDraft.error=error.localizedDescription}
    }
}
