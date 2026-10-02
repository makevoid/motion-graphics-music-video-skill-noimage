import Foundation
import CoreImage
import Metal

/// A library of Metal Shading Language compute kernels run on a frame: the CIImage is rendered into an MTLTexture, a kernel
/// writes a second texture, which is wrapped back as a CIImage. Kernels may sample anywhere (bilinear, edge-clamped), so one
/// mechanism covers colour, distortion and layer effects (SwiftUI's colorEffect/distortionEffect/layerEffect, offline).
///
/// Every kernel has this signature (the source is compiled at runtime, no build step):
///     kernel void name(texture2d<float,access::sample> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]],
///                      constant ShaderParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]])
/// with `struct ShaderParams { float4 a, b, c, d, e, f; }` filled from `params` (up to 24 floats, zero padded). Texture row 0 is the top
/// of the picture and colours are linear, premultiplied.
public final class MetalShader {
    public static let header = """
    #include <metal_stdlib>
    using namespace metal;
    struct ShaderParams { float4 a; float4 b; float4 c; float4 d; float4 e; float4 f; };
    constexpr sampler linearClamp(coord::pixel, address::clamp_to_edge, filter::linear);
    static inline float4 at(texture2d<float,access::sample> t, float2 p) { return t.sample(linearClamp, p + 0.5); }
    static inline float hash21(float2 p) { p = fract(p*float2(123.34,456.21)); p += dot(p,p+45.32); return fract(p.x*p.y); }

    """
    private let device: MTLDevice, queue: MTLCommandQueue, context: CIContext
    private var pipelines: [String:MTLComputePipelineState] = [:]
    private let input: MTLTexture, output: MTLTexture
    private let space = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    public let functions: [String]

    public init(width: Int, height: Int, source: String, functions: [String], device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw GraphicsError.unavailable("Metal unavailable") }
        guard width > 0, height > 0 else { throw GraphicsError.invalid("Invalid shader size") }
        self.device = device; self.queue = queue; self.functions = functions
        context = CIContext(mtlDevice:device,options:[.cacheIntermediates:false])
        let library = try device.makeLibrary(source:MetalShader.header + source,options:nil)
        for name in functions {
            guard let fn = library.makeFunction(name:name) else { throw GraphicsError.invalid("Missing Metal function \(name)") }
            pipelines[name] = try device.makeComputePipelineState(function:fn)
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
        desc.usage = [.shaderRead,.shaderWrite,.renderTarget]; desc.storageMode = .private
        guard let a = device.makeTexture(descriptor:desc), let b = device.makeTexture(descriptor:desc) else { throw GraphicsError.unavailable("Metal shader allocation failed") }
        input = a; output = b
    }

    /// Runs one kernel. The returned image is materialized (it does not alias the shared output texture), so passes chain.
    public func apply(_ function: String, to image: CIImage, params: [Float]) throws -> CIImage {
        CIImage(cgImage:try run(function,input:image,params:params))
    }
    /// Runs a generator kernel (one that ignores `src`, e.g. procedural gas or stars) and returns its picture.
    public func generate(_ function: String, params: [Float]) throws -> CGImage { try run(function,input:nil,params:params) }

    private func run(_ function: String, input image: CIImage?, params: [Float]) throws -> CGImage {
        guard let pipeline = pipelines[function] else { throw GraphicsError.invalid("Unknown shader \(function)") }
        guard params.count <= 24 else { throw GraphicsError.invalid("Shader params are at most 24 floats") }
        guard let command = queue.makeCommandBuffer() else { throw GraphicsError.unavailable("Metal command failed") }
        let w = input.width, h = input.height, bounds = CGRect(x:0,y:0,width:w,height:h)
        // Core Image's origin is bottom-left; flip so texture row 0 is the top of the frame, as cue coordinates are.
        let flip = CGAffineTransform(scaleX:1,y:-1).translatedBy(x:0,y:-CGFloat(h))
        if let image { context.render(image.transformed(by:flip),to:input,commandBuffer:command,bounds:bounds,colorSpace:space) }
        guard let encoder = command.makeComputeCommandEncoder() else { throw GraphicsError.unavailable("Metal compute failed") }
        encoder.setComputePipelineState(pipeline); encoder.setTexture(input,index:0); encoder.setTexture(output,index:1)
        var u = (params + Array(repeating:0,count:24-params.count))
        encoder.setBytes(&u,length:MemoryLayout<Float>.stride*24,index:0)
        let tw = pipeline.threadExecutionWidth, th = max(1,pipeline.maxTotalThreadsPerThreadgroup/tw)
        encoder.dispatchThreads(MTLSize(width:w,height:h,depth:1),threadsPerThreadgroup:MTLSize(width:tw,height:th,depth:1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        guard let wrapped = CIImage(mtlTexture:output,options:[.colorSpace:space]) else { throw GraphicsError.io("Cannot wrap shader output") }
        // Materialize now: the next pass reuses `output`.
        guard let cg = context.createCGImage(wrapped.transformed(by:flip),from:bounds,format:.RGBAh,colorSpace:space) else { throw GraphicsError.io("Shader readback failed") }
        return cg
    }
}
