import SwiftUI

struct SymbolPreview: View {
    var kind: ComponentKind
    var theme: SymbolTheme = .razavi
    var body: some View {
        Canvas { context, size in
            let c = Component(kind: kind, name: "", position: .zero)
            let scale = min(size.width / 100, size.height / 100)
            var context = context; context.translateBy(x: size.width / 2, y: size.height / 2); context.scaleBy(x: scale, y: scale)
            for primitive in Symbols.geometry(c, theme: theme) {
                var path = Path(); var fill = false
                switch primitive {
                case .line(let ps): if let p = ps.first { path.move(to: CGPoint(x: p.x, y: p.y)); for q in ps.dropFirst() { path.addLine(to: CGPoint(x: q.x, y: q.y)) } }
                case .circle(let p, let r, let f): path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)); fill = f
                case .polygon(let ps, let f): if let p = ps.first { path.move(to: CGPoint(x: p.x, y: p.y)); for q in ps.dropFirst() { path.addLine(to: CGPoint(x: q.x, y: q.y)) }; path.closeSubpath() }; fill = f
                }
                if fill { context.fill(path, with: .foreground) } else { context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)) }
            }
        }.accessibilityHidden(true)
    }
}
struct LibraryView: View {
    @Bindable var store: EditorStore
    @State private var query = ""; @State private var tab = "Symbols"
    let favorites: [ComponentKind] = [.nmos, .pmos, .resistor, .capacitor, .voltageSource, .ground]
    var filtered: [ComponentKind] { ComponentKind.allCases.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.rawValue.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 23, weight: .medium)).foregroundStyle(StudioStyle.accent)
                Text("Circuit Studio").font(.system(size: 16, weight: .semibold))
            }.padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 24)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField(store.supportsSimulation ? "Find a component" : "Find a shape or port", text: $query).textFieldStyle(.plain).font(.system(size: 12)); if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) } }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 16)
            Picker("Library", selection: $tab) { Text("Symbols").tag("Symbols"); if store.supportsSimulation { Text("Patterns").tag("Patterns") }; Text("Figures").tag("Figures") }.pickerStyle(.segmented).labelsHidden().padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if tab == "Symbols" {
                        if query.isEmpty {
                            sectionTitle("Essentials", count: "6")
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(favorites, id: \.self) { kind in
                                    Button { store.insertKind = kind; store.tool = .select; store.toast = "Click the canvas to place \(kind.title)" } label: {
                                        VStack(spacing: 4) { SymbolPreview(kind: kind, theme: store.circuit.theme).frame(height: 43); Text(kind.title).font(.system(size: 11, weight: .medium)).lineLimit(1) }.frame(maxWidth: .infinity).padding(.vertical, 10).background(store.insertKind == kind ? StudioStyle.accent.opacity(0.10) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain).accessibilityLabel("Insert \(kind.title)")
                                }
                            }
                        }
                        ForEach(["Passives", "Semiconductors", "Sources", "Amplifiers", "Connections"], id: \.self) { category in
                            let items = filtered.filter { $0.category == category }
                            if !items.isEmpty { VStack(alignment: .leading, spacing: 6) { sectionTitle(category, count: "\(items.count)"); ForEach(items, id: \.self) { kind in componentRow(kind) } } }
                        }
                        if filtered.isEmpty { ContentUnavailableView.search(text: query) }
                    } else if tab == "Figures" {
                        ForEach(["Shapes & text", "Ports & signal flow", "Flowchart"], id: \.self) { category in
                            let shapes = FigureKind.allCases.filter { $0.category == category && (query.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(query) || category.localizedCaseInsensitiveContains(query)) }
                            if !shapes.isEmpty {
                                sectionTitle(category, count: "\(shapes.count)")
                                ForEach(shapes) { kind in
                                    Button { store.cancel(); store.insertFigureKind = kind; store.toast = "Click the canvas to place \(kind.rawValue)" } label: { HStack(spacing: 12) { Image(systemName: kind.icon).frame(width: 28).font(.system(size: 22, weight: .light)); Text(kind.rawValue).font(.system(size: 12)); Spacer() }.padding(.vertical, 8).contentShape(Rectangle()) }.buttonStyle(.plain)
                                }
                            }
                        }
                        Button { store.cancel(); store.tool = .connector } label: { Label("Arrow / connector", systemImage: "arrow.up.right") }.buttonStyle(.plain)
                        Text("Click or drag between shape edges to attach an arrow. Drag corners to resize; double-click to edit text.").font(.caption).foregroundStyle(.secondary)
                        sectionTitle("Editable examples", count: "3")
                        ForEach(PaperExample.allCases) { example in Button { store.insertPaperExample(example) } label: { VStack(alignment: .leading, spacing: 5) { Text(example.rawValue).font(.system(size: 12, weight: .medium)); Text(example.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.padding(.vertical, 8) }.buttonStyle(.plain) }
                    } else {
                        sectionTitle("Analog building blocks", count: "5")
                        ForEach(CircuitTemplate.allCases.filter { $0 != .blank }) { template in
                            Button { store.insertPattern(template) } label: {
                                HStack(spacing: 12) { Image(systemName: "square.stack.3d.up").foregroundStyle(StudioStyle.accent).frame(width: 24); VStack(alignment: .leading, spacing: 5) { Text(template.rawValue).font(.system(size: 12, weight: .medium)); Text("Insert editable circuit").font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer() }.padding(.vertical, 10)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 20)
            }
            Divider()
            Button { store.showTemplates = true } label: { HStack { Image(systemName: "rectangle.stack"); Text("Explore templates"); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10)) }.font(.system(size: 12)).foregroundStyle(.secondary).padding(18) }.buttonStyle(.plain)
        }.background(.regularMaterial)
        .onChange(of: store.circuit.purpose, initial: true) { _, purpose in tab = purpose == .illustration ? "Figures" : "Symbols"; query = "" }
    }
    func sectionTitle(_ title: String, count: String) -> some View { HStack { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary); Spacer(); Text(count).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) } }
    func componentRow(_ kind: ComponentKind) -> some View {
        Button { store.cancel(); store.insertKind = kind; store.toast = "Click the canvas to place \(kind.title)" } label: { HStack(spacing: 12) { SymbolPreview(kind: kind, theme: store.circuit.theme).frame(width: 30, height: 30); Text(kind.title).font(.system(size: 12)); Spacer(); if store.insertKind == kind { Image(systemName: "plus.circle.fill").foregroundStyle(StudioStyle.accent) } }.padding(.vertical, 3).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}
