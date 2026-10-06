import Foundation

public enum PaperExample: String, CaseIterable, Identifiable, Sendable {
    case system = "Analog system diagram", flow = "Simulation flowchart", device = "MOS device cross-section"
    public var id: String { rawValue }
    public var subtitle: String { switch self { case .system: "Signal path, feedback and mathematical labels"; case .flow: "Process blocks, decisions and attached arrows"; case .device: "Layers, contacts and dimension annotations" } }
    public func make() -> Circuit {
        var c = Circuit(title: rawValue, purpose: .illustration); c.mode = .publication
        @discardableResult func shape(_ kind: FigureKind, _ p: Point, _ size: Point, _ text: String, fill: String? = nil, font: Double = 18) -> UUID {
            var element = FigureElement(kind, at: p, text: text); element.size = size; element.fontSize = font; element.style.fill = fill
            c.figures.append(element); return element.id
        }
        func connect(_ a: UUID, _ ap: String, _ b: UUID, _ bp: String, _ text: String = "", route: FigureRoute = .straight) {
            let start = TerminalRef(a, ap), end = TerminalRef(b, bp)
            guard let first = c.position(of: start), let last = c.position(of: end) else { return }
            var connector = FigureConnector(from: first, to: last, start: start, end: end); connector.text = text; connector.route = route
            c.figureConnectors.append(connector)
        }
        switch self {
        case .system:
            shape(.text, Point(370, 45), Point(500, 40), "Closed-loop analog signal chain", font: 23)
            let input = shape(.inputPort, Point(30, 160), Point(80, 40), "V_{IN}")
            let sum = shape(.summingJunction, Point(135, 160), Point(42, 42), "+", font: 22)
            let ota = shape(.rectangle, Point(280, 160), Point(150, 80), "OTA\ng_m, r_o")
            let sample = shape(.rectangle, Point(510, 160), Point(160, 80), "Sample & Hold\nC_L")
            let adc = shape(.rectangle, Point(745, 160), Point(140, 80), "ADC\nD_{OUT}")
            let dac = shape(.rectangle, Point(510, 320), Point(160, 70), "Feedback DAC")
            let output = shape(.outputPort, Point(940, 160), Point(100, 40), "D_{OUT}")
            connect(input, "right", sum, "left"); connect(sum, "right", ota, "left")
            connect(ota, "right", sample, "left", "V_{OUT}"); connect(sample, "right", adc, "left")
            connect(adc, "right", output, "left")
            connect(adc, "bottom", dac, "right", route: .orthogonal); connect(dac, "left", sum, "bottom", route: .orthogonal)
            shape(.text, Point(380, 415), Point(600, 40), "(a) Amplification, sampling and digital conversion", font: 16)
        case .flow:
            shape(.text, Point(300, 35), Point(500, 40), "Circuit simulation procedure", font: 23)
            let start = shape(.ellipse, Point(240, 110), Point(120, 50), "Start")
            let setup = shape(.rectangle, Point(240, 215), Point(190, 65), "Build netlist\nSet initial conditions")
            let solve = shape(.rectangle, Point(240, 340), Point(190, 65), "Solve circuit equations")
            let decision = shape(.diamond, Point(240, 485), Point(190, 100), "Converged?")
            let finish = shape(.ellipse, Point(240, 650), Point(140, 50), "Save waveforms")
            let update = shape(.rectangle, Point(520, 485), Point(170, 70), "Update state\nNext iteration")
            connect(start, "bottom", setup, "top"); connect(setup, "bottom", solve, "top"); connect(solve, "bottom", decision, "top")
            connect(decision, "bottom", finish, "top", "Yes"); connect(decision, "right", update, "left", "No")
            connect(update, "top", solve, "right", route: .orthogonal)
        case .device:
            shape(.text, Point(370, 30), Point(500, 40), "NMOS device cross-section", font: 23)
            shape(.rectangle, Point(370, 275), Point(620, 170), "", fill: "f1f1f1")
            shape(.text, Point(370, 310), Point(200, 40), "p-type substrate", font: 19)
            shape(.rectangle, Point(210, 220), Point(110, 60), "n+", fill: "dddddd")
            shape(.rectangle, Point(530, 220), Point(110, 60), "n+", fill: "dddddd")
            shape(.rectangle, Point(370, 183), Point(200, 14), "", fill: "ffffff")
            shape(.rectangle, Point(370, 159), Point(180, 34), "Gate", fill: "d2d2d2", font: 17)
            shape(.rectangle, Point(210, 151), Point(25, 78), "", fill: "dddddd")
            shape(.rectangle, Point(530, 151), Point(25, 78), "", fill: "dddddd")
            shape(.text, Point(210, 80), Point(120, 40), "Source")
            shape(.text, Point(370, 80), Point(120, 40), "Gate")
            shape(.text, Point(530, 80), Point(120, 40), "Drain")
            for x in [210.0, 370.0, 530.0] { var line = FigureConnector(from: Point(x, 100), to: Point(x, x == 370 ? 140 : 112)); line.arrows = .none; c.figureConnectors.append(line) }
            var dimension = FigureConnector(from: Point(280, 245), to: Point(460, 245)); dimension.arrows = .both; dimension.text = "L"; dimension.style.width = 1; c.figureConnectors.append(dimension)
            var oxide = FigureConnector(from: Point(630, 98), to: Point(470, 183)); oxide.points = [Point(630, 98), Point(490, 98), Point(475, 160), Point(470, 183)]; oxide.style.width = 1; c.figureConnectors.append(oxide)
            shape(.text, Point(630, 75), Point(100, 35), "Gate oxide", font: 16)
            shape(.text, Point(370, 415), Point(600, 40), "(c) Cross-section illustration, not to scale", font: 16)
        }
        return c
    }
}
