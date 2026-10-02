import Foundation
import CoreImage
import MotionGraphics

/// Built once per cue; all light animation is sampled analytically into one reused surface.
final class NativeLights {
    private let canvas: Canvas
    private let scene = Scene()
    private let entries: [(Cue,Node)]
    init(width: Int, height: Int, cues: [Cue]) throws {
        canvas = try Canvas(width:width,height:height)
        let w = Double(width), h = Double(height)
        var entries: [(Cue,Node)] = []
        for cue in cues where ["leak","flare","glints"].contains(cue.fx) {
            let color = try Color(hex:cue.color ?? (cue.fx == "leak" ? "#ff7a2f" : "#ffe2c4"))
            let node: Node
            if cue.fx == "flare" {
                node = try Designs.flare(radius:w*0.078,color:color)
                node.position = CGPoint(x:(cue.x ?? 0.5)*w,y:(cue.y ?? 0.5)*h)
            } else if cue.fx == "leak" {
                let r = h*0.95, shape = ShapeNode(.ellipse(CGRect(x:-r,y:-r,width:r*2,height:r*2)))
                shape.gradient = try Gradient(colors:[color.opacity(0.85),Color(1,0.1,0.4,0.2),color.opacity(0)],kind:.radial(.zero,r))
                shape.scale = CGPoint(x:0.8,y:1.25); node = shape
            } else {
                let group = Group(); var rng = Random(seed:UInt64(bitPattern:Int64(cue.seed ?? cue.f)))
                for i in 0..<max(1,min(cue.n ?? 12,1000)) {
                    let angle = rng.next()*2 * .pi, radius = (cue.sustain == true && i == 0) ? 0 : sqrt(rng.next())*(cue.radius ?? 0.14)*w
                    let size = (0.014+rng.next()*0.023)*w*(cue.size ?? 1), delay = rng.next()*Double(cue.dur)*0.5, life = 6+rng.next()*8
                    let star = ShapeNode(.star(radius:size,inner:size*0.22),style:Style(fill:color))
                    star.position = CGPoint(x:(cue.x ?? 0.5)*w+cos(angle)*radius,y:(cue.y ?? 0.5)*h+sin(angle)*radius*0.7)
                    star.update = { node,time in
                        let age = Double(time.frame-cue.f)
                        let scale = cue.sustain == true ? min(1,(age+1)/3)*pow(min(1,max(0,(Double(cue.dur)-age)/5)),2)*(0.85+0.15*sin(age*1.7+Double(i)*2)) : max(0,sin(.pi*min(1,max(0,(age-delay)/life))))
                        node.scale = CGPoint(x:scale,y:scale)
                    }
                    try group.add(star)
                }
                node = group
            }
            try scene.root.add(node); entries.append((cue,node))
        }
        self.entries = entries
    }
    func image(frame: Int) throws -> CIImage? {
        var active = false
        for (cue,node) in entries {
            node.hidden = !cue.active(frame)
            guard !node.hidden else { continue }; active = true
            if cue.fx == "leak" {
                let age = Double(frame-cue.f)/24, side = cue.x ?? 1, direction = side > 0.5 ? -1.0 : 1.0
                node.position = CGPoint(x:side*Double(canvas.width)+direction*(Double(canvas.width)*0.06+age*45),y:Double(canvas.height)*(0.35+0.08*sin(age*0.9)))
            }
            node.opacity = (cue.amt ?? 1)*(cue.fx == "glints" ? 1 : cue.env(frame,defaultShape:cue.fx == "leak" ? "span" : "hit",curve:1.6))
        }
        guard active else { return nil }
        try scene.draw(on:canvas,at:FrameTime(frame:frame,fps:24)); return CIImage(cgImage:try canvas.snapshot())
    }
}
