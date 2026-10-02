import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// The effect chain for one frame. Every active cue adds to a State (how much zoom, blur, glow… this frame), then the frame goes
// through the Core Image filters once, in a fixed order: camera (punch/zoom/shake/whip) -> blurs (zoom, motion, edge) -> light
// (glow, flash) -> the native in-memory light layer (screen blend) -> lens/signal damage (chromatic aberration, interference, old TV) -> dark flash.
//
//   fx        shape  knobs (defaults)
//   punch     hit    amt 0.06 (zoom-in fraction), radius 2 (zoom-blur amount; 10+ is a hard hit), x/y anchor 0.5/0.5 (0..1 from top-left)
//   zoom      ramp   amt 0.08 (zoom reached at f + dur, from 0), x/y; hard reset after dur, so end it on a cut
//   shake     hit    amt 14 (px)
//   whip      -      around a cut at f: pre frames slide out, dur frames slide in; amt 0.12 (of width), radius 70, angle 0 (deg)
//   mblur     hit    amt 30 (px), angle 0
//   edgeblur  span   amt 10 (px), fade 6
//   glow      hit    amt 1.0 (bloom intensity), radius 18
//   flash     hit    amt 1.0, color #fffaf0
//   dark      hit    amt 0.94 (black opacity), hold 2 (frames at full)
//   rgb       hit    amt 0.006 (radial split, fraction of the frame), radius 0 (sideways R/B split, px)
//   glitch    span   amt 1.0, fade 1: slices shoved sideways, RGB split, noise bars, flickering frame to frame
//   tv        span   amt 1.0, fade 6, grain 0.09 (0 = none): scanlines, grain, soft focus, colour fade, vignette, rolling bar, line jitter
//   bands     span   amt 1.0, n 3 (bands), size 0.07 (band height, fraction of the frame), fade 4: VHS tracking bands rolling down —
//                    strips shoved sideways with an RGB split, a lift and a bright edge
//   grain     span   amt 0.25, fade 6: film grain on its own (soft-light, so flat paper takes less of it than midtones)
//   stretch   hit    amt 0.12 (stretch along `angle`, squashed across it so the area holds), angle 0 (deg; 90 = tall), x/y anchor
//   echo      span   amt 0.6 (trail strength), n 4 (ghost frames), hold 1 (frames between ghosts), fade 2: earlier frames lighten-blended
//                    under the current one at decaying strength (speed trails; shows on dark grounds, invisible on light paper)
final class Effects {
    let extent: CGRect, fps: Double
    var w: CGFloat { extent.width }
    var h: CGFloat { extent.height }

    init(width: Int, height: Int, fps: Double = 24) {
        extent = CGRect(x: 0, y: 0, width: width, height: height)
        self.fps = fps
    }

    struct State {
        var scale = 1.0, anchor = CGPoint(x: 0.5, y: 0.5), dx = 0.0, dy = 0.0, rot = 0.0
        var zoomBlur = 0.0, motion = 0.0, motionAngle = 0.0, edge = 0.0
        var bloom = 0.0, bloomRadius = 18.0
        var flash = 0.0, flashColor = CIColor(red: 1, green: 0.98, blue: 0.94)
        var dark = 0.0, rgb = 0.0, glitch = 0.0, tv = 0.0, tvGrain = 0.09, grain = 0.0
        var stretch = 0.0, stretchAngle = 0.0, echo = 0.0, echoTaps = 4, echoStep = 1
        var rgbShift = 0.0, bands = 0.0, bandCount = 3, bandSize = 0.07, bandSeed = 0
        var seed = 0
    }

    /// u: position on the 24 fps cue grid (fractional at other output rates). Random jitter holds per grid frame, like the scene's
    /// hold-frame animation; envelopes are continuous.
    func state(u: Double, cues: [Cue]) -> State {
        let frame = Int(floor(u))
        var s = State()
        s.seed = frame
        var anchorWeight = 0.0
        func anchor(_ c: Cue, _ e: Double) {
            guard e > anchorWeight else { return }
            anchorWeight = e
            s.anchor = CGPoint(x: c.x ?? 0.5, y: c.y ?? 0.5)
        }
        for c in cues where c.active(u) {
            var r = Rand(frame, c.f)
            switch c.fx {
            case "punch":
                let e = c.env(u, curve: 2.5)
                s.scale *= 1 + (c.amt ?? 0.06) * e
                s.zoomBlur += (c.radius ?? 2) * e * e * e
                s.rgb += 0.002 * e
                anchor(c, e)
            case "zoom":
                let p = min(1, (u - Double(c.f) + 1) / Double(max(c.dur, 1)))
                let e = p * p * (3 - 2 * p)
                s.scale *= 1 + (c.amt ?? 0.08) * max(0, e)
                anchor(c, 0.01)
            case "shake":
                let e = c.env(u, curve: 2)
                let a = (c.amt ?? 14) * e
                s.dx += r.range(-a, a)
                s.dy += r.range(-a, a)
                s.rot += r.range(-0.006, 0.006) * e
                s.scale *= 1 + 2 * a / Double(h)
            case "whip":
                let rad = (c.angle ?? 0) * .pi / 180
                let dist = (c.amt ?? 0.12) * Double(w)
                var slide = 0.0, e = 0.0
                if u < Double(c.f) {
                    let q = min(1, (u - Double(c.first) + 1) / Double((c.pre ?? 1) + 1))
                    slide = dist * q * q * q
                    e = q * q
                } else {
                    let q = max(0, 1 - (u - Double(c.f)) / Double(max(c.dur, 1)))
                    slide = -dist * q * q * q
                    e = q * q
                }
                s.dx += cos(rad) * slide
                s.dy += sin(rad) * slide
                s.motion += (c.radius ?? 70) * e
                s.motionAngle = rad
                s.scale *= 1 + 0.03 * e
            case "mblur":
                s.motion += (c.amt ?? 30) * c.env(u, curve: 2)
                s.motionAngle = (c.angle ?? 0) * .pi / 180
            case "edgeblur":
                s.edge += (c.amt ?? 10) * c.env(u, defaultShape: "span")
            case "glow":
                s.bloom += (c.amt ?? 1) * c.env(u, curve: 1.6)
                s.bloomRadius = c.radius ?? 18
            case "flash":
                s.flash += (c.amt ?? 1) * c.env(u, curve: 2.8)
                if let hex = c.color { s.flashColor = Effects.color(hex) }
            case "dark":
                let hold = c.hold ?? 2
                let t = u - Double(c.f)
                let e = t < 0 ? c.env(u) : t < Double(hold) ? 1 : pow(max(0, 1 - (t - Double(hold)) / Double(max(c.dur - hold, 1))), 2)
                s.dark = max(s.dark, (c.amt ?? 0.94) * e)
            case "rgb":
                let e = c.env(u, curve: 2)
                s.rgb += (c.amt ?? 0.006) * e
                s.rgbShift += (c.radius ?? 0) * e
            case "bands":
                let e = (c.amt ?? 1) * c.env(u, defaultShape: "span")
                if e > s.bands { s.bands = e; s.bandCount = max(1, min(c.n ?? 3, 12)); s.bandSize = c.size ?? 0.07; s.bandSeed = c.seed ?? c.f }
            case "glitch":
                var e = (c.amt ?? 1) * c.env(u, defaultShape: "span")
                if r.next() < 0.3 { e *= 0.15 }                      // flicker: some frames nearly clean
                s.glitch = max(s.glitch, e)
                s.seed = frame &* 31 &+ (c.seed ?? c.f)
            case "tv":
                s.tv = max(s.tv, (c.amt ?? 1) * c.env(u, defaultShape: "span"))
                s.tvGrain = c.grain ?? 0.09
            case "grain":
                s.grain = max(s.grain, (c.amt ?? 0.25) * c.env(u, defaultShape: "span"))
            case "stretch":
                let e = c.env(u, curve: 2.4)
                s.stretch += (c.amt ?? 0.12) * e
                s.stretchAngle = (c.angle ?? 0) * .pi / 180
                anchor(c, e)
            case "echo":
                let e = (c.amt ?? 0.6) * c.env(u, defaultShape: "span")
                if e > s.echo { s.echo = e; s.echoTaps = max(1, min(c.n ?? 4, 12)); s.echoStep = max(1, c.hold ?? 1) }
            default:
                continue
            }
        }
        if s.tv > 0 {
            var r = Rand(frame, 777)
            if r.next() < 0.18 { s.dy += r.sign() * 2 * s.tv }        // line jitter
        }
        return s
    }

    /// Frames the echo cue at `frame` reads (earlier source frames), so the caller can keep or decode them.
    /// Output frames the echo at output frame `frame` reads (ghosts are `hold` cue frames apart, converted to the output rate).
    func echoFrames(frame: Int, cues: [Cue]) -> [Int] {
        let s = state(u: Double(frame) * 24 / fps, cues: cues)
        guard s.echo > 0.01 else { return [] }
        return (1...s.echoTaps).map { frame - Int((Double($0 * s.echoStep) * fps / 24).rounded()) }.filter { $0 >= 0 }
    }

    /// One output frame (index `frame` at `fps`); cues are read on the 24 fps grid at the frame's exact time.
    func apply(_ src: CIImage, frame: Int, cues: [Cue], lights: CIImage?, previous: (Int) -> CIImage? = { _ in nil }) -> CIImage {
        let u = Double(frame) * 24 / fps
        let s = state(u: u, cues: cues)
        var img = src
        // Echo first, so the camera moves the trails with the frame: older frames darkened, kept where they are brighter.
        if s.echo > 0.01 {
            var trail = src
            for k in stride(from: s.echoTaps, through: 1, by: -1) {
                guard let old = previous(frame - Int((Double(k * s.echoStep) * fps / 24).rounded())) else { continue }
                let g = CGFloat(s.echo * (1 - Double(k - 1) / Double(s.echoTaps)))
                let dim = old.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0)])
                trail = dim.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: trail])
            }
            img = trail.cropped(to: extent)
        }
        let source = img

        // Camera + camera blurs on one edge-clamped, infinite image, cropped once: shakes and whips never show black, and no
        // crop -> clamp in between (Core Image folded a translated clamp, cropped and clamped again, into black edges on whips).
        let stretched = s.stretch > 0.001
        if s.scale != 1 || s.dx != 0 || s.dy != 0 || s.rot != 0 || stretched || s.zoomBlur > 0.5 || s.motion > 0.5 {
            var inf = source.clampedToExtent()
            if s.scale != 1 || s.dx != 0 || s.dy != 0 || s.rot != 0 || stretched {
                let a = point(s.anchor)
                // stretch along the angle (image y points up in Core Image, so the angle flips to stay clockwise like the cues)
                let axis = CGAffineTransform(rotationAngle: s.stretchAngle)
                let pull = axis.inverted().concatenating(CGAffineTransform(scaleX: 1 + s.stretch, y: 1 / (1 + s.stretch))).concatenating(axis)
                inf = inf.transformed(by: CGAffineTransform(translationX: -a.x, y: -a.y)
                    .concatenating(stretched ? pull : .identity)
                    .concatenating(CGAffineTransform(rotationAngle: s.rot))
                    .concatenating(CGAffineTransform(scaleX: s.scale, y: s.scale))
                    .concatenating(CGAffineTransform(translationX: a.x + s.dx, y: a.y - s.dy)))
            }
            if s.zoomBlur > 0.5 {
                let f = CIFilter.zoomBlur()
                f.inputImage = inf
                f.center = point(s.anchor)
                f.amount = Float(s.zoomBlur)
                inf = f.outputImage!
            }
            if s.motion > 0.5 {
                let f = CIFilter.motionBlur()
                f.inputImage = inf
                f.radius = Float(s.motion)
                f.angle = Float(s.motionAngle)
                inf = f.outputImage!
            }
            img = inf.cropped(to: extent)
        }
        if s.edge > 0.3 { img = edgeBlur(img, radius: s.edge) }

        // Light.
        if s.bloom > 0.01 {
            let f = CIFilter.bloom()
            f.inputImage = img.clampedToExtent()
            f.radius = Float(s.bloomRadius)
            f.intensity = Float(s.bloom)
            img = f.outputImage!.cropped(to: extent)
        }
        if s.flash > 0.01 {
            let e = CIFilter.exposureAdjust()
            e.inputImage = img
            e.ev = Float(0.85 * s.flash)
            img = over(solid(s.flashColor, alpha: min(0.7, 0.36 * s.flash)), e.outputImage!)
        }
        if let lights {
            let f = CIFilter.screenBlendMode()
            f.inputImage = lights
            f.backgroundImage = img
            img = f.outputImage!.cropped(to: extent)
        }

        // Lens / signal damage.
        if s.rgb > 0.0003 || s.rgbShift > 0.05 { img = chroma(img, radial: s.rgb, shift: s.rgbShift) }
        if s.bands > 0.01 { img = trackingBands(img, amount: s.bands, count: s.bandCount, size: s.bandSize, u: u, seed: s.bandSeed, frame: frame) }
        if s.glitch > 0.02 { img = interference(img, amount: s.glitch, seed: s.seed) }
        if s.tv > 0.01 { img = oldTV(img, amount: s.tv, grain: s.tvGrain, frame: frame, u: u) }
        if s.grain > 0.005 { img = filmGrain(img, amount: s.grain, frame: frame) }
        if s.dark > 0.01 { img = over(solid(CIColor(red: 0.02, green: 0.02, blue: 0.05), alpha: s.dark), img) }
        return img.cropped(to: extent)
    }

    // MARK: effects

    // Sharp centre, blur growing toward the edges and corners (lens edge / dreamy focus).
    func edgeBlur(_ img: CIImage, radius: Double) -> CIImage {
        let g = CIFilter.radialGradient()
        g.center = CGPoint(x: w / 2, y: h / 2)
        g.radius0 = Float(h * 0.36)
        g.radius1 = Float(w * 0.62)
        g.color0 = CIColor.black
        g.color1 = CIColor.white
        let f = CIFilter.maskedVariableBlur()
        f.inputImage = img.clampedToExtent()
        f.mask = g.outputImage!.cropped(to: extent)
        f.radius = Float(radius)
        return f.outputImage!.cropped(to: extent)
    }

    // Split R and B: `radial` scales them apart around the centre (lens fringing), `shift` moves them sideways (px, signal error).
    func chroma(_ img: CIImage, radial: Double, shift: Double) -> CIImage {
        let c = CGPoint(x: w / 2, y: h / 2)
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, scale: Double, dx: Double) -> CIImage {
            let m = CIFilter.colorMatrix()
            m.inputImage = img.clampedToExtent()
            m.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let t = CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: c.x + dx, y: c.y))
            return m.outputImage!.transformed(by: t)
        }
        let red = channel(1, 0, 0, scale: 1 + radial, dx: shift)
        let green = channel(0, 1, 0, scale: 1, dx: 0)
        let blue = channel(0, 0, 1, scale: 1 - radial, dx: -shift)
        return red.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: extent)
    }

    // Analog interference: horizontal slices shoved sideways, an RGB split, a tinted band and white-noise bars.
    func interference(_ img: CIImage, amount a: Double, seed: Int) -> CIImage {
        var r = Rand(seed, 4242)
        var out = chroma(img, radial: 0, shift: (4 + 10 * r.next()) * a)
        let clamped = out.clampedToExtent()
        let bands = 2 + Int(r.next() * 5 * a)
        for _ in 0..<bands {
            let bh = r.range(6, 90) * (0.5 + a)
            let y = r.range(0, Double(h) - bh)
            let dx = r.sign() * r.range(12, 140) * a
            let rect = CGRect(x: 0, y: y, width: Double(w), height: bh)
            out = over(clamped.transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: rect), out)
        }
        if r.next() < 0.6 * a {                                     // one tinted band (magenta or cyan)
            let bh = r.range(20, 120)
            let rect = CGRect(x: 0, y: r.range(0, Double(h) - bh), width: Double(w), height: bh)
            let tint = r.next() < 0.5 ? CIColor(red: 1, green: 0.25, blue: 0.64) : CIColor(red: 0.2, green: 0.9, blue: 1)
            let band = solid(tint, alpha: 0.35 * a).cropped(to: rect)
            out = band.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: out])
        }
        let noise = grayNoise(seed: seed, alpha: 0.55 * a)
        for _ in 0..<(1 + Int(r.next() * 3 * a)) {                   // white-noise bars
            let bh = r.range(2, 18)
            let rect = CGRect(x: 0, y: r.range(0, Double(h) - bh), width: Double(w), height: bh)
            out = over(noise.cropped(to: rect), out)
        }
        return out.cropped(to: extent)
    }

    // VHS tracking: `count` strips rolling down the frame, each shoved sideways (smoothly, not per-frame noise), split R/B,
    // lifted, with a bright leading edge and a little snow.
    func trackingBands(_ img: CIImage, amount a: Double, count: Int, size: Double, u: Double, seed: Int, frame: Int) -> CIImage {
        var r = Rand(seed, 2024)
        let src = chroma(img, radial: 0, shift: 7 * a).clampedToExtent()
        var out = img
        let t = u / 24
        for i in 0..<count {
            let phase = r.next(), speed = 0.18 + 0.22 * r.next(), bh = Double(h) * size * (0.6 + 0.8 * r.next())
            let y = ((phase + t * speed).truncatingRemainder(dividingBy: 1)) * (Double(h) + bh * 2) - bh
            let dx = a * (18 + 40 * r.next()) * sin(t * (5 + 4 * r.next()) + Double(i) * 1.7)
            let rect = CGRect(x: 0, y: Double(h) - y - bh, width: Double(w), height: bh)
            let lift = CIFilter.exposureAdjust()
            lift.inputImage = src.transformed(by: CGAffineTransform(translationX: dx, y: 0))
            lift.ev = Float(0.35 * a)
            out = over(lift.outputImage!.cropped(to: rect), out)
            out = over(grayNoise(seed: frame &+ i, alpha: 0.12 * a).cropped(to: rect), out)
            let edge = CGRect(x: 0, y: rect.maxY - 2, width: Double(w), height: 2)
            out = over(solid(CIColor(red: 1, green: 1, blue: 1), alpha: 0.35 * a).cropped(to: edge), out)
        }
        return out.cropped(to: extent)
    }

    // A worn CRT: softer, faded colour, scanlines, grain, vignette and a slow bright bar rolling down.
    func oldTV(_ img: CIImage, amount a: Double, grain: Double, frame: Int, u: Double) -> CIImage {
        var out = img
        let soft = CIFilter.gaussianBlur()
        soft.inputImage = out.clampedToExtent()
        soft.radius = Float(1.1 * a)
        out = soft.outputImage!.cropped(to: extent)
        out = chroma(out, radial: 0, shift: 2.5 * a)
        let cc = CIFilter.colorControls()
        cc.inputImage = out
        cc.saturation = Float(1 - 0.35 * a)
        cc.contrast = Float(1 + 0.1 * a)
        cc.brightness = Float(0.02 * a)
        out = cc.outputImage!
        let tint = CIFilter.colorMatrix()                           // a little green-warm phosphor cast
        tint.inputImage = out
        tint.rVector = CIVector(x: 1 - 0.02 * a, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: 1 + 0.02 * a, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: 1 - 0.08 * a, w: 0)
        out = tint.outputImage!.cropped(to: extent)

        let stripes = CIFilter.stripesGenerator()                  // vertical stripes, turned into scanlines
        stripes.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.26 * a)
        stripes.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        stripes.width = 1.5
        stripes.sharpness = 0.6
        let lines = stripes.outputImage!.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: extent)
        out = over(lines, out)
        if grain > 0 { out = over(grayNoise(seed: frame, alpha: grain * a), out) }

        let y = CGFloat((u * 9).truncatingRemainder(dividingBy: Double(h + 400))) - 200
        let bar = CIFilter.gaussianGradient()
        bar.center = CGPoint(x: w / 2, y: h - y)
        bar.radius = 70
        bar.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.07 * a)
        bar.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        let band = bar.outputImage!
            .transformed(by: CGAffineTransform(translationX: -w / 2, y: 0).concatenating(CGAffineTransform(scaleX: 20, y: 1))
            .concatenating(CGAffineTransform(translationX: w / 2, y: 0))).cropped(to: extent)
        out = band.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: out])

        let v = CIFilter.vignetteEffect()
        v.inputImage = out
        v.center = CGPoint(x: w / 2, y: h / 2)
        v.radius = Float(w * 0.55)
        v.intensity = Float(0.55 * a)
        v.falloff = 0.55
        return v.outputImage!.cropped(to: extent)
    }

    // Film grain: soft, slightly clumped grey noise soft-light blended (strongest in midtones, faint on white paper and deep navy),
    // dissolved in by `amount` (0.1 barely there, 0.25 visible, 0.5 heavy).
    func filmGrain(_ img: CIImage, amount: Double, frame: Int) -> CIImage {
        var r = Rand(frame, 5150)
        let raw = CIFilter.randomGenerator().outputImage!
            .transformed(by: CGAffineTransform(translationX: r.range(-4000, 0), y: r.range(-4000, 0)))
        let m = CIFilter.colorMatrix()                              // opaque grey from the red channel
        m.inputImage = raw
        m.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        m.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let soft = CIFilter.gaussianBlur()
        soft.inputImage = m.outputImage!
        soft.radius = 0.7
        let grained = soft.outputImage!.cropped(to: extent)
            .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img])
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = img
        mix.targetImage = grained.cropped(to: extent)
        mix.time = Float(min(1, amount))
        return mix.outputImage!.cropped(to: extent)
    }

    // MARK: helpers

    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: (1 - p.y) * h) }

    func solid(_ c: CIColor, alpha: Double) -> CIImage {
        CIImage(color: CIColor(red: c.red, green: c.green, blue: c.blue, alpha: alpha)).cropped(to: extent)
    }

    func over(_ top: CIImage, _ bottom: CIImage) -> CIImage { top.composited(over: bottom) }

    func grayNoise(seed: Int, alpha: Double) -> CIImage {
        var r = Rand(seed, 99)
        let n = CIFilter.randomGenerator().outputImage!
            .transformed(by: CGAffineTransform(translationX: r.range(-4000, 0), y: r.range(-4000, 0)))
        let m = CIFilter.colorMatrix()
        m.inputImage = n
        m.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)                 // grey from the red channel, at a fixed opacity
        m.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        m.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))
        return m.outputImage!.cropped(to: extent)
    }

    static func color(_ hex: String) -> CIColor {
        let v = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        return CIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255)
    }
}
