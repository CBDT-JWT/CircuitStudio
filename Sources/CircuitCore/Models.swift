import Foundation

public enum SymbolTheme: String, Codable, CaseIterable, Sendable { case razavi = "Razavi", ieee = "IEEE", iec = "IEC", circuitikz = "CircuitikZ" }
public enum DiagramMode: String, Codable, CaseIterable, Sendable { case standard = "Standard", publication = "Publication", presentation = "Presentation" }
public enum CanvasPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case schematic = "Schematic", illustration = "Illustration"
    public var id: String { rawValue }
    public var supportsSimulation: Bool { self == .schematic }
    public var subtitle: String { self == .schematic ? "Circuit design · Offline simulation" : "Block diagrams · Paper figures" }
}
public enum ComponentKind: String, Codable, CaseIterable, Sendable {
    case resistor, capacitor, polarizedCapacitor, inductor, voltageSource, acVoltage, currentSource, pulseSource
    case nmos, pmos, npn, pnp, diode, zener, led, opAmp, ground, vdd, vss, port
    public var title: String {
        switch self {
        case .resistor: "Resistor"; case .capacitor: "Capacitor"; case .polarizedCapacitor: "Polarized capacitor"
        case .inductor: "Inductor"; case .voltageSource: "DC voltage"; case .acVoltage: "AC / sine voltage"
        case .currentSource: "Current source"; case .pulseSource: "Pulse voltage"; case .nmos: "NMOS"; case .pmos: "PMOS"
        case .npn: "NPN"; case .pnp: "PNP"; case .diode: "Diode"; case .zener: "Zener diode"; case .led: "LED"
        case .opAmp: "Op amp"; case .ground: "Ground"; case .vdd: "VDD"; case .vss: "VSS"; case .port: "Port"
        }
    }
    public var category: String {
        switch self {
        case .resistor, .capacitor, .polarizedCapacitor, .inductor: "Passives"
        case .voltageSource, .acVoltage, .currentSource, .pulseSource: "Sources"
        case .nmos, .pmos, .npn, .pnp, .diode, .zener, .led: "Semiconductors"
        case .opAmp: "Amplifiers"
        default: "Connections"
        }
    }
    public var prefix: String {
        switch self {
        case .resistor: "R"; case .capacitor, .polarizedCapacitor: "C"; case .inductor: "L"
        case .voltageSource, .acVoltage, .pulseSource: "V"; case .currentSource: "I"
        case .nmos, .pmos: "M"; case .npn, .pnp: "Q"; case .diode, .zener, .led: "D"
        case .opAmp: "E"; case .ground: "GND"; case .vdd: "VDD"; case .vss: "VSS"; case .port: "P"
        }
    }
    public var defaultParameters: [String: String] {
        switch self {
        case .resistor: ["value": "10k"]
        case .capacitor, .polarizedCapacitor: ["value": "2p"]
        case .inductor: ["value": "10u"]
        case .voltageSource: ["value": "1.8", "ac": "0"]
        case .acVoltage: ["value": "0.7", "ac": "1", "amplitude": "10m", "frequency": "1k"]
        case .pulseSource: ["value": "0", "high": "1.8", "period": "1m", "width": "500u", "ac": "1"]
        case .currentSource: ["value": "100u"]
        case .nmos, .pmos: ["W": "20u", "L": "180n", "M": "1", "NF": "1", "model": self == .nmos ? "NMOS" : "PMOS", "bulk": "source"]
        case .npn, .pnp: ["model": self == .npn ? "NPN" : "PNP"]
        case .diode, .zener, .led: ["model": "DDEFAULT"]
        case .opAmp: ["gain": "100k"]
        default: [:]
        }
    }
    public var isMOS: Bool { self == .nmos || self == .pmos }
    public var isConnection: Bool { [.ground, .vdd, .vss, .port].contains(self) }
}

public struct Pin: Codable, Hashable, Sendable {
    public var name: String; public var offset: Point
    public init(_ name: String, _ offset: Point) { self.name = name; self.offset = offset }
}
public struct Component: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID; public var kind: ComponentKind; public var name: String; public var position: Point
    public var rotation: Int = 0; public var flipX = false; public var flipY = false
    public var parameters: [String: String]; public var showName = true; public var showValue = true
    public init(kind: ComponentKind, name: String, position: Point, id: UUID = UUID()) {
        self.id = id; self.kind = kind; self.name = name; self.position = position; parameters = kind.defaultParameters
    }
    public var pins: [Pin] {
        switch kind {
        case .nmos, .pmos:
            // PMOS source is the upper terminal in the native academic symbol.
            var pins = [Pin("D", Point(10, kind == .pmos ? 40 : -40)), Pin("G", Point(-40, 0)), Pin("S", Point(10, kind == .pmos ? -40 : 40))]
            if parameters["bulk"] == "external" { pins.append(Pin("B", Point(40, 0))) }
            return pins
        case .npn, .pnp: return [Pin("C", Point(10, -40)), Pin("B", Point(-40, 0)), Pin("E", Point(10, 40))]
        case .opAmp: return [Pin("+", Point(-40, 20)), Pin("-", Point(-40, -20)), Pin("OUT", Point(40, 0))]
        case .ground, .vdd, .vss, .port: return [Pin("1", .zero)]
        default: return [Pin("1", Point(0, -40)), Pin("2", Point(0, 40))]
        }
    }
    public func world(_ local: Point) -> Point { position + local.transformed(rotation: rotation, flipX: flipX, flipY: flipY) }
    public func pinPosition(_ name: String) -> Point? { pins.first { $0.name == name }.map { world($0.offset) } }
    public var bodyBounds: Bounds { Bounds([world(Point(-25, -28)), world(Point(25, 28)), world(Point(-25, 28)), world(Point(25, -28))]) }
    public var valueLabel: String {
        if kind.isMOS { return "\(EngineeringUnits.display(parameters["W"] ?? "20u", unit: "m")) / \(EngineeringUnits.display(parameters["L"] ?? "180n", unit: "m"))" }
        let unit = kind == .resistor ? "Ω" : [.capacitor, .polarizedCapacitor].contains(kind) ? "F" : kind == .inductor ? "H" : kind == .currentSource ? "A" : "V"
        return parameters["value"].map { EngineeringUnits.display($0, unit: unit) } ?? ""
    }
}

public struct TerminalRef: Codable, Hashable, Sendable {
    public var componentID: UUID; public var pin: String
    public init(_ componentID: UUID, _ pin: String) { self.componentID = componentID; self.pin = pin }
}
public struct Wire: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID; public var points: [Point]; public var start: TerminalRef?; public var end: TerminalRef?
    public init(points: [Point], start: TerminalRef? = nil, end: TerminalRef? = nil) { id = UUID(); self.points = points; self.start = start; self.end = end }
}
public struct CircuitLabel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID; public var text: String; public var position: Point; public var isNet: Bool
    public init(_ text: String, at position: Point, isNet: Bool = true) { id = UUID(); self.text = text; self.position = position; self.isNet = isNet }
}
public enum Analysis: String, Codable, CaseIterable, Sendable { case op = "Operating point", dc = "DC sweep", ac = "AC analysis", tran = "Transient" }
public struct SimulationSettings: Codable, Hashable, Sendable {
    public var analysis: Analysis = .ac
    public var start = "10"; public var stop = "100Meg"; public var points = 40
    public var source = "V1"; public var dcStart = "0"; public var dcStop = "1.8"; public var dcStep = "10m"
    public var timeStep = "1u"; public var duration = "5m"; public var probes: [String] = ["VOUT", "VIN"]
    public init() {}
}
public struct Circuit: Codable, Hashable, Sendable {
    public var id = UUID(); public var title = "Untitled circuit"; public var components: [Component] = []
    public var wires: [Wire] = []; public var labels: [CircuitLabel] = []; public var junctions: [Point] = []
    public var figures: [FigureElement] = []; public var figureConnectors: [FigureConnector] = []
    public var theme: SymbolTheme = .razavi; public var mode: DiagramMode = .standard
    public var purpose: CanvasPurpose = .schematic
    public var simulation = SimulationSettings(); public var modelLibrary = ""
    /// Monotonic counters prevent deleted reference designators being reused.
    public var nameCounters: [String: Int] = [:]
    public init(title: String = "Untitled circuit", purpose: CanvasPurpose = .schematic) { self.title = title; self.purpose = purpose }
    enum CodingKeys: String, CodingKey { case id, title, components, wires, labels, junctions, figures, figureConnectors, theme, mode, purpose, simulation, modelLibrary, nameCounters }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); title = try values.decode(String.self, forKey: .title)
        components = try values.decode([Component].self, forKey: .components); wires = try values.decode([Wire].self, forKey: .wires)
        labels = try values.decode([CircuitLabel].self, forKey: .labels); junctions = try values.decode([Point].self, forKey: .junctions)
        figures = try values.decodeIfPresent([FigureElement].self, forKey: .figures) ?? []
        figureConnectors = try values.decodeIfPresent([FigureConnector].self, forKey: .figureConnectors) ?? []
        purpose = try values.decodeIfPresent(CanvasPurpose.self, forKey: .purpose) ?? (components.isEmpty && !figures.isEmpty ? .illustration : .schematic)
        theme = try values.decode(SymbolTheme.self, forKey: .theme); mode = try values.decode(DiagramMode.self, forKey: .mode)
        simulation = try values.decode(SimulationSettings.self, forKey: .simulation); modelLibrary = try values.decode(String.self, forKey: .modelLibrary)
        nameCounters = try values.decode([String: Int].self, forKey: .nameCounters)
    }
    public mutating func add(_ kind: ComponentKind, at position: Point) -> UUID {
        let n = max(nameCounters[kind.prefix] ?? 0, components.filter { $0.kind.prefix == kind.prefix }.compactMap { Int($0.name.dropFirst(kind.prefix.count)) }.max() ?? 0) + 1
        nameCounters[kind.prefix] = n
        let component = Component(kind: kind, name: kind.isConnection ? kind.prefix : "\(kind.prefix)\(n)", position: position)
        components.append(component); return component.id
    }
    public func position(of terminal: TerminalRef) -> Point? { components.first { $0.id == terminal.componentID }?.pinPosition(terminal.pin) ?? figures.first { $0.id == terminal.componentID }?.anchor(terminal.pin) }
    public func resolvedPoints(_ wire: Wire) -> [Point] {
        guard wire.points.count > 1 else { return wire.points }
        var points = wire.points
        let a = wire.start.flatMap { position(of: $0) } ?? points[0]
        let b = wire.end.flatMap { position(of: $0) } ?? points[points.count - 1]
        if a != points[0] || b != points[points.count - 1] { return WireRouting.route(from: a, to: b, obstacles: components.map(\.bodyBounds)) }
        points[0] = a; points[points.count - 1] = b; return points
    }
    public var bounds: Bounds {
        return Symbols.drawingBounds(self)
    }
    public mutating func connect(_ a: UUID, _ ap: String, _ b: UUID, _ bp: String) {
        let start = TerminalRef(a, ap), end = TerminalRef(b, bp)
        guard let pa = position(of: start), let pb = position(of: end) else { return }
        wires.append(Wire(points: WireRouting.route(from: pa, to: pb, obstacles: components.map(\.bodyBounds)), start: start, end: end))
    }
}

public struct CircuitArchive: Codable, Sendable {
    public static let currentVersion = 3
    public var formatVersion = currentVersion; public var circuit: Circuit
    public init(_ circuit: Circuit) { self.circuit = circuit }
    public func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self) }
    public static func decode(_ data: Data) throws -> CircuitArchive {
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard (1...currentVersion).contains(archive.formatVersion) else { throw CircuitError.message("This document uses format version \(archive.formatVersion). Update Circuit Studio to open it.") }
        let ids = archive.circuit.components.map(\.id) + archive.circuit.wires.map(\.id) + archive.circuit.labels.map(\.id) + archive.circuit.figures.map(\.id) + archive.circuit.figureConnectors.map(\.id)
        guard Set(ids).count == ids.count else { throw CircuitError.message("The document contains duplicate object identifiers.") }
        guard archive.circuit.components.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && [0, 90, 180, 270].contains($0.rotation) }), archive.circuit.wires.allSatisfy({ $0.points.count >= 2 && $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else { throw CircuitError.message("The document contains invalid geometry.") }
        guard archive.circuit.figures.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && $0.size.x.isFinite && $0.size.y.isFinite && $0.size.x >= 2 && $0.size.y >= 2 && $0.fontSize.isFinite && (8...72).contains($0.fontSize) && $0.style.width.isFinite && (0.5...6).contains($0.style.width) && [0, 90, 180, 270].contains($0.rotation) }), archive.circuit.figureConnectors.allSatisfy({ $0.points.count >= 2 && $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } && $0.style.width.isFinite && (0.5...6).contains($0.style.width) }) else { throw CircuitError.message("The document contains invalid figure geometry.") }
        return archive
    }
}
public enum CircuitError: LocalizedError { case message(String); public var errorDescription: String? { if case .message(let s) = self { return s }; return nil } }
