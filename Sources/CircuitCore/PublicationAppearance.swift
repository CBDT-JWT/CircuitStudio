import Foundation

/// Presentation only. Electrical parameters and terminal coordinates are never restyled.
public struct ObjectAppearance: Codable, Hashable, Sendable {
    public var color: String?
    public var textColor: String?
    public var lineScale: Double?
    public var fontScale: Double?
    public init(color: String? = nil, textColor: String? = nil, lineScale: Double? = nil, fontScale: Double? = nil) {
        self.color=color;self.textColor=textColor;self.lineScale=lineScale;self.fontScale=fontScale
    }
}
public struct PublicationAppearance: Codable, Hashable, Sendable {
    public var ink: String? = nil
    public var labelColor: String? = nil
    public var background: String? = nil
    public var lineScale = 1.0
    public var fontScale = 1.0
    public var padding = 30.0
    /// Physical width of a saved figure. nil keeps its natural 72-point dimensions.
    public var widthMM: Double? = nil
    public init() {}
}
public enum PublicationPreset: String, CaseIterable, Identifiable {
    case monochrome = "Paper · monochrome", color = "Paper · color", slide = "Presentation · color"
    public var id: String { rawValue }
    public var appearance: PublicationAppearance {
        var style=PublicationAppearance();style.background="ffffff";style.ink="171717";style.labelColor="171717"
        if self == .slide { style.fontScale=1.35;style.lineScale=1.15;style.padding=40 }
        else { style.fontScale=1.15;style.padding=20 }
        return style
    }
}
public extension Circuit {
    var figurePointScale: Double { guard let mm=appearance?.widthMM else { return 1 }; return mm * 72 / 25.4 / max(1,bounds.width) }
    var figureWidthMM: Double { bounds.width * figurePointScale * 25.4 / 72 }
    var smallestPrintedFont: Double? {
        let scene=Symbols.scene(self)
        return (scene.texts+scene.layers.flatMap(\.texts)).map(\.size).min().map { $0 * figurePointScale }
    }
    mutating func applyPublicationPreset(_ preset: PublicationPreset) {
        appearance=preset.appearance;mode = preset == .slide ? .presentation : .publication
        if preset == .monochrome {
            for i in components.indices { components[i].appearance?.color=nil;components[i].appearance?.textColor=nil }
            for i in wires.indices { wires[i].appearance?.color=nil;wires[i].appearance?.textColor=nil }
            for i in labels.indices { labels[i].appearance?.color=nil;labels[i].appearance?.textColor=nil }
            for i in figures.indices { figures[i].style.color=nil;figures[i].style.textColor=nil;figures[i].style.fill=nil }
            for i in figureConnectors.indices { figureConnectors[i].style.color=nil;figureConnectors[i].style.textColor=nil }
        }
    }
    func validateAppearance() throws {
        func validColor(_ value:String?) -> Bool { value == nil || (value!.count == 6 && UInt32(value!,radix:16) != nil) }
        func object(_ style:ObjectAppearance?) -> Bool {
            guard let style else { return true }
            return validColor(style.color) && validColor(style.textColor) && [style.lineScale,style.fontScale].allSatisfy { $0 == nil || ($0!.isFinite && (0.25...4).contains($0!)) }
        }
        guard components.allSatisfy({ object($0.appearance) }),wires.allSatisfy({ object($0.appearance) }),labels.allSatisfy({ object($0.appearance) }) else { throw CircuitError.message("Invalid object appearance.") }
        if let a=appearance {
            guard validColor(a.ink),validColor(a.labelColor),validColor(a.background),a.lineScale.isFinite,(0.25...4).contains(a.lineScale),a.fontScale.isFinite,(0.25...4).contains(a.fontScale),a.padding.isFinite,(0...500).contains(a.padding),a.widthMM == nil || (a.widthMM!.isFinite && (10...1000).contains(a.widthMM!)) else { throw CircuitError.message("Invalid document appearance.") }
        }
    }
}
