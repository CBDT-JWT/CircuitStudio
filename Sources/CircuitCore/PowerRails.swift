import Foundation

public enum PowerRailGeometry {
    public static func endpoint(from start:Point,toward pointer:Point)->Point {
        abs(pointer.x-start.x) >= abs(pointer.y-start.y) ? Point(pointer.x,start.y) : Point(start.x,pointer.y)
    }
}
public extension Circuit {
    func railPoint(_ terminal:TerminalRef)->Point? {
        guard terminal.pin.hasPrefix("rail:"),let t=Double(terminal.pin.dropFirst(5)),let rail=wires.first(where:{ $0.id == terminal.componentID && $0.powerNet != nil }),let a=rail.points.first,let b=rail.points.last else { return nil }
        return a+(b-a)*t
    }
    func powerRailLabel(_ wire:Wire)->DrawingText? {
        guard let name=wire.powerNet,let a=wire.points.first,let b=wire.points.last else { return nil }
        let width=Symbols.textBounds(DrawingText(text:Symbols.referenceLabel(name),point:.zero,size:16,reference:true)).width
        return DrawingText(text:Symbols.referenceLabel(name),point:(a+b)*0.5+Point(-width/2,-28)+(wire.labelOffset ?? .zero),size:16,reference:true)
    }
    /// A rail bonds visible pin tips explicitly, through attached ordinary tap leads.
    @discardableResult mutating func addPowerRail(from start:Point,to pointer:Point,name:String="VDD")->UUID? {
        let end=PowerRailGeometry.endpoint(from:start,toward:pointer)
        guard start.distance(to:end)>0.001 else { return nil }
        var rail=Wire(points:[start,end]);rail.powerNet=MathLabel.netName(name)
        wires.append(rail)
        var supplies=effectiveSupplyVoltages;if supplies[rail.powerNet!] == nil { supplies[rail.powerNet!]="1.8" };supplyVoltages=supplies
        let delta=end-start,denominator=delta.x*delta.x+delta.y*delta.y
        for component in components { for pin in component.pins {
            let p=component.world(pin.offset)
            guard distanceToSegment(p,start,end)<0.001 else { continue }
            let t=((p.x-start.x)*delta.x+(p.y-start.y)*delta.y)/denominator
            wires.append(Wire(points:[p,p],start:TerminalRef(component.id,pin.name),end:TerminalRef(rail.id,"rail:\(t)")))
        } }
        return rail.id
    }
    mutating func reconcileRailContacts(_ id:UUID,previous:Circuit) {
        guard let rail=wires.first(where:{ $0.id == id }),let a=rail.points.first,let b=rail.points.last else { return }
        let delta=b-a,denominator=delta.x*delta.x+delta.y*delta.y
        guard denominator>0.001 else { return }
        for i in wires.indices where wires[i].id != id {
            for first in [true,false] {
                guard let ref=first ? wires[i].start : wires[i].end,ref.componentID == id,let p=previous.position(of:ref) else { continue }
                let updated:TerminalRef? = distanceToSegment(p,a,b)<0.001 ? TerminalRef(id,"rail:\(((p.x-a.x)*delta.x+(p.y-a.y)*delta.y)/denominator)") : nil
                if first { wires[i].start=updated;wires[i].points[0]=p } else { wires[i].end=updated;wires[i].points[wires[i].points.count-1]=p }
            }
        }
        bondRailPins(id)
    }
    mutating func bondRailPins(_ id:UUID) {
        guard let rail=wires.first(where:{ $0.id == id && $0.powerNet != nil }),let a=rail.points.first,let b=rail.points.last else { return }
        let delta=b-a,denominator=delta.x*delta.x+delta.y*delta.y;guard denominator>0.001 else { return }
        for component in components { for pin in component.pins {
            let p=component.world(pin.offset),ref=TerminalRef(component.id,pin.name)
            guard distanceToSegment(p,a,b)<0.001,!wires.contains(where:{ ($0.start == ref && $0.end?.componentID == id) || ($0.end == ref && $0.start?.componentID == id) }) else { continue }
            let t=((p.x-a.x)*delta.x+(p.y-a.y)*delta.y)/denominator
            wires.append(Wire(points:[p,p],start:ref,end:TerminalRef(id,"rail:\(t)")))
        } }
    }
    mutating func updateAttachedNoConnects() {
        let positions=Dictionary(uniqueKeysWithValues:components.flatMap { c in c.pins.map { (TerminalRef(c.id,$0.name),c.world($0.offset)) } })
        for i in components.indices where components[i].kind == .noConnect {
            guard let raw=components[i].parameters["attachedComponent"],let id=UUID(uuidString:raw),let pin=components[i].parameters["attachedPin"],let p=positions[TerminalRef(id,pin)] else { continue }
            components[i].position=p
        }
    }
}
