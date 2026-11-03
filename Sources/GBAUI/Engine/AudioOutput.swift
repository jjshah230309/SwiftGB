import AVFoundation
import Foundation

/// Plays interleaved stereo Int16 produced by the emulator through an AVAudioEngine source node.
/// A fixed ring buffer decouples the emulation thread (producer) from the realtime audio thread (consumer).
public final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private let lock = NSLock()
    private let capacity = 16_384                     // stereo frames (~340 ms at 48 kHz)
    private var ring: [Int16]
    private var readIndex = 0
    private var fill = 0
    /// Playback waits until this many frames (~33 ms) are queued, then runs until an underrun, so frame-time jitter doesn't crackle.
    private let primeFrames = 1_600
    private var primed = false
    private var volumeGain: Float = 1
    public private(set) var isRunning = false
    public let sampleRate: Double

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        self.ring = [Int16](repeating: 0, count: capacity * 2)
    }

    public var volume: Float {
        get { lock.lock(); defer { lock.unlock() }; return volumeGain }
        set { lock.lock(); volumeGain = max(0, min(1, newValue)); lock.unlock() }
    }

    public func start() {
        guard !isRunning else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false) else { return }
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList -> OSStatus in
            self?.render(bufferList, frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        node = source
        do {
            try engine.start()
            isRunning = true
        } catch {
            NSLog("SwiftGB: audio engine failed to start: \(error)")
            engine.detach(source)
            node = nil
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
        isRunning = false
        lock.lock(); readIndex = 0; fill = 0; primed = false; lock.unlock()
    }

    /// Producer side. Drops the oldest audio if the consumer has fallen behind.
    public func push(_ samples: UnsafePointer<Int16>, frames: Int) {
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        for i in 0..<frames {
            if fill == capacity { readIndex = (readIndex + 1) % capacity; fill -= 1 }
            let w = (readIndex + fill) % capacity
            ring[w * 2] = samples[i * 2]
            ring[w * 2 + 1] = samples[i * 2 + 1]
            fill += 1
        }
    }

    public var bufferedFrames: Int { lock.lock(); defer { lock.unlock() }; return fill }

    private func render(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        lock.lock()
        let gain = volumeGain / 32768
        if !primed && fill >= primeFrames { primed = true }
        let available = primed ? min(fill, frames) : 0
        if primed && fill < frames { primed = false }                 // ran dry: rebuild the cushion
        for i in 0..<available {
            let r = (readIndex + i) % capacity
            left[i] = Float(ring[r * 2]) * gain
            right[i] = Float(ring[r * 2 + 1]) * gain
        }
        readIndex = (readIndex + available) % capacity
        fill -= available
        lock.unlock()
        if available < frames {       // underrun -> silence
            for i in available..<frames { left[i] = 0; right[i] = 0 }
        }
    }
}
