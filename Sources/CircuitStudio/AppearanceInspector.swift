import SwiftUI

struct HexColorControl: View {
    var title: String
    var value: String?
    var commit: (String?) -> Void
    var body: some View {
        HStack {
            ColorPicker(LocalizedStringKey(title), selection: Binding(get: { Color(cgColor:CircuitRenderer.color(value) ?? CGColor(gray:0.1,alpha:1)) }, set: { commit(hex($0)) }), supportsOpacity: false)
            Button { commit(nil) } label: { Image(systemName:"arrow.uturn.backward") }.help("Use document color").buttonStyle(.borderless)
        }
        CommitField("Hex color",value:value.map { "#"+$0 } ?? "") { text in
            let value=text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"#",with:"").lowercased()
            if value.isEmpty { commit(nil) } else if value.count == 6 && UInt32(value,radix:16) != nil { commit(value) }
        }
    }
    private func hex(_ color:Color) -> String? {
        #if os(macOS)
        guard let c=NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(format:"%02x%02x%02x",Int((c.redComponent*255).rounded()),Int((c.greenComponent*255).rounded()),Int((c.blueComponent*255).rounded()))
        #else
        var r:CGFloat=0,g:CGFloat=0,b:CGFloat=0,a:CGFloat=0
        guard UIColor(color).getRed(&r,green:&g,blue:&b,alpha:&a) else { return nil }
        return String(format:"%02x%02x%02x",Int((r*255).rounded()),Int((g*255).rounded()),Int((b*255).rounded()))
        #endif
    }
}
struct ObjectAppearanceControls: View {
    @Bindable var store: EditorStore
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Object appearance").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HexColorControl(title:"Symbol / wire color",value:store.selectedAppearance.color) { color in store.setSelectionAppearance { $0.color=color } }
            HexColorControl(title:"Label color",value:store.selectedAppearance.textColor) { color in store.setSelectionAppearance { $0.textColor=color } }
            CommitField("Line weight ×",value:String(format:"%g",store.selectedAppearance.lineScale ?? 1)) { text in if let n=Double(text),n.isFinite,(0.25...4).contains(n) { store.setSelectionAppearance { $0.lineScale=n } } }
            CommitField("Label size ×",value:String(format:"%g",store.selectedAppearance.fontScale ?? 1)) { text in if let n=Double(text),n.isFinite,(0.25...4).contains(n) { store.setSelectionAppearance { $0.fontScale=n } } }
            Button("Reset object appearance") { store.setSelectionAppearance { $0=ObjectAppearance() } }
        }
    }
}
struct PublicationAppearanceControls: View {
    @Bindable var store:EditorStore
    var appearance:PublicationAppearance { store.circuit.appearance ?? PublicationAppearance() }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Publication style").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Menu("Apply figure preset") { ForEach(PublicationPreset.allCases) { preset in Button(LocalizedStringKey(preset.rawValue)) { store.transaction("Apply figure preset") { $0.applyPublicationPreset(preset) } } } }
            HexColorControl(title:"Default ink",value:appearance.ink) { color in update { $0.ink=color } }
            HexColorControl(title:"Default label color",value:appearance.labelColor) { color in update { $0.labelColor=color } }
            HexColorControl(title:"Canvas background",value:appearance.background) { color in update { $0.background=color } }
            CommitField("Line weight ×",value:String(format:"%g",appearance.lineScale)) { text in if let n=Double(text),n.isFinite,(0.25...4).contains(n) { update { $0.lineScale=n } } }
            CommitField("Label size ×",value:String(format:"%g",appearance.fontScale)) { text in if let n=Double(text),n.isFinite,(0.25...4).contains(n) { update { $0.fontScale=n } } }
            CommitField("Export width (mm)",value:appearance.widthMM.map { String(format:"%g",$0) } ?? "") { text in if text.isEmpty { update { $0.widthMM=nil } } else if let n=Double(text),n.isFinite,(10...1000).contains(n) { update { $0.widthMM=n } } }
            HStack { Button("85 mm") { update { $0.widthMM=85 } };Button("180 mm") { update { $0.widthMM=180 } };Button("Natural size") { update { $0.widthMM=nil } } }.buttonStyle(.borderless)
            CommitField("Figure margin",value:String(format:"%g",appearance.padding)) { text in if let n=Double(text),n.isFinite,(0...500).contains(n) { update { $0.padding=n } } }
            Text("Vector PDF / SVG keeps lines and labels sharp. PNG supports transparent backgrounds. Check label size at the final printed width.").font(.caption).foregroundStyle(.secondary)
        }
    }
    func update(_ change:(inout PublicationAppearance)->Void) { var value=appearance;change(&value);store.transaction("Change figure appearance") { $0.appearance=value } }
}
@MainActor extension EditorStore {
    var selectedAppearance:ObjectAppearance {
        circuit.components.first { selection.contains($0.id) }?.appearance ?? circuit.wires.first { selection.contains($0.id) }?.appearance ?? circuit.labels.first { selection.contains($0.id) }?.appearance ?? ObjectAppearance()
    }
    func setSelectionAppearance(_ change:(inout ObjectAppearance)->Void) {
        transaction("Change object appearance") { circuit in
            for i in circuit.components.indices where selection.contains(circuit.components[i].id) { var style=circuit.components[i].appearance ?? ObjectAppearance();change(&style);circuit.components[i].appearance=style }
            for i in circuit.wires.indices where selection.contains(circuit.wires[i].id) { var style=circuit.wires[i].appearance ?? ObjectAppearance();change(&style);circuit.wires[i].appearance=style }
            for i in circuit.labels.indices where selection.contains(circuit.labels[i].id) { var style=circuit.labels[i].appearance ?? ObjectAppearance();change(&style);circuit.labels[i].appearance=style }
            for i in circuit.figures.indices where selection.contains(circuit.figures[i].id) {
                var style=ObjectAppearance(color:circuit.figures[i].style.color,textColor:circuit.figures[i].style.textColor,lineScale:circuit.figures[i].style.width/1.6,fontScale:circuit.figures[i].fontSize/18);change(&style)
                circuit.figures[i].style.color=style.color;circuit.figures[i].style.textColor=style.textColor;circuit.figures[i].style.width=max(0.5,min(6,(style.lineScale ?? 1)*1.6));circuit.figures[i].fontSize=max(8,min(72,(style.fontScale ?? 1)*18))
            }
            for i in circuit.figureConnectors.indices where selection.contains(circuit.figureConnectors[i].id) { var style=ObjectAppearance(color:circuit.figureConnectors[i].style.color,textColor:circuit.figureConnectors[i].style.textColor,lineScale:circuit.figureConnectors[i].style.width/1.6);change(&style);circuit.figureConnectors[i].style.color=style.color;circuit.figureConnectors[i].style.textColor=style.textColor;circuit.figureConnectors[i].style.width=max(0.5,min(6,(style.lineScale ?? 1)*1.6)) }
        }
    }
}
