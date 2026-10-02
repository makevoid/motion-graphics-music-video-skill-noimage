import Foundation
import CoreImage
import AVFoundation
import MotionGraphics

struct Options {
    var input = "", cues = "", out = "", lightsScene: String?, stills: String?
    var only: [Int] = [], from = 0, to: Int?
    init(_ args: [String]) throws {
        var it = args.makeIterator()
        while let key = it.next() {
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
        guard abs(nominal-24) < 0.01 else { throw GraphicsError.invalid("VFX cues use a 24 fps grid; convert the input to 24 fps first") }
        let source = try await VideoSource(url:url), total = Int((source.duration*24).rounded())
        let last = opt.to ?? total
        guard opt.from >= 0, last > opt.from, last <= total else { throw GraphicsError.invalid("Invalid VFX frame interval") }
        let wanted = opt.stills == nil ? Array(opt.from..<last) : opt.only
        guard !wanted.isEmpty, Set(wanted).count == wanted.count, wanted.allSatisfy({ $0 >= 0 && $0 < total }) else { throw GraphicsError.invalid("Invalid/empty VFX preview frames") }
        let data = try Data(contentsOf:URL(fileURLWithPath:opt.cues)), cues = try JSONDecoder().decode(CueFile.self,from:data).cues
        let known = Set(["punch","zoom","shake","whip","mblur","edgeblur","glow","flash","dark","rgb","glitch","tv","grain","leak","flare","glints"])
        guard cues.allSatisfy({ known.contains($0.fx) && $0.dur > 0 && ($0.pre ?? 0) >= 0 }) else { throw GraphicsError.invalid("Invalid VFX cue") }
        let fx = Effects(width:width,height:height), lights = try NativeLights(width:width,height:height,cues:cues)
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
            let audio = try await AudioSource(url:url,start:Double(opt.from)/24,duration:Double(last-opt.from)/24)
            writer = try VideoWriter(url:destination,width:width,height:height,fps:24,audio:audio)
        } else { writer = nil }
        let start = ProcessInfo.processInfo.systemUptime
        for (index,frame) in wanted.enumerated() {
            let image: CIImage = try autoreleasepool {
                let time = FrameTime(frame:frame,fps:24)
                var light = try lights.image(frame:frame)
                if let custom, let canvas {
                    try custom.scene.draw(on:canvas,at:time)
                    var overlay = CIImage(cgImage:try canvas.snapshot())
                    for particles in custom.particles { overlay = compositor.composite(try particles.render(at:time.seconds),over:overlay) }
                    overlay = try custom.effects.apply(overlay,at:time)
                    light = light.map { compositor.composite(overlay,over:$0,mode:.screen) } ?? overlay
                }
                return fx.apply(try source.image(at:time.seconds,size:compositor.extent.size),frame:frame,cues:cues,lights:light)
            }
            if let writer { try await writer.append(image,frame:index,compositor:compositor) }
            else { try ImageAsset.writePNG(compositor.image(image),to:destination.appendingPathComponent(String(format:"%04d.png",frame))) }
        }
        if let writer { try await writer.finish() }
        let result: [String:Any] = ["out":destination.path,"frames":wanted.count,"width":width,"height":height,"ms":(ProcessInfo.processInfo.systemUptime-start)*1000]
        print(String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!)
    }
}
