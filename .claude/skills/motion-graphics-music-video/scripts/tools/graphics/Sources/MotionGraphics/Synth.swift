import Foundation

/// Procedural sound effects: offline, free and deterministic (same spec + seed = same samples). 48 kHz stereo.
/// The spec is a JSON object: {"synth": kind, "duration": s, "seed": n, ...knobs}. Kinds (knobs, defaults):
///   whoosh   band-passed noise swept up to a peak and back down, panned across: duration 0.8, from 250, to 3500 (Hz),
///            peak 0.7 (fraction of the duration where it is loudest), q 1.6, pan [-0.7, 0.7]
///   riser    noise + a sine sweep rising to an abrupt end (place it so it ENDS on the hit): duration 1.5, from 300, to 6000
///   reverse  reversed cymbal: bright noise swelling to an abrupt end: duration 1.0
///   impact   pitched-down thump with a click and a short noise tail: duration 0.9, freq 50
///   subdrop  sine glide down with a long decay: duration 1.4, from 90, to 30
///   tick     short sine blip: duration 0.035, freq 3200
///   type     one typewriter key: band-passed noise click and a low knock: duration 0.05
///   zap      fast descending FM blip: duration 0.25, from 2400, to 180
///   glitch   gated bursts of noise and square tones at random pitches, bit-crushed: duration 0.4
///   shimmer  detuned high sine cluster with a tremolo (sparkle): duration 1.2, freq 1800
/// Output peaks at -3 dBFS with a 4 ms declick at both ends (abrupt ends stay abrupt). `peakAt` is the loudest 10 ms block (s).
public enum SoundSynth {
    public static let rate = 48_000.0
    public static let defaults: [String:Double] = ["whoosh":0.8,"riser":1.5,"reverse":1.0,"impact":0.9,"subdrop":1.4,"tick":0.035,
                                                   "type":0.05,"zap":0.25,"glitch":0.4,"shimmer":1.2]
    public struct Sound {
        public var left: [Double], right: [Double], peakAt: Double
        public var duration: Double { Double(left.count)/SoundSynth.rate }
    }

    public static func render(_ spec: [String:Any]) throws -> Sound {
        guard let kind = spec["synth"] as? String, let fallback = defaults[kind] else {
            throw GraphicsError.invalid("synth must be one of \(defaults.keys.sorted().joined(separator:", "))")
        }
        func num(_ key: String, _ d: Double) throws -> Double {
            guard let v = spec[key] else { return d }
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw GraphicsError.invalid("synth \(key) must be a number") }
            return n.doubleValue
        }
        let duration = try num("duration",fallback)
        guard (0.005...30).contains(duration) else { throw GraphicsError.invalid("synth duration must be 0.005...30 s") }
        let n = Int(duration*rate), last = Double(n-1)/rate
        var rng = Random(seed:UInt64(max(0,try num("seed",1)))&*0x9E3779B97F4A7C15&+1)
        let t = (0..<n).map { Double($0)/rate }
        func noise() -> [Double] { (0..<n).map { _ in rng.gaussian() } }
        func sweep(_ a: Double, _ b: Double) -> [Double] { t.map { a*pow(b/a,$0/last) } }
        func phase(_ freq: [Double]) -> [Double] { var p = 0.0; return freq.map { f in defer { p += 2 * .pi*f/rate }; return p } }
        var l = [Double](repeating:0,count:n), r = l
        func pan(_ x: [Double], _ p: (Int) -> Double) {
            for i in 0..<n { let th = (p(i)+1) * .pi/4; l[i] = x[i]*cos(th); r[i] = x[i]*sin(th) }
        }
        switch kind {
        case "whoosh":
            let peak = min(0.98,max(0.02,try num("peak",0.7))), lo = try num("from",250), hi = try num("to",3500), q = try num("q",1.6)
            var p0 = -0.7, p1 = 0.7
            if let p = spec["pan"] as? [NSNumber], p.count == 2 { p0 = p[0].doubleValue; p1 = p[1].doubleValue }
            var fc = [Double](repeating:0,count:n), env = fc
            for i in 0..<n {
                let u = t[i]/last, up = min(1,u/peak), down = max(0,(u-peak)/(1-peak))
                fc[i] = lo*pow(hi/lo,up)*pow(lo*1.4/hi,down*0.8)
                env[i] = u < peak ? 0.03+0.97*up*up : exp(-4.5*down)
            }
            let x = zip(svf(noise(),fc,q:q),env).map(*)
            pan(x) { p0+(p1-p0)*t[$0]/last }
        case "riser":
            let fc = sweep(try num("from",300),try num("to",6000)), filtered = svf(noise(),fc,q:2.5), ph = phase(fc.map { $0/4 })
            let x = (0..<n).map { i -> Double in let u = t[i]/last; return (filtered[i]+sin(ph[i])*0.25)*(0.03+0.97*u*u*u) }
            pan(x) { sin(2 * .pi*0.7*t[$0])*0.3 }
        case "reverse":
            let bright = svf(noise(),[Double](repeating:5500,count:n),q:0.7,mode:.high)
            let phases = (0..<3).map { _ in rng.next()*2 * .pi }
            let x: [Double] = Array((0..<n).map { i -> Double in
                let shimmer = zip([6100.0,7330,8870],phases).map { sin(2 * .pi*$0*t[i]+$1) }.reduce(0,+)*0.05*exp(-t[i]/0.3)
                return bright[i]*exp(-t[i]/(last*0.28))+shimmer
            }.reversed())
            l = x; r = (0..<n).map { x[($0-37+n)%n] }
        case "impact":
            let f0 = try num("freq",50), ph = phase(t.map { f0+f0*2.5*exp(-$0/0.035) })
            let tail = svf(noise(),[Double](repeating:900,count:n),q:0.8,mode:.low), click = noise()
            for i in 0..<n {
                let body: Double = tanh(1.8*sin(ph[i]))*exp(-t[i]/(last*0.3))
                let hit: Double = click[i]*exp(-t[i]/0.004)*0.6
                l[i] = body+hit+tail[i]*exp(-t[i]/0.12)*0.35
            }
            r = l
        case "subdrop":
            let ph = phase(sweep(try num("from",90),try num("to",30)))
            for i in 0..<n { let body: Double = tanh(1.4*sin(ph[i]))*exp(-t[i]/(last*0.45)); l[i] = body*min(1,t[i]/0.01) }
            r = l
        case "tick":
            let f = try num("freq",3200), click = noise(), p = rng.next()*0.6-0.3
            let x = (0..<n).map { i -> Double in let tone: Double = sin(2 * .pi*f*t[i])*exp(-t[i]/(last*0.25)); return tone+click[i]*exp(-t[i]/0.0015)*0.3 }
            pan(x) { _ in p }
        case "type":
            let fc = 2200+rng.next()*1400, knock = 160+rng.next()*60, p = rng.next()*0.8-0.4
            let click = svf(noise(),[Double](repeating:fc,count:n),q:2)
            let x = (0..<n).map { i -> Double in let low: Double = sin(2 * .pi*knock*t[i])*exp(-t[i]/0.012)*0.5; return click[i]*exp(-t[i]/0.006)+low }
            pan(x) { _ in p }
        case "zap":
            let freq = sweep(try num("from",2400),try num("to",180)), ph = phase(freq)
            let x = (0..<n).map { i -> Double in let mod: Double = sin(2 * .pi*freq[i]*1.5*t[i])*2; return sin(ph[i]+mod)*exp(-t[i]/(last*0.4)) }
            pan(x) { -0.5+Double($0)/Double(max(n-1,1)) }
        case "glitch":
            var x = [Double](repeating:0,count:n), i = 0
            while i < n {
                let span = min(Int((0.012+rng.next()*0.033)*rate),n-i), kind = Int(rng.next()*3), level = 0.3+rng.next()*0.7, pitch = 200+rng.next()*2300
                for k in 0..<span {
                    let s = kind == 0 ? rng.gaussian() : kind == 1 ? (sin(2 * .pi*pitch*Double(k)/rate) >= 0 ? 0.6 : -0.6) : 0
                    x[i+k] = (s*level*6).rounded()/6
                }
                i += span
            }
            let p = rng.next()*1.2-0.6
            pan(x) { _ in p }
        default: // shimmer
            let f0 = try num("freq",1800), ratios = [1.0,1.5,2.01,2.52,3.03,4.1]
            let pl = ratios.map { _ in rng.next()*2 * .pi }, pr = ratios.map { _ in rng.next()*2 * .pi }
            for i in 0..<n {
                let e = min(1,t[i]/0.04)*exp(-t[i]/(last*0.35))*(0.7+0.3*sin(2 * .pi*12*t[i]))
                var a = 0.0, b = 0.0
                for (k,ratio) in ratios.enumerated() {
                    a += sin(2 * .pi*f0*ratio*t[i]+pl[k])/Double(k+1)
                    b += sin(2 * .pi*f0*ratio*1.003*t[i]+pr[k])/Double(k+1)
                }
                l[i] = a*e; r[i] = b*e
            }
        }
        let edge = min(Int(0.004*rate),n/4)
        for k in 0..<edge { let g = Double(k)/Double(max(edge,1)); l[k] *= g; r[k] *= g; l[n-1-k] *= g; r[n-1-k] *= g }
        let peak = zip(l,r).map { max(abs($0),abs($1)) }.max() ?? 0
        guard peak > 1e-9 else { throw GraphicsError.invalid("synth \(kind) produced silence") }
        let gain = pow(10,-3.0/20)/peak
        l = l.map { $0*gain }; r = r.map { $0*gain }
        let block = Int(0.01*rate), blocks = n/block
        var loudest = 0, best = -1.0
        for b in 0..<blocks {
            var e = 0.0; for i in b*block..<(b+1)*block { let m = max(abs(l[i]),abs(r[i])); e += m*m }
            if e > best { best = e; loudest = b }
        }
        return Sound(left:l,right:r,peakAt:Double(loudest)*0.01)
    }

    enum Mode { case band, low, high }
    /// Chamberlin state-variable filter with a per-sample cutoff (clamped to 20 Hz...rate/7 for stability).
    static func svf(_ x: [Double], _ fc: [Double], q: Double, mode: Mode = .band) -> [Double] {
        var low = 0.0, band = 0.0, out = [Double](repeating:0,count:x.count)
        let damp = 1/max(q,0.05)
        for i in 0..<x.count {
            let f = 2*sin(.pi*min(max(fc[i],20),rate/7)/rate)
            low += f*band
            let high = x[i]-low-damp*band
            band += f*high
            out[i] = mode == .band ? band : mode == .low ? low : high
        }
        return out
    }

    /// 16-bit PCM stereo WAV.
    public static func writeWAV(_ s: Sound, to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of:v.littleEndian) { data.append(contentsOf:$0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of:v.littleEndian) { data.append(contentsOf:$0) } }
        let bytes = UInt32(s.left.count*4)
        data.append(contentsOf:Array("RIFF".utf8)); u32(36+bytes); data.append(contentsOf:Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate)*4); u16(4); u16(16)
        data.append(contentsOf:Array("data".utf8)); u32(bytes)
        data.reserveCapacity(data.count+Int(bytes))
        for i in 0..<s.left.count {
            u16(UInt16(bitPattern:Int16((s.left[i]*32767).rounded())))
            u16(UInt16(bitPattern:Int16((s.right[i]*32767).rounded())))
        }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
    }
}
