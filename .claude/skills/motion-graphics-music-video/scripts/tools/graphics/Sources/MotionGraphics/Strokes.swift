import Foundation
import CoreGraphics

/// A path flattened once into polylines, for length-based trimming (draw-on lines) and hand-drawn boil.
public struct Polyline {
    public var points: [CGPoint], closed: Bool
    public var length: Double { segments.reduce(0,+) }
    public var segments: [Double] {
        let pts = closed && points.count > 1 ? points+[points[0]] : points
        return zip(pts,pts.dropFirst()).map { hypot($1.x-$0.x,$1.y-$0.y) }
    }
}

extension Path {
    /// Curves are subdivided uniformly; `steps` per curve trades accuracy for per-frame cost.
    public func flattened(steps: Int = 16) -> [Polyline] {
        var out: [Polyline] = [], current: [CGPoint] = []
        func flush(closed: Bool) { if current.count > 1 { out.append(Polyline(points:current,closed:closed)) }; current = [] }
        cgPath.applyWithBlock { element in
            let e = element.pointee, p = e.points
            switch e.type {
            case .moveToPoint: flush(closed:false); current = [p[0]]
            case .addLineToPoint: current.append(p[0])
            case .addQuadCurveToPoint:
                let a = current.last ?? p[0]
                for i in 1...steps { let t = Double(i)/Double(steps), u = 1-t
                    current.append(CGPoint(x:u*u*a.x+2*u*t*p[0].x+t*t*p[1].x,y:u*u*a.y+2*u*t*p[0].y+t*t*p[1].y)) }
            case .addCurveToPoint:
                let a = current.last ?? p[0]
                for i in 1...steps { current.append(Path.bezierPoint(a,p[0],p[1],p[2],t:Double(i)/Double(steps))) }
            case .closeSubpath:
                if let first = current.first, let last = current.last, hypot(last.x-first.x,last.y-first.y) < 1e-6 { current.removeLast() }
                flush(closed:true)
            @unknown default: break
            }
        }
        flush(closed:false)
        return out
    }

    /// Sub-path between fractions `from`...`to` of the total contour length (contours are traversed in order).
    /// `boil` displaces every vertex by a seeded offset that changes once per boil `step` (hand-drawn line boil).
    public static func trimmed(_ lines: [Polyline], from: Double, to: Double, boil: Double = 0, step: Int = 0, seed: UInt64 = 1, wholeClosed: Bool = true) -> Path {
        let out = Path()
        let a = min(1,max(0,from)), b = min(1,max(0,to))
        guard b > a else { return out }
        var rng = Random(seed:seed &* 0x9E3779B97F4A7C15 &+ UInt64(bitPattern:Int64(step)))
        func jitter(_ p: CGPoint) -> CGPoint { boil > 0 ? CGPoint(x:p.x+(rng.next()*2-1)*boil,y:p.y+(rng.next()*2-1)*boil) : p }
        let total = lines.reduce(0) { $0+$1.length }
        guard total > 0 else { return out }
        let start = a*total, end = b*total
        var offset = 0.0
        for line in lines {
            let jittered = line.points.map(jitter)
            let pts = line.closed ? jittered+[jittered[0]] : jittered
            let segs = zip(line.points+(line.closed ? [line.points[0]] : []),(line.points+(line.closed ? [line.points[0]] : [])).dropFirst()).map { hypot($1.x-$0.x,$1.y-$0.y) }
            let length = segs.reduce(0,+)
            defer { offset += length }
            guard offset+length > start, offset < end else { continue }
            if wholeClosed && line.closed && start <= offset && end >= offset+length {
                out.move(pts[0].x,pts[0].y); pts.dropFirst().dropLast().forEach { out.line($0.x,$0.y) }; out.close(); continue
            }
            var d = offset, started = false
            for i in segs.indices {
                let s = segs[i], p = pts[i], q = pts[i+1]
                defer { d += s }
                guard s > 0, d+s > start, d < end else { continue }
                let t0 = max(0,(start-d)/s), t1 = min(1,(end-d)/s)
                let p0 = CGPoint(x:p.x+(q.x-p.x)*t0,y:p.y+(q.y-p.y)*t0), p1 = CGPoint(x:p.x+(q.x-p.x)*t1,y:p.y+(q.y-p.y)*t1)
                if !started { out.move(p0.x,p0.y); started = true }
                out.line(p1.x,p1.y)
            }
        }
        return out
    }
}

/// Grid whose lines bend toward a center (a gravity well / black-hole funnel). Animatable tracks: strength, twist.
/// strength: fraction (0...1) of the distance pulled toward the center at the core; falloff: Gaussian radius in px.
public final class WarpGridNode: Node {
    public var width: Double, height: Double, spacing: Double, center: CGPoint
    public var strength = 0.5, falloff = 300.0, twist = 0.0
    public var color = Color(1,1,1,0.4), lineWidth = 1.0, resolution = 12.0
    public init(width: Double, height: Double, spacing: Double = 60, center: CGPoint? = nil, name: String = "") {
        self.width = width; self.height = height; self.spacing = max(4,spacing)
        self.center = center ?? CGPoint(x:width/2,y:height/2); super.init(name:name)
    }
    public func warp(_ p: CGPoint, strength s: Double, twist w: Double) -> CGPoint {
        let dx = p.x-center.x, dy = p.y-center.y, r2 = dx*dx+dy*dy
        let k = exp(-r2/(falloff*falloff)), pull = 1-min(0.98,s*k), angle = w*k
        let x = dx*pull, y = dy*pull
        return CGPoint(x:center.x+x*cos(angle)-y*sin(angle),y:center.y+x*sin(angle)+y*cos(angle))
    }
    public override func draw(on canvas: Canvas, at time: FrameTime) {
        let s = tracks["strength"]?.value(at:time.seconds) ?? strength, w = tracks["twist"]?.value(at:time.seconds) ?? twist
        let path = Path(), step = max(2,resolution)
        for x in stride(from:0.0,through:width,by:spacing) {
            var first = true
            for y in stride(from:0.0,through:height+step/2,by:step) { let p = warp(CGPoint(x:x,y:min(y,height)),strength:s,twist:w); if first { path.move(p.x,p.y); first = false } else { path.line(p.x,p.y) } }
        }
        for y in stride(from:0.0,through:height,by:spacing) {
            var first = true
            for x in stride(from:0.0,through:width+step/2,by:step) { let p = warp(CGPoint(x:min(x,width),y:y),strength:s,twist:w); if first { path.move(p.x,p.y); first = false } else { path.line(p.x,p.y) } }
        }
        canvas.style = Style(fill:nil,stroke:color,lineWidth:tracks["strokeWidth"]?.value(at:time.seconds) ?? lineWidth); canvas.draw(path)
    }
}
