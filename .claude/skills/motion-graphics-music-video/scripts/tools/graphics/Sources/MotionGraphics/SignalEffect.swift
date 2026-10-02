import Foundation
import CoreImage

/// Fused grain, scanlines, and chromatic separation in one GPU pass. Premultiplied alpha is preserved.
public final class SignalEffect: ImageEffect {
    private let effect: MetalEffect
    public init(width: Int, height: Int, grain: Double = 0.15, scanlines: Double = 0.12, chromaticPixels: Double = 2) throws {
        guard grain.isFinite, scanlines.isFinite, chromaticPixels.isFinite,
              (0...1).contains(grain), (0...1).contains(scanlines), abs(chromaticPixels) <= 1024 else { throw GraphicsError.invalid("Invalid signal effect parameters") }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void signal(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]], constant float4 &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
            if (p.x >= src.get_width() || p.y >= src.get_height()) return;
            int shift = \(Int(chromaticPixels.rounded()));
            uint2 left = uint2(clamp(int(p.x)-shift,0,int(src.get_width())-1),p.y);
            uint2 right = uint2(clamp(int(p.x)+shift,0,int(src.get_width())-1),p.y);
            float4 c = src.read(p), r = src.read(right), b = src.read(left);
            // Unpremultiply sampled channels, then reapply the destination's coverage.
            float red = r.a > 0 ? r.r/r.a : 0, blue = b.a > 0 ? b.b/b.a : 0;
            c.r = red*c.a; c.b = blue*c.a;
            uint hash = p.x*1973u+p.y*9277u+uint(floor(u.z*1000))*26699u+911u;
            hash = (hash^(hash>>16))*2246822519u; hash = (hash^(hash>>13))*3266489917u; hash ^= hash>>16;
            float noise = float(hash&65535u)/65535.0f;
            float coverage = 1.0f-float(\(grain))*noise*noise;
            c *= coverage;
            c.rgb *= 1.0f-float(\(scanlines))*(0.5f+0.5f*sin(float(p.y)*M_PI_F*0.5f));
            dst.write(c,p);
        }
        """
        effect = try MetalEffect(width:width,height:height,source:source,function:"signal")
    }
    public func apply(_ image: CIImage, at time: FrameTime) throws -> CIImage { try effect.apply(image,at:time) }
}
