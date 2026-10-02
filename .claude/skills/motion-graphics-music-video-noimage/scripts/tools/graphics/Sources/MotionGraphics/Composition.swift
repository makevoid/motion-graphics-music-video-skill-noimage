import Foundation
import CoreImage
import CoreGraphics

/// Layers build a lazy image graph; only the final encoder/preview materializes it.
/// Each composition is single-thread confined. Consume the result before advancing its sources.
open class Layer {
    public var opacity = 1.0, start = 0.0, end = Double.infinity
    public var blend: CompositeMode = .normal
    /// Affine transform in the composition's top-left pixel coordinate system.
    public var transform = CGAffineTransform.identity
    public var effects = EffectChain()
    public var mask: CIImage?
    public var update: ((Layer,FrameTime) -> Void)?
    public init() {}
    open func image(at time: FrameTime) throws -> CIImage { throw GraphicsError.invalid("Subclass Layer.image(at:)") }
}
public final class VectorLayer: Layer {
    public let scene: Scene, canvas: Canvas
    public init(_ scene: Scene, width: Int, height: Int) throws {
        self.scene = scene; canvas = try Canvas(width:width,height:height); super.init()
    }
    public override func image(at time: FrameTime) throws -> CIImage {
        try scene.draw(on:canvas,at:time); return CIImage(cgImage:try canvas.snapshot())
    }
}
public final class StillLayer: Layer {
    public let source: CIImage
    public init(_ image: CIImage) { source = image; super.init() }
    public convenience init(_ asset: ImageAsset) { self.init(CIImage(cgImage:asset.image)) }
    public override func image(at time: FrameTime) -> CIImage { source }
}
public final class MovieLayer: Layer {
    public let source: VideoSource, size: CGSize
    public var sourceOffset = 0.0
    public init(url: URL, width: Int, height: Int) async throws {
        source = try await VideoSource(url:url); size = CGSize(width:width,height:height); super.init()
    }
    public override func image(at time: FrameTime) throws -> CIImage { try source.image(at:max(0,time.seconds-start+sourceOffset),size:size) }
}
/// Wrap a Metal particle/3D target or procedural CIImage without a CPU image readback.
public final class GeneratedLayer: Layer {
    private let generate: (FrameTime) throws -> CIImage
    public init(_ generate: @escaping (FrameTime) throws -> CIImage) { self.generate = generate; super.init() }
    public override func image(at time: FrameTime) throws -> CIImage { try generate(time) }
}
public final class Composition {
    public let compositor: Compositor
    public var layers: [Layer] = []
    public var background: Color = .clear
    public var effects = EffectChain()
    public init(width: Int, height: Int) throws { compositor = try Compositor(width:width,height:height) }
    public func image(at time: FrameTime) throws -> CIImage {
        var image = CIImage(color:CIColor(cgColor:background.cgColor)).cropped(to:compositor.extent)
        let flip = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:compositor.extent.height)
        for layer in layers where time.seconds >= layer.start && time.seconds < layer.end {
            layer.update?(layer,time); guard layer.opacity > 0 else { continue }
            let source = try layer.effects.apply(layer.image(at:time),at:time)
                .transformed(by:flip.concatenating(layer.transform).concatenating(flip))
            image = compositor.composite(source,over:image,mode:layer.blend,opacity:layer.opacity,mask:layer.mask)
        }
        return try effects.apply(image,at:time)
    }
}
public extension ImageAsset {
    /// Explicit static-layer cache. Rebuild after changing its source nodes; never caches an animation implicitly.
    static func rasterize(_ node: Node, width: Int, height: Int, at time: FrameTime = FrameTime(frame:0,fps:24)) throws -> ImageAsset {
        let canvas = try Canvas(width:width,height:height)
        try node.render(on:canvas,at:time); return ImageAsset(image:try canvas.snapshot())
    }
}
