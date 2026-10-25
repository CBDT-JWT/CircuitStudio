import SwiftUI

struct SymbolPreview: View {
    var kind: ComponentKind
    var theme: SymbolTheme = .razavi
    var assetID:String? = nil
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Canvas { context,size in
            var component=Component(kind:kind,name:"",position:.zero);component.showName=false;component.showValue=false
            var circuit=Circuit();circuit.components=[component];circuit.theme=theme
            let scene=Symbols.scene(circuit)
            let primitives=scene.primitives+scene.layers.flatMap(\.primitives)
            var points=primitives.flatMap { primitive -> [Point] in switch primitive { case .line(let p),.polygon(let p,_):return p;case .circle(let p,let r,_):return [p-Point(r,r),p+Point(r,r)];case .reference(let p):return [Point(p.bounds.minX,p.bounds.minY),Point(p.bounds.maxX,p.bounds.maxY)] } }
            for text in scene.texts+scene.layers.flatMap(\.texts) { let b=Symbols.textBounds(text);points += [Point(b.minX,b.minY),Point(b.maxX,b.maxY)] }
            let bounds=Bounds(points,padding:4)
            let scale=min(size.width/max(bounds.width,1),size.height/max(bounds.height,1))
            context.withCGContext { cg in
                cg.translateBy(x:size.width/2,y:size.height/2);cg.scaleBy(x:scale,y:scale);cg.translateBy(x:-(bounds.minX+bounds.maxX)/2,y:-(bounds.minY+bounds.maxY)/2)
                CircuitRenderer.draw(scene,in:cg,dark:colorScheme == .dark)
            }
        }.accessibilityHidden(true)
    }
}
struct LibraryView: View {
    @Bindable var store: EditorStore
    @AppStorage("library.collapsedSections") private var collapsedSections = ""
    @State private var query = ""; @State private var tab = "Symbols"
    let favorites: [ComponentKind] = [.nmos, .pmos, .resistor, .capacitor, .voltageSource, .ground]
    var filtered: [ComponentKind] { ComponentKind.allCases.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.rawValue.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 23, weight: .medium)).foregroundStyle(StudioStyle.accent)
                Text("Circuit Studio").font(.system(size: 16, weight: .semibold))
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 18)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField(LocalizedStringKey(store.supportsSimulation ? "Find a component" : "Find a shape or port"), text: $query).textFieldStyle(.plain).font(.system(size: 12)); if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) } }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 16)
            Picker("Library", selection: $tab) { Text("Symbols").tag("Symbols"); if store.supportsSimulation { Text("Patterns").tag("Patterns") }; Text("Figures").tag("Figures") }.pickerStyle(.segmented).labelsHidden().padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == "Symbols" {
                        if query.isEmpty {
                            DisclosureGroup(isExpanded:expanded("Essentials")) { LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(favorites, id: \.self) { kind in
                                    Button { store.insertKind = kind; store.tool = .select; store.toast = String(format: NSLocalizedString("Click to place %@ · Esc to finish", comment: ""), kind.title) } label: {
                                        VStack(spacing: 4) { SymbolPreview(kind: kind, theme: store.circuit.theme).frame(height: 43); Text(kind.title).font(.system(size: 11, weight: .medium)).lineLimit(1) }.frame(maxWidth: .infinity).padding(.vertical, 10).background(store.insertKind == kind ? StudioStyle.accent.opacity(0.10) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain).accessibilityLabel("Insert \(kind.title)")
                                }
                            }
                            } label: { sectionTitle("Essentials",count:"6") }
                        }
                        ForEach(AnalogLibrary.categories, id: \.self) { category in
                            let entries = AnalogLibrary.entries.filter { $0.category == category && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || NSLocalizedString($0.title,comment:"").localizedCaseInsensitiveContains(query) || category.localizedCaseInsensitiveContains(query) || NSLocalizedString(category,comment:"").localizedCaseInsensitiveContains(query)) }
                            if !entries.isEmpty { DisclosureGroup(isExpanded: expanded(category)) { VStack(alignment: .leading, spacing: 6) {
                                ForEach(entries) { entry in
                                    if case .component(let kind) = entry.item { componentRow(kind) }
                                    else { Button { place(entry) } label: { HStack(spacing:12) { SymbolPreview(kind:.resistor,assetID:annotationAsset(entry)).frame(width:30,height:30); Text(LocalizedStringKey(entry.title)).font(.system(size:12));Spacer() }.padding(.vertical,3).contentShape(Rectangle()) }.buttonStyle(.plain) }
                                }
                            } } label: { sectionTitle(category,count:"\(entries.count)") } }
                        }
                        let extras = filtered.filter { kind in !AnalogLibrary.entries.contains { if case .component(let c) = $0.item { return c == kind }; return false } }
                        if !extras.isEmpty { DisclosureGroup(isExpanded:expanded("More symbols")) { ForEach(extras,id: \.self) { componentRow($0) } } label: { sectionTitle("More symbols",count:"\(extras.count)") } }
                        if filtered.isEmpty { ContentUnavailableView.search(text: query) }
                    } else if tab == "Figures" {
                        ForEach(["Shapes & text", "Ports & signal flow", "Flowchart"], id: \.self) { category in
                            let shapes = FigureKind.allCases.filter { $0.category == category && (query.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(query) || category.localizedCaseInsensitiveContains(query)) }
                            if !shapes.isEmpty {
                                DisclosureGroup(isExpanded:expanded(category)) { ForEach(shapes) { kind in
                                    Button { store.cancel(); store.insertFigureKind = kind; store.toast = String(format: NSLocalizedString("Click to place %@ · Esc to finish", comment: ""), NSLocalizedString(kind.rawValue, comment: "")) } label: { HStack(spacing: 12) { Image(systemName: kind.icon).frame(width: 28).font(.system(size: 22, weight: .light)); Text(LocalizedStringKey(kind.rawValue)).font(.system(size: 12)); Spacer() }.padding(.vertical, 8).contentShape(Rectangle()) }.buttonStyle(.plain)
                                }
                                } label: { sectionTitle(category,count:"\(shapes.count)") }
                            }
                        }
                        Button { store.cancel(); store.tool = .connector } label: { Label("Arrow / connector", systemImage: "arrow.up.right") }.buttonStyle(.plain)
                        Text("Click or drag between shape edges to attach an arrow. Drag corners to resize; double-click to edit text.").font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup(isExpanded:expanded("Editable examples")) { ForEach(PaperExample.allCases) { example in Button { store.insertPaperExample(example) } label: { VStack(alignment: .leading, spacing: 5) { Text(LocalizedStringKey(example.rawValue)).font(.system(size: 12, weight: .medium)); Text(LocalizedStringKey(example.subtitle)).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.padding(.vertical, 8) }.buttonStyle(.plain) }
                        } label: { sectionTitle("Editable examples",count:"3") }
                    } else {
                        DisclosureGroup(isExpanded:expanded("Analog building blocks")) {
                        ForEach(CircuitTemplate.allCases.filter { $0 != .blank }) { template in
                            Button { store.insertPattern(template) } label: {
                                HStack(spacing: 12) { Image(systemName: "square.stack.3d.up").foregroundStyle(StudioStyle.accent).frame(width: 24); VStack(alignment: .leading, spacing: 5) { Text(LocalizedStringKey(template.rawValue)).font(.system(size: 12, weight: .medium)); Text("Insert editable circuit").font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer() }.padding(.vertical, 10)
                            }.buttonStyle(.plain)
                        }
                        } label: { sectionTitle("Analog building blocks",count:"5") }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 20)
            }
            Divider()
            Button { store.showTemplates = true } label: { HStack { Image(systemName: "rectangle.stack"); Text("Explore templates"); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10)) }.font(.system(size: 12)).foregroundStyle(.secondary).padding(18) }.buttonStyle(.plain)
        }.background(.regularMaterial)
        .onChange(of: store.circuit.purpose, initial: true) { _, purpose in tab = purpose == .illustration ? "Figures" : "Symbols"; query = "" }
    }
    func place(_ entry: AnalogLibrary.Entry) {
        store.cancel()
        switch entry.item {
        case .component(let kind): store.insertKind = kind
        case .figure(let kind): store.insertFigureKind = kind
        case .arrow: store.tool = .connector; store.connectorArrows = .end
        case .line, .polyline: store.tool = .connector; store.connectorArrows = .none
        }
        store.toast = "Click the canvas to place \(entry.title)"
    }
    func annotationAsset(_ entry:AnalogLibrary.Entry)->String {
        switch entry.item {
        case .arrow:return "annotation-arrow"
        case .line:return "annotation-line"
        case .polyline:return "annotation-polyline"
        case .figure(let kind):return [.rectangle:"annotation-rectangle",.ellipse:"annotation-circle",.polarity:"annotation-polarity-both",.plus:"annotation-text-plus",.minus:"annotation-text-minus",.dots:"annotation-ellipsis"][kind] ?? "annotation-rectangle"
        case .component:return ""
        }
    }
    func expanded(_ category:String)->Binding<Bool> {
        Binding(get:{ !query.isEmpty || !collapsedSections.split(separator:"|").contains(Substring(category)) },set:{ value in
            guard query.isEmpty else { return };var collapsed=Set(collapsedSections.split(separator:"|").map(String.init));if value { collapsed.remove(category) } else { collapsed.insert(category) };collapsedSections=collapsed.sorted().joined(separator:"|")
        })
    }
    func sectionTitle(_ title: String, count: String) -> some View { HStack { Text(LocalizedStringKey(title)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary); Spacer(); Text(count).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) } }
    func componentRow(_ kind: ComponentKind) -> some View {
        Button { store.cancel(); store.insertKind = kind; store.toast = String(format: NSLocalizedString("Click to place %@ · Esc to finish", comment: ""), kind.title) } label: { HStack(spacing: 12) { SymbolPreview(kind: kind, theme: store.circuit.theme).frame(width: 30, height: 30); Text(kind.title).font(.system(size: 12)); Spacer(); if store.insertKind == kind { Image(systemName: "plus.circle.fill").foregroundStyle(StudioStyle.accent) } }.padding(.vertical, 3).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}
