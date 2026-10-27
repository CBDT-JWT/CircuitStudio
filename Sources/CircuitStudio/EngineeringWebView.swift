import SwiftUI
import WebKit
import Network
import UniformTypeIdentifiers

/// Serves bundled immutable editor files only. Files, clipboard and accounts have no HTTP endpoint.
final class EngineeringAssetServer: @unchecked Sendable {
    private let root:URL
    private var listener:NWListener?
    private let queue=DispatchQueue(label:"com.circuitstudio.engineering-assets")
    init(root:URL,port:UInt16) { self.root=root.resolvingSymlinksInPath();self.port=port }
    private let port:UInt16
    deinit { listener?.cancel() }
    func start(_ completion:@escaping @Sendable (Result<URL,Error>)->Void) throws {
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port) ?? .any)
        let listener=try NWListener(using:parameters)
        self.listener=listener
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:if let port=listener?.port { completion(.success(URL(string:"http://127.0.0.1:\(port.rawValue)/")!)) }
            case .failed(let error):completion(.failure(error))
            default:break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel();return }
            connection.start(queue:self.queue);self.receive(connection,buffer:Data())
        }
        listener.start(queue:queue)
    }
    private func receive(_ connection:NWConnection,buffer:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] data,_,done,error in
            guard let self else { connection.cancel();return }
            var request=buffer;if let data { request.append(data) }
            guard request.count <= 16384,error == nil else { connection.cancel();return }
            if request.range(of:Data("\r\n\r\n".utf8)) != nil { self.respond(connection,request:request) }
            else if done { connection.cancel() }
            else { self.receive(connection,buffer:request) }
        }
    }
    private func respond(_ connection:NWConnection,request:Data) {
        let first=String(decoding:request,as:UTF8.self).components(separatedBy:"\r\n").first?.split(separator:" ") ?? []
        guard first.count >= 2, first[0] == "GET",let raw=String(first[1]).split(separator:"?",maxSplits:1).first,let path=String(raw).removingPercentEncoding else { send(connection,status:400,body:Data());return }
        let file=root.appendingPathComponent(path == "/" ? "index.html" : String(path.dropFirst())).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path+"/"),let data=try? Data(contentsOf:file) else { send(connection,status:404,body:Data());return }
        let mime:[String:String] = ["html":"text/html; charset=utf-8","js":"application/javascript","mjs":"application/javascript","css":"text/css","json":"application/json","wasm":"application/wasm","svg":"image/svg+xml","png":"image/png","woff2":"font/woff2","woff":"font/woff","ttf":"font/ttf","rnl":"application/octet-stream"]
        send(connection,status:200,body:data,mime:mime[file.pathExtension] ?? "application/octet-stream")
    }
    private func send(_ connection:NWConnection,status:Int,body:Data,mime:String="text/plain") {
        let csp="default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data: blob:; worker-src 'self' blob:; connect-src 'self' blob:; object-src 'none'; frame-ancestors 'none'"
        let headers="HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: \(csp)\r\nConnection: close\r\n\r\n"
        connection.send(content:Data(headers.utf8)+body,completion:.contentProcessed { _ in connection.cancel() })
    }
}
@MainActor @Observable final class EngineeringWorkspace {
    var url:URL?
    var error:String?
    var webView:WKWebView?
    enum DrawerTab:String,CaseIterable {case simulation="仿真",assistant="CircuitAI"}
    var showDrawer=false
    var showCourseExamples=false
    var courseExamples:[String:CircuitCourseCatalog.Example]=[:]
    var drawerTab=DrawerTab.simulation
    let simulationDraft=EngineeringSimulationDraft()
    let chat=EngineeringChat()
    var simulationOutput:EngineeringSimulationOutput?
    private var simulationResults:[String:EngineeringSimulationOutput]=[:]
    private var simulationArchive:[String:EngineeringSimulationOutput]=[:]
    private var plotOptions:[String:CircuitAIPlotOptions]=[:]
    private var simulationRunning=false
    let files=EngineeringFiles()
    let modelLibrary=EngineeringModelLibrary()
    private var server:EngineeringAssetServer?
    private var incomingProjects=Set<URL>()
    func openExternalProject(_ url:URL) async {
        guard incomingProjects.insert(url).inserted else{return}
        defer{incomingProjects.remove(url)}
        do {
            let result=try files.openProject(url)
            var ready=false
            for _ in 0..<200 {
                ready=(try? await webView?.evaluateJavaScript("typeof window.circuitStudioOpenProjectResult==='function'")) as? Bool == true
                if ready{break}
                try await Task.sleep(for:.milliseconds(100))
            }
            guard ready,let webView else{throw CircuitError.message("编辑器尚未准备好，请重新打开工程。")}
            _=try await webView.callAsyncJavaScript("return circuitStudioOpenProjectResult(result)",arguments:["result":result],in:nil,contentWorld:.page)
        } catch {self.error=(error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription}
    }
    func start() {
        guard server == nil else { return }
        guard let root=Bundle.main.url(forResource:"EngineeringEditor",withExtension:nil) else { error="The offline engineering editor is missing. Build Engineering/build.py first.";return }
        startAssetServer(root:root,port:UInt16(clamping:UserDefaults.standard.integer(forKey:"engineering-loopback-port")))
    }
    private func startAssetServer(root:URL,port:UInt16) {
        do {
            let server=EngineeringAssetServer(root:root,port:port);self.server=server
            try server.start { [weak self] result in Task { @MainActor in
                guard let self else{return}
                switch result {
                case .success(let url):UserDefaults.standard.set(url.port,forKey:"engineering-loopback-port");self.url=url
                case .failure(let error):
                    if port != 0,case NWError.posix(.EADDRINUSE)=error {self.startAssetServer(root:root,port:0)}
                    else {self.error=error.localizedDescription}
                }
            } }
        } catch { self.error=error.localizedDescription }
    }
    func fileCommand(_ command:String) {
        guard ["new","open","save","save-as"].contains(command) else{return}
        let literal=String(data:try! JSONSerialization.data(withJSONObject:command,options:.fragmentsAllowed),encoding:.utf8)!
        webView?.evaluateJavaScript("window.circuitStudioFileCommand?.(\(literal))",completionHandler:nil)
    }
    func editorCommand(_ command:String) {
        Task {do{_ = try await webView?.callAsyncJavaScript("return await window.circuitStudioEditorCommand(command)",arguments:["command":command],in:nil,contentWorld:.page)}catch{self.error=error.localizedDescription}}
    }
    #if os(macOS)
    func clipboardCommand(_ command:String) {
        Task {do{
            let handled=try await webView?.callAsyncJavaScript("return await window.circuitStudioClipboardCommand(command)",arguments:["command":command],in:nil,contentWorld:.page) as? Bool
            if handled != true{NSApp.sendAction(Selector(command+":"),to:nil,from:nil)}
        }catch{self.error=error.localizedDescription}}
    }
    #endif
    func explain() {
        withAnimation(.snappy(duration:0.25)) { if showDrawer && drawerTab == .assistant {showDrawer=false}else{drawerTab = .assistant;showDrawer=true} }
        guard showDrawer else { return }
        webView?.evaluateJavaScript("window.circuitStudioCloseTools?.()",completionHandler:nil)
        chat.preparing=true
        Task {
            defer { chat.preparing=false }
            do {
                try chat.activate(try await assistantSnapshot())
                chat.error=nil
            } catch { chat.error=error.localizedDescription }
        }
    }
    func assistantSnapshot() async throws -> String {
        guard let value=try await webView?.evaluateJavaScript("window.circuitStudioSnapshot?.()"),let text=value as? String else { throw CircuitError.message("The engineering project is not ready.") }
        guard text.utf8.count <= 60_000 else { throw CircuitError.message("This project exceeds the AI context limit. Copy the relevant Cell into a smaller project first.") }
        return text
    }
    func loadExample(_ name:String) {
        guard ["rc","common","diff"].contains(name) else { return }
        Task {
            do { _=try await webView?.callAsyncJavaScript("return await window.circuitStudioLoadExample(name)",arguments:["name":name],in:nil,contentWorld:.page) }
            catch { self.error=(error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription }
        }
    }
    func updateDrawerInset(_ width:CGFloat,bottom:CGFloat=0) {
        webView?.evaluateJavaScript("window.circuitStudioSetDrawerInset?.(\(Int(width)),\(Int(bottom)))",completionHandler:nil)
    }
    func simulate() {
        drawerTab = .simulation;showDrawer=true
        webView?.evaluateJavaScript("window.circuitStudioCloseTools?.()",completionHandler:nil)
    }
    func runSimulation() {
        simulate();Task { await runDrawerSimulation() }
    }
    func runSimulation(payload:[String:Any],present:Bool=true) async throws -> [String:Any] {
        guard !simulationRunning else { throw CircuitError.message("A simulation is already running. Wait for it to finish.") }
        let data=try JSONSerialization.data(withJSONObject:payload)
        guard data.count <= 8_000_000 else { throw CircuitError.message("Simulation settings exceed the size limit.") }
        let request=try JSONDecoder().decode(EngineeringSimulationRequest.self,from:data)
        simulationRunning=true
        defer { simulationRunning=false }
        let result=try await Task.detached(priority:.userInitiated) { try request.run() }.value
        let output=EngineeringSimulationOutput(source:request.source,settings:request.configuration.settings,result:result,modelNotice:request.configuration.modelNotice)
        simulationResults[request.source.id]=output
        simulationArchive[output.id.uuidString]=output
        if present { simulationOutput=output }
        return ["summary":"Simulation complete"]
    }
    func showSimulationResult(id:String) throws {
        guard let result=simulationResults[id] else { throw CircuitError.message("Run this project to view its waveforms.") }
        simulationOutput=result
    }
    func simulationResult(id:String) -> EngineeringSimulationOutput? { simulationResults[id] }
    func archivedResult(_ id:String,projectID:String)->EngineeringSimulationOutput? {guard let result=simulationArchive[id],result.source.id==projectID else{return nil};return result}
    func simulationHistory(projectID:String)->[EngineeringSimulationOutput] {simulationArchive.values.filter{$0.source.id==projectID}.sorted{$0.createdAt<$1.createdAt}}
    func figureOptions(_ id:String)->CircuitAIPlotOptions {plotOptions[id] ?? CircuitAIPlotOptions()}
    func updateFigure(_ figure:CircuitAIFigure) {plotOptions[figure.id]=figure.options;chat.updateFigure(figure)}
    func hasSimulationResult(id:String) -> Bool { simulationResults[id] != nil }
    func exportImage(_ format:String,style:String,copy:Bool=false,selection:Bool=false) {
        Task {do {_ = try await webView?.callAsyncJavaScript("return await window.circuitStudioImage(format,style,copy,scope)",arguments:["format":format,"style":style,"copy":copy,"scope":selection ? "selection":"all"],in:nil,contentWorld:.page)}catch{self.error=error.localizedDescription}}
    }
    func copyPNG() { webView?.evaluateJavaScript("window.circuitStudioCopyPNG?.()",completionHandler:nil) }
}
struct EngineeringFocusKey:FocusedValueKey { typealias Value=EngineeringWorkspace }
extension FocusedValues { var engineeringEditor:EngineeringWorkspace? { get { self[EngineeringFocusKey.self] } set { self[EngineeringFocusKey.self]=newValue } } }
struct EngineeringWorkspaceView:View {
    @State private var workspace=EngineeringWorkspace()
    init(workspace:EngineeringWorkspace? = nil) { _workspace=State(initialValue:workspace ?? EngineeringWorkspace()) }
    var body:some View {
        VStack(spacing:0) {
            if let url=workspace.url {
                GeometryReader { geometry in
                 let compact=geometry.size.width<600
                 let drawerWidth=compact ? max(0,geometry.size.width-24):min(420,max(340,geometry.size.width*0.30))
                 let drawerHeight=compact ? min(500,max(300,geometry.size.height*0.55)):max(300,geometry.size.height-48)
                 ZStack(alignment:compact ? .bottom:.trailing) {
                  ZStack(alignment:.bottomTrailing) {
                    EngineeringBrowser(workspace:workspace,url:url)
                    if !workspace.showDrawer { HStack(spacing:6) {
                        Menu {
                            Button("课程 CAD 示例…") {workspace.showCourseExamples=true}
                            Divider()
                            Button("RC 滤波器") { workspace.loadExample("rc") }
                            Button("共源放大器") { workspace.loadExample("common") }
                            Button("差分放大器") { workspace.loadExample("diff") }
                        } label: { Image(systemName:"square.stack").frame(width:36,height:36) }.menuStyle(.borderlessButton).fixedSize().help("电路模板").accessibilityLabel("电路模板")
                        Menu {
                            Section("Virtuoso 风格") {
                                Button("导出 PNG…"){workspace.exportImage("png",style:"virtuoso")}
                                Button("导出 SVG…"){workspace.exportImage("svg",style:"virtuoso")}
                                Button("复制为 PNG"){workspace.exportImage("png",style:"virtuoso",copy:true)}
                            }
                            Section("当前配色") {
                                Button("导出 PNG…"){workspace.exportImage("png",style:"current")}
                                Button("导出 SVG…"){workspace.exportImage("svg",style:"current")}
                            }
                        } label:{Image(systemName:"square.and.arrow.up").frame(width:36,height:36)}.menuStyle(.borderlessButton).fixedSize().help("导出电路图").accessibilityLabel("导出电路图")
                        Button { workspace.simulate() } label: { Image(systemName:"waveform.path").frame(width:36,height:36) }.help("Run simulation").accessibilityLabel("Run simulation")
                        Button { workspace.explain() } label: { Label("CircuitAI",systemImage:"sparkles").font(.system(size:12,weight:.medium)).padding(.horizontal,10).frame(height:36) }.help("AI 电路解读").accessibilityLabel("CircuitAI 对话")
                    }.buttonStyle(.plain).padding(7).glassEffect(.regular.interactive(),in:Capsule()).padding(.trailing,16).padding(.bottom,30) }
                  }.frame(minWidth:0).accessibilityIdentifier("engineering-canvas-region")
                    if workspace.showDrawer {
                        VStack(spacing:0) {
                            HStack(spacing:12) {
                                Picker("工具抽屉",selection:$workspace.drawerTab) {ForEach(EngineeringWorkspace.DrawerTab.allCases,id:\.self){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
                                Button {withAnimation(.snappy){workspace.showDrawer=false}} label:{Image(systemName:"xmark").frame(width:24,height:24)}.buttonStyle(.plain).accessibilityLabel("收起工具抽屉")
                            }.padding(14)
                            Divider()
                            if workspace.drawerTab == .assistant {
                                EngineeringChatDrawer(chat:workspace.chat,close:{workspace.showDrawer=false},snapshot:{try await workspace.assistantSnapshot()},execute:{try await workspace.agentTool($0,arguments:$1,stamp:$2)},figureChanged:{workspace.updateFigure($0)},showsClose:false)
                            } else {EngineeringSimulationDrawer(workspace:workspace)}
                        }.frame(width:drawerWidth,height:drawerHeight).background(.regularMaterial,in:RoundedRectangle(cornerRadius:20)).clipShape(RoundedRectangle(cornerRadius:20)).shadow(color:.black.opacity(0.10),radius:24,y:8).padding(.trailing,compact ? 0:16).padding(.bottom,compact ? 16:0).accessibilityIdentifier("engineering-tools-drawer")
                            .transition(.move(edge:compact ? .bottom:.trailing).combined(with:.opacity))
                    }
                 }.onChange(of:workspace.showDrawer,initial:true) {_,open in workspace.updateDrawerInset(open && !compact ? drawerWidth+32:0,bottom:open && compact ? drawerHeight+32:0)}
                  .onChange(of:geometry.size){_,_ in if workspace.showDrawer{workspace.updateDrawerInset(compact ? 0:drawerWidth+32,bottom:compact ? drawerHeight+32:0)}}
                }
            }
            else if let error=workspace.error { ContentUnavailableView("Engineering workspace",systemImage:"exclamationmark.triangle",description:Text(error)) }
            else { ProgressView("Loading engineering workspace…").frame(maxWidth:.infinity,maxHeight:.infinity) }
        }
        #if os(macOS)
        .frame(minWidth:1000,minHeight:680)
        #endif
        .tint(StudioStyle.accent)
        .task { workspace.start() }
        #if os(iOS)
        .onOpenURL {url in Task{await workspace.openExternalProject(url)}}
        .onContinueUserActivity("com.circuitstudio.edit") {activity in
            if let value=activity.userInfo?["documentURL"] as? String,let url=URL(string:value) {Task{await workspace.openExternalProject(url)}}
        }
        #endif
        #if DEBUG && os(iOS)
        .task { await workspace.runIndependentDebugChecks() }
        #endif
        .task { await workspace.chat.subscription.watch() }
        .focusedSceneValue(\.engineeringEditor,workspace)
        .alert("Circuit Studio",isPresented:Binding(get:{workspace.error != nil && workspace.url != nil},set:{if !$0{workspace.error=nil}})){Button("好"){workspace.error=nil}}message:{Text(workspace.error ?? "")}
        .sheet(isPresented:$workspace.showCourseExamples) {CircuitCourseExamples(workspace:workspace)}
        .sheet(item:$workspace.simulationOutput) { EngineeringSimulationView(output:$0) }
        .alert("Engineering workspace",isPresented:Binding(get:{workspace.error != nil && workspace.url != nil},set:{ if !$0 { workspace.error=nil } })) { Button("OK") { workspace.error=nil } } message: { Text(workspace.error ?? "") }
    }
}
#if os(macOS)
struct EngineeringBrowser:NSViewRepresentable {
    var workspace:EngineeringWorkspace
    var url:URL
    func makeCoordinator()->Coordinator { Coordinator(workspace:workspace,url:url) }
    func makeNSView(context:Context)->WKWebView {
        let configuration=WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(context.coordinator,contentWorld:.page,name:"circuitStudio")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically=false
        let view=WKWebView(frame:.zero,configuration:configuration)
        view.navigationDelegate=context.coordinator;view.uiDelegate=context.coordinator
        workspace.webView=view;context.coordinator.installFileShortcuts(for:view);view.load(URLRequest(url:url));return view
    }
    func updateNSView(_ view:WKWebView,context:Context) {}
    static func dismantleNSView(_ view:WKWebView,coordinator:Coordinator) { coordinator.removeFileShortcuts();view.configuration.userContentController.removeScriptMessageHandler(forName:"circuitStudio",contentWorld:.page);view.stopLoading() }
    @MainActor final class Coordinator:NSObject,WKScriptMessageHandlerWithReply,WKNavigationDelegate,WKUIDelegate {
        let workspace:EngineeringWorkspace
        let url:URL
        private var closeAlert:NSAlert?
        private var fileShortcutMonitor:Any?
        init(workspace:EngineeringWorkspace,url:URL) { self.workspace=workspace;self.url=url }
        func installFileShortcuts(for view:WKWebView) {
            removeFileShortcuts()
            // The legacy DocumentGroup also registers document key equivalents.
            // Route file commands by the actual engineering window, including
            // while a native drawer field is first responder.
            fileShortcutMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) {[weak self,weak view] event in
                guard let self,let window=view?.window,event.window === window,window.attachedSheet == nil else{return event}
                let modifiers=event.modifierFlags.intersection([.command,.shift,.option,.control])
                guard modifiers == .command || modifiers == [.command,.shift] else{return event}
                let key=event.charactersIgnoringModifiers?.lowercased()
                let command:String?
                if key == "s" {command=modifiers.contains(.shift) ? "save-as":"save"}
                else if key == "o",modifiers == .command {command="open"}
                else if key == "n",modifiers == .command {command="new"}
                else {command=nil}
                guard let command else{return event}
                self.workspace.fileCommand(command);return nil
            }
        }
        func removeFileShortcuts() {if let fileShortcutMonitor{NSEvent.removeMonitor(fileShortcutMonitor)};fileShortcutMonitor=nil}
        func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage,replyHandler:@escaping @MainActor @Sendable (Any?,String?)->Void) {
            guard message.frameInfo.isMainFrame,message.frameInfo.securityOrigin.protocol == "http",message.frameInfo.securityOrigin.host == "127.0.0.1",message.frameInfo.securityOrigin.port == url.port,
                  let envelope=message.body as? [String:Any],let action=envelope["action"] as? String else { replyHandler(nil,"Untrusted editor frame");return }
            let payload=envelope["payload"] as? [String:Any] ?? [:]
            if action == "simulation-drawer" {
                workspace.simulate();if payload["run"] as? Bool == true {Task{await workspace.runDrawerSimulation()}}
                replyHandler(["ok":true],nil);return
            }
            if action == "simulation-probe-mode" {
                if payload["id"] as? String == workspace.chat.projectID {workspace.simulationDraft.pickingProbes=payload["active"] as? Bool ?? false}
                replyHandler(["ok":true],nil);return
            }
            if action == "simulation-probe" {
                Task {do {
                    let stamp=try CircuitAIStamp.context(try await workspace.assistantSnapshot())
                    guard payload["id"] as? String == stamp.projectID,let name=payload["name"] as? String,!name.isEmpty,name.count<200 else{throw CircuitError.message("工程已切换，请重新选择观测网络。")}
                    if workspace.simulationDraft.projectID != stamp.projectID {await workspace.refreshSimulationDraft()}
                    let draft=workspace.simulationDraft
                    if let index=draft.value.settings.probes.firstIndex(where:{$0.caseInsensitiveCompare(name) == .orderedSame}){draft.value.settings.probes.remove(at:index)}else{draft.value.settings.probes.append(name)}
                    try await workspace.saveSimulationDraft(draft.value,projectID:stamp.projectID)
                    draft.notice="观测网络："+draft.value.settings.probes.joined(separator:", ")
                    replyHandler(["ok":true],nil)
                }catch{replyHandler(["error":error.localizedDescription],nil)}};return
            }
            if action == "model-library" {
                do { replyHandler(try workspace.modelLibrary.handle(payload),nil) } catch { replyHandler(["error":error.localizedDescription],nil) }
                return
            }
            if action == "assistant-context" {
                if let text=payload["context"] as? String,text.utf8.count<10000 { try? workspace.chat.activate(text) }
                replyHandler(["ok":true],nil);return
            }
            if action == "confirm-close" {
                guard closeAlert == nil,let window=workspace.webView?.window else { replyHandler(["decision":"cancel"],nil);return }
                let alert=NSAlert();closeAlert=alert
                let name=String((payload["name"] as? String ?? "未命名电路").prefix(120))
                alert.messageText="要保存对“\(name)”的修改吗？"
                alert.informativeText="如果不保存，关闭后将丢失这些修改。"
                alert.alertStyle = .warning
                let canSave=payload["canSave"] as? Bool == true
                if canSave { alert.addButton(withTitle:"保存") }
                alert.addButton(withTitle:"不保存").keyEquivalent="d"
                alert.addButton(withTitle:"取消").keyEquivalent="\u{1b}"
                alert.beginSheetModal(for:window) { [weak self] response in
                    self?.closeAlert=nil
                    let index=response.rawValue-NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    let decision=canSave ? (index == 0 ? "save" : index == 1 ? "discard" : "cancel") : (index == 0 ? "discard" : "cancel")
                    replyHandler(["decision":decision],nil)
                }
                return
            }
            if action == "simulation-run" {
                Task {
                    do { replyHandler(try await workspace.runSimulation(payload:payload),nil) }
                    catch { replyHandler(["error":error.localizedDescription],nil) }
                }
                return
            }
            do {
                if action == "simulation-result-status" { replyHandler(["available":workspace.hasSimulationResult(id:payload["id"] as? String ?? "")],nil) }
                else if action == "simulation-results" { try workspace.showSimulationResult(id:payload["id"] as? String ?? "");replyHandler([:],nil) }
                else { replyHandler(try workspace.files.handle(action,payload:payload),nil) }
            }
            catch { replyHandler(["error":error.localizedDescription],nil) }
        }
        func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping @MainActor (WKNavigationActionPolicy)->Void) {
            guard let target=navigationAction.request.url,target.scheme == "http",target.host == "127.0.0.1",target.port == url.port else { decisionHandler(.cancel);return };decisionHandler(.allow)
        }
        func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { workspace.error=error.localizedDescription }
        func webView(_ webView:WKWebView,runJavaScriptAlertPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping @MainActor ()->Void) { let alert=NSAlert();alert.messageText=String(message.prefix(2000));alert.runModal();completionHandler() }
        func webView(_ webView:WKWebView,runJavaScriptConfirmPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping @MainActor (Bool)->Void) { let alert=NSAlert();alert.messageText=String(message.prefix(2000));alert.addButton(withTitle:NSLocalizedString("Continue",comment:""));alert.addButton(withTitle:NSLocalizedString("Cancel",comment:""));completionHandler(alert.runModal() == .alertFirstButtonReturn) }
    }
}
#endif
