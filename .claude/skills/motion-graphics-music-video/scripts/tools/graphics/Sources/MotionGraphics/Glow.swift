import Foundation
import CoreGraphics
import CoreImage

/// GPU neon for Canvas (`gpuGlow`). A CPU shadow blur per glowing mark (CGContext.setShadow, vImage convolution) was most of a
/// frame's render time. Instead, halo sources are filled unblurred into a few layers by blur size: σ 1, 2, 4 … 64 output px, a halo
/// between two sizes split across both (in log space), each layer at a resolution where its blur is ~2.5 px. Later marks without
/// glow knock their footprint out of the layers, so foreground shapes still hide the halos behind them. `image()` blurs every touched
/// layer once with Core Image (on the GPU) and stacks them; the caller composites that over the frame in sRGB, as CG blended the shadows.
public final class GlowLayers {
    final class Layer {
        let sigma: Double, scale: Double, context: CGContext    // sigma in output px; scale = layer px per output px
        var dirty = false
        init(sigma: Double, scale: Double, context: CGContext) { self.sigma = sigma; self.scale = scale; self.context = context }
    }
    /// CG shadow `blur` → Gaussian σ in device px (measured: a 1 px line under blur 10 / 40 spreads to σ 4.5 / 17.8).
    public static let sigmaPerShadowBlur = 0.45
    public static let sigmas: [Double] = [1, 2, 4, 8, 16, 32, 64]
    let layers: [Layer], pixelScale: Double, width: Int, height: Int
    typealias Clip = (path: CGPath, ctm: CGAffineTransform, evenOdd: Bool)

    init(width: Int, height: Int, pixelScale: Double) throws {
        self.width = width; self.height = height; self.pixelScale = pixelScale
        layers = try GlowLayers.sigmas.map { sigma in
            let s = min(1, 2.5/sigma), w = max(1, Int((Double(width)*s).rounded(.up))), h = max(1, Int((Double(height)*s).rounded(.up)))
            guard let c = CGContext(data:nil, width:w, height:h, bitsPerComponent:8, bytesPerRow:w*4, space:Color.space,
                                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw GraphicsError.unavailable("Could not allocate glow layer") }
            c.scaleBy(x:CGFloat(s/pixelScale), y:CGFloat(s/pixelScale))   // device px (the canvas's base space) → layer px
            return Layer(sigma:sigma, scale:s, context:c)
        }
    }
    func reset() {
        for l in layers where l.dirty { l.context.clear(CGRect(x:0, y:0, width:Double(width)*pixelScale, height:Double(height)*pixelScale)); l.dirty = false }
    }
    /// Adds a halo source: `body` adds and paints a path in user space (`ctm` maps it to device px) with the colours already set.
    /// `sigma` is the blur in device px.
    func halo(sigma: Double, color: Color, alpha: Double, ctm: CGAffineTransform, clips: [Clip], _ body: (CGContext) -> Void) {
        guard alpha > 0.002 else { return }
        let x = log2(min(GlowLayers.sigmas.last!, max(1, sigma/pixelScale))), i = min(layers.count-2, Int(x)), u = x-Double(i)
        for (layer, weight) in [(layers[i], 1-u), (layers[i+1], u)] where weight > 0.01 {
            draw(layer, ctm:ctm, clips:clips, mode:.normal) { c in
                let cg = Color(color.r, color.g, color.b, min(1, alpha*weight)).cgColor
                c.setFillColor(cg); c.setStrokeColor(cg); body(c)
            }
            layer.dirty = true
        }
    }
    /// Erases a mark's footprint (painted by `body` with its own alphas) from every touched layer.
    func knockout(alpha: Double, ctm: CGAffineTransform, clips: [Clip], _ body: (CGContext) -> Void) {
        guard alpha > 0.002 else { return }
        for layer in layers where layer.dirty { draw(layer, ctm:ctm, clips:clips, mode:.destinationOut) { c in c.setAlpha(alpha); body(c) } }
    }
    private func draw(_ layer: Layer, ctm: CGAffineTransform, clips: [Clip], mode: CGBlendMode, _ body: (CGContext) -> Void) {
        let c = layer.context
        c.saveGState(); defer { c.restoreGState() }
        for clip in clips {
            c.concatenate(clip.ctm); c.addPath(clip.path); c.clip(using:clip.evenOdd ? .evenOdd : .winding)
            c.concatenate(clip.ctm.inverted())   // back to the base space; the clip stays
        }
        c.concatenate(ctm); c.setBlendMode(mode); body(c)
    }
    /// The blurred, stacked halos for this frame in output pixels (raw sRGB values: no colour space), or nil if nothing glowed.
    public func image() -> CIImage? {
        var out: CIImage?
        for l in layers where l.dirty {
            guard let cg = l.context.makeImage() else { continue }
            let halo = CIImage(cgImage:cg, options:[.colorSpace:NSNull()])
                .applyingGaussianBlur(sigma:l.sigma*l.scale)
                .transformed(by:CGAffineTransform(scaleX:1/l.scale, y:1/l.scale))
            out = out.map { halo.composited(over:$0) } ?? halo
        }
        return out?.cropped(to:CGRect(x:0, y:0, width:width, height:height))
    }
}
