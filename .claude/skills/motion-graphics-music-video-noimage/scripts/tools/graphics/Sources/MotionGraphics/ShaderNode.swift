import Foundation
import CoreGraphics

/// A procedural picture drawn by a built-in Metal kernel at the node's size (scene type "shader"), placed like an image so
/// transforms, opacity, blend and clips apply. `nebula`: domain-warped fbm gas (colours[0] deep -> colours[1] bright),
/// ridged filaments (colours[2]), an optional blue synchrotron core and sparse stars; inside a ragged disc of `radius` around
/// `center` (0 = fills the node), grown by `reveal`.
/// `starfield`: three parallax layers of jittered stars (density `stars`, colours mostly [0], some [1] and [2]) drifting with
/// evolve, each twinkling at its own rate (`twinkle` 0...1); the bright near stars get diffraction spikes. `pulse` (amount) with a
/// `beat` track (phase 0 -> 1 between beats) swells the stars on each beat and sends a soft light ring out from `center`;
/// `radius` > 0 fades the field out beyond it.
/// Tracks: evolve (the gas's/field's time; default seconds × drift), reveal (0...1+), brightness, beat (starfield).
public final class ShaderNode: Node {
    public static let library = ["nebula", "starfield"]
    public let shader: String, width: Double, height: Double
    public var colors = [Color(0.25,0.05,0.35), Color(1,0.35,0.12), Color(1,0.8,0.5)]
    public var center: CGPoint, radius = 0.0, reveal = 1.0, brightness = 1.0, drift = 0.25
    public var detail = 3.0, swirl = 4.0, filaments = 1.0, core = 0.0, stars = 0.0, seed = 1.0, resolution = 1.0
    public var twinkle = 0.6, pulse = 0.0
    private var engine: MetalShader?, failed = false

    public init(shader: String, width: Double, height: Double, name: String = "") throws {
        guard ShaderNode.library.contains(shader) else { throw GraphicsError.invalid("Unknown shader \(shader) (\(ShaderNode.library.joined(separator:", ")))") }
        guard width > 0, height > 0 else { throw GraphicsError.invalid("shader needs a positive width and height") }
        self.shader = shader; self.width = width; self.height = height; center = CGPoint(x:width/2,y:height/2); super.init(name:name)
    }

    public override func draw(on canvas: Canvas, at time: FrameTime) {
        let t = time.seconds, k = max(0.1,min(2,resolution))
        let pw = max(1,Int((width*k).rounded())), ph = max(1,Int((height*k).rounded()))
        if engine == nil && !failed {
            do { engine = try MetalShader(width:pw,height:ph,source:ShaderNode.source,functions:ShaderNode.library) }
            catch { failed = true; FileHandle.standardError.write(Data("shader \(shader): \(error)\n".utf8)) }
        }
        guard let engine else { return }
        func lin(_ c: Color) -> [Float] { [c.r,c.g,c.b].map { Float(pow(max(0,$0),2.2)) } }
        let c = (colors + Array(repeating:colors.last ?? .white,count:max(0,3-colors.count)))
        let head: [Float] = [Float(pw),Float(ph),Float(tracks["evolve"]?.value(at:t) ?? t*drift),Float(tracks["brightness"]?.value(at:t) ?? brightness),
                             Float(center.x*k),Float(center.y*k),Float(radius*k)]
        let params: [Float] = (shader == "starfield"
            ? head + [Float(pulse),Float(twinkle),Float(seed),Float(stars),Float(tracks["beat"]?.value(at:t) ?? 1)]
            : head + [Float(tracks["reveal"]?.value(at:t) ?? reveal),Float(swirl),Float(seed),Float(detail),Float(filaments)])
            + lin(c[0]) + [Float(stars)] + lin(c[1]) + [Float(core)] + lin(c[2]) + [0]
        let rect = CGRect(x:0,y:0,width:width,height:height)
        do {
            if canvas.gpu != nil, try canvas.composite(try engine.generateTexture(shader,params:params),in:rect) { return }
            canvas.image(try engine.generate(shader,params:params),in:rect)
        }
        catch { FileHandle.standardError.write(Data("shader \(shader): \(error)\n".utf8)) }
    }

    public override func contentBounds(at time: FrameTime) -> CGRect? { CGRect(x:0,y:0,width:width,height:height) }
    public override var paintsOnce: Bool { children.isEmpty }

    // a = (w, h, evolve, brightness)  b = (cx, cy, radius, reveal)  c = (swirl, seed, detail, filaments)
    // d = (colour0, stars)  e = (colour1, core)  f = (colour2, -). Output is emissive light, premultiplied, alpha = brightest channel.
    // starfield: b.w = pulse amount, c = (twinkle, seed, density, beat phase).
    static let source = """
    static inline float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p), u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
    }
    static inline float fbm(float2 p) {
        float v = 0.0, a = 0.5; float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);
        for (int i = 0; i < 6; i++) { v += a * vnoise(p); p = m * p; a *= 0.5; }
        return v;
    }
    static inline float ridged(float2 p) {
        float v = 0.0, a = 0.5; float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);
        for (int i = 0; i < 5; i++) { float n = 1.0 - fabs(vnoise(p) * 2.0 - 1.0); v += a * n * n; p = m * p; a *= 0.5; }
        return v;
    }
    static inline float uhash(uint2 v, uint seed) {                     // integer hash: no lattice artefacts at large coordinates
        uint h = v.x * 0x8da6b343u ^ v.y * 0xd8163841u ^ seed * 0xcb1ab31fu;
        h ^= h >> 15; h *= 0x2c1b3c6du; h ^= h >> 12; h *= 0x297a2d39u; h ^= h >> 15;
        return float(h) / 4294967295.0;
    }
    kernel void nebula(texture2d<float,access::sample> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]],
                       constant ShaderParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 pos = float2(gid);
        float t = p.a.z;
        float2 uv = (pos - p.b.xy) / p.a.y * p.c.z + float2(fmod(p.c.y * 17.13, 97.0), fmod(p.c.y * 7.31, 89.0)); // small offsets keep float precision
        float2 q = float2(fbm(uv + float2(0.0, 0.11 * t)), fbm(uv + float2(5.2, 1.3) - 0.09 * t));
        float2 r = float2(fbm(uv + p.c.x * q + float2(1.7, 9.2) + 0.15 * t), fbm(uv + p.c.x * q + float2(8.3, 2.8) - 0.12 * t));
        float gas = fbm(uv + p.c.x * r);
        float fil = ridged(uv * 1.7 + 2.2 * r + 0.05 * t);
        float d = p.b.z > 0.0 ? length(pos - p.b.xy) / p.b.z : 0.0;
        float edge = p.b.w * (0.7 + 0.6 * q.x);                         // ragged rim, grown by reveal
        float env = p.b.z > 0.0 ? smoothstep(edge, edge * 0.45, d) : 1.0;
        float3 col = mix(p.d.rgb, p.e.rgb, smoothstep(0.45, 0.8, gas)) * smoothstep(0.35, 0.75, gas) * 0.7;
        float strand = smoothstep(0.62, 0.92, fil / 0.97);                  // thin bright ridges of the warped field
        col += p.f.rgb * strand * strand * p.c.w * smoothstep(0.4, 0.65, gas) * 0.9;
        col += p.e.w * float3(0.25, 0.5, 1.0) * exp(-d * d * 9.0) * (0.4 + 0.6 * gas);
        col *= env * p.a.w;
        uint2 cell = gid / 3u; uint sd = uint(p.c.y);
        col += float3(step(1.0 - p.d.w * 0.0015, uhash(cell, sd)) * (0.25 + 0.75 * pow(uhash(cell, sd + 7u), 3.0)));
    dst.write(float4(col, clamp(max(col.r, max(col.g, col.b)), 0.0, 1.0)), gid);
}
kernel void starfield(texture2d<float,access::sample> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]],
                      constant ShaderParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 pos = float2(gid);
    float s = p.a.y / 1080.0, t = p.a.z, ph = clamp(p.c.w, 0.0, 1.0), amt = p.b.w;
    uint sd = uint(p.c.y);
    float3 col = float3(0.0);
    for (int L = 0; L < 3; L++) {                                      // far -> near: denser, smaller, dimmer, slower
        float cellPx = (L == 0 ? 24.0 : (L == 1 ? 44.0 : 82.0)) * s;
        float keep = p.c.z * (L == 0 ? 0.5 : (L == 1 ? 0.32 : 0.2));
        float2 off = float2(6.0 + 16.0 * float(L), 2.0 + 5.0 * float(L)) * t * s;
        float2 q = (pos + off) / cellPx;
        int2 base = int2(floor(q));
        uint ls = sd + uint(L) * 101u;
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            int2 ci = base + int2(dx, dy);
            uint2 cell = uint2(ci + int2(8192));
            if (uhash(cell, ls) > keep) continue;
            float2 sp = (float2(ci) + 0.15 + 0.7 * float2(uhash(cell, ls + 1u), uhash(cell, ls + 2u))) * cellPx - off;
            float2 v = pos - sp; float d = length(v);
            if (d > 40.0 * s) continue;
            float mag = pow(uhash(cell, ls + 3u), 2.5);                // most stars faint, a few bright
            float r = (0.6 + 0.45 * float(L) + 1.5 * mag) * s;
            float tw = 1.0 - p.c.x * 0.5 * (1.0 + sin(t * (1.2 + 3.5 * uhash(cell, ls + 4u)) + 6.2832 * uhash(cell, ls + 5u)));
            float b = (0.25 + 0.75 * mag) * (0.5 + 0.3 * float(L)) * tw;
            float glow = exp(-d * d / (r * r)) + 0.1 * exp(-d / (r * 4.0));
            if (L == 2 && mag > 0.45) {                                 // diffraction spikes on the bright near stars
                float2 a = fabs(v); float len = 20.0 * s * mag;
                glow += 0.4 * (exp(-a.y / (0.7 * s)) * exp(-a.x / len) + exp(-a.x / (0.7 * s)) * exp(-a.y / len));
            }
            float hc = uhash(cell, ls + 6u);
            col += (hc < 0.72 ? p.d.rgb : (hc < 0.88 ? p.e.rgb : p.f.rgb)) * b * glow;
        }
    }
    // Beat pulse: every star swells as the beat lands and settles; a soft light ring runs out from the centre.
    float dc = length(pos - p.b.xy), fall = (1.0 - ph) * (1.0 - ph);
    float ring = exp(-pow((dc - ph * 0.75 * length(p.a.xy)) / (110.0 * s), 2.0)) * (1.0 - ph);
    col *= p.a.w * (1.0 + amt * (0.6 * fall + 1.4 * ring));
    if (p.b.z > 0.0) col *= smoothstep(p.b.z, p.b.z * 0.6, dc);
    dst.write(float4(col, clamp(max(col.r, max(col.g, col.b)), 0.0, 1.0)), gid);
}
"""
}
