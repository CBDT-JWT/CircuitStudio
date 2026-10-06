import SwiftUI
import Observation

enum CanvasTool: String, CaseIterable, Identifiable {
    case select = "Select", wire = "Wire", connector = "Arrow", pan = "Pan", label = "Label", probe = "Probe"
    var id: String { rawValue }
    var icon: String { switch self { case .select: "cursorarrow"; case .wire: "point.topleft.down.to.point.bottomright.curvepath"; case .connector: "arrow.up.right"; case .pan: "hand.draw"; case .label: "textformat"; case .probe: "waveform.path" } }
    var shortcut: String { switch self { case .select: "Esc"; case .wire: "W"; case .connector: "L"; case .pan: "Space"; case .label: "T"; case .probe: "B" } }
}

@MainActor @Observable final class EditorStore {
    var circuit: Circuit
    var selection: Set<UUID> = []
    var tool: CanvasTool = .select
    var zoom = 1.0; var offset = Point(); var viewport = CGSize(width: 900, height: 700)
    var showGrid = true; var snapEnabled = true; var showLibrary = true; var showInspector = true
    var showPalette = false; var paletteQuery = ""; var showTemplates = false; var showExport = false; var showImport = false; var showSimulationSettings = false; var showModels = false
    var inspectorUsesSheet = false; var inspectorRequested = false
    var insertKind: ComponentKind?; var insertionPoint: Point?
    var insertFigureKind: FigureKind?; var connectorRoute: FigureRoute = .straight
    var error: String?; var toast: String?; var labelPoint: Point?; var labelText = "V_{OUT}"
    var simulationResult: SimulationResult?; var isSimulating = false; var showWaveforms = false; var annotateOP = false
    #if os(macOS)
    @ObservationIgnored weak var documentWindow: NSWindow?
    func openSimulationResult(inNewTab: Bool) {
        guard supportsSimulation, let result = simulationResult else { return }
        SimulationResultWindow.open(result, title: circuit.title, probes: circuit.simulation.probes, sourceWindow: documentWindow, inNewTab: inNewTab)
    }
    #endif
    var draftWire: [Point] = []; var draftStart: TerminalRef?; var hoverTerminal: Point?
    var marquee: Bounds?; var hasFitted = false; var undoManager: UndoManager?
    private var gestureStart: Point?; private var gestureSnapshot: Circuit?; private var gestureUndoSnapshot: Circuit?; private var originalOffset: Point?
    private var movingIDs: Set<UUID> = []; private var isMarquee = false; private var isPanning = false
    private var draftOrigin: Point?; private var didMove = false
    private var drawingConnector = false
    private var resizingFigure: UUID?; private var resizeFixed: Point?
    private var editingConnector: (UUID, Bool)?
    private var fallbackUndo: [Circuit] = []; private var fallbackRedo: [Circuit] = []
    var canUndo: Bool { undoManager?.canUndo ?? !fallbackUndo.isEmpty }
    var canRedo: Bool { undoManager?.canRedo ?? !fallbackRedo.isEmpty }
    var selectedComponent: Component? { circuit.components.first { selection.contains($0.id) } }
    var selectedLabel: CircuitLabel? { circuit.labels.first { selection.contains($0.id) } }
    var selectedWire: Wire? { circuit.wires.first { selection.contains($0.id) } }
    var selectedFigure: FigureElement? { circuit.figures.first { selection.contains($0.id) } }
    var selectedConnector: FigureConnector? { circuit.figureConnectors.first { selection.contains($0.id) } }
    var isPaperOnly: Bool { circuit.purpose == .illustration }
    var supportsSimulation: Bool { circuit.purpose.supportsSimulation }
    var availableTools: [CanvasTool] { supportsSimulation ? CanvasTool.allCases : [.select, .connector, .pan, .label] }
    func setPurpose(_ purpose: CanvasPurpose) {
        guard purpose != circuit.purpose else { return }
        cancel(); selection.removeAll(); labelPoint = nil
        transaction("Change canvas mode") { $0.purpose = purpose }
        showWaveforms = false; showSimulationSettings = false; showModels = false
    }
    func activateTool(_ requested: CanvasTool) {
        cancel()
        tool = requested == .wire && !supportsSimulation ? .connector : requested == .probe && !supportsSimulation ? .select : requested
    }
    var selectionTitle: String { selection.count > 1 ? "\(selection.count) objects" : selectedComponent?.kind.title ?? selectedFigure?.kind.rawValue ?? (selectedConnector != nil ? "Arrow" : selectedLabel != nil ? "Net label" : selectedWire != nil ? "Wire" : "Document") }
    init(_ circuit: Circuit) { self.circuit = circuit }
    func transaction(_ name: String, _ action: (inout Circuit) -> Void) {
        let before = circuit; action(&circuit); if before != circuit { record(before, name: name) }
    }
    private func record(_ before: Circuit, name: String) {
        if let undoManager { undoManager.registerUndo(withTarget: self) { store in MainActor.assumeIsolated { store.restore(before, name: name) } }; undoManager.setActionName(name) }
        else { fallbackUndo.append(before); if fallbackUndo.count > 100 { fallbackUndo.removeFirst() }; fallbackRedo.removeAll() }
        simulationResult = nil; annotateOP = false
    }
    private func restore(_ snapshot: Circuit, name: String) {
        let current = circuit; circuit = snapshot; selection = selection.intersection(circuit.objectIDs)
        undoManager?.registerUndo(withTarget: self) { store in MainActor.assumeIsolated { store.restore(current, name: name) } }; undoManager?.setActionName(name)
        simulationResult = nil
    }
    func undo() { if let undoManager { undoManager.undo() } else if let before = fallbackUndo.popLast() { fallbackRedo.append(circuit); circuit = before } }
    func redo() { if let undoManager { undoManager.redo() } else if let after = fallbackRedo.popLast() { fallbackUndo.append(circuit); circuit = after } }
    func updateComponent(_ id: UUID, _ action: (inout Component) -> Void) { transaction("Edit component") { if let i = $0.components.firstIndex(where: { $0.id == id }) { action(&$0.components[i]) } } }
    func updateFigure(_ id: UUID, _ action: (inout FigureElement) -> Void) { transaction("Edit figure") { if let i = $0.figures.firstIndex(where: { $0.id == id }) { action(&$0.figures[i]) } } }
    func updateConnector(_ id: UUID, _ action: (inout FigureConnector) -> Void) { transaction("Edit arrow") { if let i = $0.figureConnectors.firstIndex(where: { $0.id == id }) { action(&$0.figureConnectors[i]) } } }
    func fit() {
        if circuit.objectIDs.isEmpty { zoom = 1; offset = Point(viewport.width / 2, viewport.height / 2); hasFitted = true; return }
        let bounds = circuit.bounds; zoom = min(1.65, max(0.1, min((viewport.width - 110) / bounds.width, (viewport.height - 130) / bounds.height)))
        offset = Point(viewport.width / 2, viewport.height / 2) - bounds.center * zoom; hasFitted = true
    }
    func world(_ screen: Point) -> Point { (screen - offset) * (1 / zoom) }
    func screen(_ world: Point) -> Point { world * zoom + offset }
    func changeZoom(_ scale: Double, at anchor: Point? = nil) {
        let anchor = anchor ?? Point(viewport.width / 2, viewport.height / 2); let p = world(anchor)
        zoom = max(0.1, min(20, scale)); offset = anchor - p * zoom
    }
    func snap(_ p: Point) -> Point {
        if let pin = nearestTerminal(p, tolerance: 12 / zoom) { return pin.1 }
        for q in circuit.wires.flatMap({ circuit.resolvedPoints($0) }) where p.distance(to: q) < 10 / zoom { return q }
        return snapEnabled ? p.snapped() : p
    }
    func nearestTerminal(_ p: Point, tolerance: Double? = nil) -> (TerminalRef, Point)? {
        let pins = circuit.components.flatMap { c in c.pins.map { (TerminalRef(c.id, $0.name), c.world($0.offset)) } }
        return pins.filter { $0.1.distance(to: p) < (tolerance ?? 10 / zoom) }.min { $0.1.distance(to: p) < $1.1.distance(to: p) }
    }
    func nearestFigureAnchor(_ p: Point) -> (TerminalRef, Point)? {
        let anchors = circuit.figures.flatMap { f in f.anchors.map { (TerminalRef(f.id, $0.name), f.world($0.offset)) } }
        let figure = anchors.filter { $0.1.distance(to: p) < 14 / zoom }.min { $0.1.distance(to: p) < $1.1.distance(to: p) }
        return figure ?? nearestTerminal(p)
    }
    func connectorSnap(_ p: Point) -> Point { nearestFigureAnchor(p)?.1 ?? (snapEnabled ? p.snapped() : p) }
    func connectorPath(from a: Point, to b: Point) -> [Point] { connectorRoute == .straight ? [a, b] : WireRouting.route(from: a, to: b, obstacles: circuit.figures.map(\.bounds) + circuit.components.map(\.bodyBounds)) }
    func hit(_ p: Point) -> UUID? {
        if let f = circuit.figures.reversed().first(where: { $0.bounds.contains(p, margin: 5 / zoom) }) { return f.id }
        if let c = circuit.components.reversed().first(where: { $0.bodyBounds.contains(p, margin: 8 / zoom) }) { return c.id }
        if let label = circuit.labels.reversed().first(where: { Bounds([$0.position + Point(0, -24), $0.position + Point(Double($0.text.count) * 8, 5)]).contains(p, margin: 4 / zoom) }) { return label.id }
        if let arrow = circuit.figureConnectors.reversed().first(where: { connector in let ps = circuit.resolvedPoints(connector); return zip(ps, ps.dropFirst()).contains { distanceToSegment(p, $0, $1) < 7 / zoom } }) { return arrow.id }
        return circuit.wires.reversed().first { wire in let ps = circuit.resolvedPoints(wire); return zip(ps, ps.dropFirst()).contains { distanceToSegment(p, $0, $1) < 6 / zoom } }?.id
    }
    func hover(_ screenPoint: Point) { let p = world(screenPoint); hoverTerminal = (tool == .connector ? nearestFigureAnchor(p) : nearestTerminal(p))?.1; if let draftOrigin { draftWire = drawingConnector ? connectorPath(from: draftOrigin, to: connectorSnap(p)) : WireRouting.route(from: draftOrigin, to: snap(p), obstacles: circuit.components.map(\.bodyBounds)) } }
    func pointerDown(_ screenPoint: Point, extend: Bool = false, duplicate: Bool = false, pan: Bool = false, double: Bool = false) {
        let p = world(screenPoint); gestureStart = p; gestureSnapshot = circuit; gestureUndoSnapshot = circuit; originalOffset = offset; didMove = false
        if pan || tool == .pan { isPanning = true; return }
        if let kind = insertKind { insert(kind, at: snap(p)); insertKind = nil; return }
        if let kind = insertFigureKind { insertFigure(kind, at: snapEnabled ? p.snapped() : p); insertFigureKind = nil; return }
        if double {
            if let id = hit(p) { selection = [id]; revealInspector() }
            else { insertionPoint = snap(p); paletteQuery = ""; showPalette = true }
            return
        }
        if tool == .label { if supportsSimulation { labelPoint = snap(p); labelText = "V_{OUT}" } else { insertFigure(.text, at: connectorSnap(p)); revealInspector() }; return }
        if tool == .probe { probe(p); return }
        if tool == .connector {
            if !draftWire.isEmpty { finishWire(at: connectorSnap(p)); return }
            drawingConnector = true; draftOrigin = connectorSnap(p); draftStart = nearestFigureAnchor(p)?.0; draftWire = [connectorSnap(p), connectorSnap(p)]; return
        }
        if tool == .select {
            for f in circuit.figures where selection.contains(f.id) {
                let corners = [Point(-f.size.x / 2, -f.size.y / 2), Point(f.size.x / 2, -f.size.y / 2), Point(f.size.x / 2, f.size.y / 2), Point(-f.size.x / 2, f.size.y / 2)]
                if let corner = corners.first(where: { f.world($0).distance(to: p) < 10 / zoom }) { resizingFigure = f.id; resizeFixed = f.world(corner * -1); return }
            }
            if let connector = selectedConnector { let points = circuit.resolvedPoints(connector); if let first = points.first, first.distance(to: p) < 12 / zoom { editingConnector = (connector.id, true); return }; if let last = points.last, last.distance(to: p) < 12 / zoom { editingConnector = (connector.id, false); return } }
        }
        if supportsSimulation && (tool == .wire || nearestTerminal(p) != nil || !draftWire.isEmpty) {
            if !draftWire.isEmpty { finishWire(at: snap(p)); return }
            draftOrigin = snap(p); draftStart = nearestTerminal(p)?.0; draftWire = [snap(p), snap(p)]; return
        }
        if let id = hit(p) {
            if extend { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }
            else if !selection.contains(id) { selection = [id] }
            if duplicate { paste(selectionData(), displacement: .zero, recordUndo: false); gestureSnapshot = circuit }
            movingIDs = selection
        } else { if !extend { selection.removeAll() }; isMarquee = true; marquee = Bounds([p, p]) }
    }
    func pointerDragged(_ screenPoint: Point) {
        guard let start = gestureStart else { return }; let p = world(screenPoint); let delta = p - start
        didMove = didMove || delta.distance(to: .zero) > 2 / zoom
        if isPanning, let originalOffset { offset = originalOffset + delta * zoom; return }
        if let draftOrigin { draftWire = drawingConnector ? connectorPath(from: draftOrigin, to: connectorSnap(p)) : WireRouting.route(from: draftOrigin, to: snap(p), obstacles: circuit.components.map(\.bodyBounds)); return }
        if let id = resizingFigure, let fixed = resizeFixed, let i = circuit.figures.firstIndex(where: { $0.id == id }) {
            let end = snapEnabled ? p.snapped() : p
            let local = (end - fixed).transformed(rotation: 360 - circuit.figures[i].rotation, flipX: false, flipY: false)
            circuit.figures[i].position = (fixed + end) * 0.5
            circuit.figures[i].size = Point(max(2, abs(local.x)), max(2, abs(local.y))); return
        }
        if let (id, first) = editingConnector, let i = circuit.figureConnectors.firstIndex(where: { $0.id == id }) {
            let index = first ? 0 : circuit.figureConnectors[i].points.count - 1
            circuit.figureConnectors[i].points[index] = connectorSnap(p)
            if first { circuit.figureConnectors[i].start = nearestFigureAnchor(p)?.0 } else { circuit.figureConnectors[i].end = nearestFigureAnchor(p)?.0 }; return
        }
        if isMarquee { marquee = Bounds([start, p]); return }
        guard let before = gestureSnapshot else { return }
        let shift = snapEnabled ? delta.snapped() : delta
        for i in circuit.components.indices where movingIDs.contains(circuit.components[i].id) {
            if let original = before.components.first(where: { $0.id == circuit.components[i].id }) { circuit.components[i].position = original.position + shift }
            else if let original = circuit.components.first(where: { $0.id == circuit.components[i].id }) { circuit.components[i].position = (original.position + delta).snapped() }
        }
        for i in circuit.labels.indices where movingIDs.contains(circuit.labels[i].id) { if let original = before.labels.first(where: { $0.id == circuit.labels[i].id }) { circuit.labels[i].position = original.position + shift } }
        for i in circuit.figures.indices where movingIDs.contains(circuit.figures[i].id) { if let original = before.figures.first(where: { $0.id == circuit.figures[i].id }) { circuit.figures[i].position = original.position + shift } }
        for i in circuit.figureConnectors.indices where movingIDs.contains(circuit.figureConnectors[i].id) {
            if let original = before.figureConnectors.first(where: { $0.id == circuit.figureConnectors[i].id }) {
                circuit.figureConnectors[i].points = before.resolvedPoints(original).map { $0 + shift }
                if original.start.map({ movingIDs.contains($0.componentID) }) != true { circuit.figureConnectors[i].start = nil }
                if original.end.map({ movingIDs.contains($0.componentID) }) != true { circuit.figureConnectors[i].end = nil }
            }
        }
    }
    func pointerUp(_ screenPoint: Point) {
        if isMarquee, let marquee { selection.formUnion(circuit.components.filter { marquee.contains($0.position) }.map(\.id)); selection.formUnion(circuit.labels.filter { marquee.contains($0.position) }.map(\.id)); selection.formUnion(circuit.figures.filter { marquee.contains($0.position) }.map(\.id)) }
        if draftOrigin != nil && didMove { finishWire(at: drawingConnector ? connectorSnap(world(screenPoint)) : snap(world(screenPoint))) }
        if let before = gestureUndoSnapshot, before != circuit, !movingIDs.isEmpty || resizingFigure != nil || editingConnector != nil { record(before, name: resizingFigure != nil ? "Resize figure" : editingConnector != nil ? "Adjust arrow" : "Move objects") }
        gestureStart = nil; gestureSnapshot = nil; gestureUndoSnapshot = nil; movingIDs.removeAll(); isPanning = false; isMarquee = false; marquee = nil; originalOffset = nil
        resizingFigure = nil; resizeFixed = nil; editingConnector = nil
    }
    func finishWire(at point: Point) {
        guard let origin = draftOrigin, origin.distance(to: point) > 1 else { return }
        if drawingConnector {
            let start = draftStart, end = nearestFigureAnchor(point)?.0
            var connector = FigureConnector(from: origin, to: point, start: start, end: end); connector.route = connectorRoute
            transaction("Draw arrow") { $0.figureConnectors.append(connector) }; selection = [connector.id]
            draftWire = []; draftOrigin = nil; draftStart = nil; drawingConnector = false; return
        }
        let start = draftStart, end = nearestTerminal(point)?.0
        transaction("Draw wire") { $0.wires.append(Wire(points: WireRouting.route(from: origin, to: point, obstacles: $0.components.map(\.bodyBounds)), start: start, end: end)) }
        draftWire = []; draftOrigin = nil; draftStart = nil
    }
    func cancel() { insertKind = nil; insertFigureKind = nil; tool = .select; draftWire = []; draftOrigin = nil; draftStart = nil; hoverTerminal = nil; drawingConnector = false }
    func revealInspector() { if inspectorUsesSheet { inspectorRequested = true } else { showInspector = true } }
    func insert(_ kind: ComponentKind, at p: Point? = nil) {
        var id: UUID?; transaction("Add \(kind.title)") { id = $0.add(kind, at: p ?? world(Point(viewport.width / 2, viewport.height / 2)).snapped()) }
        if let id { selection = [id] }; tool = .select; toast = "\(kind.title) added"
    }
    func addLabel() {
        guard let p = labelPoint, !labelText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        transaction("Add net label") { $0.labels.append(CircuitLabel(labelText, at: p)) }; labelPoint = nil
    }
    func insertFigure(_ kind: FigureKind, at p: Point? = nil) {
        let figure = FigureElement(kind, at: p ?? world(Point(viewport.width / 2, viewport.height / 2)).snapped())
        transaction("Add \(kind.rawValue)") { $0.figures.append(figure) }; selection = [figure.id]; tool = .select; showInspector = true; toast = "\(kind.rawValue) added"
    }
    func insertPaperExample(_ example: PaperExample) {
        let paper = example.make(); let shift = world(Point(viewport.width / 2, viewport.height / 2)) - paper.bounds.center
        transaction("Insert paper figure") { circuit in circuit.figures += paper.figures.map { var f = $0; f.position = f.position + shift; return f }; circuit.figureConnectors += paper.figureConnectors.map { var c = $0; c.points = c.points.map { $0 + shift }; return c } }
        selection = Set(paper.figures.map(\.id)); fit()
    }
    func loadPaperExample(_ example: PaperExample) { transaction("Apply paper template") { $0 = example.make() }; selection.removeAll(); fit(); showTemplates = false }
    func deleteSelection() {
        transaction("Delete objects") { c in c.components.removeAll { selection.contains($0.id) }; c.wires.removeAll { selection.contains($0.id) || $0.start.map { selection.contains($0.componentID) } == true || $0.end.map { selection.contains($0.componentID) } == true }; c.labels.removeAll { selection.contains($0.id) }; c.figures.removeAll { selection.contains($0.id) }; c.figureConnectors.removeAll { selection.contains($0.id) || $0.start.map { selection.contains($0.componentID) } == true || $0.end.map { selection.contains($0.componentID) } == true } }; selection.removeAll()
    }
    func transformSelection(_ transform: String) {
        transaction(transform) { c in for i in c.components.indices where selection.contains(c.components[i].id) {
            if transform == "Rotate" { c.components[i].rotation = (c.components[i].rotation + 90) % 360 }
            else if transform == "Flip horizontal" { c.components[i].flipX.toggle() } else { c.components[i].flipY.toggle() }
        }; for i in c.figures.indices where selection.contains(c.figures[i].id) { if transform == "Rotate" { c.figures[i].rotation = (c.figures[i].rotation + 90) % 360 } } }
    }
    func duplicateSelection(recordUndo: Bool = true) {
        let before = circuit; let payload = selectionData(); paste(payload, displacement: Point(30, 30), recordUndo: false)
        if recordUndo && before != circuit { record(before, name: "Duplicate objects") }
    }
    struct SelectionPayload: Codable { var components: [Component]; var wires: [Wire]; var labels: [CircuitLabel]; var figures: [FigureElement]? = nil; var connectors: [FigureConnector]? = nil }
    func selectionData() -> Data? {
        let components = circuit.components.filter { selection.contains($0.id) }
        let ids = Set(components.map(\.id))
        let wires = circuit.wires.filter { selection.contains($0.id) || ($0.start.map { ids.contains($0.componentID) } == true && $0.end.map { ids.contains($0.componentID) } == true) }
        let figures = circuit.figures.filter { selection.contains($0.id) }; let allIDs = ids.union(figures.map(\.id))
        let connectors = circuit.figureConnectors.filter { selection.contains($0.id) || ($0.start.map { allIDs.contains($0.componentID) } == true && $0.end.map { allIDs.contains($0.componentID) } == true) }.map { original in var c = original; c.points = circuit.resolvedPoints(original); return c }
        return try? JSONEncoder().encode(SelectionPayload(components: components, wires: wires, labels: circuit.labels.filter { selection.contains($0.id) }, figures: figures, connectors: connectors))
    }
    func paste(_ data: Data?, displacement: Point = Point(30, 30), recordUndo: Bool = true) {
        guard let data, let payload = try? JSONDecoder().decode(SelectionPayload.self, from: data) else { return }
        let before = circuit; var mapping: [UUID: UUID] = [:]; selection.removeAll()
        for original in payload.components { let id = circuit.add(original.kind, at: original.position + displacement); var c = original; c.id = id; c.name = circuit.components.last!.name; c.position = original.position + displacement; circuit.components[circuit.components.count - 1] = c; mapping[original.id] = id; selection.insert(id) }
        for original in payload.figures ?? [] { var f = original; f.id = UUID(); f.position = f.position + displacement; circuit.figures.append(f); mapping[original.id] = f.id; selection.insert(f.id) }
        func ref(_ old: TerminalRef?) -> TerminalRef? { old.flatMap { r in mapping[r.componentID].map { TerminalRef($0, r.pin) } } }
        for original in payload.wires { let w = Wire(points: original.points.map { $0 + displacement }, start: ref(original.start), end: ref(original.end)); circuit.wires.append(w); selection.insert(w.id) }
        for original in payload.labels { let l = CircuitLabel(original.text, at: original.position + displacement, isNet: original.isNet); circuit.labels.append(l); selection.insert(l.id) }
        for original in payload.connectors ?? [] { var c = original; c.id = UUID(); c.points = c.points.map { $0 + displacement }; c.start = ref(original.start); c.end = ref(original.end); circuit.figureConnectors.append(c); selection.insert(c.id) }
        if recordUndo && before != circuit { record(before, name: "Paste objects") }
    }
    func loadTemplate(_ template: CircuitTemplate) { transaction("Apply template") { $0 = template.make() }; selection.removeAll(); fit(); showTemplates = false }
    func insertPattern(_ template: CircuitTemplate) {
        let pattern = template.make(); let payload = SelectionPayload(components: pattern.components, wires: pattern.wires, labels: pattern.labels)
        paste(try? JSONEncoder().encode(payload), displacement: world(Point(viewport.width / 2, viewport.height / 2)) - pattern.bounds.center); showPalette = false
    }
    func cleanUp() {
        transaction("Clean up circuit") { c in for i in c.components.indices { c.components[i].position = c.components[i].position.snapped(20) }; for i in c.wires.indices { let p = c.resolvedPoints(c.wires[i]); if let a = p.first, let b = p.last { c.wires[i].points = WireRouting.route(from: a, to: b, obstacles: c.components.map(\.bodyBounds)) } } }; toast = "Aligned to grid and rerouted wires"
    }
    func align(_ axis: String) {
        let points = circuit.components.filter { selection.contains($0.id) }.map(\.position) + circuit.figures.filter { selection.contains($0.id) }.map(\.position); guard points.count > 1 else { return }
        transaction("Align objects") { c in let avg = points.reduce(Point(), +) * (1 / Double(points.count)); for i in c.components.indices where selection.contains(c.components[i].id) { if axis == "horizontal" { c.components[i].position.y = avg.y.snappedValue } else { c.components[i].position.x = avg.x.snappedValue } }; for i in c.figures.indices where selection.contains(c.figures[i].id) { if axis == "horizontal" { c.figures[i].position.y = avg.y.snappedValue } else { c.figures[i].position.x = avg.x.snappedValue } } }
    }
    func distribute(_ axis: String) {
        let objects = (circuit.components.filter { selection.contains($0.id) }.map { ($0.id, $0.position) } + circuit.figures.filter { selection.contains($0.id) }.map { ($0.id, $0.position) }).sorted { axis == "horizontal" ? $0.1.x < $1.1.x : $0.1.y < $1.1.y }
        guard objects.count > 2, let first = objects.first, let last = objects.last else { return }
        transaction("Distribute objects") { c in for (index, object) in objects.enumerated() {
            let value = axis == "horizontal" ? first.1.x + (last.1.x - first.1.x) * Double(index) / Double(objects.count - 1) : first.1.y + (last.1.y - first.1.y) * Double(index) / Double(objects.count - 1)
            if let i = c.components.firstIndex(where: { $0.id == object.0 }) { if axis == "horizontal" { c.components[i].position.x = value } else { c.components[i].position.y = value } }
            if let i = c.figures.firstIndex(where: { $0.id == object.0 }) { if axis == "horizontal" { c.figures[i].position.x = value } else { c.figures[i].position.y = value } }
        } }
    }
    func renumber() { transaction("Renumber circuit") { c in c.nameCounters = [:]; for i in c.components.indices where !c.components[i].kind.isConnection { let prefix = c.components[i].kind.prefix; c.nameCounters[prefix, default: 0] += 1; c.components[i].name = "\(prefix)\(c.nameCounters[prefix]!)" } } }
    func probe(_ p: Point) {
        guard supportsSimulation else { return }
        let topology = Connectivity(circuit)
        if let net = topology.nets.filter({ $0.name != "0" }).min(by: { ($0.points.map { $0.distance(to: p) }.min() ?? .infinity) < ($1.points.map { $0.distance(to: p) }.min() ?? .infinity) }), net.points.contains(where: { $0.distance(to: p) < 35 / zoom }) {
            transaction("Add voltage probe") { if !$0.simulation.probes.contains(net.name) { $0.simulation.probes.append(net.name) } }; toast = "Probe: V(\(net.name))"
        }
    }
    func runSimulation() {
        guard supportsSimulation, !isSimulating else { return }; isSimulating = true; let input = circuit
        Task {
            do { let result = try await Task.detached(priority: .userInitiated) { try SimulationEngine.run(input) }.value; if circuit == input { simulationResult = result; showWaveforms = true; toast = "Simulation complete" } }
            catch { self.error = error.localizedDescription }
            isSimulating = false
        }
    }
}
private extension Double { var snappedValue: Double { (self / 10).rounded() * 10 } }
