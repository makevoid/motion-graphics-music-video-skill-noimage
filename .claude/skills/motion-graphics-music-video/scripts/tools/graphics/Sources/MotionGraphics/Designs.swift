import Foundation
import CoreGraphics

public enum Designs {
    public static func grid(width: Double, height: Double, spacing: Double = 48, color: Color = Color(0,1,1,0.2)) -> ShapeNode {
        let path = Path(), step = max(1,spacing)
        for x in stride(from:0.0,through:width,by:step) { path.move(x,0).line(x,height) }
        for y in stride(from:0.0,through:height,by:step) { path.move(0,y).line(width,y) }
        return ShapeNode(path,style:Style(fill:nil,stroke:color))
    }
    public static func reticle(radius: Double = 100, color: Color = Color(0,1,1)) throws -> Group {
        let group = Group(name:"reticle")
        for i in 0..<4 {
            let start = Double(i)*Double.pi/2+0.12
            let node = ShapeNode(.arc(center:.zero,radius:radius,start:start,end:start+1.2),style:Style(fill:nil,stroke:color,lineWidth:2))
            try group.add(node)
        }
        let ticks = Path()
        for i in 0..<60 {
            let a = Double(i)*Double.pi/30, inner = radius+(i%5 == 0 ? 8 : 14)
            ticks.move(cos(a)*inner,sin(a)*inner).line(cos(a)*(radius+20),sin(a)*(radius+20))
        }
        try group.add(ShapeNode(ticks,style:Style(fill:nil,stroke:color.opacity(0.65))))
        return group
    }
    public static func flare(radius: Double = 120, color: Color = Color(0.4,0.8,1)) throws -> Group {
        let group = Group(name:"flare"); group.blendMode = .screen
        for (sx,sy,alpha) in [(1.0,1.0,0.6),(5.0,0.05,0.9),(0.2,0.2,1.0)] {
            let node = ShapeNode(.ellipse(CGRect(x:-radius,y:-radius,width:2*radius,height:2*radius)))
            node.gradient = try Gradient(colors:[color.opacity(alpha),color.opacity(0)],kind:.radial(.zero,radius))
            node.scale = CGPoint(x:sx,y:sy); try group.add(node)
        }
        return group
    }
    public static func misregister(_ path: Path, color: Color, ghost: Color, offset: CGPoint = CGPoint(x:4,y:3)) throws -> Group {
        let group = Group(), back = ShapeNode(path,style:Style(fill:ghost))
        back.position = offset; try group.add(back); try group.add(ShapeNode(path,style:Style(fill:color))); return group
    }
    public static func entrance(_ node: Node, start: Double, duration: Double = 0.22, kind: String = "pop") throws {
        let from = kind == "slap" ? 1.18 : kind == "slam" ? 1.7 : 0.55
        let easing: Easing = kind == "slam" ? .inCubic : .outBack
        let scale = try Track([Keyframe(start,from),Keyframe(start+duration,1,easing:easing)])
        node.start = start; node.tracks["scaleX"] = scale; node.tracks["scaleY"] = scale
        // Hits (slap/slam) are fully visible on their first frame so they land on the beat; pop fades in.
        if kind == "pop" { node.tracks["opacity"] = try Track([Keyframe(start,0),Keyframe(start+duration/3,1)]) }
        else { node.tracks["opacity"] = nil }
        if kind == "slap" { node.tracks["rotation"] = try Track([Keyframe(start,node.rotation+0.08),Keyframe(start+duration,node.rotation,easing:.outCubic)]) }
    }
}
/// Input samples are precomputed audio amplitudes (0...1); no disk or FFT work inside draw().
public final class WaveformNode: Node {
    public let samples: [Double]
    public var width: Double, height: Double, color = Color(0,1,1)
    public var lineWidth = 2.0, progress: Track?
    private let path: Path
    public init(samples: [Double], width: Double, height: Double) {
        self.samples = samples; self.width = width; self.height = height
        path = .polygon(samples.enumerated().map { CGPoint(x:Double($0.offset)*width/Double(max(1,samples.count-1)),y:-$0.element*height) },closed:false)
        super.init()
    }
    public override func draw(on canvas: Canvas, at time: FrameTime) {
        if let progress { canvas.context.clip(to:CGRect(x:0,y:-height,width:width*min(1,max(0,progress.value(at:time.seconds))),height:height*2)) }
        canvas.style = Style(fill:nil,stroke:color,lineWidth:lineWidth); canvas.draw(path)
    }
}
