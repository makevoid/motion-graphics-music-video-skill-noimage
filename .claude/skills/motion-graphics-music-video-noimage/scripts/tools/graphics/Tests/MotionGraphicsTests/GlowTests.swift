import XCTest
import CoreGraphics
import CoreImage
@testable import MotionGraphics

final class GlowTests: XCTestCase {
    /// Draws `body` on black and flattens the frame as the CLI does (GPU halos composited in sRGB); returns RGBA8 bytes.
    func render(gpu: Bool, width: Int = 400, height: Int = 200, supersample: Int = 1, _ body: (Canvas) throws -> Void) throws -> (bytes: [UInt8], width: Int) {
        let canvas = try Canvas(width:width,height:height,supersample:supersample,gpu:gpu), compositor = try Compositor(width:width,height:height)
        canvas.clear(.black); try body(canvas)
        var image = CIImage(cgImage:try canvas.snapshot())
        if supersample > 1 { image = image.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:1/Double(supersample),kCIInputAspectRatioKey:1.0]).cropped(to:compositor.extent) }
        if let glow = canvas.glowImage(), let srgb = image.matchedFromWorkingSpace(to:Color.space) { image = glow.composited(over:srgb).matchedToWorkingSpace(from:Color.space)! }
        let cg = try compositor.image(image)
        let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:Color.space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
        return (Array(UnsafeBufferPointer(start:ctx.data!.assumingMemoryBound(to:UInt8.self),count:width*height*4)), width)
    }
    func row(_ r: (bytes: [UInt8], width: Int), y: Int, channel: Int, _ xs: StrideTo<Int>) -> [Int] { xs.map { Int(r.bytes[(y*r.width+$0)*4+channel]) } }

    func neon(_ c: Canvas) { c.glow = 12; c.style = Style(fill:nil,stroke:Color(0.2,0.9,1),lineWidth:2); c.line(200,20,200,180) }

    func testGPUGlowMatchesTheCoreGraphicsShadowHalo() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        for ss in [1, 2] {
            let cg = try render(gpu:false,supersample:ss,neon), gpu = try render(gpu:true,supersample:ss,neon)
            let a = row(cg,y:100,channel:1,stride(from:150,to:251,by:2)), b = row(gpu,y:100,channel:1,stride(from:150,to:251,by:2))
            for (x,y) in zip(a,b) { XCTAssertEqual(Double(x),Double(y),accuracy:max(12,Double(x)*0.25)) }   // same halo, within a few levels
            XCTAssertEqual(Double(b.reduce(0,+)),Double(a.reduce(0,+)),accuracy:Double(a.reduce(0,+))*0.12)  // same light overall
            XCTAssertGreaterThan(b[20],20)                                                                // 10 px out it still glows
        }
    }
    func testLaterOpaqueMarksHideTheGPUHaloBehindThem() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let draw: (Canvas) -> Void = { c in self.neon(c); c.glow = 0; c.style = Style(fill:Color(0.1,0.1,0.1)); c.rect(204,0,196,200) }
        for gpu in [false, true] {
            let r = try render(gpu:gpu,draw)
            XCTAssertEqual(row(r,y:100,channel:1,stride(from:230,to:231,by:1))[0],26,accuracy:3)    // inside the box: its own grey, no halo
            XCTAssertGreaterThan(row(r,y:100,channel:1,stride(from:190,to:191,by:1))[0],30)          // the uncovered side still glows
        }
    }
    func testGPUCanvasMatchesCoreGraphicsForGroupOpacityAndShaders() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glow-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at:url) }
        // A nebula under a half-transparent group of overlapping shapes, a translucent leaf shader and a rotated, scaled one.
        try Data("""
        {"background":"#101018","nodes":[
          {"type":"shader","shader":"nebula","width":400,"height":200,"seed":2,"stars":0.5},
          {"type":"group","opacity":0.5,"x":40,"y":30,"children":[{"type":"rect","width":120,"height":80,"fill":"#FF5A1F"},
                                                                  {"type":"rect","x":60,"y":40,"width":120,"height":80,"fill":"#2EE6FF"}]},
          {"type":"shader","shader":"starfield","x":220,"y":20,"width":160,"height":160,"opacity":0.6,"stars":1,"seed":5},
          {"type":"group","x":300,"y":150,"rotation":0.4,"scaleX":0.5,"scaleY":0.5,"children":[{"type":"shader","shader":"nebula","width":120,"height":90,"seed":7}]},
          {"type":"rect","x":0,"y":170,"width":400,"height":30,"fill":"#000000"}]}
        """.utf8).write(to:url)
        let doc = try SceneDocument(url:url,width:400,height:200)
        let cg = try render(gpu:false) { c in try doc.scene.draw(on:c,at:FrameTime(frame:12,fps:24)) }
        let gpu = try render(gpu:true) { c in try doc.scene.draw(on:c,at:FrameTime(frame:12,fps:24)) }
        var worst = 0, total = 0
        for i in 0..<cg.bytes.count { let d = abs(Int(cg.bytes[i])-Int(gpu.bytes[i])); worst = max(worst,d); total += d }
        XCTAssertLessThan(Double(total)/Double(cg.bytes.count),0.6)   // the same picture ...
        XCTAssertLessThan(worst,40)                                   // ... up to resampling at a few edge pixels
        XCTAssertEqual(row(gpu,y:185,channel:0,stride(from:10,to:400,by:40)).max()!,0)   // the later black bar covers the shader
    }
}
