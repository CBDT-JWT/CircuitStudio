import Foundation

public enum EngineeringUnits {
    /// SPICE is case insensitive: M means milli; only Meg means mega.
    public static func parse(_ input: String) throws -> Double {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "μ", with: "u").replacingOccurrences(of: "µ", with: "u")
        let pattern = #"^([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*(Meg|meg|MEG|[fFpPnNuUmMkKgG]?)(?:\s*(?:Ω|Ohm|ohm|F|H|V|A|Hz|s|m))?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = normalized as NSString
        guard let match = regex.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)), let number = Double(ns.substring(with: match.range(at: 1))) else { throw CircuitError.message("“\(input)” is not a valid value. Use 10k, 2p, 180n, or 1Meg.") }
        let prefix = ns.substring(with: match.range(at: 2)).lowercased()
        let factors: [String: Double] = ["": 1.0, "f": 1e-15, "p": 1e-12, "n": 1e-9, "u": 1e-6, "m": 1e-3, "k": 1e3, "meg": 1e6, "g": 1e9]
        let factor = factors[prefix] ?? 1.0
        let result = number * factor
        guard result.isFinite else { throw CircuitError.message("The value must be finite.") }
        return result
    }
    public static func spice(_ input: String) throws -> String { String(format: "%.12g", try parse(input)) }
    public static func display(_ input: String, unit: String = "") -> String {
        guard let value = try? parse(input) else { return input }
        return format(value, unit: unit)
    }
    public static func format(_ value: Double, unit: String = "") -> String {
        if value == 0 { return "0" + (unit.isEmpty ? "" : " " + unit) }
        let prefixes = [(-15, "f"), (-12, "p"), (-9, "n"), (-6, "μ"), (-3, "m"), (0, ""), (3, "k"), (6, "M"), (9, "G")]
        let exponent = max(-15, min(9, Int(floor(log10(abs(value)) / 3)) * 3))
        let prefix = prefixes.first { $0.0 == exponent }?.1 ?? ""
        let number = String(format: "%.3g", value / pow(10, Double(exponent)))
        return number + (prefix.isEmpty && unit.isEmpty ? "" : " " + prefix + unit)
    }
}

public enum MathLabel {
    public struct Run: Sendable { public var text: String; public var subscripted: Bool }
    public static func runs(_ input: String) -> [Run] {
        var input = input
        for (command, symbol) in [("\\mu", "μ"), ("\\omega", "ω"), ("\\pi", "π"), ("\\lambda", "λ"), ("\\gamma", "γ"), ("\\Delta", "Δ")] { input = input.replacingOccurrences(of: command, with: symbol) }
        input = input.replacingOccurrences(of: "$", with: "")
        var runs: [Run] = []; var normal = ""; let chars = Array(input); var i = 0
        while i < chars.count {
            if chars[i] == "_", i + 1 < chars.count {
                if !normal.isEmpty { runs.append(Run(text: normal, subscripted: false)); normal = "" }
                i += 1; var sub = ""
                if chars[i] == "{" { i += 1; while i < chars.count && chars[i] != "}" { sub.append(chars[i]); i += 1 }; if i < chars.count { i += 1 } }
                else { while i < chars.count && (chars[i].isLetter || chars[i].isNumber) { sub.append(chars[i]); i += 1 } }
                runs.append(Run(text: sub, subscripted: true))
            } else { normal.append(chars[i]); i += 1 }
        }
        if !normal.isEmpty { runs.append(Run(text: normal, subscripted: false)) }
        return runs
    }
    public static func netName(_ label: String) -> String {
        let text = runs(label).map(\.text).joined().uppercased()
        return text.filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }
    }
}
