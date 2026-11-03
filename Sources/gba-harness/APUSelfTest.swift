import Foundation
import GBACore

// Programs the sound registers directly, runs emulated time, and analyses the audio that comes out (pitch, silence, decay).

func apuSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name): \(detail)")
    }
    let io: UInt32 = 0x0400_0000

    func fresh() -> GBASystem { let g = GBASystem(); g.load(rom: Data(count: 0x200)); return g }
    /// Run `seconds` of emulated time in small steps (so timers and DMA are serviced), returning left-channel samples.
    func run(_ g: GBASystem, _ seconds: Double) -> [Int16] {
        let end = g.bus.cycles + UInt64(seconds * 16_777_216)
        var out = [Int16]()
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 2 * 8192)
        defer { scratch.deallocate() }
        while g.bus.cycles < end {
            g.bus.cycles += 256
            g.bus.runEvents()
            if (g.bus.cycles >> 8) & 0x3F == 0 {
                let n = g.bus.apu.drain(into: scratch, maxFrames: 8192)
                for i in 0..<n { out.append(scratch[i * 2]) }
            }
        }
        let n = g.bus.apu.drain(into: scratch, maxFrames: 8192)
        for i in 0..<n { out.append(scratch[i * 2]) }
        return out
    }
    func frequency(_ s: ArraySlice<Int16>) -> Double {
        var crossings = 0
        var prev = s.first ?? 0
        for v in s.dropFirst() { if prev <= 0 && v > 0 { crossings += 1 }; prev = v }
        return Double(crossings) / (Double(s.count) / 48_000)
    }
    func peak(_ s: ArraySlice<Int16>) -> Int { s.map { abs(Int($0)) }.max() ?? 0 }
    func masterOn(_ g: GBASystem, channelsBothSides: UInt16) {
        g.bus.poke16(io + 0x84, 0x80)
        g.bus.poke16(io + 0x80, 0x77 | channelsBothSides << 8)        // volume 7/7, selected PSG channels left+right
        g.bus.poke16(io + 0x82, 0x0002)                                // PSG at 100%
    }

    do {  // pulse channel pitch
        let g = fresh()
        masterOn(g, channelsBothSides: 0x11)
        g.bus.poke16(io + 0x62, 0xF000 | 2 << 6)                       // volume 15, 50% duty
        g.bus.poke16(io + 0x64, 0x8000 | 1750)                         // 131072 / (2048-1750) = 439.8 Hz
        let s = run(g, 1.0)
        let f = frequency(s[4800...])
        check("pulse: pitch", abs(f - 439.8) < 3, String(format: "%.1f Hz (expected 439.8)", f))
        check("pulse: audible level", peak(s[4800...]) > 2000, "peak \(peak(s[4800...]))")
        check("pulse: status bit set", g.bus.peek16(io + 0x84) & 1 == 1, "SOUNDCNT_X = \(String(g.bus.peek16(io + 0x84), radix: 16))")
    }
    do {  // length counter
        let g = fresh()
        masterOn(g, channelsBothSides: 0x11)
        g.bus.poke16(io + 0x62, 0xF000 | 2 << 6 | 48)                  // length = 64 - 48 = 16 ticks of 1/256 s = 62.5 ms
        g.bus.poke16(io + 0x64, 0xC000 | 1750)
        let s = run(g, 0.3)
        check("length: sounds at first", peak(s[480..<1440]) > 2000, "peak \(peak(s[480..<1440]))")
        check("length: silent after it expires", peak(s[6000...]) < 50, "peak \(peak(s[6000...]))")
        check("length: status bit cleared", g.bus.peek16(io + 0x84) & 1 == 0, "")
    }
    do {  // envelope decay
        let g = fresh()
        masterOn(g, channelsBothSides: 0x11)
        g.bus.poke16(io + 0x62, 0xF000 | 1 << 8 | 2 << 6)              // start 15, decrease, one step per 1/64 s
        g.bus.poke16(io + 0x64, 0x8000 | 1750)
        let s = run(g, 0.6)
        let early = peak(s[0..<1000]), late = peak(s[24000...])
        check("envelope: starts loud, ends quiet", early > 3000 && late < 60, "early \(early), late \(late)")
    }
    do {  // frequency sweep rises
        let g = fresh()
        masterOn(g, channelsBothSides: 0x11)
        g.bus.poke16(io + 0x60, 7 << 4 | 8 | 2)                        // every 7/128 s, subtract freq/4
        g.bus.poke16(io + 0x62, 0xF000 | 2 << 6)
        g.bus.poke16(io + 0x64, 0x8000 | 1600)                         // 292 Hz, then 154 Hz after the first step
        let s = run(g, 0.3)
        let a = frequency(s[0..<2400]), b = frequency(s[4000..<6000])
        check("sweep: pitch moves down", b < a * 0.75 && b > 100, String(format: "%.0f Hz then %.0f Hz (expected ~292 then ~154)", a, b))
    }
    do {  // wave channel
        let g = fresh()
        masterOn(g, channelsBothSides: 0x44)
        g.bus.poke16(io + 0x70, 0x80)                                  // wave on, bank 0 playing (CPU writes bank 1)
        g.bus.poke16(io + 0x70, 0x80 | 0x40)                           // play bank 1 so the CPU fills bank 0
        for i in 0..<16 { g.bus.poke8(io + 0x90 + UInt32(i), UInt8(i << 4 | i)) }                   // sample n = n/2: a 32-sample ramp 0...15
        g.bus.poke16(io + 0x70, 0x80)
        g.bus.poke16(io + 0x72, 0x2000)                                // 100% volume
        g.bus.poke16(io + 0x74, 0x8000 | 1984)                         // 2097152 / (32 * 64) = 1024 Hz
        let s = run(g, 0.5)
        let f = frequency(s[4800...])
        check("wave: pitch", abs(f - 1024) < 25, String(format: "%.1f Hz (expected 1024)", f))
        check("wave: audible", peak(s[4800...]) > 500, "peak \(peak(s[4800...]))")
    }
    do {  // noise
        let g = fresh()
        masterOn(g, channelsBothSides: 0x88)
        g.bus.poke16(io + 0x78, 0xF000)
        g.bus.poke16(io + 0x7C, 0x8000 | 0x33)                         // divisor 3, shift 3
        let s = run(g, 0.3)
        let mean = s[4800...].reduce(0.0) { $0 + Double($1) } / Double(s.count - 4800)
        let variance = s[4800...].reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(s.count - 4800)
        check("noise: produces a varying signal", variance > 1e5, String(format: "std %.0f", sqrt(variance)))
    }
    do {  // direct sound through timer + DMA
        let g = fresh(), b = g.bus
        for i in 0..<8192 { b.poke8(0x0200_0000 + UInt32(i), (i / 32) % 2 == 0 ? 80 : 0xB0) }     // 512 Hz square at 32768 Hz
        b.poke16(io + 0x84, 0x80)
        b.poke16(io + 0x82, 0x0200 | 0x0100 | 0x0004 | 0x0800 | 0x0002)    // A to both sides, full volume, timer 0, reset FIFO
        b.poke32(io + 0xBC, 0x0200_0000); b.poke32(io + 0xC0, 0x0400_00A0)
        b.poke32(io + 0xC4, 4 | (0x8000 | 0x400 | 0x200 | 3 << 12 | 2 << 5) << 16)   // DMA1: special timing, repeat, 32-bit, fixed dest
        b.poke16(io + 0x100, 0xFE00); b.poke16(io + 0x102, 0x0080)          // timer 0 at 32768 Hz
        let s = run(g, 0.25)
        let f = frequency(s[2400...])
        check("FIFO: DMA keeps it fed, pitch is the pattern's", abs(f - 512) < 12, String(format: "%.1f Hz (expected 512)", f))
        check("FIFO: audible", peak(s[2400...]) > 1000, "peak \(peak(s[2400...]))")
    }
    do {  // silence when off
        let g = fresh()
        let s = run(g, 0.1)
        check("master off: silent", peak(s[...]) == 0, "peak \(peak(s[...]))")
        check("master off: sample count is time x 48 kHz", abs(s.count - 4800) <= 16, "\(s.count) samples for 0.1 s")
    }

    print(failures == 0 ? "PASS: APU self-check" : "FAIL: \(failures) APU check(s)")
    return failures == 0 ? 0 : 1
}
