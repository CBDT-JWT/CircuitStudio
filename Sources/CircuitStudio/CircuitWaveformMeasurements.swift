import SwiftUI
struct CircuitWaveformMeasurements:View {
    let output:EngineeringSimulationOutput
    @State private var positive=""
    @State private var negative=""
    @State private var current=""
    @State private var delivered=false
    @State private var figure:CircuitAIFigure?
    @State private var measurement:CircuitSignalAnalysis.Measurement?
    @State private var error:String?
    private var voltages:[Waveform] {output.result.waveforms.filter{$0.name.hasPrefix("V(")}}
    private var currents:[Waveform] {output.result.waveforms.filter{$0.name.hasPrefix("I(")}}
    var body:some View {
        DisclosureGroup("功率与能量") {
            Picker("正端电压",selection:$positive){ForEach(voltages){Text($0.name).tag($0.name)}}
            Picker("负端电压",selection:$negative){Text("地 / 0V").tag("");ForEach(voltages){Text($0.name).tag($0.name)}}
            Picker("流入正端的电流",selection:$current){ForEach(currents){Text($0.name).tag($0.name)}}
            Toggle("显示电源输出功率（反号）",isOn:$delivered)
            Text("p(t)=[V+−V−]·I；电流方向按网表定义。按实际非均匀时间轴积分，得到当前记录区间的能量。").font(.caption).foregroundStyle(.secondary)
            Button("计算并绘制功率",action:calculate).disabled(positive.isEmpty || current.isEmpty)
            if let measurement {
                LabeledContent("平均功率",value:EngineeringUnits.format(measurement.mean)+" W")
                LabeledContent("积分能量",value:EngineeringUnits.format(measurement.integral)+" J")
                LabeledContent("功率 RMS",value:EngineeringUnits.format(measurement.rms)+" W")
            }
            if let figure {CircuitAIFigureCard(figure:figure){self.figure=$0}}
            if let error {Text(error).font(.caption).foregroundStyle(.red)}
        }.task(id:output.id){positive=voltages.first{$0.name=="V(IN)"}?.name ?? voltages.first?.name ?? "";current=currents.first{$0.name=="I(VIN)"}?.name ?? currents.first?.name ?? "";figure=nil;measurement=nil}
    }
    private func calculate() {
        do {
            let (wave,metrics)=try CircuitSignalAnalysis.power(output.result,positive:positive,negative:negative.isEmpty ? nil:negative,current:current,delivered:delivered)
            let result=SimulationResult(analysis:.tran,axis:output.result.axis,waveforms:[wave],engine:"Power · "+output.result.engine)
            var settings=output.settings;settings.probes=[wave.name]
            let derived=EngineeringSimulationOutput(source:output.source,settings:settings,result:result,modelNotice:output.modelNotice)
            var options=CircuitAIPlotOptions();options.title=delivered ? "电源输出功率":"吸收功率";options.xLabel="Time (s)";options.yLabel="Power (W)"
            figure=try CircuitAIPlotRenderer.figure(derived,options:options);measurement=metrics;error=nil
        }catch{self.error=error.localizedDescription}
    }
}
