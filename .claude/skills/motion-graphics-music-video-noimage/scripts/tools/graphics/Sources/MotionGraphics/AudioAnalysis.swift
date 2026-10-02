import Foundation
import AVFoundation
import Accelerate

public struct AudioFeatures: Codable {
    public let fps: Double, sampleRate: Double
    public let rms: [Float], peak: [Float], bands: [[Float]]
}
/// Offline streaming analysis: one audio window in memory, reusable Accelerate DFT buffers.
public final class AudioAnalyzer {
    public init() {}
    public func analyze(url: URL, fps: Double = 24, fftSize: Int = 2048, bandCount: Int = 32) throws -> AudioFeatures {
        guard fps > 0 && fps <= 240, fps.isFinite, fftSize >= 32, fftSize <= 32768,
              fftSize.nonzeroBitCount == 1, bandCount > 0, bandCount <= fftSize/2 else { throw GraphicsError.invalid("Invalid audio analysis settings") }
        let file = try AVAudioFile(forReading:url), format = file.processingFormat
        let hop = Int(ceil(format.sampleRate/fps))
        guard hop > 0, let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(hop)),
              let setup = vDSP_DFT_zop_CreateSetup(nil,vDSP_Length(fftSize),.FORWARD) else { throw GraphicsError.unavailable("Audio/DFT allocation failed") }
        defer { vDSP_DFT_DestroySetup(setup) }
        var real = [Float](repeating:0,count:fftSize), imag = real, outR = real, outI = real, window = real
        vDSP_hann_window(&window,vDSP_Length(fftSize),Int32(vDSP_HANN_NORM))
        var mono = [Float](repeating:0,count:hop), rms: [Float] = [], peaks: [Float] = [], bands: [[Float]] = []
        var frame = 0
        while file.framePosition < file.length {
            // Rounded absolute sample boundaries prevent cumulative drift at fractional frame rates.
            let start = AVAudioFramePosition((Double(frame)*format.sampleRate/fps).rounded())
            let end = AVAudioFramePosition((Double(frame+1)*format.sampleRate/fps).rounded())
            let length = Int(min(file.length-start,end-start))
            if length <= 0 { break }
            file.framePosition = start; try file.read(into:buffer,frameCount:AVAudioFrameCount(length))
            guard let channels = buffer.floatChannelData else { throw GraphicsError.unavailable("Float PCM required") }
            for i in 0..<length { var v: Float = 0; for ch in 0..<Int(format.channelCount) { v += channels[ch][i] }; mono[i] = v/Float(format.channelCount) }
            var r: Float = 0, peak: Float = 0
            vDSP_rmsqv(mono,1,&r,vDSP_Length(length)); vDSP_maxmgv(mono,1,&peak,vDSP_Length(length)); rms.append(r); peaks.append(peak)
            for i in 0..<fftSize { real[i] = i < length ? mono[i]*window[i] : 0 }; for i in 0..<fftSize { imag[i] = 0 }
            vDSP_DFT_Execute(setup,real,imag,&outR,&outI)
            var row = [Float](repeating:0,count:bandCount)
            for i in 1..<fftSize/2 { let band = min(bandCount-1,Int(log2(Double(i)+1)/log2(Double(fftSize/2))*Double(bandCount))); row[band] = max(row[band],hypot(outR[i],outI[i])/Float(fftSize)) }
            bands.append(row); frame += 1
        }
        return AudioFeatures(fps:fps,sampleRate:format.sampleRate,rms:rms,peak:peaks,bands:bands)
    }
}
