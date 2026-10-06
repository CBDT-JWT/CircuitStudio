import SwiftUI
import UniformTypeIdentifiers

struct SimulationSettingsView: View {
    @Bindable var store: EditorStore
    @State private var settings: SimulationSettings
    init(store: EditorStore) { self.store = store; _settings = State(initialValue: store.circuit.simulation) }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Analysis", selection: $settings.analysis) { ForEach(Analysis.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                switch settings.analysis {
                case .op: Text("Calculate node voltages, branch currents and MOS operating point parameters.").foregroundStyle(.secondary)
                case .ac: TextField("Start frequency (Hz)", text: $settings.start); TextField("Stop frequency (Hz)", text: $settings.stop); Stepper("\(settings.points) points / decade", value: $settings.points, in: 5...200, step: 5)
                case .dc: TextField("Source reference", text: $settings.source); TextField("Start voltage", text: $settings.dcStart); TextField("Stop voltage", text: $settings.dcStop); TextField("Voltage step", text: $settings.dcStep)
                case .tran: TextField("Time step", text: $settings.timeStep); TextField("Duration", text: $settings.duration)
                }
                Section("Voltage probes") { TextField("Comma-separated net names", text: Binding(get: { settings.probes.joined(separator: ", ") }, set: { settings.probes = $0.split(separator: ",").map { MathLabel.netName(String($0).trimmingCharacters(in: .whitespaces)) } })); Text("Use engineering units: 10k, 1u, 100Meg. SPICE M means milli.").font(.caption).foregroundStyle(.secondary) }
                #if !os(macOS)
                Text("On this device, the native solver supports linear RC circuits. MOS and other nonlinear devices use ngspice on Mac.").font(.caption).foregroundStyle(.secondary)
                #endif
            }.formStyle(.grouped).navigationTitle("Simulation settings").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.showSimulationSettings = false } }; ToolbarItem(placement: .confirmationAction) { Button("Apply") { do { _ = try SPICENetlist.directive(settings); store.transaction("Edit simulation settings") { $0.simulation = settings }; store.showSimulationSettings = false } catch { store.error = error.localizedDescription } } } }
        }.frame(minWidth: 350, idealWidth: 500, minHeight: 380, idealHeight: 460)
    }
}
struct ModelLibraryView: View {
    @Bindable var store: EditorStore
    @State private var text: String; @State private var importing = false
    init(store: EditorStore) { self.store = store; _text = State(initialValue: store.circuit.modelLibrary) }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) { Text("Custom device models").font(.title2.weight(.semibold)); Text("Paste .model definitions and continuation lines. Default Level-1 NMOS / PMOS models are included automatically.").font(.callout).foregroundStyle(.secondary); TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).frame(minHeight: 230); Button("Import .model / .spice file…") { importing = true } }.padding(24)
                .navigationTitle("Model library").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.showModels = false } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { do { _ = try SPICENetlist.validatedModels(text); store.transaction("Edit model library") { $0.modelLibrary = text }; store.showModels = false } catch { store.error = error.localizedDescription } } } }
        }.frame(minWidth: 360, idealWidth: 620, minHeight: 430)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data]) { result in do { let url = try result.get(), access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; text = try String(contentsOf: url, encoding: .utf8) } catch { store.error = error.localizedDescription } }
    }
}
