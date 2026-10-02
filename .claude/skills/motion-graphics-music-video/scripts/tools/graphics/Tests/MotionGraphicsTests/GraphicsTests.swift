import XCTest
import CoreGraphics
import CoreImage
import AVFoundation
import Metal
@testable import MotionGraphics

final class GraphicsTests: XCTestCase {
    func pixel(_ canvas: Canvas, _ x: Int, _ y: Int) -> [UInt8] {
        let ptr = canvas.context.data!.assumingMemoryBound(to:UInt8.self)
        let index = y*canvas.context.bytesPerRow+x*4
        return (0..<4).map { ptr[index+$0] }
    }
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("graphics-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    func testPremultipliedAlphaAndTopLeftOrigin() throws {
        let c = try Canvas(width:32,height:32); c.clear(); c.style = Style(fill:Color(1,0,0,0.5)); c.rect(0,0,10,10)
        XCTAssertEqual(pixel(c,5,5)[0],128,accuracy:1); XCTAssertEqual(pixel(c,5,5)[3],128,accuracy:1)
        XCTAssertEqual(pixel(c,5,25)[3],0)
    }
    func testImageOrientationAndPNGAlphaRoundTrip() throws {
        let source = try Canvas(width:16,height:16); source.clear(); source.style.fill = Color(1,0,0); source.rect(0,0,16,4)
        let file = try temp().appendingPathComponent("alpha.png"); try source.writePNG(to:file)
        let result = try Canvas(width:16,height:16); result.image(try ImageAsset(url:file).image,in:CGRect(x:0,y:0,width:16,height:16))
        XCTAssertEqual(pixel(result,2,2),[255,0,0,255]); XCTAssertEqual(pixel(result,2,14)[3],0)
    }
    func testIsolatedGroupOpacityAndNestedTransforms() throws {
        let scene = Scene(), group = Group(); group.opacity = 0.5; group.position = CGPoint(x:3,y:4)
        try scene.root.add(group)
        for x in [0.0,5.0] { let n = ShapeNode(.rect(CGRect(x:x,y:0,width:10,height:10))); try group.add(n) }
        let c = try Canvas(width:32,height:32); try scene.draw(on:c,at:FrameTime(frame:0,fps:24))
        XCTAssertEqual(pixel(c,5,6)[3],128,accuracy:1); XCTAssertEqual(pixel(c,10,6)[3],128,accuracy:1)
        XCTAssertEqual(pixel(c,1,1)[3],0)
    }
    func testStateRestoreOnError() throws {
        let c = try Canvas(width:16,height:16)
        XCTAssertThrowsError(try c.withState { c in c.translate(10,10); c.style.fill = .black; throw GraphicsError.invalid("fixture") })
        XCTAssertEqual(c.style.fill,.white); c.rect(0,0,3,3); XCTAssertEqual(pixel(c,1,1),[255,255,255,255])
    }
    func testClippingAndContours() throws {
        let c = try Canvas(width:32,height:32), path = Path.rect(CGRect(x:0,y:0,width:30,height:30))
        path.cgPath.addRect(CGRect(x:10,y:10,width:10,height:10)); c.style.evenOdd = true; c.draw(path)
        XCTAssertEqual(pixel(c,4,4)[3],255); XCTAssertEqual(pixel(c,15,15)[3],0)
    }
    func testSceneRejectsCyclesAndDoubleParents() throws {
        let a = Group(), b = Group(), c = Group(); try a.add(b)
        XCTAssertThrowsError(try b.add(a)); XCTAssertThrowsError(try c.add(b)); a.remove(b); XCTAssertNoThrow(try c.add(b))
    }
    func testTracksSeekRepeatAndValidation() throws {
        let t = try Track([Keyframe(0,0),Keyframe(1,10),Keyframe(2,20)],repeatDuration:3)
        XCTAssertEqual(t.value(at:1.5),15); XCTAssertEqual(t.value(at:0.5),5); XCTAssertEqual(t.value(at:3.5),5)
        XCTAssertEqual(t.value(at:-1),0); XCTAssertThrowsError(try Track([])); XCTAssertThrowsError(try Track([Keyframe(1,0),Keyframe(1,2)]))
    }
    func testSparseFramesEqualSequentialRender() throws {
        let scene = Scene(), box = ShapeNode(.rect(CGRect(x:0,y:0,width:4,height:4)))
        box.tracks["x"] = try Track([Keyframe(0,0),Keyframe(1,24)]); try scene.root.add(box)
        let a = try Canvas(width:32,height:16), b = try Canvas(width:32,height:16)
        for f in 0...12 { try scene.draw(on:a,at:FrameTime(frame:f,fps:24)) }
        try scene.draw(on:b,at:FrameTime(frame:12,fps:24))
        XCTAssertEqual(Data(bytes:a.context.data!,count:a.context.bytesPerRow*16),Data(bytes:b.context.data!,count:b.context.bytesPerRow*16))
    }
    func testColorNoiseAndCurves() throws {
        XCTAssertEqual(try Color(hex:"#f008"),Color(1,0,0,136.0/255)); XCTAssertThrowsError(try Color(hex:"xyz"))
        let noise = Noise(seed:9); XCTAssertEqual(noise.value(1.3,2.4),Noise(seed:9).value(1.3,2.4))
        XCTAssertLessThan(abs(noise.value(1.3,2.4)-noise.value(1.3001,2.4)),0.001)
        let a = CGPoint.zero, d = CGPoint(x:10,y:10)
        XCTAssertEqual(Path.bezierPoint(a,a,d,d,t:0),a); XCTAssertEqual(Path.bezierPoint(a,a,d,d,t:1),d)
    }
    func testTextOutlinesAndUnicodeReveal() throws {
        let layout = TextLayout("SIGNAL",size:20); XCTAssertGreaterThan(layout.width,30); XCTAssertFalse(layout.outline.cgPath.isEmpty)
        XCTAssertEqual(Motion.typed("👩🏽‍🚀é",progress:0.5),"👩🏽‍🚀")
        let c = try Canvas(width:128,height:40); layout.draw(on:c,at:CGPoint(x:2,y:28))
        let top = (0..<28).reduce(0) { sum,y in sum+(0..<100).reduce(0) { $0+Int(pixel(c,$1,y)[3]) } }
        XCTAssertGreaterThan(top,0); XCTAssertEqual(pixel(c,3,38)[3],0)
    }
    func testSpriteClampingLoopAndBackwardSeek() throws {
        let dir = try temp(), c = try Canvas(width:4,height:4)
        for i in 0..<3 { c.clear(Color(Double(i)/2,0,0)); try c.writePNG(to:dir.appendingPathComponent(String(format:"%04d.png",i))) }
        let s = try SpriteSequence(directory:dir,count:3,fps:2,rect:CGRect(x:0,y:0,width:4,height:4),cacheLimit:1)
        XCTAssertNoThrow(try s.image(at:1)); XCTAssertNoThrow(try s.image(at:0)); XCTAssertNoThrow(try s.image(at:100))
        s.loop = true; c.clear(); c.image(try s.image(at:-0.5).image,in:CGRect(x:0,y:0,width:4,height:4)); XCTAssertEqual(pixel(c,1,1)[0],255)
    }
    func testDocumentRejectsTyposBadTracksAndMissingAssets() throws {
        let dir = try temp(), url = dir.appendingPathComponent("scene.json")
        for json in ["{\"nodes\":[{\"type\":\"typo\"}]}","{\"nodes\":[{\"type\":\"rect\",\"tracks\":{\"x\":[[1,0],[0,1]]}}]}","{\"nodes\":[{\"type\":\"image\",\"path\":\"missing.png\"}]}","{\"noodes\":[]}"] {
            try Data(json.utf8).write(to:url); XCTAssertThrowsError(try SceneDocument(url:url,width:32,height:32))
        }
    }
    func testCoreImageMaskAndComposition() throws {
        let c = try Compositor(width:16,height:16), canvas = try Canvas(width:16,height:16)
        let bounds = c.extent, red = CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:bounds)
        let mask = CIImage(color:.white).cropped(to:CGRect(x:0,y:8,width:16,height:8))
        let clear = CIImage(color:.clear).cropped(to:bounds)
        canvas.image(try c.image(c.composite(red,over:clear,opacity:0.5,mask:mask)),in:bounds)
        XCTAssertEqual(pixel(canvas,4,4)[3],128,accuracy:2); XCTAssertEqual(pixel(canvas,4,12)[3],0)
    }
    func testMetalParticlesDeterministicAndOriented() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device in this session") }
        let particles = try MetalParticles(width:64,height:64,particles:[.init(origin:SIMD2(12,10),velocity:.zero,color:SIMD4(1,0,0,1),size:6,phase:1,life:2)])
        let c = try Compositor(width:64,height:64), canvas = try Canvas(width:64,height:64)
        canvas.image(try c.image(particles.render(at:0)),in:c.extent)
        XCTAssertGreaterThan(pixel(canvas,12,10)[3],100); XCTAssertEqual(pixel(canvas,12,54)[3],0)
        let a = Data(bytes:canvas.context.data!,count:canvas.context.bytesPerRow*64)
        _ = try particles.render(at:3); canvas.clear(); canvas.image(try c.image(particles.render(at:0)),in:c.extent)
        XCTAssertEqual(a,Data(bytes:canvas.context.data!,count:canvas.context.bytesPerRow*64))
    }
    func test3DPrimitivesRender() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device in this session") }
        let scene = try Scene3D(width:64,height:64); scene.add(.torus,color:Color(0,1,1))
        let c = try Compositor(width:64,height:64), canvas = try Canvas(width:64,height:64)
        canvas.image(try c.image(scene.render(at:0)),in:c.extent)
        XCTAssertGreaterThan((0..<64).reduce(0) { sum,y in sum+(0..<64).reduce(0) { $0+Int(pixel(canvas,$1,y)[3]) } },0)
    }
    func testNativeVideoFrameCountTimingAndDecode() async throws {
        let url = try temp().appendingPathComponent("test.mp4"), c = try Compositor(width:64,height:32)
        let writer = try VideoWriter(url:url,width:64,height:32,fps:24)
        for f in 0..<6 {
            let image = CIImage(color:CIColor(cgColor:Color(Double(f)/5,0.25,0.5).cgColor)).cropped(to:c.extent)
            try await writer.append(image,frame:f,compositor:c)
        }
        try await writer.finish()
        let source = try await VideoSource(url:url); XCTAssertEqual(source.duration,0.25,accuracy:0.002)
        let canvas = try Canvas(width:64,height:32)
        canvas.image(try c.image(source.image(at:2.0/24,size:c.extent.size)),in:c.extent)
        for (channel,value) in [102,64,128].enumerated() { XCTAssertEqual(Int(pixel(canvas,10,10)[channel]),value,accuracy:5) }
        canvas.clear()
        canvas.image(try c.image(source.image(at:5.0/24,size:c.extent.size)),in:c.extent)
        XCTAssertGreaterThan(pixel(canvas,10,10)[0],240)
        XCTAssertThrowsError(try source.image(at:0,size:c.extent.size))
        let asset = AVURLAsset(url:url), track = try await asset.loadTracks(withMediaType:.video).first!
        let reader = try AVAssetReader(asset:asset), output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading()); var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }; XCTAssertEqual(count,6)
    }
    func testComputeSignalPreservesOrientationAndAlpha() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device in this session") }
        let canvas = try Canvas(width:32,height:32); canvas.style.fill = Color(1,0.5,0.2,0.5); canvas.rect(0,0,32,8)
        let input = CIImage(cgImage:try canvas.snapshot()), c = try Compositor(width:32,height:32)
        let identity = try SignalEffect(width:32,height:32,grain:0,scanlines:0,chromaticPixels:0)
        let output = try c.image(identity.apply(input,at:FrameTime(frame:4,fps:24)))
        canvas.clear(); canvas.image(output,in:c.extent)
        XCTAssertEqual(pixel(canvas,4,4)[3],128,accuracy:2); XCTAssertEqual(pixel(canvas,4,28)[3],0)
        let grain = try SignalEffect(width:32,height:32,grain:0.8,scanlines:0,chromaticPixels:0)
        canvas.clear(); canvas.image(try c.image(grain.apply(input,at:FrameTime(frame:4,fps:24))),in:c.extent)
        let alphaSum = (0..<8).reduce(0) { sum,y in sum+(0..<32).reduce(0) { $0+Int(pixel(canvas,$1,y)[3]) } }
        XCTAssertLessThan(alphaSum,32*8*110)
    }
    func testProResAlphaAndFractionalFPS() async throws {
        let url = try temp().appendingPathComponent("alpha.mov"), c = try Compositor(width:64,height:32)
        let writer = try VideoWriter(url:url,width:64,height:32,fps:30000.0/1001,codec:.prores4444)
        let transparent = CIImage(color:.clear).cropped(to:c.extent)
        let image = CIImage(color:CIColor(red:1,green:0,blue:0,alpha:0.5)).cropped(to:CGRect(x:0,y:16,width:64,height:16)).composited(over:transparent)
        for f in 0..<5 { try await writer.append(image,frame:f,compositor:c) }; try await writer.finish()
        let source = try await VideoSource(url:url)
        XCTAssertEqual(source.duration,5*1001.0/30000,accuracy:0.002)
        let canvas = try Canvas(width:64,height:32); canvas.image(try c.image(source.image(at:0,size:c.extent.size)),in:c.extent)
        XCTAssertEqual(pixel(canvas,4,4)[3],128,accuracy:4); XCTAssertEqual(pixel(canvas,4,28)[3],0,accuracy:2)
    }
    func testAudioAnalysisUsesAbsoluteSampleBoundaries() throws {
        let url = try temp().appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:44100)!
        buffer.frameLength = 44100
        for i in 0..<44100 { buffer.floatChannelData![0][i] = Float(sin(Double(i)*2 * .pi*440/44100))*0.5 }
        do { let file = try AVAudioFile(forWriting:url,settings:format.settings); try file.write(from:buffer) }
        let result = try AudioAnalyzer().analyze(url:url,fps:30000.0/1001)
        XCTAssertEqual(result.rms.count,30); XCTAssertEqual(result.rms[0],Float(0.5/sqrt(2)),accuracy:0.01)
        XCTAssertEqual(result.bands[0].count,32); XCTAssertGreaterThan(result.bands[0].max()!,0.03)
    }

    func testMemoryCompositionLayerTransformsAndStaticCache() throws {
        let composition = try Composition(width:32,height:32), scene = Scene()
        let rect = ShapeNode(.rect(CGRect(x:0,y:0,width:8,height:8)),style:Style(fill:Color(1,0,0)))
        try scene.root.add(rect)
        let layer = try VectorLayer(scene,width:32,height:32)
        layer.transform = CGAffineTransform(translationX:4,y:12); layer.opacity = 0.5
        composition.layers = [layer]
        let canvas = try Canvas(width:32,height:32)
        canvas.image(try composition.compositor.image(composition.image(at:FrameTime(frame:0,fps:24))),in:composition.compositor.extent)
        XCTAssertEqual(pixel(canvas,6,14)[3],128,accuracy:2); XCTAssertEqual(pixel(canvas,6,2)[3],0)
        let cached = try ImageAsset.rasterize(rect,width:8,height:8)
        canvas.clear(); canvas.image(cached.image,in:CGRect(x:0,y:0,width:8,height:8)); XCTAssertEqual(pixel(canvas,4,4),[255,0,0,255])
    }
    func testAudioAndPictureShareOneOutputWithTrimmedPCM() async throws {
        let dir = try temp(), wav = dir.appendingPathComponent("source.wav"), movie = dir.appendingPathComponent("final.mp4")
        let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!; buffer.frameLength = 48000
        for i in 0..<48000 { buffer.floatChannelData![0][i] = Float(sin(Double(i)*2 * .pi*500/48000))*0.3 }
        do { let file = try AVAudioFile(forWriting:wav,settings:format.settings); try file.write(from:buffer) }
        let source = try await AudioSource(url:wav,start:0.25,duration:0.5)
        let c = try Compositor(width:64,height:32), writer = try VideoWriter(url:movie,width:64,height:32,fps:24,audio:source)
        for f in 0..<12 { try await writer.append(CIImage(color:.white).cropped(to:c.extent),frame:f,compositor:c) }
        try await writer.finish()
        let asset = AVURLAsset(url:movie), tracks = try await asset.loadTracks(withMediaType:.audio)
        XCTAssertEqual(tracks.count,1)
        let duration = try await asset.load(.duration).seconds; XCTAssertEqual(duration,0.5,accuracy:0.003)
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:tracks[0],outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsNonInterleaved:false])
        reader.add(output); XCTAssertTrue(reader.startReading()); var samples = 0
        while let sample = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(sample) }
        XCTAssertGreaterThan(samples,20000)
        // Compressed AAC readers emit grouped packets and empty timing markers.
        // Exercise passthrough with picture continuing well after audio EOF.
        let copied = dir.appendingPathComponent("copied.mp4")
        let aac = try await AudioSource(url:movie,duration:2)
        let second = try VideoWriter(url:copied,width:64,height:32,fps:24,audio:aac)
        for f in 0..<48 { try await second.append(CIImage(color:.white).cropped(to:c.extent),frame:f,compositor:c) }
        try await second.finish()
        let copyAsset = AVURLAsset(url:copied)
        let copyDuration = try await copyAsset.load(.duration).seconds
        let copyTracks = try await copyAsset.loadTracks(withMediaType:.audio)
        XCTAssertEqual(copyDuration,2,accuracy:0.003); XCTAssertEqual(copyTracks.count,1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:dir.path)),Set(["source.wav","final.mp4","copied.mp4"]))
    }

}
