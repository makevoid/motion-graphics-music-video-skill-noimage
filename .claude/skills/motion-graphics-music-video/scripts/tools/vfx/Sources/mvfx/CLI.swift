import Foundation
import CoreImage
import AVFoundation
import MotionGraphics

struct Options {
    var input = "", cues = "", out = "", lightsScene: String?, stills: String?
    var only: [Int] = [], from = 0, to: Int?, bitrate: Int?, audio = true
    init(_ args: [String]) throws {
        var it = args.makeIterator()
        while let key = it.next() {
            if key == "--no-audio" { audio = false; continue } // picture-only chunk (parallel renders copy the audio once)
            guard let value = it.next() else { throw GraphicsError.invalid("Missing value for \(key)") }
            func integer() throws -> Int { guard let n = Int(value) else { throw GraphicsError.invalid("Invalid \(key)") }; return n }
            switch key {
            case "--in": input = value
            case "--cues": cues = value
            case "--out": out = value
            case "--lights-scene": lightsScene = value
            case "--stills": stills = value
            case "--only": only = try value.split(separator:",").map { guard let n = Int($0) else { throw GraphicsError.invalid("Invalid frame index") }; return n }.sorted()
            case "--from": from = try integer()
            case "--to": to = try integer()
            case "--bitrate": bitrate = try integer()
            default: throw GraphicsError.invalid("Unknown option \(key)")
            }
        }
        guard !input.isEmpty, !cues.isEmpty, !out.isEmpty || stills != nil else { throw GraphicsError.invalid("mvfx --in source.mp4 --cues cues.json (--out finish.mp4 | --stills dir --only 0,24)") }
    }
}
@main struct VFXCLI {
    static func main() async {
        do { try await run(Options(Array(CommandLine.arguments.dropFirst()))) }
        catch { FileHandle.standardError.write(Data("mvfx: \(error)\n".utf8)); exit(1) }
    }
    static func run(_ opt: Options) async throws {
        let url = URL(fileURLWithPath:opt.input), asset = AVURLAsset(url:url)
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw GraphicsError.invalid("Input has no picture track") }
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin:.zero,size:size).applying(transform), width = Int(abs(bounds.width)), height = Int(abs(bounds.height))
        let nominal = try await track.load(.nominalFrameRate)
        // Cues, --from/--to and --only are on the 24 fps cue grid; the video may run at any rate (e.g. 60 fps): every output
        // frame is rendered, sampling the cues at its exact time.
        let fps = Double(nominal)
        guard fps.isFinite, fps >= 1, fps <= 240 else { throw GraphicsError.invalid("Unsupported input frame rate \(nominal)") }
        let toOut = { (cueFrame: Int) in Int((Double(cueFrame)*fps/24).rounded()) }
        let duration = try await AVURLAsset(url:url).load(.duration).seconds, total = Int((duration*fps).rounded())
        let first = toOut(opt.from), last = opt.to.map(toOut) ?? total
        guard first >= 0, last > first, last <= total else { throw GraphicsError.invalid("Invalid VFX frame interval") }
        let wanted = opt.stills == nil ? Array(first..<last) : opt.only.map(toOut)
        guard !wanted.isEmpty, Set(wanted).count == wanted.count, wanted.allSatisfy({ $0 >= 0 && $0 < total }) else { throw GraphicsError.invalid("Invalid/empty VFX preview frames") }
        let data = try Data(contentsOf:URL(fileURLWithPath:opt.cues)), cues = try JSONDecoder().decode(CueFile.self,from:data).cues
        let known = Set(["punch","zoom","shake","whip","mblur","edgeblur","glow","flash","dark","rgb","glitch","tv","grain","stretch","echo","bands","shockwave","lens","heat","streaks","leak","flare","glints"])
        guard cues.allSatisfy({ known.contains($0.fx) && $0.dur > 0 && ($0.pre ?? 0) >= 0 }) else { throw GraphicsError.invalid("Invalid VFX cue") }
        let fx = Effects(width:width,height:height,fps:fps), lights = try NativeLights(width:width,height:height,cues:cues)
        // Existing cue amounts were authored with nonlinear RGB blending.
        let compositor = try Compositor(width:width,height:height,workingColorSpace:Color.space), canvas: Canvas?, custom: SceneDocument?
        if let path = opt.lightsScene {
            canvas = try Canvas(width:width,height:height)
            custom = try SceneDocument(url:URL(fileURLWithPath:path),width:width,height:height,data:["vfx":try JSONSerialization.jsonObject(with:data)])
        } else { canvas = nil; custom = nil }
        let destination = URL(fileURLWithPath:opt.stills ?? opt.out)
        try FileManager.default.createDirectory(at:opt.stills == nil ? destination.deletingLastPathComponent() : destination,withIntermediateDirectories:true)
        let writer: VideoWriter?
        if opt.stills == nil {
            let audio = opt.audio ? try await AudioSource(url:url,start:Double(first)/fps,duration:Double(last-first)/fps) : nil
            writer = try VideoWriter(url:destination,width:width,height:height,fps:fps,audio:audio,bitrate:opt.bitrate)
        } else { writer = nil }
        let start = ProcessInfo.processInfo.systemUptime
        // Decoded source frames an echo cue may read again: only as many as the longest echo reaches (each holds a decoder buffer).
        let reach = Int((Double(cues.filter { $0.fx == "echo" }.map { max(1,min($0.n ?? 4,12))*max(1,$0.hold ?? 1) }.max() ?? 0)*fps/24).rounded(.up))
        // Seek: a chunk (--from) or a sparse still decodes from just before its first frame (and the echo ghosts behind it).
        let source = try await VideoSource(url:url,start:max(0,Double(wanted.min()! - reach - 2)/fps))
        var recent: [Int:CIImage] = [:]
        for (index,frame) in wanted.enumerated() {
            let image: CIImage = try autoreleasepool {
                let time = FrameTime(frame:frame,fps:fps)
                var light = try lights.image(frame:frame,fps:fps)
                if let custom, let canvas {
                    try custom.scene.draw(on:canvas,at:time)
                    var overlay = CIImage(cgImage:try canvas.snapshot())
                    for particles in custom.particles { overlay = compositor.composite(try particles.render(at:time.seconds),over:overlay) }
                    overlay = try custom.effects.apply(overlay,at:time)
                    light = light.map { compositor.composite(overlay,over:$0,mode:.screen) } ?? overlay
                }
                // Ghosts not kept from earlier frames (stills, a clip's first frames) are decoded first: the source only reads forward,
                // so one behind the previously decoded frame (close stills) is left out.
                var ghosts: [Int:CIImage] = [:]
                for k in fx.echoFrames(frame:frame,cues:cues).sorted() {
                    if let kept = recent[k] { ghosts[k] = kept }
                    else if k > (recent.keys.max() ?? -1) { ghosts[k] = try source.image(at:FrameTime(frame:k,fps:fps).seconds,size:compositor.extent.size) }
                }
                let src = try source.image(at:time.seconds,size:compositor.extent.size)
                if reach > 0 { recent[frame] = src; ghosts.forEach { recent[$0.key] = $0.value }; recent = recent.filter { $0.key >= frame-reach } }
                return try fx.apply(src,frame:frame,cues:cues,lights:light,previous:{ ghosts[$0] })
            }
            if let writer { try await writer.append(image,frame:index,compositor:compositor) }
            else { try ImageAsset.writePNG(compositor.image(image),to:destination.appendingPathComponent(String(format:"%04d.png",opt.only[index]))) } // named by cue frame
        }
        if let writer { try await writer.finish() }
        let result: [String:Any] = ["out":destination.path,"frames":wanted.count,"width":width,"height":height,"ms":(ProcessInfo.processInfo.systemUptime-start)*1000]
        print(String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!)
    }
}
