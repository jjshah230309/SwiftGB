import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Records the emulated picture and sound to an MP4 (H.264 + AAC). Timestamps come from the emulated frame and sample counts,
/// not the wall clock, so a recording made while fast-forwarding still plays back at normal speed with sound in step.
public final class VideoRecorder: @unchecked Sendable {
    public enum RecorderError: Error { case couldNotStart(String) }

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int, scale: Int
    private let framesPerSecond: Double
    private let sampleRate: Int
    private let audioFormat: CMAudioFormatDescription
    private var frameCount = 0
    private var audioFrameCount = 0
    private var finished = false
    private let lock = NSLock()
    public let url: URL

    /// The enlargement actually used: at least `requested`, and enough that the shorter side is 640 pixels or more
    /// (smaller pictures take the system's slow software encoder, about a tenth of the speed).
    public static func effectiveScale(width: Int, height: Int, requested: Int) -> Int {
        max(requested, Int((640.0 / Double(max(1, min(width, height)))).rounded(.up)))
    }

    public var outputSize: (width: Int, height: Int) { (width * scale, height * scale) }

    /// `width` x `height` is the console's screen; the picture is enlarged by whole pixels (`scale`) so it stays sharp.
    public init(url: URL, width: Int, height: Int, scale requestedScale: Int = 5, framesPerSecond: Double, audioSampleRate: Int = 48_000) throws {
        let scale = VideoRecorder.effectiveScale(width: width, height: height, requested: requestedScale)
        self.url = url; self.width = width; self.height = height; self.scale = scale
        self.framesPerSecond = framesPerSecond; sampleRate = audioSampleRate
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width * scale, AVVideoHeightKey: height * scale,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        video.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width * scale, kCVPixelBufferHeightKey as String: height * scale,
        ])

        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(audioSampleRate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var desc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &desc) == noErr, let desc else {
            throw RecorderError.couldNotStart("audio format")
        }
        audioFormat = desc
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: audioSampleRate, AVEncoderBitRateKey: 160_000,
        ], sourceFormatHint: desc)
        audio.expectsMediaDataInRealTime = false

        guard writer.canAdd(video), writer.canAdd(audio) else { throw RecorderError.couldNotStart("inputs") }
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw RecorderError.couldNotStart(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)
    }

    private static let timescale: Int32 = 600_000

    /// Add one emulated frame and the sound it produced. Blocks briefly if the encoder is behind.
    public func append(frame: UnsafePointer<UInt32>, audio samples: UnsafePointer<Int16>?, audioFrames: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, writer.status == .writing else { return }
        appendVideo(frame)
        if let samples, audioFrames > 0 { appendAudio(samples, audioFrames) }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) -> Bool {
        var waited = 0
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing || waited > 3000 { return false }
            Thread.sleep(forTimeInterval: 0.001); waited += 1
        }
        return true
    }

    private func appendVideo(_ frame: UnsafePointer<UInt32>) {
        guard waitUntilReady(video), let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pb = buffer else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb) / 4
        let out = base.assumingMemoryBound(to: UInt32.self)
        let s = scale
        for y in 0..<(height * s) {
            let src = frame + (y / s) * width
            let row = out + y * stride
            if y % s != 0 { row.update(from: out + (y - y % s) * stride, count: width * s); continue }     // repeat the first row of each block
            for x in 0..<width {
                let p = src[x]
                let o = row + x * s
                for k in 0..<s { o[k] = p }
            }
        }
        let t = CMTime(value: Int64((Double(frameCount) / framesPerSecond * Double(Self.timescale)).rounded()), timescale: Self.timescale)
        if adaptor.append(pb, withPresentationTime: t) { frameCount += 1 }
    }

    private func appendAudio(_ samples: UnsafePointer<Int16>, _ frames: Int) {
        guard waitUntilReady(audio) else { return }
        let bytes = frames * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let block,
              CMBlockBufferAssureBlockMemory(block) == noErr,
              CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr else { return }
        var sample: CMSampleBuffer?
        let pts = CMTime(value: Int64(audioFrameCount), timescale: Int32(sampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: frames,
                                                                  presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if audio.append(sample) { audioFrameCount += frames }
    }

    public var framesWritten: Int { lock.lock(); defer { lock.unlock() }; return frameCount }

    /// Close the file. `completion` runs (on an arbitrary queue) with whether a playable file was produced.
    public func finish(completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); completion(false); return }
        finished = true
        let hadFrames = frameCount > 0
        video.markAsFinished(); audio.markAsFinished()
        lock.unlock()
        writer.finishWriting { [writer] in completion(hadFrames && writer.status == .completed) }
    }
}
