#if os(macOS)
import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// Native I/O boundary for the offline editor. No caller-supplied filesystem paths are accepted.
@MainActor final class EngineeringFiles {
    struct Recent:Codable { var id:String;var name:String;var path:String;var bookmark:Data;var revision:Int;var digest:String }
    private var recent:[Recent]
    private let root:URL
    private let defaults:UserDefaults
    init(directory:URL? = nil,defaults:UserDefaults = .standard) {
        self.defaults=defaults
        recent=(defaults.data(forKey:"engineering-recent").flatMap { try? JSONDecoder().decode([Recent].self,from:$0) }) ?? []
        root=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CircuitStudio/Engineering",isDirectory:true)
    }
    private func remember() throws { defaults.set(try JSONEncoder().encode(recent),forKey:"engineering-recent") }
    private func digest(_ data:Data)->String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private func binding(_ file:Recent)->[String:Any] { ["id":file.id,"name":file.name,"path":file.path,"revision":file.revision,"byteDigest":file.digest] }
    private func resolve(_ file:Recent)throws->URL {
        var stale=false
        return try URL(resolvingBookmarkData:file.bookmark,options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&stale)
    }
    private func selectedFile(_ url:URL,existing:Recent?,data:Data)throws->Recent {
        Recent(id:existing?.id ?? UUID().uuidString,name:url.lastPathComponent,path:url.path,bookmark:try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil),revision:(existing?.revision ?? 0)+1,digest:digest(data))
    }
    private func text(_ body:[String:Any],_ key:String,limit:Int)throws->String {
        guard let text=body[key] as? String,text.utf8.count <= limit else { throw CircuitError.message("Invalid or oversized \(key).") };return text
    }
    private func name(_ raw:String,fallback:String)->String {
        let value=URL(fileURLWithPath:raw).lastPathComponent.trimmingCharacters(in:.whitespacesAndNewlines)
        return value.isEmpty ? fallback : String(value.prefix(180))
    }
    func openProject(_ url:URL,previous:Recent? = nil)throws->[String:Any] {
        let access=url.startAccessingSecurityScopedResource();defer {if access {url.stopAccessingSecurityScopedResource()}}
        let contents=try EngineeringProjectFile.read(url)
        let file=try selectedFile(url,existing:previous ?? recent.first{$0.path==url.path},data:contents.sourceData)
        recent.removeAll{$0.id==file.id || $0.path==file.path};recent.insert(file,at:0);recent=Array(recent.prefix(30));try remember()
        return ["status":"opened","file":binding(file),"text":contents.text,"importedLegacy":contents.importedLegacy]
    }
    func handle(_ action:String,payload:[String:Any])throws->[String:Any] {
        switch action {
        case "project-recent":return ["files":recent.map { ["id":$0.id,"name":$0.name,"path":$0.path] }]
        case "project-forget":recent.removeAll { $0.id == payload["id"] as? String };try remember();return ["status":"done"]
        case "project-open":
            let old=recent.first { $0.id == payload["id"] as? String }
            let url:URL
            if let old { url=try resolve(old) }
            else {
                let panel=NSOpenPanel();panel.title="打开工程";panel.allowedContentTypes=[.json,.circuit];panel.canChooseDirectories=false;panel.canChooseFiles=true;panel.allowsMultipleSelection=false
                guard panel.runModal() == .OK,let selected=panel.url else { return ["status":"cancelled"] };url=selected
            }
            return try openProject(url,previous:old)
        case "project-save":
            let text=try text(payload,"text",limit:20_000_000),data=Data(text.utf8)
            guard let project=try JSONSerialization.jsonObject(with:data) as? [String:Any],project["documents"] is [[String:Any]] || (project["schema"] as? String == "circuitstudio-project-v1" && project["cells"] is [[String:Any]]) else { throw CircuitError.message("Invalid engineering project.") }
            let bound=payload["binding"] as? [String:Any]
            let old=recent.first { $0.id == bound?["id"] as? String }
            var saveAs=payload["saveAs"] as? Bool ?? false
            if let old,!saveAs {
                let existing=try resolve(old),access=existing.startAccessingSecurityScopedResource();defer{if access{existing.stopAccessingSecurityScopedResource()}}
                saveAs=try EngineeringProjectFile.read(existing).importedLegacy
            }
            let url:URL
            if let old,!saveAs { url=try resolve(old) }
            else {
                let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue=name(payload["name"] as? String ?? "",fallback:"Project.circuitstudio.json")
                guard panel.runModal() == .OK,let selected=panel.url else { return ["status":"cancelled"] };url=selected
            }
            let access=url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let old,!saveAs {
                guard let expected=bound?["byteDigest"] as? String,expected == digest(try Data(contentsOf:url)),bound?["revision"] as? Int == old.revision else { return ["status":"conflict","message":"The file changed outside this window. Reopen it or save an independent copy."] }
            }
            try data.write(to:url,options:.atomic)
            let file=try selectedFile(url,existing:saveAs ? nil : old,data:data)
            recent.removeAll { $0.id == file.id || $0.path == file.path };recent.insert(file,at:0);recent=Array(recent.prefix(30));try remember()
            return ["status":"saved","file":binding(file)]
        case "export":
            let encoded=try text(payload,"data",limit:80_000_000)
            guard let bytes=Data(base64Encoded:encoded) else { throw CircuitError.message("Invalid export data.") }
            let mime=payload["mime"] as? String ?? "application/octet-stream"
            let type=UTType(mimeType:mime) ?? .data
            let panel=NSSavePanel();panel.allowedContentTypes=[type];panel.nameFieldStringValue=name(payload["name"] as? String ?? "",fallback:"Circuit")
            guard panel.runModal() == .OK,let url=panel.url else { return ["status":"cancelled"] }
            let access=url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } };try bytes.write(to:url,options:.atomic);return ["status":"saved"]
        case "clipboard-read":return ["text":NSPasteboard.general.string(forType:NSPasteboard.PasteboardType("com.circuitstudio.engineering-selection")) ?? NSPasteboard.general.string(forType:.string) ?? ""]
        case "clipboard-prepare":
            _ = try text(payload,"text",limit:20_000_000)
            return ["ticket":NSPasteboard.general.changeCount]
        case "clipboard":
            if let ticket=payload["ticket"] as? Int,ticket != NSPasteboard.general.changeCount { throw CircuitError.message("The clipboard changed. Copy your selection again.") }
            let item=NSPasteboardItem();var hasData=false
            if let value=payload["text"] as? String,value.utf8.count <= 20_000_000 {
                item.setString(value,forType:NSPasteboard.PasteboardType("com.circuitstudio.engineering-selection"));hasData=true
            }
            for (field,type) in [("png",NSPasteboard.PasteboardType.png),("svg",NSPasteboard.PasteboardType("public.svg-image"))] {
                if let encoded=payload[field] as? String {
                    guard encoded.utf8.count <= 60_000_000,let bytes=Data(base64Encoded:encoded),field != "png" || NSImage(data:bytes) != nil else { throw CircuitError.message("Invalid clipboard image.") }
                    item.setData(bytes,forType:type);if field == "png",let tiff=NSImage(data:bytes)?.tiffRepresentation{item.setData(tiff,forType:.tiff)};hasData=true
                }
            }
            guard hasData else { throw CircuitError.message("Nothing to copy.") }
            NSPasteboard.general.clearContents();guard NSPasteboard.general.writeObjects([item]) else { throw CircuitError.message("Could not write the clipboard.") };return ["status":"copied"]
        case "components":return try components(payload)
        default:throw CircuitError.message("Unsupported native command.")
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
