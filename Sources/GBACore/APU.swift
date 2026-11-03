/// The sound hardware: four Game Boy-style PSG channels (two squares, wave, noise) plus two DMA-fed 8-bit FIFOs.
///
/// Time is processed in 32-cycle ticks (524,288 per second). Every tick advances the channels and adds to a running
/// average; every 48,000th-of-a-second worth of ticks emits one averaged stereo sample, which doubles as a simple
/// anti-aliasing filter. The hardware's own mixing resolution (SOUNDBIAS) is not modelled.
public final class APU {
    unowned let bus: Bus
    private let io: UnsafeMutablePointer<UInt8>

    // MARK: output ring (stereo frames, interleaved Int16)
    private let ringCapacity = 16_384
    private let ring = UnsafeMutablePointer<Int16>.allocate(capacity: 16_384 * 2)
    private var ringHead = 0
    private var ringCount = 0

    // MARK: clocking
    private static let tickCycles: UInt64 = 32
    private static let ticksPerSecond = 524_288
    private static let outputRate = 48_000
    private var lastTick: UInt64 = 0
    private var rateAccumulator = 0
    private var sumL = 0, sumR = 0, sumCount = 0
    private var sequencerTicks = 0
    private var sequencerStep = 0

    // MARK: high-pass filter (removes the DC offset of the unipolar PSG mix)
    private var prevInL = 0.0, prevInR = 0.0, prevOutL = 0.0, prevOutR = 0.0

    // MARK: channels
    private let sq1 = PSGSquare(), sq2 = PSGSquare(), wave = PSGWave(), noise = PSGNoise()

    // MARK: direct-sound FIFOs
    private struct Fifo {
        var data = [Int8](repeating: 0, count: 32)
        var head = 0, count = 0
        var sample = 0
        mutating func reset() { head = 0; count = 0; sample = 0 }
        mutating func push(_ v: Int8) { if count < 32 { data[(head + count) & 31] = v; count += 1 } }
        mutating func pop() { if count > 0 { sample = Int(data[head]); head = (head + 1) & 31; count -= 1 } }
    }
    private var fifoA = Fifo(), fifoB = Fifo()

    private var masterOn = false

    init(bus: Bus) {
        self.bus = bus
        io = bus.io
        sq1.hasSweep = true
    }

    deinit { ring.deallocate() }

    func reset() {
        ringHead = 0; ringCount = 0
        lastTick = 0; rateAccumulator = 0; sumL = 0; sumR = 0; sumCount = 0
        sequencerTicks = 0; sequencerStep = 0
        prevInL = 0; prevInR = 0; prevOutL = 0; prevOutR = 0
        fifoA.reset(); fifoB.reset()
        masterOn = false
        silenceChannels()
    }

    private func silenceChannels() {
        sq1.enabled = false; sq2.enabled = false; wave.enabled = false; noise.enabled = false
    }

    // MARK: registers
    func read16(_ o: Int) -> UInt16 {
        switch o {
        case 0x60: return ld16(io, o) & 0x007F
        case 0x62, 0x68: return ld16(io, o) & 0xFFC0
        case 0x64, 0x6C, 0x74: return ld16(io, o) & 0x4000
        case 0x70: return ld16(io, o) & 0x00E0
        case 0x72: return ld16(io, o) & 0xE000
        case 0x78: return ld16(io, o) & 0xFF00
        case 0x7C: return ld16(io, o) & 0x40FF
        case 0x80: return ld16(io, o) & 0xFF77
        case 0x82: return ld16(io, o) & 0x770F
        case 0x84:
            sync()
            return (masterOn ? 0x80 : 0) | (sq1.enabled ? 1 : 0) | (sq2.enabled ? 2 : 0) | (wave.enabled ? 4 : 0) | (noise.enabled ? 8 : 0)
        case 0x88: return ld16(io, o) & 0xC3FE
        case 0x90..<0xA0:
            let bank = 1 - wave.playBank
            let i = bank * 16 + (o - 0x90)
            return UInt16(wave.ram[i]) | UInt16(wave.ram[i + 1]) << 8
        default: return 0
        }
    }

    func write8(_ o: Int, _ v: UInt8) {
        switch o {
        case 0xA0..<0xA4: sync(); fifoA.push(Int8(bitPattern: v))
        case 0xA4..<0xA8: sync(); fifoB.push(Int8(bitPattern: v))
        case 0x90..<0xA0: wave.ram[(1 - wave.playBank) * 16 + (o - 0x90)] = v
        default:
            let base = o & ~1
            var cur = ld16(io, base)
            cur = o & 1 == 0 ? (cur & 0xFF00) | UInt16(v) : (cur & 0x00FF) | UInt16(v) << 8
            write16(base, cur)
        }
    }

    func write16(_ o: Int, _ v: UInt16) {
        if o >= 0xA0 { write8(o, UInt8(truncatingIfNeeded: v)); write8(o + 1, UInt8(truncatingIfNeeded: v >> 8)); return }
        if o >= 0x90 { write8(o, UInt8(truncatingIfNeeded: v)); write8(o + 1, UInt8(truncatingIfNeeded: v >> 8)); return }
        sync()
        let r = Int(v)
        switch o {
        case 0x84:
            let on = v & 0x80 != 0
            if !on && masterOn {
                for reg in stride(from: 0x60, to: 0x82, by: 2) { st16(io, reg, 0) }
                silenceChannels()
                for c in [sq1, sq2] { c.lengthEnabled = false }
                wave.lengthEnabled = false; noise.lengthEnabled = false
            }
            masterOn = on
            return
        case 0x88: st16(io, o, v); return
        default: break
        }
        // Bit 15 of the frequency registers is a write-only trigger; elsewhere it is real data (e.g. envelope volume).
        let stored = (o == 0x64 || o == 0x6C || o == 0x74 || o == 0x7C) ? v & 0x7FFF : (o == 0x82 ? v & 0x770F : v)
        guard masterOn || o >= 0x80 else { return }                                // registers are locked while the unit is off
        st16(io, o, stored)
        switch o {
        case 0x60: sq1.sweepShift = r & 7; sq1.sweepNegate = r & 8 != 0; sq1.sweepPeriod = (r >> 4) & 7
        case 0x62: sq1.length = 64 - (r & 63); sq1.duty = (r >> 6) & 3; sq1.env.load(r); if !sq1.env.dacOn { sq1.enabled = false }
        case 0x64:
            sq1.frequency = r & 2047; sq1.lengthEnabled = r & 0x4000 != 0
            if r & 0x8000 != 0 { sq1.trigger() }
        case 0x68: sq2.length = 64 - (r & 63); sq2.duty = (r >> 6) & 3; sq2.env.load(r); if !sq2.env.dacOn { sq2.enabled = false }
        case 0x6C:
            sq2.frequency = r & 2047; sq2.lengthEnabled = r & 0x4000 != 0
            if r & 0x8000 != 0 { sq2.trigger() }
        case 0x70:
            wave.twoBanks = r & 0x20 != 0; wave.playBank = (r >> 6) & 1; wave.dacOn = r & 0x80 != 0
            if !wave.dacOn { wave.enabled = false }
        case 0x72: wave.length = 256 - (r & 255); wave.volumeCode = (r >> 13) & 3; wave.force75 = r & 0x8000 != 0
        case 0x74:
            wave.frequency = r & 2047; wave.lengthEnabled = r & 0x4000 != 0
            if r & 0x8000 != 0 { wave.trigger() }
        case 0x78: noise.length = 64 - (r & 63); noise.env.load(r); if !noise.env.dacOn { noise.enabled = false }
        case 0x7C:
            noise.divisor = r & 7; noise.narrow = r & 8 != 0; noise.shift = (r >> 4) & 15; noise.lengthEnabled = r & 0x4000 != 0
            if r & 0x8000 != 0 { noise.trigger() }
        case 0x82:
            if r & 0x800 != 0 { fifoA.reset() }
            if r & 0x8000 != 0 { fifoB.reset() }
        default: break
        }
    }

    // MARK: direct sound
    func timerOverflow(_ index: Int) {
        let cnt = Int(ld16(io, 0x82))
        let aTimer = (cnt >> 10) & 1, bTimer = (cnt >> 14) & 1
        guard (aTimer == index || bTimer == index) else { return }
        sync()
        if aTimer == index { fifoA.pop(); if fifoA.count <= 16 { bus.dma.triggerSound(fifo: 0) } }
        if bTimer == index { fifoB.pop(); if fifoB.count <= 16 { bus.dma.triggerSound(fifo: 1) } }
    }

    // MARK: synthesis
    /// Generate everything up to the bus's current cycle.
    func sync() {
        let target = bus.cycles
        guard lastTick + APU.tickCycles <= target else { return }
        if !masterOn && fifoA.sample == 0 && fifoB.sample == 0 {
            let ticks = Int((target - lastTick) / APU.tickCycles)
            lastTick += UInt64(ticks) * APU.tickCycles
            rateAccumulator += ticks * APU.outputRate
            let n = rateAccumulator / APU.ticksPerSecond
            rateAccumulator -= n * APU.ticksPerSecond
            for _ in 0..<n { emit(0, 0) }
            return
        }
        while lastTick + APU.tickCycles <= target {
            lastTick += APU.tickCycles
            tick()
        }
    }

    private func tick() {
        let dt = Int(APU.tickCycles)
        if masterOn {
            sequencerTicks += 1
            if sequencerTicks == 1024 { sequencerTicks = 0; clockSequencer() }
            sq1.advance(dt); sq2.advance(dt); wave.advance(dt); noise.advance(dt)
        }
        var l = 0, r = 0
        if masterOn {
            let cl = Int(ld16(io, 0x80))
            let outs = (sq1.output, sq2.output, wave.output, noise.output)
            var pl = 0, pr = 0
            if cl & 0x0100 != 0 { pr += outs.0 }; if cl & 0x1000 != 0 { pl += outs.0 }
            if cl & 0x0200 != 0 { pr += outs.1 }; if cl & 0x2000 != 0 { pl += outs.1 }
            if cl & 0x0400 != 0 { pr += outs.2 }; if cl & 0x4000 != 0 { pl += outs.2 }
            if cl & 0x0800 != 0 { pr += outs.3 }; if cl & 0x8000 != 0 { pl += outs.3 }
            pl *= ((cl >> 4) & 7) + 1; pr *= (cl & 7) + 1
            let ratio = Int(ld16(io, 0x82)) & 3
            if ratio == 0 { pl >>= 2; pr >>= 2 } else if ratio == 1 { pl >>= 1; pr >>= 1 }
            l = pl; r = pr
        }
        let ch = Int(ld16(io, 0x82))
        let a = (ch & 4 != 0 ? fifoA.sample : fifoA.sample >> 1) * 2
        let b = (ch & 8 != 0 ? fifoB.sample : fifoB.sample >> 1) * 2
        if ch & 0x0200 != 0 { l += a }; if ch & 0x0100 != 0 { r += a }
        if ch & 0x2000 != 0 { l += b }; if ch & 0x1000 != 0 { r += b }
        sumL += l; sumR += r; sumCount += 1
        rateAccumulator += APU.outputRate
        if rateAccumulator >= APU.ticksPerSecond {
            rateAccumulator -= APU.ticksPerSecond
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

    /// Filter, scale and queue one stereo frame.
    private func emit(_ l: Int, _ r: Int) {
        let rc = 0.9974                                        // ~20 Hz high-pass at 48 kHz
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

    /// Hand over the audio produced so far.
    public func drain(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int {
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
extension APU {
    private func saveEnvelope(_ e: PSGEnvelope, _ w: inout StateWriter) {
        w.int(e.volume); w.int(e.initial); w.bool(e.increase); w.int(e.period); w.int(e.timer)
    }
    private func loadEnvelope(_ e: PSGEnvelope, _ r: inout StateReader) {
        e.volume = r.int(); e.initial = r.int(); e.increase = r.bool(); e.period = r.int(); e.timer = r.int()
    }
    private func saveSquare(_ c: PSGSquare, _ w: inout StateWriter) {
        w.bool(c.enabled); w.bool(c.lengthEnabled); w.int(c.length); w.int(c.duty); w.int(c.step); w.int(c.timer); w.int(c.frequency)
        saveEnvelope(c.env, &w)
        w.bool(c.sweepEnabled); w.bool(c.sweepNegate); w.int(c.sweepShift); w.int(c.sweepPeriod); w.int(c.sweepTimer); w.int(c.shadow)
    }
    private func loadSquare(_ c: PSGSquare, _ r: inout StateReader) {
        c.enabled = r.bool(); c.lengthEnabled = r.bool(); c.length = r.int(); c.duty = r.int(); c.step = r.int(); c.timer = r.int(); c.frequency = r.int()
        loadEnvelope(c.env, &r)
        c.sweepEnabled = r.bool(); c.sweepNegate = r.bool(); c.sweepShift = r.int(); c.sweepPeriod = r.int(); c.sweepTimer = r.int(); c.shadow = r.int()
    }
    private func saveFifo(_ f: Fifo, _ w: inout StateWriter) { w.i8s(f.data); w.int(f.head); w.int(f.count); w.int(f.sample) }
    private func loadFifo(_ f: inout Fifo, _ r: inout StateReader) { r.i8s(&f.data); f.head = r.int(); f.count = r.int(); f.sample = r.int() }

    func save(_ w: inout StateWriter) {
        w.tag("APU0")
        w.u64(lastTick); w.int(rateAccumulator); w.int(sumL); w.int(sumR); w.int(sumCount); w.int(sequencerTicks); w.int(sequencerStep)
        w.double(prevInL); w.double(prevInR); w.double(prevOutL); w.double(prevOutR); w.bool(masterOn)
        saveSquare(sq1, &w); saveSquare(sq2, &w)
        w.bool(wave.enabled); w.bool(wave.dacOn); w.bool(wave.lengthEnabled); w.int(wave.length); w.int(wave.timer); w.int(wave.frequency)
        w.int(wave.position); w.int(wave.volumeCode); w.bool(wave.force75); w.bool(wave.twoBanks); w.int(wave.playBank); w.u8s(wave.ram)
        w.bool(noise.enabled); w.bool(noise.lengthEnabled); w.bool(noise.narrow); w.int(noise.length); w.int(noise.timer)
        w.int(noise.divisor); w.int(noise.shift); w.int(noise.lfsr); saveEnvelope(noise.env, &w)
        saveFifo(fifoA, &w); saveFifo(fifoB, &w)
    }

    func load(_ r: inout StateReader) {
        r.tag("APU0")
        lastTick = r.u64(); rateAccumulator = r.int(); sumL = r.int(); sumR = r.int(); sumCount = r.int(); sequencerTicks = r.int(); sequencerStep = r.int()
        prevInL = r.double(); prevInR = r.double(); prevOutL = r.double(); prevOutR = r.double(); masterOn = r.bool()
        loadSquare(sq1, &r); loadSquare(sq2, &r)
        wave.enabled = r.bool(); wave.dacOn = r.bool(); wave.lengthEnabled = r.bool(); wave.length = r.int(); wave.timer = r.int(); wave.frequency = r.int()
        wave.position = r.int(); wave.volumeCode = r.int(); wave.force75 = r.bool(); wave.twoBanks = r.bool(); wave.playBank = r.int(); r.u8s(&wave.ram)
        noise.enabled = r.bool(); noise.lengthEnabled = r.bool(); noise.narrow = r.bool(); noise.length = r.int(); noise.timer = r.int()
        noise.divisor = r.int(); noise.shift = r.int(); noise.lfsr = r.int(); loadEnvelope(noise.env, &r)
        loadFifo(&fifoA, &r); loadFifo(&fifoB, &r)
        ringHead = 0; ringCount = 0                                     // audio queued before the load belongs to another timeline
    }
}
