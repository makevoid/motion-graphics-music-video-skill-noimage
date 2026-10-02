import Foundation
import MotionGraphics
import CoreImage
import AVFoundation

struct Options {
    var scene: String, out = "", width = 1920, height = 1080, frames = 1, fps = 24.0
    var only: [Int]?, data: [String:String] = [:], plate: String?, audio: String?
    var codec = VideoCodec.h264, benchmark = false, software = false, measureCoverage = false, supersample = 1, bitrate: Int?
    var from = 0, to: Int?
    init(_ arguments: [String]) throws {
        guard let first = arguments.first, !first.hasPrefix("--") else { throw GraphicsError.invalid("First argument must be a scene.json path; use --help") }; scene = first
        var i = 1
        while i < arguments.count {
            let key = arguments[i]; i += 1
            if key == "--benchmark" { benchmark = true; continue }
            if key == "--measure-coverage" { measureCoverage = true; continue }
            if key == "--software" { software = true; continue }
            guard i < arguments.count else { throw GraphicsError.invalid("Missing value for \(key)") }
            let value = arguments[i]; i += 1
            func integer() throws -> Int { guard let n = Int(value) else { throw GraphicsError.invalid("Invalid integer for \(key)") }; return n }
            switch key {
            case "--out": out = value
            case "--width": width = try integer()
            case "--height": height = try integer()
            case "--frames": frames = try integer()
            case "--fps": guard let n = Double(value) else { throw GraphicsError.invalid("Invalid fps") }; fps = n
            case "--only": only = try value.split(separator:",",omittingEmptySubsequences:false).map { guard let n = Int($0) else { throw GraphicsError.invalid("Invalid frame index") }; return n }
            case "--data":
                let pair = value.split(separator:"=",maxSplits:1).map(String.init)
                guard pair.count == 2 else { throw GraphicsError.invalid("--data requires name=file.json") }; data[pair[0]] = pair[1]
            case "--plate": plate = value
            case "--audio": audio = value
            case "--supersample": supersample = try integer(); guard (1...4).contains(supersample) else { throw GraphicsError.invalid("--supersample must be 1...4") }
            case "--bitrate": bitrate = try integer()
            case "--from": from = try integer()
            case "--to": to = try integer()
            case "--codec": guard let c = VideoCodec(rawValue:value) else { throw GraphicsError.invalid("Codec must be h264, hevc or prores4444") }; codec = c
            default: throw GraphicsError.invalid("Unknown option \(key)")
            }
        }
        guard (1...16384).contains(width), (1...16384).contains(height), frames > 0, fps.isFinite, fps > 0, fps <= 240 else { throw GraphicsError.invalid("Invalid dimensions, frame count, or fps") }
        guard !out.isEmpty || benchmark else { throw GraphicsError.invalid("--out is required") }
        guard from >= 0, from < (to ?? frames), (to ?? frames) <= frames else { throw GraphicsError.invalid("--from/--to must satisfy 0 <= from < to <= frames") }
        if let only { guard !only.isEmpty, Set(only).count == only.count, only.allSatisfy({ $0 >= 0 && $0 < frames }) else { throw GraphicsError.invalid("--only requires distinct indices inside the frame range") } }
    }
}
@main struct CLI {
    static func main() async {
        if CommandLine.arguments.contains("--help") {
            print("""
            mgraphics scene.json --out frames/|video.mp4|overlay.mov --frames N [--width 1920 --height 1080 --fps 24]
              --only 0,24,48             Sparse PNG previews (absolute frame numbers)
              --data words=words.json   External cue/sample/clip data; repeatable
              --plate video.mp4         Decode and compose over a video (center-cropped to fill)
              --audio song.m4a          Mux audio; otherwise inherit plate audio if present
              --codec h264|hevc|prores4444  ProRes 4444 .mov preserves alpha; MP4 flattens over black
              --supersample 2           Draw at 2x (or 3, 4) and Lanczos-downscale: cleaner thin lines, glows and small type
              --bitrate 15000000        Average H.264/HEVC bits/s (default 0.18 bit/pixel/frame)
              --from 0 --to N           Render only frames from..<to (a chunk; times stay absolute) — for parallel renders
              --benchmark              Render without writing; reports wall time and fps
              --software               Force software Core Image (Metal particles still require GPU)
              --analyze audio.wav --out features.json [--fps 24]  Native RMS/peak/spectrum analysis
              --sfx out.wav --spec '{"synth":"whoosh","duration":0.8}'  Procedural sound effect (see SoundSynth)
            Times are seconds; angles radians; coordinates top-left pixels. No network access.
            """); return
        }
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "--analyze" { try analyze(args) }
            else if args.first == "--sfx" { try sfx(args) }
            else { try await run(Options(args)) }
        }
        catch { FileHandle.standardError.write(Data("mgraphics: \(error)\n".utf8)); exit(1) }
    }
    static func analyze(_ args: [String]) throws {
        guard args.count >= 4 else { throw GraphicsError.invalid("--analyze audio.wav --out features.json [--fps 24]") }
        let audio = args[1]; var output: String?, fps = 24.0, i = 2
        while i < args.count {
            guard i+1 < args.count else { throw GraphicsError.invalid("Missing analysis argument") }
            switch args[i] {
            case "--out": output = args[i+1]
            case "--fps": guard let value = Double(args[i+1]) else { throw GraphicsError.invalid("Invalid analysis fps") }; fps = value
            default: throw GraphicsError.invalid("Unknown analysis argument")
            }; i += 2
        }
        guard let output else { throw GraphicsError.invalid("Analysis requires --out") }
        let result = try AudioAnalyzer().analyze(url:URL(fileURLWithPath:audio),fps:fps)
        let out = URL(fileURLWithPath:output)
        try FileManager.default.createDirectory(at:out.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(result).write(to:out,options:.atomic)
        print(String(data:try JSONSerialization.data(withJSONObject:["out":output,"frames":result.rms.count,"fps":fps]),encoding:.utf8)!)
    }
    static func sfx(_ args: [String]) throws {
        guard args.count == 4, args[2] == "--spec" else { throw GraphicsError.invalid("--sfx out.wav --spec '{\"synth\":\"whoosh\"}'") }
        guard let spec = try JSONSerialization.jsonObject(with:Data(args[3].utf8)) as? [String:Any] else { throw GraphicsError.invalid("--spec must be a JSON object") }
        let sound = try SoundSynth.render(spec)
        try SoundSynth.writeWAV(sound,to:URL(fileURLWithPath:args[1]))
        print(String(data:try JSONSerialization.data(withJSONObject:["wav":args[1],"duration":sound.duration,"peak_at":sound.peakAt]),encoding:.utf8)!)
    }
    static func run(_ o: Options) async throws {
        let canvas = try Canvas(width:o.width,height:o.height,supersample:o.supersample), compositor = try Compositor(width:o.width,height:o.height,software:o.software)
        var data: [String:Any] = [:]
        for (name,path) in o.data { data[name] = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) }
        let document = try SceneDocument(url:URL(fileURLWithPath:o.scene),width:o.width,height:o.height,data:data)
        let source: VideoSource?, still: CIImage?
        if let path = o.plate {
            let url = URL(fileURLWithPath:path)
            if ["png","jpg","jpeg","tiff","tif","heic"].contains(url.pathExtension.lowercased()) {
                var image = CIImage(cgImage:try ImageAsset(url:url).image)
                let scale = max(Double(o.width)/image.extent.width,Double(o.height)/image.extent.height)
                image = image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                still = image.transformed(by:CGAffineTransform(translationX:(Double(o.width)-image.extent.width)/2,y:(Double(o.height)-image.extent.height)/2)).cropped(to:compositor.extent)
                source = nil
            } else { source = try await VideoSource(url:url); still = nil }
        } else { source = nil; still = nil }
        let out = URL(fileURLWithPath:o.out), movie = ["mp4","mov"].contains(out.pathExtension.lowercased())
        guard !movie || o.only == nil else { throw GraphicsError.invalid("--only is for PNG sequences; movie frames must be contiguous") }
        if !movie && o.audio != nil { throw GraphicsError.invalid("Audio requires movie output") }
        var audio = o.audio
        if movie, source != nil, audio == nil, let plate = o.plate,
           try await !AVURLAsset(url:URL(fileURLWithPath:plate)).loadTracks(withMediaType:.audio).isEmpty { audio = plate }
        if !o.benchmark { try FileManager.default.createDirectory(at:movie ? out.deletingLastPathComponent() : out,withIntermediateDirectories:true) }
        if movie && !o.benchmark && FileManager.default.fileExists(atPath:out.path) { throw GraphicsError.io("Output already exists: \(out.path)") }
        let audioSource: AudioSource?
        if movie && !o.benchmark, let audio { audioSource = try await AudioSource(url:URL(fileURLWithPath:audio),start:Double(o.from)/o.fps,duration:Double((o.to ?? o.frames)-o.from)/o.fps) }
        else { audioSource = nil }
        let writer = movie && !o.benchmark ? try VideoWriter(url:out,width:o.width,height:o.height,fps:o.fps,codec:o.codec,audio:audioSource,bitrate:o.bitrate) : nil
        var coverage: [String:Double] = [:]
        let reviewCanvas = o.measureCoverage ? try Canvas(width:o.width,height:o.height) : nil
        let frames = o.only?.sorted() ?? Array(o.from..<(o.to ?? o.frames)), start = ProcessInfo.processInfo.systemUptime
        for frame in frames {
            let time = FrameTime(frame:frame,fps:o.fps)
            let image: CIImage = try autoreleasepool {
                try document.scene.draw(on:canvas,at:time)
                var image = CIImage(cgImage:try canvas.snapshot())
                if o.supersample > 1 {
                    image = image.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:1/Double(o.supersample),kCIInputAspectRatioKey:1.0]).cropped(to:compositor.extent)
                }
                for particles in document.particles { image = compositor.composite(try particles.render(at:time.seconds),over:image) }
                image = try document.effects.apply(image,at:time)
                if let review = reviewCanvas, frame % 6 == 0 {
                    // Review-only readback, sampled in memory; never writes a frame sequence.
                    review.clear()
                    review.image(try compositor.image(image),in:compositor.extent)
                    let bytes = review.context.data!.assumingMemoryBound(to:UInt8.self)
                    var sum = 0.0
                    for y in stride(from:0,to:o.height,by:4) { for x in stride(from:0,to:o.width,by:4) { sum += Double(bytes[y*review.context.bytesPerRow+x*4+3])/255 } }
                    coverage[String(frame)] = 100*sum/Double(((o.width+3)/4)*((o.height+3)/4))
                }
                if let still { image = compositor.composite(image,over:still) }
                if let source { image = compositor.composite(image,over:try source.image(at:time.seconds,size:compositor.extent.size)) }
                if movie && o.codec != .prores4444 { image = compositor.composite(image,over:CIImage(color:.black).cropped(to:compositor.extent)) }
                // Explicitly materialize only for PNG/benchmark; movie goes directly to pooled buffers below.
                if writer == nil {
                    let cg = try compositor.image(image)
                    if !o.benchmark { try ImageAsset.writePNG(cg,to:out.appendingPathComponent(String(format:"%04d.png",frame))) }
                }
                return image
            }
            if let writer { try await writer.append(image,frame:frame-o.from,compositor:compositor) }
        }
        if let writer { try await writer.finish() }
        let elapsed = ProcessInfo.processInfo.systemUptime-start
        let summary: [String:Any] = ["out":o.out,"frames":frames.count,"width":o.width,"height":o.height,"fps":o.fps,
                                   "ms":elapsed*1000,"render_fps":Double(frames.count)/max(elapsed,1e-9),"backend":compositor.backend,"benchmark":o.benchmark,"coverage_pct_by_frame":coverage]
        print(String(data:try JSONSerialization.data(withJSONObject:summary,options:.sortedKeys),encoding:.utf8)!)
    }
}
