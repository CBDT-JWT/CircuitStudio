import SwiftUI

struct CircuitAIStamp:Codable,Equatable {
    var projectID:String;var documentId:String;var revision:Int;var structureRevision:Int
    static func context(_ text:String) throws -> Self {
        let object=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any]
        guard let id=object?["id"] as? String,let document=object?["activeDocumentId"] as? String,let documents=object?["documents"] as? [[String:Any]],let revision=documents.first(where:{$0["id"] as? String==document})?["revision"] as? Int,let structure=object?["structureRevision"] as? Int else { throw CircuitError.message("当前电路尚未准备好。") }
        return Self(projectID:id,documentId:document,revision:revision,structureRevision:structure)
    }
}
struct CircuitAIToolResult { var content:String;var image:String?;var stamp:CircuitAIStamp;var figure:CircuitAIFigure?=nil }
@MainActor @Observable final class EngineeringChat {
    struct Message:Identifiable { let id=UUID();var role:String;var text:String;var attachments:[CircuitAIImageAttachment]=[];var figures:[CircuitAIFigure]=[] }
    struct Question { var call:CircuitAIToolCall;var value:CircuitAIQuestion;var stamp:CircuitAIStamp }
    struct Thread { var messages:[Message]=[];var draft="";var wire:[CircuitAIMessage]=[];var question:Question?;var intent="";var attachments:[CircuitAIImageAttachment]=[] }
    var projectID="";var projectName="当前画布";var threads:[String:Thread]=[:]
    var error:String?;var sending=false;var preparing=false;var activity=""
    let subscription=CircuitSubscription()
    private var request:Task<Void,Never>?;private var generation=UUID()
    private let response:@MainActor (String,[CircuitAIMessage],CircuitAIConfiguration) async throws -> CircuitAIMessage
    private let access:(@MainActor () throws -> CircuitAIConfiguration)?
    init(response:@escaping @MainActor (String,[CircuitAIMessage],CircuitAIConfiguration) async throws -> CircuitAIMessage = { try await CircuitAIService.agent(context:$0,messages:$1,configuration:$2) },access:(@MainActor () throws -> CircuitAIConfiguration)?=nil) { self.response=response;self.access=access }
    var messages:[Message] { threads[projectID]?.messages ?? [] }
    var pendingQuestion:Question? { threads[projectID]?.question }
    var attachments:[CircuitAIImageAttachment] {threads[projectID]?.attachments ?? []}
    func attach(_ attachment:CircuitAIImageAttachment) {guard attachments.count<4 else{error="每条消息最多添加 4 张图片。";return};threads[projectID,default:Thread()].attachments.append(attachment)}
    func removeAttachment(_ id:UUID){threads[projectID]?.attachments.removeAll{$0.id==id}}
    func updateFigure(_ figure:CircuitAIFigure) {guard var thread=threads[projectID] else{return};for i in thread.messages.indices {for j in thread.messages[i].figures.indices where thread.messages[i].figures[j].id==figure.id {thread.messages[i].figures[j]=figure}};threads[projectID]=thread}
    var draft:String { get { threads[projectID]?.draft ?? "" } set { threads[projectID,default:Thread()].draft=newValue } }
    func activate(_ context:String) throws {
        let object=try JSONSerialization.jsonObject(with:Data(context.utf8)) as? [String:Any]
        guard object?["schema"] as? String=="circuitstudio-assistant-v1",let id=object?["id"] as? String else { throw CircuitError.message("当前电路尚未准备好。") }
        projectID=id;projectName=object?["name"] as? String ?? "当前画布"
    }
    func submit(snapshot:@escaping @MainActor () async throws -> String,execute:@escaping @MainActor (String,String,CircuitAIStamp) async throws -> CircuitAIToolResult) {
        if pendingQuestion != nil { answerQuestion(draft,snapshot:snapshot,execute:execute) } else { send(snapshot:snapshot,execute:execute) }
    }
    func send(_ prompt:String?=nil,snapshot:@escaping @MainActor () async throws -> String,execute:@escaping @MainActor (String,String,CircuitAIStamp) async throws -> CircuitAIToolResult) {
        guard !sending else { return }
        var text=(prompt ?? draft).trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        if text.isEmpty {text="请分析附图。"}
        if pendingQuestion != nil { answerQuestion(text,snapshot:snapshot,execute:execute);return }
        start(text:text,answer:nil,snapshot:snapshot,execute:execute)
    }
    func answerQuestion(_ text:String,snapshot:@escaping @MainActor () async throws -> String,execute:@escaping @MainActor (String,String,CircuitAIStamp) async throws -> CircuitAIToolResult) {
        guard !sending,let question=pendingQuestion,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        start(text:text,answer:question,snapshot:snapshot,execute:execute)
    }
    private func start(text:String,answer:Question?,snapshot:@escaping @MainActor () async throws -> String,execute:@escaping @MainActor (String,String,CircuitAIStamp) async throws -> CircuitAIToolResult) {
        guard text.utf8.count<=2000 else { error="请将输入控制在 2000 个 UTF-8 字节以内。";return }
        sending=true;error=nil;activity="正在读取电路…";let token=UUID();generation=token;let requestedProject=projectID
        request=Task {
            defer { if generation==token { sending=false;activity="";request=nil } }
            var threadID=projectID
            do {
                var context=try await snapshot();try activate(context);threadID=projectID
                guard requestedProject.isEmpty || requestedProject==threadID else {throw CircuitError.message("已切换工程，请回到原工程发送。")}
                var stamp=try CircuitAIStamp.context(context)
                let configuration=try access?() ?? subscription.configuration()
                let attached=threads[threadID]?.attachments ?? []
                let taskStart=threads[threadID]?.messages.count ?? 0
                var figures:[CircuitAIFigure]=[]
                if let answer {
                    guard answer.stamp.projectID==stamp.projectID,answer.stamp.documentId==stamp.documentId else { throw CircuitError.message("已切换工程，请回到原来的单元回答卡片。") }
                    threads[threadID,default:Thread()].question=nil
                    threads[threadID,default:Thread()].wire.append(.init(role:"tool",content:.string("用户选择："+text),tool_call_id:answer.call.id))
                } else {
                    threads[threadID,default:Thread()].intent=text
                    if attached.isEmpty {threads[threadID,default:Thread()].wire.append(.init(role:"user",content:.string(text)))}
                }
                if !attached.isEmpty {
                    threads[threadID,default:Thread()].wire=threads[threadID,default:Thread()].wire.map {row in
                        guard row.imageOrigin=="attachment" else{return row}
                        var plain=row
                        if case .array(let parts)?=row.content {plain.content=parts.first; if case .object(let first)?=plain.content {plain.content=first["text"]}}
                        plain.imageOrigin=nil;return plain
                    }
                    let parts:[CircuitAIJSON]=[.object(["type":.string("text"),"text":.string(text)])]+attached.map{.object(["type":.string("image_url"),"image_url":.object(["url":.string($0.dataURL)])])}
                    threads[threadID,default:Thread()].wire.append(.init(role:"user",content:.array(parts),imageOrigin:"attachment"))
                }
                threads[threadID,default:Thread()].messages.append(.init(role:"user",text:text,attachments:attached));threads[threadID,default:Thread()].draft="";threads[threadID,default:Thread()].attachments=[]
                let intent=answer == nil ? text : (threads[threadID]?.intent ?? "")+"\n用户的澄清回答："+text
                while true {
                    try Task.checkCancellation();activity="CircuitAI 正在思考…"
                    threads[threadID,default:Thread()].wire=CircuitAIHistory.compact(threads[threadID]?.wire ?? [],request:intent)
                    let response=try await self.response(context,threads[threadID]?.wire ?? [],configuration)
                    try Task.checkCancellation()
                    threads[threadID,default:Thread()].wire.append(response)
                    if let text=response.content?.string,!text.isEmpty {
                        let final=(response.tool_calls ?? []).isEmpty
                        if final,!figures.isEmpty {for i in taskStart..<(threads[threadID]?.messages.count ?? taskStart) {threads[threadID]?.messages[i].figures=[]}}
                        threads[threadID,default:Thread()].messages.append(.init(role:"assistant",text:text,figures:final ? figures:[]))
                    }
                    guard let call=response.tool_calls?.first else { return }
                    if call.function.name=="ask_user" {
                        let value=try CircuitAIQuestion.decode(call.function.arguments)
                        threads[threadID,default:Thread()].question=Question(call:call,value:value,stamp:stamp);return
                    }
                    activity=Self.toolTitle(call.function.name)
                    do {
                        let result=try await execute(call.function.name,call.function.arguments,stamp)
                        try Task.checkCancellation();stamp=result.stamp
                        threads[threadID,default:Thread()].wire.append(.init(role:"tool",content:.string(result.content),tool_call_id:call.id))
                        if let figure=result.figure {figures.removeAll{$0.id==figure.id};figures.append(figure)}
                        threads[threadID,default:Thread()].messages.append(.init(role:"tool",text:activity+" · 已完成",figures:result.figure.map{[$0]} ?? []))
                        if let image=result.image {
                            // Keep only the newest visual evidence, preserving tool receipt order.
                            threads[threadID,default:Thread()].wire.removeAll { if case .array?=$0.content { return $0.role=="user" && $0.imageOrigin != "attachment" };return false }
                            let imageContent:[CircuitAIJSON]=[
                                .object(["type":.string("text"),"text":.string("这是工具返回的实际图形，请结合数值与连接信息阅读。")]),
                                .object(["type":.string("image_url"),"image_url":.object(["url":.string(image),"detail":.string("original")])])
                            ]
                            threads[threadID,default:Thread()].wire.append(.init(role:"user",content:.array(imageContent),imageOrigin:"tool"))
                        }
                    } catch {
                        if Task.isCancelled { throw error }
                        threads[threadID,default:Thread()].wire.append(.init(role:"tool",content:.string("操作失败："+error.localizedDescription),tool_call_id:call.id))
                        threads[threadID,default:Thread()].messages.append(.init(role:"tool",text:activity+" · "+error.localizedDescription))
                        // A context change must never retarget the rest of an old request.
                        let current=try CircuitAIStamp.context(try await snapshot())
                        guard current==stamp else { throw CircuitError.message("电路已改变，已停止后续操作。请重新提问。") }
                    }
                    context=try await snapshot()
                    guard try CircuitAIStamp.context(context)==stamp else { throw CircuitError.message("电路在操作期间发生变化，请重新提问。") }
                    await Task.yield()
                }
            } catch {
                if let last=threads[threadID]?.wire.last,last.role=="assistant",let call=last.tool_calls?.first,threads[threadID]?.question==nil {
                    threads[threadID,default:Thread()].wire.append(.init(role:"tool",content:.string("操作已停止。"),tool_call_id:call.id))
                }
                if !Task.isCancelled { self.error=error.localizedDescription }
            }
        }
    }
    static func toolTitle(_ name:String)->String {
        ["apply_foundry_model":"应用 GF180MCU 真实模型","inspect_circuit":"读取电路图","edit_components":"修改元件参数","add_component":"放置元件","add_power_rail":"绘制电源轨","connect_pins":"连接引脚","delete_components":"删除元件","undo_circuit_edit":"撤销电路修改","run_simulation":"运行本地仿真","view_waveforms":"读取波形","configure_plot":"设置图表","list_simulations":"读取仿真记录"][name] ?? "调用工具"
    }
    func cancel() { generation=UUID();request?.cancel();request=nil;sending=false;activity="" }
}
