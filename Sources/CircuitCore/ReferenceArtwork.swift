import Foundation
import CoreGraphics

/// Generic native path primitive retained for document rendering compatibility.
public struct ReferenceStroke: Sendable {
    public enum Command: Sendable { case move(Point), line(Point), curve(Point,Point,Point), close }
    public var commands: [Command] = []
    public var circle: (Point,Double)?
    public var filled = false
    public var stroked = true
    public var width = 1.6
    public var cap = "butt"
    public var join = "miter"
    public var miterLimit = 12.0
    public var path: CGPath {
        let path=CGMutablePath()
        if let (p,r)=circle { path.addEllipse(in:CGRect(x:p.x-r,y:p.y-r,width:2*r,height:2*r)) }
        for command in commands { switch command {
        case .move(let p):path.move(to:CGPoint(x:p.x,y:p.y))
        case .line(let p):path.addLine(to:CGPoint(x:p.x,y:p.y))
        case .curve(let a,let b,let p):path.addCurve(to:CGPoint(x:p.x,y:p.y),control1:CGPoint(x:a.x,y:a.y),control2:CGPoint(x:b.x,y:b.y))
        case .close:path.closeSubpath()
        } }
        return path
    }
    public var bounds: Bounds { let b=path.boundingBoxOfPath;return Bounds([Point(b.minX-width/2,b.minY-width/2),Point(b.maxX+width/2,b.maxY+width/2)]) }
    public func transformed(_ transform: (Point)->Point, scale: Double = 1) -> Self {
        var result=self
        result.commands=commands.map { switch $0 { case .move(let p):.move(transform(p));case .line(let p):.line(transform(p));case .curve(let a,let b,let p):.curve(transform(a),transform(b),transform(p));case .close:.close } }
        if let (p,r)=circle { result.circle=(transform(p),r*scale) };result.width *= scale
        return result
    }
    public func draw(in context: CGContext) {
        context.saveGState();context.setLineWidth(width);context.setLineCap(cap == "round" ? .round : cap == "square" ? .square : .butt);context.setLineJoin(join == "round" ? .round : join == "bevel" ? .bevel : .miter);context.setMiterLimit(miterLimit)
        context.addPath(path)
        if filled && stroked { context.drawPath(using:.fillStroke) } else if filled { context.fillPath() } else if stroked { context.strokePath() }
        context.restoreGState()
    }
    public func svg(color: String) -> String {
        func p(_ p:Point)->String { "\(p.x) \(p.y)" }
        let style="fill=\"\(filled ? "#"+color : "none")\" stroke=\"\(stroked ? "#"+color : "none")\" stroke-width=\"\(width)\" stroke-linecap=\"\(cap)\" stroke-linejoin=\"\(join)\" stroke-miterlimit=\"\(miterLimit)\""
        if let (c,r)=circle { return "<circle cx=\"\(c.x)\" cy=\"\(c.y)\" r=\"\(r)\" \(style)/>" }
        let data=commands.map { switch $0 { case .move(let a):"M "+p(a);case .line(let a):"L "+p(a);case .curve(let a,let b,let c):"C "+p(a)+" "+p(b)+" "+p(c);case .close:"Z" } }.joined(separator:" ")
        return "<path d=\"\(data)\" \(style)/>"
    }
    public var sampledPoints: [Point] {
        if let (p,r)=circle { return (0..<64).map { p+Point(cos(Double($0) * .pi/32),sin(Double($0) * .pi/32))*r } }
        var points:[Point]=[];var current=Point.zero
        for command in commands { switch command {
        case .move(let p),.line(let p):points.append(p);current=p
        case .curve(let a,let b,let p):let start=current;points += (1...24).map { i in let t=Double(i)/24,u=1-t;return start*(u*u*u)+a*(3*u*u*t)+b*(3*u*t*t)+p*(t*t*t) };current=p
        case .close:break
        } };return points
    }
}
