import SwiftUI
import ImageIO

struct PaletteItem: Identifiable { var id: String; var title: String; var subtitle: String; var kind: ComponentKind?; var pattern: CircuitTemplate?; var action: (() -> Void)? }
struct CommandPalette: View {
    @Bindable var store: EditorStore
    @FocusState private var focus: Bool
    @State private var selectedIndex = 0
    var items: [PaletteItem] {
        let components = ComponentKind.allCases.map { PaletteItem(id: $0.rawValue, title: $0.title, subtitle: $0.category, kind: $0) }
        let patterns = CircuitTemplate.allCases.filter { $0 != .blank }.map { PaletteItem(id: $0.rawValue, title: $0.rawValue, subtitle: "Editable circuit pattern", pattern: $0) }
        let commands = [PaletteItem(id: "run", title: "Run simulation", subtitle: store.circuit.simulation.analysis.rawValue, action: { store.runSimulation() }), PaletteItem(id: "export", title: "Export circuit", subtitle: "PDF, PNG, SVG, CircuitikZ, SPICE", action: { store.showExport = true }), PaletteItem(id: "grid", title: "Toggle grid", subtitle: "Canvas", action: { store.showGrid.toggle() }), PaletteItem(id: "clean", title: "Clean up circuit", subtitle: "Align and reroute", action: { store.cleanUp() }), PaletteItem(id: "fit", title: "Fit circuit", subtitle: "Canvas", action: { store.fit() })]
        let shapes = FigureKind.allCases.map { kind in PaletteItem(id: "figure-" + kind.rawValue, title: kind.rawValue, subtitle: "Paper figure shape", action: { store.insertFigure(kind, at: store.insertionPoint); store.insertionPoint = nil }) }
        let examples = PaperExample.allCases.map { example in PaletteItem(id: "paper-" + example.rawValue, title: example.rawValue, subtitle: "Editable paper figure", action: { store.insertPaperExample(example) }) }
        let query = store.paletteQuery.lowercased().replacingOccurrences(of: "add ", with: "")
        let available = components + (store.supportsSimulation ? patterns : []) + shapes + examples + commands.filter { store.supportsSimulation || $0.id != "run" }
        return available.filter { query.isEmpty || fuzzy(query, in: $0.title.lowercased()) || $0.subtitle.lowercased().contains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) { Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(StudioStyle.accent); TextField("Add a component or run a command…", text: $store.paletteQuery).textFieldStyle(.plain).font(.system(size: 17)).focused($focus).onSubmit { if !items.isEmpty { choose(items[min(selectedIndex, items.count - 1)]) } }; Button { store.showPalette = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain) }.padding(24)
            Divider()
            ScrollViewReader { proxy in ScrollView {
                LazyVStack(spacing: 3) { ForEach(Array(items.enumerated()), id: \.element.id) { index, item in Button { choose(item) } label: { HStack(spacing: 14) { if let kind = item.kind { SymbolPreview(kind: kind).frame(width: 38, height: 38) } else { Image(systemName: item.pattern != nil ? "square.stack.3d.up" : "command").frame(width: 38).foregroundStyle(StudioStyle.accent) }; VStack(alignment: .leading, spacing: 4) { Text(item.title).font(.system(size: 14, weight: .medium)); Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer(); if index == selectedIndex { Image(systemName: "return").foregroundStyle(.secondary).font(.caption) } }.padding(.horizontal, 14).padding(.vertical, 8).background(index == selectedIndex ? StudioStyle.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain).id(index) } }.padding(12)
                if items.isEmpty { ContentUnavailableView.search(text: store.paletteQuery) }
            }.onChange(of: selectedIndex) { _, value in proxy.scrollTo(value) } }
            Divider(); HStack { Text("↑ ↓ to navigate"); Spacer(); Text("↵ to insert") }.font(.system(size: 11)).foregroundStyle(.secondary).padding(16)
        }.frame(minWidth: 320, idealWidth: 520, maxWidth: 560, minHeight: 350, idealHeight: 460, maxHeight: 540).tint(StudioStyle.accent)
        .onAppear { focus = true }
        .onChange(of: store.paletteQuery) { _, _ in selectedIndex = 0 }
        .onKeyPress(.downArrow) { selectedIndex = min(items.count - 1, selectedIndex + 1); return .handled }
        .onKeyPress(.upArrow) { selectedIndex = max(0, selectedIndex - 1); return .handled }
    }
    func choose(_ item: PaletteItem) { store.showPalette = false; if let kind = item.kind { store.insert(kind, at: store.insertionPoint); store.insertionPoint = nil } else if let pattern = item.pattern { store.insertPattern(pattern) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { item.action?() } } }
    func fuzzy(_ query: String, in text: String) -> Bool { var remaining = text[...]; for char in query { guard let i = remaining.firstIndex(of: char) else { return false }; remaining = remaining[remaining.index(after: i)...] }; return true }
}
struct TemplateBrowser: View {
    @Bindable var store: EditorStore
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) { Text("Start with a spark.").font(.system(size: 30, weight: .semibold)); Text("Draw circuits as naturally as writing equations.").font(.callout).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230))], spacing: 18) { ForEach(store.supportsSimulation ? CircuitTemplate.allCases : [.blank]) { template in Button { store.loadTemplate(template) } label: { VStack(alignment: .leading, spacing: 12) { CircuitThumbnail(circuit: template.make()).frame(height: 150).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12)); Text(template.rawValue).font(.system(size: 14, weight: .semibold)); Text(template.subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }.padding(10) }.buttonStyle(.plain) } }
                Text("Paper figures").font(.title2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230))], spacing: 18) { ForEach(PaperExample.allCases) { example in Button { store.loadPaperExample(example) } label: { VStack(alignment: .leading, spacing: 12) { CircuitThumbnail(circuit: example.make()).frame(height: 150); Text(example.rawValue).font(.system(size: 14, weight: .semibold)); Text(example.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.padding(10) }.buttonStyle(.plain) } }
                Text("Choosing a template replaces the current sheet. You can undo this action.").font(.caption).foregroundStyle(.secondary)
            }.padding(28) }.navigationTitle("Circuit templates").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { store.showTemplates = false } } }
        }.frame(minWidth: 350, idealWidth: 760, minHeight: 480, idealHeight: 650)
    }
}
struct CircuitThumbnail: View {
    var circuit: Circuit
    var body: some View {
        if let data = try? CircuitExport.raster(circuit, scale: 1, transparent: false), let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { Image(decorative: image, scale: 1).resizable().scaledToFit().accessibilityHidden(true) }
    }
}
