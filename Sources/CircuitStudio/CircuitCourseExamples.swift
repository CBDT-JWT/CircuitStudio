import SwiftUI
import WebKit
struct CircuitCourseCatalog:Decodable {
    struct Assignment:Decodable,Identifiable {var id:String;var chapter:String;var title:String;var pdf:String;var pages:[Int];var goals:[String];var assumptions:String;var optional:Bool;var caseIDs:[String]}
    struct Example:Decodable,Identifiable {
        struct Preset:Decodable {var title:String;var settings:SimulationSettings}
        var id:String;var assignmentID:String;var title:String;var runs:[Preset];var notes:String
    }
    var title:String;var assignments:[Assignment];var cases:[Example]
    static func bundled() throws -> Self {
        guard let root=Bundle.main.url(forResource:"EngineeringEditor",withExtension:nil) else{throw CircuitError.message("课程示例未安装。")}
        return try JSONDecoder().decode(Self.self,from:Data(contentsOf:root.appendingPathComponent("course-cad/catalog.json")))
    }
}
struct CircuitCourseExamples:View {
    let workspace:EngineeringWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var catalog:CircuitCourseCatalog?
    @State private var selected:String?
    @State private var caseID=""
    @State private var preset=0
    @State private var search=""
    @State private var busy=false
    @State private var error:String?
    private var assignment:CircuitCourseCatalog.Assignment? {catalog?.assignments.first{$0.id==selected}}
    private var examples:[CircuitCourseCatalog.Example] {catalog?.cases.filter{$0.assignmentID==selected} ?? []}
    private var example:CircuitCourseCatalog.Example? {examples.first{$0.id==caseID} ?? examples.first}
    var body:some View {
        NavigationSplitView {
            List(selection:$selected) {
                ForEach(["A1","A2"],id:\.self) {term in
                    Section(term=="A1" ? "A1 · 电阻与有源电路":"A2 · 动态与反馈电路") {
                        ForEach((catalog?.assignments ?? []).filter{$0.chapter.hasPrefix(term) && (search.isEmpty || ($0.chapter+$0.title).localizedCaseInsensitiveContains(search))}) {item in
                            VStack(alignment:.leading,spacing:4){Text(item.title).font(.callout);Text(item.chapter+(item.optional ? " · 选做":"")+" · \(item.caseIDs.count) 个配置").font(.caption).foregroundStyle(.secondary)}.padding(.vertical,3).tag(item.id)
                        }
                    }
                }
            }.searchable(text:$search,prompt:"搜索章节或电路").navigationSplitViewColumnWidth(min:240,ideal:285,max:330)
        } detail: {
            if let assignment {
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        VStack(alignment:.leading,spacing:8) {
                            Text(assignment.title).font(.title2.weight(.semibold))
                            Text(assignment.pdf+" · 第 "+assignment.pages.map(String.init).joined(separator:"、")+" 页").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if assignment.optional {Text("选做作业").font(.caption.weight(.medium)).foregroundStyle(StudioStyle.accent)}
                        }
                        VStack(alignment:.leading,spacing:9) {Text("观察与验证").font(.headline);ForEach(assignment.goals,id:\.self){Text("• "+$0).font(.callout).fixedSize(horizontal:false,vertical:true)}}
                        VStack(alignment:.leading,spacing:10) {
                            Text("电路与仿真配置").font(.headline)
                            Picker("电路配置",selection:$caseID) {ForEach(examples){Text($0.title).tag($0.id)}}
                            if let example {
                                Picker("打开后的分析",selection:$preset){ForEach(example.runs.indices,id:\.self){i in Text(example.runs[i].title).tag(i)}}
                                if !example.notes.isEmpty {Text(example.notes).font(.caption).foregroundStyle(.secondary)}
                            }
                        }
                        VStack(alignment:.leading,spacing:9){Text("原题条件与示例设定").font(.headline);Text(assignment.assumptions).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
                        Text("打开后可修改元件、连线和模型，使用仿真抽屉运行。每次打开会创建新的工程标签页。").font(.caption).foregroundStyle(.secondary)
                        if let error {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
                        HStack {if busy{ProgressView().controlSize(.small)};Button(busy ? "正在打开…":"打开可编辑电路") {Task{await open()}}.buttonStyle(.borderedProminent).disabled(busy || example==nil)}
                    }.padding(28).frame(maxWidth:760,alignment:.leading)
                }.id(assignment.id).onChange(of:selected){_,_ in caseID=examples.first?.id ?? "";preset=0;error=nil}.onChange(of:caseID){_,_ in preset=0}
            } else {ContentUnavailableView("课程 CAD 示例",systemImage:"square.stack.3d.up",description:Text(error ?? "选择章节中的一道作业开始。"))}
        }
        .toolbar {ToolbarItem(placement:.confirmationAction){Button("完成"){dismiss()}}}
        .frame(minWidth:600,minHeight:580).tint(StudioStyle.accent)
        .task {do{catalog=try .bundled();selected=workspace.courseExamples[workspace.chat.projectID]?.assignmentID ?? catalog?.assignments.first?.id;caseID=examples.first?.id ?? ""}catch{self.error=error.localizedDescription}}
    }
    private func open() async {
        guard let example else{return};busy=true;error=nil;defer{busy=false}
        do {
            guard let value=try await workspace.webView?.callAsyncJavaScript("return await window.circuitStudioLoadCourseCase(id,preset)",arguments:["id":example.id,"preset":preset],in:nil,contentWorld:.page) as? [String:Any],let session=value["sessionID"] as? String else{throw CircuitError.message("课程工程尚未准备好。")}
            workspace.courseExamples[session]=example;workspace.showDrawer=false;dismiss()
        }catch{self.error=(error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription}
    }
}
