import SwiftUI
import Observation

enum CanvasTool: String, CaseIterable, Identifiable {
    case select = "Select", wire = "Wire", connector = "Arrow", pan = "Pan", label = "Label", probe = "Probe"
    var id: String { rawValue }
    var icon: String { switch self { case .select: "cursorarrow"; case .wire: "point.topleft.down.to.point.bottomright.curvepath"; case .connector: "arrow.up.right"; case .pan: "hand.draw"; case .label: "textformat"; case .probe: "waveform.path" } }
    var shortcut: String { switch self { case .select: "Esc"; case .wire: "W"; case .connector: "⇧L"; case .pan: "Space"; case .label: "L"; case .probe: "B" } }
}

@MainActor @Observable final class EditorStore {
    var circuit: Circuit
    var selection: Set<UUID> = []
    var tool: CanvasTool = .select
    var zoom = 1.0; var offset = Point(); var viewport = CGSize(width: 900, height: 700)
    var showGrid = true; var snapEnabled = true; var showLibrary = true; var showInspector = true
    var showShortcuts = false; var showPalette = false; var paletteQuery = ""; var showTemplates = false; var showExport = false; var showImport = false; var showSimulationSettings = false; var showModels = false
    var inspectorUsesSheet = false; var inspectorRequested = false
    var insertKind: ComponentKind?; var insertionPoint: Point?
    var insertFigureKind: FigureKind?; var connectorRoute: FigureRoute = .straight; var connectorArrows: FigureArrows = .end
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
    var drawingPowerRail = false
    private var movingRailLabel:UUID?
    private var editingRailEndpoint:(UUID,Bool)?
    private var drawingConnector = false
    private var marqueeBase: Set<UUID> = []
    var placementCopy: Data?
    var placementPoint: Point?
    var copyPicking = false
    var insertionRotation = 0; var insertionFlipX = false; var insertionFlipY = false
    private var movingComponentLabel: (UUID,Bool)?
    private var editingWire: (UUID, Int)?
    var wireCorner = 0
    private var wireBends: [Point] = []
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
        let before = circuit; action(&circuit); circuit.updateAttachedNoConnects(); if before != circuit { record(before, name: name) }
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
        if let pin=pins.filter({ $0.1.distance(to:p)<(tolerance ?? 10/zoom) }).min(by:{ $0.1.distance(to:p)<$1.1.distance(to:p) }) { return pin }
        let candidates=circuit.wires.compactMap { rail -> (TerminalRef,Point)? in
            guard rail.powerNet != nil,let a=rail.points.first,let b=rail.points.last else { return nil };let d=b-a,denom=d.x*d.x+d.y*d.y;guard denom>0 else { return nil }
            let input=snapEnabled ? p.snapped() : p
            let t=min(1,max(0,((input.x-a.x)*d.x+(input.y-a.y)*d.y)/denom)),q=a+d*t
            return q.distance(to:p)<(tolerance ?? 10/zoom) ? (TerminalRef(rail.id,"rail:\(t)"),q) : nil
        }
        return candidates.min { $0.1.distance(to:p)<$1.1.distance(to:p) }
    }
    func nearestFigureAnchor(_ p: Point) -> (TerminalRef, Point)? {
        let anchors = circuit.figures.flatMap { f in f.anchors.map { (TerminalRef(f.id, $0.name), f.world($0.offset)) } }
        let figure = anchors.filter { $0.1.distance(to: p) < 14 / zoom }.min { $0.1.distance(to: p) < $1.1.distance(to: p) }
        return figure ?? nearestTerminal(p)
    }
    func connectorSnap(_ p: Point) -> Point { nearestFigureAnchor(p)?.1 ?? (snapEnabled ? p.snapped() : p) }
    func connectorPath(from a: Point, to b: Point) -> [Point] { connectorRoute == .straight ? [a, b] : WireRouting.route(from: a, to: b, obstacles: circuit.figures.map(\.bounds) + circuit.components.map(\.bodyBounds)) }
    func hit(_ p: Point) -> UUID? {
        if let marker=circuit.components.reversed().first(where:{ $0.kind == .noConnect && $0.position.distance(to:p)<12/zoom }) { return marker.id }
        if let rail=circuit.wires.reversed().first(where:{ circuit.powerRailLabel($0).map { Symbols.textBounds($0).contains(p,margin:4/zoom) } == true }) { return rail.id }
        if let f = circuit.figures.reversed().first(where: { $0.bounds.contains(p, margin: 5 / zoom) }) { return f.id }
        if let c = circuit.components.reversed().first(where: { $0.bodyBounds.contains(p, margin: 8 / zoom) }) { return c.id }
        if let component = circuit.components.reversed().first(where: { c in Symbols.componentLabels(c,theme:circuit.theme,appearance:circuit.appearance).contains { Symbols.textBounds($0.text).contains(p,margin:4/zoom) } }) { return component.id }
        if let label = circuit.labels.reversed().first(where: { Bounds([$0.position + Point(0, -24), $0.position + Point(Double($0.text.count) * 8, 5)]).contains(p, margin: 4 / zoom) }) { return label.id }
        if let arrow = circuit.figureConnectors.reversed().first(where: { connector in let ps = circuit.resolvedPoints(connector); return zip(ps, ps.dropFirst()).contains { distanceToSegment(p, $0, $1) < 7 / zoom } }) { return arrow.id }
        return circuit.wires.reversed().first { wire in let ps = circuit.resolvedPoints(wire); return zip(ps, ps.dropFirst()).contains { distanceToSegment(p, $0, $1) < 6 / zoom } }?.id
    }
    func hover(_ screenPoint: Point) { let p = world(screenPoint); placementPoint = insertKind == .noConnect ? nearestTerminal(p)?.1 : snap(p); hoverTerminal = (tool == .connector ? nearestFigureAnchor(p) : nearestTerminal(p))?.1; if draftOrigin != nil { draftWire = wirePreview(to: drawingConnector ? connectorSnap(p) : snap(p)) } }
    func pointerDown(_ screenPoint: Point, extend: Bool = false, duplicate: Bool = false, pan: Bool = false, double: Bool = false) {
        let p = world(screenPoint); gestureStart = p; gestureSnapshot = circuit; gestureUndoSnapshot = circuit; originalOffset = offset; didMove = false
        if pan || tool == .pan { isPanning = true; return }
        if copyPicking {
            if let id = hit(p) { selection = [id]; beginCopyPlacement(selectionData()) }
            return
        }
        if let data = placementCopy, let payload = try? JSONDecoder().decode(SelectionPayload.self, from: data) {
            var snapshot = Circuit(); snapshot.components = payload.components; snapshot.wires = payload.wires; snapshot.labels = payload.labels; snapshot.figures = payload.figures ?? []; snapshot.figureConnectors = payload.connectors ?? []
            paste(data, displacement: snap(p) - snapshot.bounds.center); return
        }
        if let kind = insertKind {
            if kind == .powerRail {
                if draftOrigin == nil { drawingPowerRail=true;draftOrigin=snap(p);draftWire=[snap(p),snap(p)] }
                else { finishWire(at:snap(p)) }; return
            }
            if kind == .noConnect { markNoConnect(at:p);return }
            insert(kind, at:snap(p)); toast = String(format: NSLocalizedString("Click to place another %@ · Esc to finish", comment: ""), kind.title); return
        }
        if let kind = insertFigureKind { insertFigure(kind, at: snapEnabled ? p.snapped() : p); insertFigureKind = nil; return }
        if double && !draftWire.isEmpty { completeWire(); return }
        if double {
            if let id = hit(p) { selection = [id]; revealInspector() }
            else { insertionPoint = snap(p); paletteQuery = ""; showPalette = true }
            return
        }
        if tool == .label { if supportsSimulation { labelPoint = snap(p); labelText = "V_{OUT}" } else { insertFigure(.text, at: connectorSnap(p)); revealInspector() }; return }
        if tool == .probe { probe(p); return }
        if tool == .connector {
            if !draftWire.isEmpty { if nearestFigureAnchor(p) != nil { finishWire(at:connectorSnap(p)) } else { addWireBend(at:connectorSnap(p)) }; return }
            wireBends = []; drawingConnector = true; draftOrigin = connectorSnap(p); draftStart = nearestFigureAnchor(p)?.0; draftWire = [connectorSnap(p), connectorSnap(p)]; return
        }
        if tool == .select {
            for rail in circuit.wires.reversed() { if let label=circuit.powerRailLabel(rail),Symbols.textBounds(label).contains(p,margin:4/zoom) { selection=[rail.id];movingRailLabel=rail.id;return } }
            for component in circuit.components.reversed() {
                let labels = Symbols.componentLabels(component,theme:circuit.theme,appearance:circuit.appearance)
                if let label = labels.first(where: { Symbols.textBounds($0.text).contains(p,margin:4/zoom) }) {
                    selection = [component.id]; movingComponentLabel = (component.id,label.value); return
                }
            }
            if let wire = selectedWire {
                if wire.powerNet != nil,let a=wire.points.first,let b=wire.points.last {
                    if a.distance(to:p)<9/zoom { editingRailEndpoint=(wire.id,true);return }
                    if b.distance(to:p)<9/zoom { editingRailEndpoint=(wire.id,false);return }
                }
                let ps = circuit.resolvedPoints(wire)
                for i in 0..<max(0,ps.count-1) where ((ps[i]+ps[i+1])*0.5).distance(to:p)<9/zoom { editingWire=(wire.id,i); return }
            }
            for f in circuit.figures where selection.contains(f.id) {
                let corners = [Point(-f.size.x / 2, -f.size.y / 2), Point(f.size.x / 2, -f.size.y / 2), Point(f.size.x / 2, f.size.y / 2), Point(-f.size.x / 2, f.size.y / 2)]
                if let corner = corners.first(where: { f.world($0).distance(to: p) < 10 / zoom }) { resizingFigure = f.id; resizeFixed = f.world(corner * -1); return }
            }
            if let connector = selectedConnector { let points = circuit.resolvedPoints(connector); if let first = points.first, first.distance(to: p) < 12 / zoom { editingConnector = (connector.id, true); return }; if let last = points.last, last.distance(to: p) < 12 / zoom { editingConnector = (connector.id, false); return } }
        }
        if tool == .select,let id=hit(p),circuit.components.first(where:{ $0.id == id })?.kind == .noConnect { selection=[id];return }
        if supportsSimulation && (tool == .wire || (selection.isEmpty && nearestTerminal(p).map { terminal in circuit.components.contains { $0.id == terminal.0.componentID } } == true) || !draftWire.isEmpty) {
            if !draftWire.isEmpty { if nearestTerminal(p) != nil || circuit.wires.contains(where: { w in let ps = circuit.resolvedPoints(w); return zip(ps,ps.dropFirst()).contains { distanceToSegment(p,$0,$1) < 8 / zoom } }) { finishWire(at: snap(p)) } else { addWireBend(at: snap(p)) }; return }
            wireBends = []; draftOrigin = snap(p); draftStart = nearestTerminal(p)?.0; draftWire = [snap(p), snap(p)]; return
        }
        if let id = hit(p) {
            if extend { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }
            else if !selection.contains(id) { selection = [id] }
            if duplicate { paste(selectionData(), displacement: .zero, recordUndo: false); gestureSnapshot = circuit }
            movingIDs = selection
        } else { marqueeBase = extend ? selection : []; selection = marqueeBase; isMarquee = true; marquee = Bounds([p, p]) }
    }
    func pointerDragged(_ screenPoint: Point) {
        defer { circuit.updateAttachedNoConnects() }
        guard let start = gestureStart else { return }; let p = world(screenPoint); let delta = p - start
        didMove = didMove || delta.distance(to: .zero) > 2 / zoom
        if isPanning, let originalOffset { offset = originalOffset + delta * zoom; return }
        if draftOrigin != nil { draftWire = wirePreview(to: drawingConnector ? connectorSnap(p) : snap(p)); return }
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
        if let (id,first)=editingRailEndpoint,let before=gestureSnapshot,let original=before.wires.first(where:{ $0.id == id }),let i=circuit.wires.firstIndex(where:{ $0.id == id }) {
            let fixed=first ? original.points.last! : original.points.first!,end=PowerRailGeometry.endpoint(from:fixed,toward:snapEnabled ? p.snapped() : p)
            circuit.wires[i].points=first ? [end,fixed] : [fixed,end];circuit.reconcileRailContacts(id,previous:before);return
        }
        if let id=movingRailLabel,let before=gestureSnapshot,let original=before.wires.first(where:{ $0.id == id }),let i=circuit.wires.firstIndex(where:{ $0.id == id }) { circuit.wires[i].labelOffset=(original.labelOffset ?? .zero)+delta;return }
        if let (id,value) = movingComponentLabel, let before = gestureSnapshot, let original = before.components.first(where: { $0.id == id }), let i = circuit.components.firstIndex(where: { $0.id == id }) {
            if value { circuit.components[i].valueOffset = (original.valueOffset ?? .zero)+delta }
            else { circuit.components[i].nameOffset = (original.nameOffset ?? .zero)+delta }; return
        }
        if let (id,segment) = editingWire, let before = gestureSnapshot, let original = before.wires.first(where: { $0.id == id }), let i = circuit.wires.firstIndex(where: { $0.id == id }) {
            var ps = before.resolvedPoints(original)
            let horizontal = abs(ps[segment].y-ps[segment+1].y)<0.01
            let shift = snapEnabled ? delta.snapped() : delta
            if horizontal { ps[segment].y += shift.y; ps[segment+1].y += shift.y } else { ps[segment].x += shift.x; ps[segment+1].x += shift.x }
            circuit.wires[i].points = ps
            if segment == 0 { circuit.wires[i].start = nearestTerminal(ps[0])?.0 }
            if segment+1 == ps.count-1 { circuit.wires[i].end = nearestTerminal(ps.last!)?.0 }
            return
        }
        if isMarquee { marquee = Bounds([start,p]); selection = marqueeBase.union(circuit.objects(in: marquee!)); return }
        guard let before = gestureSnapshot else { return }
        let shift = snapEnabled ? delta.snapped() : delta
        for i in circuit.components.indices where movingIDs.contains(circuit.components[i].id) {
            if let original = before.components.first(where: { $0.id == circuit.components[i].id }) { circuit.components[i].position = original.position + shift }
            else if let original = circuit.components.first(where: { $0.id == circuit.components[i].id }) { circuit.components[i].position = (original.position + delta).snapped() }
        }
        for i in circuit.wires.indices {
            let wire = before.wires[i]
            let internalWire = wire.start.map { movingIDs.contains($0.componentID) } == true && wire.end.map { movingIDs.contains($0.componentID) } == true
            if movingIDs.contains(wire.id) || internalWire {
                circuit.wires[i].points = before.resolvedPoints(wire).map { $0 + shift }
                if movingIDs.contains(wire.id) {
                    if wire.start.map({ movingIDs.contains($0.componentID) }) != true { circuit.wires[i].start = nil }
                    if wire.end.map({ movingIDs.contains($0.componentID) }) != true { circuit.wires[i].end = nil }
                }
            }
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
        for id in movingIDs where circuit.wires.contains(where:{ $0.id == id && $0.powerNet != nil }) { circuit.bondRailPins(id) }
        if isMarquee, let marquee { selection = marqueeBase.union(circuit.objects(in: marquee)) }
        if draftOrigin != nil && didMove { finishWire(at: drawingConnector ? connectorSnap(world(screenPoint)) : snap(world(screenPoint))) }
        if let before = gestureUndoSnapshot, before != circuit, !movingIDs.isEmpty || resizingFigure != nil || editingConnector != nil || editingWire != nil || movingComponentLabel != nil || movingRailLabel != nil || editingRailEndpoint != nil { record(before, name: resizingFigure != nil ? "Resize figure" : editingConnector != nil ? "Adjust arrow" : "Move objects") }
        gestureStart = nil; gestureSnapshot = nil; gestureUndoSnapshot = nil; movingIDs.removeAll(); isPanning = false; isMarquee = false; marquee = nil; originalOffset = nil
        resizingFigure = nil; resizeFixed = nil; editingConnector = nil; editingWire = nil; movingComponentLabel = nil; movingRailLabel = nil; editingRailEndpoint = nil
    }
    func markNoConnect(at p:Point) {
        let candidates=circuit.components.flatMap { c in c.pins.map { (TerminalRef(c.id,$0.name),c.world($0.offset)) } }.filter { $0.1.distance(to:p)<12/zoom }.sorted { $0.1.distance(to:p)<$1.1.distance(to:p) }
        guard let (terminal,point)=candidates.first,candidates.count<2 || abs(candidates[1].1.distance(to:p)-point.distance(to:p))>1/zoom else { toast=NSLocalizedString("No Connect: choose one unambiguous pin.",comment:"");return }
        if let existing=circuit.components.first(where:{ $0.kind == .noConnect && $0.parameters["attachedComponent"] == terminal.componentID.uuidString && $0.parameters["attachedPin"] == terminal.pin }) { selection=[existing.id];return }
        let topology=Connectivity(circuit),net=topology.nets.first { $0.terminals.contains(terminal) }
        let wired=circuit.wires.contains { wire in let ps=circuit.resolvedPoints(wire);return zip(ps,ps.dropFirst()).contains { distanceToSegment(point,$0,$1)<0.001 } }
        guard !wired,(net?.terminals.count ?? 0)<2,circuit.components.first(where:{ $0.id == terminal.componentID })?.kind.isConnection != true,!circuit.labels.contains(where:{ $0.isNet && $0.position.distance(to:point)<0.001 }) else { toast=NSLocalizedString("Disconnect the pin before marking it No Connect.",comment:"");return }
        transaction("Mark No Connect") { c in
            let id=c.add(.noConnect,at:point);let i=c.components.firstIndex(where:{ $0.id == id })!
            c.components[i].parameters=["attachedComponent":terminal.componentID.uuidString,"attachedPin":terminal.pin];selection=[id]
        }
    }
    func finishWire(at point: Point) {
        guard let origin = wireBends.first ?? draftOrigin, origin.distance(to: point) > 1 || wireBends.count > 1 else { return }
        if drawingPowerRail {
            let end=PowerRailGeometry.endpoint(from:origin,toward:point)
            var candidate=circuit
            guard let id=candidate.addPowerRail(from:origin,to:end) else { return }
            guard Connectivity(candidate).conflictingLabels.isEmpty else { toast=NSLocalizedString("The rail would join differently named nets. Choose another position.",comment:"");return }
            transaction("Draw power rail") { $0=candidate };selection=[id]
            draftWire=[];wireBends=[];draftOrigin=nil;draftStart=nil;drawingPowerRail=false;return
        }
        if drawingConnector {
            let start = draftStart, end = nearestFigureAnchor(point)?.0
            var connector = FigureConnector(from: origin, to: point, start: start, end: end); connector.route = connectorRoute; connector.arrows = connectorArrows; connector.points = wirePreview(to:point)
            transaction("Draw arrow") { $0.figureConnectors.append(connector) }; selection = [connector.id]
            draftWire = []; wireBends = []; draftOrigin = nil; draftStart = nil; drawingConnector = false; return
        }
        let start = draftStart, end = nearestTerminal(point)?.0, path = wirePreview(to:point)
        transaction("Draw wire") { c in
            c.wires.append(Wire(points:path,start:start,end:end))
            c.components.removeAll { marker in marker.kind == .noConnect && zip(path,path.dropFirst()).contains { distanceToSegment(marker.position,$0,$1)<0.001 } }
        }
        draftWire = []; wireBends = []; draftOrigin = nil; draftStart = nil
    }
    func cancel() { drawingPowerRail = false; placementCopy = nil; copyPicking = false; placementPoint = nil; insertionRotation = 0; insertionFlipX = false; insertionFlipY = false; wireBends = []; insertKind = nil; insertFigureKind = nil; tool = .select; draftWire = []; draftOrigin = nil; draftStart = nil; hoverTerminal = nil; drawingConnector = false }
    func revealInspector() { if inspectorUsesSheet { inspectorRequested = true } else { showInspector = true } }
    func insert(_ kind: ComponentKind, at p: Point? = nil) {
        var id: UUID?; transaction("Add \(kind.title)") { id = $0.add(kind, at: p ?? world(Point(viewport.width / 2, viewport.height / 2)).snapped()) }
        if let id {
            selection = [id]
            if let i = circuit.components.firstIndex(where: { $0.id == id }) { circuit.components[i].rotation = insertionRotation; circuit.components[i].flipX = insertionFlipX; circuit.components[i].flipY = insertionFlipY }
        }; tool = .select; toast = "\(kind.title) added"
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
        transaction("Delete objects") { c in c.components.removeAll { selection.contains($0.id) || ($0.kind == .noConnect && $0.parameters["attachedComponent"].flatMap(UUID.init(uuidString:)).map { selection.contains($0) } == true) }; c.wires.removeAll { selection.contains($0.id) || $0.start.map { selection.contains($0.componentID) } == true || $0.end.map { selection.contains($0.componentID) } == true }; c.labels.removeAll { selection.contains($0.id) }; c.figures.removeAll { selection.contains($0.id) }; c.figureConnectors.removeAll { selection.contains($0.id) || $0.start.map { selection.contains($0.componentID) } == true || $0.end.map { selection.contains($0.componentID) } == true } }; selection.removeAll()
    }
    func transformSelection(_ transform: String) {
        if insertKind != nil {
            if transform == "Rotate" { insertionRotation = (insertionRotation+90)%360 }
            else if transform == "Flip horizontal" { insertionFlipX.toggle() } else { insertionFlipY.toggle() }; return
        }
        if let data = placementCopy, let payload = try? JSONDecoder().decode(SelectionPayload.self,from:data) {
            var copy = Circuit(); copy.components = payload.components; copy.wires = payload.wires; copy.labels = payload.labels; copy.figures = payload.figures ?? []; copy.figureConnectors = payload.connectors ?? []
            let temporary = EditorStore(copy); temporary.selection = copy.objectIDs; temporary.transformSelection(transform); placementCopy = temporary.selectionData(); return
        }
        guard !selection.isEmpty else { return }
        let before = circuit, selected = circuit.selected(selection)
        let anchors = selected.components.map(\.position) + selected.figures.map(\.position) + selected.labels.map(\.position) + selected.wires.flatMap(\.points) + selected.figureConnectors.flatMap(\.points)
        let center = Bounds(anchors).center
        let rotation = transform == "Rotate" ? 90 : 0
        let mirrorX = transform == "Flip horizontal", mirrorY = transform == "Flip vertical"
        func point(_ p: Point) -> Point { center + (p-center).transformed(rotation: rotation, flipX: mirrorX, flipY: mirrorY) }
        transaction(transform) { c in
            for i in c.components.indices where selection.contains(c.components[i].id) {
                c.components[i].position = point(c.components[i].position)
                c.components[i].rotation = (mirrorX || mirrorY ? 360-c.components[i].rotation : c.components[i].rotation+rotation) % 360
                if mirrorX { c.components[i].flipX.toggle() }; if mirrorY { c.components[i].flipY.toggle() }
            }
            for i in c.figures.indices where selection.contains(c.figures[i].id) {
                c.figures[i].position = point(c.figures[i].position)
                c.figures[i].rotation = (mirrorX || mirrorY ? 360-c.figures[i].rotation : c.figures[i].rotation+rotation) % 360
                if mirrorX { c.figures[i].flipX = !(c.figures[i].flipX ?? false) }; if mirrorY { c.figures[i].flipY = !(c.figures[i].flipY ?? false) }
            }
            for i in c.labels.indices where selection.contains(c.labels[i].id) { c.labels[i].position = point(c.labels[i].position) }
            let snapshot = before.selected(selection)
            for i in c.wires.indices { if let wire = snapshot.wires.first(where: { $0.id == c.wires[i].id }) { c.wires[i].points = wire.points.map(point); c.wires[i].start = wire.start; c.wires[i].end = wire.end } }
            for i in c.figureConnectors.indices { if let arrow = snapshot.figureConnectors.first(where: { $0.id == c.figureConnectors[i].id }) { c.figureConnectors[i].points = arrow.points.map(point); c.figureConnectors[i].start = arrow.start; c.figureConnectors[i].end = arrow.end } }
        }
    }
    func nudge(_ delta: Point) {
        guard !selection.isEmpty else { return }
        let source = circuit.selected(selection)
        transaction("Move selection") { c in
            for i in c.components.indices where selection.contains(c.components[i].id) { c.components[i].position = c.components[i].position+delta }
            for i in c.figures.indices where selection.contains(c.figures[i].id) { c.figures[i].position = c.figures[i].position+delta }
            for i in c.labels.indices where selection.contains(c.labels[i].id) { c.labels[i].position = c.labels[i].position+delta }
            for i in c.wires.indices { if let wire = source.wires.first(where: { $0.id == c.wires[i].id }) { c.wires[i].points = wire.points.map { $0+delta }; c.wires[i].start = wire.start; c.wires[i].end = wire.end } }
            for i in c.figureConnectors.indices { if let arrow = source.figureConnectors.first(where: { $0.id == c.figureConnectors[i].id }) { c.figureConnectors[i].points = arrow.points.map { $0+delta }; c.figureConnectors[i].start = arrow.start; c.figureConnectors[i].end = arrow.end } }
        }
    }
    func beginPickCopy() { cancel(); copyPicking = true; toast = NSLocalizedString("Click an object to copy", comment: "") }
    func beginCopyPlacement(_ data: Data?) { cancel(); guard let data else { return }; placementCopy = data; toast = NSLocalizedString("Click to place copies · Esc to finish", comment: "") }
    func wirePreview(to p: Point) -> [Point] {
        guard let origin = wireBends.last ?? draftOrigin else { return [] }
        if drawingPowerRail { return [origin,PowerRailGeometry.endpoint(from:origin,toward:p)] }
        let segment: [Point]
        if drawingConnector { segment = connectorPath(from:origin,to:p) } else {
        switch wireCorner {
        case 1: segment = [origin,Point(origin.x,p.y),p]
        case 2:
            let dx=p.x-origin.x, dy=p.y-origin.y, d=min(abs(dx),abs(dy))
            segment = [origin,origin+Point(dx<0 ? -d : d,dy<0 ? -d : d),p]
        case 3: segment = [origin,p]
        default: segment = WireRouting.route(from:origin,to:p,obstacles:circuit.components.map(\.bodyBounds))
        }
        }
        return wireBends.isEmpty ? segment : Array(wireBends.dropLast()) + segment
    }
    func addWireBend(at p: Point) {
        let path = wirePreview(to:p)
        wireBends = path; draftWire = path
    }
    func removeWireBend() { if !wireBends.isEmpty { wireBends.removeLast(); draftWire = wireBends; if wireBends.isEmpty, let origin = draftOrigin { draftWire = [origin,origin] } } else { cancel() } }
    func completeWire() { if let p = draftWire.last { finishWire(at:p) } }
    func cycleWireCorner() { wireCorner = (wireCorner+1)%4; toast = ["Automatic corner","Opposite corner","45° corner","Any angle"][wireCorner] }
    func duplicateSelection(recordUndo: Bool = true) {
        let before = circuit; let payload = selectionData(); paste(payload, displacement: Point(30, 30), recordUndo: false)
        if recordUndo && before != circuit { record(before, name: "Duplicate objects") }
    }
    struct SelectionPayload: Codable { var components: [Component]; var wires: [Wire]; var labels: [CircuitLabel]; var figures: [FigureElement]? = nil; var connectors: [FigureConnector]? = nil; var junctions: [Point]? = nil }
    func selectionData() -> Data? {
        guard !selection.isEmpty else { return nil }
        let selected = circuit.selected(selection)
        return try? JSONEncoder().encode(SelectionPayload(components: selected.components, wires: selected.wires, labels: selected.labels, figures: selected.figures, connectors: selected.figureConnectors, junctions: selected.junctions))
    }

    func paste(_ data: Data?, displacement: Point = Point(30, 30), recordUndo: Bool = true, replacingHandDrawing: Data? = nil) {
        guard let data, let payload = try? JSONDecoder().decode(SelectionPayload.self, from: data) else { return }
        let before = circuit; var mapping: [UUID: UUID] = [:]; selection.removeAll()
        for original in payload.components { let id = circuit.add(original.kind, at: original.position + displacement); var c = original; c.id = id; c.name = circuit.components.last!.name; c.position = original.position + displacement; circuit.components[circuit.components.count - 1] = c; mapping[original.id] = id; selection.insert(id) }
        for i in circuit.components.indices where selection.contains(circuit.components[i].id) && circuit.components[i].kind == .noConnect {
            if let raw=circuit.components[i].parameters["attachedComponent"],let old=UUID(uuidString:raw),let new=mapping[old] { circuit.components[i].parameters["attachedComponent"]=new.uuidString }
        }
        for original in payload.figures ?? [] { var f = original; f.id = UUID(); f.position = f.position + displacement; circuit.figures.append(f); mapping[original.id] = f.id; selection.insert(f.id) }
        for original in payload.wires { mapping[original.id]=UUID() }
        func ref(_ old: TerminalRef?) -> TerminalRef? { old.flatMap { r in mapping[r.componentID].map { TerminalRef($0, r.pin) } } }
        for original in payload.wires { var w=original;w.id=mapping[original.id]!;w.points=original.points.map { $0+displacement };w.start=ref(original.start);w.end=ref(original.end);circuit.wires.append(w);selection.insert(w.id) }
        for original in payload.labels { var l=original;l.id=UUID();l.position=original.position+displacement; circuit.labels.append(l); selection.insert(l.id) }
        for original in payload.connectors ?? [] { var c = original; c.id = UUID(); c.points = c.points.map { $0 + displacement }; c.start = ref(original.start); c.end = ref(original.end); circuit.figureConnectors.append(c); selection.insert(c.id) }
        circuit.junctions += (payload.junctions ?? []).map { $0 + displacement }
        if let replacingHandDrawing { circuit.handDrawing = replacingHandDrawing }
        if recordUndo && before != circuit { record(before, name: "Paste objects") }
    }
    func loadTemplate(_ template: CircuitTemplate) { transaction("Apply template") { $0 = template.make() }; selection.removeAll(); fit(); showTemplates = false }
    func insertPattern(_ template: CircuitTemplate) {
        let pattern = template.make(); let payload = SelectionPayload(components: pattern.components, wires: pattern.wires, labels: pattern.labels)
        paste(try? JSONEncoder().encode(payload), displacement: world(Point(viewport.width / 2, viewport.height / 2)) - pattern.bounds.center); showPalette = false
    }
    func cleanUp() {
        transaction("Clean up circuit") { c in for i in c.components.indices { c.components[i].position = c.components[i].position.snapped(20) }; for i in c.wires.indices where c.wires[i].powerNet == nil { let p = c.resolvedPoints(c.wires[i]); if let a = p.first, let b = p.last { c.wires[i].points = WireRouting.route(from: a, to: b, obstacles: c.components.map(\.bodyBounds)) } } }; toast = "Aligned to grid and rerouted wires"
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
