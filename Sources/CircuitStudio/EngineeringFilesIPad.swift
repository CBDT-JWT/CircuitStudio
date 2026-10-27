#if os(iOS)
import UIKit
import UniformTypeIdentifiers
import CryptoKit

/// Files/iCloud and the system share sheet; no user documents are served by HTTP.
@MainActor final class EngineeringFiles:NSObject,UIDocumentPickerDelegate {
    struct Recent:Codable {var id:String;var name:String;var path:String;var bookmark:Data;var revision:Int;var digest:String}
    private var root:URL {index.deletingLastPathComponent()}
    private var recent:[Recent]=[]
    private var pending:CheckedContinuation<URL?,Never>?
    private let index:URL
    override init(){let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CircuitStudio/Engineering",isDirectory:true);index=folder.appendingPathComponent("recent.json");super.init();recent=(try? JSONDecoder().decode([Recent].self,from:Data(contentsOf:index))) ?? []}
    private func remember()throws{try FileManager.default.createDirectory(at:index.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(recent).write(to:index,options:.atomic)}
    private func digest(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func binding(_ r:Recent)->[String:Any]{["id":r.id,"name":r.name,"path":r.path,"revision":r.revision,"byteDigest":r.digest]}
    private func resolve(_ r:Recent)throws->URL{var stale=false;return try URL(resolvingBookmarkData:r.bookmark,options:[],relativeTo:nil,bookmarkDataIsStale:&stale)}
    private func record(_ url:URL,data:Data,previous:Recent?)throws->Recent{
        let entry=Recent(id:previous?.id ?? UUID().uuidString,name:url.lastPathComponent,path:url.path,bookmark:try url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil),revision:(previous?.revision ?? 0)+1,digest:digest(data))
        recent.removeAll{$0.path==entry.path || $0.id==entry.id};recent.insert(entry,at:0);recent=Array(recent.prefix(30));try remember();return entry
    }
    private func choose(_ picker:UIDocumentPickerViewController)async throws->URL?{
        guard pending==nil,let presenter=CircuitImageActions.controller else{throw CircuitError.message("请先关闭当前文件窗口。")}
        return await withCheckedContinuation{continuation in pending=continuation;picker.delegate=self;presenter.present(picker,animated:true)}
    }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]){let completion=pending;pending=nil;completion?.resume(returning:urls.first)}
    func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController){let completion=pending;pending=nil;completion?.resume(returning:nil)}
    private func temporary(_ data:Data,name:String)throws->URL{
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);let name=String(URL(fileURLWithPath:name).lastPathComponent.prefix(180));let url=folder.appendingPathComponent(name.isEmpty ? "Circuit.json":name);try data.write(to:url,options:.atomic);return url
    }
    func openProject(_ url:URL,previous:Recent? = nil)throws->[String:Any]{
        let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
        let contents=try EngineeringProjectFile.read(url)
        let old=previous ?? recent.first{$0.path==url.path}
        let entry=try record(url,data:contents.sourceData,previous:old)
        return ["status":"opened","file":binding(entry),"text":contents.text,"importedLegacy":contents.importedLegacy]
    }
    func handle(_ action:String,payload:[String:Any])async throws->[String:Any]{
        switch action{
        case "project-recent":return ["files":recent.map{["id":$0.id,"name":$0.name,"path":$0.path]}]
        case "project-forget":recent.removeAll{$0.id==payload["id"] as? String};try remember();return ["status":"done"]
        case "project-open":
            let old=recent.first{$0.id==payload["id"] as? String};let selected:URL?
            if let old{selected=try resolve(old)}else{selected=try await choose(UIDocumentPickerViewController(forOpeningContentTypes:[.json,.circuit],asCopy:false))}
            guard let url=selected else{return ["status":"cancelled"]}
            return try openProject(url,previous:old)
        case "project-save":
            guard let text=payload["text"] as? String,text.utf8.count<=20_000_000,let object=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any],object["documents"] is [[String:Any]] || (object["schema"] as? String == "circuitstudio-project-v1" && object["cells"] is [[String:Any]]) else{throw CircuitError.message("工程内容无效。")}
            let data=Data(text.utf8),bound=payload["binding"] as? [String:Any]
            var saveAs=payload["saveAs"] as? Bool ?? false
            let old=recent.first{$0.id==bound?["id"] as? String};let url:URL
            if let old,!saveAs {
                let existing=try resolve(old),access=existing.startAccessingSecurityScopedResource();defer{if access{existing.stopAccessingSecurityScopedResource()}}
                saveAs=try EngineeringProjectFile.read(existing).importedLegacy
            }
            if let old,!saveAs{url=try resolve(old);let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
                guard bound?["byteDigest"] as? String == digest(try Data(contentsOf:url)),bound?["revision"] as? Int == old.revision else{return ["status":"conflict","message":"文件已在外部修改，请重新打开或另存为。"]}
                try data.write(to:url,options:.atomic)
            }else{let temporary=try temporary(data,name:payload["name"] as? String ?? "Circuit.circuitstudio.json");guard let selected=try await choose(UIDocumentPickerViewController(forExporting:[temporary],asCopy:true)) else{return ["status":"cancelled"]};url=selected}
            let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
            return ["status":"saved","file":binding(try record(url,data:data,previous:saveAs ? nil:old))]
        case "export":
            guard let encoded=payload["data"] as? String,encoded.utf8.count<=80_000_000,let data=Data(base64Encoded:encoded) else{throw CircuitError.message("导出图片无效。")}
            let file=try temporary(data,name:payload["name"] as? String ?? "Circuit.png")
            guard try await choose(UIDocumentPickerViewController(forExporting:[file],asCopy:true)) != nil else{return ["status":"cancelled"]};return ["status":"saved"]
        case "clipboard-prepare":
            guard let text=payload["text"] as? String,text.utf8.count<=20_000_000 else{throw CircuitError.message("选区过大。")}
            UIPasteboard.general.string=text;return ["ticket":UIPasteboard.general.changeCount]
        case "clipboard":
            if let ticket=payload["ticket"] as? Int,ticket != UIPasteboard.general.changeCount{throw CircuitError.message("剪贴板已改变，请重新复制。")}
            var item:[String:Any]=[:]
            if let text=payload["text"] as? String,text.utf8.count<=20_000_000{item[UTType.utf8PlainText.identifier]=text;item["com.circuitstudio.engineering-selection"]=text}
            for (key,type) in [("png",UTType.png.identifier),("svg",UTType.svg.identifier)]{if let encoded=payload[key] as? String,encoded.utf8.count<=80_000_000,let data=Data(base64Encoded:encoded){item[type]=data}}
            if !item.isEmpty{UIPasteboard.general.items=[item]};return ["ok":true]
        case "clipboard-read":return ["text":UIPasteboard.general.string ?? ""]
        case "components":return try components(payload)
        default:throw CircuitError.message("未知文件操作："+action)
        }
    }
    private func components(_ payload:[String:Any])throws->[String:Any] {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent("components.json")
        var entries=(try? Data(contentsOf:url)).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [[String:Any]] } ?? []
        let action=payload["action"] as? String ?? "",body=payload["body"] as? [String:Any] ?? [:]
        if action == "list" { return ["entries":entries] }
        guard let id=body["id"] as? String,(8...80).contains(id.count),id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { throw CircuitError.message("Invalid component identifier.") }
        let index=entries.firstIndex { $0["id"] as? String == id }
        if action == "read",let index { return ["entry":entries[index]] }
        let previous=index.map { entries[$0] }
        if let revision=previous?["revision"] as? Int,revision != body["revision"] as? Int { throw CircuitError.message("This component changed. Refresh the library before saving.") }
        if action == "check" { guard index != nil else { throw CircuitError.message("Component no longer exists.") };return ["status":"ready"] }
        var entry=previous ?? ["id":id,"revision":0,"authorId":"local-owner","author":"Local","createdAt":ISO8601DateFormatter().string(from:Date())]
        switch action {
        case "save":
            guard let definition=body["definition"] as? [String:Any],let symbol=definition["symbol"] as? [String:Any],symbol["name"] is String else { throw CircuitError.message("Invalid component definition.") }
            entry["definition"]=definition;entry["circuit"]=body["circuit"];entry["status"]="shared"
        case "delete":guard index != nil else { throw CircuitError.message("Component no longer exists.") };entry["status"]="deleted"
        case "restore":guard index != nil else { throw CircuitError.message("Component no longer exists.") };entry["status"]="shared"
        default:throw CircuitError.message("Unsupported component library command.")
        }
        entry["revision"]=(previous?["revision"] as? Int ?? 0)+1;entry["updatedAt"]=ISO8601DateFormatter().string(from:Date())
        guard try JSONSerialization.data(withJSONObject:entry).count <= 160_000 else { throw CircuitError.message("Component exceeds the library size limit.") }
        if let index { entries[index]=entry } else { entries.append(entry) }
        try JSONSerialization.data(withJSONObject:entries,options:.sortedKeys).write(to:url,options:.atomic)
        return ["entry":entry]
    }
}
#endif
