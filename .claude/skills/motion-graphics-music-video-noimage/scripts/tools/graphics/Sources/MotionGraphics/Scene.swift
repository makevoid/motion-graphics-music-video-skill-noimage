import Foundation
import CoreGraphics

/// Nodes have identity and ownership; geometry and particle data remain value/buffer based.
/// Mutation and rendering are single-thread confined. A node cannot have two parents or form a cycle.
open class Node {
    public let name: String
    public var position = CGPoint.zero, scale = CGPoint(x:1,y:1), anchor = CGPoint.zero
    public var rotation = 0.0, opacity = 1.0, skewX = 0.0, skewY = 0.0
    public var start = 0.0, end = Double.infinity
    public var hidden = false
    public var blendMode: CGBlendMode = .normal
    /// Neon halo (px) and core (0...1) for this subtree; nil inherits. See Canvas.glow.
    public var glow: Double?, glowCore: Double?
    public var clip: Path?
    public var tracks: [String:Track] = [:]
    public var update: ((Node, FrameTime) -> Void)?
    public private(set) weak var parent: Node?
    public private(set) var children: [Node] = []
    public init(name: String = "") { self.name = name }
    @discardableResult public func add(_ child: Node) throws -> Node {
        var ancestor: Node? = self
        while let a = ancestor { if a === child { throw GraphicsError.invalid("Scene graph cycle") }; ancestor = a.parent }
        guard child.parent == nil else { throw GraphicsError.invalid("Node already has a parent") }
        children.append(child); child.parent = self; return child
    }
    public func remove(_ child: Node) { children.removeAll { $0 === child }; if child.parent === self { child.parent = nil } }
    public func render(on canvas: Canvas, at time: FrameTime) throws {
        guard !hidden, time.seconds >= start, time.seconds < end else { return }
        update?(self,time)
        func value(_ key: String, _ fallback: Double) -> Double { tracks[key]?.value(at:time.seconds) ?? fallback }
        let alpha = min(1,max(0,value("opacity",opacity)))
        guard alpha > 0 else { return }
        try canvas.withState { c in
            c.translate(value("x",position.x),value("y",position.y)); c.rotate(value("rotation",rotation))
            c.scale(value("scaleX",scale.x),value("scaleY",scale.y))
            let sx = value("skewX",skewX), sy = value("skewY",skewY)
            if sx != 0 || sy != 0 { c.shear(sx,sy) }
            c.translate(-anchor.x,-anchor.y)
            if let clip { c.clip(clip) }
            if let glow { c.glow = max(0,value("glow",glow)) }
            if let glowCore { c.glowCore = glowCore }
            // Isolated group opacity: overlapping children fade together, once.
            c.context.setBlendMode(blendMode); c.context.setAlpha(alpha)
            c.opacity *= alpha; if blendMode != .normal { c.occludes = false }
            var isolated = (alpha < 1 && !paintsOnce) || blendMode != .normal
            if isolated {
                // A transparency layer costs its whole area (the full supersampled frame) to clear and composite; bound it to the subtree's
                // box when that is known. Only with GPU glow: Core Graphics shadows would spill outside the box.
                let m = c.context.ctm, s = sqrt(abs(m.a*m.d-m.b*m.c))
                if c.glowLayers != nil, c.projection == nil, s > 1e-9, let box = localBounds(at:time) {
                    guard !box.isNull else { isolated = false; return }
                    c.context.beginTransparencyLayer(in:box.insetBy(dx:-3/s,dy:-3/s),auxiliaryInfo:nil)
                } else { c.context.beginTransparencyLayer(auxiliaryInfo:nil) }
                c.layerDepth += 1
            }
            defer { if isolated { c.context.endTransparencyLayer() } }
            try draw(on:c,at:time)
            for child in children { try child.render(on:c,at:time) }
        }
    }
    open func draw(on canvas: Canvas, at time: FrameTime) throws {}
    /// A conservative box around what draw(on:at:) paints, in local coordinates (.null = nothing); nil = unknown.
    open func contentBounds(at time: FrameTime) -> CGRect? { nil }
    /// True when draw(on:at:) paints a single mark and there are no children: group opacity then needs no isolated layer.
    open var paintsOnce: Bool { false }
    /// The node's transform at `time` (local -> parent coordinates), as render applies it.
    public func transform(at time: FrameTime) -> CGAffineTransform {
        func value(_ key: String, _ fallback: Double) -> Double { tracks[key]?.value(at:time.seconds) ?? fallback }
        var t = CGAffineTransform(translationX:value("x",position.x),y:value("y",position.y))
            .rotated(by:value("rotation",rotation)).scaledBy(x:value("scaleX",scale.x),y:value("scaleY",scale.y))
        let sx = value("skewX",skewX), sy = value("skewY",skewY)
        if sx != 0 || sy != 0 { t = CGAffineTransform(a:1,b:tan(sy),c:tan(sx),d:1,tx:0,ty:0).concatenating(t) }
        return t.translatedBy(x:-anchor.x,y:-anchor.y)
    }
    /// Box of this node and its visible descendants in local coordinates at `time` (.null = paints nothing); nil when any part is
    /// unknown (custom drawing, update closures).
    public func localBounds(at time: FrameTime) -> CGRect? {
        guard update == nil, var box = contentBounds(at:time) else { return nil }
        for child in children {
            guard !child.hidden, time.seconds >= child.start, time.seconds < child.end,
                  (child.tracks["opacity"]?.value(at:time.seconds) ?? child.opacity) > 0 else { continue }
            guard let b = child.localBounds(at:time) else { return nil }
            if !b.isNull { box = box.union(b.applying(child.transform(at:time))) }
        }
        if let clip { box = box.intersection(clip.cgPath.boundingBoxOfPath) }
        return box
    }
}
public final class Group: Node {
    public override func contentBounds(at time: FrameTime) -> CGRect? { .null }
}
/// Animatable tracks beyond the transform: trimStart, trimEnd (0...1 of the outline length; a partial outline
/// is stroked only), strokeWidth, dashPhase. `boil` (px) redraws the vertices with seeded jitter `boilRate` times
/// per second, like hand-drawn animation on twos/threes.
public final class ShapeNode: Node {
    public let path: Path
    public var style: Style, gradient: Gradient?
    public var trimStart = 0.0, trimEnd = 1.0, boil = 0.0, boilRate = 12.0, boilSeed: UInt64 = 1
    private lazy var polylines: [Polyline] = path.flattened()
    public init(_ path: Path, style: Style = Style(), name: String = "") { self.path = path; self.style = style; super.init(name:name) }
    public override func draw(on canvas: Canvas, at time: FrameTime) {
        let t = time.seconds
        canvas.style = style
        if let w = tracks["strokeWidth"] { canvas.style.lineWidth = max(0,w.value(at:t)) }
        if let d = tracks["dashPhase"] { canvas.style.dashPhase = d.value(at:t) }
        let a = tracks["trimStart"]?.value(at:t) ?? trimStart, b = tracks["trimEnd"]?.value(at:t) ?? trimEnd
        var shape = path
        if a > 0 || b < 1 || boil > 0 {
            guard b > a else { return }
            let partial = a > 0 || b < 1
            shape = Path.trimmed(polylines,from:a,to:b,boil:boil,step:Int(floor(t*max(0.001,boilRate))),seed:boilSeed,wholeClosed:!partial)
            if partial { canvas.style.fill = nil }
        }
    if let gradient, canvas.style.fill != nil { canvas.gradient(gradient,in:shape); canvas.style.fill = nil }
    canvas.draw(shape)
}
public override func contentBounds(at time: FrameTime) -> CGRect? {
    let w = style.stroke == nil ? 0 : max(style.lineWidth,tracks["strokeWidth"]?.value(at:time.seconds) ?? 0)
    let pad = w*(style.lineJoin == .miter ? 5 : 1)+boil*2+1
    return path.cgPath.boundingBoxOfPath.insetBy(dx:-pad,dy:-pad)
}
}
public final class TextNode: Node {
    public enum Alignment: String { case left, center, right }
    public let layout: TextLayout
    public var color: Color = .white, outlineColor: Color = .black, outlineWidth = 0.0
    public var reveal: Track?, alignment = Alignment.left
    public init(_ text: String, font: String = "HelveticaNeue", size: Double = 48, tracking: Double = 0, name: String = "") {
        layout = TextLayout(text,font:font,size:size,tracking:tracking); super.init(name:name)
    }
    public override func draw(on canvas: Canvas, at time: FrameTime) {
        switch alignment { case .left: break; case .center: canvas.translate(-layout.width/2,0); case .right: canvas.translate(-layout.width,0) }
        if let reveal { canvas.clip(.rect(CGRect(x:0,y:-layout.ascent,width:layout.width*min(1,max(0,reveal.value(at:time.seconds))),height:layout.ascent+layout.descent))) }
        if outlineWidth > 0 { canvas.style = Style(fill:nil,stroke:outlineColor,lineWidth:outlineWidth); canvas.draw(layout.outline) }
    layout.draw(on:canvas,at:.zero,color:color)
}
public override func contentBounds(at time: FrameTime) -> CGRect? {
    let x = alignment == .left ? 0 : alignment == .center ? -layout.width/2 : -layout.width, pad = outlineWidth+(layout.ascent+layout.descent)*0.3
    return CGRect(x:x,y:-layout.ascent,width:layout.width,height:layout.ascent+layout.descent).insetBy(dx:-pad,dy:-pad)
}
}
public final class ImageNode: Node {
    public let asset: ImageAsset
    public var rect: CGRect
    public init(_ asset: ImageAsset, rect: CGRect? = nil, name: String = "") {
        self.asset = asset; self.rect = rect ?? CGRect(x:0,y:0,width:asset.image.width,height:asset.image.height); super.init(name:name)
    }
    public override func draw(on canvas: Canvas, at time: FrameTime) { canvas.image(asset.image,in:rect) }
    public override func contentBounds(at time: FrameTime) -> CGRect? { rect }
    public override var paintsOnce: Bool { children.isEmpty }
}
/// Bounded LRU avoids loading an entire music video's sprite sequence into memory.
public final class SpriteSequence: Node {
    public let directory: URL, count: Int, sourceFPS: Double, cacheLimit: Int
    public var loop = false, audioAt = 0.0
    public var rect: CGRect
    private var cache: [Int:ImageAsset] = [:], order: [Int] = []
    public init(directory: URL, count: Int, fps: Double, rect: CGRect, cacheLimit: Int = 8, name: String = "") throws {
        guard count > 0, fps > 0, fps.isFinite, cacheLimit > 0 else { throw GraphicsError.invalid("Invalid sprite sequence") }
        self.directory = directory; self.count = count; sourceFPS = fps; self.rect = rect; self.cacheLimit = cacheLimit; super.init(name:name)
    }
    public func image(at seconds: Double) throws -> ImageAsset {
        let raw = Int(floor((seconds-audioAt)*sourceFPS)), index = loop ? ((raw%count)+count)%count : max(0,min(count-1,raw))
        order.removeAll { $0 == index }; order.append(index)
        if let image = cache[index] { return image }
        let image = try ImageAsset(url:directory.appendingPathComponent(String(format:"%04d.png",index)))
        cache[index] = image
        if order.count > cacheLimit { cache.removeValue(forKey:order.removeFirst()) }
        return image
    }
    public override func draw(on canvas: Canvas, at time: FrameTime) throws { canvas.image(try image(at:time.seconds).image,in:rect) }
    public override func contentBounds(at time: FrameTime) -> CGRect? { rect }
}
public final class TraceNode: Node {
    public let points: [CGPoint], lengths: [Double], total: Double
    public var progress: Track?, color = Color(0,1,1), lineWidth = 3.0, dotSize = 6.0
    public init(_ points: [CGPoint], name: String = "") {
        self.points = points
        lengths = zip(points,points.dropFirst()).map { hypot($1.x-$0.x,$1.y-$0.y) }; total = lengths.reduce(0,+)
        super.init(name:name)
    }
    public override func draw(on canvas: Canvas, at time: FrameTime) {
        guard let first = points.first else { return }
        var remaining = total*min(1,max(0,progress?.value(at:time.seconds) ?? 1)), head = first
        guard remaining > 0 else { return }
        let path = Path().move(first.x,first.y)
        for i in lengths.indices where remaining > 0 {
            if lengths[i] == 0 { continue }
            let k = min(1,remaining/lengths[i]), a = points[i], b = points[i+1]
            head = CGPoint(x:a.x+(b.x-a.x)*k,y:a.y+(b.y-a.y)*k); path.line(head.x,head.y); remaining -= lengths[i]
        }
        canvas.style = Style(fill:nil,stroke:color,lineWidth:lineWidth); canvas.draw(path)
        canvas.style = Style(fill:color); canvas.circle(head.x,head.y,dotSize)
    }
}
public final class KaraokeNode: Node {
    public let words: [WordCue], layouts: [TextLayout], size: Double
    public var active = Color(0,1,1), done = Color.white, todo = Color(1,1,1,0.3)
    public init(words: [WordCue], font: String = "HelveticaNeue", size: Double = 48) {
        self.words = words; self.size = size; layouts = words.map { TextLayout($0.w,font:font,size:size) }; super.init()
    }
    public override func draw(on canvas: Canvas, at time: FrameTime) {
        var x = 0.0
        for i in words.indices {
            let cue = words[i], layout = layouts[i], t = time.seconds
            layout.draw(on:canvas,at:CGPoint(x:x,y:0),color:t < cue.s ? todo : t < cue.e ? active : done)
            if t >= cue.s {
                canvas.style = Style(fill:nil,stroke:active,lineWidth:size*0.07)
                canvas.line(x,size*0.18,x+layout.width*Motion.progress(t,start:cue.s,duration:cue.e-cue.s),size*0.18)
            }
            x += layout.width+size*0.28
        }
    }
}
public final class Scene {
    public let root = Group(name:"root")
    public var background: Color = .clear
    public init() {}
    public func draw(on canvas: Canvas, at time: FrameTime) throws { canvas.clear(background); try root.render(on:canvas,at:time) }
}
