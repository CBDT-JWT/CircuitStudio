import Foundation

public enum CircuitAIJSON:Codable,Sendable,Equatable {
    case string(String),number(Double),bool(Bool),array([CircuitAIJSON]),object([String:CircuitAIJSON]),null
    public init(from decoder:Decoder) throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v=try? c.decode(Bool.self) { self = .bool(v) }
        else if let v=try? c.decode(Double.self) { self = .number(v) }
        else if let v=try? c.decode(String.self) { self = .string(v) }
        else if let v=try? c.decode([CircuitAIJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String:CircuitAIJSON].self)) }
    }
    public func encode(to encoder:Encoder) throws {
        var c=encoder.singleValueContainer()
        switch self { case .string(let v):try c.encode(v);case .number(let v):try c.encode(v);case .bool(let v):try c.encode(v);case .array(let v):try c.encode(v);case .object(let v):try c.encode(v);case .null:try c.encodeNil() }
    }
    public var string:String? { if case .string(let v)=self { return v };return nil }
}
public struct CircuitAIToolCall:Codable,Sendable,Equatable {
    public struct Function:Codable,Sendable,Equatable { public var name:String;public var arguments:String }
    public var id:String;public var type:String;public var function:Function
}
public struct CircuitAIMessage:Codable,Sendable,Equatable {
    public var role:String
    public var content:CircuitAIJSON?
    public var tool_calls:[CircuitAIToolCall]?
    public var tool_call_id:String?
    public var imageOrigin:String?
    public init(role:String,content:CircuitAIJSON? = nil,tool_calls:[CircuitAIToolCall]? = nil,tool_call_id:String? = nil,imageOrigin:String?=nil) { self.role=role;self.content=content;self.tool_calls=tool_calls;self.tool_call_id=tool_call_id;self.imageOrigin=imageOrigin }
}
/// A bounded context window, independent of how many tool steps the task takes.
public enum CircuitAIHistory {
    public static func compact(_ messages:[CircuitAIMessage],request:String)->[CircuitAIMessage] {
        func size(_ rows:[CircuitAIMessage])->Int { (try? JSONEncoder().encode(rows).count) ?? Int.max }
        guard messages.count>28 || size(messages)>5_000_000 else { return messages }
        let attachment=messages.last(where:{$0.imageOrigin=="attachment"})
        var start=max(0,messages.count-12)
        func boundary(_ index:Int)->Int {
            var i=index
            while i<messages.count {
                let row=messages[i]
                if row.role=="tool" { i+=1;continue }
                if row.role=="user",row.imageOrigin != "attachment",case .array?=row.content { i+=1;continue }
                break
            }
            return i
        }
        start=boundary(start)
        while true {
            let removed=Array(messages.prefix(start))
            let receipts=Dictionary(removed.compactMap { row -> (String,String)? in
                guard row.role=="tool",let id=row.tool_call_id else { return nil };return (id,row.content?.string ?? "")
            },uniquingKeysWith:{_,new in new})
            let calls:[CircuitAIToolCall]=removed.flatMap{$0.tool_calls ?? []}
            var records:[String]=[]
            for call in calls.suffix(8) {
                let arguments=String(call.function.arguments.prefix(180))
                let result=String((receipts[call.id] ?? "无回执").prefix(320))
                records.append("\(call.function.name) \(arguments) → \(result)")
            }
            let older=records.joined(separator:"\n")
            let context=String((removed.first(where:{$0.role=="assistant" && ($0.content?.string?.hasPrefix("较早工具记录") ?? false)})?.content?.string ?? "").suffix(2400))
            let retained=Array(messages.suffix(from:start))
            let images=attachment.map{retained.contains($0) ? []:[$0]} ?? []
            let rows=[CircuitAIMessage(role:"user",content:.string(request)),CircuitAIMessage(role:"assistant",content:.string("较早工具记录（上下文已压缩，当前电路以最新快照为准）：\n"+context+"\n"+older))]+images+retained
            if size(rows)<=5_000_000 || start>=messages.count-2 { return rows }
            start=boundary(start+1)
        }
    }
}
public struct CircuitAIQuestion:Decodable,Sendable {
    public struct Option:Decodable,Sendable,Identifiable { public var label:String;public var detail:String?;public var id:String { label } }
    public var question:String;public var options:[Option]
    public static func decode(_ text:String) throws -> Self {
        let question=try JSONDecoder().decode(Self.self,from:Data(text.utf8))
        guard !question.question.isEmpty,question.question.count<=400,(2...4).contains(question.options.count),Set(question.options.map(\.label)).count==question.options.count,question.options.allSatisfy({ !$0.label.isEmpty && $0.label.count<=100 && ($0.detail?.count ?? 0)<=300 }) else { throw CircuitError.message("CircuitAI 提问卡片格式无效。") }
        return question
    }
}
extension CircuitAIService {
    public static func agent(context:String,messages:[CircuitAIMessage],configuration:CircuitAIConfiguration) async throws -> CircuitAIMessage {
        var request=try makeRequest(context:context,question:"CircuitAI conversation",language:"中文",configuration:configuration)
        request.url=request.url?.deletingLastPathComponent().appendingPathComponent("assistant")
        guard context.utf8.count<=60_000,messages.count<=40 else { throw CircuitError.message("对话过长，请开启新对话。") }
        let encoded=try JSONEncoder().encode(messages)
        let list=try JSONSerialization.jsonObject(with:encoded)
        request.httpBody=try JSONSerialization.data(withJSONObject:["context":context,"question":"CircuitAI conversation","language":"中文","messages":list])
        guard (request.httpBody?.count ?? 0)<=6_000_000 else { throw CircuitError.message("对话中的图形过大，请减少附件后重试。") }
        let settings=URLSessionConfiguration.ephemeral;settings.httpShouldSetCookies=false
        let session=URLSession(configuration:settings);defer { session.invalidateAndCancel() }
        let (bytes,response)=try await session.bytes(for:request)
        var data=Data()
        for try await byte in bytes { try Task.checkCancellation();guard data.count<500_000 else { throw CircuitError.message("CircuitAI 回复过大。") };data.append(byte) }
        guard (response as? HTTPURLResponse)?.statusCode==200 else {
            struct Failure:Decodable { var error:String }
            throw CircuitError.message((try? JSONDecoder().decode(Failure.self,from:data).error) ?? "CircuitAI 服务暂不可用。")
        }
        struct Response:Decodable { var message:CircuitAIMessage }
        let message=try JSONDecoder().decode(Response.self,from:data).message
        guard message.role=="assistant",(message.tool_calls?.count ?? 0)<=1,!((message.content?.string ?? "").isEmpty && (message.tool_calls ?? []).isEmpty) else { throw CircuitError.message("CircuitAI 返回了无效的操作。") }
        return message
    }
}
