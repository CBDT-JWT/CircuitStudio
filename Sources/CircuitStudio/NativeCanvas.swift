import SwiftUI

@MainActor enum CanvasPainter {
    static func draw(_ store: EditorStore, scene: VectorScene, context: CGContext, size: CGSize, dark: Bool) {
        let bg = dark ? CGColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 1) : CGColor(red: 0.985, green: 0.986, blue: 0.98, alpha: 1)
        context.setFillColor(bg); context.fill(CGRect(origin: .zero, size: size))
        if store.showGrid && store.circuit.mode != .publication {
            let step = max(10, ceil(16 / store.zoom / 10) * 10), visibleA = store.world(.zero), visibleB = store.world(Point(size.width, size.height))
            context.setFillColor(CGColor(gray: dark ? 0.28 : 0.80, alpha: 0.65))
            let firstX = floor(visibleA.x / step) * step, firstY = floor(visibleA.y / step) * step
            var x = firstX
            while x < visibleB.x { var y = firstY; while y < visibleB.y { let p = store.screen(Point(x, y)); context.fillEllipse(in: CGRect(x: p.x - 0.65, y: p.y - 0.65, width: 1.3, height: 1.3)); y += step }; x += step }
        }
        context.saveGState(); context.translateBy(x: store.offset.x, y: store.offset.y); context.scaleBy(x: store.zoom, y: store.zoom)
        CircuitRenderer.draw(scene, in: context, dark: dark)
        if store.circuit.mode == .presentation {
            context.setStrokeColor(CGColor(red: 0.09, green: 0.48, blue: 0.78, alpha: 1)); context.setLineWidth(2)
            let topology = Connectivity(store.circuit)
            for wire in store.circuit.wires { if let p = wire.points.first, topology.nets.contains(where: { $0.name.hasPrefix("VIN") || $0.name.hasPrefix("VOUT") ? $0.points.contains(p) : false }) { CircuitRenderer.stroke(store.circuit.resolvedPoints(wire), in: context) } }
        }
        let accent = CGColor(red: 0.08, green: 0.53, blue: 0.47, alpha: 1)
        context.setStrokeColor(accent); context.setFillColor(accent); context.setLineWidth(1.4 / store.zoom)
        for c in store.circuit.components where store.selection.contains(c.id) {
            let b = c.bodyBounds; let rect = CGRect(x: b.minX - 9, y: b.minY - 9, width: b.width + 18, height: b.height + 18)
            context.setFillColor(CGColor(red: 0.08, green: 0.53, blue: 0.47, alpha: 0.07)); context.fill(rect); context.setFillColor(accent); context.stroke(rect)
            for pin in c.pins { let p = c.world(pin.offset); context.fillEllipse(in: CGRect(x: p.x - 3 / store.zoom, y: p.y - 3 / store.zoom, width: 6 / store.zoom, height: 6 / store.zoom)) }
        }
        for w in store.circuit.wires where store.selection.contains(w.id) { context.setLineWidth(3 / store.zoom); CircuitRenderer.stroke(store.circuit.resolvedPoints(w), in: context) }
        for figure in store.circuit.figures where store.selection.contains(figure.id) {
            let b = figure.bounds; context.setLineWidth(1 / store.zoom); context.stroke(CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height))
            for corner in [Point(-figure.size.x / 2, -figure.size.y / 2), Point(figure.size.x / 2, -figure.size.y / 2), Point(figure.size.x / 2, figure.size.y / 2), Point(-figure.size.x / 2, figure.size.y / 2)] { let p = figure.world(corner); context.fill(CGRect(x: p.x - 4 / store.zoom, y: p.y - 4 / store.zoom, width: 8 / store.zoom, height: 8 / store.zoom)) }
            if store.tool == .connector { for pin in figure.anchors { let p = figure.world(pin.offset); context.fillEllipse(in: CGRect(x: p.x - 3 / store.zoom, y: p.y - 3 / store.zoom, width: 6 / store.zoom, height: 6 / store.zoom)) } }
        }
        for connector in store.circuit.figureConnectors where store.selection.contains(connector.id) {
            let points = store.circuit.resolvedPoints(connector); context.setLineWidth(2 / store.zoom); CircuitRenderer.stroke(points, in: context)
            for p in [points.first, points.last].compactMap({ $0 }) { context.fillEllipse(in: CGRect(x: p.x - 4 / store.zoom, y: p.y - 4 / store.zoom, width: 8 / store.zoom, height: 8 / store.zoom)) }
        }
        for l in store.circuit.labels where store.selection.contains(l.id) { context.stroke(CGRect(x: l.position.x, y: l.position.y - 25, width: Double(l.text.count) * 8, height: 26)) }
        if let p = store.hoverTerminal { context.setLineWidth(1.5 / store.zoom); context.strokeEllipse(in: CGRect(x: p.x - 7 / store.zoom, y: p.y - 7 / store.zoom, width: 14 / store.zoom, height: 14 / store.zoom)) }
        if !store.draftWire.isEmpty { context.setLineWidth(2 / store.zoom); context.setLineDash(phase: 0, lengths: [5 / store.zoom, 3 / store.zoom]); CircuitRenderer.stroke(store.draftWire, in: context); context.setLineDash(phase: 0, lengths: []) }
        if let b = store.marquee { context.setLineWidth(1 / store.zoom); context.stroke(CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height)) }
        if store.annotateOP, let result = store.simulationResult {
            for c in store.circuit.components where c.kind.isMOS { if let op = result.operatingPoints[c.name.uppercased()] {
                let keys = ["id", "gm", "gds", "vgs", "vds"]
                for (i, key) in keys.enumerated() { if let v = op[key] { CircuitRenderer.drawText(DrawingText(text: "\(key) = \(EngineeringUnits.format(v, unit: key == "id" ? "A" : key == "gm" || key == "gds" ? "S" : "V"))", point: c.position + Point(35, 45 + Double(i) * 17), size: 11), in: context, color: accent) } }
            } }
        }
        context.restoreGState()
    }
}

#if os(macOS)
final class CanvasObjectAccessibility: NSAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { activate?(); return activate != nil }
}
struct NativeCanvas: NSViewRepresentable {
    var store: EditorStore
    func makeNSView(context: Context) -> MacCanvas { MacCanvas(store: store) }
    func updateNSView(_ view: MacCanvas, context: Context) { view.update() }
}
final class MacCanvas: NSView {
    let store: EditorStore; var tracking: NSTrackingArea?; var cachedCircuit: Circuit?; var scene = VectorScene(); var spaceDown = false
    override var isFlipped: Bool { true }; override var acceptsFirstResponder: Bool { true }
    init(store: EditorStore) { self.store = store; super.init(frame: .zero); wantsLayer = true; setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Circuit canvas. Use A to add a component and W to draw wires.") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        store.documentWindow = window
        window?.tabbingIdentifier = "com.circuitstudio.workspace"
    }
    func update() {
        if cachedCircuit != store.circuit { scene = Symbols.scene(store.circuit); cachedCircuit = store.circuit; updateAccessibility() }; needsDisplay = true
    }
    override func layout() { super.layout(); let old = store.viewport; store.viewport = bounds.size; if !store.hasFitted && bounds.width > 100 { store.fit() } else if old != bounds.size { store.offset = store.offset + Point((bounds.width - old.width) / 2, (bounds.height - old.height) / 2) }; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) { guard let context = NSGraphicsContext.current?.cgContext else { return }; if cachedCircuit != store.circuit { update() }; CanvasPainter.draw(store, scene: scene, context: context, size: bounds.size, dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) }
    func point(_ event: NSEvent) -> Point { let p = convert(event.locationInWindow, from: nil); return Point(p.x, p.y) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); store.pointerDown(point(event), extend: event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command), duplicate: event.modifierFlags.contains(.option), pan: spaceDown, double: event.clickCount == 2); update() }
    override func mouseDragged(with event: NSEvent) { store.pointerDragged(point(event)); update() }
    override func mouseUp(with event: NSEvent) { store.pointerUp(point(event)); update() }
    override func mouseMoved(with event: NSEvent) { store.hover(point(event)); update() }
    override func mouseExited(with event: NSEvent) { store.hoverTerminal = nil; update() }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { store.changeZoom(store.zoom * exp(Double(event.scrollingDeltaY) * 0.015), at: point(event)) }
        else { store.offset = store.offset + Point(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY)) * (event.hasPreciseScrollingDeltas ? 1 : 12) }; update()
    }
    override func magnify(with event: NSEvent) { store.changeZoom(store.zoom * (1 + event.magnification), at: point(event)); update() }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { spaceDown = true; NSCursor.openHand.set(); return }
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        switch event.keyCode {
        case 53: store.cancel()
        case 51, 117: store.deleteSelection()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": store.paletteQuery = ""; store.showPalette = true
            case "w": store.activateTool(.wire)
            case "l": store.cancel(); store.tool = .connector
            case "t": store.activateTool(.label)
            case "b": store.activateTool(.probe)
            case "r": store.transformSelection("Rotate")
            case "h": store.transformSelection("Flip horizontal")
            case "v": store.transformSelection("Flip vertical")
            case "f": store.fit()
            default: super.keyDown(with: event)
            }
        }; update()
    }
    override func keyUp(with event: NSEvent) { if event.charactersIgnoringModifiers == " " { spaceDown = false; NSCursor.arrow.set() } }
    override func updateTrackingAreas() { super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }; let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self); addTrackingArea(area); tracking = area }
    func updateAccessibility() {
        let objects = store.circuit.components.map { ($0.id, "\($0.name), \($0.kind.title), \($0.valueLabel)") } + store.circuit.figures.map { ($0.id, "\($0.kind.rawValue), \($0.text)") } + store.circuit.figureConnectors.map { ($0.id, "Figure arrow, \($0.text)") }
        setAccessibilityChildren(objects.map { id, label in let element = CanvasObjectAccessibility(); element.setAccessibilityRole(.button); element.setAccessibilityLabel(label); element.setAccessibilityParent(self); element.setAccessibilityEnabled(true); element.activate = { [weak self] in self?.store.selection = [id]; self?.store.revealInspector(); self?.update() }; return element })
    }
}
#else
final class CanvasObjectAccessibility: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
}
struct NativeCanvas: UIViewRepresentable {
    var store: EditorStore
    func makeUIView(context: Context) -> TouchCanvas { TouchCanvas(store: store) }
    func updateUIView(_ view: TouchCanvas, context: Context) { view.update() }
}
final class TouchCanvas: UIView, UIGestureRecognizerDelegate {
    let store: EditorStore; var cachedCircuit: Circuit?; var scene = VectorScene(); var pinchZoom = 1.0; var panOffset = Point()
    override var canBecomeFirstResponder: Bool { true }
    init(store: EditorStore) {
        self.store = store; super.init(frame: .zero); isMultipleTouchEnabled = true; isOpaque = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched)); pinch.delegate = self; addGestureRecognizer(pinch)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned)); pan.minimumNumberOfTouches = 2; pan.delegate = self; addGestureRecognizer(pan)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered)); addGestureRecognizer(hover)
        isAccessibilityElement = false; accessibilityLabel = "Circuit canvas"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func update() {
        if cachedCircuit != store.circuit {
            scene = Symbols.scene(store.circuit); cachedCircuit = store.circuit
            let objects = store.circuit.components.map { ($0.id, "\($0.name), \($0.kind.title), \($0.valueLabel)", $0.bodyBounds) } + store.circuit.figures.map { ($0.id, "\($0.kind.rawValue), \($0.text)", $0.bounds) }
            accessibilityElements = objects.map { id, label, bounds in let e = CanvasObjectAccessibility(accessibilityContainer: self); e.accessibilityLabel = label; e.accessibilityTraits = .button; let p = store.screen(Point(bounds.minX, bounds.minY)); e.accessibilityFrameInContainerSpace = CGRect(x: p.x, y: p.y, width: bounds.width * store.zoom, height: bounds.height * store.zoom); e.activate = { [weak self] in self?.store.selection = [id]; self?.store.revealInspector(); self?.setNeedsDisplay() }; return e }
        }
        setNeedsDisplay()
    }
    override func layoutSubviews() { super.layoutSubviews(); let old = store.viewport; store.viewport = bounds.size; if !store.hasFitted && bounds.width > 100 { store.fit() } else if old != bounds.size { store.offset = store.offset + Point((bounds.width - old.width) / 2, (bounds.height - old.height) / 2) }; update() }
    override func draw(_ rect: CGRect) { guard let c = UIGraphicsGetCurrentContext() else { return }; CanvasPainter.draw(store, scene: scene, context: c, size: bounds.size, dark: traitCollection.userInterfaceStyle == .dark) }
    func point(_ touch: UITouch) -> Point { let p = touch.location(in: self); return Point(p.x, p.y) }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { guard event?.allTouches?.count == 1, let touch = touches.first else { return }; becomeFirstResponder(); store.pointerDown(point(touch), double: touch.tapCount == 2); update() }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { guard event?.allTouches?.count == 1, let touch = touches.first else { return }; store.pointerDragged(point(touch)); update() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { guard let touch = touches.first else { return }; store.pointerUp(point(touch)); update() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { store.pointerUp(point(touch)) }; update() }
    @objc func pinched(_ gesture: UIPinchGestureRecognizer) { if gesture.state == .began { pinchZoom = store.zoom }; let p = gesture.location(in: self); store.changeZoom(pinchZoom * gesture.scale, at: Point(p.x, p.y)); update() }
    @objc func panned(_ gesture: UIPanGestureRecognizer) { if gesture.state == .began { panOffset = store.offset }; let p = gesture.translation(in: self); store.offset = panOffset + Point(p.x, p.y); update() }
    @objc func hovered(_ gesture: UIHoverGestureRecognizer) { let p = gesture.location(in: self); store.hover(Point(p.x, p.y)); update() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    override var keyCommands: [UIKeyCommand]? { [("a", "Add component"), ("w", "Wire"), ("l", "Figure arrow"), ("r", "Rotate"), ("h", "Flip horizontal"), ("v", "Flip vertical"), ("t", "Net label"), ("f", "Fit circuit"), (UIKeyCommand.inputEscape, "Select")].map { input, title in let c = UIKeyCommand(input: input, modifierFlags: [], action: #selector(key)); c.discoverabilityTitle = title; return c } }
    @objc func key(_ command: UIKeyCommand) { switch command.input { case "a": store.showPalette = true; case "w": store.activateTool(.wire); case "l": store.cancel(); store.tool = .connector; case "r": store.transformSelection("Rotate"); case "h": store.transformSelection("Flip horizontal"); case "v": store.transformSelection("Flip vertical"); case "t": store.activateTool(.label); case "f": store.fit(); default: store.cancel() }; update() }
}
#endif
