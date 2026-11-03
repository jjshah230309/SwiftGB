import Foundation

/// The Game Boy's four-channel sound chip: the same PSG channels as the GBA, behind the original register layout (FF10-FF3F).
/// Like the GBA's, it works in 8-dot ticks (524,288 per second), averaged down to 48 kHz.
final class GBAPU {
    unowned let system: GBSystem

    private let ringCapacity = 16_384
    private let ring = UnsafeMutablePointer<Int16>.allocate(capacity: 16_384 * 2)
    private var ringHead = 0, ringCount = 0

    private static let tickDots: UInt64 = 8
    private static let ticksPerSecond = 524_288
    private static let outputRate = 48_000
    private var lastTick: UInt64 = 0
    private var rateAccumulator = 0
    private var sumL = 0, sumR = 0, sumCount = 0
    private var sequencerTicks = 0, sequencerStep = 0
    private var prevInL = 0.0, prevInR = 0.0, prevOutL = 0.0, prevOutR = 0.0

    private let sq1 = PSGSquare(), sq2 = PSGSquare(), wave = PSGWave(), noise = PSGNoise()
    private var regs = [UInt8](repeating: 0, count: 0x30)       // raw NRxx values, indexed by address - 0xFF00
    private var masterOn = false

    init(system: GBSystem) {
        self.system = system
        sq1.hasSweep = true
    }

    deinit { ring.deallocate() }

    func silenceChannels() { sq1.enabled = false; sq2.enabled = false; wave.enabled = false; noise.enabled = false }

    // MARK: registers
    private static let readMask: [UInt8] = {
        var m = [UInt8](repeating: 0xFF, count: 0x30)
        let table: [(Int, UInt8)] = [(0x10, 0x80), (0x11, 0x3F), (0x12, 0x00), (0x13, 0xFF), (0x14, 0xBF), (0x16, 0x3F), (0x17, 0x00), (0x18, 0xFF), (0x19, 0xBF),
                                     (0x1A, 0x7F), (0x1B, 0xFF), (0x1C, 0x9F), (0x1D, 0xFF), (0x1E, 0xBF), (0x20, 0xFF), (0x21, 0x00), (0x22, 0x00), (0x23, 0xBF),
                                     (0x24, 0x00), (0x25, 0x00)]
        for (i, v) in table { m[i] = v }
        return m
    }()

    func read(_ o: UInt8) -> UInt8 {
        let i = Int(o)
        if o >= 0x30 { return wave.ram[i - 0x30] }
        if o == 0x26 {
            sync()
            return 0x70 | (masterOn ? 0x80 : 0) | (sq1.enabled ? 1 : 0) | (sq2.enabled ? 2 : 0) | (wave.enabled ? 4 : 0) | (noise.enabled ? 8 : 0)
        }
        guard i < 0x26 else { return 0xFF }
        return regs[i] | GBAPU.readMask[i]
    }

    func write(_ o: UInt8, _ v: UInt8) {
        let i = Int(o)
        if o >= 0x30 { wave.ram[i - 0x30] = v; return }
        if o == 0x26 {
            sync()
            let on = v & 0x80 != 0
            if !on && masterOn {
                // Every register clears and every channel stops, but (on the original hardware) the length counters survive.
                for k in 0x10..<0x26 { regs[k] = 0 }
                silenceChannels()
                for c in [sq1, sq2] { c.lengthEnabled = false; c.frequency = 0; c.duty = 0; c.env.load(0) }
                sq1.sweepShift = 0; sq1.sweepNegate = false; sq1.sweepPeriod = 0
                wave.lengthEnabled = false; wave.frequency = 0; wave.dacOn = false; wave.volumeCode = 0
                noise.lengthEnabled = false; noise.env.load(0); noise.shift = 0; noise.narrow = false; noise.divisor = 0
            } else if on && !masterOn {
                sequencerTicks = 0; sequencerStep = 0
            }
            masterOn = on
            return
        }
        guard i < 0x26 else { return }
        guard masterOn else {
            // While the chip is off only the length counters can still be written (original Game Boy behaviour).
            switch o {
            case 0x11: sq1.length = 64 - Int(v & 63)
            case 0x16: sq2.length = 64 - Int(v & 63)
            case 0x1B: wave.length = 256 - Int(v)
            case 0x20: noise.length = 64 - Int(v & 63)
            default: break
            }
            return
        }
        sync()
        regs[i] = v
        let r = Int(v)
        switch o {
        case 0x10:
            let wasNegate = sq1.sweepNegate
            sq1.sweepShift = r & 7; sq1.sweepNegate = r & 8 != 0; sq1.sweepPeriod = (r >> 4) & 7
            if wasNegate && !sq1.sweepNegate && sq1.sweepNegateUsed { sq1.enabled = false }
        case 0x11: sq1.length = 64 - (r & 63); sq1.duty = r >> 6
        case 0x12: sq1.env.load(r << 8); if !sq1.env.dacOn { sq1.enabled = false }
        case 0x13: sq1.frequency = (sq1.frequency & 0x700) | r
        case 0x14: sq1.frequency = (sq1.frequency & 0xFF) | (r & 7) << 8; lengthAndTrigger(v, sq1, maxLength: 64)
        case 0x16: sq2.length = 64 - (r & 63); sq2.duty = r >> 6
        case 0x17: sq2.env.load(r << 8); if !sq2.env.dacOn { sq2.enabled = false }
        case 0x18: sq2.frequency = (sq2.frequency & 0x700) | r
        case 0x19: sq2.frequency = (sq2.frequency & 0xFF) | (r & 7) << 8; lengthAndTrigger(v, sq2, maxLength: 64)
        case 0x1A: wave.dacOn = r & 0x80 != 0; if !wave.dacOn { wave.enabled = false }
        case 0x1B: wave.length = 256 - r
        case 0x1C: wave.volumeCode = (r >> 5) & 3
        case 0x1D: wave.frequency = (wave.frequency & 0x700) | r
        case 0x1E: wave.frequency = (wave.frequency & 0xFF) | (r & 7) << 8; lengthAndTrigger(v, wave, maxLength: 256)
        case 0x20: noise.length = 64 - (r & 63)
        case 0x21: noise.env.load(r << 8); if !noise.env.dacOn { noise.enabled = false }
        case 0x22: noise.shift = r >> 4; noise.narrow = r & 8 != 0; noise.divisor = r & 7
        case 0x23: lengthAndTrigger(v, noise, maxLength: 64)
        default: break
        }
    }

    /// Shared NRx4 behaviour: enabling the length counter on an odd sequencer step clocks it once immediately, and a trigger
    /// on an empty counter reloads it (one short in that same situation).
    private func lengthAndTrigger(_ v: UInt8, _ c: PSGLengthChannel, maxLength: Int) {
        let was = c.lengthEnabled
        c.lengthEnabled = v & 0x40 != 0
        let skipsLength = sequencerStep & 1 == 1
        if !was && c.lengthEnabled && skipsLength && c.length > 0 {
            c.length -= 1
            if c.length == 0 && v & 0x80 == 0 { c.enabled = false }
        }
        if v & 0x80 != 0 {
            let wasEmpty = c.length == 0
            c.trigger()
            if wasEmpty && c.lengthEnabled && skipsLength { c.length = maxLength - 1 }
        }
    }

    // MARK: synthesis
    func sync() {
        let target = system.dots
        guard lastTick + GBAPU.tickDots <= target else { return }
        while lastTick + GBAPU.tickDots <= target {
            lastTick += GBAPU.tickDots
            tick()
        }
    }

    private func tick() {
        let dt = 32                                              // 8 Game Boy dots = 32 GBA cycles, the unit the channels count in
        var l = 0, r = 0
        if masterOn {
            sequencerTicks += 1
            if sequencerTicks == 1024 { sequencerTicks = 0; clockSequencer() }
            sq1.advance(dt); sq2.advance(dt); wave.advance(dt); noise.advance(dt)
            let outs = [sq1.output, sq2.output, wave.output, noise.output]
            let pan = Int(regs[0x25]), vol = Int(regs[0x24])
            for c in 0..<4 {
                if pan & (1 << c) != 0 { r += outs[c] }
                if pan & (0x10 << c) != 0 { l += outs[c] }
            }
            l *= ((vol >> 4) & 7) + 1; r *= (vol & 7) + 1
        }
        sumL += l; sumR += r; sumCount += 1
        rateAccumulator += GBAPU.outputRate
        if rateAccumulator >= GBAPU.ticksPerSecond {
            rateAccumulator -= GBAPU.ticksPerSecond
            emit(sumL / sumCount, sumR / sumCount)
            sumL = 0; sumR = 0; sumCount = 0
        }
    }

    private func clockSequencer() {
        let s = sequencerStep
        sequencerStep = (s + 1) & 7
        if s & 1 == 0 { sq1.clockLength(); sq2.clockLength(); wave.clockLength(); noise.clockLength() }
        if s == 2 || s == 6 { sq1.clockSweep() }
        if s == 7 { sq1.env.clock(); sq2.env.clock(); noise.env.clock() }
    }

    private func emit(_ l: Int, _ r: Int) {
        let rc = 0.9974
        let inL = Double(l), inR = Double(r)
        let outL = inL - prevInL + rc * prevOutL
        let outR = inR - prevInR + rc * prevOutR
        prevInL = inL; prevInR = inR; prevOutL = outL; prevOutR = outR
        let gain = 64.0                                         // the hardware mixes into ±512, so 64 puts full scale at the 16-bit limit
        let w = (ringHead + ringCount) % ringCapacity
        if ringCount == ringCapacity { ringHead = (ringHead + 1) % ringCapacity; ringCount -= 1 }
        ring[w * 2] = Int16(max(-32768, min(32767, outL * gain)))
        ring[w * 2 + 1] = Int16(max(-32768, min(32767, outR * gain)))
        ringCount += 1
    }

    func drain(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int {
        sync()
        let n = min(maxFrames, ringCount)
        for i in 0..<n {
            let p = (ringHead + i) % ringCapacity
            buffer[i * 2] = ring[p * 2]; buffer[i * 2 + 1] = ring[p * 2 + 1]
        }
        ringHead = (ringHead + n) % ringCapacity
        ringCount -= n
        return n
    }
}

// MARK: save states
extension GBAPU {
    private func saveEnvelope(_ e: PSGEnvelope, _ w: inout StateWriter) { w.int(e.volume); w.int(e.initial); w.bool(e.increase); w.int(e.period); w.int(e.timer) }
    private func loadEnvelope(_ e: PSGEnvelope, _ r: inout StateReader) { e.volume = r.int(); e.initial = r.int(); e.increase = r.bool(); e.period = r.int(); e.timer = r.int() }
    private func saveSquare(_ c: PSGSquare, _ w: inout StateWriter) {
        w.bool(c.enabled); w.bool(c.lengthEnabled); w.int(c.length); w.int(c.duty); w.int(c.step); w.int(c.timer); w.int(c.frequency)
        saveEnvelope(c.env, &w)
        w.bool(c.sweepNegateUsed); w.bool(c.sweepEnabled); w.bool(c.sweepNegate); w.int(c.sweepShift); w.int(c.sweepPeriod); w.int(c.sweepTimer); w.int(c.shadow)
    }
    private func loadSquare(_ c: PSGSquare, _ r: inout StateReader) {
        c.enabled = r.bool(); c.lengthEnabled = r.bool(); c.length = r.int(); c.duty = r.int(); c.step = r.int(); c.timer = r.int(); c.frequency = r.int()
        loadEnvelope(c.env, &r)
        c.sweepNegateUsed = r.bool(); c.sweepEnabled = r.bool(); c.sweepNegate = r.bool(); c.sweepShift = r.int(); c.sweepPeriod = r.int(); c.sweepTimer = r.int(); c.shadow = r.int()
    }

    func save(_ w: inout StateWriter) {
        w.tag("GAP0")
        w.u64(lastTick); w.int(rateAccumulator); w.int(sumL); w.int(sumR); w.int(sumCount); w.int(sequencerTicks); w.int(sequencerStep)
        w.double(prevInL); w.double(prevInR); w.double(prevOutL); w.double(prevOutR); w.bool(masterOn); w.u8s(regs)
        saveSquare(sq1, &w); saveSquare(sq2, &w)
        w.bool(wave.enabled); w.bool(wave.dacOn); w.bool(wave.lengthEnabled); w.int(wave.length); w.int(wave.timer); w.int(wave.frequency)
        w.int(wave.position); w.int(wave.volumeCode); w.bool(wave.force75); w.bool(wave.twoBanks); w.int(wave.playBank); w.u8s(wave.ram)
        w.bool(noise.enabled); w.bool(noise.lengthEnabled); w.bool(noise.narrow); w.int(noise.length); w.int(noise.timer)
        w.int(noise.divisor); w.int(noise.shift); w.int(noise.lfsr); saveEnvelope(noise.env, &w)
    }

    func load(_ r: inout StateReader) {
        r.tag("GAP0")
        lastTick = r.u64(); rateAccumulator = r.int(); sumL = r.int(); sumR = r.int(); sumCount = r.int(); sequencerTicks = r.int(); sequencerStep = r.int()
        prevInL = r.double(); prevInR = r.double(); prevOutL = r.double(); prevOutR = r.double(); masterOn = r.bool(); r.u8s(&regs)
        loadSquare(sq1, &r); loadSquare(sq2, &r)
        wave.enabled = r.bool(); wave.dacOn = r.bool(); wave.lengthEnabled = r.bool(); wave.length = r.int(); wave.timer = r.int(); wave.frequency = r.int()
        wave.position = r.int(); wave.volumeCode = r.int(); wave.force75 = r.bool(); wave.twoBanks = r.bool(); wave.playBank = r.int(); r.u8s(&wave.ram)
        noise.enabled = r.bool(); noise.lengthEnabled = r.bool(); noise.narrow = r.bool(); noise.length = r.int(); noise.timer = r.int()
        noise.divisor = r.int(); noise.shift = r.int(); noise.lfsr = r.int(); loadEnvelope(noise.env, &r)
        ringHead = 0; ringCount = 0
    }
}
