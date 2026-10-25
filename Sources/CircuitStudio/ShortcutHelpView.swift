import SwiftUI

struct ShortcutHelpView: View {
    @Environment(\.dismiss) private var dismiss
    private let shortcuts = [
        ("I / A", "Search and place a component"), ("W", "Wire"), ("T", "Text note"), ("L", "Net label"),
        ("R", "Rotate selection"), ("⇧R", "Mirror left/right"), ("⌘R / Ctrl R", "Mirror top/bottom"),
        ("Q / E", "Properties"), ("C", "Copy and place repeatedly"), ("V", "Place last copy"),
        ("⌘C / Ctrl C", "Copy objects + transparent PNG"), ("⌘⇧C", "Copy selection as PNG"),
        ("⌘X / Ctrl X", "Cut selection"), ("⌘V / Ctrl V", "Paste objects"), ("⌘A / Ctrl A", "Select all"),
        ("⇧ / ⌘ click", "Add or remove selection"), ("Drag blank canvas", "Box select parts, wires and notes"),
        ("Arrow / ⇧Arrow", "Move selection 1 / 10 units"), ("Space drag / middle drag", "Pan"),
        ("Ctrl / ⌘ wheel", "Zoom at pointer"), ("F / Home", "Fit view"),
        ("Wire click", "Add bend; click pin or wire to finish"), ("Enter / double-click", "Finish wire or polyline"),
        ("Backspace", "Remove last wire bend"), ("/", "Cycle wire corner"), ("Esc", "Cancel placement / drawing"),
        ("⌘Z / Ctrl Z", "Undo"), ("⌘⇧Z / Ctrl Y", "Redo")
    ]
    var body: some View {
        NavigationStack {
            List(shortcuts, id: \.0) { key, title in HStack { Text(LocalizedStringKey(title)); Spacer(); Text(key).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary) } }
                .navigationTitle("Keyboard & canvas controls")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(minWidth:400,minHeight:500)
    }
}
