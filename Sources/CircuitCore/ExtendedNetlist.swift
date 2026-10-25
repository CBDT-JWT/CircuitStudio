import Foundation

extension SPICENetlist {
    static func extendedLines(_ c: Component, topology: Connectivity) throws -> [String] {
        func n(_ pin: String) -> String { topology.net(c.id,pin) }
        func v(_ key: String, _ fallback: String = "0") throws -> String { try EngineeringUnits.spice(c.parameters[key] ?? fallback) }
        if c.kind.needsSimulationModel || (c.referenceArtwork == true && [.chopper,.spdtSwitch].contains(c.kind)) { throw CircuitError.message("\(c.name) (\(c.kind.title)) is available for drawing. Its stateful simulation model is not implemented yet.") }
        switch c.kind {
        case .vcvs,.vccs:
            var cp=n("CP"),cn=n("CN")
            if c.referenceArtwork == true {
                guard let positive=c.parameters["controlPositive"],let negative=c.parameters["controlNegative"],!positive.isEmpty,!negative.isEmpty else { throw CircuitError.message("\(c.name): choose the positive and negative control nets in Properties.") }
                cp=MathLabel.netName(positive);cn=MathLabel.netName(negative)
                guard [cp,cn].allSatisfy({ $0 == "0" || topology.nets.map(\.name).contains($0) }) else { throw CircuitError.message("\(c.name): a selected control net does not exist.") }
            }
            return ["\(c.name) \(n("1")) \(n("2")) \(cp) \(cn) \(try v("gain","1"))"]
        case .cccs,.ccvs:
            let control = try modelName(c.parameters["control"] ?? "V1")
            guard control.uppercased().hasPrefix("V") else { throw CircuitError.message("\(c.name): control must name a voltage source.") }
            return ["\(c.name) \(n("1")) \(n("2")) \(control) \(try v("gain","1"))"]
        case .openSwitch,.closedSwitch,.simpleSwitch,.chopper:
            return ["R_\(c.name) \(n("1")) \(n("2")) \(try v(c.kind == .closedSwitch ? "ron" : "roff",c.kind == .closedSwitch ? "1m" : "1G"))"]
        case .controlledSwitch,.voltageSwitch,.spdtSwitch:
            let cp = n(c.kind == .voltageSwitch ? "CP" : "CTRL"), cn = c.kind == .voltageSwitch ? n("CN") : "0"
            let model = "SW_\(c.name)"
            var lines = [".model \(model) SW(Ron=\(try v("ron","1m")) Roff=\(try v("roff","1G")) Vt=\(try v("threshold","0.5")) Vh=0)","\(c.name) \(n("1")) \(n("2")) \(cp) \(cn) \(model)"]
            if c.kind == .spdtSwitch { lines += ["B_\(c.name) NC_\(c.name) 0 V=2*\(try v("threshold","0.5"))-v(\(cp))", "\(c.name)_B \(n("1")) \(n("3")) NC_\(c.name) 0 \(model)"] }
            return lines
        case .opAmpSmall: return ["\(c.name) \(n("OUT")) 0 \(n("+")) \(n("-")) \(try v("gain","100k"))"]
        case .fdAmp,.fdAmpSmall: return ["\(c.name) \(n("OUT+")) \(n("OUT-")) \(n("+")) \(n("-")) \(try v("gain","100k"))"]
        case .voltageAmplifier,.transconductance: return ["\(c.name) \(n("OUT")) 0 \(n("IN")) 0 \(try v("gain","1"))"]
        case .differentialTransconductance: return ["\(c.name) \(n("OUT")) 0 \(n("+")) \(n("-")) \(try v("gain","1m"))"]
        case .comparator: return ["\(c.name) \(n("OUT")) 0 V=v(\(n("+")))>v(\(n("-"))) ? \(try v("high","1.8")) : 0"]
        case .fdComparator: return ["\(c.name) \(n("OUT+")) 0 V=v(\(n("+")))>v(\(n("-"))) ? \(try v("high","1.8")) : 0", "\(c.name)_N \(n("OUT-")) 0 V=v(\(n("+")))>v(\(n("-"))) ? 0 : \(try v("high","1.8"))"]
        case .inverter,.buffer,.andGate,.orGate,.nandGate,.norGate,.xorGate,.xnorGate:
            let threshold = try v("threshold","0.9"), high = try v("high","1.8")
            let inputs=c.pins.filter { ["A","B","C","D"].contains($0.name) }.map { "(v(\(n($0.name)))>\(threshold))" }
            let and=inputs.joined(separator:" && "),or=inputs.joined(separator:" || ")
            let xor=inputs.dropFirst().reduce(inputs.first ?? "0") { "("+$0+" != "+$1+")" }
            let expression: String
            switch c.kind {
            case .inverter: expression = "(v(\(n("IN")))<\(threshold))"
            case .buffer: expression = "(v(\(n("IN")))>\(threshold))"
            case .andGate,.nandGate: expression = "(\(and))"
            case .orGate,.norGate: expression = "(\(or))"
            default: expression = xor
            }
            let inverted = [.nandGate,.norGate,.xnorGate].contains(c.kind)
            return ["\(c.name) \(n("OUT")) 0 V=\(expression) ? \(inverted ? "0" : high) : \(inverted ? high : "0")"]
        case .adder,.multiplier: return ["\(c.name) \(n("OUT")) 0 V=v(\(n("A")))\(c.kind == .adder ? "+" : "*")v(\(n("B")))"]
        case .transformer,.centerTappedCoil,.tCoil:
            let k = try EngineeringUnits.parse(c.parameters["k"] ?? "0.9")
            guard (0...1).contains(k), try EngineeringUnits.parse(c.parameters["L1"] ?? "0") > 0, try EngineeringUnits.parse(c.parameters["L2"] ?? "0") > 0 else { throw CircuitError.message("\(c.name): L1/L2 must be positive and coupling k between 0 and 1.") }
            var lines = ["L_\(c.name)_1 \(n("1")) \(n(c.kind == .transformer ? "2" : "CT")) \(try v("L1"))", "L_\(c.name)_2 \(n(c.kind == .transformer ? "3" : "CT")) \(n(c.kind == .transformer ? "4" : "2")) \(try v("L2"))", "K_\(c.name) L_\(c.name)_1 L_\(c.name)_2 \(k)"]
            if c.kind == .tCoil { lines.append("C_\(c.name) \(n("1")) \(n("2")) \(try v("C","1p"))") }
            return lines
        default:
            if c.kind.isConnection { return [] }
            throw CircuitError.message("\(c.name): simulation for \(c.kind.title) is not available.")
        }
    }
}
