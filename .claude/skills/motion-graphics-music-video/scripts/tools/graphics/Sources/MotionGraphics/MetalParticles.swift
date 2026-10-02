import Foundation
import Metal
import CoreImage
import simd

/// One immutable particle buffer, six vertices per instance, one draw call per field.
/// Motion is evaluated in the vertex shader from absolute time, so seeking is deterministic.
public final class MetalParticles {
    public struct Particle {
        public var origin: SIMD2<Float>, velocity: SIMD2<Float>
        public var color: SIMD4<Float>
        public var size: Float, phase: Float, life: Float, padding: Float = 0
        public init(origin: SIMD2<Float>, velocity: SIMD2<Float>, color: SIMD4<Float>, size: Float, phase: Float = 0, life: Float = 5) {
            self.origin = origin; self.velocity = velocity; self.color = color; self.size = size; self.phase = phase; self.life = life
        }
    }
    private let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState, buffer: MTLBuffer
    private let texture: MTLTexture, count: Int
    public init(width: Int, height: Int, particles: [Particle], device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard width > 0, height > 0, !particles.isEmpty, particles.allSatisfy({ $0.life > 0 && $0.life.isFinite && $0.size >= 0 }) else { throw GraphicsError.invalid("Invalid particle field") }
        guard let device, let queue = device.makeCommandQueue() else { throw GraphicsError.unavailable("Metal device unavailable") }
        self.device = device; self.queue = queue; count = particles.count
        let library = try device.makeLibrary(source:Self.shader,options:nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name:"particleVertex"); descriptor.fragmentFunction = library.makeFunction(name:"particleFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .rgba16Float; attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one; attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor:descriptor)
        guard let buffer = particles.withUnsafeBytes({ device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }) else { throw GraphicsError.unavailable("Particle buffer allocation failed") }
        self.buffer = buffer
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
        desc.usage = [.renderTarget,.shaderRead]; desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor:desc) else { throw GraphicsError.unavailable("Particle texture allocation failed") }; self.texture = texture
    }
    /// The returned CIImage references the reused texture; consume it before rendering the next frame.
    public func render(at time: Double) throws -> CIImage {
        guard let command = queue.makeCommandBuffer() else { throw GraphicsError.unavailable("Metal command allocation failed") }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor:pass) else { throw GraphicsError.unavailable("Metal encoder allocation failed") }
        var uniforms = SIMD4<Float>(Float(texture.width),Float(texture.height),Float(time),0)
        encoder.setRenderPipelineState(pipeline); encoder.setVertexBuffer(buffer,offset:0,index:0)
        encoder.setVertexBytes(&uniforms,length:MemoryLayout<SIMD4<Float>>.stride,index:1)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:count); encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        guard let image = CIImage(mtlTexture:texture,options:[.colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!]) else { throw GraphicsError.io("Cannot wrap particle texture") }
        // Metal render targets have a top-left origin; CI images have a bottom-left origin.
        return image.transformed(by:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:CGFloat(texture.height)))
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Particle { float2 origin; float2 velocity; float4 color; float size; float phase; float life; float padding; };
    struct Vertex { float4 position [[position]]; float2 uv; float4 color; };
    vertex Vertex particleVertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device Particle *p [[buffer(0)]], constant float4 &u [[buffer(1)]]) {
        const float2 corners[6] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
        Particle a = p[iid]; float age = fmod(max(0.0f,u.z)+a.phase,a.life);
        float2 center = a.origin+a.velocity*age;
        center = center-floor(center/u.xy)*u.xy;
        float2 pixel = center+corners[vid]*a.size;
        Vertex out; out.position = float4(pixel.x/u.x*2-1,1-pixel.y/u.y*2,0,1);
        out.uv = corners[vid]; out.color = a.color;
        out.color.a *= sin(M_PI_F*age/a.life); return out;
    }
    fragment float4 particleFragment(Vertex in [[stage_in]]) {
        float alpha = (1-smoothstep(0.0f,1.0f,length(in.uv)))*in.color.a;
        return float4(in.color.rgb*alpha,alpha);
    }
    """
}

/// Reusable custom compute stage: source texture(0), destination texture(1), float4(width,height,time,0) buffer(0).
/// Supply MSL source with a kernel named by `function`; no shader compilation in the frame loop.
public final class MetalEffect: ImageEffect {
    private let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLComputePipelineState, context: CIContext
    private let input: MTLTexture, output: MTLTexture
    public init(width: Int, height: Int, source: String, function: String, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw GraphicsError.unavailable("Metal unavailable") }
        guard width > 0, height > 0 else { throw GraphicsError.invalid("Invalid effect size") }
        self.device = device; self.queue = queue; context = CIContext(mtlDevice:device)
        let library = try device.makeLibrary(source:source,options:nil)
        guard let kernel = library.makeFunction(name:function) else { throw GraphicsError.invalid("Missing Metal function \(function)") }
        pipeline = try device.makeComputePipelineState(function:kernel)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
        desc.usage = [.shaderRead,.shaderWrite,.renderTarget]; desc.storageMode = .private
        guard let a = device.makeTexture(descriptor:desc), let b = device.makeTexture(descriptor:desc) else { throw GraphicsError.unavailable("Metal effect allocation failed") }
        input = a; output = b
    }
    public func apply(_ image: CIImage, at time: FrameTime) throws -> CIImage {
        guard let command = queue.makeCommandBuffer() else { throw GraphicsError.unavailable("Metal command failed") }
        let bounds = CGRect(x:0,y:0,width:input.width,height:input.height)
        context.render(image,to:input,commandBuffer:command,bounds:bounds,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        guard let encoder = command.makeComputeCommandEncoder() else { throw GraphicsError.unavailable("Metal compute failed") }
        encoder.setComputePipelineState(pipeline); encoder.setTexture(input,index:0); encoder.setTexture(output,index:1)
        var u = SIMD4<Float>(Float(input.width),Float(input.height),Float(time.seconds),0)
        encoder.setBytes(&u,length:MemoryLayout<SIMD4<Float>>.stride,index:0)
        let w = pipeline.threadExecutionWidth, h = max(1,pipeline.maxTotalThreadsPerThreadgroup/w)
        encoder.dispatchThreads(MTLSize(width:input.width,height:input.height,depth:1),threadsPerThreadgroup:MTLSize(width:w,height:h,depth:1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        guard let result = CIImage(mtlTexture:output,options:[.colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!]) else { throw GraphicsError.io("Cannot wrap compute output") }
        return result
    }
}
