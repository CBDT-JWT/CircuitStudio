import SwiftUI
import UniformTypeIdentifiers

struct CircuitAIFigure:Identifiable {
    var id:String { output.id.uuidString }
    let output:EngineeringSimulationOutput
    var options:CircuitAIPlotOptions
    var png:Data
    var title:String { options.title ?? output.source.name+" · "+NSLocalizedString(output.result.analysis.rawValue,comment:"") }
}
@MainActor enum CircuitAIPlotRenderer {
    static func figure(_ output:EngineeringSimulationOutput,options:CircuitAIPlotOptions) throws -> CircuitAIFigure {
        try options.validate()
        if options.mode == .spectrum {_ = try plottedResult(output,options:options)}
        let traces=selected(output,options:options)
        guard !traces.isEmpty else { throw CircuitError.message("未找到要绘制的曲线，请使用工具返回的曲线名称。") }
        if let requested=options.traces,requested.contains(where:{name in !output.result.waveforms.contains{ $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.name.caseInsensitiveCompare("V(\(name))") == .orderedSame }}) {throw CircuitError.message("指定的曲线不存在，请先读取仿真记录。")}
        if options.xScale == .log,output.result.axis.contains(where:{$0<=0}) { throw CircuitError.message("对数 X 轴要求所有横坐标大于零。") }
        let two=output.result.analysis == .ac && (options.mode ?? .auto) == .auto
        let renderer=ImageRenderer(content:CircuitAIPlot(output:output,options:options).frame(width:1100,height:two ? 760:540).background(.white));renderer.scale=1.5
        #if os(macOS)
        let image=renderer.nsImage;let png=image?.tiffRepresentation.flatMap{NSBitmapImageRep(data:$0)?.representation(using:.png,properties:[:])}
        #else
        let png=renderer.uiImage?.pngData()
        #endif
        guard let png,png.count<=1_400_000 else{throw CircuitError.message("波形图渲染失败。") }
        return .init(output:output,options:options,png:png)
    }
    static func plottedResult(_ output:EngineeringSimulationOutput,options:CircuitAIPlotOptions)throws->SimulationResult {
        guard options.mode == .spectrum else{return output.result}
        var selectedResult=output.result;selectedResult.waveforms=selected(output,options:options)
        return try CircuitSignalAnalysis.spectrum(selectedResult)
    }
    static func selected(_ output:EngineeringSimulationOutput,options:CircuitAIPlotOptions)->[Waveform] {
        let desired=options.traces ?? output.settings.probes
        let matches=output.result.waveforms.filter { trace in desired.contains { name in
            trace.name.caseInsensitiveCompare(name) == .orderedSame || trace.name.caseInsensitiveCompare("V(\(name))") == .orderedSame
        } }
        if options.traces != nil { return Array(matches.prefix(12)) }
        return Array((matches.isEmpty ? output.result.waveforms:matches).prefix(matches.isEmpty ? 6:12))
    }
}
struct CircuitAIPlot:View {
    let output:EngineeringSimulationOutput
    var options:CircuitAIPlotOptions
    private let result:SimulationResult
    init(output:EngineeringSimulationOutput,options:CircuitAIPlotOptions){self.output=output;self.options=options;self.result=options.mode == .spectrum ? ((try? CircuitAIPlotRenderer.plottedResult(output,options:options)) ?? output.result):output.result}
    private var traces:[Waveform] {let names=Set(CircuitAIPlotRenderer.selected(output,options:options).map(\.name));return result.waveforms.filter{names.contains($0.name)}}
    private var mode:CircuitAIPlotOptions.Mode { options.mode ?? .auto }
    private var ink:Color {options.theme == .virtuoso ? .white:.black}
    private var paper:Color {options.theme == .virtuoso ? Color(white:0.025):.white}
    private var colors:[Color] {options.theme == .virtuoso ? [.green,.cyan,.yellow,.pink,.orange,.mint,.purple,.blue,.red,.white,.teal,.gray]:[.teal,.blue,.orange,.purple,.pink,.brown,.indigo,.cyan,.red,.green,.mint,.gray]}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(options.title ?? output.source.name+" · "+NSLocalizedString(result.analysis.rawValue,comment:"")).font(.system(size:19,weight:.semibold)).foregroundStyle(ink)
            Text(result.engine+" · \(result.axis.count) samples").font(.system(size:11)).foregroundStyle(.gray)
            if mode == .spectrum {Text("去直流 · Hann 窗 · 对求解器的自适应时间样本线性重采样 · 幅值以 1 信号单位为 0 dB").font(.system(size:10)).foregroundStyle(.gray)}
            if let notice=output.modelNotice { Text(notice).font(.system(size:10)).foregroundStyle(.orange) }
            if options.showLegend ?? true { LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],alignment:.leading,spacing:8) { ForEach(Array(traces.enumerated()),id:\.offset) { i,trace in HStack(spacing:6) { RoundedRectangle(cornerRadius:1).fill(colors[i]).frame(width:18,height:3);Text(options.legend?[trace.name] ?? trace.name).font(.system(size:12)).foregroundStyle(ink).lineLimit(2) }.frame(maxWidth:.infinity,alignment:.leading) } } }
            chart(phase:mode == .phase)
            if result.analysis == .ac && mode == .auto { chart(phase:true) }
            Text(options.xLabel ?? NSLocalizedString(result.axisLabel,comment:"")).font(.system(size:13)).foregroundStyle(ink).frame(maxWidth:.infinity)
        }.padding(26).background(paper)
    }
    private func chart(phase:Bool)->some View {
        let result=self.result,traces=self.traces,options=self.options,mode=self.mode,colors=self.colors,ink=self.ink
        return Canvas { context,size in
            let logX=options.xScale == .log || ((options.xScale ?? .auto) == .auto && result.analysis == .ac)
            func x(_ v:Double)->Double { logX ? log10(max(v,1e-30)):v }
            func y(_ v:Complex)->Double {
                if phase { return v.phase }
                if mode == .magnitude || mode == .spectrum || (mode == .auto && result.analysis == .ac) { return 20*log10(max(v.magnitude,1e-30)) }
                return v.real
            }
            let indices=circuitAISampleIndices(count:result.axis.count,limit:1600)
            guard !indices.isEmpty else { return }
            let xs=indices.map{x(result.axis[$0])};let ys=traces.flatMap{$0.values.map(y)}.filter(\.isFinite)
            let x0=xs.min() ?? 0,x1=xs.max() ?? 1,minY=ys.min() ?? 0,maxY=ys.max() ?? 1
            let padding=max(0.02,abs(maxY-minY)*0.07),y0=minY-padding,y1=maxY+padding
            let left=92.0,top=28.0,width=max(1,size.width-left-24),height=max(1,size.height-top-30)
            let dx=max(1e-20,x1-x0),dy=max(1e-20,y1-y0)
            for i in 0...4 {
                let yy=top+Double(i)*height/4,xx=left+Double(i)*width/4
                if options.grid ?? true { var line=Path();line.move(to:CGPoint(x:left,y:yy));line.addLine(to:CGPoint(x:left+width,y:yy));context.stroke(line,with:.color(.gray.opacity(0.2))) }
                context.draw(Text(String(format:"%.4g",y1-Double(i)*dy/4)).font(.system(size:11)).foregroundColor(ink),at:CGPoint(x:left-10,y:yy),anchor:.trailing)
                let value=logX ? pow(10,x0+Double(i)*dx/4):x0+Double(i)*dx/4
                context.draw(Text(EngineeringUnits.format(value)).font(.system(size:11)).foregroundColor(ink),at:CGPoint(x:xx,y:top+height+16))
            }
            var axes=Path();axes.move(to:CGPoint(x:left,y:top));axes.addLine(to:CGPoint(x:left,y:top+height));axes.addLine(to:CGPoint(x:left+width,y:top+height));context.stroke(axes,with:.color(ink.opacity(0.65)),lineWidth:0.7)
            let automatic=phase ? "Phase (deg)":(mode == .magnitude || mode == .spectrum || (result.analysis == .ac && mode == .auto) ? "Magnitude (dB)":"Voltage / current")
            let label=phase ? (options.phaseLabel ?? (mode == .phase ? options.yLabel:nil) ?? automatic):(options.yLabel ?? automatic)
            var rotated=context;rotated.translateBy(x:17,y:top+height/2);rotated.rotate(by:.degrees(-90));rotated.draw(Text(label).font(.system(size:13)).foregroundColor(ink),at:.zero)
            for (index,trace) in traces.enumerated() {
                var path=Path();var started=false
                for i in indices where trace.values.indices.contains(i) {
                    let v=y(trace.values[i]);guard v.isFinite else {started=false;continue}
                    let point=CGPoint(x:left+(x(result.axis[i])-x0)/dx*width,y:top+(y1-v)/dy*height)
                    if indices.count==1 {context.fill(Path(ellipseIn:CGRect(x:point.x-3,y:point.y-3,width:6,height:6)),with:.color(colors[index]))}
                    if started {path.addLine(to:point)}else{path.move(to:point);started=true}
                }
                context.stroke(path,with:.color(colors[index]),lineWidth:options.lineWidth ?? 1.8)
            }
        }
    }
}
func circuitAISampleIndices(count:Int,limit:Int)->[Int] {
    guard count>0 else {return []};if count<=limit{return Array(0..<count)}
    return (0..<limit).map{Int(Double($0)*Double(count-1)/Double(limit-1))}
}
struct CircuitAIFigureCard:View {
    let figure:CircuitAIFigure
    let update:(CircuitAIFigure)->Void
    @State private var editing=false
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Button {editing=true} label:{CircuitDataImage(data:figure.png).aspectRatio(contentMode:.fit).frame(maxWidth:.infinity)}.buttonStyle(.plain).accessibilityLabel("仿真曲线："+figure.title)
            HStack {
                Text(figure.title).font(.caption.weight(.medium)).lineLimit(1);Spacer()
                Button {editing=true} label:{Image(systemName:"slider.horizontal.3")}.help("编辑坐标轴与图例").accessibilityLabel("编辑图表")
                Button {CircuitImageActions.copy(figure.png)} label:{Image(systemName:"doc.on.doc")}.help("复制 PNG").accessibilityLabel("复制波形 PNG")
                Button {CircuitImageActions.export(figure.png,name:"CircuitAI-waveform.png")} label:{Image(systemName:"square.and.arrow.up")}.help("导出 PNG").accessibilityLabel("导出波形 PNG")
            }.buttonStyle(.borderless)
        }.padding(10).background(.background,in:RoundedRectangle(cornerRadius:12))
        .sheet(isPresented:$editing) { CircuitAIFigureEditor(figure:figure,update:update) }
    }
}
private struct CircuitAIFigureEditor:View {
    let figure:CircuitAIFigure;let update:(CircuitAIFigure)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var options:CircuitAIPlotOptions
    @State private var error:String?
    init(figure:CircuitAIFigure,update:@escaping(CircuitAIFigure)->Void) {self.figure=figure;self.update=update;_options=State(initialValue:figure.options)}
    private func text(_ path:WritableKeyPath<CircuitAIPlotOptions,String?>,_ fallback:String="")->Binding<String>{Binding(get:{options[keyPath:path] ?? fallback},set:{options[keyPath:path]=$0})}
    @ViewBuilder private func field(_ title:String,text:Binding<String>)->some View {
        #if os(iOS)
        VStack(alignment:.leading,spacing:6) {Text(title).font(.caption).foregroundStyle(.secondary);TextField(title,text:text).autocorrectionDisabled()}.padding(.vertical,2)
        #else
        TextField(title,text:text)
        #endif
    }
    var body:some View {
        VStack(spacing:0) {
            HStack {Text("图表设置").font(.headline);Spacer();Button("取消"){dismiss()};Button("应用"){do {update(try CircuitAIPlotRenderer.figure(figure.output,options:options));dismiss()}catch{self.error=error.localizedDescription}}.buttonStyle(.borderedProminent)}.padding(18)
            HStack(spacing:0) {
                CircuitAIPlot(output:figure.output,options:options).frame(minWidth:320).padding(12)
                Form {
                    field("标题",text:text(\.title,figure.title))
                    field("X 轴",text:text(\.xLabel,figure.output.result.axisLabel))
                    field("Y 轴",text:text(\.yLabel))
                    if figure.output.result.analysis == .ac {field("相位轴",text:text(\.phaseLabel,"Phase (deg)"))}
                    Picker("显示",selection:Binding(get:{options.mode ?? .auto},set:{value in let wasSpectrum=options.mode == .spectrum;options.mode=value;if value == .spectrum{options.xLabel="Frequency (Hz)";options.yLabel="Amplitude (dB)"}else if wasSpectrum{options.xLabel=figure.output.result.axisLabel;options.yLabel=nil}})) {Text("自动").tag(CircuitAIPlotOptions.Mode.auto);Text("实部").tag(CircuitAIPlotOptions.Mode.real);Text("幅值 dB").tag(CircuitAIPlotOptions.Mode.magnitude);Text("相位").tag(CircuitAIPlotOptions.Mode.phase);if figure.output.result.analysis == .tran {Text("FFT 频谱").tag(CircuitAIPlotOptions.Mode.spectrum)}}
                    Picker("配色",selection:Binding(get:{options.theme ?? .publication},set:{options.theme=$0})) {Text("出版 · 白底").tag(CircuitAIPlotOptions.Theme.publication);Text("Virtuoso · 黑底").tag(CircuitAIPlotOptions.Theme.virtuoso)}
                    Picker("X 轴刻度",selection:Binding(get:{options.xScale ?? .auto},set:{options.xScale=$0})) {Text("自动").tag(CircuitAIPlotOptions.XScale.auto);Text("线性").tag(CircuitAIPlotOptions.XScale.linear);Text("对数").tag(CircuitAIPlotOptions.XScale.log)}
                    Toggle("显示图例",isOn:Binding(get:{options.showLegend ?? true},set:{options.showLegend=$0}))
                    Toggle("显示网格",isOn:Binding(get:{options.grid ?? true},set:{options.grid=$0}))
                    ForEach(CircuitAIPlotRenderer.selected(figure.output,options:options)) {trace in field(trace.name,text:Binding(get:{options.legend?[trace.name] ?? trace.name},set:{options.legend=(options.legend ?? [:]).merging([trace.name:$0],uniquingKeysWith:{$1})}))}
                    if let error {Text(error).foregroundStyle(.red).font(.caption)}
                }.formStyle(.grouped).frame(width:300)
            }
        }.frame(minWidth:600,minHeight:580)
    }
}
