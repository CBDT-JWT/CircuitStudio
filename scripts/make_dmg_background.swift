import AppKit
let size=NSSize(width:640,height:400)
let image=NSImage(size:size)
image.lockFocus()
let paper=NSColor(calibratedRed:0.965,green:0.977,blue:0.97,alpha:1)
paper.setFill();NSRect(origin:.zero,size:size).fill()
let teal=NSColor(calibratedRed:0.08,green:0.44,blue:0.37,alpha:1)
let ink=NSColor(calibratedRed:0.12,green:0.22,blue:0.18,alpha:1)
func line(_ points:[NSPoint]){let p=NSBezierPath();p.move(to:points[0]);for v in points.dropFirst(){p.line(to:v)};p.lineWidth=1.5;p.lineJoinStyle = .round;p.lineCapStyle = .round;p.stroke()}
func motif(_ type:Int,_ x:CGFloat,_ y:CGFloat,_ rotation:CGFloat,_ scale:CGFloat=1){
 NSGraphicsContext.saveGraphicsState()
 let t=NSAffineTransform();t.translateX(by:x,yBy:y);t.rotate(byDegrees:rotation);t.scale(by:scale);t.concat()
 teal.withAlphaComponent(0.19).setStroke()
 if type%5==0{line([NSPoint(x:-28,y:0),NSPoint(x:-18,y:0),NSPoint(x:-14,y:6),NSPoint(x:-8,y:-6),NSPoint(x:-2,y:6),NSPoint(x:4,y:-6),NSPoint(x:10,y:6),NSPoint(x:16,y:0),NSPoint(x:28,y:0)])}
 if type%5==1{line([NSPoint(x:-26,y:0),NSPoint(x:-4,y:0)]);line([NSPoint(x:4,y:0),NSPoint(x:26,y:0)]);line([NSPoint(x:-4,y:-12),NSPoint(x:-4,y:12)]);line([NSPoint(x:4,y:-12),NSPoint(x:4,y:12)])}
 if type%5==2{let p=NSBezierPath(ovalIn:NSRect(x:-13,y:-13,width:26,height:26));p.lineWidth=1.5;p.stroke();line([NSPoint(x:0,y:-26),NSPoint(x:0,y:-13)]);line([NSPoint(x:0,y:13),NSPoint(x:0,y:26)]);line([NSPoint(x:-4,y:5),NSPoint(x:4,y:5)]);line([NSPoint(x:0,y:1),NSPoint(x:0,y:9)]);line([NSPoint(x:-4,y:-6),NSPoint(x:4,y:-6)])}
 if type%5==3{line([NSPoint(x:-14,y:-17),NSPoint(x:17,y:0),NSPoint(x:-14,y:17),NSPoint(x:-14,y:-17)]);line([NSPoint(x:17,y:0),NSPoint(x:29,y:0)]);line([NSPoint(x:-28,y:8),NSPoint(x:-14,y:8)]);line([NSPoint(x:-28,y:-8),NSPoint(x:-14,y:-8)])}
 if type%5==4{line([NSPoint(x:-28,y:0),NSPoint(x:-9,y:0),NSPoint(x:-9,y:11),NSPoint(x:9,y:0),NSPoint(x:-9,y:-11),NSPoint(x:-9,y:0)]);line([NSPoint(x:9,y:-12),NSPoint(x:9,y:12)]);line([NSPoint(x:9,y:0),NSPoint(x:28,y:0)])}
 NSGraphicsContext.restoreGraphicsState()
}
for (i,v) in [(0,(38.0,258.0,22.0)),(1,(599.0,330.0,-22.0)),(2,(568.0,80.0,16.0)),(3,(73.0,61.0,-18.0)),(4,(330.0,45.0,12.0)),(0,(393.0,333.0,-20.0)),(1,(613.0,204.0,55.0)),(4,(24.0,137.0,-48.0)),(3,(275.0,298.0,13.0))]{motif(i,CGFloat(v.0),CGFloat(v.1),CGFloat(v.2))}
for x in [170.0,470.0]{let r=NSRect(x:x-71,y:125,width:142,height:146);let p=NSBezierPath(roundedRect:r,xRadius:24,yRadius:24);NSColor.white.withAlphaComponent(0.82).setFill();p.fill();teal.withAlphaComponent(0.10).setStroke();p.lineWidth=1;p.stroke()}
func text(_ value:String,_ x:CGFloat,_ y:CGFloat,_ font:CGFloat,_ weight:NSFont.Weight,_ color:NSColor){(value as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:font,weight:weight),.foregroundColor:color])}
text("Circuit Studio",34,342,28,.semibold,ink)
text("让电路与想法，清晰呈现。",35,315,13,.regular,teal)
text("拖入「应用程序」即可安装",238,91,13,.medium,ink)
text("macOS 26+ · Apple Silicon / Intel",217,69,10,.regular,teal)
let trace=NSBezierPath();trace.move(to:NSPoint(x:263,y:198));trace.curve(to:NSPoint(x:377,y:198),controlPoint1:NSPoint(x:298,y:218),controlPoint2:NSPoint(x:343,y:218));trace.lineWidth=1.5;teal.withAlphaComponent(0.35).setStroke();trace.stroke()
image.unlockFocus()
guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:])else{fatalError("Background render failed")}
try png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
