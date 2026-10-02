import Foundation
import CoreGraphics
import CoreImage

/// Versioned, declarative entry point for the Ruby pipeline. Swift clients can subclass Node directly.
public final class SceneDocument {
    public let scene = Scene(), effects = EffectChain()
    public private(set) var particles: [MetalParticles] = []
    private let base: URL, data: [String:Any], width: Int, height: Int
    public init(url: URL, width: Int, height: Int, data: [String:Any] = [:]) throws {
        base = url.deletingLastPathComponent(); self.data = data; self.width = width; self.height = height
        let raw = try JSONSerialization.jsonObject(with:Data(contentsOf:url))
        let doc = try Object(raw)
        try doc.keys(["version","background","nodes","effects","particles","fonts"])
        guard try doc.number("version",1) == 1 else { throw GraphicsError.invalid("Unsupported scene version") }
        for value in try doc.array("fonts") { guard let file = value as? String else { throw GraphicsError.invalid("Font must be a path") }; try TextLayout.registerFont(at:resolve(file)) }
        scene.background = try doc.color("background",.clear) ?? .clear
        for n in try doc.array("nodes") { try scene.root.add(node(Object(n))) }
        for raw in try doc.array("effects") {
            let fx = try Object(raw); try fx.keys(["name","parameters"])
            var parameters: [String:Any] = [:]
            for (key,value) in try fx.object("parameters").raw {
                if let components = value as? [Double] { parameters[key] = CIVector(values:components.map { CGFloat($0) },count:components.count) }
                else if let color = value as? String, color.hasPrefix("#") { parameters[key] = CIColor(cgColor:try Color(hex:color).cgColor) }
                else if let number = value as? NSNumber { parameters[key] = number }
                else { throw GraphicsError.invalid("Unsupported filter parameter \(key)") }
            }
            let name = try fx.string("name")
            if name == "signal" {
                let p = try fx.object("parameters"); try p.keys(["grain","scanlines","chromaticPixels"])
                effects.effects.append(try SignalEffect(width:width,height:height,grain:p.number("grain",0.15),scanlines:p.number("scanlines",0.12),chromaticPixels:p.number("chromaticPixels",2)))
            } else { effects.effects.append(try FilterEffect(name,parameters:parameters)) }
        }
        for raw in try doc.array("particles") {
            let p = try Object(raw); try p.keys(["count","seed","color","size","speed","life"])
            let count = try p.integer("count",2000), seed = try p.integer("seed",7)
            guard count > 0 && count <= 1_000_000 && seed >= 0 else { throw GraphicsError.invalid("Particle count must be 1...1000000 and seed nonnegative") }
            var rng = Random(seed:UInt64(seed)); let color = try p.color("color",Color(0.2,0.8,1))!
            let size = try p.number("size",3), speed = try p.number("speed",35), life = try p.number("life",5)
            let values = (0..<count).map { _ -> MetalParticles.Particle in
                .init(origin:SIMD2(Float(rng.next()*Double(width)),Float(rng.next()*Double(height))),
                      velocity:SIMD2(Float((rng.next()-0.5)*speed),Float(-rng.next()*speed)),
                      color:SIMD4(Float(color.r),Float(color.g),Float(color.b),Float(color.a)),size:Float(size*(0.4+rng.next()*0.6)),phase:Float(rng.next()*life),life:Float(life))
            }
            particles.append(try MetalParticles(width:width,height:height,particles:values))
        }
    }
    private func resolve(_ path: String) -> URL { URL(fileURLWithPath:path,relativeTo:base).standardizedFileURL }
    private func track(_ raw: Any) throws -> Track {
        guard let list = raw as? [[Any]] else { throw GraphicsError.invalid("Track must be [[time,value,easing?], ...]") }
        let keys = try list.map { row -> Keyframe in
            guard (2...3).contains(row.count), let t = row[0] as? Double, let v = row[1] as? Double else { throw GraphicsError.invalid("Invalid keyframe") }
            let ease: Easing
            if row.count == 3 { guard let name = row[2] as? String, let e = Easing(rawValue:name) else { throw GraphicsError.invalid("Unknown easing \(row[2]) (use linear, inCubic, outCubic, inOutCubic, inExpo, outExpo, outBack, outElastic, smooth or hold)") }; ease = e } else { ease = .linear }
            return Keyframe(t,v,easing:ease)
        }
        do { return try Track(keys) }
        catch { throw GraphicsError.invalid("\(error) (keyframe times: \(keys.map(\.time)))") }
    }
    private func points(_ o: Object) throws -> [CGPoint] {
        try o.array("points").map { raw in
            guard let p = raw as? [Double], p.count == 2, p.allSatisfy(\.isFinite) else { throw GraphicsError.invalid("Points must be [x,y]") }
            return CGPoint(x:p[0],y:p[1])
        }
    }
    private func font(_ o: Object) throws -> String {
        let name = try o.string("font","HelveticaNeue")
        guard TextLayout.isAvailable(name) else { throw GraphicsError.invalid("Font not installed or registered: \(name) (use its PostScript name and list the file in fonts)") }
        return name
    }
    private func node(_ o: Object) throws -> Node {
        try o.keys(["type","name","x","y","rotation","scale","scaleX","scaleY","opacity","start","end","anchor","blend","children","tracks","clip",
                    "width","height","radius","inner","rays","points","closed","commands","fill","stroke","strokeWidth","dash","evenOdd","gradient",
                    "text","font","size","outline","outlineWidth","reveal","path","frames","fps","loop","audioAt","clipData","clipName",
                    "progress","spacing","seed","roughness","samples","samplesData","words","wordsData","entrance","color","arcStart","arcEnd","arcMode",
                    "trimStart","trimEnd","boil","boilRate","align","tracking","strength","falloff","twist","center","resolution",
                    "skewX","skewY","rotationX","rotationY","z","panX","panY","perspective","offset","count","sides","aspect","fade"])
        let type = try o.string("type"), name = try o.string("name","")
        let w = try o.number("width",100), h = try o.number("height",100), radius = try o.number("radius",50)
        let color = try o.color("color",Color(0,1,1)) ?? .clear
        let n: Node
        switch type {
        case "group": n = Group(name:name)
        case "plane":
            let plane = PlaneNode(name:name)
            plane.rotationX = try o.number("rotationX",0); plane.rotationY = try o.number("rotationY",0); plane.z = try o.number("z",0)
            plane.panX = try o.number("panX",0); plane.panY = try o.number("panY",0); plane.perspective = try o.number("perspective",1400)
            guard plane.perspective > 0 else { throw GraphicsError.invalid("plane perspective must be positive") }; n = plane
        case "textpath":
            let path: Path
            if o.raw["points"] != nil {
                let p = try points(o); guard p.count >= 2 else { throw GraphicsError.invalid("textpath points need at least 2 points") }
                path = try o.bool("closed",false) ? .polygon(p,closed:true) : .spline(p)
            } else {
                // Circle starting at the top, running clockwise: glyphs stand outside the ring.
                path = .polygon((0..<180).map { i in let a = -Double.pi/2+Double(i)*2*Double.pi/180; return CGPoint(x:cos(a)*radius,y:sin(a)*radius) },closed:true)
            }
            let tp = try TextPathNode(try o.string("text"),path:path,font:try font(o),size:try o.number("size",48),tracking:try o.number("tracking",0),name:name)
            guard let align = TextNode.Alignment(rawValue:try o.string("align","left")) else { throw GraphicsError.invalid("align must be left, center or right") }; tp.alignment = align
            tp.color = try o.color("fill",.white) ?? .clear; tp.outlineColor = try o.color("outline",nil); tp.outlineWidth = try o.number("outlineWidth",0)
            tp.offset = try o.number("offset",0); n = tp
        case "rings":
            let rings = RingsNode(count:try o.integer("count",12),radius:radius,spacing:try o.number("spacing",40),sides:try o.integer("sides",0),name:name)
            rings.color = try o.color("stroke",color) ?? color; rings.lineWidth = try o.number("strokeWidth",1.5); rings.twist = try o.number("twist",0)
            rings.aspect = try o.number("aspect",1); rings.fade = try o.number("fade",1); rings.dash = try o.numbers("dash").map { CGFloat($0) }
            rings.boil = try o.number("boil",0); rings.seed = UInt64(max(0,try o.integer("seed",1)))
            guard rings.count <= 2000, rings.spacing != 0 else { throw GraphicsError.invalid("rings count must be 1...2000 and spacing nonzero") }; n = rings
        case "rect","square","circle","ellipse","line","point","triangle","quad","polygon","path","spline","arc","star","paper":
            let path: Path
            switch type {
            case "rect","square": path = .rect(CGRect(x:0,y:0,width:w,height:type == "square" ? w : h),radius:try o.number("radius",0))
            case "circle": path = .ellipse(CGRect(x:-radius,y:-radius,width:radius*2,height:radius*2))
            case "ellipse": path = .ellipse(CGRect(x:-w/2,y:-h/2,width:w,height:h))
            case "point": let d = try o.number("strokeWidth",1); path = .ellipse(CGRect(x:-d/2,y:-d/2,width:d,height:d))
            case "line","triangle","quad","polygon":
                let p = try points(o), expected = ["line":2,"triangle":3,"quad":4][type]
                guard expected == nil || p.count == expected else { throw GraphicsError.invalid("\(type) requires \(expected!) points") }
                path = .polygon(p,closed:type == "line" ? false : try o.bool("closed",true))
            case "spline": path = .spline(try points(o))
            case "star": path = .star(radius:radius,inner:try o.number("inner",radius*0.22),rays:try o.integer("rays",4))
            case "paper":
                let seed = try o.integer("seed",1); guard seed >= 0 else { throw GraphicsError.invalid("Seed must be nonnegative") }
                path = .paper(width:w,height:h,seed:UInt64(seed),roughness:try o.number("roughness",7))
            case "arc":
                let mode = try o.string("arcMode","open")
                guard ["open","chord","pie"].contains(mode) else { throw GraphicsError.invalid("Unknown arcMode") }
                path = .arc(center:.zero,radius:radius,start:try o.number("arcStart",0),end:try o.number("arcEnd",.pi),mode:mode == "open" ? .open : mode == "pie" ? .pie : .chord)
            default:
                path = Path()
                for command in try o.array("commands") {
                    guard let row = command as? [Any], let op = row.first as? String else { throw GraphicsError.invalid("Invalid path command") }
                    let values = row.dropFirst().compactMap { $0 as? Double }
                    let counts = ["M":2,"L":2,"Q":4,"C":6,"Z":0]
                    guard counts[op] == values.count, values.count == row.count-1, values.allSatisfy(\.isFinite) else { throw GraphicsError.invalid("Invalid \(op) path operands") }
                    switch op {
                    case "M": path.move(values[0],values[1])
                    case "L": path.line(values[0],values[1])
                    case "Q": path.quadratic(CGPoint(x:values[0],y:values[1]),CGPoint(x:values[2],y:values[3]))
                    case "C": path.cubic(CGPoint(x:values[0],y:values[1]),CGPoint(x:values[2],y:values[3]),CGPoint(x:values[4],y:values[5]))
                    default: path.close()
                    }
                }
            }
            var style = Style(fill:try o.color("fill",type == "line" ? nil : .white),stroke:try o.color("stroke",type == "line" ? .white : nil),lineWidth:try o.number("strokeWidth",1))
            style.evenOdd = try o.bool("evenOdd",false); style.dash = try o.numbers("dash").map { CGFloat($0) }
            let shape = ShapeNode(path,style:style,name:name)
            shape.trimStart = try o.number("trimStart",0); shape.trimEnd = try o.number("trimEnd",1)
            shape.boil = try o.number("boil",0); shape.boilRate = try o.number("boilRate",12); shape.boilSeed = UInt64(max(0,try o.integer("seed",1)))
            guard shape.boil >= 0, shape.boilRate > 0 else { throw GraphicsError.invalid("boil must be >= 0 and boilRate > 0") }
            if o.raw["gradient"] != nil {
                let g = try o.object("gradient"); try g.keys(["colors","from","to","center","radius"])
                let colors = try g.array("colors").map { value -> Color in guard let s = value as? String else { throw GraphicsError.invalid("Gradient colors must be hex") }; return try Color(hex:s) }
                let kind: Gradient.Kind = g.raw["radius"] != nil ? .radial(try g.point("center",.zero),try g.number("radius",radius)) : .linear(try g.point("from",.zero),try g.point("to",CGPoint(x:w,y:0)))
                shape.gradient = try Gradient(colors:colors,kind:kind)
            }
            n = shape
        case "text":
            let text = TextNode(try o.string("text"),font:try font(o),size:try o.number("size",48),tracking:try o.number("tracking",0),name:name)
            guard let align = TextNode.Alignment(rawValue:try o.string("align","left")) else { throw GraphicsError.invalid("align must be left, center or right") }; text.alignment = align
            text.color = try o.color("fill",.white) ?? .clear; text.outlineColor = try o.color("outline",.black) ?? .clear; text.outlineWidth = try o.number("outlineWidth",0)
            if let reveal = o.raw["reveal"] { text.reveal = try track(reveal) }; n = text
        case "image": n = try ImageNode(ImageAsset(url:resolve(o.string("path"))),rect:CGRect(x:0,y:0,width:w,height:h),name:name)
        case "sprite":
            var directory = try o.string("path",""), count = try o.integer("frames",1), fps = try o.number("fps",24), audioAt = try o.number("audioAt",0)
            var resolved: URL?
            if let clipName = o.raw["clipName"] as? String {
                let dataName = try o.string("clipData","clips")
                guard let clips = data[dataName] as? [String:Any], let clip = clips[clipName] else { throw GraphicsError.invalid("Missing clip data \(clipName)") }
                let meta = try Object(clip); directory = try meta.string("dir"); count = try meta.integer("frames",1); fps = try meta.number("fps",24); audioAt = try meta.number("audio_at",0)
                resolved = URL(fileURLWithPath:directory)
            }
            guard !directory.isEmpty else { throw GraphicsError.invalid("Sprite requires path or clipName") }
            let sprite = try SpriteSequence(directory:resolved ?? resolve(directory),count:count,fps:fps,rect:CGRect(x:0,y:0,width:w,height:h),name:name)
            sprite.loop = try o.bool("loop",false); sprite.audioAt = audioAt; n = sprite
        case "trace":
            let trace = TraceNode(try points(o),name:name); trace.color = color; trace.lineWidth = try o.number("strokeWidth",3)
            if let progress = o.raw["progress"] { trace.progress = try track(progress) }; n = trace
        case "grid": n = Designs.grid(width:w,height:h,spacing:try o.number("spacing",48),color:color)
        case "warpgrid":
            let grid = WarpGridNode(width:w,height:h,spacing:try o.number("spacing",60),center:try o.point("center",CGPoint(x:w/2,y:h/2)),name:name)
            grid.color = color; grid.lineWidth = try o.number("strokeWidth",1); grid.strength = try o.number("strength",0.5)
            grid.falloff = try o.number("falloff",300); grid.twist = try o.number("twist",0); grid.resolution = try o.number("resolution",12)
            guard grid.falloff > 0, grid.resolution > 0 else { throw GraphicsError.invalid("warpgrid falloff and resolution must be positive") }; n = grid
        case "reticle": n = try Designs.reticle(radius:radius,color:color)
        case "flare": n = try Designs.flare(radius:radius,color:color)
        case "waveform":
            let values: [Double]
            if let key = o.raw["samplesData"] as? String { guard let samples = data[key] as? [Double] else { throw GraphicsError.invalid("Missing samplesData array: \(key)") }; values = samples }
            else { values = try o.numbers("samples") }
            let wave = WaveformNode(samples:values,width:w,height:h); wave.color = color
            if let progress = o.raw["progress"] { wave.progress = try track(progress) }; n = wave
        case "karaoke":
            let raw: Any
            if let key = o.raw["wordsData"] as? String { guard let value = data[key] else { throw GraphicsError.invalid("Missing wordsData: \(key)") }; raw = value }
            else { raw = try o.array("words") }
            let cues = try JSONDecoder().decode([WordCue].self,from:JSONSerialization.data(withJSONObject:raw))
            _ = try CueSheet(cues); n = KaraokeNode(words:cues,font:try font(o),size:try o.number("size",48))
        default: throw GraphicsError.invalid("Unknown node type: \(type)")
        }
        n.position = CGPoint(x:try o.number("x",0),y:try o.number("y",0)); n.rotation = try o.number("rotation",0)
        let scale = try o.number("scale",1); n.scale = CGPoint(x:try o.number("scaleX",scale),y:try o.number("scaleY",scale)); n.anchor = try o.point("anchor",.zero)
        n.skewX = try o.number("skewX",0); n.skewY = try o.number("skewY",0)
        n.opacity = try o.number("opacity",1); n.start = try o.number("start",0); n.end = try o.number("end",.infinity)
        guard n.end >= n.start else { throw GraphicsError.invalid("Node end precedes start: \(type)\(name.isEmpty ? "" : " \(name)") start \(n.start) end \(n.end)") }
        let blend = try o.string("blend","normal")
        let modes: [String:CGBlendMode] = ["normal":.normal,"screen":.screen,"add":.plusLighter,"multiply":.multiply,"overlay":.overlay,"difference":.difference,"exclusion":.exclusion,"lighten":.lighten,"darken":.darken,"erase":.destinationOut]
        guard let mode = modes[blend] else { throw GraphicsError.invalid("Unknown blend \(blend)") }; if o.raw["blend"] != nil { n.blendMode = mode }
        let specific: [String]
        switch n {
        case is ShapeNode: specific = ["trimStart","trimEnd","strokeWidth","dashPhase"]
        case is WarpGridNode: specific = ["strength","twist","strokeWidth"]
        case is PlaneNode: specific = ["rotationX","rotationY","z","panX","panY"]
        case is TextPathNode: specific = ["offset","reveal"]
        case is RingsNode: specific = ["phase","twist","spacing","strokeWidth"]
        default: specific = []
        }
        let animated = ["x","y","rotation","scaleX","scaleY","opacity","skewX","skewY"] + specific
        for (key,value) in try o.object("tracks").raw {
            guard animated.contains(key) else { throw GraphicsError.invalid("Unknown animated property \(key) for \(type)") }
            do { n.tracks[key] = try track(value) } catch { throw GraphicsError.invalid("\(type)\(name.isEmpty ? "" : " \(name)") track \(key): \(error)") }
        }
        if o.raw["clip"] != nil { let r = try o.numbers("clip"); guard r.count == 4 else { throw GraphicsError.invalid("Clip is [x,y,width,height]") }; n.clip = .rect(CGRect(x:r[0],y:r[1],width:r[2],height:r[3])) }
        if let kind = o.raw["entrance"] as? String { guard ["pop","slap","slam"].contains(kind) else { throw GraphicsError.invalid("Unknown entrance") }; try Designs.entrance(n,start:n.start,kind:kind) }
        for child in try o.array("children") { try n.add(node(Object(child))) }
        return n
    }
}
private struct Object {
    let raw: [String:Any]
    init(_ value: Any) throws { guard let o = value as? [String:Any] else { throw GraphicsError.invalid("Expected JSON object") }; raw = o }
    func keys(_ allowed: [String]) throws { let extra = Set(raw.keys).subtracting(allowed); guard extra.isEmpty else { throw GraphicsError.invalid("Unknown scene keys: \(extra.sorted().joined(separator:", "))") } }
    func number(_ key: String, _ fallback: Double) throws -> Double {
        guard let v = raw[key] else { return fallback }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw GraphicsError.invalid("\(key) must be a finite number") }; return n.doubleValue
    }
    func integer(_ key: String, _ fallback: Int) throws -> Int { let n = try number(key,Double(fallback)); guard n.rounded() == n, n >= Double(Int.min), n < Double(Int.max) else { throw GraphicsError.invalid("\(key) must be an integer") }; return Int(n) }
    func string(_ key: String, _ fallback: String? = nil) throws -> String {
        if raw[key] == nil, let fallback { return fallback }
        guard let s = raw[key] as? String else { throw GraphicsError.invalid("\(key) must be a string") }; return s
    }
    func bool(_ key: String, _ fallback: Bool) throws -> Bool {
        guard let value = raw[key] else { return fallback }
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw GraphicsError.invalid("\(key) must be boolean") }; return n.boolValue
    }
    func array(_ key: String) throws -> [Any] { guard let v = raw[key] else { return [] }; guard let a = v as? [Any] else { throw GraphicsError.invalid("\(key) must be an array") }; return a }
    func object(_ key: String) throws -> Object { try Object(raw[key] ?? [String:Any]()) }
    func numbers(_ key: String) throws -> [Double] {
        try array(key).map { v in guard let n = v as? Double, n.isFinite else { throw GraphicsError.invalid("\(key) requires finite numbers") }; return n }
    }
    func point(_ key: String, _ fallback: CGPoint) throws -> CGPoint {
        guard raw[key] != nil else { return fallback }; let n = try numbers(key)
        guard n.count == 2 else { throw GraphicsError.invalid("\(key) must be [x,y]") }; return CGPoint(x:n[0],y:n[1])
    }
    func color(_ key: String, _ fallback: Color?) throws -> Color? {
        guard let v = raw[key] else { return fallback }; if v is NSNull { return nil }
        guard let s = v as? String else { throw GraphicsError.invalid("\(key) must be a hex color or null") }; return try Color(hex:s)
    }
}
