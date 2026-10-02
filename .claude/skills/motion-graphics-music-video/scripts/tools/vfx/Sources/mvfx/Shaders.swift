import Foundation
import MotionGraphics

// Metal Shading Language kernels for MetalShader (frame -> MTLTexture -> kernel -> CIImage). Params (pixels, top-left origin):
//   a = (width, height, seconds, amount)   b = (centre x, centre y, radius, angle radians)   c = (progress, seed, k0, k1)
// Colours are linear and premultiplied; `at(src, p)` samples bilinearly with clamped edges.
enum Shaders {
    static let functions = ["shockwave", "streaks", "lens", "heat"]
    static let source = """
    // An expanding refraction ring (distortion): pixels in the ring's band are pushed along the radius, R/G/B by slightly
    // different amounts, and the ring catches a little light. radius = final ring radius as a fraction of the frame diagonal.
    kernel void shockwave(texture2d<float,access::sample> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]],
                          constant ShaderParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 pos = float2(gid), c = p.b.xy;
        float pr = p.c.x, amt = p.a.w, diag = length(p.a.xy);
        float ringR = pr * p.b.z * diag, band = max(12.0, 0.045 * p.a.y) * (0.6 + 0.9 * pr);
        float2 d = pos - c; float r = length(d); float2 dir = r > 0.0 ? d / r : float2(0.0);
        float x = (r - ringR) / band;
        float4 col = at(src, pos);
        if (fabs(x) < 1.0) {
            float fade = (1.0 - pr) * amt, off = sin(x * M_PI_F) * fade * band * 0.3;
            float4 g = at(src, pos - dir * off);
            col = float4(at(src, pos - dir * off * 1.25).r, g.g, at(src, pos - dir * off * 0.75).b, g.a);
            float edge = 1.0 - fabs(x);
            col.rgb *= 1.0 + 0.12 * fade * edge * edge;   // the ring catches light where there is light (black stays black)
        }
        dst.write(col, gid);
    }

    // Streak source: light above `thr` with dark on both sides along some axis (a high-pass), so thin lines, dots and small
    // type flare while bright areas and their edges (big type, fills) don't smear slabs across the frame.
    static inline float3 spark(texture2d<float,access::sample> src, float2 q, float2 dir, float thr) {
        float2 n = float2(-dir.y, dir.x) * 5.0, m = dir * 5.0;
        float3 c = max(at(src, q).rgb - thr, 0.0);
        float3 across = max(max(at(src, q + n).rgb - thr, 0.0), max(at(src, q - n).rgb - thr, 0.0));
        float3 along = max(max(at(src, q + m).rgb - thr, 0.0), max(at(src, q - m).rgb - thr, 0.0));
        return max(c - min(across, along), 0.0);   // dark on both sides along some axis = thinner than ~10 px: lines and dots flare
    }

    // Anamorphic lens streaks (layer effect): light above `threshold` (k0) bleeds `radius` px along `angle` both ways, falling
    // off exponentially, cooled toward blue like a cylindrical lens. Thin neon lines get long thin flares; flat areas barely do.
    kernel void streaks(texture2d<float,access::sample> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]],
                        constant ShaderParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 pos = float2(gid), dir = float2(cos(p.b.w), sin(p.b.w));
        float thr = p.c.z, len = p.b.z;
        float3 acc = float3(0.0);
        const int N = 40;
        for (int i = 1; i <= N; i++) {
            float t = float(i) / float(N), w = exp(-4.5 * t);
            float2 o = dir * t * len;
            acc += (spark(src, pos + o, dir, thr) + spark(src, pos - o, dir, thr)) * w;
        }
        acc *= p.a.w * 0.12;
        float lum = dot(acc, float3(0.333));
        float3 tint = mix(acc, lum * float3(0.5, 0.8, 1.5), 0.6);
        float4 col = at(src, pos);
        col.rgb += tint;
        dst.write(col, gid);
    }

    // Lens (distortion + colour): barrel distortion about the centre with per-channel dispersion (k0) and a vignette (k1);
    // zoomed so the corners stay filled.
    kernel void lens(texture2d<float,access::sample> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]],
                     constant ShaderParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 pos = float2(gid), c = p.b.xy;
        float half_diag = 0.5 * length(p.a.xy), k = p.a.w, disp = p.c.z;
        float2 q = (pos - c) / half_diag; float r2 = dot(q, q);
        float zoom = 1.0 + max(k, 0.0) * 0.55;
        float2 base = q / zoom;
        float4 g = at(src, c + base * (1.0 + k * r2) * half_diag);
        float red = at(src, c + base * (1.0 + k * (1.0 + disp) * r2) * half_diag).r;
        float blue = at(src, c + base * (1.0 + k * (1.0 - disp) * r2) * half_diag).b;
        float4 col = float4(red, g.g, blue, g.a);
        col.rgb *= 1.0 - p.c.w * smoothstep(0.35, 1.25, r2);
        dst.write(col, gid);
    }

    // Heat shimmer (distortion): rising, interfering sine refraction, `amount` px, optionally limited to a soft disc of
    // `radius` px around the centre (radius 0 = whole frame).
    kernel void heat(texture2d<float,access::sample> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]],
                     constant ShaderParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 pos = float2(gid);
        float t = p.a.z, s = 1080.0 / p.a.y;
        float mask = p.b.z > 0.0 ? 1.0 - smoothstep(p.b.z * 0.35, p.b.z, length(pos - p.b.xy)) : 1.0;
        float2 q = pos * s + float2(0.0, t * 140.0);      // pattern rises
        float2 o = float2(sin(q.y * 0.045 + sin(q.x * 0.013 + t * 1.7) * 2.2) + 0.5 * sin(q.y * 0.11 + q.x * 0.02),
                          0.6 * cos(q.x * 0.031 + q.y * 0.017 + t * 2.3));
        float4 col = at(src, pos + o * p.a.w * mask / s);
        dst.write(col, gid);
    }
    """
}
