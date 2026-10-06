// Compile with CircuitCore sources and EditorStore to exercise real editing commands.
import SwiftUI

@main struct EditorVerification {
    @MainActor static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) throws {
            guard passed else { throw CircuitError.message("Editor verification failed: \(name)") }
            checks.append(["check": name, "passed": true])
        }
        let blank = EditorStore(CircuitFile().circuit)
        try check("New document starts blank", blank.circuit.objectIDs.isEmpty && blank.circuit.purpose == .schematic)
        blank.setPurpose(.illustration)
        try check("Illustration has drawing tools only", !blank.supportsSimulation && !blank.availableTools.contains(.wire) && !blank.availableTools.contains(.probe))
        blank.activateTool(.wire)
        try check("Wire shortcut draws illustration connector", blank.tool == .connector)
        blank.activateTool(.label); blank.pointerDown(Point(100, 100))
        try check("Illustration text is not an electrical label", blank.circuit.figures.first?.kind == .text && blank.circuit.labels.isEmpty)
        blank.undo(); blank.undo()
        try check("Undo mode restores schematic", blank.circuit.purpose == .schematic && blank.circuit.objectIDs.isEmpty)
        let original = PaperExample.system.make()
        let ota = original.figures[3], sample = original.figures[4], adc = original.figures[5]
        let editor = EditorStore(original); editor.zoom = 1; editor.offset = .zero
        editor.selection = [ota.id]
        editor.pointerDown(ota.position); editor.pointerDragged(ota.position + Point(60, 30)); editor.pointerUp(ota.position + Point(60, 30))
        try check("Drag shape and attached arrows", editor.circuit.figures[3].position == ota.position + Point(60, 30) && editor.circuit.resolvedPoints(editor.circuit.figureConnectors[1]).last == editor.circuit.figures[3].anchor("left"))
        let moved = editor.circuit
        editor.undo(); try check("Undo / redo move", editor.circuit == original)
        editor.redo(); try check("Redo restores move", editor.circuit == moved)
        let shape = editor.circuit.figures[3], corner = shape.world(Point(shape.size.x / 2, shape.size.y / 2))
        editor.pointerDown(corner); editor.pointerDragged(corner + Point(30, 20)); editor.pointerUp(corner + Point(30, 20))
        let fixed = shape.world(Point(-shape.size.x / 2, -shape.size.y / 2))
        let snappedEnd = (corner + Point(30, 20)).snapped()
        try check("Resize honors grid and preserves attached edge", editor.circuit.figures[3].size == snappedEnd - fixed && editor.circuit.resolvedPoints(editor.circuit.figureConnectors[1]).last == editor.circuit.figures[3].anchor("left"))
        editor.undo(); try check("Undo resize", editor.circuit == moved)
        let arrows = EditorStore(original); arrows.tool = .connector
        let start = ota.anchor("right")!, end = sample.anchor("left")!
        arrows.pointerDown(start); arrows.pointerDragged(end); arrows.pointerUp(end)
        let added = arrows.circuit.figureConnectors.last!
        try check("Draw arrow by dragging between edges", added.start == TerminalRef(ota.id, "right") && added.end == TerminalRef(sample.id, "left") && arrows.circuit.figureConnectors.count == original.figureConnectors.count + 1)
        arrows.cancel(); arrows.selection = [added.id]
        arrows.pointerDown(end); arrows.pointerDragged(adc.anchor("left")!); arrows.pointerUp(adc.anchor("left")!)
        try check("Reconnect arrow endpoint", arrows.circuit.figureConnectors.last!.end == TerminalRef(adc.id, "left"))
        arrows.undo(); try check("Undo endpoint change", arrows.circuit.figureConnectors.last!.end == TerminalRef(sample.id, "left"))
        let copied = EditorStore(original); copied.selection = Set(original.figures.map(\.id)); copied.duplicateSelection()
        let newIDs = Set(copied.circuit.figures.dropFirst(original.figures.count).map(\.id))
        try check("Duplicate remaps internal arrow references", copied.circuit.figureConnectors.count == original.figureConnectors.count * 2 && copied.circuit.figureConnectors.suffix(original.figureConnectors.count).allSatisfy { newIDs.contains($0.start!.componentID) && newIDs.contains($0.end!.componentID) })
        copied.undo(); try check("Undo duplicate", copied.circuit == original)
        let group = EditorStore(original); group.selection = original.objectIDs
        group.pointerDown(ota.position); group.pointerDragged(ota.position + Point(20, 10)); group.pointerUp(ota.position + Point(20, 10))
        try check("Move multiple shapes without detaching arrows", zip(group.circuit.figureConnectors, original.figureConnectors).allSatisfy { $0.start == $1.start && $0.end == $1.end } && group.circuit.figures[3].position == ota.position + Point(20, 10))
        var mixed = CircuitTemplate.commonSource.make(); mixed.figures = [ota]
        let rotated = EditorStore(mixed); rotated.selection = [mixed.components[0].id, ota.id]; rotated.transformSelection("Rotate"); rotated.undo()
        try check("Mixed selection rotation has one undo", rotated.circuit == mixed)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/circuitstudio-editor-verification.json")
        let data = try JSONSerialization.data(withJSONObject: ["allPassed": true, "checks": checks], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output)
        print("\(checks.count) editor interaction checks passed")
    }
}
