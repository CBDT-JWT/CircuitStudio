import Foundation
import CryptoKit

/// Local reusable model packets. The gateway never receives the library itself.
@MainActor final class EngineeringModelLibrary {
    struct Entry:Codable { var id:String;var name:String;var text:String;var sha256:String;var updated:Date }
    private let file:URL
    init(directory:URL?=nil) {
        let root=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CircuitStudio/ModelLibrary",isDirectory:true)
        file=root.appendingPathComponent("models.json")
    }
    func handle(_ payload:[String:Any]) throws -> [String:Any] {
        let action=payload["operation"] as? String ?? "list"
        var entries=try load()
        switch action {
        case "list":return ["entries":entries.map{["id":$0.id,"name":$0.name,"sha256":$0.sha256]}]
        case "read":
            guard let entry=entries.first(where:{$0.id==payload["id"] as? String}) else { throw CircuitError.message("模型库中找不到这个模型。") }
            return ["id":entry.id,"name":entry.name,"text":entry.text,"sha256":entry.sha256]
        case "save":
            guard let raw=payload["text"] as? String,let rawName=payload["name"] as? String else { throw CircuitError.message("请填写模型名称和内容。") }
            let name=rawName.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty,name.count<=80,raw.utf8.count<=6_000_000,raw.range(of:"(?im)^\\s*\\.(model|subckt)\\b",options:.regularExpression) != nil else { throw CircuitError.message("请使用 6MB 以内、包含 .model 或 .subckt 的自包含模型文件。") }
            _=try EngineeringSimulation.deck("",settings:SimulationSettings(),models:raw)
            let digest=SHA256.hash(data:Data(raw.utf8)).map{String(format:"%02x",$0)}.joined()
            let existing=entries.first(where:{$0.sha256==digest})
            let entry=Entry(id:existing?.id ?? UUID().uuidString,name:name,text:raw,sha256:digest,updated:Date())
            entries.removeAll{$0.id==entry.id};entries.insert(entry,at:0)
            guard entries.count<=100,try JSONEncoder().encode(entries).count<=50_000_000 else { throw CircuitError.message("本地模型库已达到容量上限。") }
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(entries).write(to:file,options:.atomic)
            return ["id":entry.id,"name":entry.name,"sha256":digest]
        default:throw CircuitError.message("不支持的模型库操作。")
        }
    }
    private func load() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath:file.path) else { return [] }
        let data=try Data(contentsOf:file)
        guard data.count<=50_000_000 else { throw CircuitError.message("模型库文件过大。") }
        return try JSONDecoder().decode([Entry].self,from:data)
    }
}
