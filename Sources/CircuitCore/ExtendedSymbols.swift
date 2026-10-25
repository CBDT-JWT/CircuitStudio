import Foundation

public enum ExtendedSymbols {
    /// Local vector artwork; the shared renderer applies instance placement once.
    public static func geometry(_ component: Component, theme: SymbolTheme) -> [Primitive] {
        let kind = component.kind
        var r: [Primitive] = []
        func line(_ ps: Point...) { r.append(.line(ps)) }
        func circle(_ p: Point, _ radius: Double, _ filled: Bool = false) { r.append(.circle(p,radius,filled:filled)) }
        func polygon(_ ps: [Point]) { r.append(.polygon(ps,filled:false)) }
        func base(_ kind: ComponentKind) {
            var c = Component(kind: kind, name: "", position: .zero); c.parameters = component.parameters; c.referenceArtwork = component.referenceArtwork
            r += Symbols.geometry(c,theme:theme)
        }
        func arrow(_ a: Point, _ b: Point) {
            line(a,b); let d = atan2(b.y-a.y,b.x-a.x)
            r.append(.polygon([b,b-Point(cos(d-0.45),sin(d-0.45))*7,b-Point(cos(d+0.45),sin(d+0.45))*7],filled:true))
        }
        switch kind {
        case .largeInductor, .variableInductor, .variableResistor, .variableCapacitor:
            base(kind == .variableResistor ? .resistor : kind == .variableCapacitor ? .capacitor : .inductor)
            if kind == .largeInductor { line(Point(16,-24),Point(16,24)); line(Point(20,-24),Point(20,24)) }
            else { arrow(Point(-23,25),Point(23,-25)) }
        case .depletionNMOS, .depletionPMOS, .ndmos, .pdmos:
            base(kind.isPMOS ? .pmos : .nmos)
            if kind == .depletionNMOS || kind == .depletionPMOS { line(Point(1,-18),Point(1,18)) }
            else { line(Point(19,-8),Point(30,0),Point(19,8),Point(19,-8)); line(Point(30,-8),Point(30,8)) }
        case .powerRail: line(.zero,Point(0,-20)); line(Point(-35,-20),Point(35,-20))
        case .biasPort: line(.zero,Point(0,-15)); r.append(.polygon([Point(-8,-15),Point(0,-27),Point(8,-15)],filled:true))
        case .cellPin: line(.zero,Point(20,0)); circle(Point(25,0),5)
        case .noConnect: line(Point(-7,-7),Point(7,7)); line(Point(-7,7),Point(7,-7))
        case .battery:
            line(Point(0,-40),Point(0,-13)); line(Point(0,13),Point(0,40))
            for y in [-12.0, 8.0] { line(Point(-18,y),Point(18,y)); line(Point(-9,y+5),Point(9,y+5)) }
        case .vcvs, .vccs, .cccs, .ccvs:
            polygon([Point(0,-23),Point(19,0),Point(0,23),Point(-19,0)])
            line(Point(0,-40),Point(0,-23)); line(Point(0,23),Point(0,40))
            if kind == .vccs || kind == .cccs { arrow(Point(0,10),Point(0,-10)) }
            else { line(Point(-5,-8),Point(5,-8)); line(Point(0,-13),Point(0,-3)); line(Point(-5,9),Point(5,9)) }
            if kind == .vcvs || kind == .vccs { line(Point(-40,-20),Point(-27,-20)); line(Point(-40,20),Point(-27,20)); line(Point(-33,-24),Point(-33,-16)) }
        case .openSwitch, .closedSwitch, .controlledSwitch, .voltageSwitch, .chopper, .simpleSwitch:
            line(Point(0,-40),Point(0,-18)); line(Point(0,18),Point(0,40)); circle(Point(0,-15),3); circle(Point(0,15),3)
            line(Point(0,13),Point(kind == .closedSwitch ? 0 : 18,-13))
            if kind == .controlledSwitch { line(Point(-40,0),Point(-10,0)) }
            if kind == .voltageSwitch { line(Point(-40,-20),Point(-25,-20)); line(Point(-40,20),Point(-25,20)); line(Point(-33,-24),Point(-33,-16)) }
            if kind == .chopper { arrow(Point(24,15),Point(24,-15)) }
        case .spdtSwitch:
            line(Point(-40,0),Point(-15,0),Point(20,-20)); line(Point(24,-20),Point(40,-20)); line(Point(24,20),Point(40,20)); circle(Point(22,-20),3); circle(Point(22,20),3); line(Point(0,-40),Point(0,-20))
        case .tCoil, .centerTappedCoil:
            base(.inductor); line(Point(0,0),Point(40,0))
            if kind == .tCoil { line(Point(0,-40),Point(-28,-40),Point(-28,-5)); line(Point(-38,-5),Point(-18,-5)); line(Point(-38,5),Point(-18,5)); line(Point(-28,5),Point(-28,40),Point(0,40)) }
        case .transformer:
            for x in [-30.0,30.0] {
                line(Point(x,-40),Point(x,-24)); line(Point(x,24),Point(x,40))
                for i in 0..<4 { let cy = -18.0 + Double(i)*12; r.append(.line((0...16).map { j in let t = Double(j)/16 * .pi; return Point(x+(x<0 ? 10 : -10)*sin(t),cy-6*cos(t)) })) }
            }; line(Point(-5,-26),Point(-5,26)); line(Point(5,-26),Point(5,26)); circle(Point(-33,-22),2,true); circle(Point(33,-22),2,true)
        case .opAmpSmall, .fdAmp, .fdAmpSmall, .voltageAmplifier, .transconductance, .differentialTransconductance, .comparator, .fdComparator:
            polygon([Point(-24,-30),Point(-24,30),Point(28,0)])
            for pin in component.pins { let x = pin.offset.x; let y = pin.offset.y; line(pin.offset,Point(x<0 ? -24 : 28,y)); if pin.name == "+" || pin.name == "-" { line(Point(-18,y),Point(-10,y)); if pin.name == "+" { line(Point(-14,y-4),Point(-14,y+4)) } } }
            if kind == .comparator || kind == .fdComparator { line(Point(-4,6),Point(-4,-4),Point(8,-4)) }
        case .inverter, .buffer:
            polygon([Point(-22,-24),Point(-22,24),Point(23,0)]); line(Point(-40,0),Point(-22,0)); if kind == .inverter { circle(Point(27,0),4) }; line(Point(kind == .inverter ? 31 : 23,0),Point(40,0))
        case .andGate, .nandGate, .orGate, .norGate, .xorGate, .xnorGate:
            let inverted = [.nandGate,.norGate,.xnorGate].contains(kind)
            let conjunction = kind == .andGate || kind == .nandGate
            if conjunction {
                let arc = (0...32).map { i in let a = -Double.pi/2 + Double(i)/32 * .pi; return Point(24*cos(a),26*sin(a)) }
                polygon([Point(-23,-26)] + arc + [Point(-23,26)])
            } else {
                let upper = (0...24).map { i in let t = Double(i)/24; return Point(-24+48*t,-26*(1-t*t)) }
                let lower = upper.reversed().map { Point($0.x,-$0.y) }
                let back = (0...24).map { i in let y = 26-52*Double(i)/24; return Point(-24+10*(1-y*y/676),y) }
                polygon(upper+lower+back)
                if kind == .xorGate || kind == .xnorGate { r.append(.line(back.map { $0-Point(6,0) })) }
            }
            for pin in component.pins where pin.name != "OUT" { line(pin.offset,Point(-23,pin.offset.y)) }; if inverted { circle(Point(28,0),4) }; line(Point(inverted ? 32 : 24,0),Point(40,0))
        case .adder, .multiplier:
            circle(.zero,24); for pin in component.pins { line(pin.offset,Point(pin.offset.x<0 ? -13 : 24,pin.offset.y)) }
        default:
            polygon([Point(-25,-30),Point(25,-30),Point(25,30),Point(-25,30)])
            for pin in component.pins { let p=pin.offset; line(p,Point(p.x == 0 ? 0 : p.x<0 ? -25 : 25,p.y == 40 ? 30 : p.y)) }
            if [.dFlipFlop,.dFlipFlopQ,.dFlipFlopReset].contains(kind) { line(Point(-25,14),Point(-17,20),Point(-25,26)) }
        }
        return r
    }
}
