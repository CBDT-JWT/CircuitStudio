import Foundation

public extension Circuit {
    var effectiveSupplyVoltages: [String:String] { supplyVoltages ?? ["VDD":"1.8","VSS":"0"] }
    func automaticSupplies(topology: Connectivity) throws -> [(name:String,value:String)] {
        var result: [(String,String)] = []
        let voltageSources = components.filter { [.voltageSource,.acVoltage,.pulseSource,.battery].contains($0.kind) }
        for (name,value) in effectiveSupplyVoltages.sorted(by:{ $0.key<$1.key }) {
            let net = MathLabel.netName(name)
            guard net.range(of:#"^[A-Za-z][A-Za-z0-9_]*$"#,options:.regularExpression) != nil else { throw CircuitError.message("Invalid global supply name: \(name)") }
            guard topology.nets.contains(where: { $0.name == net }) else { continue }
            let driven = voltageSources.contains { source in
                let a=topology.net(source.id,"1"),b=topology.net(source.id,"2")
                return (a==net && b=="0") || (a=="0" && b==net)
            }
            if !driven { result.append((net,try EngineeringUnits.spice(value))) }
        }
        return result
    }
}
