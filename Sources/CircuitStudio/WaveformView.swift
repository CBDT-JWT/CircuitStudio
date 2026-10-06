import SwiftUI

struct WaveformView: View {
    let result: SimulationResult; var probes: [String]; var onClose: () -> Void
    var onOpen: ((Bool) -> Void)? = nil
    @State private var phase = false; @State private var cursor: Double?; @State private var secondCursor: Double?; @State private var delta = false
    @State private var hidden: Set<String> = []; @State private var separate = false; @State private var zoom = 1.0; @State private var pan = 0.0
    let colors: [Color] = [StudioStyle.accent, StudioStyle.secondaryAccent, .orange, .purple, .pink]
    var traces: [Waveform] { let selected = result.waveforms.filter { trace in probes.isEmpty || probes.contains(where: { probe in trace.name.uppercased() == "V(\(MathLabel.netName(probe)))" }) }; return Array((selected.isEmpty ? result.waveforms.filter { $0.name.hasPrefix("V(") } : selected).prefix(6)) }
    var active: [Waveform] { traces.filter { !hidden.contains($0.name) } }
    func x(_ value: Double) -> Double { result.analysis == .ac ? log10(max(1e-30, value)) : value }
    func y(_ value: Complex) -> Double { result.analysis == .ac ? (phase ? value.phase : 20 * log10(max(1e-30, value.magnitude))) : value.real }
    var domain: ClosedRange<Double> { let min = x(result.axis.first ?? 0), max = x(result.axis.last ?? 1), span = Swift.max(1e-12, max - min), visible = span / zoom; let start = min + Swift.min(1 - 1 / zoom, Swift.max(0, pan)) * span; return start...(start + visible) }
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { waveformTitle; phasePicker; plotControls; openResultButton; closeButton }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { waveformTitle; Spacer(); openResultButton; closeButton }
                    if result.analysis != .op { HStack { phasePicker; Spacer(minLength: 8); plotControls } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 12)
            if result.analysis == .op {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 14) {
                            ForEach(result.waveforms) { trace in
                                HStack { Text(trace.name).font(.system(size: 12, design: .monospaced)); Spacer(); Text(EngineeringUnits.format(trace.values.first?.real ?? 0, unit: trace.name.hasPrefix("I(") || trace.name.contains("#BRANCH") ? "A" : "V")).foregroundStyle(StudioStyle.accent) }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        if !result.operatingPoints.isEmpty {
                            Text("MOS operating points").font(.subheadline.weight(.semibold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 14) {
                                ForEach(result.operatingPoints.keys.sorted(), id: \.self) { device in operatingPointCard(device) }
                            }
                        }
                    }.padding(18)
                }
            } else {
                HStack(spacing: 20) { ForEach(Array(traces.enumerated()), id: \.element.id) { index, trace in Button { if hidden.contains(trace.name) { hidden.remove(trace.name) } else { hidden.insert(trace.name) } } label: { HStack(spacing: 6) { Circle().fill(colors[index % colors.count]).frame(width: 6, height: 6); Text(trace.name).font(.system(size: 11, weight: .medium, design: .monospaced)); if let value = cursorValue(trace) { Text(value).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) } }.opacity(hidden.contains(trace.name) ? 0.35 : 1) }.buttonStyle(.plain) }; Spacer() }.padding(.horizontal, 24).padding(.bottom, 8)
                if separate { VStack(spacing: 6) { ForEach(active) { trace in plot([trace]) } } } else { plot(active) }
                HStack { Text(result.axisLabel); Spacer(); if let cursor { Text("Cursor \(EngineeringUnits.format(result.analysis == .ac ? pow(10, cursor) : cursor, unit: result.analysis == .ac ? "Hz" : result.analysis == .tran ? "s" : "V"))") }; if delta, let cursor, let secondCursor { Text("Δ \(EngineeringUnits.format(abs((result.analysis == .ac ? pow(10, cursor) : cursor) - (result.analysis == .ac ? pow(10, secondCursor) : secondCursor))))") }; if zoom > 1 { Slider(value: $pan, in: 0...max(0.001, 1 - 1 / zoom)).frame(width: 110).help("Pan waveform") } }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 7)
            }
        }.background(.background)
    }
    private var waveformTitle: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path").foregroundStyle(StudioStyle.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.analysis == .ac ? "Frequency response" : result.analysis.rawValue).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(result.engine).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    @ViewBuilder private var phasePicker: some View {
        if result.analysis == .ac { Picker("Display", selection: $phase) { Text("Magnitude").tag(false); Text("Phase").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 180) }
    }
    private var plotControls: some View {
        HStack(spacing: 14) {
            Button { zoom = max(1, zoom / 2) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out").accessibilityLabel("Zoom out")
            Button { zoom = min(16, zoom * 2) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in").accessibilityLabel("Zoom in")
            Menu { Toggle("Separate plots", isOn: $separate); Toggle("Delta cursor", isOn: $delta); Button("Reset view") { zoom = 1; pan = 0; cursor = nil; secondCursor = nil } } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Waveform options")
        }
    }
    private var closeButton: some View { Button(action: onClose) { Image(systemName: "xmark") }.help("Close waveforms").accessibilityLabel("Close waveforms") }
    @ViewBuilder private var openResultButton: some View {
        if let onOpen {
            HStack(spacing: 6) {
                Button { onOpen(true) } label: { Label("New tab", systemImage: "rectangle.on.rectangle") }.help("Open this simulation result in a new tab").accessibilityLabel("Open simulation result in new tab")
                Menu { Button("Open in new window") { onOpen(false) } } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Simulation result window options")
            }.font(.system(size: 11))
        }
    }
    private func operatingPointCard(_ device: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(device).font(.system(.subheadline, design: .monospaced).weight(.semibold))
            ForEach(["id", "vgs", "vds", "vdsat", "gm", "gds", "ro"], id: \.self) { key in
                if let value = result.operatingPoints[device]?[key] {
                    HStack { Text(key).foregroundStyle(.secondary); Spacer(); Text(EngineeringUnits.format(value, unit: key == "id" ? "A" : key == "gm" || key == "gds" ? "S" : key == "ro" ? "Ω" : "V")).foregroundStyle(StudioStyle.accent) }.font(.system(size: 12, design: .monospaced))
                }
            }
        }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
    func plot(_ traces: [Waveform]) -> some View {
        GeometryReader { geometry in
            let values = traces.flatMap { $0.values.map(y) }.filter(\.isFinite), minimum = (values.min() ?? -1), maximum = (values.max() ?? 1), padding = max(0.1, (maximum - minimum) * 0.12), lo = minimum - padding, hi = maximum + padding
            let left = 54.0, right = 18.0, bottom = 22.0, width = max(1, geometry.size.width - left - right), height = max(1, geometry.size.height - bottom - 6)
            Canvas { context, _ in
                for i in 0...4 {
                    let yy = 3 + Double(i) * height / 4; var p = Path(); p.move(to: CGPoint(x: left, y: yy)); p.addLine(to: CGPoint(x: left + width, y: yy)); context.stroke(p, with: .color(.secondary.opacity(0.18)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 4]))
                    let val = hi - Double(i) / 4 * (hi - lo), label = result.analysis == .ac ? String(format: "%.0f", val) + (phase ? "°" : " dB") : EngineeringUnits.format(val, unit: "V")
                    context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: left - 8, y: yy), anchor: .trailing)
                }
                for i in 0...5 { let xx = left + Double(i) * width / 5, axis = domain.lowerBound + Double(i) / 5 * (domain.upperBound - domain.lowerBound); let value = result.analysis == .ac ? pow(10, axis) : axis; context.draw(Text(EngineeringUnits.format(value)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: xx, y: height + 15)) }
                for trace in traces {
                    let color = colors[(self.traces.firstIndex(where: { $0.id == trace.id }) ?? 0) % colors.count]; var path = Path(); var started = false
                    for (axis, value) in zip(result.axis, trace.values) { let xx = x(axis); guard domain.contains(xx), y(value).isFinite else { continue }; let p = CGPoint(x: left + (xx - domain.lowerBound) / (domain.upperBound - domain.lowerBound) * width, y: 3 + (hi - y(value)) / (hi - lo) * height); if started { path.addLine(to: p) } else { path.move(to: p); started = true } }
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                }
                for c in [cursor, delta ? secondCursor : nil].compactMap({ $0 }) where domain.contains(c) { let xx = left + (c - domain.lowerBound) / (domain.upperBound - domain.lowerBound) * width; var p = Path(); p.move(to: CGPoint(x: xx, y: 3)); p.addLine(to: CGPoint(x: xx, y: height)); context.stroke(p, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in let c = domain.lowerBound + max(0, min(1, (value.location.x - left) / width)) * (domain.upperBound - domain.lowerBound); if delta && cursor != nil { secondCursor = c } else { cursor = c } })
            .accessibilityLabel("Waveform plot. \(traces.map(\.name).joined(separator: ", ")). \(result.axis.count) computed samples.")
        }
    }
    func cursorValue(_ trace: Waveform) -> String? { guard let cursor, let i = result.axis.indices.min(by: { abs(x(result.axis[$0]) - cursor) < abs(x(result.axis[$1]) - cursor) }), i < trace.values.count else { return nil }; return result.analysis == .ac ? String(format: "%.2f", y(trace.values[i])) + (phase ? "°" : " dB") : EngineeringUnits.format(trace.values[i].real, unit: "V") }
}

#if os(macOS)
/// Each result window owns an immutable snapshot, independent of future edits or analyses.
@MainActor final class SimulationResultWindow: NSWindowController, NSWindowDelegate {
    private static var retained: [UUID: SimulationResultWindow] = [:]
    private let identifier = UUID()
    static func open(_ result: SimulationResult, title: String, probes: [String], sourceWindow: NSWindow?, inNewTab: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(title) · \(result.analysis.rawValue)"
        window.minSize = NSSize(width: 640, height: 440)
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "com.circuitstudio.workspace"
        window.tabbingMode = inNewTab ? .preferred : .disallowed
        window.contentView = NSHostingView(rootView: WaveformView(result: result, probes: probes, onClose: { [weak window] in window?.close() }).tint(StudioStyle.accent))
        let controller = SimulationResultWindow(window: window)
        window.delegate = controller
        retained[controller.identifier] = controller
        if inNewTab, let sourceWindow { sourceWindow.addTabbedWindow(window, ordered: .above) }
        else { window.center() }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { Self.retained.removeValue(forKey: identifier) }
}
#endif
