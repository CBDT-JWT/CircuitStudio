import Foundation

/// Supplies actual circuit connectivity to a language model rather than asking it
/// to infer wiring from a screenshot. No generated answer is persisted here.
public enum CircuitAssistantContext {
    public static func make(_ circuit: Circuit) throws -> String {
        guard circuit.purpose.supportsSimulation else { throw CircuitError.message("Switch to Schematic to explain an electrical circuit.") }
        guard !circuit.components.isEmpty else { throw CircuitError.message("Add a circuit before asking for an explanation.") }
        guard circuit.components.count <= 200 else { throw CircuitError.message("The circuit assistant currently supports up to 200 components. Use a smaller circuit.") }
        let topology = Connectivity(circuit)
        let components: [[String: Any]] = circuit.components.map { component in
            ["reference": component.name, "kind": component.kind.rawValue, "parameters": component.parameters,
             "pins": Dictionary(uniqueKeysWithValues: component.pins.map { ($0.name, topology.net(component.id, $0.name)) })]
        }
        let warnings: [String]
        do { try SPICENetlist.validate(circuit); warnings = [] }
        catch { warnings = [error.localizedDescription] }
        let payload: [String: Any] = ["schema": "circuitstudio-assistant-v1", "title": circuit.title,
            "components": components, "validationWarnings": warnings, "globalSupplyVoltages": circuit.effectiveSupplyVoltages,
            "simulationPerformed": false,
            "notes": "Parameter values use SPICE units: m is milli, Meg is mega. Device models and calculated operating points are not supplied. Do not infer them."]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= 60_000, let text = String(data: data, encoding: .utf8) else { throw CircuitError.message("The circuit context is too large for the circuit assistant. Shorten labels and parameters or use a smaller circuit.") }
        return text
    }
}

public struct CircuitChatTurn:Codable,Sendable {
    public enum Role:String,Codable,Sendable { case user,assistant }
    public var role:Role
    public var content:String
    public init(role:Role,content:String) { self.role=role;self.content=content }
}
public enum CircuitChatContext {
    /// The existing relay accepts one JSON context. Keep the conversation bounded
    /// inside that envelope without changing credentials or the server contract.
    public static func appendingConversation(to context:String,turns:[CircuitChatTurn]) throws -> String {
        guard let bytes=context.data(using:.utf8),bytes.count <= 60_000,
              var object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],object["schema"] as? String == "circuitstudio-assistant-v1" else { throw CircuitError.message("Invalid circuit context.") }
        var history:[[String:String]]=[]
        for turn in turns.suffix(8).reversed() {
            let candidate=[["role":turn.role.rawValue,"content":turn.content]]+history
            object["conversation"]=candidate
            guard try JSONSerialization.data(withJSONObject:object).count <= 60_000 else { break }
            history=candidate
        }
        object["conversation"]=history
        let data=try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)
        guard data.count <= 60_000 else { throw CircuitError.message("The circuit context is too large for the circuit assistant.") }
        return String(decoding:data,as:UTF8.self)
    }
}
