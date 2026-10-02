import Foundation
import CoreGraphics

public enum GraphicsError: Error, CustomStringConvertible {
    case invalid(String), unavailable(String), io(String)
    public var description: String {
        switch self { case .invalid(let s), .unavailable(let s), .io(let s): return s }
    }
}

public struct Color: Equatable {
    public var r, g, b, a: Double
    /// Light emits, ink doesn't: neon halos skip dark colours (a dark halo on a light ground reads as a smudge).
    public var glows: Bool { a > 0 && max(r,g,b) > 0.35 }
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public init(hex: String) throws {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard [6, 8].contains(s.count), let n = UInt64(s, radix: 16) else {
            throw GraphicsError.invalid("Invalid hex color: \(hex)")
        }
        let alpha = s.count == 8
        self.init(Double((n >> (alpha ? 24 : 16)) & 255) / 255,
                  Double((n >> (alpha ? 16 : 8)) & 255) / 255,
                  Double((n >> (alpha ? 8 : 0)) & 255) / 255,
                  alpha ? Double(n & 255) / 255 : 1)
    }
    public static let clear = Color(0, 0, 0, 0), white = Color(1, 1, 1), black = Color(0, 0, 0)
    public static func hsb(_ h: Double, _ s: Double, _ b: Double, alpha: Double = 1) -> Color {
        let hue = (h - floor(h)) * 6, c = b * s, x = c * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1)), m = b - c
        let rgb: (Double, Double, Double)
        switch Int(hue) { case 0: rgb = (c,x,0); case 1: rgb = (x,c,0); case 2: rgb = (0,c,x)
        case 3: rgb = (0,x,c); case 4: rgb = (x,0,c); default: rgb = (c,0,x) }
        return Color(rgb.0 + m, rgb.1 + m, rgb.2 + m, alpha)
    }
    public func opacity(_ value: Double) -> Color { Color(r, g, b, a * value) }
    public func mixed(with other: Color, amount: Double) -> Color {
        Color(r + (other.r-r)*amount, g + (other.g-g)*amount, b + (other.b-b)*amount, a + (other.a-a)*amount)
    }
    public var cgColor: CGColor { CGColor(colorSpace: Color.space, components: [r,g,b,a])! }
    public static let space = CGColorSpace(name: CGColorSpace.sRGB)!
}

/// Geometry is built once and retained by ShapeNode. Coordinates: pixels, top-left, radians.
public final class Path {
    public let cgPath: CGMutablePath
    public init() { cgPath = CGMutablePath() }
    public init(_ path: CGPath) { cgPath = path.mutableCopy()! }
    @discardableResult public func move(_ x: Double, _ y: Double) -> Path { cgPath.move(to: CGPoint(x:x,y:y)); return self }
    @discardableResult public func line(_ x: Double, _ y: Double) -> Path { cgPath.addLine(to: CGPoint(x:x,y:y)); return self }
    @discardableResult public func cubic(_ c1: CGPoint, _ c2: CGPoint, _ end: CGPoint) -> Path {
        cgPath.addCurve(to: end, control1: c1, control2: c2); return self
    }
    @discardableResult public func quadratic(_ control: CGPoint, _ end: CGPoint) -> Path {
        cgPath.addQuadCurve(to: end, control: control); return self
    }
    @discardableResult public func close() -> Path { cgPath.closeSubpath(); return self }
    public static func rect(_ rect: CGRect, radius: Double = 0) -> Path {
        let p = Path(); p.cgPath.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius); return p
    }
    public static func ellipse(_ rect: CGRect) -> Path { let p = Path(); p.cgPath.addEllipse(in: rect); return p }
    public static func polygon(_ points: [CGPoint], closed: Bool = true) -> Path {
        let p = Path(); guard let first = points.first else { return p }
        p.cgPath.move(to: first); points.dropFirst().forEach { p.cgPath.addLine(to: $0) }
        if closed { p.close() }; return p
    }
    public enum ArcMode { case open, chord, pie }
    public static func arc(center: CGPoint, radius: Double, start: Double, end: Double, mode: ArcMode = .open) -> Path {
        let p = Path()
        if mode == .pie { p.cgPath.move(to: center) }
        p.cgPath.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        if mode != .open { p.close() }; return p
    }
    /// Catmull-Rom converted to cubic Beziers, with duplicated endpoint tangents.
    public static func spline(_ points: [CGPoint], tightness: Double = 0) -> Path {
        guard points.count > 1 else { return polygon(points, closed: false) }
        let p = Path().move(points[0].x, points[0].y), k = (1 - tightness) / 6
        for i in 0..<(points.count-1) {
            let a = points[max(0,i-1)], b = points[i], c = points[i+1], d = points[min(points.count-1,i+2)]
            p.cubic(CGPoint(x:b.x+(c.x-a.x)*k,y:b.y+(c.y-a.y)*k),
                    CGPoint(x:c.x-(d.x-b.x)*k,y:c.y-(d.y-b.y)*k), c)
        }
        return p
    }
    public static func bezierPoint(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, t: Double) -> CGPoint {
        let u = 1-t
        return CGPoint(x:u*u*u*a.x+3*u*u*t*b.x+3*u*t*t*c.x+t*t*t*d.x,
                       y:u*u*u*a.y+3*u*u*t*b.y+3*u*t*t*c.y+t*t*t*d.y)
    }
    public static func bezierTangent(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, t: Double) -> CGPoint {
        let u = 1-t
        return CGPoint(x:3*u*u*(b.x-a.x)+6*u*t*(c.x-b.x)+3*t*t*(d.x-c.x),
                       y:3*u*u*(b.y-a.y)+6*u*t*(c.y-b.y)+3*t*t*(d.y-c.y))
    }
    public static func star(radius: Double, inner: Double, rays: Int = 4) -> Path {
        guard rays >= 2 else { return Path() }
        return polygon((0..<rays*2).map { i in
            let a = Double(i) * .pi / Double(rays) - .pi/2, r = i % 2 == 0 ? radius : inner
            return CGPoint(x:cos(a)*r,y:sin(a)*r)
        })
    }
    public static func paper(width: Double, height: Double, seed: UInt64 = 1, roughness: Double = 7, step: Double = 9) -> Path {
        var rng = Random(seed: seed); let p = Path()
        let corners = [CGPoint(x:0,y:0), CGPoint(x:width,y:0), CGPoint(x:width,y:height), CGPoint(x:0,y:height)]
        for i in 0..<4 {
            let a = corners[i], b = corners[(i+1)%4], n = max(2, Int(hypot(b.x-a.x,b.y-a.y)/max(1,step)))
            for j in 0..<n {
                let t = Double(j)/Double(n), jitter = (rng.next()-0.5)*2*roughness
                let x = a.x+(b.x-a.x)*t + (i == 1 || i == 3 ? jitter : 0)
                let y = a.y+(b.y-a.y)*t + (i == 0 || i == 2 ? jitter : 0)
                if i == 0 && j == 0 { p.move(x,y) } else { p.line(x,y) }
            }
        }
        return p.close()
    }
}

public struct Random {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var z = state; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9; z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return Double((z ^ (z >> 31)) >> 11) / 9007199254740992
    }
    public mutating func gaussian() -> Double { sqrt(-2 * log(max(next(), 1e-15))) * cos(2 * .pi * next()) }
}

/// Seeded, continuous gradient noise; no mutable per-frame state.
public final class Noise {
    private let permutation: [Int]
    public init(seed: UInt64 = 7) {
        var rng = Random(seed: seed), p = Array(0..<256)
        for i in stride(from: 255, through: 1, by: -1) { p.swapAt(i, Int(rng.next() * Double(i+1))) }
        permutation = p+p
    }
    public func value(_ x: Double, _ y: Double = 0, octaves: Int = 1, falloff: Double = 0.5) -> Double {
        var sum = 0.0, weight = 1.0, norm = 0.0, frequency = 1.0
        for _ in 0..<max(1,octaves) { sum += raw(x*frequency,y*frequency)*weight; norm += weight; weight *= falloff; frequency *= 2 }
        return (sum/norm+1)/2
    }
    private func raw(_ x: Double, _ y: Double) -> Double {
        let ix = Int(floor(x)) & 255, iy = Int(floor(y)) & 255, fx = x-floor(x), fy = y-floor(y)
        func fade(_ t: Double) -> Double { t*t*t*(t*(t*6-15)+10) }
        func grad(_ h: Int, _ x: Double, _ y: Double) -> Double {
            switch h & 3 { case 0: return x+y; case 1: return -x+y; case 2: return x-y; default: return -x-y }
        }
        let u = fade(fx), v = fade(fy), p = permutation
        let a = grad(p[p[ix]+iy],fx,fy), b = grad(p[p[ix+1]+iy],fx-1,fy)
        let c = grad(p[p[ix]+iy+1],fx,fy-1), d = grad(p[p[ix+1]+iy+1],fx-1,fy-1)
        return (a+(b-a)*u)*(1-v)+(c+(d-c)*u)*v
    }
}
