import Foundation

public struct Complex: Codable, Hashable, Sendable {
    public var real: Double; public var imaginary: Double
    public init(_ real: Double = 0, _ imaginary: Double = 0) { self.real = real; self.imaginary = imaginary }
    public var magnitude: Double { hypot(real, imaginary) }
    public var phase: Double { atan2(imaginary, real) * 180 / .pi }
    public static func + (a: Self, b: Self) -> Self { Self(a.real + b.real, a.imaginary + b.imaginary) }
    public static func - (a: Self, b: Self) -> Self { Self(a.real - b.real, a.imaginary - b.imaginary) }
    public static prefix func - (a: Self) -> Self { Self(-a.real, -a.imaginary) }
    public static func * (a: Self, b: Self) -> Self { Self(a.real * b.real - a.imaginary * b.imaginary, a.real * b.imaginary + a.imaginary * b.real) }
    public static func / (a: Self, b: Self) -> Self { let d = b.real * b.real + b.imaginary * b.imaginary; return Self((a.real * b.real + a.imaginary * b.imaginary) / d, (a.imaginary * b.real - a.real * b.imaginary) / d) }
}
public struct Waveform: Identifiable, Sendable {
    public var name: String; public var values: [Complex]; public var id: String { name }
    public init(name: String, values: [Complex]) { self.name = name; self.values = values }
}
public struct SimulationResult: Sendable {
    public var analysis: Analysis; public var axis: [Double]; public var waveforms: [Waveform]; public var engine: String
    public var operatingPoints: [String: [String: Double]] = [:]
    public var axisLabel: String { analysis == .ac ? "Frequency (Hz)" : analysis == .tran ? "Time (s)" : analysis == .dc ? "Sweep (V)" : "Operating point" }
    public func waveform(_ name: String) -> Waveform? { waveforms.first { $0.name.uppercased() == "V(\(MathLabel.netName(name)))" || $0.name.uppercased() == name.uppercased() } }
}

public enum SimulationEngine {
    public static func run(_ circuit: Circuit) throws -> SimulationResult {
        guard circuit.purpose.supportsSimulation else { throw CircuitError.message("Simulation is available in Schematic mode.") }
        return try EmbeddedSpice.run(circuit)
    }
}

#if os(macOS) && !APP_STORE
public enum NgspiceEngine {
    public static func run(_ circuit: Circuit, executable: String) throws -> SimulationResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CircuitStudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("circuit.spice"), raw = directory.appendingPathComponent("result.raw"), log = directory.appendingPathComponent("simulation.log")
        var netlist = try SPICENetlist.generate(circuit)
        var save = "save all"
        if circuit.simulation.analysis == .op { for c in circuit.components where c.kind.isMOS { for key in ["gm", "gds", "id", "vgs", "vds", "vdsat"] { save += " @\(c.name.lowercased())[\(key)]" } } }
        let control = ".control\nset filetype=ascii\n\(save)\nrun\nwrite \(raw.path) all\n.endc\n.end\n"
        netlist = netlist.replacingOccurrences(of: ".end\n", with: control)
        try netlist.write(to: input, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["-b", input.path]; process.standardOutput = handle; process.standardError = handle
        try process.run(); let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw CircuitError.message("Simulation took longer than 20 seconds. Reduce the sweep range or check your circuit.") }
        guard let data = try? String(contentsOf: raw, encoding: .utf8) else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if text.lowercased().contains("singular") { throw CircuitError.message("The circuit has a floating node or a loop of ideal voltage sources. Check the highlighted nets and ground connections.") }
            if text.lowercased().contains("unknown model") || text.lowercased().contains("could not find a valid modelname") { throw CircuitError.message("A device model is missing. Import its .model definition in the model library.") }
            throw CircuitError.message("SPICE could not solve this circuit. Check device models, source values and ground connections.\n" + text.split(separator: "\n").filter { $0.lowercased().contains("error") }.prefix(3).joined(separator: "\n"))
        }
        return try parseRaw(data, analysis: circuit.simulation.analysis)
    }
    public static func parseRaw(_ input: String, analysis: Analysis) throws -> SimulationResult {
        let lines = input.components(separatedBy: .newlines)
        guard let variablesIndex = lines.firstIndex(where: { $0.hasPrefix("Variables:") }), let valuesIndex = lines.firstIndex(where: { $0.hasPrefix("Values:") }) else { throw CircuitError.message("SPICE returned an unreadable waveform file.") }
        let variables = lines[(variablesIndex + 1)..<valuesIndex].compactMap { line -> String? in let tokens = line.split(whereSeparator: \.isWhitespace); return tokens.count >= 3 ? String(tokens[1]) : nil }
        guard !variables.isEmpty else { throw CircuitError.message("SPICE returned no waveforms.") }
        var columns = Array(repeating: [Complex](), count: variables.count); var valueCount = 0
        for line in lines.dropFirst(valuesIndex + 1) {
            let tokens = line.split(whereSeparator: \.isWhitespace); guard let last = tokens.last else { continue }
            let pair = last.split(separator: ",")
            guard let re = pair.first.flatMap({ Double($0) }) else { continue }; let im = pair.count > 1 ? Double(pair[1]) ?? 0 : 0
            columns[valueCount % variables.count].append(Complex(re, im)); valueCount += 1
        }
        guard valueCount > 0, valueCount % variables.count == 0 else { throw CircuitError.message("SPICE returned incomplete waveform samples.") }
        var result = SimulationResult(analysis: analysis, axis: columns[0].map(\.real), waveforms: [], engine: "ngspice")
        for (i, name) in variables.enumerated() {
            if name.hasPrefix("@"), let bracket = name.firstIndex(of: "[") {
                let device = String(name[name.index(after: name.startIndex)..<bracket]).uppercased(), property = String(name[name.index(after: bracket)...].dropLast())
                result.operatingPoints[device, default: [:]][property] = columns[i].first?.real
            } else if i > 0 || analysis == .op { result.waveforms.append(Waveform(name: name.uppercased(), values: columns[i])) }
        }
        if analysis == .op { result.axis = [0] }
        return result
    }
}
#endif

/// Portable modified nodal analysis for linear RC circuits. Nonlinear devices are rejected explicitly.
public enum LinearSimulator {
    public static func run(_ circuit: Circuit) throws -> SimulationResult {
        let allowed: [ComponentKind] = [.resistor, .capacitor, .polarizedCapacitor, .voltageSource, .acVoltage, .pulseSource, .currentSource, .ground, .vdd, .vss, .port]
        if let c = circuit.components.first(where: { !allowed.contains($0.kind) }) { throw CircuitError.message("The portable solver supports linear RC circuits. \(c.kind.title) requires ngspice on Mac. You can still export the complete SPICE netlist on this device.") }
        let topology = Connectivity(circuit), nodes = topology.nets.filter { $0.name != "0" && !$0.terminals.isEmpty }.map(\.name)
        let nodeIndex = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, $0.offset) })
        let sources = circuit.components.filter { [.voltageSource, .acVoltage, .pulseSource].contains($0.kind) }
        let dimension = nodes.count + sources.count
        guard dimension > 0, dimension <= 80 else { throw CircuitError.message("The portable solver supports up to 80 matrix variables. Use ngspice on Mac for larger circuits.") }
        let s = circuit.simulation; _ = try SPICENetlist.directive(s)
        var axis: [Double]
        switch s.analysis {
        case .op: axis = [0]
        case .ac:
            let start = try EngineeringUnits.parse(s.start), stop = try EngineeringUnits.parse(s.stop), count = Int(ceil(log10(stop / start) * Double(s.points)))
            guard count < 10000 else { throw CircuitError.message("Choose fewer AC points.") }
            axis = (0...count).map { start * pow(stop / start, Double($0) / Double(max(1, count))) }
        case .dc:
            guard sources.contains(where: { $0.name == s.source }) else { throw CircuitError.message("DC sweep source \(s.source) does not exist.") }
            let start = try EngineeringUnits.parse(s.dcStart), stop = try EngineeringUnits.parse(s.dcStop), step = try EngineeringUnits.parse(s.dcStep)
            axis = (0...Int((stop - start) / step)).map { start + Double($0) * step }
        case .tran:
            let duration = try EngineeringUnits.parse(s.duration), step = try EngineeringUnits.parse(s.timeStep)
            axis = (0...Int(duration / step)).map { Double($0) * step }
        }
        guard axis.count * dimension <= 2_000_000 else { throw CircuitError.message("Reduce the analysis range for this device.") }
        var columns = Array(repeating: [Complex](), count: dimension), previous = Array(repeating: Complex(), count: dimension)
        for x in axis {
            var a = Array(repeating: Array(repeating: Complex(), count: dimension), count: dimension), b = Array(repeating: Complex(), count: dimension)
            func idx(_ c: Component, _ pin: String) -> Int? { nodeIndex[topology.net(c.id, pin)] }
            func stampConductance(_ i: Int?, _ j: Int?, _ g: Complex) {
                if let i { a[i][i] = a[i][i] + g }; if let j { a[j][j] = a[j][j] + g }
                if let i, let j { a[i][j] = a[i][j] - g; a[j][i] = a[j][i] - g }
            }
            func stampCurrent(_ i: Int?, _ j: Int?, _ current: Complex) { if let i { b[i] = b[i] - current }; if let j { b[j] = b[j] + current } }
            for c in circuit.components {
                let i = idx(c, "1"), j = idx(c, "2"), value = try EngineeringUnits.parse(c.parameters["value"] ?? "0")
                if c.kind == .resistor { stampConductance(i, j, Complex(1 / value)) }
                if [.capacitor, .polarizedCapacitor].contains(c.kind) {
                    if s.analysis == .ac { stampConductance(i, j, Complex(0, 2 * .pi * x * value)) }
                    if s.analysis == .tran && x > 0 {
                        let g = value / (try EngineeringUnits.parse(s.timeStep)); stampConductance(i, j, Complex(g))
                        let prevV = (i.map { previous[$0] } ?? Complex()) - (j.map { previous[$0] } ?? Complex()); stampCurrent(i, j, -Complex(g) * prevV)
                    }
                }
                if c.kind == .currentSource { stampCurrent(i, j, Complex(s.analysis == .ac ? 0 : value)) }
                if let source = sources.firstIndex(where: { $0.id == c.id }) {
                    let k = nodes.count + source
                    if let i { a[i][k] = Complex(1); a[k][i] = Complex(1) }; if let j { a[j][k] = Complex(-1); a[k][j] = Complex(-1) }
                    var voltage = value
                    if s.analysis == .ac { voltage = try EngineeringUnits.parse(c.parameters["ac"] ?? "0") }
                    if s.analysis == .dc && c.name == s.source { voltage = x }
                    if s.analysis == .tran && c.kind == .acVoltage { voltage += (try EngineeringUnits.parse(c.parameters["amplitude"] ?? "0")) * sin(2 * .pi * (try EngineeringUnits.parse(c.parameters["frequency"] ?? "1k")) * x) }
                    if s.analysis == .tran && c.kind == .pulseSource {
                        let period = try EngineeringUnits.parse(c.parameters["period"] ?? "1m"), width = try EngineeringUnits.parse(c.parameters["width"] ?? "500u")
                        guard period > 0, width > 0, width <= period else { throw CircuitError.message("\(c.name): pulse width must be positive and no greater than its period.") }
                        if x.truncatingRemainder(dividingBy: period) < width { voltage = try EngineeringUnits.parse(c.parameters["high"] ?? "1.8") }
                    }
                    b[k] = Complex(voltage)
                }
            }
            previous = try solve(a, b)
            for i in 0..<dimension { columns[i].append(previous[i]) }
        }
        let waveforms = nodes.enumerated().map { Waveform(name: "V(\($0.element))", values: columns[$0.offset]) } + sources.enumerated().map { Waveform(name: "I(\($0.element.name))", values: columns[nodes.count + $0.offset]) }
        return SimulationResult(analysis: s.analysis, axis: axis, waveforms: waveforms, engine: "Native linear RC solver")
    }
    static func solve(_ input: [[Complex]], _ rhs: [Complex]) throws -> [Complex] {
        var a = input, b = rhs; let n = b.count
        for k in 0..<n {
            let pivot = (k..<n).max { a[$0][k].magnitude < a[$1][k].magnitude }!
            guard a[pivot][k].magnitude > 1e-18 else { throw CircuitError.message("A node is floating or ideal voltage sources form a loop. Check the circuit’s ground reference and connections.") }
            if pivot != k { a.swapAt(k, pivot); b.swapAt(k, pivot) }
            if k + 1 < n { for i in (k + 1)..<n {
                let factor = a[i][k] / a[k][k]; for j in k..<n { a[i][j] = a[i][j] - factor * a[k][j] }; b[i] = b[i] - factor * b[k]
            } }
        }
        var x = Array(repeating: Complex(), count: n)
        for i in stride(from: n - 1, through: 0, by: -1) { var v = b[i]; if i + 1 < n { for j in (i + 1)..<n { v = v - a[i][j] * x[j] } }; x[i] = v / a[i][i] }
        guard x.allSatisfy({ $0.real.isFinite && $0.imaginary.isFinite }) else { throw CircuitError.message("The solver produced an invalid value. Check component values.") }; return x
    }
}
