import Foundation

/// Validation boundary between an editable engineering netlist and shared ngspice.
public enum EngineeringSimulation {
    public static func deck(_ source:String,settings:SimulationSettings,models:String="",supplies:[String:String]=[:]) throws -> String {
        guard source.utf8.count <= 2_000_000,!source.contains("\0") else { throw CircuitError.message("Simulation netlist exceeds 2 MB.") }
        let allowed:Set<String>=[".subckt",".ends",".model",".param",".func",".global",".temp"]
        var cards:[String]=[];var hasCard=false
        for raw in (source+"\n"+models).components(separatedBy:.newlines) {
            let line=raw.trimmingCharacters(in:.whitespaces)
            if line.isEmpty || line.hasPrefix("*") { continue }
            guard !line.contains(";"),!line.contains("`"),!line.contains("$&"),!line.contains("$(") else { throw CircuitError.message("The netlist contains an unsupported command expression.") }
            let head=String(line.split(whereSeparator: \.isWhitespace).first ?? "").lowercased()
            if head == ".end" { continue }
            if line.hasPrefix(".") {
                guard allowed.contains(head) else { throw CircuitError.message("Unsupported SPICE directive \(head). Import model definitions inline; control commands and external file access are disabled.") }
            } else if line.hasPrefix("+") {
                guard hasCard else { throw CircuitError.message("A continuation line has no preceding card.") }
            } else {
                guard let first=head.first,"rclkdqmviebfghxswt".contains(first),head.allSatisfy({ $0.isLetter || $0.isNumber || "_.$:@#-".contains($0) }) else { throw CircuitError.message("Unsupported SPICE card: \(head).") }
            }
            cards.append(line);hasCard=true
        }
        let subcircuits=Set(cards.compactMap { line -> String? in let fields=line.split(whereSeparator:\.isWhitespace);return fields.count>1 && fields[0].lowercased()==".subckt" ? fields[1].lowercased() : nil })
        let models=Set(cards.compactMap { line -> String? in let fields=line.split(whereSeparator:\.isWhitespace);return fields.count>1 && fields[0].lowercased()==".model" ? fields[1].lowercased() : nil })
        let modelBases=Set(models.map { $0.replacingOccurrences(of:"\\.[0-9]+$",with:"",options:.regularExpression) })
        var missing=Set<String>()
        for line in cards {
            let fields=line.split(whereSeparator:\.isWhitespace)
            guard let first=fields.first?.lowercased() else { continue }
            if first.hasPrefix("x"),let target=fields.dropFirst().prefix(while: { !$0.contains("=") && $0.lowercased() != "params:" }).last,!subcircuits.contains(target.lowercased()) { missing.insert(String(target)) }
            if first.hasPrefix("m"),fields.count>5,!models.contains(fields[5].lowercased()),!modelBases.contains(fields[5].lowercased()) { missing.insert(String(fields[5])) }
        }
        guard missing.isEmpty else { throw CircuitError.message("缺少器件模型："+missing.sorted().joined(separator:"、")+"。当前工艺只提供了元件接口，请在‘器件模型’中导入完整 .subckt / .model 实现；也可明确选择教学 MOS 模型进行近似仿真。") }
        let joined=cards.joined(separator:"\n")
        for (node,value) in supplies.sorted(by:{$0.key<$1.key}) {
            guard !node.isEmpty,node.allSatisfy({ $0.isLetter || $0.isNumber || "_!".contains($0) }) else { throw CircuitError.message("Use letters, numbers or underscores for supply names.") }
            let voltage=try EngineeringUnits.parse(value)
            guard voltage.isFinite else { throw CircuitError.message("Invalid global supply voltage.") }
            // Never add a second ideal source if the root already drives this supply.
            let alreadyDriven=cards.contains { line in let fields=line.split(whereSeparator: \.isWhitespace);return fields.count >= 3 && fields[0].lowercased().hasPrefix("v") && fields[1].caseInsensitiveCompare(node) == .orderedSame && fields[2] == "0" }
            if !alreadyDriven && joined.range(of:"(?i)(?<![a-z0-9_])"+NSRegularExpression.escapedPattern(for:node)+"(?![a-z0-9_])",options:.regularExpression) != nil { cards.append("VCS_\(node) \(node) 0 DC \(voltage)") }
        }
        return "* Circuit Studio local engineering simulation\n"+cards.joined(separator:"\n")+"\n"+(try SPICENetlist.directive(settings))+"\n.end\n"
    }
}

/// JSON boundary shared by the engineering tools and the native simulation host.
public struct EngineeringRunSource:Decodable,Identifiable,Sendable { public var id:String;public var name:String;public var netlist:String }
public struct EngineeringSimulationConfiguration:Decodable,Sendable {
    public var settings:SimulationSettings
    public var supplies:String
    public var models:String
    public var modelNotice:String? {
        if models.contains("CIRCUIT_STUDIO_TEACHING") { return "教学 MOS 等效模型 · 不代表实际工艺精度" }
        if models.contains("CIRCUIT_STUDIO_GF180MCU_") { let corner=["TT","FF","SS","FS","SF"].first{models.contains("CIRCUIT_STUDIO_GF180MCU_"+$0)} ?? "所选角";return "GlobalFoundries GF180MCU · 3.3V MOS · \(corner) · 官方 BSIM4" }
        if models.contains("CIRCUIT_STUDIO_SKY130_") { return "SkyWater SKY130 · 1.8V MOS · 官方 BSIM4（工艺角见模型包）" }
        return nil
    }
    public func supplyVoltages() throws -> [String:String] {
        var values:[String:String]=[:]
        guard supplies.utf8.count <= 16_000,models.utf8.count <= 6_000_000 else { throw CircuitError.message("Simulation settings exceed the size limit.") }
        for row in supplies.components(separatedBy:.newlines) where !row.trimmingCharacters(in:.whitespaces).isEmpty {
            let parts=row.split(separator:"=",maxSplits:1)
            guard parts.count == 2 else { throw CircuitError.message("Use NAME=VOLTAGE for each global supply.") }
            let name=parts[0].trimmingCharacters(in:.whitespaces),value=parts[1].trimmingCharacters(in:.whitespaces)
            guard !values.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { throw CircuitError.message("Each global supply name must be unique.") }
            values[name]=value
        }
        return values
    }
}
public struct EngineeringSimulationRequest:Decodable,Sendable {
    public var source:EngineeringRunSource
    public var configuration:EngineeringSimulationConfiguration
    public func run() throws -> SimulationResult {
        try EmbeddedSpice.run(netlist:source.netlist,settings:configuration.settings,models:configuration.models,supplies:configuration.supplyVoltages())
    }
}
