#if os(iOS)
import SwiftUI
import PencilKit
import Observation
import UIKit

@MainActor @Observable private final class CircuitPencilDrawing: NSObject, PKCanvasViewDelegate {
    let canvas = PKCanvasView()
    var revision = 0
    var loadError: String?
    var allowsFingerDrawing = false { didSet { canvas.drawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly } }
    private var displayTransform = CGAffineTransform.identity
    var worldDrawing: PKDrawing { canvas.drawing.transformed(using: displayTransform.inverted()) }
    init(data: Data?) {
        super.init()
        canvas.backgroundColor = .clear; canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly; canvas.isScrollEnabled = false
        canvas.tool = PKInkingTool(.pen, color: .black, width: 2.5)
        canvas.accessibilityLabel = "Hand-drawn circuit canvas"
        if let data {
            do {
                let original = try PKDrawing(data: data)
                if !original.strokes.isEmpty {
                    displayTransform = CGAffineTransform(translationX: 40 - original.bounds.minX, y: 40 - original.bounds.minY)
                }
                canvas.drawing = original.transformed(using: displayTransform)
            }
            catch { loadError = "The saved sketch could not be opened. Its original data is preserved until you draw a new sketch." }
        }
        canvas.delegate = self
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { revision += 1 }
    func strokeInput() throws -> (strokes: [CircuitInkStroke], origins: [Int]) {
        guard canvas.drawing.strokes.count <= 500 else { throw CircuitError.message("Split this sketch into smaller circuits (up to 500 strokes).") }
        var result: [CircuitInkStroke] = [], origins: [Int] = [], count = 0
        for (index, stroke) in worldDrawing.strokes.enumerated() {
            // Use visible ranges so erased portions never become hidden wires.
            let ranges = stroke.maskedPathRanges
            for range in ranges {
                var points: [Point] = []
                for point in stroke.path.interpolatedPoints(in: range, by: .distance(2)) {
                    count += 1
                    guard count <= 30_000 else { throw CircuitError.message("Split this detailed sketch into smaller circuits.") }
                    let location = point.location.applying(stroke.transform)
                    points.append(Point(location.x, location.y))
                }
                if points.count > 1 { result.append(CircuitInkStroke(points)); origins.append(index) }
            }
        }
        return (result, origins)
    }
    func strokes() throws -> [CircuitInkStroke] { try strokeInput().strokes }
    func imageData() throws -> Data {
        let bounds = canvas.drawing.bounds.insetBy(dx: -24, dy: -24)
        guard !canvas.drawing.strokes.isEmpty, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw CircuitError.message("Draw a circuit first.") }
        let scale = min(2, 2048 / max(bounds.width, bounds.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            canvas.drawing.image(from: bounds, scale: scale).draw(in: CGRect(origin: .zero, size: CGSize(width: bounds.width * scale, height: bounds.height * scale)))
        }
        guard let data = image.pngData() else { throw CircuitError.message("Could not export the drawing.") }
        return data
    }
    func loadExample() {
        displayTransform = .identity
        let ink = PKInk(.pen, color: .black)
        canvas.drawing = PKDrawing(strokes: CircuitInkRecognizer.example.map { stroke in
            // Dense points preserve deliberate corners through PencilKit smoothing.
            var points = [stroke.points[0]]
            for (a, b) in zip(stroke.points, stroke.points.dropFirst()) {
                let steps = max(1, Int(ceil(a.distance(to: b) / 2)))
                for i in 1...steps { points.append(a + (b - a) * (Double(i) / Double(steps))) }
            }
            let path = PKStrokePath(controlPoints: points.enumerated().map { index, p in
                PKStrokePoint(location: CGPoint(x: p.x, y: p.y), timeOffset: Double(index) * 0.015, size: CGSize(width: 2.5, height: 2.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: Date())
            return PKStroke(ink: ink, path: path)
        })
        revision += 1
    }
}

private struct CircuitPencilCanvas: UIViewRepresentable {
    let model: CircuitPencilDrawing
    func makeUIView(context: Context) -> PKCanvasView { model.canvas }
    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}

struct HandDrawnCircuitView: View {
    @Bindable var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var drawing: CircuitPencilDrawing
    @State private var recognition: CircuitInkResult?
    @State private var task: Task<Void, Never>?
    @State private var recognizing = false
    @State private var erasing = false
    @State private var includeWires = false
    @State private var error: String?
    @State private var savedRevision = 0
    @State private var replaceAction: String?
    @State private var assistantImage: Data?
    @State private var assistantSheet = false
    init(store: EditorStore) { self.store = store; _drawing = State(initialValue: CircuitPencilDrawing(data: store.circuit.handDrawing)) }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 12) {
                    controls
                    Text("A small neural network recognizes common hand-drawn symbols offline. Draw one complete symbol at a time; uncertain and unsupported ink is preserved. MOS defaults to NMOS; review polarity, parameters and pins.")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal)
                    if geometry.size.width >= 900 {
                        HStack(alignment: .top, spacing: 16) { sketch; review.frame(width: 300) }
                    } else {
                        VStack(spacing: 12) { sketch.frame(minHeight: 250, maxHeight: geometry.size.height * 0.57); review }
                    }
                    if let message = error ?? drawing.loadError { Text(message).font(.callout).foregroundStyle(.red).padding(.horizontal) }
                }.padding(16)
            }
            .navigationTitle("Hand-drawn circuit")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { if save() { dismiss() } } } }
            .confirmationDialog("Replace the current sketch?", isPresented: Binding(get: { replaceAction != nil }, set: { if !$0 { replaceAction = nil } }), titleVisibility: .visible) {
                Button(replaceAction == "example" ? "Load example" : "Clear sketch", role: .destructive) { replaceSketch(replaceAction ?? "clear"); replaceAction = nil }
                Button("Cancel", role: .cancel) { replaceAction = nil }
            } message: { Text("The editable circuit on your canvas is preserved.") }
            .sheet(isPresented: $assistantSheet) { CircuitAssistantView(store: store, initialImage: assistantImage) }
            .onChange(of: drawing.revision) { _, _ in task?.cancel(); recognition = nil; recognizing = false; error = nil }
            .onChange(of: erasing) { _, value in drawing.canvas.tool = value ? PKEraserTool(.vector) : PKInkingTool(.pen, color: .black, width: 2.5) }
            .onDisappear { task?.cancel(); _ = save() }
        }
    }
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack { drawingTools; Spacer(); recognitionTools }
            VStack(spacing: 8) { HStack { drawingTools; Spacer() }; HStack { recognitionTools; Spacer() } }
        }.buttonStyle(.bordered)
    }
    private var drawingTools: some View {
        HStack(spacing: 8) {
            Picker("Drawing tool", selection: $erasing) { Label("Pen", systemImage: "pencil.tip").tag(false); Label("Eraser", systemImage: "eraser").tag(true) }.pickerStyle(.segmented).frame(width: 180)
            Button { drawing.canvas.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!(drawing.canvas.undoManager?.canUndo ?? false)).accessibilityLabel("Undo drawing")
            Button { drawing.canvas.undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!(drawing.canvas.undoManager?.canRedo ?? false)).accessibilityLabel("Redo drawing")
            Menu { Toggle("允许手指绘图", isOn: $drawing.allowsFingerDrawing); Button("Load R–C example") { requestReplacement("example") }; Button("Clear sketch", role: .destructive) { requestReplacement("clear") } } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Sketch options")
        }
    }
    private var recognitionTools: some View {
        HStack {
            Button(action: recognize) { Label(recognizing ? "Recognizing…" : "Recognize drawing", systemImage: "sparkles") }.buttonStyle(.borderedProminent).disabled(recognizing || drawing.canvas.drawing.strokes.isEmpty)
            if !(Bundle.main.object(forInfoDictionaryKey: "CircuitAIServiceURL") as? String ?? "").isEmpty {
                Button("Cloud analysis") { do { assistantImage = try drawing.imageData(); assistantSheet = true } catch { self.error = error.localizedDescription } }.disabled(drawing.canvas.drawing.strokes.isEmpty)
            }
        }
    }
    private var sketch: some View {
        CircuitPencilCanvas(model: drawing)
            .background {
                Canvas { context, size in
                    var grid = Path()
                    for x in stride(from: 0.0, through: size.width, by: 20) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
                    for y in stride(from: 0.0, through: size.height, by: 20) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                    context.stroke(grid, with: .color(.black.opacity(0.055)), lineWidth: 0.5)
                }.background(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.25)))
    }
    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Review recognition").font(.headline)
                if recognizing { ProgressView("Recognizing strokes on this iPad…") }
                if let result = recognition {
                    Text("\(result.components.count) component candidates · \(result.wires.count) wire candidates").font(.subheadline)
                    Text("\(result.unrecognizedStrokes) strokes were not recognized. Check source type and polarity, missing symbols, values and every connection.").font(.caption).foregroundStyle(.secondary)
                    if let preview = try? result.circuit(includeWires: includeWires) { CircuitInkPreview(circuit: preview).frame(height: 220) }
                    ForEach(result.components) { candidate in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Include \(candidate.kind.title)", isOn: binding(candidate, \.included))
                            Picker("Type", selection: binding(candidate, \.kind)) { ForEach(ComponentKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                            Picker("Rotation", selection: binding(candidate, \.rotation)) { ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) } }
                            if candidate.kind.defaultParameters["value"] != nil { TextField("Value (for example 10k or 10n)", text: binding(candidate, \.value)).textFieldStyle(.roundedBorder).autocorrectionDisabled() }
                        }.padding(.vertical, 4)
                        Divider()
                    }
                    Toggle("Include suggested wires", isOn: $includeWires)
                    Text("Wire crossings have no inferred junction dots. Unknown values stay blank. Complete and check the imported circuit before simulation.").font(.caption).foregroundStyle(.secondary)
                    Button("Import reviewed circuit", action: importCircuit).buttonStyle(.borderedProminent).disabled(!result.components.contains { $0.included })
                } else if !recognizing {
                    Text("Draw with Apple Pencil, then tap Recognize drawing. Finger drawing can be enabled in Sketch options. For instant conversion as you draw, use 电路笔 on the main canvas. The sketch is saved with your document.").font(.callout).foregroundStyle(.secondary)
                    Text("Recognition is free and offline. No Apple Intelligence is used.").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
    private func binding<Value>(_ candidate: CircuitInkComponent, _ key: WritableKeyPath<CircuitInkComponent, Value>) -> Binding<Value> {
        Binding(get: { recognition?.components.first { $0.id == candidate.id }?[keyPath: key] ?? candidate[keyPath: key] }, set: { value in
            if let i = recognition?.components.firstIndex(where: { $0.id == candidate.id }) { recognition?.components[i][keyPath: key] = value }
        })
    }
    private func requestReplacement(_ action: String) { if drawing.canvas.drawing.strokes.isEmpty { replaceSketch(action) } else { replaceAction = action } }
    private func replaceSketch(_ action: String) { if action == "example" { drawing.loadExample() } else { drawing.canvas.drawing = PKDrawing(); drawing.revision += 1 }; drawing.loadError = nil }
    @discardableResult private func save() -> Bool {
        guard drawing.revision != savedRevision else { return true }
        let data = drawing.worldDrawing.dataRepresentation()
        guard data.count <= 5_000_000 else { error = "This sketch exceeds 5 MB. Remove some strokes before saving."; return false }
        store.transaction("Save hand drawing") { $0.handDrawing = data }; savedRevision = drawing.revision
        return true
    }
    private func recognize() {
        guard save() else { return }
        do {
            let strokes = try drawing.strokes()
            guard !strokes.isEmpty else { throw CircuitError.message("Draw at least one symbol first.") }
            error = nil; recognizing = true; recognition = nil
            task = Task {
                defer { if !Task.isCancelled { recognizing = false } }
                do {
                    let worker = Task.detached(priority: .userInitiated) { try CircuitHandwritingRecognizer.recognize(strokes) }
                    let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation(); recognition = result
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func importCircuit() {
        do {
            guard let recognition, save() else { return }
            let circuit = try recognition.circuit(includeWires: includeWires)
            let payload = EditorStore.SelectionPayload(components: circuit.components, wires: circuit.wires, labels: [])
            let shift = store.circuit.components.isEmpty ? Point.zero : Point(store.circuit.bounds.maxX + 160 - circuit.bounds.minX, store.circuit.bounds.minY - circuit.bounds.minY)
            // Converted ink leaves the pending layer so the circuit pen cannot
            // create duplicate components on the next stroke. Undo restores both.
            var consumed = Set(recognition.components.filter(\.included).flatMap(\.strokeIndices))
            if includeWires { consumed.formUnion(recognition.wireInkStrokeIndices) }
            let origins = try drawing.strokeInput().origins
            guard let removed = CircuitInkResult.completeStrokeOrigins(origins, consuming: consumed) else { throw CircuitError.message("A partly erased stroke contains unrecognized ink. Complete or separate it before importing; all ink has been preserved.") }
            let remaining = PKDrawing(strokes: drawing.worldDrawing.strokes.enumerated().filter { !removed.contains($0.offset) }.map(\.element))
            store.paste(try JSONEncoder().encode(payload), displacement: shift, replacingHandDrawing: remaining.dataRepresentation())
            store.fit(); store.toast = "Hand-drawn circuit imported · review values and connections"
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct CircuitInkPreview: View {
    let circuit: Circuit
    var body: some View {
        Canvas { context, size in
            let bounds = circuit.bounds, scale = min(size.width / bounds.width, size.height / bounds.height) * 0.9
            context.withCGContext { cg in
                cg.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
                cg.scaleBy(x: scale, y: scale); cg.translateBy(x: -bounds.minX, y: -bounds.minY)
                CircuitRenderer.draw(circuit, in: cg)
            }
        }.background(.white).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Editable circuit recognition preview")
    }
}
#endif
