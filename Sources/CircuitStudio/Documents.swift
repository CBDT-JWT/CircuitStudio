import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let circuit = UTType(exportedAs: "com.circuitstudio.circuit", conformingTo: .package) }
struct CircuitFile: FileDocument {
    static var readableContentTypes: [UTType] { [.circuit] }
    var circuit: Circuit
    init(_ circuit: Circuit = Circuit()) { self.circuit = circuit }
    init(configuration: ReadConfiguration) throws {
        let wrapper = configuration.file
        guard let data = wrapper.fileWrappers?["document.json"]?.regularFileContents ?? wrapper.regularFileContents else { throw CircuitError.message("This circuit document has no document.json file.") }
        circuit = try CircuitArchive.decode(data).circuit
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var files = ["document.json": FileWrapper(regularFileWithContents: try CircuitArchive(circuit).encoded())]
        if let image = try? CircuitExport.raster(circuit, scale: 1, transparent: false) { files["preview.png"] = FileWrapper(regularFileWithContents: image) }
        return FileWrapper(directoryWithFileWrappers: files)
    }
}
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct EditorFocusKey: FocusedValueKey { typealias Value = EditorStore }
extension FocusedValues { var circuitEditor: EditorStore? { get { self[EditorFocusKey.self] } set { self[EditorFocusKey.self] = newValue } } }

#if !CIRCUITSTUDIO_PREVIEW
@main struct CircuitStudioApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) var delegate
    #endif
    var body: some Scene {
        DocumentGroup(newDocument: CircuitFile()) { file in WorkspaceView(document: file.$document, fileURL: file.fileURL) }
            .commands { StudioCommands() }
        #if os(macOS)
            .defaultSize(width: 1280, height: 820)
            .defaultLaunchBehavior(.suppressed)
        #endif
        #if os(macOS)
        Settings { StudioSettings().frame(width: 460, height: 370) }
        #endif
    }
}
#endif
#if os(macOS)
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        #if canImport(Sparkle) && !APP_STORE
        _ = AppUpdater.shared
        #endif
        // Let restored or explicitly opened documents win; otherwise start on a blank canvas.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.newDocument(nil)
            }
        }
    }
}
#endif
struct StudioSettings: View {
    @AppStorage("appearance") private var appearance = "System"
    @State private var showPrivacy = false
    var body: some View { Form {
        #if os(macOS) && canImport(Sparkle) && !APP_STORE
        UpdateSettings()
        #endif
        Picker("Appearance", selection: $appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }; Text("Circuit Studio uses native document storage. Save in iCloud Drive to sync across your Apple devices.").foregroundStyle(.secondary); Text("Built-in simulation: \(EmbeddedSpice.version)").font(.footnote); Button("Privacy policy") { showPrivacy = true }; DisclosureGroup("ngspice acknowledgements") { ScrollView { Text(ngspiceLicense).font(.system(size: 11)).textSelection(.enabled) }.frame(height: 120) } }.padding(24).sheet(isPresented: $showPrivacy) { PrivacyView() } }
    private var ngspiceLicense: String { AppPrivacy.license }
}
