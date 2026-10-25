#if os(iOS)
import SwiftUI
import PencilKit
import Observation

enum IPadNotebookTool: String, CaseIterable, Identifiable {
    case circuit, annotation, laser, eraser, lasso
    var id: Self { self }
    var title: String { switch self { case .circuit: "电路笔"; case .annotation: "批注笔"; case .laser: "激光笔"; case .eraser: "橡皮擦"; case .lasso: "套索" } }
    var icon: String { switch self { case .circuit: "pencil.and.scribble"; case .annotation: "pencil.tip"; case .laser: "laser.burst"; case .eraser: "eraser"; case .lasso: "lasso" } }
}

@MainActor @Observable final class IPadNotebookSettings {
    var tool: IPadNotebookTool = .lasso
    var boxSelection = true
    var inkColor = "Blue"
    var inkWidth = 3.0
    var highlighter = false
    var eraseCircuit = true
    var erasePending = true
    var lassoInk = false
    var allowsFingerDrawing = false
    var preferredMOS: ComponentKind? = nil
    var recognitionStatus = "抬笔后本地 AI 识别"
    var color: UIColor { switch inkColor { case "Red": .systemRed; case "Black": .black; case "Yellow": .systemYellow; default: .systemBlue } }
}

struct IPadNotebookToolbar: View {
    @Bindable var settings: IPadNotebookSettings
    let addComponents: () -> Void
    let addSketch: () -> Void
    let addLabel: () -> Void
    let copySelection: () -> Void
    let selectTool: () -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            tools(width: 64, spacing: 6)
            tools(width: 45, spacing: 2)
        }.buttonStyle(.plain).padding(8).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22)).padding(.top, 12)
    }
    private func select(_ tool: IPadNotebookTool) { settings.tool = tool; selectTool() }
    private func tools(width: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(IPadNotebookTool.allCases.filter { $0 != .circuit }) { tool in
                Button { select(tool) } label: {
                    VStack(spacing: 5) { Image(systemName: tool.icon).font(.system(size: 22)); Text(tool == .lasso && settings.boxSelection ? "框选" : tool.title).font(.system(size: 11, weight: .medium)) }
                        .frame(width: width, height: 54)
                        .background(settings.tool == tool ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12))
                }.accessibilityLabel(tool.title).accessibilityAddTraits(settings.tool == tool ? [.isSelected] : [])
                    .contextMenu {
                        if tool == .circuit {
                            Picker("MOS 类型", selection: $settings.preferredMOS) {
                                Text("自动（MOS 默认为 NMOS）").tag(ComponentKind?.none)
                                Text("NMOS").tag(ComponentKind?.some(.nmos))
                                Text("PMOS").tag(ComponentKind?.some(.pmos))
                            }
                        }
                        if tool == .circuit || tool == .annotation { Toggle("允许手指绘图", isOn: $settings.allowsFingerDrawing) }
                        if tool == .annotation {
                            Picker("颜色", selection: $settings.inkColor) { ForEach(["Blue", "Black", "Red", "Yellow"], id: \.self) { Text(["Blue": "蓝色", "Black": "黑色", "Red": "红色", "Yellow": "黄色"][$0]!).tag($0) } }
                            Picker("粗细", selection: $settings.inkWidth) { ForEach([1.5, 3.0, 6.0], id: \.self) { Text("\($0, specifier: "%.1f") pt").tag($0) } }
                            Toggle("荧光笔", isOn: $settings.highlighter)
                        }
                        if tool == .eraser {
                            Button("擦除电路和笔迹") { settings.eraseCircuit = true; settings.erasePending = true; select(.eraser) }
                            Button("擦除批注") { settings.eraseCircuit = false; settings.erasePending = false; select(.eraser) }
                            Button("擦除待识别笔迹") { settings.eraseCircuit = false; settings.erasePending = true; select(.eraser) }
                            Button("擦除电路对象") { settings.eraseCircuit = true; settings.erasePending = false; select(.eraser) }
                        }
                        if tool == .lasso { Button("矩形框选") { settings.boxSelection = true; settings.lassoInk = false; select(.lasso) }; Button("套索选择电路对象") { settings.boxSelection = false; settings.lassoInk = false; select(.lasso) }; Button("选择批注") { settings.lassoInk = true; select(.lasso) } }
                    }
            }
            Divider().frame(height: 36)
            Menu {
                Button("添加元件", systemImage: "square.grid.2x2", action: addComponents)
                Button("添加标签", systemImage: "textformat", action: addLabel)
                Button("复制选区为 PNG", systemImage: "doc.on.doc") { copySelection() }
            } label: { VStack(spacing: 5) { Image(systemName: "plus").font(.system(size: 22)); Text("添加").font(.system(size: 11, weight: .medium)) }.frame(width: width, height: 54) }.accessibilityLabel("添加")
        }
    }
}

/// Two separate world-coordinate ink layers. Annotation ink is never fed into
/// electrical recognition; laser strokes are never stored in either layer.
@MainActor final class IPadNotebookInk: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    let annotation = PKCanvasView(), pending = PKCanvasView()
    private var transform = CGAffineTransform.identity
    private var annotationData: Data?, pendingData: Data?
    private var drawing = false
    private var recognitionTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    private var presentedAnnotation = PKDrawing(), presentedPending = PKDrawing()
    private var applyingDrawing = false
    private var pinchZoom = 1.0, panOffset = Point()
    private weak var store: EditorStore?
    private var settings: IPadNotebookSettings?
    private struct RecentInk {
        var strokes: [PKStroke]
        var components: [Component]
        var wires: [Wire]
        var date: Date
    }
    private var recentInk: [RecentInk] = []
    var pointerDrawing = false
    override init() {
        super.init()
        for canvas in [annotation, pending] {
            canvas.backgroundColor = .clear; canvas.isOpaque = false; canvas.isScrollEnabled = false
            canvas.contentInsetAdjustmentBehavior = .never
            canvas.drawingPolicy = .anyInput; canvas.delegate = self
        }
        annotation.accessibilityLabel = "批注画布"; pending.accessibilityLabel = "电路笔画布"
    }
    func update(store: EditorStore, settings: IPadNotebookSettings) {
        self.store = store; self.settings = settings
        guard !drawing else { return }
        let next = CGAffineTransform(a: store.zoom, b: 0, c: 0, d: store.zoom, tx: store.offset.x, ty: store.offset.y)
        let changedCamera = next != transform
        applyingDrawing = true
        defer { applyingDrawing = false }
        if changedCamera || store.circuit.annotationDrawing != annotationData {
            annotation.drawing = ((try? store.circuit.annotationDrawing.map { try PKDrawing(data: $0) }) ?? PKDrawing()).transformed(using: next)
            presentedAnnotation = annotation.drawing
            annotationData = store.circuit.annotationDrawing
        }
        if changedCamera || store.circuit.handDrawing != pendingData {
            pending.drawing = ((try? store.circuit.handDrawing.map { try PKDrawing(data: $0) }) ?? PKDrawing()).transformed(using: next)
            presentedPending = pending.drawing
            pendingData = store.circuit.handDrawing
        }
        transform = next
        annotation.drawingPolicy = settings.allowsFingerDrawing ? .anyInput : .pencilOnly
        pending.drawingPolicy = settings.allowsFingerDrawing ? .anyInput : .pencilOnly
        pending.tool = PKInkingTool(.pen, color: UIColor(red: 0.10, green: 0.51, blue: 0.45, alpha: 1), width: 2.5)
        if settings.tool == .eraser { annotation.tool = PKEraserTool(.vector); pending.tool = PKEraserTool(.vector) }
        else if settings.tool == .lasso { annotation.tool = PKLassoTool() }
        else { annotation.tool = PKInkingTool(settings.highlighter ? .marker : .pen, color: settings.color, width: settings.inkWidth) }
        annotation.isUserInteractionEnabled = settings.tool == .annotation || (settings.tool == .eraser && !settings.eraseCircuit && !settings.erasePending) || (settings.tool == .lasso && settings.lassoInk)
        pending.isUserInteractionEnabled = settings.tool == .circuit || (settings.tool == .eraser && !settings.eraseCircuit && settings.erasePending)
        if annotation.isUserInteractionEnabled { annotation.superview?.bringSubviewToFront(annotation) }
        else if pending.isUserInteractionEnabled { pending.superview?.bringSubviewToFront(pending) }
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { drawing = true; commitTask?.cancel(); recognitionTask?.cancel() }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        drawing = false
        scheduleCommit(canvasView)
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !applyingDrawing, !drawing else { return }
        // PencilKit can publish the completed stroke after DidEndUsingTool.
        // Lasso edits also arrive here without a new drawing gesture.
        scheduleCommit(canvasView)
    }
    private func scheduleCommit(_ canvasView: PKCanvasView) {
        let presented = canvasView === annotation ? presentedAnnotation : presentedPending
        guard canvasView.drawing != presented else { return }
        commitTask?.cancel()
        commitTask = Task { [weak self, weak canvasView] in
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            guard let self, let canvasView, !self.drawing else { return }
            self.commit(canvasView)
        }
    }
    private func commit(_ canvasView: PKCanvasView) {
        guard let store else { return }
        let world = canvasView.drawing.transformed(using: transform.inverted()), data = world.dataRepresentation()
        guard data.count <= 5_000_000 else { store.toast = "Ink layer exceeds 5 MB · erase some strokes"; return }
        if canvasView === annotation {
            presentedAnnotation = canvasView.drawing
            annotationData = data
            store.transaction("Edit annotation") { $0.annotationDrawing = data }
        } else {
            presentedPending = canvasView.drawing
            pendingData = data
            store.transaction("Draw circuit ink") { $0.handDrawing = data }
            if settings?.tool == .circuit { recognize(world, originalData: data, in: store) }
        }
    }
    private func recognize(_ world: PKDrawing, originalData: Data, in store: EditorStore) {
        guard !world.strokes.isEmpty else { settings?.recognitionStatus = "抬笔后本地 AI 识别"; return }
        // Keep the raw shape briefly so later strokes can finish a MOS or box
        // even if its first two bars already looked like a capacitor. Edited,
        // moved, erased or undone objects are never replaced by this history.
        recentInk.removeAll { group in Date().timeIntervalSince(group.date) > 10 || !group.components.allSatisfy({ old in store.circuit.components.contains(old) }) || !group.wires.allSatisfy({ old in store.circuit.wires.contains(old) }) }
        let pendingBounds = Bounds(world.strokes.flatMap { stroke in stroke.path.map { let p = $0.location.applying(stroke.transform); return Point(p.x, p.y) } })
        let nearby = recentInk.filter { group in
            let bounds = Bounds(group.strokes.flatMap { stroke in stroke.path.map { let p = $0.location.applying(stroke.transform); return Point(p.x, p.y) } }, padding: 24)
            return pendingBounds.maxX >= bounds.minX && pendingBounds.minX <= bounds.maxX && pendingBounds.maxY >= bounds.minY && pendingBounds.minY <= bounds.maxY
        }
        let historical = nearby.flatMap(\.strokes), combined = PKDrawing(strokes: historical + world.strokes)
        var offset = 0
        let historicalGroups = nearby.map { group -> Set<Int> in
            defer { offset += group.strokes.count }
            return Set(offset..<(offset + group.strokes.count))
        }
        var ink: [CircuitInkStroke] = [], origins: [Int] = [], total = 0
        for (i, stroke) in combined.strokes.enumerated() {
            for range in stroke.maskedPathRanges {
                var points: [Point] = []
                for point in stroke.path.interpolatedPoints(in: range, by: .distance(2)) {
                    total += 1
                    guard total <= 30_000 else { store.toast = "Use 手绘识别与校正 for a large drawing"; return }
                    let p = point.location.applying(stroke.transform); points.append(Point(p.x, p.y))
                }
                if points.count > 1 { ink.append(CircuitInkStroke(points)); origins.append(i) }
            }
        }
        guard ink.count <= 500 else { store.toast = "Review this large drawing before importing"; return }
        let input = ink, mapping = origins
        let preferredMOS = settings?.preferredMOS
        settings?.recognitionStatus = "本地 AI 识别中…"
        recognitionTask = Task {
            do {
                // Wait for multi-stroke symbols to finish before replacing ink.
                try await Task.sleep(for: .milliseconds(120))
                let worker = Task.detached(priority: .userInitiated) { try CircuitHandwritingRecognizer.recognize(input, preferredMOS: preferredMOS) }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard !self.drawing, self.settings?.tool == .circuit,
                      self.settings?.preferredMOS == preferredMOS,
                      store.circuit.handDrawing == originalData else { return }
                // Undo, erasure or editing can happen while the worker runs.
                // Retry with current ink instead of restoring an obsolete object.
                guard nearby.allSatisfy({ group in group.components.allSatisfy({ store.circuit.components.contains($0) }) && group.wires.allSatisfy({ store.circuit.wires.contains($0) }) }) else {
                    self.recognize(world, originalData: originalData, in: store)
                    return
                }
                var consumed = Set(result.components.flatMap(\.strokeIndices))
                var chosenWires: [Wire] = []
                var wireOrigins: [UUID: Set<Int>] = [:]
                for (i, wire) in result.wires.enumerated() {
                    if let chosen = CircuitInkResult.connectedWire(wire, in: store.circuit) {
                        chosenWires.append(chosen)
                        let origin = result.wireStrokeIndices[i]
                        if mapping.indices.contains(origin) {
                            consumed.insert(origin)
                            wireOrigins[chosen.id] = [mapping[origin]]
                        }
                    }
                }
                guard let consumedStrokes = CircuitInkResult.completeStrokeOrigins(mapping, consuming: consumed) else { self.settings?.recognitionStatus = "部分擦除的笔迹已保留 · 请继续补全"; return }
                let removed = Set(consumedStrokes.filter { $0 >= historical.count }.map { $0 - historical.count })
                guard !removed.isEmpty else { self.settings?.recognitionStatus = "笔迹已保留 · 继续补全元件"; return }
                guard let replaced = CircuitInkResult.replacedHistoricalGroups(historicalGroups, consuming: consumedStrokes) else { self.settings?.recognitionStatus = "笔迹已保留 · 继续补全元件"; return }
                let remaining = PKDrawing(strokes: world.strokes.enumerated().filter { !removed.contains($0.offset) }.map(\.element))
                let data = remaining.dataRepresentation()
                let replacedGroups = replaced.sorted().map { nearby[$0] }
                let oldComponents = replacedGroups.flatMap(\.components), oldWireIDs = Set(replacedGroups.flatMap(\.wires).map(\.id)), oldIDs = Set(oldComponents.map(\.id))
                var insertedIDs = Set<UUID>()
                var insertedOrigins: [UUID: Set<Int>] = [:]
                var insertedWireOrigins: [UUID: Set<Int>] = [:]
                store.transaction("Recognize circuit ink") { circuit in
                    let preservedWirePoints = Dictionary(uniqueKeysWithValues: circuit.wires.filter { !oldWireIDs.contains($0.id) }.map { ($0.id, circuit.resolvedPoints($0)) })
                    circuit.components.removeAll { oldIDs.contains($0.id) }; circuit.wires.removeAll { oldWireIDs.contains($0.id) }
                    var ids: [UUID: UUID] = [:]
                    for candidate in result.components {
                        let previous = oldComponents.filter { !insertedIDs.contains($0.id) && $0.position.distance(to: candidate.position) < 32 }.min { $0.position.distance(to: candidate.position) < $1.position.distance(to: candidate.position) }
                        if let previous, previous.kind == candidate.kind { circuit.components.append(previous) }
                        else { _ = circuit.add(candidate.kind, at: candidate.position) }
                        let i = circuit.components.count - 1
                        if let previous { circuit.components[i].id = previous.id }
                        circuit.components[i].position = candidate.position; circuit.components[i].rotation = candidate.rotation
                        if circuit.components[i].parameters["value"] != nil { circuit.components[i].parameters["value"] = "" }
                        if candidate.kind.isMOS { circuit.components[i].parameters["W"] = ""; circuit.components[i].parameters["L"] = "" }
                        let id = circuit.components[i].id
                        ids[candidate.id] = id; insertedIDs.insert(id)
                        insertedOrigins[id] = Set(candidate.strokeIndices.map { mapping[$0] })
                    }
                    for i in circuit.wires.indices {
                        if let a = circuit.wires[i].start, circuit.position(of: a) == nil { circuit.wires[i].start = nil; circuit.wires[i].points = preservedWirePoints[circuit.wires[i].id] ?? circuit.wires[i].points }
                        if let b = circuit.wires[i].end, circuit.position(of: b) == nil { circuit.wires[i].end = nil; circuit.wires[i].points = preservedWirePoints[circuit.wires[i].id] ?? circuit.wires[i].points }
                    }
                    func ref(_ original: TerminalRef?) -> TerminalRef? { original.flatMap { ref in let mapped = TerminalRef(ids[ref.componentID] ?? ref.componentID, ref.pin); return circuit.position(of: mapped) == nil ? nil : mapped } }
                    for original in chosenWires {
                        let a = ref(original.start), b = ref(original.end)
                        var points = original.points
                        if let p = a.flatMap({ circuit.position(of: $0) }) { points[0] = p }
                        if let p = b.flatMap({ circuit.position(of: $0) }) { points[points.count - 1] = p }
                        let wire = Wire(points: points, start: a, end: b)
                        if a != nil && b != nil && circuit.wires.contains(where: { ($0.start == a && $0.end == b) || ($0.start == b && $0.end == a) }) { continue }
                        circuit.wires.append(wire)
                        if let origins = wireOrigins[original.id] { insertedWireOrigins[wire.id] = origins }
                    }
                    circuit.handDrawing = data
                }
                self.applyingDrawing = true
                self.pendingData = data; self.pending.drawing = remaining.transformed(using: self.transform)
                self.presentedPending = self.pending.drawing; self.applyingDrawing = false
                self.recentInk.removeAll { group in group.components.contains { oldIDs.contains($0.id) } || group.wires.contains { oldWireIDs.contains($0.id) } }
                // Share a history group only when objects use the same raw
                // lead. Do not duplicate that PencilKit stroke into two groups.
                var groups: [(Set<Int>, [Component], [Wire])] = store.circuit.components.filter { insertedIDs.contains($0.id) }.map { (insertedOrigins[$0.id] ?? [], [$0], []) }
                groups += store.circuit.wires.filter { insertedWireOrigins[$0.id] != nil }.map { (insertedWireOrigins[$0.id] ?? [], [], [$0]) }
                while let pair = groups.indices.compactMap({ i in groups.indices.first(where: { $0 > i && !groups[i].0.isDisjoint(with: groups[$0].0) }).map { (i, $0) } }).first {
                    groups[pair.0].0.formUnion(groups[pair.1].0); groups[pair.0].1 += groups[pair.1].1; groups[pair.0].2 += groups[pair.1].2
                    groups.remove(at: pair.1)
                }
                for group in groups {
                    self.recentInk.append(RecentInk(strokes: combined.strokes.enumerated().filter { group.0.contains($0.offset) }.map(\.element), components: group.1, wires: group.2, date: Date()))
                }
                let kinds = result.components.map { $0.kind.title }.joined(separator: "、")
                self.settings?.recognitionStatus = kinds.isEmpty ? "导线已连接" : "已识别 \(kinds) · 可继续画下一个"
                store.toast = kinds.isEmpty ? "导线已连接" : "已识别 \(kinds) · 请填写参数并检查连接"
            } catch { if !Task.isCancelled { self.settings?.recognitionStatus = "笔迹已保留 · AI 识别暂不可用"; store.toast = error.localizedDescription } }
        }
    }
    func installNavigation(on view: UIView) {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched)); pinch.delegate = self; view.addGestureRecognizer(pinch)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned)); pan.minimumNumberOfTouches = 2; pan.delegate = self; view.addGestureRecognizer(pan)
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard let store else { return }
        if gesture.state == .began { pinchZoom = store.zoom }
        let p = gesture.location(in: gesture.view)
        store.changeZoom(pinchZoom * gesture.scale, at: Point(p.x, p.y))
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let store else { return }
        if gesture.state == .began { panOffset = store.offset }
        let p = gesture.translation(in: gesture.view); store.offset = panOffset + Point(p.x, p.y)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { !drawing && !pointerDrawing }
    func cancel() { recognitionTask?.cancel(); commitTask?.cancel() }
}

private final class NotebookInkContainer: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

struct IPadNotebookInkView: UIViewRepresentable {
    let model: IPadNotebookInk
    let store: EditorStore
    let settings: IPadNotebookSettings
    private let watchedCamera: CGAffineTransform
    private let watchedAnnotation: Data?
    private let watchedPending: Data?
    private let watchedTool: IPadNotebookTool
    private let watchedStyle: String
    init(model: IPadNotebookInk, store: EditorStore, settings: IPadNotebookSettings) {
        self.model = model; self.store = store; self.settings = settings
        watchedCamera = CGAffineTransform(a: store.zoom, b: 0, c: 0, d: store.zoom, tx: store.offset.x, ty: store.offset.y)
        watchedAnnotation = store.circuit.annotationDrawing; watchedPending = store.circuit.handDrawing
        watchedTool = settings.tool
        watchedStyle = "\(settings.inkColor)/\(settings.inkWidth)/\(settings.highlighter)/\(settings.eraseCircuit)/\(settings.erasePending)/\(settings.lassoInk)/\(settings.allowsFingerDrawing)/\(settings.preferredMOS?.rawValue ?? "auto")"
    }
    func makeUIView(context: Context) -> UIView {
        let view = NotebookInkContainer()
        model.installNavigation(on: view)
        for canvas in [model.annotation, model.pending] {
            canvas.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(canvas)
            NSLayoutConstraint.activate([canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor), canvas.topAnchor.constraint(equalTo: view.topAnchor), canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { model.update(store: store, settings: settings) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? { proposal.replacingUnspecifiedDimensions() }
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {}
}

struct IPadNotebookPointer: View {
    @Bindable var store: EditorStore
    let settings: IPadNotebookSettings
    let ink: IPadNotebookInk
    @State private var path: [Point] = []
    @State private var moving = false
    @State private var erased: Set<UUID> = []
    @State private var laser: [(Point, Date)] = []
    private var active: Bool { settings.tool == .laser || (settings.tool == .eraser && settings.eraseCircuit) || (settings.tool == .lasso && !settings.boxSelection && !settings.lassoInk && store.tool == .select && store.insertKind == nil && store.insertFigureKind == nil) }
    var body: some View {
        ZStack {
          TimelineView(.animation(minimumInterval: 1.0 / 30, paused: settings.tool != .laser)) { timeline in
            Canvas { context, _ in
                if !path.isEmpty, settings.tool == .lasso {
                    var line = Path(); line.addLines(path.map { CGPoint(x: $0.x, y: $0.y) }); line.closeSubpath()
                    context.fill(line, with: .color(.blue.opacity(0.08))); context.stroke(line, with: .color(.blue), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                let visible = laser.filter { timeline.date.timeIntervalSince($0.1) < 0.8 }
                for pair in zip(visible, visible.dropFirst()) {
                    var line = Path(); line.move(to: CGPoint(x: pair.0.0.x, y: pair.0.0.y)); line.addLine(to: CGPoint(x: pair.1.0.x, y: pair.1.0.y))
                    context.stroke(line, with: .color(.red.opacity(max(0, 1 - timeline.date.timeIntervalSince(pair.0.1) / 0.8))), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
                if let last = visible.last { context.fill(Path(ellipseIn: CGRect(x: last.0.x - 5, y: last.0.y - 5, width: 10, height: 10)), with: .color(.red)) }
            }
          }.allowsHitTesting(false)
          NotebookPointerInput(ink: ink, allowsFinger: settings.allowsFingerDrawing, changed: { point, start in
                if settings.tool == .laser { laser.append((point, Date())); if laser.count > 100 { laser.removeFirst(laser.count - 100) }; return }
                if settings.tool == .eraser {
                    let previous = path.last ?? point
                    let steps = max(1, Int(ceil(previous.distance(to: point) / 5)))
                    for i in 0...steps { if let id = store.hit(store.world(previous + (point - previous) * (Double(i) / Double(steps)))) { erased.insert(id) } }
                    path.append(point); store.selection = erased; return
                }
                if path.isEmpty {
                    moving = store.hit(store.world(start)).map { store.selection.contains($0) } ?? false
                    if moving { store.pointerDown(start) }
                    path = [start]
                }
                if moving { store.pointerDragged(point) } else if path.last!.distance(to: point) > 2 { path.append(point) }
          }, ended: { point in
                if settings.tool == .eraser { erase(); return }
                guard settings.tool == .lasso else { return }
                if moving { store.pointerUp(point) }
                else if path.count < 3 { store.selection = store.hit(store.world(point)).map { [$0] } ?? [] }
                else {
                    let polygon = path.map { store.world($0) }
                    var ids = Set(store.circuit.components.filter { CircuitInkRecognizer.contains($0.position, in: polygon) }.map(\.id))
                    ids.formUnion(store.circuit.figures.filter { CircuitInkRecognizer.contains($0.position, in: polygon) }.map(\.id))
                    ids.formUnion(store.circuit.labels.filter { CircuitInkRecognizer.contains($0.position, in: polygon) }.map(\.id))
                    ids.formUnion(store.circuit.wires.filter { store.circuit.resolvedPoints($0).contains { CircuitInkRecognizer.contains($0, in: polygon) } }.map(\.id))
                    store.selection = ids
                }
                path.removeAll(); moving = false
          }, cancelled: { path.removeAll(); erased.removeAll(); moving = false })
        }.allowsHitTesting(active)
            .onChange(of: settings.tool) { _, _ in path.removeAll(); laser.removeAll(); erased.removeAll(); moving = false }
    }
    private func erase() {
        let points = path.map { store.world($0) }, radius = 12 / store.zoom
        func cleared(_ data: Data?) -> Data? {
            guard settings.erasePending, let data, let drawing = try? PKDrawing(data: data) else { return data }
            let kept = drawing.strokes.filter { stroke in
                for range in stroke.maskedPathRanges {
                    for sample in stroke.path.interpolatedPoints(in: range, by: .distance(3)) {
                        let p = sample.location.applying(stroke.transform), q = Point(p.x, p.y)
                        if points.count == 1, q.distance(to: points[0]) <= radius { return false }
                        if zip(points, points.dropFirst()).contains(where: { distanceToSegment(q, $0, $1) <= radius }) { return false }
                    }
                }
                return true
            }
            return kept.count == drawing.strokes.count ? data : PKDrawing(strokes: kept).dataRepresentation()
        }
        store.transaction("Erase circuit and ink") { circuit in
            circuit.components.removeAll { erased.contains($0.id) }
            circuit.wires.removeAll { erased.contains($0.id) || $0.start.map { erased.contains($0.componentID) } == true || $0.end.map { erased.contains($0.componentID) } == true }
            circuit.labels.removeAll { erased.contains($0.id) }
            circuit.handDrawing = cleared(circuit.handDrawing)
            circuit.annotationDrawing = cleared(circuit.annotationDrawing)
        }
        store.selection.removeAll(); erased.removeAll(); path.removeAll()
    }
}

/// SwiftUI DragGesture accepts palms as well as Pencil. Filter the touch type
/// at UIKit's recognizer so every notebook tool follows the same input policy.
private final class NotebookStrokeGesture: UIGestureRecognizer {
    var first = CGPoint.zero, current = CGPoint.zero
    private var tracked: UITouch?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, touches.count == 1, let touch = touches.first else { state = tracked == nil ? .failed : .cancelled; return }
        tracked = touch; first = touch.location(in: view); current = first; state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        current = tracked.location(in: view); state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        current = tracked.location(in: view); state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() { tracked = nil }
}

private struct NotebookPointerInput: UIViewRepresentable {
    let ink: IPadNotebookInk
    let allowsFinger: Bool
    let changed: (Point, Point) -> Void
    let ended: (Point) -> Void
    let cancelled: () -> Void
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var input: NotebookPointerInput
        let gesture = NotebookStrokeGesture()
        init(_ input: NotebookPointerInput) { self.input = input; super.init(); gesture.addTarget(self, action: #selector(handle)); gesture.delegate = self }
        @objc func handle() {
            let point = Point(gesture.current.x, gesture.current.y), start = Point(gesture.first.x, gesture.first.y)
            switch gesture.state {
            case .began: input.ink.pointerDrawing = true; input.changed(point, start)
            case .changed: input.changed(point, start)
            case .ended: input.ink.pointerDrawing = false; input.ended(point)
            case .cancelled, .failed: input.ink.pointerDrawing = false; input.cancelled()
            default: break
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear; view.isMultipleTouchEnabled = true
        ink.installNavigation(on: view); view.addGestureRecognizer(context.coordinator.gesture)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.input = self
        context.coordinator.gesture.allowedTouchTypes = allowsFinger ? [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)] : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? { proposal.replacingUnspecifiedDimensions() }
}
#endif
