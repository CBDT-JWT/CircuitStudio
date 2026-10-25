import Foundation
import CoreText
import CoreGraphics

/// Shared font shaping for native canvas, bounding boxes and all export formats.
public enum SchematicTypography {
    private static let registered: Bool = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        for face in ["Regular","RegularItalic","Bold","BoldItalic"] {
            if let url = bundle.url(forResource:"Metropolis-"+face,withExtension:"ttf",subdirectory:"Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil)
            }
        }
        return true
    }()
    public static func font(size: Double, bold: Bool = true, italic: Bool = false) -> CTFont {
        _ = registered
        let name = "Metropolis-"+(bold ? (italic ? "BoldItalic" : "Bold") : (italic ? "RegularItalic" : "Regular"))
        let requested = CTFontCreateWithName(name as CFString,size,nil)
        if (CTFontCopyPostScriptName(requested) as String).hasPrefix("Metropolis") { return requested }
        let fallback = CTFontCreateWithName("HelveticaNeue-Bold" as CFString,size,nil)
        return italic ? (CTFontCreateCopyWithSymbolicTraits(fallback,size,nil,.traitItalic,.traitItalic) ?? fallback) : fallback
    }
    public static func line(_ text: DrawingText, color: CGColor? = nil) -> CTLine {
        let string = NSMutableAttributedString(string:"")
        for run in MathLabel.runs(text.text) {
            let font = font(size:text.size*(run.subscripted ? 0.73 : 1),bold:text.bold,italic:text.italic || (text.reference && !run.subscripted))
            var attrs: [NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTBaselineOffsetAttributeName as String):run.subscripted ? -text.size*0.18 : 0]
            if let color { attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
            string.append(NSAttributedString(string:run.text,attributes:attrs))
        }
        return CTLineCreateWithAttributedString(string)
    }
}
