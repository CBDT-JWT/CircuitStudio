import SwiftUI

#if os(iOS)
/// iPad keyboard/File commands must use the same editor as touch and Files opens.
struct EngineeringMobileCommands:Commands {
    @FocusedValue(\.engineeringEditor) private var workspace
    var body:some Commands {
        CommandGroup(replacing:.newItem) {
            Button("新建电路"){workspace?.fileCommand("new")}.keyboardShortcut("n")
            Button("打开工程…"){workspace?.fileCommand("open")}.keyboardShortcut("o")
        }
        CommandGroup(replacing:.saveItem) {
            Button("保存"){workspace?.fileCommand("save")}.keyboardShortcut("s")
            Button("另存为…"){workspace?.fileCommand("save-as")}.keyboardShortcut("s",modifiers:[.command,.shift])
        }
    }
}
#endif

struct StudioCommands: Commands {
    @FocusedValue(\.circuitEditor) private var store
    #if os(macOS)
    var engineeringWorkspace:EngineeringWorkspace? = nil
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.engineeringEditor) private var focusedEngineering
    private var engineering:EngineeringWorkspace? { focusedEngineering ?? engineeringWorkspace }
    #endif
    var body: some Commands {
        #if os(macOS) && canImport(Sparkle) && !APP_STORE
        CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        #endif
        #if os(macOS)
        CommandGroup(replacing:.newItem) {
            Button("New circuit") { if let engineering {engineering.fileCommand("new")}else{NSDocumentController.shared.newDocument(nil)} }.keyboardShortcut("n")
            Button("Open…") { if let engineering {engineering.fileCommand("open")}else{NSDocumentController.shared.openDocument(nil)} }.keyboardShortcut("o")
        }
        CommandGroup(replacing:.saveItem) {
            Button("Save") { if let engineering {engineering.fileCommand("save")}else{NSDocumentController.shared.currentDocument?.save(nil)} }.keyboardShortcut("s")
            Button("Save As…") { if let engineering {engineering.fileCommand("save-as")}else{NSDocumentController.shared.currentDocument?.saveAs(nil)} }.keyboardShortcut("s",modifiers:[.command,.shift])
        }
        CommandGroup(after: .newItem) { Button("Engineering workspace…") { openWindow(id:"engineering") }.keyboardShortcut("n",modifiers:[.command,.option]) }
        #endif
        CommandGroup(after: .newItem) { Button("Circuit templates…") { store?.showTemplates = true }; Button("Import CircuitikZ…") { store?.showImport = true } }
        CommandGroup(replacing: .pasteboard) { Button("Cut") { if let store { StudioClipboard.cutSelection(store) } else { nativeClipboard("cut:") } }.keyboardShortcut("x").disabled(store?.selection.isEmpty ?? false); Button("Copy selection as PNG") { if let store { StudioClipboard.copyAs(.png,store:store) } else { nativeCopyPNG() } }.keyboardShortcut("c",modifiers:[.command,.shift]).disabled(store?.selection.isEmpty ?? false); Button("Copy") { if let store { StudioClipboard.copySelection(store) } else { nativeClipboard("copy:") } }.keyboardShortcut("c").disabled(store?.selection.isEmpty ?? false); Button("Paste") { if let store { StudioClipboard.pasteSelection(store) } else { nativeClipboard("paste:") } }.keyboardShortcut("v"); Button("Duplicate") { store?.duplicateSelection() }.keyboardShortcut("d").disabled(store?.selection.isEmpty ?? true); Button("Delete") { store?.deleteSelection() }.keyboardShortcut(.delete, modifiers: []).disabled(store?.selection.isEmpty ?? true); Divider(); Menu("Copy as") { ForEach(ExportFormat.allCases.filter { store?.supportsSimulation != false || $0 != .spice }) { format in Button(format.rawValue) { if let store { StudioClipboard.copyAs(format, store: store) } } } } }
        CommandGroup(replacing: .help) { Button("Keyboard & canvas controls…") { store?.showShortcuts = true }.keyboardShortcut("/", modifiers:[.command]) }
        CommandMenu("Circuit") { Button("Add component…") { store?.paletteQuery = ""; store?.showPalette = true }.keyboardShortcut("i", modifiers: []).disabled(store == nil); Button("Command palette…") { store?.paletteQuery = ""; store?.showPalette = true }.keyboardShortcut("p"); Divider(); Button("Rotate") { store?.transformSelection("Rotate") }.keyboardShortcut("r", modifiers: []).disabled(store == nil); Button("Flip horizontal") { store?.transformSelection("Flip horizontal") }.keyboardShortcut("r", modifiers: [.shift]).disabled(store == nil); Button("Flip vertical") { store?.transformSelection("Flip vertical") }.keyboardShortcut("r"); Divider(); Button("Global supplies…") { store?.selection.removeAll(); store?.revealInspector() }; Button("Clean up circuit") { store?.cleanUp() }; Button("Renumber circuit") { store?.renumber() }; Button("Select all") { if let store { store.selection = store.circuit.objectIDs } else { nativeClipboard("selectAll:") } }.keyboardShortcut("a") }
        CommandMenu("Paper figure") { ForEach(FigureKind.allCases) { kind in Button(kind.rawValue) { store?.insertFigure(kind) } }; Button("Draw arrow") { store?.cancel(); store?.tool = .connector }.keyboardShortcut("l", modifiers: [.shift]); Divider(); Button("Align horizontally") { store?.align("horizontal") }; Button("Align vertically") { store?.align("vertical") }; Button("Distribute horizontally") { store?.distribute("horizontal") }; Button("Distribute vertically") { store?.distribute("vertical") }; Divider(); ForEach(PaperExample.allCases) { example in Button(example.rawValue) { store?.insertPaperExample(example) } } }
        CommandMenu("Canvas mode") { ForEach(CanvasPurpose.allCases) { purpose in Button(purpose.rawValue) { store?.setPurpose(purpose) }.disabled(store == nil) } }
        CommandMenu("Simulation") {
            Button("Run simulation") { runSimulation() }.keyboardShortcut(.return).disabled(!canSimulate)
            Button("Configure analysis…") { configureSimulation() }.disabled(!canSimulate)
            Button("Model library…") { if let store { store.showModels = true } else { configureSimulation() } }.disabled(!canSimulate)
            Button("Show waveforms") { store?.showWaveforms.toggle() }.disabled(store?.simulationResult == nil)
            Button("Annotate operating points") { store?.annotateOP.toggle() }.disabled(store?.simulationResult?.analysis != .op)
        }
        CommandGroup(after: .toolbar) { Button("Toggle grid") { store?.showGrid.toggle() }; Button("Snap to grid") { store?.snapEnabled.toggle() }; Button("Fit circuit") { store?.fit() }.keyboardShortcut("0"); Button("Zoom in") { if let store { store.changeZoom(store.zoom * 1.2) } }.keyboardShortcut("+"); Button("Zoom out") { if let store { store.changeZoom(store.zoom / 1.2) } }.keyboardShortcut("-") }
        #if os(macOS)
        CommandMenu("电路图导出") {
            Menu("Virtuoso 风格") {
                Button("导出 PNG…"){engineering?.exportImage("png",style:"virtuoso")}.disabled(engineering == nil)
                Button("导出 SVG…"){engineering?.exportImage("svg",style:"virtuoso")}.disabled(engineering == nil)
                Button("复制为 PNG"){engineering?.exportImage("png",style:"virtuoso",copy:true)}.disabled(engineering == nil)
            }
            Menu("当前配色") {
                Button("导出 PNG…"){engineering?.exportImage("png",style:"current")}.disabled(engineering == nil)
                Button("导出 SVG…"){engineering?.exportImage("svg",style:"current")}.disabled(engineering == nil)
            }
        }
        #endif
        CommandGroup(after: .importExport) { Button("Export circuit…") { store?.showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift]) }
    }
    private func nativeCopyPNG() {
        #if os(macOS)
        engineering?.copyPNG()
        #endif
    }
    private var canSimulate:Bool {
        #if os(macOS)
        return store?.supportsSimulation == true || engineering != nil
        #else
        return store?.supportsSimulation == true
        #endif
    }
    private func runSimulation() {
        if let store { store.runSimulation() }
        else {
        #if os(macOS)
            engineering?.runSimulation()
        #endif
        }
    }
    private func configureSimulation() {
        if let store { store.showSimulationSettings=true }
        else {
        #if os(macOS)
            engineering?.simulate()
        #endif
        }
    }
    private func nativeClipboard(_ selector:String) {
        #if os(macOS)
        NSApp.sendAction(Selector(selector),to:nil,from:nil)
        #endif
    }
}
