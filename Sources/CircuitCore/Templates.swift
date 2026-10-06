import Foundation

public enum CircuitTemplate: String, CaseIterable, Identifiable, Sendable {
    case commonSource = "Common-source amplifier", differentialPair = "Differential pair", currentMirror = "Current mirror", rcFilter = "RC low-pass filter", inverter = "CMOS inverter", blank = "Blank circuit"
    public var id: String { rawValue }
    public var subtitle: String {
        switch self {
        case .commonSource: "One transistor. A world of possibilities."
        case .differentialPair: "The heart of analog design."
        case .currentMirror: "A matched pair, a stable bias."
        case .rcFilter: "Explore your first frequency response."
        case .inverter: "Complementary devices, simple logic."
        case .blank: "Make room for your next idea."
        }
    }
    public func make() -> Circuit {
        var c = Circuit(title: rawValue)
        if self == .blank { return c }
        func add(_ kind: ComponentKind, _ p: Point, _ parameters: [String: String] = [:]) -> UUID {
            let id = c.add(kind, at: p); let i = c.components.count - 1; c.components[i].parameters.merge(parameters) { _, b in b }; return id
        }
        func wire(_ a: Point, _ b: Point) { c.wires.append(Wire(points: WireRouting.route(from: a, to: b))) }
        switch self {
        case .commonSource:
            let m = add(.nmos, Point(320, 260)), r = add(.resistor, Point(330, 140), ["value": "10k"])
            let input = add(.acVoltage, Point(120, 300), ["value": "0.55", "amplitude": "5m"]), supply = add(.voltageSource, Point(560, 140), ["value": "1.8"])
            let g1 = add(.ground, Point(330, 360)), g2 = add(.ground, Point(120, 360)), g3 = add(.ground, Point(560, 220))
            let vdd1 = add(.vdd, Point(330, 70)), vdd2 = add(.vdd, Point(560, 70)); let cap = add(.capacitor, Point(460, 290), ["value": "2p"]), g4 = add(.ground, Point(460, 360))
            c.connect(m, "D", r, "2"); c.connect(r, "1", vdd1, "1"); c.connect(supply, "1", vdd2, "1"); c.connect(supply, "2", g3, "1")
            c.connect(m, "S", g1, "1"); c.connect(input, "2", g2, "1")
            c.wires.append(Wire(points: [Point(120, 260), Point(280, 260)], start: TerminalRef(input, "1"), end: TerminalRef(m, "G")))
            wire(Point(330, 200), Point(460, 200)); wire(Point(460, 200), Point(460, 250)); c.connect(cap, "2", g4, "1")
            c.labels = [CircuitLabel("V_{IN}", at: Point(200, 260)), CircuitLabel("V_{OUT}", at: Point(400, 200))]
            c.simulation.source = "V1"; c.simulation.probes = ["VOUT", "VIN"]
        case .rcFilter:
            let v = add(.acVoltage, Point(100, 210), ["value": "0", "amplitude": "1", "frequency": "1k"])
            let r = add(.resistor, Point(240, 150), ["value": "10k"]); c.components[c.components.count - 1].rotation = 90
            let cap = add(.capacitor, Point(380, 210), ["value": "10n"])
            let g1 = add(.ground, Point(100, 310)), g2 = add(.ground, Point(380, 310))
            c.connect(v, "1", r, "2"); c.connect(r, "1", cap, "1"); c.connect(v, "2", g1, "1"); c.connect(cap, "2", g2, "1")
            c.labels = [CircuitLabel("V_{IN}", at: Point(160, 150)), CircuitLabel("V_{OUT}", at: Point(320, 150))]
        case .differentialPair:
            let m1 = add(.nmos, Point(220, 230)), m2 = add(.nmos, Point(440, 230)); c.components[c.components.count - 1].flipX = true
            let r1 = add(.resistor, Point(230, 120)), r2 = add(.resistor, Point(430, 120)); let power1 = add(.vdd, Point(230, 50)), power2 = add(.vdd, Point(430, 50))
            let tail = add(.currentSource, Point(330, 330), ["value": "100u"]), ground = add(.ground, Point(330, 410))
            c.connect(m1, "D", r1, "2"); c.connect(m2, "D", r2, "2"); c.connect(r1, "1", power1, "1"); c.connect(r2, "1", power2, "1")
            wire(Point(230, 270), Point(330, 290)); wire(Point(430, 270), Point(330, 290)); c.connect(tail, "2", ground, "1")
            c.labels = [CircuitLabel("V_{IN+}", at: Point(180, 230)), CircuitLabel("V_{IN-}", at: Point(480, 230)), CircuitLabel("V_{OUT+}", at: Point(230, 180)), CircuitLabel("V_{OUT-}", at: Point(430, 180))]
        case .currentMirror:
            let m1 = add(.nmos, Point(230, 250)), m2 = add(.nmos, Point(450, 250)); let i = add(.currentSource, Point(240, 120)), power = add(.vdd, Point(240, 50))
            let g1 = add(.ground, Point(240, 340)), g2 = add(.ground, Point(460, 340))
            c.connect(i, "1", power, "1"); c.connect(i, "2", m1, "D"); c.connect(m1, "S", g1, "1"); c.connect(m2, "S", g2, "1")
            c.wires.append(Wire(points: [Point(240, 190), Point(170, 190), Point(170, 250), Point(190, 250)], end: TerminalRef(m1, "G")))
            wire(Point(170, 190), Point(390, 190)); c.wires.append(Wire(points: [Point(390, 190), Point(390, 250), Point(410, 250)], end: TerminalRef(m2, "G")))
            c.labels = [CircuitLabel("I_{REF}", at: Point(240, 170)), CircuitLabel("I_{OUT}", at: Point(460, 210))]
        case .inverter:
            let p = add(.pmos, Point(320, 150)), n = add(.nmos, Point(320, 290)), power = add(.vdd, Point(330, 70)), ground = add(.ground, Point(330, 370))
            let input = add(.pulseSource, Point(100, 260), ["value": "0", "high": "1.8"]), inputGround = add(.ground, Point(100, 330))
            let supply = add(.voltageSource, Point(560, 150), ["value": "1.8"]), supplyRail = add(.vdd, Point(560, 70)), supplyGround = add(.ground, Point(560, 230))
            c.connect(p, "S", power, "1"); c.connect(p, "D", n, "D"); c.connect(n, "S", ground, "1")
            c.connect(supply, "1", supplyRail, "1"); c.connect(supply, "2", supplyGround, "1"); c.connect(input, "2", inputGround, "1")
            c.wires.append(Wire(points: [Point(100, 220), Point(200, 220)], start: TerminalRef(input, "1")))
            wire(Point(280, 150), Point(200, 150)); wire(Point(200, 150), Point(200, 290)); wire(Point(200, 290), Point(280, 290)); wire(Point(330, 220), Point(430, 220))
            c.labels = [CircuitLabel("V_{IN}", at: Point(200, 220)), CircuitLabel("V_{OUT}", at: Point(430, 220))]
            c.simulation.analysis = .tran; c.simulation.source = "V1"; c.simulation.duration = "2m"
        case .blank: break
        }
        return c
    }
}
