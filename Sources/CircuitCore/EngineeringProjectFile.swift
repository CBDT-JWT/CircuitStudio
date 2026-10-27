import Foundation

/// Read-only boundary for engineering JSON and the previous native document package.
/// Legacy input is never used as the save destination of an imported project.
public enum EngineeringProjectFile {
    public struct Contents {
        public let text: String
        public let sourceData: Data
        public let importedLegacy: Bool
    }
    public static func read(_ url: URL) throws -> Contents {
        guard url.isFileURL else { throw CircuitError.message("请选择本机或文件服务中的工程。") }
        var outcome: Result<Contents, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { selected in
            outcome = Result {
                let info = try selected.resourceValues(forKeys: [.isDirectoryKey])
                var document = selected
                if info.isDirectory == true {
                    guard ["circuit", "cdraw"].contains(selected.pathExtension.lowercased()) else {
                        throw CircuitError.message("请选择工程文件，而不是普通文件夹。")
                    }
                    document = selected.appendingPathComponent("document.json").resolvingSymlinksInPath()
                    guard document.path.hasPrefix(selected.resolvingSymlinksInPath().path + "/") else {
                        throw CircuitError.message("旧工程的 document.json 不能指向工程包外部。")
                    }
                }
                guard let size = try document.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000 else {
                    throw CircuitError.message("工程超过 20MB。")
                }
                return try prepare(Data(contentsOf: document))
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CircuitError.message("无法读取工程。") }
        return try outcome.get()
    }
    public static func prepare(_ data: Data) throws -> Contents {
        guard data.count <= 20_000_000, let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CircuitError.message("工程不是有效的 JSON，或超过 20MB。")
        }
        if raw["circuit"] != nil, raw["formatVersion"] != nil {
            let archive = try CircuitArchive.decode(data), circuit = archive.circuit
            let topology = Connectivity(circuit)
            var terminals: [String: [String: String]] = [:]
            for (ref, name) in topology.terminalNets {
                terminals[ref.componentID.uuidString, default: [:]][ref.pin] = name
            }
            var wireNets: [String: String] = [:]
            for wire in circuit.wires {
                if let point = circuit.resolvedPoints(wire).first,
                   let net = topology.nets.first(where: { $0.points.contains(point) }) { wireNets[wire.id.uuidString] = net.name }
            }
            var packet: [String: Any] = ["schema": "circuitstudio-native-import-v1", "archive": raw,
                "terminalNets": terminals, "wireNets": wireNets, "supplies": circuit.effectiveSupplyVoltages]
            // Model definitions are useful for simulation; invalid/unfinished circuits can still open.
            if let spice = try? SPICENetlist.generate(circuit, analysis: false) { packet["spice"] = spice }
            let encoded = try JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys])
            return Contents(text: String(decoding: encoded, as: UTF8.self), sourceData: data, importedLegacy: true)
        }
        guard raw["documents"] is [[String: Any]] || (raw["schema"] as? String == "circuitstudio-project-v1" && raw["cells"] is [[String: Any]]) else {
            throw CircuitError.message("这不是 Circuit Studio 工程。原文件未改动。")
        }
        return Contents(text: String(decoding: data, as: UTF8.self), sourceData: data, importedLegacy: false)
    }
}
