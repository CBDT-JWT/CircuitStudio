import SwiftUI
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF", svg = "SVG", png = "PNG", jpeg = "JPEG", tiff = "TIFF", circuitikz = "CircuitikZ", spice = "SPICE netlist"
    var id: String { rawValue }
    var type: UTType { switch self { case .pdf: .pdf; case .svg: .svg; case .png: .png; case .jpeg: .jpeg; case .tiff: .tiff; case .circuitikz, .spice: .plainText } }
    var extensionName: String { switch self { case .circuitikz: "tex"; case .spice: "spice"; case .jpeg: "jpg"; default: rawValue.lowercased() } }
    var caption: String { switch self { case .pdf, .svg: "Resolution-independent vector artwork"; case .png, .jpeg, .tiff: "High-resolution raster image"; case .circuitikz: "Editable LaTeX circuit source"; case .spice: "Simulation-ready electrical netlist" } }
}
@MainActor enum StudioClipboard {
    static func copy(_ data: Data, type: UTType) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        if type == .plainText, let text = String(data: data, encoding: .utf8) { pasteboard.setString(text, forType: .string) }
        #else
        UIPasteboard.general.setItems([[type.identifier: data]])
        #endif
    }
    static func copySelection(_ store: EditorStore) { guard let data = store.selectionData() else { return }; copy(data, type: UTType(exportedAs: "com.circuitstudio.selection")) }
    static func pasteSelection(_ store: EditorStore) {
        #if os(macOS)
        store.paste(NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("com.circuitstudio.selection")))
        #else
        store.paste(UIPasteboard.general.data(forPasteboardType: "com.circuitstudio.selection"))
        #endif
    }
    static func copyAs(_ format: ExportFormat, store: EditorStore) {
        do { let data = try exportData(format, circuit: store.circuit, scale: 2, transparent: true); copy(data, type: format.type); store.toast = "Copied as \(format.rawValue)" } catch { store.error = error.localizedDescription }
    }
    static func exportData(_ format: ExportFormat, circuit: Circuit, scale: Double, transparent: Bool) throws -> Data {
        switch format {
        case .pdf: return try CircuitExport.pdf(circuit)
        case .svg: return Data(CircuitExport.svg(circuit, transparent: transparent).utf8)
        case .png, .jpeg, .tiff: return try CircuitExport.raster(circuit, scale: scale, transparent: transparent, type: format.type)
        case .circuitikz: return Data(try CircuitikZ.export(circuit).utf8)
        case .spice: return Data(try SPICENetlist.generate(circuit).utf8)
        }
    }
}
struct ExportView: View {
    @Bindable var store: EditorStore
    @State private var format: ExportFormat = .pdf; @State private var resolution = "2×"; @State private var customDPI = "300"; @State private var transparent = true
    @State private var exporting = false; @State private var file = ExportFile(Data()); @State private var shareURL: URL?; @State private var textPreview = ""
    var scale: Double { resolution == "1×" ? 1 : resolution == "2×" ? 2 : resolution == "4×" ? 4 : (Double(customDPI) ?? 300) / 72 }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                CircuitThumbnail(circuit: store.circuit).frame(height: 170).frame(maxWidth: .infinity).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                Picker("Format", selection: $format) { ForEach(ExportFormat.allCases.filter { store.supportsSimulation || $0 != .spice }) { Text($0.rawValue).tag($0) } }
                Text(format.caption).font(.caption).foregroundStyle(.secondary)
                if [.png, .jpeg, .tiff].contains(format) { Picker("Resolution", selection: $resolution) { ForEach(["1×", "2×", "4×", "Custom DPI"], id: \.self) { Text($0) } }.pickerStyle(.segmented); if resolution == "Custom DPI" { TextField("DPI", text: $customDPI).textFieldStyle(.roundedBorder) } }
                if [.png, .tiff, .svg].contains(format) { Toggle("Transparent background", isOn: $transparent) }
                if format == .circuitikz || format == .spice { ScrollView { Text(textPreview).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90).padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)) }
                HStack { Button { do { let data = try makeData(); StudioClipboard.copy(data, type: format.type); store.toast = "Copied as \(format.rawValue)"; store.showExport = false } catch { store.error = error.localizedDescription } } label: { Label("Copy \(format.rawValue)", systemImage: "doc.on.doc") }; Spacer(); if let shareURL { ShareLink(item: shareURL) { Label("Share", systemImage: "square.and.arrow.up") } }; Button("Save file…") { do { file = ExportFile(try makeData()); exporting = true } catch { store.error = error.localizedDescription } }.buttonStyle(.borderedProminent) }.controlSize(.large)
            }.padding(24).navigationTitle("Export circuit").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { store.showExport = false } } }
        }.frame(minWidth: 350, idealWidth: 530, minHeight: 430)
            .fileExporter(isPresented: $exporting, document: file, contentType: format.type, defaultFilename: "\(store.circuit.title).\(format.extensionName)") { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
            .task(id: "\(format.rawValue)-\(resolution)-\(customDPI)-\(transparent)") { textPreview = format == .circuitikz ? ((try? CircuitikZ.export(store.circuit))?.components(separatedBy: .newlines).dropFirst().joined(separator: "\n") ?? "") : ((try? SPICENetlist.generate(store.circuit)) ?? ""); do { let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(store.circuit.id.uuidString).\(format.extensionName)"); try makeData().write(to: url); shareURL = url } catch { shareURL = nil } }
    }
    func makeData() throws -> Data { if resolution == "Custom DPI" { guard let dpi = Double(customDPI), dpi > 0, dpi <= 2400 else { throw CircuitError.message("Enter a DPI between 1 and 2400.") } }; return try StudioClipboard.exportData(format, circuit: store.circuit, scale: scale, transparent: transparent) }
}
struct ImportView: View {
    @Bindable var store: EditorStore
    @State private var code = "\\begin{circuitikz}\n\\draw (0,0) to[R,l={10k}] (0,2);\n\\draw (0,0) node[ground]{};\n\\end{circuitikz}"
    var body: some View {
        NavigationStack { VStack(alignment: .leading, spacing: 16) { Text("Paste CircuitikZ").font(.title2.weight(.semibold)); Text("Import numeric coordinate pairs with R, C, L, V, sV, I, D, ground and simple wires. Circuit Studio exports preserve every editable property.").font(.callout).foregroundStyle(.secondary); TextEditor(text: $code).font(.system(size: 12, design: .monospaced)).frame(minHeight: 240) }.padding(24).navigationTitle("Import CircuitikZ").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.showImport = false } }; ToolbarItem(placement: .confirmationAction) { Button("Import") { do { let circuit = try CircuitikZ.importCode(code); store.transaction("Import CircuitikZ") { $0 = circuit }; store.selection.removeAll(); store.fit(); store.showImport = false } catch { store.error = error.localizedDescription } } } } }.frame(minWidth: 350, idealWidth: 620, minHeight: 420)
    }
}
