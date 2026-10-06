import SwiftUI

enum StudioStyle {
    static let accent = Color(red: 0.10, green: 0.51, blue: 0.45)
    static let secondaryAccent = Color(red: 0.27, green: 0.48, blue: 0.75)
    static let sideWidth: CGFloat = 232
}
struct WorkspaceView: View {
    @Binding var document: CircuitFile
    var fileURL: URL?
    @State private var store: EditorStore
    @Environment(\.undoManager) private var undoManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearance") private var appearance = "System"
    @State private var librarySheet = false; @State private var inspectorSheet = false
    init(document: Binding<CircuitFile>, fileURL: URL?) { _document = document; self.fileURL = fileURL; _store = State(initialValue: EditorStore(document.wrappedValue.circuit)) }
    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            let compact = geometry.size.width < 740 || UIDevice.current.userInterfaceIdiom == .phone
            #else
            let compact = geometry.size.width < 740
            #endif
            let waveformOnly = compact && geometry.size.height < 500 && store.showWaveforms
            HStack(spacing: 0) {
                if !compact && store.showLibrary { LibraryView(store: store).frame(width: StudioStyle.sideWidth); Divider() }
                VStack(spacing: 0) {
                    canvasHeader(compact: compact, inlineInspector: geometry.size.width > 1000)
                    if !waveformOnly { ZStack {
                        NativeCanvas(store: store)
                            .onPencilDoubleTap { _ in store.activateTool(store.tool == .select ? (store.supportsSimulation ? .wire : .connector) : .select) }
                            .onPencilSqueeze { phase in if case .ended = phase { store.showPalette = true } }
                            .accessibilityLabel("\(store.circuit.purpose.rawValue) drawing canvas")
                        VStack {
                            HStack { Label(store.circuit.purpose.rawValue, systemImage: store.supportsSimulation ? "point.3.connected.trianglepath.dotted" : "square.on.circle").font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: Capsule()); Spacer(); if store.circuit.mode == .publication { Label("Publication", systemImage: "book.closed").font(.caption).foregroundStyle(.secondary) } }.padding(18)
                            Spacer()
                            if let toast = store.toast { Text(toast).font(.callout).padding(.horizontal, 16).padding(.vertical, 9).glassEffect().transition(.opacity).task(id: toast) { try? await Task.sleep(for: .seconds(2.4)); if store.toast == toast { store.toast = nil } } }
                            if compact { phoneToolbar } else { canvasToolbar }
                            HStack {
                                Label(store.snapEnabled ? "Snap on" : "Snap off", systemImage: "dot.square").font(.system(size: 11))
                                Spacer()
                                Text(store.isPaperOnly ? "\(store.circuit.figures.count) shapes · \(store.circuit.figureConnectors.count) arrows" : "\(store.circuit.components.filter { !$0.kind.isConnection }.count) components · \(Connectivity(store.circuit).nets.count) nets").font(.system(size: 11, design: .monospaced))
                            }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
                        }.allowsHitTesting(true)
                    }.clipped() }
                    if store.showWaveforms, let result = store.simulationResult {
                        Divider()
                        #if os(macOS)
                        WaveformView(result: result, probes: store.circuit.simulation.probes, onClose: { store.showWaveforms = false }, onOpen: { store.openSimulationResult(inNewTab: $0) }).frame(maxHeight: 290)
                        #else
                        WaveformView(result: result, probes: store.circuit.simulation.probes, onClose: { store.showWaveforms = false }).frame(maxHeight: waveformOnly ? .infinity : (compact ? 245 : 290))
                        #endif
                    }
                }
                if !compact && store.showInspector && geometry.size.width > 1000 { Divider(); InspectorView(store: store).frame(width: 262) }
            }
            .background(.background)
            .onChange(of: geometry.size.width, initial: true) { _, _ in store.inspectorUsesSheet = compact || geometry.size.width <= 1000 }
            #if os(macOS)
            .toolbar { toolbar(compact: compact) }
            #endif
        }
        .navigationTitle(store.circuit.title)
        #if os(macOS)
        .frame(minWidth: 850, minHeight: 580)
        #endif
        .tint(StudioStyle.accent)
        .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
        .focusedSceneValue(\.circuitEditor, store)
        .onAppear {
            store.undoManager = undoManager
            #if CIRCUITSTUDIO_PREVIEW
            if ProcessInfo.processInfo.arguments.contains("--run-analysis") { store.runSimulation() }
            #endif
        }
        .onChange(of: store.circuit) { _, newValue in document.circuit = newValue }
        .onChange(of: store.circuit.purpose) { _, _ in store.cancel(); store.showWaveforms = false; store.showSimulationSettings = false; store.showModels = false }
        .onChange(of: document.circuit) { _, newValue in if store.circuit != newValue { store.circuit = newValue; store.selection.removeAll() } }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.showWaveforms)
        .sheet(isPresented: $store.showPalette) { CommandPalette(store: store) }
        .sheet(isPresented: $store.showTemplates) { TemplateBrowser(store: store) }
        .sheet(isPresented: $store.showExport) { ExportView(store: store) }
        .sheet(isPresented: $store.showImport) { ImportView(store: store) }
        .sheet(isPresented: $store.showSimulationSettings) { SimulationSettingsView(store: store) }
        .sheet(isPresented: $store.showModels) { ModelLibraryView(store: store) }
        .sheet(isPresented: $librarySheet) { NavigationStack { LibraryView(store: store).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { librarySheet = false } } } }.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $inspectorSheet) { NavigationStack { InspectorView(store: store).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { inspectorSheet = false } } } }.presentationDetents([.medium, .large]) }
        .onChange(of: store.inspectorRequested) { _, value in if value { inspectorSheet = true; store.inspectorRequested = false } }
        .alert("Circuit needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .alert("Add net label", isPresented: Binding(get: { store.labelPoint != nil }, set: { if !$0 { store.labelPoint = nil } })) { TextField("V_{OUT}", text: $store.labelText); Button("Add") { store.addLabel() }; Button("Cancel", role: .cancel) { store.labelPoint = nil } } message: { Text("Use subscripts such as V_{IN}. Identical labels connect electrically.") }
        .userActivity("com.circuitstudio.edit") { activity in activity.title = store.circuit.title; activity.isEligibleForHandoff = fileURL != nil; if let fileURL { activity.userInfo = ["documentURL": fileURL.absoluteString] } }
        .onContinueUserActivity("com.circuitstudio.edit") { activity in if let value = activity.userInfo?["documentURL"] as? String, let url = URL(string: value) { openDocument(url) } }
    }
    func canvasHeader(compact: Bool, inlineInspector: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.circuit.title).font(.system(size: compact ? 18 : 22, weight: .semibold)).lineLimit(1)
                Text(store.circuit.purpose.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            Picker("Canvas mode", selection: Binding(get: { store.circuit.purpose }, set: { store.setPurpose($0) })) {
                ForEach(CanvasPurpose.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: compact ? 205 : 230).help("Schematic runs simulations. Illustration draws diagrams and figures.")
            if !compact {
                Menu {
                    Picker("Diagram mode", selection: Binding(get: { store.circuit.mode }, set: { mode in store.transaction("Change diagram mode") { $0.mode = mode } })) { ForEach(DiagramMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                } label: { Label(store.circuit.mode == .standard ? "Academic" : store.circuit.mode.rawValue, systemImage: "book.closed").font(.system(size: 12, weight: .medium)) }.menuStyle(.borderlessButton).fixedSize()
            }
          }
          #if os(iOS)
          HStack(spacing: 10) {
              if !store.isPaperOnly { analysisSelector.buttonStyle(.glass); runButton.buttonStyle(.glassProminent) }
              else { figureMenu.buttonStyle(.glass) }
              Button { store.showExport = true } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.glass).accessibilityLabel("Export circuit")
              Spacer(minLength: 8)
              Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.glass).disabled(!store.canUndo).accessibilityLabel("Undo")
              if !compact {
                  Button { store.showLibrary.toggle() } label: { Image(systemName: "sidebar.left") }.buttonStyle(.glass).accessibilityLabel("Toggle library")
                  Button { if inlineInspector { store.showInspector.toggle() } else { inspectorSheet = true } } label: { Image(systemName: "sidebar.right") }.buttonStyle(.glass).accessibilityLabel("Inspector")
              }
          }.controlSize(.small)
          #endif
        }.padding(.horizontal, compact ? 20 : 28).padding(.vertical, 20).background(.background)
    }
    private var analysisSelector: some View {
        Menu { ForEach(Analysis.allCases, id: \.self) { analysis in Button(analysis.rawValue) { store.transaction("Change analysis") { $0.simulation.analysis = analysis } } }; Divider(); Button("Simulation settings…") { store.showSimulationSettings = true } } label: { Text(store.circuit.simulation.analysis == .ac ? "AC" : store.circuit.simulation.analysis == .tran ? "TRAN" : store.circuit.simulation.analysis == .dc ? "DC" : "OP").font(.system(size: 12, weight: .medium, design: .monospaced)) }.accessibilityLabel("Simulation analysis")
    }
    private var runButton: some View {
        Button { store.runSimulation() } label: { if store.isSimulating { ProgressView().controlSize(.small) } else { Label("Run", systemImage: "play.fill") } }.disabled(store.isSimulating).help("Run simulation · ⌘↵").accessibilityLabel("Run simulation").keyboardShortcut(.return, modifiers: .command)
    }
    var canvasToolbar: some View {
        HStack(spacing: 4) {
            ForEach(store.availableTools) { tool in toolButton(tool) }
            figureMenu
            Divider().frame(height: 24).padding(.horizontal, 8)
            Button { store.changeZoom(store.zoom / 1.2) } label: { Image(systemName: "minus").frame(width: 28, height: 32) }.help("Zoom out")
            Button { store.fit() } label: { Text("\(Int(store.zoom * 100))%").font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 48) }.help("Fit circuit · F")
            Button { store.changeZoom(store.zoom * 1.2) } label: { Image(systemName: "plus").frame(width: 28, height: 32) }.help("Zoom in")
        }.buttonStyle(.plain).padding(8).glassEffect(.regular, in: Capsule()).padding(.top, 12)
    }
    var phoneToolbar: some View {
        HStack(spacing: 4) {
            Button { librarySheet = true } label: { Image(systemName: "square.grid.2x2").frame(width: 40, height: 40) }.accessibilityLabel("Component library")
            toolButton(.select); if store.supportsSimulation { toolButton(.wire) }; toolButton(.connector)
            figureMenu
            Button { inspectorSheet = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 40, height: 40) }.accessibilityLabel("Inspector")
            Button { store.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 40, height: 40) }.accessibilityLabel("Fit circuit")
        }.buttonStyle(.plain).padding(6).glassEffect(.regular, in: Capsule())
    }
    var figureMenu: some View {
        Menu {
            Button("Search components and shapes…") { store.showPalette = true }
            Section("Paper shapes") { ForEach(FigureKind.allCases) { kind in Button { store.insertFigure(kind) } label: { Label(kind.rawValue, systemImage: kind.icon) } } }
            Section("Connectors") { Button("Draw arrow") { store.cancel(); store.tool = .connector }; Picker("New arrow route", selection: $store.connectorRoute) { ForEach(FigureRoute.allCases, id: \.self) { Text($0.rawValue).tag($0) } } }
            Section("Paper templates") { ForEach(PaperExample.allCases) { example in Button(example.rawValue) { store.insertPaperExample(example) } } }
        } label: { Image(systemName: "plus").frame(width: 40, height: 36) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Add shapes and components")
    }
    func toolButton(_ tool: CanvasTool) -> some View {
        Button { store.activateTool(tool) } label: { Image(systemName: tool.icon).font(.system(size: 16, weight: .medium)).frame(width: 40, height: 36).foregroundStyle(store.tool == tool ? StudioStyle.accent : Color.primary).background(store.tool == tool ? StudioStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12)) }.help("\(tool.rawValue) · \(tool.shortcut)").accessibilityLabel(tool.rawValue).accessibilityAddTraits(store.tool == tool ? .isSelected : [])
    }
    #if os(macOS)
    @ToolbarContentBuilder func toolbar(compact: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) { Button { if compact { librarySheet = true } else { store.showLibrary.toggle() } } label: { Image(systemName: "sidebar.left") }.help("Toggle library") }
        ToolbarItemGroup(placement: .primaryAction) {
            if !compact { Button { store.showTemplates = true } label: { Image(systemName: "rectangle.stack.badge.plus") }.help("Circuit templates"); Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!store.canUndo).help("Undo") }
            if !store.isPaperOnly { analysisSelector; runButton }
            Button { store.showExport = true } label: { Image(systemName: "square.and.arrow.up") }.help("Export circuit")
            if !compact { Button { store.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Toggle inspector") }
        }
    }
    #endif
    func openDocument(_ url: URL) {
        #if os(macOS)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in if let error { store.error = error.localizedDescription } }
        #else
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { let wrapper = try FileWrapper(url: url); guard let data = wrapper.fileWrappers?["document.json"]?.regularFileContents else { return }; store.transaction("Continue document") { $0 = (try? CircuitArchive.decode(data).circuit) ?? $0 }; store.toast = "Handoff content opened. Save this document to continue." } catch { store.error = error.localizedDescription }
        #endif
    }
}
