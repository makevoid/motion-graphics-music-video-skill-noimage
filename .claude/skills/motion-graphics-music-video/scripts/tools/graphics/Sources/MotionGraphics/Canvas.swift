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
    /// Active 3D plane (set by PlaneNode for its subtree); paths, text outlines and clips are projected through it.
    public var projection: Projection?
    /// Neon (inherited down the scene graph like the transform): strokes, small fills (dots, stars <= 160 px) and Core Text glyphs
    /// cast a halo of their own colour `glow` px wide; `glowCore` 0...1 adds a thin, whitened core over strokes (the hot tube).
    public var glow = 0.0, glowCore = 0.0
    /// Device pixels per scene unit (supersampling); glow radii are scaled by it so the look holds at any render size.
    public let pixelScale: Double
    private var stack: [(Style, Projection?, Double, Double)] = []
    /// `supersample` draws at N× the size in device pixels (scene coordinates unchanged); downscale the snapshot for output.
    public init(width: Int, height: Int, supersample: Int = 1) throws {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw GraphicsError.invalid("Canvas dimensions must be 1...16384") }
        guard (1...4).contains(supersample) else { throw GraphicsError.invalid("supersample must be 1...4") }
        self.width = width; self.height = height; pixelScale = Double(supersample)
        let pw = width*supersample, ph = height*supersample
        guard let c = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw*4,
                                space: Color.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw GraphicsError.unavailable("Could not allocate drawing surface")
        }
        context = c
        c.translateBy(x: 0, y: CGFloat(ph)); c.scaleBy(x: CGFloat(supersample), y: -CGFloat(supersample))
    }
    public func clear(_ color: Color = .clear) {
        context.saveGState(); context.setBlendMode(.copy); context.setFillColor(color.cgColor)
        context.fill(CGRect(x:0,y:0,width:width,height:height)); context.restoreGState()
    }
    public func push() { stack.append((style,projection,glow,glowCore)); context.saveGState() }
    public func pop() { precondition(!stack.isEmpty, "Unbalanced Canvas.pop"); (style,projection,glow,glowCore) = stack.removeLast(); context.restoreGState() }
    public func withState(_ body: (Canvas) throws -> Void) rethrows { push(); defer { pop() }; try body(self) }
    public func translate(_ x: Double, _ y: Double) { context.translateBy(x:x,y:y) }
    public func rotate(_ radians: Double) { context.rotate(by:radians) }
    public func scale(_ x: Double, _ y: Double? = nil) { context.scaleBy(x:x,y:y ?? x) }
    public func transform(_ matrix: CGAffineTransform) { context.concatenate(matrix) }
    public func shear(_ x: Double, _ y: Double) { transform(CGAffineTransform(a:1,b:tan(y),c:tan(x),d:1,tx:0,ty:0)) }
    public func clip(_ path: Path, evenOdd: Bool = false) {
        var shape = path
        if let projection { guard let (p,_) = projection.project(path,ctm:context.ctm) else { context.clip(to:.zero); return }; shape = p }
        context.addPath(shape.cgPath); context.clip(using: evenOdd ? .evenOdd : .winding)
    }
    public func draw(_ path: Path) {
        let c = context
        var shape = path, width = style.lineWidth, dash = style.dash
        if let projection {
            guard let (p,s) = projection.project(path,ctm:c.ctm) else { return }
            shape = p; width *= s; dash = dash.map { $0*CGFloat(s) }
        }
        c.addPath(shape.cgPath); c.setLineWidth(width); c.setLineCap(style.lineCap); c.setLineJoin(style.lineJoin)
        c.setLineDash(phase:style.dashPhase,lengths:dash)
        if let f = style.fill { c.setFillColor(f.cgColor) }
        if let s = style.stroke { c.setStrokeColor(s.cgColor) }
        var halo: Color?
        if glow > 0 {
            if let s = style.stroke { halo = s }
            else if let f = style.fill {
                let box = shape.cgPath.boundingBoxOfPath.applying(c.ctm)
                if max(box.width,box.height) <= 160*pixelScale { halo = f }
            }
            if let h = halo, !h.glows { halo = nil }
        }
        let mode: CGPathDrawingMode? = style.fill != nil && style.stroke != nil ? (style.evenOdd ? .eoFillStroke : .fillStroke)
            : style.fill != nil ? (style.evenOdd ? .eoFill : .fill) : style.stroke != nil ? .stroke : nil
        guard let mode else { c.beginPath(); return }
        guard let halo else { c.drawPath(using:mode); return }
        c.beginPath()
        // Neon: a thin tube carries too little light for a shadow to read, so the wide halo is cast from a fattened copy of the
        // outline drawn far off-canvas — only its blurred shadow lands (offsets are in device pixels). Then the tube itself with a
        // tight glow, then the hot core.
        var source: CGPath = shape.cgPath
        if style.stroke != nil {
            if !dash.isEmpty { source = source.copy(dashingWithPhase:style.dashPhase,lengths:dash) }
            source = source.copy(strokingWithWidth:width+glow*0.6,lineCap:.round,lineJoin:.round,miterLimit:10)
        } else {
            let dot = CGMutablePath(); dot.addPath(source); dot.addPath(source.copy(strokingWithWidth:glow*0.6,lineCap:.round,lineJoin:.round,miterLimit:10)); source = dot
        }
        let ctm = c.ctm, away = CGFloat(c.width+c.height)*4
        c.saveGState(); c.concatenate(ctm.inverted())
        var device = ctm.concatenating(CGAffineTransform(translationX:away,y:0))
        if let moved = source.copy(using:&device) {
            let a = halo.a*0.8
            c.setShadow(offset:CGSize(width:-away,height:0),blur:CGFloat(glow*1.6*pixelScale),color:Color(halo.r,halo.g,halo.b,a).cgColor)
            c.setFillColor(Color(halo.r,halo.g,halo.b,1).cgColor); c.addPath(moved); c.fillPath()
        }
        c.restoreGState()
        c.setShadow(offset:.zero,blur:CGFloat(glow*0.35*pixelScale),color:halo.cgColor)
        c.addPath(shape.cgPath); c.drawPath(using:mode)
        c.setShadow(offset:.zero,blur:0,color:nil)
        if glowCore > 0, let s = style.stroke {
            let k = min(1,glowCore)*0.65
            c.addPath(shape.cgPath); c.setLineWidth(width*0.45)
            c.setStrokeColor(Color(s.r+(1-s.r)*k,s.g+(1-s.g)*k,s.b+(1-s.b)*k,s.a).cgColor); c.strokePath()
        }
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
    public struct Glyph { public let path: CGPath, x: Double, advance: Double }
    public let line: CTLine, width: Double, ascent: Double, descent: Double, outline: Path
    /// Per-glyph outlines at the origin (y down) with their pen x and advance, for text on paths.
    public private(set) var glyphs: [Glyph] = []
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
            var advances = [CGSize](repeating:.zero,count:n)
            CTRunGetAdvances(run,CFRange(location:0,length:0),&advances)
            for i in 0..<n {
                if let p = CTFontCreatePathForGlyph(font,glyphs[i],nil) {
                    let t = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:positions[i].x,ty:-positions[i].y)
                    outline.cgPath.addPath(p,transform:t)
                    var flip = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:-positions[i].y)
                    if let local = p.copy(using:&flip) { self.glyphs.append(Glyph(path:local,x:positions[i].x,advance:advances[i].width)) }
                }
            }
        }
    }
    /// Core Text substitutes a fallback face for unknown names; this detects that by PostScript/full/family name.
    public static func isAvailable(_ font: String) -> Bool {
        let f = CTFontCreateWithName(font as CFString,12,nil), wanted = font.lowercased()
        return [CTFontCopyPostScriptName(f),CTFontCopyFullName(f),CTFontCopyFamilyName(f)].contains { ($0 as String).lowercased() == wanted }
    }
    public static func registerFont(at url: URL) throws {
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL,.process,&error) else {
            throw GraphicsError.io("Font registration failed: \(error?.takeRetainedValue().localizedDescription ?? url.path)")
        }
    }
    public func draw(on canvas: Canvas, at point: CGPoint, color: Color = .white) {
        if canvas.projection != nil {
            // Core Text cannot be projected; fill the cached glyph outlines instead.
            canvas.withState { c in c.translate(point.x,point.y); c.style = Style(fill:color); c.draw(outline) }
            return
        }
        canvas.withState { c in
            c.translate(point.x,point.y); c.scale(1,-1); c.context.textMatrix = .identity
            c.context.textPosition = .zero; c.context.setFillColor(color.cgColor)
            // Small type glows; big poster words stay crisp (a halo on them reads as blur).
            let cap = ascent*Double(hypot(c.context.ctm.a,c.context.ctm.b))/c.pixelScale
            if c.glow > 0, color.glows, cap < 90 { c.context.setShadow(offset:.zero,blur:CGFloat(c.glow*0.7*c.pixelScale),color:color.cgColor) }
            CTLineDraw(line,c.context)
        }
    }
}
