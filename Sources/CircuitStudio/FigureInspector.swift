import SwiftUI

struct FigureInspector: View {
    @Bindable var store: EditorStore
    var figure: FigureElement
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(figure.kind.rawValue, systemImage: figure.kind.icon).font(.title3)
            CommitTextEditor(value: figure.text) { text in store.updateFigure(figure.id) { $0.text = text } }
            Text("Mathematical labels: V_{OUT}, g_m, r_o, \\mu. Use new lines for multiple lines.").font(.caption).foregroundStyle(.secondary)
            CommitField("Width", value: number(figure.size.x)) { v in if let value = Double(v), value.isFinite { store.updateFigure(figure.id) { $0.size.x = max(2, min(5000, value)) } } }
            CommitField("Height", value: number(figure.size.y)) { v in if let value = Double(v), value.isFinite { store.updateFigure(figure.id) { $0.size.y = max(2, min(5000, value)) } } }
            CommitField("Font size", value: number(figure.fontSize)) { v in if let value = Double(v), value.isFinite { store.updateFigure(figure.id) { $0.fontSize = max(8, min(72, value)) } } }
            FigureStyleControls(style: figure.style) { style in store.updateFigure(figure.id) { $0.style = style } }
            HStack { Button("Rotate") { store.transformSelection("Rotate") }; Spacer(); Text("\(figure.rotation)°").foregroundStyle(.secondary) }
            Text("Drag a corner to resize. Arrows attached to the edges follow this shape.").font(.caption).foregroundStyle(.secondary)
            Button("Delete shape", role: .destructive) { store.deleteSelection() }
        }
    }
    func number(_ value: Double) -> String { String(format: "%g", value) }
}
struct ConnectorInspector: View {
    @Bindable var store: EditorStore
    var connector: FigureConnector
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Figure connector", systemImage: "arrow.up.right").font(.title3)
            CommitField("Label", value: connector.text) { v in store.updateConnector(connector.id) { $0.text = v } }
            if !connector.text.isEmpty {
                CommitField("Label X offset", value: String(format: "%g", connector.labelOffset?.x ?? 0)) { v in if let value = Double(v), value.isFinite { store.updateConnector(connector.id) { $0.labelOffset = Point(value, $0.labelOffset?.y ?? 0) } } }
                CommitField("Label Y offset", value: String(format: "%g", connector.labelOffset?.y ?? 0)) { v in if let value = Double(v), value.isFinite { store.updateConnector(connector.id) { $0.labelOffset = Point($0.labelOffset?.x ?? 0, value) } } }
            }
            Picker("Arrowheads", selection: Binding(get: { connector.arrows }, set: { v in store.updateConnector(connector.id) { $0.arrows = v } })) { ForEach(FigureArrows.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Picker("Route", selection: Binding(get: { connector.route }, set: { v in store.updateConnector(connector.id) { $0.route = v } })) { ForEach(FigureRoute.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            FigureStyleControls(style: connector.style, allowFill: false) { style in store.updateConnector(connector.id) { $0.style = style } }
            Text("Drag either endpoint to reconnect. These arrows annotate a figure and do not create electrical nets.").font(.caption).foregroundStyle(.secondary)
            Button("Delete arrow", role: .destructive) { store.deleteSelection() }
        }
    }
}
struct FigureStyleControls: View {
    var style: FigureStyle
    var allowFill = true
    var commit: (FigureStyle) -> Void
    let colors = [("Automatic", ""), ("Gray", "777777"), ("Blue", "2867a8"), ("Orange", "b76a2b"), ("Purple", "7950a4")]
    let fills = [("None", ""), ("White", "ffffff"), ("Light gray", "f1f1f1"), ("Gray", "dddddd"), ("Dark gray", "d2d2d2"), ("Blue", "dce8f5")]
    var body: some View {
        CommitField("Line width", value: String(format: "%g", style.width)) { v in if let width = Double(v), width.isFinite { var updated = style; updated.width = max(0.5, min(6, width)); commit(updated) } }
        Toggle("Dashed line", isOn: Binding(get: { style.dashed }, set: { v in var updated = style; updated.dashed = v; commit(updated) }))
        Picker("Line color", selection: Binding(get: { style.color ?? "" }, set: { v in var updated = style; updated.color = v.isEmpty ? nil : v; commit(updated) })) { ForEach(colors, id: \.1) { Text($0.0).tag($0.1) } }
        if allowFill { Picker("Fill", selection: Binding(get: { style.fill ?? "" }, set: { v in var updated = style; updated.fill = v.isEmpty ? nil : v; commit(updated) })) { ForEach(fills, id: \.1) { Text($0.0).tag($0.1) } } }
        Text("Publication mode exports colors in black and grayscale.").font(.caption).foregroundStyle(.secondary)
    }
}
struct CommitTextEditor: View {
    var value: String; var commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text").foregroundStyle(.secondary)
            TextEditor(text: $draft).font(.system(size: 14)).frame(minHeight: 80, maxHeight: 120).padding(5).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).focused($focused)
            Button("Apply text") { if draft != value { commit(draft) }; focused = false }.buttonStyle(.bordered).controlSize(.small)
        }.onAppear { draft = value }.onChange(of: value) { _, v in draft = v }.onChange(of: focused) { _, v in if !v && draft != value { commit(draft) } }
    }
}
