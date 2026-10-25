import Foundation

public struct CircuitAIPlotOptions:Codable,Sendable,Equatable {
    public enum Mode:String,Codable,Sendable { case auto,real,magnitude,phase,spectrum }
    public enum Theme:String,Codable,Sendable {case publication,virtuoso}
    public var theme:Theme?
    public enum XScale:String,Codable,Sendable { case auto,linear,log }
    public var title:String?
    public var xLabel:String?
    public var yLabel:String?
    public var phaseLabel:String?
    public var legend:[String:String]?
    public var showLegend:Bool?
    public var mode:Mode?
    public var xScale:XScale?
    public var traces:[String]?
    public var lineWidth:Double?
    public var grid:Bool?
    public init() {}
    public func validate() throws {
        guard [title,xLabel,yLabel,phaseLabel].compactMap({$0}).allSatisfy({$0.count<=120}),
              (legend?.count ?? 0)<=12,legend?.allSatisfy({$0.key.count<=120 && $0.value.count<=100}) ?? true,
              (traces?.count ?? 0)<=12,traces?.allSatisfy({!$0.isEmpty && $0.count<=120}) ?? true,
              lineWidth.map({$0.isFinite && (0.5...6).contains($0)}) ?? true else { throw CircuitError.message("图表设置无效：标题与坐标轴最多 120 字，最多 12 条曲线，线宽为 0.5–6。") }
    }
}
