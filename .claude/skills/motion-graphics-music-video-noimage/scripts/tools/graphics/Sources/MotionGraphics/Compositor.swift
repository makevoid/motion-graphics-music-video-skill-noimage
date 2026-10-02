import Foundation
import CoreImage
import CoreVideo
import Metal

public enum CompositeMode: String, Codable, CaseIterable {
    case normal, screen, add, multiply, overlay, difference, exclusion, lighten, darken
    var filter: String {
        switch self {
        case .normal: return "CISourceOverCompositing"
        case .screen: return "CIScreenBlendMode"
        case .add: return "CIAdditionCompositing"
        case .multiply: return "CIMultiplyBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .difference: return "CIDifferenceBlendMode"
        case .exclusion: return "CIExclusionBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .darken: return "CIDarkenBlendMode"
        }
    }
}
public protocol ImageEffect { func apply(_ image: CIImage, at time: FrameTime) throws -> CIImage }
/// Compiled once; only parameters change per frame. Confine each effect to one render thread.
public final class FilterEffect: ImageEffect {
    private let filter: CIFilter
    public var parameters: [String:Any]
    public init(_ name: String, parameters: [String:Any] = [:]) throws {
        guard let f = CIFilter(name:name) else { throw GraphicsError.invalid("Unknown Core Image filter \(name)") }
        guard f.inputKeys.contains(kCIInputImageKey), parameters.keys.allSatisfy({ f.inputKeys.contains($0) && $0 != kCIInputImageKey }) else {
            throw GraphicsError.invalid("Invalid filter inputs for \(name)")
        }
        filter = f; self.parameters = parameters
    }
    public func apply(_ image: CIImage, at time: FrameTime) throws -> CIImage {
        guard parameters.keys.allSatisfy({ filter.inputKeys.contains($0) && $0 != kCIInputImageKey }) else { throw GraphicsError.invalid("Invalid effect parameters") }
        filter.setDefaults(); filter.setValue(image,forKey:kCIInputImageKey)
        for (key,value) in parameters { filter.setValue(value,forKey:key) }
        guard let out = filter.outputImage else { throw GraphicsError.invalid("Filter produced no output") }; return out
    }
}
public final class EffectChain: ImageEffect {
    public var effects: [ImageEffect]
    public init(_ effects: [ImageEffect] = []) { self.effects = effects }
    public func apply(_ image: CIImage, at time: FrameTime) throws -> CIImage {
        try effects.reduce(image) { try $1.apply($0,at:time) }.cropped(to:image.extent)
    }
}
public final class Compositor {
    private static let videoColorSpace = CVImageBufferCreateColorSpaceFromAttachments([
        kCVImageBufferColorPrimariesKey:kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey:kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey:kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ] as CFDictionary)!.takeRetainedValue()
    public let context: CIContext, device: MTLDevice?, extent: CGRect
    public var backend: String { device == nil ? "Core Image software" : "Core Image Metal" }
    public init(width: Int, height: Int, software: Bool = false, workingColorSpace: CGColorSpace = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!) throws {
        guard width > 0 && height > 0 else { throw GraphicsError.invalid("Invalid compositor size") }
        extent = CGRect(x:0,y:0,width:width,height:height)
        device = software ? nil : MTLCreateSystemDefaultDevice()
        let options: [CIContextOption:Any] = [.workingColorSpace:workingColorSpace, .outputColorSpace:Color.space, .cacheIntermediates:false]
        if let device { context = CIContext(mtlDevice:device,options:options) }
        else { context = CIContext(options:options.merging([.useSoftwareRenderer:true]) { _,new in new }) }
    }
    public func composite(_ foreground: CIImage, over background: CIImage, mode: CompositeMode = .normal, opacity: Double = 1, mask: CIImage? = nil) -> CIImage {
        var fg = foreground
        if opacity != 1 { fg = fg.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:min(1,max(0,opacity)))]) }
        if let mask { fg = fg.applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:extent),kCIInputMaskImageKey:mask]) }
        return fg.applyingFilter(mode.filter,parameters:[kCIInputBackgroundImageKey:background]).cropped(to:extent)
    }
    public func image(_ image: CIImage) throws -> CGImage {
        guard let out = context.createCGImage(image,from:extent,format:.RGBA8,colorSpace:Color.space) else { throw GraphicsError.io("Core Image render failed") }; return out
    }
    // Match VideoWriter's Rec.709 transfer metadata. Tagging sRGB bytes as Rec.709
    // changes midtones after a decode/encode round trip, even with no effects.
    public func render(_ image: CIImage, to buffer: CVPixelBuffer) {
        context.render(image,to:buffer,bounds:extent,colorSpace:Self.videoColorSpace)
    }
}
