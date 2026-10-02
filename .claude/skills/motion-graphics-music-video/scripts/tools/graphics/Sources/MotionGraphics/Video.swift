import Foundation
import AVFoundation
import CoreImage

/// Sequential decode with one frame of lookahead. The reader does not retain decoded video in RAM.
public final class VideoSource {
    private let reader: AVAssetReader, output: AVAssetReaderTrackOutput
    private let transform: CGAffineTransform
    private var current: CMSampleBuffer?, next: CMSampleBuffer?
    private var previousTime = -Double.infinity
    public let duration: Double
    public init(url: URL) async throws {
        let asset = AVURLAsset(url:url)
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw GraphicsError.invalid("Video has no picture track") }
        duration = try await asset.load(.duration).seconds; transform = try await track.load(.preferredTransform)
        reader = try AVAssetReader(asset:asset)
        output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw GraphicsError.unavailable("Cannot attach video decoder") }; reader.add(output)
        guard reader.startReading() else { throw reader.error ?? GraphicsError.io("Cannot start video decoder") }
        next = output.copyNextSampleBuffer()
    }
    public func image(at seconds: Double, size: CGSize) throws -> CIImage {
        guard seconds.isFinite, seconds >= 0, seconds >= previousTime else { throw GraphicsError.invalid("VideoSource requires nondecreasing, nonnegative times; create a new source to seek backward") }
        previousTime = seconds
        while let sample = next, CMSampleBufferGetPresentationTimeStamp(sample).seconds <= seconds + 1e-8 {
            current = sample; next = output.copyNextSampleBuffer()
        }
        if reader.status == .failed { throw reader.error ?? GraphicsError.io("Video decoding failed") }
        guard let sample = current ?? next, let buffer = CMSampleBufferGetImageBuffer(sample) else { throw GraphicsError.io("Video contains no decodable frames") }
        var image = CIImage(cvPixelBuffer:buffer).transformed(by:transform)
        image = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
        let scale = max(size.width/image.extent.width,size.height/image.extent.height)
        image = image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        return image.transformed(by:CGAffineTransform(translationX:(size.width-image.extent.width)/2,y:(size.height-image.extent.height)/2)).cropped(to:CGRect(origin:.zero,size:size))
    }
    deinit { reader.cancelReading() }
}

/// Streams compressed audio into the same writer as the picture; no intermediate movie/mux file.
public final class AudioSource {
    let reader: AVAssetReader, input: AVAssetWriterInput
    private let output: AVAssetReaderTrackOutput, offset: CMTime
    private var next: CMSampleBuffer?
    private var finished = false
    public init?(url: URL, start: Double = 0, duration: Double) async throws {
        let asset = AVURLAsset(url:url)
        guard let track = try await asset.loadTracks(withMediaType:.audio).first else { return nil }
        let total = try await asset.load(.duration).seconds
        guard start >= 0, duration > 0, total > start else { throw GraphicsError.invalid("Invalid audio source range") }
        offset = CMTime(seconds:start,preferredTimescale:600_000)
        reader = try AVAssetReader(asset:asset)
        reader.timeRange = CMTimeRange(start:offset,duration:CMTime(seconds:min(duration,total-start),preferredTimescale:600_000))
        let format = try await track.load(.formatDescriptions).first
        let passthrough = start == 0 && (format.map { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC } ?? false)
        let channels = min(2,Int(format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2))
        let pcm: [String:Any] = [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:channels,
                                AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsNonInterleaved:false]
        output = AVAssetReaderTrackOutput(track:track,outputSettings:passthrough ? nil : pcm); output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw GraphicsError.unavailable("Cannot read audio") }; reader.add(output)
        let settings: [String:Any]? = passthrough ? nil : [AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:channels,AVEncoderBitRateKey:192000]
        input = AVAssetWriterInput(mediaType:.audio,outputSettings:settings,sourceFormatHint:passthrough ? format : nil)
        input.expectsMediaDataInRealTime = false
        guard reader.startReading() else { throw reader.error ?? GraphicsError.io("Audio reader start failed") }
        next = readSample()
    }
    // Compressed readers also emit zero-sample end markers with invalid timestamps.
    // Do not let one block EOF detection and leave the writer waiting for more audio.
    private func readSample() -> CMSampleBuffer? {
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { return sample }
        }
        return nil
    }
    func append(through seconds: Double) async throws {
        guard !finished else { return }
        while let sample = next, (CMSampleBufferGetPresentationTimeStamp(sample)-offset).seconds <= seconds {
            // No wall-clock timeout: the writer holds audio back until the picture catches up (about a second of media), and a
            // slow render (60 fps, supersampled) can take minutes per second of video. The writer cancels this task if it fails.
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds:2_000_000)
            }
            var shifted: CMSampleBuffer = sample
            if offset != .zero {
                var count = 0
                guard CMSampleBufferGetSampleTimingInfoArray(sample,entryCount:0,arrayToFill:nil,entriesNeededOut:&count) == noErr else { throw GraphicsError.io("Audio sample timing unavailable") }
                var timing = [CMSampleTimingInfo](repeating:CMSampleTimingInfo(),count:count)
                CMSampleBufferGetSampleTimingInfoArray(sample,entryCount:count,arrayToFill:&timing,entriesNeededOut:nil)
                for i in timing.indices {
                    timing[i].presentationTimeStamp = timing[i].presentationTimeStamp-offset
                    if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp-offset }
                }
                var copy: CMSampleBuffer?
                guard CMSampleBufferCreateCopyWithNewTiming(allocator:kCFAllocatorDefault,sampleBuffer:sample,sampleTimingEntryCount:count,sampleTimingArray:&timing,sampleBufferOut:&copy) == noErr, let copy else { throw GraphicsError.io("Audio timestamp adjustment failed") }
                shifted = copy
            }
            guard input.append(shifted) else { throw GraphicsError.io("Audio passthrough append failed; check container/codec compatibility") }
            next = readSample()
        }
        if reader.status == .failed { throw reader.error ?? GraphicsError.io("Audio decoding failed") }
        if next == nil { finish() }
    }
    func finish() { if !finished { finished = true; input.markAsFinished() } }
    deinit { reader.cancelReading() }
}

public enum VideoCodec: String { case h264, hevc, prores4444 }
/// Pooled BGRA buffers go directly from Core Image to AVAssetWriter. No PNG or raw-video pipe.
public final class VideoWriter {
    private let writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var lastFrame = -1, finished = false
    private let audio: AudioSource?
    private var audioTask: Task<Void,Error>?
    public let fps: Double
    /// bitrate: average bits/s for H.264/HEVC (nil = 0.18 bit per pixel per frame, at least 2 Mb/s).
    public init(url: URL, width: Int, height: Int, fps: Double, codec: VideoCodec = .h264, audio: AudioSource? = nil, bitrate: Int? = nil) throws {
        guard width > 0, height > 0, fps.isFinite, fps > 0, fps <= 240 else { throw GraphicsError.invalid("Invalid video format") }
        guard !FileManager.default.fileExists(atPath:url.path) else { throw GraphicsError.io("Output already exists: \(url.path)") }
        if codec != .prores4444 && (width % 2 != 0 || height % 2 != 0) { throw GraphicsError.invalid("H.264/HEVC dimensions must be even") }
        if codec == .prores4444 && url.pathExtension.lowercased() != "mov" { throw GraphicsError.invalid("ProRes 4444 requires .mov") }
        if let bitrate { guard (100_000...400_000_000).contains(bitrate) else { throw GraphicsError.invalid("Bitrate must be 100k...400M bits/s") } }
        self.fps = fps; self.audio = audio
        writer = try AVAssetWriter(outputURL:url,fileType:url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        let avCodec: AVVideoCodecType = codec == .h264 ? .h264 : codec == .hevc ? .hevc : .proRes4444
        var settings: [String:Any] = [AVVideoCodecKey:avCodec,AVVideoWidthKey:width,AVVideoHeightKey:height,
            AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]]
        if codec != .prores4444 { settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey:bitrate ?? max(2_000_000,Int(Double(width*height)*fps*0.18)),AVVideoExpectedSourceFrameRateKey:fps] }
        input = AVAssetWriterInput(mediaType:.video,outputSettings:settings); input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
            kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:] ])
        guard writer.canAdd(input) else { throw GraphicsError.unavailable("Encoder unavailable: \(codec.rawValue)") }; writer.add(input)
        if let audio { guard writer.canAdd(audio.input) else { throw GraphicsError.unavailable("Audio codec is not supported by this container") }; writer.add(audio.input) }
        guard writer.startWriting() else { throw writer.error ?? GraphicsError.io("Encoder start failed") }
        writer.startSession(atSourceTime:.zero)
        // Each writer input must be fed independently: AVFoundation can wait for
        // the other track before declaring this input ready (including at frame 0).
        // The writer's backpressure bounds buffered audio; no full-track preload.
        if let audio { audioTask = Task { try await audio.append(through:.infinity); audio.finish() } }
    }
    public func append(_ image: CIImage, frame: Int, compositor: Compositor) async throws {
        guard !finished, frame == lastFrame+1 else { throw GraphicsError.invalid("Video frames must be contiguous starting at zero") }
        let deadline = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed || writer.status == .cancelled { audioTask?.cancel(); throw writer.error ?? GraphicsError.io("Encoder stopped") }
            guard Date() < deadline else { throw GraphicsError.io("Encoder backpressure timed out at frame \(frame)") }
            try await Task.sleep(nanoseconds:1_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else { throw GraphicsError.unavailable("Missing encoder pixel buffer pool") }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer) == kCVReturnSuccess, let buffer else { throw GraphicsError.unavailable("Pixel buffer allocation failed") }
        compositor.render(image,to:buffer)
        let timestamp = CMTime(seconds:Double(frame)/fps,preferredTimescale:600_000)
        guard adaptor.append(buffer,withPresentationTime:timestamp) else { throw writer.error ?? GraphicsError.io("Frame append failed") }; lastFrame = frame
    }
    public func finish() async throws {
        guard !finished, lastFrame >= 0 else { throw GraphicsError.invalid("Cannot finish an empty or finished movie") }
        input.markAsFinished()
        try await audioTask?.value
        audio?.finish()
        writer.endSession(atSourceTime:CMTime(seconds:Double(lastFrame+1)/fps,preferredTimescale:600_000))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? GraphicsError.io("Movie finalization failed") }
        finished = true
    }
    deinit { audioTask?.cancel(); if !finished { writer.cancelWriting() } }
}

public enum AudioMuxer {
    /// Copies encoded video and the available audio duration; longer audio is trimmed, shorter audio leaves silence.
    public static func mux(video: URL, audio: URL, output: URL) async throws {
        guard !FileManager.default.fileExists(atPath:output.path) else { throw GraphicsError.io("Output exists: \(output.path)") }
        let composition = AVMutableComposition(), v = AVURLAsset(url:video), a = AVURLAsset(url:audio)
        guard let vt = try await v.loadTracks(withMediaType:.video).first,
              let at = try await a.loadTracks(withMediaType:.audio).first else { throw GraphicsError.invalid("Mux requires picture and audio tracks") }
        let vd = try await v.load(.duration), ad = try await a.load(.duration)
        guard let cv = composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid),
              let ca = composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw GraphicsError.unavailable("Cannot create composition tracks") }
        try cv.insertTimeRange(CMTimeRange(start:.zero,duration:vd),of:vt,at:.zero)
        cv.preferredTransform = try await vt.load(.preferredTransform)
        try ca.insertTimeRange(CMTimeRange(start:.zero,duration:CMTimeMinimum(vd,ad)),of:at,at:.zero)
        guard let export = AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough) else { throw GraphicsError.unavailable("Cannot create mux session") }
        export.outputURL = output; export.outputFileType = output.pathExtension.lowercased() == "mov" ? .mov : .mp4
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in export.exportAsynchronously { continuation.resume() } }
        guard export.status == .completed else { throw export.error ?? GraphicsError.io("Audio mux failed (audio codec must be supported by the output container)") }
    }
}
