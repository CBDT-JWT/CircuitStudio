import Foundation

public extension ComponentKind {
    static var categories: [String] { ["Passives", "Semiconductors", "Sources", "Switches", "Amplifiers", "Logic gates", "Signal flow", "Connections"] }
    var extendedInfo: (String, String, String)? {
        switch self {
        case .largeInductor: ("Large Inductor", "Passives", "L")
        case .variableResistor: ("Variable Resistor", "Passives", "R")
        case .variableCapacitor: ("Variable Capacitor", "Passives", "C")
        case .variableInductor: ("Variable Inductor", "Passives", "L")
        case .tCoil: ("T-Coil", "Passives", "X")
        case .centerTappedCoil: ("CT Coil", "Passives", "X")
        case .transformer: ("XFMR", "Passives", "X")
        case .powerRail: ("Power Rail", "Connections", "VDD")
        case .battery: ("Battery", "Sources", "V")
        case .biasPort: ("Bias Voltage Port", "Connections", "VB")
        case .cellPin: ("Cell Pin", "Connections", "P")
        case .noConnect: ("NoConn", "Connections", "NC")
        case .vcvs: ("VCVS", "Sources", "E")
        case .vccs: ("VCCS", "Sources", "G")
        case .cccs: ("CCCS", "Sources", "F")
        case .ccvs: ("CCVS", "Sources", "H")
        case .openSwitch: ("Open Switch", "Switches", "S")
        case .closedSwitch: ("Closed Switch", "Switches", "S")
        case .controlledSwitch: ("Ctrl SW", "Switches", "S")
        case .voltageSwitch: ("Voltage-Controlled Switch", "Switches", "S")
        case .chopper: ("Chopper", "Switches", "S")
        case .simpleSwitch: ("Simple Switch", "Switches", "S")
        case .spdtSwitch: ("SPDT Switch", "Switches", "S")
        case .opAmpSmall: ("Op Amp S", "Amplifiers", "E")
        case .fdAmp: ("FD Amp", "Amplifiers", "E")
        case .fdAmpSmall: ("FD Amp S", "Amplifiers", "E")
        case .voltageAmplifier: ("Voltage Amplifier", "Amplifiers", "E")
        case .transconductance: ("Transconductance (gₘ)", "Amplifiers", "G")
        case .differentialTransconductance: ("Differential Transconductance (gₘ)", "Amplifiers", "G")
        case .comparator: ("Comparator", "Amplifiers", "B")
        case .fdComparator: ("FD Comp", "Amplifiers", "B")
        case .adc: ("Analog-to-Digital Converter", "Amplifiers", "X")
        case .dac: ("Digital-to-Analog Converter", "Amplifiers", "X")
        case .inverter: ("Inverter", "Logic gates", "B")
        case .buffer: ("Buffer", "Logic gates", "B")
        case .andGate: ("AND Gate", "Logic gates", "B")
        case .orGate: ("OR Gate", "Logic gates", "B")
        case .nandGate: ("NAND Gate", "Logic gates", "B")
        case .norGate: ("NOR Gate", "Logic gates", "B")
        case .xorGate: ("XOR Gate", "Logic gates", "B")
        case .xnorGate: ("XNOR Gate", "Logic gates", "B")
        case .dFlipFlop: ("D Flip-Flop", "Logic gates", "X")
        case .dFlipFlopReset: ("D Flip-Flop (Reset)", "Logic gates", "X")
        case .dFlipFlopQ: ("D Flip-Flop (Q)", "Logic gates", "X")
        case .delayCell: ("Delay Cell", "Logic gates", "X")
        case .adder: ("Adder", "Signal flow", "B")
        case .multiplier: ("Multiplier", "Signal flow", "B")
        case .integrator: ("Integrator (1/s)", "Signal flow", "X")
        case .unitDelay: ("Unit Delay (z⁻¹)", "Signal flow", "X")
        case .discreteIntegrator: ("Discrete-Time Integrator (z⁻¹/(1−z⁻¹))", "Signal flow", "X")
        case .quantizer: ("Quantizer", "Signal flow", "X")
        case .depletionNMOS: ("D-NMOS", "Semiconductors", "M")
        case .depletionPMOS: ("D-PMOS", "Semiconductors", "M")
        case .ndmos: ("N-channel DMOS", "Semiconductors", "M")
        case .pdmos: ("P-channel DMOS", "Semiconductors", "M")
        default: nil
        }
    }
    var extendedParameters: [String: String]? {
        switch self {
        case .largeInductor, .variableInductor: return ComponentKind.inductor.defaultParameters
        case .variableResistor: return ComponentKind.resistor.defaultParameters
        case .variableCapacitor: return ComponentKind.capacitor.defaultParameters
        case .depletionNMOS, .depletionPMOS, .ndmos, .pdmos:
            var p = (isPMOS ? ComponentKind.pmos : .nmos).defaultParameters
            if self == .depletionNMOS || self == .depletionPMOS { p["model"] = isPMOS ? "DPMOS" : "DNMOS" }
            return p
        case .battery: return ComponentKind.voltageSource.defaultParameters
        case .vcvs, .vccs: return ["gain": "1", "controlPositive":"", "controlNegative":""]
        case .cccs, .ccvs: return ["gain": "1", "control": "V1"]
        case .openSwitch, .closedSwitch, .simpleSwitch, .chopper: return ["ron": "1m", "roff": "1G"]
        case .controlledSwitch, .voltageSwitch, .spdtSwitch: return ["ron": "1m", "roff": "1G", "threshold": "0.5"]
        case .opAmpSmall, .fdAmp, .fdAmpSmall, .voltageAmplifier: return ["gain": "100k"]
        case .transconductance, .differentialTransconductance: return ["gain": "1m"]
        case .comparator, .fdComparator, .inverter, .buffer, .andGate, .orGate, .nandGate, .norGate, .xorGate, .xnorGate: return ["high": "1.8", "threshold": "0.9"]
        case .tCoil, .centerTappedCoil, .transformer: return ["L1": "10u", "L2": "10u", "k": "0.9", "C": "1p"]
        case .adc, .dac: return ["bits": "8", "reference": "1.8"]
        case .delayCell, .unitDelay, .discreteIntegrator: return ["period": "1u"]
        case .quantizer: return ["step": "0.1"]
        default: return nil
        }
    }
    var extendedPins: [Pin]? {
        switch self {
        case .noConnect: return []
        case .powerRail, .biasPort, .cellPin: return [Pin("1", .zero)]
        case .vcvs, .vccs, .voltageSwitch: return [Pin("1", Point(0,-40)), Pin("2", Point(0,40)), Pin("CP", Point(-40,-20)), Pin("CN", Point(-40,20))]
        case .controlledSwitch: return [Pin("1",Point(0,-40)), Pin("2",Point(0,40)), Pin("CTRL",Point(-40,0))]
        case .spdtSwitch: return [Pin("1",Point(-40,0)), Pin("2",Point(40,-20)), Pin("3",Point(40,20)), Pin("CTRL",Point(0,-40))]
        case .tCoil, .centerTappedCoil: return [Pin("1",Point(0,-40)), Pin("2",Point(0,40)), Pin("CT",Point(40,0))]
        case .transformer: return [Pin("1",Point(-30,-40)), Pin("2",Point(-30,40)), Pin("3",Point(30,-40)), Pin("4",Point(30,40))]
        case .opAmpSmall, .comparator, .differentialTransconductance: return [Pin("+",Point(-40,10)), Pin("-",Point(-40,-10)), Pin("OUT",Point(40,0))]
        case .fdAmp, .fdAmpSmall, .fdComparator:
            let d = self == .fdAmp ? 20.0 : 10.0
            return [Pin("+",Point(-40,d)), Pin("-",Point(-40,-d)), Pin("OUT+",Point(40,-d)), Pin("OUT-",Point(40,d))]
        case .voltageAmplifier, .transconductance, .adc, .dac, .inverter, .buffer, .delayCell, .integrator, .unitDelay, .discreteIntegrator, .quantizer: return [Pin("IN",Point(-40,0)), Pin("OUT",Point(40,0))]
        case .andGate, .orGate, .nandGate, .norGate, .xorGate, .xnorGate, .adder, .multiplier: return [Pin("A",Point(-40,-20)), Pin("B",Point(-40,20)), Pin("OUT",Point(40,0))]
        case .dFlipFlop, .dFlipFlopReset, .dFlipFlopQ:
            var pins = [Pin("D",Point(-40,-20)), Pin("CLK",Point(-40,20)), Pin("Q",Point(40,-20))]
            if self != .dFlipFlopQ { pins.append(Pin("QB",Point(40,20))) }
            if self == .dFlipFlopReset { pins.append(Pin("RESET",Point(0,40))) }
            return pins
        default: return nil
        }
    }
    var symbolText: String? {
        switch self {
        case .voltageAmplifier: "A"; case .transconductance, .differentialTransconductance: "g_{m}"
        case .adc: "ADC"; case .dac: "DAC"; case .delayCell: "τ"; case .integrator: "1/s"
        case .unitDelay: "z⁻¹"; case .discreteIntegrator: "z⁻¹/(1−z⁻¹)"; case .quantizer: "Q"
        case .adder: "+"; case .multiplier: "×"; default: nil
        }
    }
    /// Stateful/discrete blocks are drawing symbols until a simulation model is supplied.
    var needsSimulationModel: Bool { [.adc,.dac,.delayCell,.dFlipFlop,.dFlipFlopReset,.dFlipFlopQ,.integrator,.unitDelay,.discreteIntegrator,.quantizer].contains(self) }
}
