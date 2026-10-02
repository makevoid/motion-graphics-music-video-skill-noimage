import Foundation
import CoreGraphics

/// Perspective projection of a 2D plane in 3D, applied to vector geometry (paths, text outlines, clips) so lines stay crisp.
/// Points are rotated about `pivot` (plane-local), translated by (tx, ty, tz) and projected with focal length `focal` (px)
/// toward a vanishing point at the pivot. Straight segments stay straight under projection, so only curves are subdivided.
/// rotationX > 0 tips the top edge away (a floor receding upward); rotationY > 0 swings the right edge away.
/// Nested planes compose. Raster images are drawn unprojected. Geometry crossing behind the camera is clipped at a near plane
/// (depth = 5% of the focal length), so a floor grid may run under the viewer; only an enclosing plane can still drop a path.
public final class Projection {
    public let base: CGAffineTransform, inverse: CGAffineTransform
    public let pivot: CGPoint, rx: Double, ry: Double, tx: Double, ty: Double, tz: Double, focal: Double
    public let outer: Projection?
    public init(base: CGAffineTransform, pivot: CGPoint, rx: Double, ry: Double, tx: Double = 0, ty: Double = 0, tz: Double = 0, focal: Double = 1400, outer: Projection? = nil) {
        self.base = base; inverse = base.inverted(); self.pivot = pivot
        self.rx = rx; self.ry = ry; self.tx = tx; self.ty = ty; self.tz = tz; self.focal = max(1,focal); self.outer = outer
    }
    /// Plane-local point -> camera space: (x, y) about the pivot after rotation and pan, and depth along the view axis.
    public func lift(local p: CGPoint) -> (x: Double, y: Double, depth: Double) {
        let x = p.x-pivot.x, y = p.y-pivot.y
        let x1 = x*cos(ry), z1 = x*sin(ry)
        let y2 = y*cos(rx), z2 = z1-y*sin(rx)
        return (x1+tx,y2+ty,focal+z2+tz)
    }
    public var near: Double { focal*0.05 }
    private func divide(_ q: (x: Double, y: Double, depth: Double)) -> (CGPoint, Double) {
        let s = focal/q.depth
        return (CGPoint(x:pivot.x+q.x*s,y:pivot.y+q.y*s),s)
    }
    /// Plane-local point -> plane-local projected point and its perspective scale; nil behind the near plane.
    public func project(local p: CGPoint) -> (CGPoint, Double)? {
        let q = lift(local:p)
        guard q.depth >= near else { return nil }
        return divide(q)
    }
    /// Clips camera-space points to depth >= near: a closed ring stays one ring (Sutherland-Hodgman), an open polyline
    /// splits into the runs in front of the camera.
    func clipNear(_ pts: [(x: Double, y: Double, depth: Double)], closed: Bool) -> [[(x: Double, y: Double, depth: Double)]] {
        let n = near
        func cut(_ a: (x: Double, y: Double, depth: Double), _ b: (x: Double, y: Double, depth: Double)) -> (x: Double, y: Double, depth: Double) {
            let k = (n-a.depth)/(b.depth-a.depth)
            return (a.x+(b.x-a.x)*k,a.y+(b.y-a.y)*k,n)
        }
        guard pts.contains(where: { $0.depth < n }) else { return [pts] }
        if closed {
            var ring: [(x: Double, y: Double, depth: Double)] = []
            for (i,b) in pts.enumerated() {
                let a = pts[(i+pts.count-1)%pts.count]
                if b.depth >= n { if a.depth < n { ring.append(cut(a,b)) }; ring.append(b) }
                else if a.depth >= n { ring.append(cut(a,b)) }
            }
            return ring.count >= 3 ? [ring] : []
        }
        var runs: [[(x: Double, y: Double, depth: Double)]] = [], run: [(x: Double, y: Double, depth: Double)] = []
        for (i,b) in pts.enumerated() {
            if i > 0 {
                let a = pts[i-1]
                if a.depth >= n && b.depth < n { run.append(cut(a,b)); runs.append(run); run = [] }
                else if a.depth < n && b.depth >= n { run.append(cut(a,b)) }
            }
            if b.depth >= n { run.append(b) }
        }
        if run.count > 1 { runs.append(run) }
        return runs.filter { $0.count > 1 }
    }
    /// Device point -> projected device point (through every enclosing plane) and the accumulated scale.
    public func map(device d: CGPoint) -> (CGPoint, Double)? {
        guard let (p,s) = project(local:d.applying(inverse)) else { return nil }
        let out = p.applying(base)
        guard let outer else { return (out,s) }
        guard let (o,s2) = outer.map(device:out) else { return nil }
        return (o,s*s2)
    }
    /// Projects a path drawn under user transform `ctm`; the result is in the same user space. Returns the mean scale,
    /// or nil when nothing is left in front of the camera.
    public func project(_ path: Path, ctm: CGAffineTransform) -> (Path, Double)? {
        guard abs(ctm.a*ctm.d-ctm.b*ctm.c) > 1e-12 else { return nil }
        let back = ctm.inverted(), out = Path()
        var total = 0.0, count = 0
        for line in path.flattened(steps:24) {
            let lifted = line.points.map { lift(local:$0.applying(ctm).applying(inverse)) }
            for run in clipNear(lifted,closed:line.closed) {
                for (i,q) in run.enumerated() {
                    var (p,s) = divide(q)
                    p = p.applying(base)
                    if let outer { guard let (o,s2) = outer.map(device:p) else { return nil }; p = o; s *= s2 }
                    let u = p.applying(back)
                    if i == 0 { out.move(u.x,u.y) } else { out.line(u.x,u.y) }
                    total += s; count += 1
                }
                if line.closed { out.close() }
            }
        }
        guard count > 0 else { return nil }
        return (out,total/Double(count))
    }
}

/// Group whose children are drawn on a plane rotated in 3D. Tracks: rotationX, rotationY, z (depth, + is away), panX, panY.
/// The 3D pivot (and vanishing point) is the node's anchor. Share one pan track across planes at different z for parallax.
public final class PlaneNode: Node {
    public var rotationX = 0.0, rotationY = 0.0, z = 0.0, panX = 0.0, panY = 0.0, perspective = 1400.0
    public override func draw(on canvas: Canvas, at time: FrameTime) {
        let t = time.seconds
        func v(_ k: String, _ d: Double) -> Double { tracks[k]?.value(at:t) ?? d }
        canvas.projection = Projection(base:canvas.context.ctm,pivot:anchor,rx:v("rotationX",rotationX),ry:v("rotationY",rotationY),
                                       tx:v("panX",panX),ty:v("panY",panY),tz:v("z",z),focal:perspective,outer:canvas.projection)
    }
}

/// Text set along a path: an open polyline/spline or a closed loop (circle). Each glyph sits upright on the path tangent.
/// Tracks: offset (px along the path; closed paths wrap), reveal (0...1 fraction of glyphs shown, typewriter).
public final class TextPathNode: Node {
    public let layout: TextLayout, line: Polyline, closed: Bool
    public var color: Color = .white, outlineColor: Color? = nil, outlineWidth = 0.0, offset = 0.0
    public var alignment = TextNode.Alignment.left
    private let cumulative: [Double], length: Double
    public init(_ text: String, path: Path, font: String = "HelveticaNeue", size: Double = 48, tracking: Double = 0, name: String = "") throws {
        layout = TextLayout(text,font:font,size:size,tracking:tracking)
        guard let first = path.flattened(steps:48).first, first.points.count > 1 else { throw GraphicsError.invalid("textpath needs a path with length") }
        line = first; closed = first.closed
        var c = [0.0]; for s in first.segments { c.append(c.last!+s) }
        cumulative = c; length = c.last!
        guard length > 0 else { throw GraphicsError.invalid("textpath needs a path with length") }
        super.init(name:name)
    }
    /// Point and tangent angle at arc length `d`.
    public func sample(_ d: Double) -> (CGPoint, Double)? {
        var s = d
        if closed { s = s.truncatingRemainder(dividingBy:length); if s < 0 { s += length } }
        else if s < 0 || s > length { return nil }
        let pts = closed ? line.points+[line.points[0]] : line.points
        var i = 0
        while i < cumulative.count-2 && cumulative[i+1] < s { i += 1 }
        let a = pts[i], b = pts[i+1], seg = max(1e-9,cumulative[i+1]-cumulative[i]), k = (s-cumulative[i])/seg
        return (CGPoint(x:a.x+(b.x-a.x)*k,y:a.y+(b.y-a.y)*k),atan2(b.y-a.y,b.x-a.x))
    }
    public override func draw(on canvas: Canvas, at time: FrameTime) {
        let t = time.seconds, glyphs = layout.glyphs
        let shown = Int(floor(Double(glyphs.count)*min(1,max(0,tracks["reveal"]?.value(at:t) ?? 1))+1e-9))
        let lead: Double
        // Open paths align within their length; closed loops align about their start point (a circle's top).
        let span = closed ? 0 : length
        switch alignment { case .left: lead = 0; case .center: lead = (span-layout.width)/2; case .right: lead = span-layout.width }
        let start = lead+(tracks["offset"]?.value(at:t) ?? offset)
        for g in glyphs.prefix(shown) {
            guard let (p,angle) = sample(start+g.x+g.advance/2) else { continue }
            let path = Path(g.path)
            canvas.withState { c in
                c.translate(p.x,p.y); c.rotate(angle); c.translate(-g.advance/2,0)
                c.style = Style(fill:color,stroke:outlineWidth > 0 ? outlineColor : nil,lineWidth:outlineWidth)
                c.draw(path)
            }
        }
    }
}

/// Concentric rings (circles or n-gons) for contour fields, tunnels and ripples.
/// Tracks: phase (0...1 moves every ring outward by one spacing and wraps: endless flow), twist, spacing, strokeWidth.
/// `fade` sets the outermost ring's alpha (inner rings are full), `aspect` squashes vertically (perspective rings).
public final class RingsNode: Node {
    public var count: Int, radius: Double, spacing: Double, sides: Int
    public var twist = 0.0, aspect = 1.0, fade = 1.0, color = Color.white, lineWidth = 1.0, dash: [CGFloat] = [], boil = 0.0, seed: UInt64 = 1
    public init(count: Int, radius: Double, spacing: Double, sides: Int = 0, name: String = "") {
        self.count = max(1,count); self.radius = max(0,radius); self.spacing = spacing; self.sides = sides; super.init(name:name)
    }
public override func contentBounds(at time: FrameTime) -> CGRect? {
    let t = time.seconds, gap = tracks["spacing"]?.value(at:t) ?? spacing, width = tracks["strokeWidth"]?.value(at:t) ?? lineWidth
    let r = max(radius,radius+Double(count)*gap)+boil+width*5+1, ry = r*abs(aspect)+width*5+1
    return CGRect(x:-r,y:-ry,width:2*r,height:2*ry)
}
    public override func draw(on canvas: Canvas, at time: FrameTime) {
        let t = time.seconds
        let phase = tracks["phase"]?.value(at:t) ?? 0, tw = tracks["twist"]?.value(at:t) ?? twist
        let gap = tracks["spacing"]?.value(at:t) ?? spacing, width = tracks["strokeWidth"]?.value(at:t) ?? lineWidth
        let f = phase-floor(phase)
        var rng = Random(seed:seed &* 0x9E3779B97F4A7C15 &+ UInt64(max(0,Int(floor(t*12)))))
        for i in 0...count {
            let k = Double(i)+f
            guard k <= Double(count) else { continue }
            let r = radius+k*gap
            guard r > 0 else { continue }
            let alpha = (i == 0 && tracks["phase"] != nil ? f : 1)*(1+(fade-1)*k/Double(count))
            guard alpha > 0.001 else { continue }
            let path: Path
            if sides >= 3 {
                let rot = tw*k-Double.pi/2
                path = .polygon((0..<sides).map { j in
                    let a = rot+Double(j)*2*Double.pi/Double(sides), jitter = boil > 0 ? (rng.next()*2-1)*boil : 0
                    return CGPoint(x:cos(a)*(r+jitter),y:sin(a)*(r+jitter)*aspect)
                })
            } else { path = .ellipse(CGRect(x:-r,y:-r*aspect,width:2*r,height:2*r*aspect)) }
            canvas.style = Style(fill:nil,stroke:color.opacity(alpha),lineWidth:width); canvas.style.dash = dash
            canvas.draw(path)
        }
    }
}
