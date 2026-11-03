import Foundation

/// Placeholder core: an animated pattern, key echo, and a tone while A is held.
/// It emulates NOTHING. It exists so the app, renderer, audio and input paths can be built and verified
/// before the real console core lands, and it says so via `statusNote`.
public final class TestPatternCore: EmulatorCore {
    public var statusNote: String? { "Placeholder core — no GBA emulation yet. This is a test pattern." }
    public var screenWidth: Int { GBAConstants.screenWidth }
    public var screenHeight: Int { GBAConstants.screenHeight }
    public var framesPerSecond: Double { GBAConstants.framesPerSecond }
    public var audioSampleRate: Int { 48_000 }

    private var frame: UInt32 = 0
    private var keys: GBAKeys = []
    private var tonePhase: Double = 0
    private var audioCarry: Double = 0
    private var audio = [Int16](repeating: 0, count: 4096 * 2)
    private var audioFrames = 0

    public init() {}

    public func reset() { frame = 0; tonePhase = 0; audioCarry = 0; audioFrames = 0 }
    public func setKeys(_ keys: GBAKeys) { self.keys = keys }

    public func runFrame(framebuffer: UnsafeMutablePointer<UInt32>) {
        let w = screenWidth, h = screenHeight
        let t = Double(frame) * 0.03
        for y in 0..<h {
            let fy = Double(y) / Double(h)
            for x in 0..<w {
                let fx = Double(x) / Double(w)
                let v = sin(fx * 7 + t) + sin(fy * 9 - t * 1.3) + sin((fx + fy) * 6 + t * 0.7)
                let r = UInt32(max(0, min(255, 120 + 90 * sin(v + 0.0))))
                let g = UInt32(max(0, min(255, 110 + 90 * sin(v + 2.1))))
                let b = UInt32(max(0, min(255, 140 + 100 * sin(v + 4.2))))
                framebuffer[y * w + x] = 0xFF00_0000 | (r << 16) | (g << 8) | b
            }
        }
        drawKeyEcho(framebuffer, w, h)
        frame &+= 1
        generateAudio()
    }

    public func readAudio(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int {
        let n = min(audioFrames, maxFrames)
        audio.withUnsafeBufferPointer { src in
            buffer.update(from: src.baseAddress!, count: n * 2)
        }
        // Keep any remainder at the front (normally zero: the caller drains every frame).
        if n < audioFrames {
            let rest = audioFrames - n
            audio.withUnsafeMutableBufferPointer { p in
                for i in 0..<(rest * 2) { p[i] = p[n * 2 + i] }
            }
        }
        audioFrames -= n
        return n
    }

    // MARK: - private

    private func generateAudio() {
        let rate = Double(audioSampleRate)
        audioCarry += rate / framesPerSecond
        let count = min(Int(audioCarry), 2048)
        audioCarry -= Double(count)
        let active = keys.contains(.a)
        let step = 2 * Double.pi * 440 / rate
        let start = audioFrames
        for i in 0..<count {
            let s: Int16 = active ? Int16(sin(tonePhase) * 6000) : 0
            tonePhase += step
            if tonePhase > 2 * Double.pi { tonePhase -= 2 * Double.pi }
            audio[(start + i) * 2] = s
            audio[(start + i) * 2 + 1] = s
        }
        audioFrames = start + count
    }

    private func drawKeyEcho(_ fb: UnsafeMutablePointer<UInt32>, _ w: Int, _ h: Int) {
        let order: [GBAKeys] = [.l, .r, .select, .start, .left, .up, .down, .right, .b, .a]
        let size = 10, gap = 4
        let total = order.count * size + (order.count - 1) * gap
        var x0 = (w - total) / 2
        let y0 = h - size - 8
        for k in order {
            let color: UInt32 = keys.contains(k) ? 0xFFFF_FFFF : 0xFF18_1818
            for y in y0..<(y0 + size) { for x in x0..<(x0 + size) { fb[y * w + x] = color } }
            x0 += size + gap
        }
    }
}
