import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public struct Style {
    public var fill: Color? = .white
    public var stroke: Color? = nil
    public var lineWidth: Double = 1
    public var lineCap: CGLineCap = .round
    public var lineJoin: CGLineJoin = .round
    public var dash: [CGFloat] = []
    public var dashPhase: CGFloat = 0
    public var evenOdd = false
    public init(fill: Color? = .white, stroke: Color? = nil, lineWidth: Double = 1) {
        self.fill = fill; self.stroke = stroke; self.lineWidth = lineWidth
    }
}

/// Native Quartz raster drawing. Bitmap CGContext is CPU rasterization, not Metal.
/// The surface and caches are retained across frames; use MetalParticles for large fields.
public final class Canvas {
    public let width: Int, height: Int, context: CGContext
    public var style = Style()
    private var stack: [Style] = []
    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw GraphicsError.invalid("Canvas dimensions must be 1...16384") }
        self.width = width; self.height = height
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                                space: Color.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw GraphicsError.unavailable("Could not allocate drawing surface")
        }
        context = c
        c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
    }
    public func clear(_ color: Color = .clear) {
        context.saveGState(); context.setBlendMode(.copy); context.setFillColor(color.cgColor)
        context.fill(CGRect(x:0,y:0,width:width,height:height)); context.restoreGState()
    }
    public func push() { stack.append(style); context.saveGState() }
    public func pop() { precondition(!stack.isEmpty, "Unbalanced Canvas.pop"); style = stack.removeLast(); context.restoreGState() }
    public func withState(_ body: (Canvas) throws -> Void) rethrows { push(); defer { pop() }; try body(self) }
    public func translate(_ x: Double, _ y: Double) { context.translateBy(x:x,y:y) }
    public func rotate(_ radians: Double) { context.rotate(by:radians) }
    public func scale(_ x: Double, _ y: Double? = nil) { context.scaleBy(x:x,y:y ?? x) }
    public func transform(_ matrix: CGAffineTransform) { context.concatenate(matrix) }
    public func shear(_ x: Double, _ y: Double) { transform(CGAffineTransform(a:1,b:tan(y),c:tan(x),d:1,tx:0,ty:0)) }
    public func clip(_ path: Path, evenOdd: Bool = false) { context.addPath(path.cgPath); context.clip(using: evenOdd ? .evenOdd : .winding) }
    public func draw(_ path: Path) {
        let c = context
        c.addPath(path.cgPath); c.setLineWidth(style.lineWidth); c.setLineCap(style.lineCap); c.setLineJoin(style.lineJoin)
        c.setLineDash(phase:style.dashPhase,lengths:style.dash)
        if let f = style.fill { c.setFillColor(f.cgColor) }
        if let s = style.stroke { c.setStrokeColor(s.cgColor) }
        if style.fill != nil && style.stroke != nil { c.drawPath(using:style.evenOdd ? .eoFillStroke : .fillStroke) }
        else if style.fill != nil { c.drawPath(using:style.evenOdd ? .eoFill : .fill) }
        else if style.stroke != nil { c.strokePath() }
        else { c.beginPath() }
    }
    public func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, radius: Double = 0) { draw(.rect(CGRect(x:x,y:y,width:w,height:h), radius:radius)) }
    public func square(_ x: Double, _ y: Double, _ size: Double) { rect(x,y,size,size) }
    public func ellipse(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { draw(.ellipse(CGRect(x:x-w/2,y:y-h/2,width:w,height:h))) }
    public func circle(_ x: Double, _ y: Double, _ diameter: Double) { ellipse(x,y,diameter,diameter) }
    public func point(_ x: Double, _ y: Double) { withState { c in c.style.fill = c.style.stroke; c.style.stroke = nil; c.circle(x,y,c.style.lineWidth) } }
    public func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) { withState { c in c.style.fill = nil; c.draw(Path().move(x1,y1).line(x2,y2)) } }
    public func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) { draw(.polygon([a,b,c])) }
    public func quad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) { draw(.polygon([a,b,c,d])) }
    public func image(_ image: CGImage, in rect: CGRect) {
        context.saveGState(); context.translateBy(x:rect.minX,y:rect.maxY); context.scaleBy(x:1,y:-1)
        context.draw(image,in:CGRect(origin:.zero,size:rect.size)); context.restoreGState()
    }
    public func gradient(_ gradient: Gradient, in path: Path) {
        withState { c in
            c.clip(path)
            switch gradient.kind {
            case .linear(let a, let b): c.context.drawLinearGradient(gradient.cgGradient,start:a,end:b,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
            case .radial(let center, let radius): c.context.drawRadialGradient(gradient.cgGradient,startCenter:center,startRadius:0,endCenter:center,endRadius:radius,options:.drawsAfterEndLocation)
            }
        }
    }
    public func snapshot() throws -> CGImage {
        guard let image = context.makeImage() else { throw GraphicsError.io("Snapshot failed") }; return image
    }
    public func writePNG(to url: URL) throws { try ImageAsset.writePNG(snapshot(), to:url) }
}

public final class Gradient {
    public enum Kind { case linear(CGPoint, CGPoint), radial(CGPoint, Double) }
    public let kind: Kind, cgGradient: CGGradient
    public init(colors: [Color], locations: [CGFloat]? = nil, kind: Kind) throws {
        guard colors.count >= 2, locations == nil || locations!.count == colors.count,
              locations?.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) ?? true,
              locations == nil || locations! == locations!.sorted() else { throw GraphicsError.invalid("Invalid gradient stops") }
        guard let g = CGGradient(colorsSpace: Color.space, colors: colors.map(\.cgColor) as CFArray, locations: locations) else {
            throw GraphicsError.invalid("Invalid gradient")
        }
        cgGradient = g; self.kind = kind
    }
}

public final class ImageAsset {
    public let image: CGImage
    public init(url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL,nil), let img = CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {
            throw GraphicsError.io("Cannot load image: \(url.path)")
        }
        image = img
    }
    public init(image: CGImage) { self.image = image }
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw GraphicsError.io("Cannot write \(url.path)") }
        CGImageDestinationAddImage(dest,image,nil)
        guard CGImageDestinationFinalize(dest) else { throw GraphicsError.io("PNG write failed: \(url.path)") }
    }
}

/// Shaping and glyph outlines are cached at construction, including fallback fonts.
public final class TextLayout {
    public let line: CTLine, width: Double, ascent: Double, descent: Double, outline: Path
    public init(_ text: String, font: String = "HelveticaNeue", size: Double = 48, tracking: Double = 0) {
        let f = CTFontCreateWithName(font as CFString,size,nil)
        let attrs = [kCTFontAttributeName:f, kCTKernAttributeName:tracking,
                     kCTForegroundColorFromContextAttributeName:true] as [CFString:Any]
        line = CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:Dictionary(uniqueKeysWithValues:attrs.map { (NSAttributedString.Key($0 as String),$1) })))
        var a: CGFloat = 0, d: CGFloat = 0
        width = CTLineGetTypographicBounds(line,&a,&d,nil); ascent = a; descent = d
        outline = Path()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run), attrs = CTRunGetAttributes(run) as NSDictionary
            let font = attrs[kCTFontAttributeName] as! CTFont
            var glyphs = [CGGlyph](repeating:0,count:n), positions = [CGPoint](repeating:.zero,count:n)
            CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs); CTRunGetPositions(run,CFRange(location:0,length:0),&positions)
            for i in 0..<n {
                if let p = CTFontCreatePathForGlyph(font,glyphs[i],nil) {
                    let t = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:positions[i].x,ty:-positions[i].y)
                    outline.cgPath.addPath(p,transform:t)
                }
            }
        }
    }
    public static func registerFont(at url: URL) throws {
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL,.process,&error) else {
            throw GraphicsError.io("Font registration failed: \(error?.takeRetainedValue().localizedDescription ?? url.path)")
        }
    }
    public func draw(on canvas: Canvas, at point: CGPoint, color: Color = .white) {
        canvas.withState { c in
            c.translate(point.x,point.y); c.scale(1,-1); c.context.textMatrix = .identity
            c.context.textPosition = .zero; c.context.setFillColor(color.cgColor); CTLineDraw(line,c.context)
        }
    }
}
