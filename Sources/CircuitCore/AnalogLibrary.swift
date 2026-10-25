import Foundation

/// Inventory checked against the hosted Analog Canvas library on 2026-10-24.
/// Symbols are independently constructed from native vector primitives.
public enum AnalogLibrary {
    public enum Item: Sendable {
        case component(ComponentKind), figure(FigureKind), arrow, line, polyline
    }
    public struct Entry: Identifiable, Sendable {
        public var title: String; public var category: String; public var item: Item
        public var id: String { title }
    }
    public static let categories = ["Transistors", "Passives", "Power and ports", "Sources", "Switches", "Analog blocks", "Logic gates", "Signal flow", "Annotations", "Extended devices"]
    public static let entries: [Entry] = {
        var entries: [Entry] = []
        func add(_ category: String, _ kinds: [ComponentKind]) { entries += kinds.map { Entry(title:$0.title,category:category,item:.component($0)) } }
        add("Transistors",[.nmos,.pmos,.npn,.pnp])
        add("Passives",[.resistor,.capacitor,.inductor,.largeInductor])
        add("Power and ports",[.vdd,.powerRail,.ground,.noConnect,.battery,.biasPort,.cellPin])
        add("Sources",[.voltageSource,.currentSource,.vcvs,.vccs,.cccs,.ccvs])
        add("Switches",[.openSwitch,.closedSwitch,.controlledSwitch,.voltageSwitch,.chopper,.simpleSwitch,.spdtSwitch])
        add("Analog blocks",[.opAmp,.opAmpSmall,.fdAmp,.fdAmpSmall,.voltageAmplifier,.transconductance,.differentialTransconductance,.comparator,.fdComparator,.adc,.dac])
        add("Logic gates",[.inverter,.buffer,.andGate,.orGate,.nandGate,.norGate,.xorGate,.xnorGate,.dFlipFlop,.dFlipFlopReset,.dFlipFlopQ,.delayCell])
        add("Signal flow",[.adder,.multiplier,.integrator,.unitDelay,.discreteIntegrator,.quantizer])
        entries += [Entry(title:"Arrow",category:"Annotations",item:.arrow),Entry(title:"Line",category:"Annotations",item:.line),Entry(title:"Polyline",category:"Annotations",item:.polyline)]
        entries += [("Rectangle",FigureKind.rectangle),("Circle",.ellipse),("Polarity (+ / text / −)",.polarity),("Plus sign",.plus),("Minus sign",.minus),("Three dots",.dots)].map { Entry(title:$0.0,category:"Annotations",item:.figure($0.1)) }
        add("Extended devices",[.variableResistor,.variableCapacitor,.variableInductor,.diode,.zener,.tCoil,.centerTappedCoil,.transformer,.depletionNMOS,.depletionPMOS,.ndmos,.pdmos])
        return entries
    }()
}
