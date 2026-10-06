import Foundation

public enum CircuitikZ {
    static func coordinate(_ p: Point) -> String { String(format: "(%.4f,%.4f)", p.x / 60, -p.y / 60) }
    static func latex(_ input: String) -> String {
        input.replacingOccurrences(of: "μ", with: "\\mu ").replacingOccurrences(of: "Ω", with: "\\Omega ").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "&", with: "\\&").replacingOccurrences(of: "#", with: "\\#")
    }
    public static func export(_ circuit: Circuit) throws -> String {
        // A comment preserves editable properties when reimporting our own export.
        let metadata = try CircuitArchive(circuit).encoded().base64EncodedString()
        var lines = ["% CircuitStudio-v1:\(metadata)", "\\begin{circuitikz}[american, scale=1]", "  \\ctikzset{bipoles/length=1cm}"]
        for (i, c) in circuit.components.enumerated() {
            let name = "cs\(i)"
            let options = ["rotate=\(-c.rotation)", c.flipX ? "xscale=-1" : "", c.flipY ? "yscale=-1" : ""].filter { !$0.isEmpty }.joined(separator: ",")
            let theme = circuit.mode == .publication ? SymbolTheme.razavi : circuit.theme
            if [.npn, .pnp].contains(c.kind), theme == .razavi {
                // Preserve the academic BJT shape, including its base and arrow proportions.
                lines += nativeSymbol(c, theme: theme)
            } else if c.kind.isMOS || [.npn, .pnp, .opAmp].contains(c.kind) {
                let kind = c.kind == .opAmp ? "op amp" : c.kind.isMOS ? c.kind.rawValue + ", arrowmos" + (c.kind == .pmos ? ", nocircle" : "") : c.kind.rawValue
                let anchor = c.kind == .opAmp ? "" : ",anchor=\(c.kind.isMOS ? "G" : "B")"
                let origin = c.kind == .opAmp ? c.position : c.world(Point(-40, 0))
                lines.append("  \\draw \(coordinate(origin)) node[\(kind),\(options)\(anchor)] (\(name)) {$\(latex(c.name))$};")
                for pin in c.pins {
                    let anchorName = c.kind == .opAmp ? (pin.name == "OUT" ? "out" : pin.name == "+" ? "+" : "-") : pin.name
                    lines.append("  \\draw (\(name).\(anchorName)) -- \(coordinate(c.world(pin.offset)));")
                }
            } else if c.kind.isConnection {
                if c.kind == .vdd || c.kind == .vss {
                    lines += nativeSymbol(c, theme: theme)
                } else {
                    let kind = c.kind == .ground ? "ground" : "ocirc"
                    lines.append("  \\draw \(coordinate(c.position)) node[\(kind),\(options)]{}\(c.kind == .ground ? "" : " node[above] {$\(latex(c.name))$}");")
                }
            } else {
                let mapping: [ComponentKind: String] = [.resistor: "R", .capacitor: "C", .polarizedCapacitor: "cC", .inductor: "L", .voltageSource: "V", .acVoltage: "sV", .currentSource: "I", .pulseSource: "V", .diode: "D", .zener: "zD", .led: "leD"]
                guard let kind = mapping[c.kind], let a = c.pinPosition("1"), let b = c.pinPosition("2") else { continue }
                let label = (c.showName ? latex(c.name) : "") + (c.showValue && !c.valueLabel.isEmpty ? "\\; \\mathrm{\(latex(c.valueLabel))}" : "")
                lines.append("  \\draw \(coordinate(a)) to[\(kind), l={$\(label)$}] \(coordinate(b));")
            }
        }
        for wire in circuit.wires { lines.append("  \\draw " + circuit.resolvedPoints(wire).map(coordinate).joined(separator: " -- ") + ";") }
        for p in Connectivity(circuit).connectionDots { lines.append("  \\fill \(coordinate(p)) circle (1.5pt);") }
        for label in circuit.labels { lines.append("  \\node[above right] at \(coordinate(label.position)) {$\(latex(label.text))$};") }
        for layer in circuit.figureLayers {
            let hex = CircuitRenderer.color(layer.style.color) == nil ? "202020" : layer.style.color!
            lines += ["  \\definecolor{csfigure}{HTML}{\(hex)}", "  \\begin{scope}[draw=csfigure, fill=csfigure, text=csfigure, line width=\(layer.style.width * 0.47)pt, line cap=round, line join=round\(layer.style.dashed ? ", dashed" : "")]"]
            lines += vectorCode(layer.primitives, texts: layer.texts)
            lines.append("  \\end{scope}")
        }
        lines.append("\\end{circuitikz}"); return lines.joined(separator: "\n")
    }
    private static func nativeSymbol(_ component: Component, theme: SymbolTheme) -> [String] {
        var single = Circuit(); single.components = [component]; single.theme = theme
        let scene = Symbols.scene(single)
        var lines = ["  % \(component.kind.rawValue) \(component.id.uuidString)"]
        lines.append("  \\begin{scope}[line width=0.8pt, line cap=round, line join=round]")
        lines += vectorCode(scene.primitives, texts: scene.texts)
        lines.append("  \\end{scope}")
        return lines
    }
    private static func vectorCode(_ primitives: [Primitive], texts: [DrawingText]) -> [String] {
        var lines: [String] = []
        for primitive in primitives {
            switch primitive {
            case .line(let points):
                lines.append("  \\draw[fill=none] " + points.map(coordinate).joined(separator: " -- ") + ";")
            case .polygon(let points, let filled):
                lines.append("  \\" + (filled ? "fill[draw=none]" : "draw[fill=none]") + " " + points.map(coordinate).joined(separator: " -- ") + " -- cycle;")
            case .circle(let center, let radius, let filled):
                lines.append("  \\" + (filled ? "fill[draw=none]" : "draw[fill=none]") + " \(coordinate(center)) circle (\(radius / 60)cm);")
            }
        }
        for text in texts {
            let content = text.text.contains("_") || text.text.contains("\\") || text.text.contains("μ") ? "$\(latex(text.text))$" : "\\textrm{\(latex(text.text))}"
            let font = String(format: "\\fontsize{%.1f}{%.1f}\\selectfont", text.size * 0.47, text.size * 0.60)
            lines.append("  \\node[anchor=north west, inner sep=0pt, font=\(font)] at \(coordinate(text.point)) {\(content)};")
        }
        return lines
    }
    public static func importCode(_ code: String) throws -> Circuit {
        if let line = code.components(separatedBy: .newlines).first(where: { $0.hasPrefix("% CircuitStudio-v1:") }), let data = Data(base64Encoded: String(line.dropFirst("% CircuitStudio-v1:".count))) { return try CircuitArchive.decode(data).circuit }
        var circuit = Circuit(title: "Imported CircuitikZ")
        let number = #"(-?\d+(?:\.\d+)?)"#, coord = "\\(\\s*\(number)\\s*,\\s*\(number)\\s*\\)"
        let pattern = coord + #"\s*(?:to\[([^\]]+)\]|(--))\s*"# + coord
        let regex = try NSRegularExpression(pattern: pattern); let ns = code as NSString
        let matches = regex.matches(in: code, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            func numberAt(_ i: Int) -> Double { Double(ns.substring(with: match.range(at: i))) ?? 0 }
            let a = Point(numberAt(1) * 60, -numberAt(2) * 60), b = Point(numberAt(5) * 60, -numberAt(6) * 60)
            if match.range(at: 4).location != NSNotFound { circuit.wires.append(Wire(points: [a, b])); continue }
            let options = ns.substring(with: match.range(at: 3)); let token = options.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            let mapping: [String: ComponentKind] = ["R": .resistor, "resistor": .resistor, "C": .capacitor, "capacitor": .capacitor, "L": .inductor, "V": .voltageSource, "sV": .acVoltage, "I": .currentSource, "D": .diode]
            guard let kind = mapping[token] else { throw CircuitError.message("CircuitikZ import does not yet support “\(token)”. Supported: coordinate-based R, C, L, V, sV, I, D and wires.") }
            let center = (a + b) * 0.5; let id = circuit.add(kind, at: center); let i = circuit.components.count - 1
            circuit.components[i].rotation = abs(a.x - b.x) > abs(a.y - b.y) ? (a.x < b.x ? 270 : 90) : (a.y < b.y ? 0 : 180)
            let terminalA = circuit.position(of: TerminalRef(id, "1"))!, terminalB = circuit.position(of: TerminalRef(id, "2"))!
            if a != terminalA { circuit.wires.append(Wire(points: [a, terminalA], end: TerminalRef(id, "1"))) }
            if b != terminalB { circuit.wires.append(Wire(points: [terminalB, b], start: TerminalRef(id, "2"))) }
            if let r = options.range(of: #"l\s*=\s*\{?\$?([^,\]}$]+)"#, options: .regularExpression) {
                let label = String(options[r]).components(separatedBy: "=").last!.trimmingCharacters(in: CharacterSet(charactersIn: " {$}"))
                if (try? EngineeringUnits.parse(label)) != nil { circuit.components[i].parameters["value"] = label }
            }
        }
        let groundRegex = try NSRegularExpression(pattern: coord + #"\s*node\[ground\]"#)
        for match in groundRegex.matches(in: code, range: NSRange(location: 0, length: ns.length)) { _ = circuit.add(.ground, at: Point((Double(ns.substring(with: match.range(at: 1))) ?? 0) * 60, -(Double(ns.substring(with: match.range(at: 2))) ?? 0) * 60)) }
        guard !matches.isEmpty else { throw CircuitError.message("No supported coordinate-based CircuitikZ elements were found.") }
        // Named anchors, relative coordinates and chained paths are not silently accepted.
        let stripped = code.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        if stripped.contains(" to[") || stripped.contains(" to [") || stripped.contains(" -- ") { throw CircuitError.message("This import contains chained paths or named anchors. Split each path into numeric coordinate pairs.") }
        return circuit
    }
}
