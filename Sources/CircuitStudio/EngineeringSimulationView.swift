import SwiftUI

struct EngineeringSimulationOutput:Identifiable {
    let id=UUID()
    let createdAt=Date()
    let source:EngineeringRunSource
    let settings:SimulationSettings
    let result:SimulationResult
    var modelNotice:String?=nil
}
/// Settings stay in the right-hand tools; this sheet is dedicated to the actual result.
struct EngineeringSimulationView:View {
    let output:EngineeringSimulationOutput
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:16) {
                VStack(alignment:.leading,spacing:5) {
                    Text(output.source.name).font(.headline)
                    HStack(spacing:8) {
                        Text(LocalizedStringKey(output.result.analysis.rawValue))
                        Text("·")
                        Text("Local ngspice")
                        Text("·")
                        Text("\(output.result.axis.count) samples")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            if let notice=output.modelNotice { Text(notice).font(.caption).foregroundStyle(.orange).padding(.horizontal,20).padding(.bottom,12) }
            Divider()
            WaveformView(result:output.result,probes:output.settings.probes,onClose:{ dismiss() })
        }.frame(minWidth:500,idealWidth:1000,minHeight:500).tint(StudioStyle.accent)
    }
}
