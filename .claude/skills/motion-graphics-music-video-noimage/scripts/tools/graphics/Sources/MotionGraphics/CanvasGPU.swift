import Foundation
import CoreGraphics
import Metal

/// The canvas's pixels in a Metal buffer shared with the CPU (unified memory): Core Graphics rasterizes into it, and GPU pictures
/// (shader nodes) are blended straight into it between marks — the same z-order as drawing a CGImage, without reading the
/// picture back or converting it on the CPU.
final class CanvasGPU {
    let device: MTLDevice, queue: MTLCommandQueue, buffer: MTLBuffer, pipeline: MTLComputePipelineState
    let memory: UnsafeMutableRawPointer, bytesPerRow: Int, width: Int, height: Int

    /// width/height in device pixels; nil when Metal is unavailable.
    init?(width: Int, height: Int) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let page = Int(getpagesize()), align = max(16, device.minimumLinearTextureAlignment(for:.rgba8Unorm))
        let rowBytes = (width*4+align-1)/align*align, length = (rowBytes*height+page-1)/page*page
        var raw: UnsafeMutableRawPointer?
        guard posix_memalign(&raw, page, length) == 0, let memory = raw else { return nil }
        memset(memory, 0, length)
        guard let buffer = device.makeBuffer(bytesNoCopy:memory, length:length, options:.storageModeShared, deallocator:{ p, _ in free(p) }),
              let library = try? device.makeLibrary(source:CanvasGPU.source, options:nil), let fn = library.makeFunction(name:"over"),
              let pipeline = try? device.makeComputePipelineState(function:fn) else { free(memory); return nil }
        self.device = device; self.queue = queue; self.buffer = buffer; self.pipeline = pipeline
        self.memory = memory; bytesPerRow = rowBytes; self.width = width; self.height = height
    }

    /// Blends `texture` (linear, premultiplied) over the pixels in `region` (buffer px, row 0 = top), sampling it at
    /// `toTexel` (buffer px -> texel), in sRGB like Core Graphics.
    func composite(_ texture: MTLTexture, toTexel m: CGAffineTransform, region: (x: Int, y: Int, w: Int, h: Int), opacity: Double) throws {
        guard region.w > 0, region.h > 0, let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return }
        var p = Params(a:Float(m.a), b:Float(m.b), c:Float(m.c), d:Float(m.d), tx:Float(m.tx), ty:Float(m.ty), opacity:Float(opacity),
                       x0:UInt32(region.x), y0:UInt32(region.y), w:UInt32(region.w), h:UInt32(region.h), stride:UInt32(bytesPerRow/4))
        encoder.setComputePipelineState(pipeline); encoder.setTexture(texture, index:0); encoder.setBuffer(buffer, offset:0, index:0)
        encoder.setBytes(&p, length:MemoryLayout<Params>.stride, index:1)
        let tw = pipeline.threadExecutionWidth, th = max(1, pipeline.maxTotalThreadsPerThreadgroup/tw)
        encoder.dispatchThreads(MTLSize(width:region.w, height:region.h, depth:1), threadsPerThreadgroup:MTLSize(width:tw, height:th, depth:1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
    }

    struct Params { var a, b, c, d, tx, ty, opacity: Float; var x0, y0, w, h, stride: UInt32 }
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Params { float a, b, c, d, tx, ty, opacity; uint x0, y0, w, h, stride; };
    constexpr sampler texels(coord::pixel, address::clamp_to_zero, filter::linear);
    static inline float enc(float x) { x = clamp(x, 0.0, 1.0); return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055; }
    kernel void over(texture2d<float, access::sample> src [[texture(0)]], device uchar4 *dst [[buffer(0)]],
                     constant Params &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.w || gid.y >= p.h) return;
        uint x = p.x0 + gid.x, y = p.y0 + gid.y;
        float2 q = float2(x, y) + 0.5;
        float4 s = src.sample(texels, float2(p.a * q.x + p.c * q.y + p.tx, p.b * q.x + p.d * q.y + p.ty));
        if (s.a <= 0.0) return;
        float a = min(s.a, 1.0) * p.opacity;
        float3 c = s.rgb / s.a;                              // unpremultiply, encode sRGB, premultiply: as CG draws the image
        float4 o = float4(enc(c.r), enc(c.g), enc(c.b), 1.0) * a;
        device uchar4 &px = dst[y * p.stride + x];
        float4 r = o + float4(px) / 255.0 * (1.0 - o.a);
        px = uchar4(round(clamp(r, 0.0, 1.0) * 255.0));
    }
    """
}
