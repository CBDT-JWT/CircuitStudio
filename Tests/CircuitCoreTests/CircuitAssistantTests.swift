import Foundation
import Testing
import CoreGraphics
@testable import CircuitCore

@Test func assistantContextUsesActualPinsAndDoesNotClaimSimulation() throws {
    let circuit = CircuitTemplate.inverter.make()
    let data = Data(try CircuitAssistantContext.make(circuit).utf8)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let components = try #require(payload["components"] as? [[String: Any]])
    let pmos = try #require(components.first { $0["kind"] as? String == "pmos" })
    let pins = try #require(pmos["pins"] as? [String: String])
    #expect(pins["S"] == "VDD")
    #expect(pins["D"] == "VOUT")
    #expect(pins["G"] == "VIN")
    #expect(payload["simulationPerformed"] as? Bool == false)
}
@Test func assistantWarnsAboutFloatingCircuitAndRejectsInvalidContexts() throws {
    var circuit = Circuit(); _ = circuit.add(.resistor, at: .zero)
    let data = Data(try CircuitAssistantContext.make(circuit).utf8)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(!(payload["validationWarnings"] as? [String] ?? []).isEmpty)
    #expect(throws: CircuitError.self) { try CircuitAssistantContext.make(Circuit()) }
    #expect(throws: CircuitError.self) { try CircuitAssistantContext.make(Circuit(title: "Figure", purpose: .illustration)) }
    for i in 0..<200 { _ = circuit.add(.resistor, at: Point(Double(i) * 100, 0)) }
    #expect(throws: CircuitError.self) { try CircuitAssistantContext.make(circuit) }
}
@Test func recognitionCoordinatesFlipVerticalAxisWithoutChangingSize() {
    let bounds = CircuitVision.topLeft(CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.25))
    #expect(abs(bounds.minY - 0.65) < 1e-12)
    #expect(bounds.minX == 0.2)
    #expect(bounds.width == 0.3)
    #expect(bounds.height == 0.25)
}
@Test func recognitionRejectsInvalidImages() {
    #expect(throws: CircuitError.self) { try CircuitVision.previewImage(Data("invalid image".utf8)) }
}
@Test func recognitionKeepsStrongestCompetingLabelAndSeparateSymbols() {
    let box = CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.2)
    let strongest = CircuitSymbolDetection(id: UUID(), kind: .nmos, confidence: 0.9, bounds: box)
    let competing = CircuitSymbolDetection(id: UUID(), kind: .pmos, confidence: 0.6, bounds: box.offsetBy(dx: 0.005, dy: 0))
    let separate = CircuitSymbolDetection(id: UUID(), kind: .resistor, confidence: 0.5, bounds: box.offsetBy(dx: 0.4, dy: 0))
    let result = CircuitVision.suppressOverlaps([competing, separate, strongest])
    #expect(result.map(\.id) == [strongest.id, separate.id])
}
@Test func subscriptionGatewayReceivesProofAndNoProviderKey() throws {
    let configuration = CircuitAIConfiguration(endpoint: "https://example.test/api/ai", signedTransaction: "signed-store-proof")
    let request = try CircuitAIService.makeRequest(context: "{}", question: "Explain", language: "中文", configuration: configuration)
    #expect(request.url?.path == "/api/ai/explain")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "StoreKit signed-store-proof")
    let requestData = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
    #expect(body["model"] == nil)
    #expect(body["apiKey"] == nil)
    #expect(throws: CircuitError.self) { try CircuitAIService.makeRequest(context: "{}", question: "Explain", language: "中文", configuration: CircuitAIConfiguration(endpoint: "http://example.test", signedTransaction: "proof")) }
    #expect(throws: CircuitError.self) { try CircuitAIService.makeRequest(context: "{}", question: "Explain", language: "中文", configuration: CircuitAIConfiguration(endpoint: "https://example.test", signedTransaction: "")) }
    #expect(try CircuitAIService.decodeResponse(Data("{\"answer\":\"RC filter\"}".utf8)) == "RC filter")
    #expect(throws: CircuitError.self) { try CircuitAIService.decodeResponse(Data("{\"answer\":\"\"}".utf8)) }
}

@Test func chatPreservesEngineeringContextAndRecentConversation() throws {
    let context="{\"schema\":\"circuitstudio-assistant-v1\",\"id\":\"project-a\",\"documents\":[],\"simulationPerformed\":false}"
    let turns=(0..<12).map { CircuitChatTurn(role:$0.isMultiple(of:2) ? .user : .assistant,content:"message-\($0)") }
    let result=try CircuitChatContext.appendingConversation(to:context,turns:turns)
    let payload=try #require(JSONSerialization.jsonObject(with:Data(result.utf8)) as? [String:Any])
    let history=try #require(payload["conversation"] as? [[String:String]])
    #expect(payload["id"] as? String == "project-a")
    #expect(payload["simulationPerformed"] as? Bool == false)
    #expect(history.count == 8)
    #expect(history.first?["content"] == "message-4")
    #expect(history.last?["content"] == "message-11")
}
@Test func chatTrimsHistoryWithoutDroppingCircuitDataOrExceedingRelayLimit() throws {
    let context=String(decoding:try JSONSerialization.data(withJSONObject:["schema":"circuitstudio-assistant-v1","topology":String(repeating:"x",count:50_000)]),as:UTF8.self)
    let result=try CircuitChatContext.appendingConversation(to:context,turns:[CircuitChatTurn(role:.user,content:String(repeating:"a",count:6_000)),CircuitChatTurn(role:.assistant,content:String(repeating:"b",count:6_000))])
    let payload=try #require(JSONSerialization.jsonObject(with:Data(result.utf8)) as? [String:Any])
    #expect(result.utf8.count <= 60_000)
    #expect((payload["topology"] as? String)?.count == 50_000)
    #expect((payload["conversation"] as? [[String:String]])?.count == 1)
    #expect(throws:CircuitError.self) { try CircuitChatContext.appendingConversation(to:"{}",turns:[]) }
}

@Test func circuitAIQuestionCardsRejectInvalidOrAmbiguousChoices() throws {
    let card=try CircuitAIQuestion.decode("{\"question\":\"希望调整什么？\",\"options\":[{\"label\":\"带宽\",\"detail\":\"调整 R/C\"},{\"label\":\"布局\"}]}")
    #expect(card.options.count==2)
    #expect(throws:CircuitError.self) { try CircuitAIQuestion.decode("{\"question\":\"?\",\"options\":[{\"label\":\"same\"},{\"label\":\"same\"}]}") }
}
@Test func circuitAIMessagesPreserveToolIDsAndMultimodalImages() throws {
    let raw=Data("{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"inspect_circuit\",\"arguments\":\"{}\"}}]}".utf8)
    let message=try JSONDecoder().decode(CircuitAIMessage.self,from:raw)
    #expect(message.tool_calls?.first?.function.name=="inspect_circuit")
    #expect(try JSONDecoder().decode(CircuitAIMessage.self,from:JSONEncoder().encode(message))==message)
    let image=CircuitAIMessage(role:"user",content:.array([.object(["type":.string("image_url"),"image_url":.object(["url":.string("data:image/png;base64,example")])])]))
    #expect(try JSONDecoder().decode(CircuitAIMessage.self,from:JSONEncoder().encode(image))==image)
}

@Test func circuitAIHistoryContinuesForTwoHundredToolStepsWithoutDanglingReceipts() throws {
    let intent="请画完整电路，使用接地和 VDD 电源轨"
    var history=[CircuitAIMessage(role:"user",content:.string(intent))]
    for i in 0..<200 {
        history=CircuitAIHistory.compact(history,request:intent)
        #expect(history.count<=28)
        var pending=Set<String>()
        for row in history {
            for call in row.tool_calls ?? [] { #expect(pending.isEmpty);pending.insert(call.id) }
            if row.role=="tool" { #expect(pending.remove(try #require(row.tool_call_id)) != nil) }
        }
        #expect(pending.isEmpty)
        #expect(history.contains{$0.role=="user" && $0.content?.string==intent})
        let call=CircuitAIToolCall(id:"step-\(i)",type:"function",function:.init(name:"inspect_circuit",arguments:"{}"))
        history.append(.init(role:"assistant",tool_calls:[call]));history.append(.init(role:"tool",content:.string("verified revision \(i)"),tool_call_id:call.id))
    }
    #expect(history.last?.content?.string=="verified revision 199")
}

@Test func circuitAIHistoryBoundsLargeVisualContextsWhileKeepingTheNewestReceipt() throws {
    var history=[CircuitAIMessage(role:"user",content:.string("keep request"))]
    for i in 0..<16 {
        let call=CircuitAIToolCall(id:"large-\(i)",type:"function",function:.init(name:"inspect_circuit",arguments:"{}"))
        history.append(.init(role:"assistant",tool_calls:[call]));history.append(.init(role:"tool",content:.string(String(repeating:"x",count:140_000)),tool_call_id:call.id))
    }
    history.append(.init(role:"user",content:.array([.object(["image":.string(String(repeating:"p",count:1_900_000))])])))
    let compact=CircuitAIHistory.compact(history,request:"keep request")
    #expect(try JSONEncoder().encode(compact).count<=3_000_000)
    #expect(compact.contains{$0.tool_call_id=="large-15"})
    #expect(compact.last==history.last)
}

@Test func circuitAIPlotOptionsRejectInvalidPresentationWithoutChangingData() throws {
    let options=try JSONDecoder().decode(CircuitAIPlotOptions.self,from:Data("{\"title\":\"RC response\",\"xLabel\":\"Frequency (Hz)\",\"yLabel\":\"Gain (dB)\",\"legend\":{\"V(OUT)\":\"Output\"},\"lineWidth\":2}".utf8))
    try options.validate();#expect(options.legend?["V(OUT)"]=="Output")
    var bad=options;bad.lineWidth=Double.infinity;#expect(throws:CircuitError.self){try bad.validate()}
    bad=options;bad.title=String(repeating:"x",count:121);#expect(throws:CircuitError.self){try bad.validate()}
    #expect(throws:(any Error).self){try JSONDecoder().decode(CircuitAIPlotOptions.self,from:Data("{\"xScale\":\"arbitrary\"}".utf8))}
}

@Test func circuitAIHistoryKeepsUploadedImageAlongsideRecentToolEvidence() throws {
    let upload=CircuitAIMessage(role:"user",content:.array([.object(["type":.string("image_url"),"image_url":.object(["url":.string("data:image/jpeg;base64,uploaded")])])]),imageOrigin:"attachment")
    var history=[upload]
    for i in 0..<30 {
        let call=CircuitAIToolCall(id:"img-\(i)",type:"function",function:.init(name:"inspect_circuit",arguments:"{}"))
        history.append(.init(role:"assistant",tool_calls:[call]));history.append(.init(role:"tool",content:.string("{}"),tool_call_id:call.id))
    }
    let compact=CircuitAIHistory.compact(history,request:"Use the uploaded reference")
    #expect(compact.contains(upload));#expect(compact.last?.tool_call_id=="img-29")
}
