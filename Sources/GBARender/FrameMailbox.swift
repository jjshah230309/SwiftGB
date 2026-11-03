import Foundation

/// Hand-off of finished frames from the emulation thread to the render thread.
/// The emulator publishes; the renderer copies out only when the generation has advanced.
public final class FrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pixels: [UInt32] = []
    private var width = 0
    private var height = 0
    private var generation: UInt64 = 0

    public init() {}

    public func publish(_ source: UnsafePointer<UInt32>, width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        let count = width * height
        if pixels.count != count { pixels = [UInt32](repeating: 0, count: count) }
        pixels.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: source, count: count) }
        self.width = width
        self.height = height
        generation &+= 1
    }

    /// If a newer frame exists than `seen`, copies it into `destination` and returns (generation, width, height).
    public func copyIfNew(since seen: UInt64, into destination: inout [UInt32]) -> (UInt64, Int, Int)? {
        lock.lock(); defer { lock.unlock() }
        guard generation != seen, width > 0 else { return nil }
        if destination.count != pixels.count { destination = [UInt32](repeating: 0, count: pixels.count) }
        destination.withUnsafeMutableBufferPointer { dst in
            pixels.withUnsafeBufferPointer { src in dst.baseAddress!.update(from: src.baseAddress!, count: src.count) }
        }
        return (generation, width, height)
    }
}
