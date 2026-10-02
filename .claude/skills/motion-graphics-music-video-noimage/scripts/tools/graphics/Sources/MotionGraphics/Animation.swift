import Foundation
import CoreGraphics

public struct FrameTime {
    public let frame: Int, fps: Double
    public var seconds: Double { Double(frame)/fps }
    public init(frame: Int, fps: Double) { precondition(fps.isFinite && fps > 0); self.frame = frame; self.fps = fps }
}
public enum Easing: String, Codable {
    case linear, inCubic, outCubic, inOutCubic, inExpo, outExpo, outBack, outElastic, smooth, hold
    public func evaluate(_ x: Double) -> Double {
        let x = min(1,max(0,x))
        switch self {
        case .linear: return x
        case .inCubic: return x*x*x
        case .outCubic: return 1-pow(1-x,3)
        case .inOutCubic: return x < 0.5 ? 4*x*x*x : 1-pow(-2*x+2,3)/2
        case .inExpo: return x == 0 ? 0 : pow(2,10*x-10)
        case .outExpo: return x == 1 ? 1 : 1-pow(2,-10*x)
        case .outBack: return 1+2.70158*pow(x-1,3)+1.70158*pow(x-1,2)
        case .outElastic: return x == 0 || x == 1 ? x : pow(2,-10*x)*sin((x*10-0.75)*2 * .pi/3)+1
        case .smooth: return x*x*(3-2*x)
        case .hold: return x < 1 ? 0 : 1
        }
    }
}
public struct Keyframe {
    public let time: Double, value: Double, easing: Easing
    public init(_ time: Double, _ value: Double, easing: Easing = .linear) { self.time = time; self.value = value; self.easing = easing }
}
/// Stateless sampling supports sparse previews, reverse seeking and repeatable exports.
public final class Track {
    public let keys: [Keyframe]
    public let repeatDuration: Double?
    public init(_ keys: [Keyframe], repeatDuration: Double? = nil) throws {
        guard !keys.isEmpty, keys.allSatisfy({ $0.time.isFinite && $0.value.isFinite }),
              zip(keys,keys.dropFirst()).allSatisfy({ $0.time < $1.time }),
              repeatDuration == nil || (repeatDuration!.isFinite && repeatDuration! > 0) else {
            throw GraphicsError.invalid("Keyframes need finite values and strictly increasing times; repeat duration must be positive")
        }
        self.keys = keys; self.repeatDuration = repeatDuration
    }
    public func value(at seconds: Double) -> Double {
        var t = seconds
        if let period = repeatDuration, t >= keys[0].time { t = keys[0].time+(t-keys[0].time).truncatingRemainder(dividingBy:period) }
        if t <= keys[0].time { return keys[0].value }
        if t >= keys.last!.time { return keys.last!.value }
        var low = 0, high = keys.count-1
        while high-low > 1 { let mid = (low+high)/2; if keys[mid].time <= t { low = mid } else { high = mid } }
        let a = keys[low], b = keys[high], p = b.easing.evaluate((t-a.time)/(b.time-a.time))
        return a.value+(b.value-a.value)*p
    }
}
public enum Motion {
    public static func progress(_ t: Double, start: Double, duration: Double, easing: Easing = .linear) -> Double {
        easing.evaluate(duration <= 0 ? (t >= start ? 1 : 0) : (t-start)/duration)
    }
    public static func envelope(_ t: Double, start: Double, end: Double, fadeIn: Double = 0, fadeOut: Double = 0) -> Double {
        guard t >= start && t < end else { return 0 }
        return min(fadeIn > 0 ? min(1,(t-start)/fadeIn) : 1, fadeOut > 0 ? min(1,(end-t)/fadeOut) : 1)
    }
    public static func shake(_ time: FrameTime, start: Double, duration: Double = 0.3, amplitude: Double = 14, seed: UInt64 = 1) -> CGPoint {
        let p = (time.seconds-start)/max(duration,1e-9)
        guard p >= 0 && p < 1 else { return .zero }
        var rng = Random(seed:seed &+ UInt64(bitPattern:Int64(time.frame)))
        let a = amplitude*pow(1-p,2); return CGPoint(x:(rng.next()*2-1)*a,y:(rng.next()*2-1)*a)
    }
    public static func typed(_ text: String, progress: Double) -> String { String(text.prefix(Int((Double(text.count)*min(1,max(0,progress))).rounded()))) }
    public static func beat(_ seconds: Double, bpm: Double, offset: Double = 0, decay: Double = 6) -> Double {
        guard seconds >= offset, bpm > 0 else { return 0 }
        let phase = ((seconds-offset)*bpm/60).truncatingRemainder(dividingBy:1)
        return exp(-decay*phase)
    }
}
public struct WordCue: Codable {
    public let w: String, s: Double, e: Double
    public init(_ word: String, start: Double, end: Double) { w = word; s = start; e = end }
}
public final class CueSheet {
    public let words: [WordCue]
    public init(_ words: [WordCue]) throws {
        guard words.allSatisfy({ $0.s.isFinite && $0.e.isFinite && $0.e >= $0.s }) else { throw GraphicsError.invalid("Invalid word cue interval") }
        self.words = words
    }
    public func cue(_ word: String, occurrence: Int = 1) throws -> WordCue {
        func normalized(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        let hits = words.filter { normalized($0.w) == normalized(word) }
        guard occurrence > 0, occurrence <= hits.count else { throw GraphicsError.invalid("Missing word cue \(word) #\(occurrence)") }
        return hits[occurrence-1]
    }
}
