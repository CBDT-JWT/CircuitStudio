import Foundation
import NgSpice

/// ngspice owns process-global circuit state. All documents share this serialized session.
private final class SpiceSession: @unchecked Sendable {
    let runLock = NSLock()
    private let callbackLock = NSLock()
    var initialized = false
    var unusable = false
    private var output = ""
    private var exitCode: Int32?
    private var completed = false
    func append(_ line: String) { callbackLock.withLock { output = String((output + line + "\n").suffix(16_384)) } }
    func exited(_ code: Int32) { callbackLock.withLock { exitCode = code } }
    func clear() { callbackLock.withLock { output = ""; exitCode = nil; completed = false } }
    func backgroundExited(_ value: Bool) { callbackLock.withLock { completed = value } }
    var isComplete: Bool { callbackLock.withLock { completed } }
    var log: String { callbackLock.withLock { output } }
    var failure: Int32? { callbackLock.withLock { exitCode } }
}

private func spiceOutput(_ text: UnsafeMutablePointer<CChar>?, _ identifier: Int32, _ context: UnsafeMutableRawPointer?) -> Int32 {
    if let text, let context { Unmanaged<SpiceSession>.fromOpaque(context).takeUnretainedValue().append(String(cString: text)) }
    return 0
}
private func spiceExit(_ code: Int32, _ immediate: Bool, _ requested: Bool, _ identifier: Int32, _ context: UnsafeMutableRawPointer?) -> Int32 {
    if let context { Unmanaged<SpiceSession>.fromOpaque(context).takeUnretainedValue().exited(code) }
    return 0
}
private func spiceBackground(_ exited: Bool, _ identifier: Int32, _ context: UnsafeMutableRawPointer?) -> Int32 {
    // sharedspice.c sends false on thread entry and true after cp_evloop finishes.
    if let context { Unmanaged<SpiceSession>.fromOpaque(context).takeUnretainedValue().backgroundExited(exited) }
    return 0
}

public enum EmbeddedSpice {
    private static let session = SpiceSession()
    public static let version = "ngspice 47 · on-device"

    /// Runs off the UI thread. No process launching, network access or external executable is used.
    public static func run(_ circuit: Circuit, timeout: TimeInterval = 20) throws -> SimulationResult {
        try SPICENetlist.validate(circuit)
        session.runLock.lock(); defer { session.runLock.unlock() }
        guard !session.unusable else { throw CircuitError.message("The simulation engine could not stop its previous analysis. Reopen the app before running another simulation.") }
        if !session.initialized {
            let status = ngSpice_Init(spiceOutput, nil, spiceExit, nil, nil, spiceBackground, Unmanaged.passUnretained(session).toOpaque())
            guard status == 0 else { throw CircuitError.message("The built-in SPICE engine could not initialize.") }
            session.initialized = true
            _ = command("set noaskquit")
            _ = command("set nomoremode")
        }
        _ = command("destroy all"); _ = command("remcirc"); session.clear()
        let netlist = try SPICENetlist.generate(circuit)
        let deck = netlist.split(separator: "\n", omittingEmptySubsequences: false).map { strdup(String($0)) }
        defer { deck.forEach { free($0) } }
        guard deck.allSatisfy({ $0 != nil }) else { throw CircuitError.message("Not enough memory to prepare this circuit.") }
        var pointers = deck + [nil]
        let status = pointers.withUnsafeMutableBufferPointer { ngSpice_Circ($0.baseAddress) }
        guard status == 0, session.failure == nil else { throw simulationError(session.log) }
        var save = "save all"
        if circuit.simulation.analysis == .op {
            for component in circuit.components where component.kind.isMOS {
                for key in ["id", "gm", "gds", "vgs", "vds", "vdsat"] { save += " @\(component.name.lowercased())[\(key)]" }
            }
        }
        _ = command(save)
        guard command("bg_run") == 0 else { throw simulationError(session.log) }
        let deadline = Date().addingTimeInterval(max(0.001, timeout))
        while !session.isComplete && session.failure == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        if !session.isComplete && session.failure == nil {
            _ = command("bg_halt")
            if !session.isComplete { session.unusable = true }
            throw CircuitError.message("Simulation took longer than \(Int(timeout)) seconds. Reduce the sweep range or check your circuit.")
        }
        // Finish the shared library's background-run state before reading or loading another circuit.
        _ = command("bg_halt")
        guard session.failure == nil else { throw simulationError(session.log) }
        return try readResult(analysis: circuit.simulation.analysis)
    }

    @discardableResult private static func command(_ text: String) -> Int32 {
        var bytes = Array(text.utf8CString)
        return bytes.withUnsafeMutableBufferPointer { ngSpice_Command($0.baseAddress) }
    }

    private static func readResult(analysis: Analysis) throws -> SimulationResult {
        guard let plot = ngSpice_CurPlot(), String(cString: plot) != "const", let names = ngSpice_AllVecs(plot) else { throw simulationError(session.log) }
        var vectors: [(String, Int32, [Complex])] = []
        var index = 0, total = 0
        while let name = names[index] {
            guard index < 10_000, let pointer = ngGet_Vec_Info(name) else { throw CircuitError.message("SPICE returned an unreadable waveform.") }
            let info = pointer.pointee, count = Int(info.v_length)
            total += count
            guard count > 0, count <= 500_000, total <= 8_000_000 else { throw CircuitError.message("This result is too large to display. Reduce the analysis range or number of probes.") }
            let values: [Complex]
            if let data = info.v_compdata { values = (0..<count).map { Complex(data[$0].cx_real, data[$0].cx_imag) } }
            else if let data = info.v_realdata { values = (0..<count).map { Complex(data[$0]) } }
            else { throw CircuitError.message("SPICE returned a waveform without samples.") }
            guard values.allSatisfy({ $0.real.isFinite && $0.imaginary.isFinite }) else { throw CircuitError.message("SPICE produced an invalid value. Check component values and device models.") }
            vectors.append((String(cString: name), info.v_type, values)); index += 1
        }
        let scale = vectors.first { name, type, _ in
            analysis == .ac ? type == 2 : analysis == .tran ? type == 1 : name == "v-sweep" || name == "i-sweep"
        }
        guard analysis == .op || scale != nil else { throw simulationError(session.log) }
        var result = SimulationResult(analysis: analysis, axis: analysis == .op ? [0] : scale!.2.map(\.real), waveforms: [], engine: version)
        for (name, type, values) in vectors {
            if name.hasPrefix("@"), let bracket = name.firstIndex(of: "[") {
                let device = String(name.dropFirst().prefix(upTo: bracket)).uppercased()
                let property = String(name[name.index(after: bracket)...].dropLast())
                result.operatingPoints[device, default: [:]][property] = values.first?.real
            } else if name != scale?.0 && (type == 3 || type == 4) {
                guard values.count == result.axis.count else { throw CircuitError.message("SPICE returned incomplete waveform samples.") }
                let title: String
                if type == 3 { title = name.lowercased().hasPrefix("v(") ? name.uppercased() : "V(\(name.uppercased()))" }
                else { title = name.lowercased().hasSuffix("#branch") ? "I(\(name.dropLast(7).uppercased()))" : name.uppercased() }
                result.waveforms.append(Waveform(name: title, values: values))
            }
        }
        for device in Array(result.operatingPoints.keys) {
            if let gds = result.operatingPoints[device]?["gds"], gds > 0 { result.operatingPoints[device]?["ro"] = 1 / gds }
        }
        guard !result.waveforms.isEmpty else { throw simulationError(session.log) }
        return result
    }

    private static func simulationError(_ log: String) -> CircuitError {
        let text = log.lowercased()
        if text.contains("unknown model") || text.contains("could not find a valid modelname") || text.contains("model not found") {
            return .message("A device model is missing or unsupported. Import its .model definition in the model library.")
        }
        if text.contains("singular") || text.contains("no dc path") {
            return .message("The circuit has a floating node or a loop of ideal voltage sources. Check its ground reference and connections.")
        }
        if text.contains("timestep too small") {
            return .message("Transient analysis could not converge. Check device models and use finite rise and fall times for pulse sources.")
        }
        if text.contains("unknown parameter") || text.contains("unrecognized parameter") {
            return .message("A device model contains an unsupported parameter. Check that its model level is compatible with ngspice 47.")
        }
        return .message("SPICE could not solve this circuit. Check device models, source values and ground connections.")
    }
}
