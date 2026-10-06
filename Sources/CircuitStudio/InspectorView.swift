import SwiftUI

struct InspectorView: View {
    @Bindable var store: EditorStore
    @State private var showPrivacy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Text("Inspector").font(.system(size: 16, weight: .semibold)); Spacer(); Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary) }.padding(.bottom, 6)
                if store.selection.count > 1 {
                    Text("\(store.selection.count) objects").font(.title3)
                    inspectorSection("Alignment") { Button("Align horizontally") { store.align("horizontal") }; Button("Align vertically") { store.align("vertical") }; Button("Distribute horizontally") { store.distribute("horizontal") }; Button("Distribute vertically") { store.distribute("vertical") }; Button("Duplicate selection") { store.duplicateSelection() }; Button("Delete selection", role: .destructive) { store.deleteSelection() } }
                } else if let figure = store.selectedFigure {
                    FigureInspector(store: store, figure: figure)
                } else if let connector = store.selectedConnector {
                    ConnectorInspector(store: store, connector: connector)
                } else if let c = store.selectedComponent {
                    HStack(spacing: 15) { SymbolPreview(kind: c.kind, theme: store.circuit.theme).frame(width: 48, height: 60).foregroundStyle(StudioStyle.accent); VStack(alignment: .leading, spacing: 5) { Text(c.name).font(.system(size: 24, weight: .medium)); Text(c.kind.title).font(.system(size: 12)).foregroundStyle(.secondary) } }
                    Divider()
                    inspectorSection("Identity") { CommitField("Reference", value: c.name) { v in store.updateComponent(c.id) { $0.name = v } } }
                    inspectorSection(c.kind.isMOS ? "Device parameters" : "Parameters") {
                        if c.kind.isMOS {
                            ForEach([("model", "Model"), ("W", "Width"), ("L", "Length"), ("M", "Multiplicity"), ("NF", "Fingers")], id: \.0) { key, title in CommitField(title, value: c.parameters[key] ?? "") { value in store.updateComponent(c.id) { $0.parameters[key] = value } } }
                            Picker("Body", selection: Binding(get: { c.parameters["bulk"] ?? "source" }, set: { value in store.updateComponent(c.id) { $0.parameters["bulk"] = value } })) { Text("Tied to source").tag("source"); Text("External terminal").tag("external") }.font(.system(size: 12))
                        } else {
                            ForEach(c.parameters.keys.sorted(), id: \.self) { key in CommitField(parameterTitle(key, kind: c.kind), value: c.parameters[key] ?? "") { value in store.updateComponent(c.id) { $0.parameters[key] = value } } }
                            if c.parameters.isEmpty { Text("This symbol has no simulation parameters.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    inspectorSection("Annotation") {
                        Toggle("Show reference", isOn: Binding(get: { c.showName }, set: { v in store.updateComponent(c.id) { $0.showName = v } }))
                        Toggle("Show value", isOn: Binding(get: { c.showValue }, set: { v in store.updateComponent(c.id) { $0.showValue = v } }))
                    }
                    inspectorSection("Transform") {
                        HStack { Button { store.transformSelection("Rotate") } label: { Label("Rotate", systemImage: "rotate.right") }; Button { store.transformSelection("Flip horizontal") } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help("Flip horizontal"); Button { store.transformSelection("Flip vertical") } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }.help("Flip vertical") }.buttonStyle(.bordered).controlSize(.small)
                        Text("\(c.rotation)° · X \(Int(c.position.x)) · Y \(Int(c.position.y))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if let op = store.simulationResult?.operatingPoints[c.name.uppercased()] { inspectorSection("Operating point") { ForEach(op.keys.sorted(), id: \.self) { key in HStack { Text(key); Spacer(); Text(EngineeringUnits.format(op[key]!)).monospacedDigit() } } } }
                    Button(role: .destructive) { store.deleteSelection() } label: { Label("Delete component", systemImage: "trash") }.font(.system(size: 12)).buttonStyle(.borderless)
                } else if let label = store.selectedLabel {
                    inspectorSection("Net label") {
                        CommitField("Text", value: label.text) { text in store.transaction("Edit label") { if let i = $0.labels.firstIndex(where: { $0.id == label.id }) { $0.labels[i].text = text } } }
                        Text("Use V_{OUT}, g_m or \\mu for mathematical labels.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Electrical net label", isOn: Binding(get: { label.isNet }, set: { v in store.transaction("Change label type") { if let i = $0.labels.firstIndex(where: { $0.id == label.id }) { $0.labels[i].isNet = v } } }))
                    }
                    Button("Delete label", role: .destructive) { store.deleteSelection() }
                } else if store.selectedWire != nil {
                    inspectorSection("Wire") { Text("Orthogonal route").font(.callout); Text("Attached endpoints follow their components. Bare crossings remain electrically separate; endpoints form junctions.").font(.caption).foregroundStyle(.secondary) }
                    Button("Delete wire", role: .destructive) { store.deleteSelection() }
                } else {
                    VStack(alignment: .leading, spacing: 8) { Image(systemName: "doc.text.image").font(.system(size: 30, weight: .light)).foregroundStyle(StudioStyle.accent); Text(store.selection.count > 1 ? "\(store.selection.count) objects" : "Your next idea,\nbeautifully drawn.").font(.system(size: 20, weight: .medium)).lineSpacing(3); Text("Select an object to edit its properties.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    Divider()
                    inspectorSection("Document") { CommitField("Title", value: store.circuit.title) { title in store.transaction("Rename document") { $0.title = title } }; Picker("Symbol style", selection: Binding(get: { store.circuit.theme }, set: { theme in store.transaction("Change symbol style") { $0.theme = theme } })) { ForEach(SymbolTheme.allCases, id: \.self) { Text($0.rawValue).tag($0) } }; Picker("Diagram mode", selection: Binding(get: { store.circuit.mode }, set: { mode in store.transaction("Change diagram mode") { $0.mode = mode } })) { ForEach(DiagramMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } } }
                    inspectorSection("Canvas") { Toggle("Show grid", isOn: $store.showGrid); Toggle("Snap to grid", isOn: $store.snapEnabled); Button { store.cleanUp() } label: { Label("Clean up circuit", systemImage: "sparkles") }.buttonStyle(.bordered).controlSize(.small) }
                    if store.selection.count > 1 { inspectorSection("Alignment") { Button("Align horizontally") { store.align("horizontal") }; Button("Align vertically") { store.align("vertical") }; Button("Duplicate selection") { store.duplicateSelection() } } }
                    if store.supportsSimulation { inspectorSection("Simulation") { HStack { Text("Analysis"); Spacer(); Text(store.circuit.simulation.analysis == .ac ? "AC" : store.circuit.simulation.analysis.rawValue).foregroundStyle(.secondary) }; Button("Configure analysis…") { store.showSimulationSettings = true }; Button("Model library…") { store.showModels = true }; if store.simulationResult?.analysis == .op { Toggle("Annotate operating points", isOn: $store.annotateOP) } } }
                    inspectorSection("Quick start") { shortcut(store.supportsSimulation ? "Add component" : "Add shape or port", "A"); shortcut(store.supportsSimulation ? "Draw wire" : "Draw connector", "W"); shortcut("Rotate", "R"); shortcut("Fit to canvas", "F") }
                }
                Divider()
                Button("Privacy policy & acknowledgements") { showPrivacy = true }
                    .font(.footnote).buttonStyle(.borderless)
            }.font(.system(size: 12)).padding(22)
        }.background(.regularMaterial)
            .sheet(isPresented: $showPrivacy) { PrivacyView() }
    }
    func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 12) { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary); content() } }
    func shortcut(_ title: String, _ key: String) -> some View { HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(key).font(.system(size: 10, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 3).background(.quaternary, in: RoundedRectangle(cornerRadius: 4)) } }
    func parameterTitle(_ key: String, kind: ComponentKind) -> String { if key == "value" { return kind == .resistor ? "Resistance" : [.capacitor, .polarizedCapacitor].contains(kind) ? "Capacitance" : "Value" }; return ["ac": "AC magnitude", "model": "Model", "amplitude": "Amplitude", "frequency": "Frequency", "high": "High level", "width": "Pulse width", "period": "Period", "gain": "Open-loop gain"][key] ?? key }
}
struct CommitField: View {
    var title: String; var value: String; var commit: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool
    init(_ title: String, value: String, commit: @escaping (String) -> Void) { self.title = title; self.value = value; self.commit = commit; _draft = State(initialValue: value) }
    var body: some View { HStack(spacing: 10) { Text(title).foregroundStyle(.secondary); Spacer(minLength: 4); TextField(title, text: $draft).font(.system(size: 12, design: .monospaced)).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(maxWidth: 125).focused($focused).onSubmit { if draft != value { commit(draft) } }.onChange(of: focused) { _, v in if !v && draft != value { commit(draft) } }.onChange(of: value) { _, v in draft = v } }.accessibilityElement(children: .contain) }
}
