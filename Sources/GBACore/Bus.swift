import Foundation

/// The GBA memory map: one concrete object shared by the CPU, DMA and video. Memory is held in raw buffers; every
/// timed access also advances the global cycle counter by that region's wait-state cost (derived from WAITCNT).
public final class Bus {
    // MARK: storage
    public let bios = Bus.alloc(0x4000)
    public let ewram = Bus.alloc(0x40000)
    public let iwram = Bus.alloc(0x8000)
    public let io = Bus.alloc(0x400)
    public let pram = Bus.alloc(0x400)
    public let vram = Bus.alloc(0x18000)
    public let oam = Bus.alloc(0x400)
    public let cart = Cartridge()
    public private(set) var rom: UnsafeMutablePointer<UInt8>? = nil
    public private(set) var romSize = 0

    private static func alloc(_ n: Int) -> UnsafeMutablePointer<UInt8> {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        p.initialize(repeating: 0, count: n)
        return p
    }

    // MARK: time and state shared with the CPU
    /// Global cycle counter at 16.78 MHz. Everything (LCD position, timers, DMA) is derived from this.
    public var cycles: UInt64 = 0
    /// Active-low key state as the KEYINPUT register reports it (bit set = released).
    public var keyInput: UInt16 = 0x03FF
    /// Last value fetched by the CPU, returned for reads of unmapped addresses (open bus).
    public var openBus: UInt32 = 0
    /// Set by a write to HALTCNT; the CPU clears it when it acts on it.
    public var haltRequested = false
    /// Program counter, kept up to date by the CPU, used for BIOS read protection.
    public var cpuPC: UInt32 = 0x0800_0000
    /// What a read of BIOS memory returns while the CPU is executing outside the BIOS: the last opcode the BIOS fetched.
    /// With the native BIOS this is set explicitly at the same points the real BIOS would have left it.
    public var biosLatch: UInt32 = 0xE129_F000
    /// Called at the start of VBlank / at the end of each visible line's drawing (HBlank). Hooks for video and DMA.
    public var onVBlank: (() -> Void)?
    /// Interrupt flag/enable registers (the CPU reads these to decide on IRQ entry).
    public var ie: UInt16 = 0
    public var ifl: UInt16 = 0
    public var ime: UInt16 = 0
    public var irqPending: Bool { (ime & 1) != 0 && (ie & ifl) != 0 }

    // MARK: wait states
    private let waits = UnsafeMutablePointer<Int32>.allocate(capacity: 16 * 8)
    var nextSeqAddr: UInt32 = 0xFFFF_FFFF
    public internal(set) var waitcnt: UInt16 = 0

    public init() {
        waits.initialize(repeating: 1, count: 16 * 8)
        rebuildWaits()
    }

    deinit {
        bios.deallocate(); ewram.deallocate(); iwram.deallocate(); io.deallocate(); pram.deallocate()
        vram.deallocate(); oam.deallocate(); waits.deallocate(); rom?.deallocate()
    }

    public func loadROM(_ data: Data) {
        rom?.deallocate()
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(data.count, 1))
        data.copyBytes(to: p, count: data.count)
        rom = p
        romSize = data.count
        cart.configure(rom: p, size: data.count)
    }

    public func loadBIOS(_ data: Data) {
        let n = min(data.count, 0x4000)
        data.copyBytes(to: bios, count: n)
    }

    func rebuildWaits() {
        let nTab: [Int32] = [4, 3, 2, 8]
        func set(_ region: Int, _ size: Int, _ seq: Int, _ v: Int32) { waits[(region << 3) | (size << 1) | seq] = v }
        let ws: [(n: Int32, s: Int32)] = [
            (nTab[Int((waitcnt >> 2) & 3)], (waitcnt >> 4) & 1 == 0 ? 2 : 1),
            (nTab[Int((waitcnt >> 5) & 3)], (waitcnt >> 7) & 1 == 0 ? 4 : 1),
            (nTab[Int((waitcnt >> 8) & 3)], (waitcnt >> 10) & 1 == 0 ? 8 : 1),
        ]
        for region in 0..<16 {
            for size in 0..<3 {          // 0 = 8-bit, 1 = 16-bit, 2 = 32-bit
                for seq in 0..<2 {
                    var c: Int32 = 1
                    switch region {
                    case 2: c = size == 2 ? 6 : 3                        // EWRAM: 16-bit bus, 2 wait states
                    case 5, 6: c = size == 2 ? 2 : 1                     // palette / VRAM: 16-bit bus
                    case 8...0xD:
                        let w = ws[(region - 8) >> 1]
                        let first: Int32 = seq == 1 ? 1 + w.s : 1 + w.n
                        c = size == 2 ? first + 1 + w.s : first
                    case 0xE, 0xF: c = 1 + nTab[Int(waitcnt & 3)]
                    default: c = 1
                    }
                    set(region, size, seq, c)
                }
            }
        }
    }

    /// Charge the cost of one access and remember it so the next access can be recognised as sequential.
    @inline(__always) public func charge(_ a: UInt32, _ size: Int) {
        let region = Int(a >> 24) & 0xF
        let seq = (a == nextSeqAddr && !(region >= 8 && region <= 0xD && (a & 0x1FFFF) == 0)) ? 1 : 0
        nextSeqAddr = a &+ UInt32(size)
        cycles &+= UInt64(waits[(region << 3) | ((size >> 1) << 1) | seq])
    }

    /// An internal (I) cycle; breaks the sequential chain like on hardware.
    @inline(__always) public func internalCycles(_ n: Int) {
        cycles &+= UInt64(n)
        nextSeqAddr = 0xFFFF_FFFF
    }

    // MARK: components
    public lazy var ppu = PPU(bus: self)
    lazy var timers = Timers(bus: self)
    lazy var dma = DMA(bus: self)
    public lazy var apu = APU(bus: self)
    lazy var sio = SIO(bus: self)
    /// The link cable, if one is plugged in (GBA multi-player mode).
    public var link: SerialLink? { get { sio.link } set { sio.link = newValue } }

    // MARK: event scheduler
    /// Cycle of the next thing that needs attention (LCD line/HBlank edge, timer overflow, queued DMA).
    /// The CPU calls runEvents() when it is reached.
    public private(set) var nextEvent: UInt64 = 0
    var lcdNext: UInt64 = 0
    var nextIsHBlank = false
    var curLineStart: UInt64 = 0

    public func resetEvents() {
        lcdNext = 0; nextIsHBlank = false; curLineStart = 0; nextEvent = 0
        timers.reset(); dma.reset(); ppu.reset(); apu.reset(); sio.reset()
    }

    /// Recompute `nextEvent` after anything that can change it.
    func reschedule() {
        nextEvent = dma.pending != 0 ? 0 : min(lcdNext, timers.next)
    }

    /// Break the sequential-access chain (after an internal cycle or a DMA burst).
    @inline(__always) func breakSequence() { nextSeqAddr = 0xFFFF_FFFF }

    /// Cost in cycles of one access, without touching the sequential-access state.
    func accessCost(_ a: UInt32, _ size: Int, sequential: Bool) -> Int {
        let region = Int(a >> 24) & 0xF
        return Int(waits[(region << 3) | ((size >> 1) << 1) | (sequential ? 1 : 0)])
    }

    /// Raise every LCD interrupt/hook whose cycle has been reached, then run timers and DMA.
    public func runEvents() {
        repeat {
            while cycles >= lcdNext {
                let dispstat = ld16(io, 4)
                if nextIsHBlank {
                    let line = Int((curLineStart / 1232) % 228)
                    if dispstat & 0x10 != 0 { ifl |= 2 }
                    if line < 160 { ppu.renderLine(line); dma.trigger(timing: 2) }
                    nextIsHBlank = false
                    lcdNext = curLineStart + 1232
                } else {
                    curLineStart = lcdNext
                    let line = Int((curLineStart / 1232) % 228)
                    if line == 160 {
                        if dispstat & 0x08 != 0 { ifl |= 1 }
                        ppu.reloadReferences()
                        dma.trigger(timing: 1)
                        onVBlank?()
                    }
                    if line == Int(dispstat >> 8) && dispstat & 0x20 != 0 { ifl |= 4 }
                    nextIsHBlank = true
                    lcdNext = curLineStart + 1006
                }
            }
            timers.service()
            if sio.active { sio.service() }
            if dma.pending != 0 { dma.run() }
            reschedule()
        } while cycles >= nextEvent
    }

    // MARK: LCD position (derived from the cycle counter)
    @inline(__always) public var scanline: Int { Int((cycles / 1232) % 228) }
    @inline(__always) public var hcycle: Int { Int(cycles % 1232) }

    // MARK: timed access (used by the CPU)
    @inline(__always) public func read8(_ a: UInt32) -> UInt8 { charge(a, 1); return peek8(a) }
    @inline(__always) public func read16(_ a: UInt32) -> UInt16 { charge(a, 2); return peek16(a) }
    @inline(__always) public func read32(_ a: UInt32) -> UInt32 { charge(a, 4); return peek32(a) }
    @inline(__always) public func write8(_ a: UInt32, _ v: UInt8) { charge(a, 1); poke8(a, v) }
    @inline(__always) public func write16(_ a: UInt32, _ v: UInt16) { charge(a & ~1, 2); poke16(a, v) }
    @inline(__always) public func write32(_ a: UInt32, _ v: UInt32) { charge(a & ~3, 4); poke32(a, v) }

    // MARK: untimed access
    @inline(__always) private func vramIndex(_ a: UInt32) -> Int {
        let o = Int(a & 0x1FFFF)
        return o >= 0x18000 ? o - 0x8000 : o
    }

    @inline(__always) private func openBus8(_ a: UInt32) -> UInt8 { UInt8(truncatingIfNeeded: openBus >> (8 * (a & 3))) }

    @inline(__always) private func romIndex(_ a: UInt32) -> Int { Int(a & 0x01FF_FFFF) }

    public func peek8(_ a: UInt32) -> UInt8 {
        switch a >> 24 {
        case 0x0: return a < 0x4000 ? (cpuPC < 0x4000 ? bios[Int(a)] : UInt8(truncatingIfNeeded: biosLatch >> (8 * (a & 3)))) : openBus8(a)
        case 0x2: return ewram[Int(a & 0x3FFFF)]
        case 0x3: return iwram[Int(a & 0x7FFF)]
        case 0x4: return a & 0x00FF_FFFF < 0x400 ? ioRead8(Int(a & 0x3FF)) : openBus8(a)
        case 0x5: return pram[Int(a & 0x3FF)]
        case 0x6: return vram[vramIndex(a)]
        case 0x7: return oam[Int(a & 0x3FF)]
        case 0xD where cart.isEEPROM(a, romSize: romSize): return UInt8(truncatingIfNeeded: cart.readEEPROM())
        case 0x8...0xD:
            let i = romIndex(a)
            if UInt(bitPattern: i &- 0xC4) < 6 && cart.hasRTC, let v = cart.rtc.read16(i & ~1) { return UInt8(truncatingIfNeeded: v >> (8 * UInt16(i & 1))) }
            if let rom, i < romSize { return rom[i] }
            return UInt8(truncatingIfNeeded: (a >> 1) >> (8 * (a & 1)))
        case 0xE, 0xF: return cart.readSave(a)
        default: return openBus8(a)
        }
    }

    public func peek16(_ a: UInt32) -> UInt16 {
        let a = a & ~1
        switch a >> 24 {
        case 0x0: return a < 0x4000 ? (cpuPC < 0x4000 ? ld16(bios, Int(a)) : UInt16(truncatingIfNeeded: biosLatch >> (8 * (a & 2)))) : UInt16(truncatingIfNeeded: openBus >> (8 * (a & 2)))
        case 0x2: return ld16(ewram, Int(a & 0x3FFFF))
        case 0x3: return ld16(iwram, Int(a & 0x7FFF))
        case 0x4: return a & 0x00FF_FFFF < 0x400 ? ioRead16(Int(a & 0x3FF)) : UInt16(truncatingIfNeeded: openBus >> (8 * (a & 2)))
        case 0x5: return ld16(pram, Int(a & 0x3FF))
        case 0x6: return ld16(vram, vramIndex(a))
        case 0x7: return ld16(oam, Int(a & 0x3FF))
        case 0xD where cart.isEEPROM(a, romSize: romSize): return cart.readEEPROM()
        case 0x8...0xD:
            let i = romIndex(a)
            if UInt(bitPattern: i &- 0xC4) < 6 && cart.hasRTC, let v = cart.rtc.read16(i) { return v }
            if let rom, i + 1 < romSize { return ld16(rom, i) }
            return UInt16(truncatingIfNeeded: a >> 1)
        case 0xE, 0xF: return UInt16(cart.readSave(a)) * 0x0101
        default: return UInt16(truncatingIfNeeded: openBus >> (8 * (a & 2)))
        }
    }

    public func peek32(_ a: UInt32) -> UInt32 {
        let a = a & ~3
        switch a >> 24 {
        case 0x0: return a < 0x4000 ? (cpuPC < 0x4000 ? ld32(bios, Int(a)) : biosLatch) : openBus
        case 0x2: return ld32(ewram, Int(a & 0x3FFFF))
        case 0x3: return ld32(iwram, Int(a & 0x7FFF))
        case 0x4:
            if a & 0x00FF_FFFF < 0x400 { return UInt32(ioRead16(Int(a & 0x3FF))) | UInt32(ioRead16(Int((a & 0x3FF) + 2))) << 16 }
            return openBus
        case 0x5: return ld32(pram, Int(a & 0x3FF))
        case 0x6: return ld32(vram, vramIndex(a))
        case 0x7: return ld32(oam, Int(a & 0x3FF))
        case 0xD where cart.isEEPROM(a, romSize: romSize): return UInt32(cart.readEEPROM())
        case 0x8...0xD:
            let i = romIndex(a)
            if UInt(bitPattern: i &- 0xC4) < 6 && cart.hasRTC {
                let lo = cart.rtc.read16(i), hi = cart.rtc.read16(i + 2)
                if lo != nil || hi != nil {
                    return UInt32(lo ?? ld16(rom!, i)) | UInt32(hi ?? ld16(rom!, i + 2)) << 16
                }
            }
            if let rom, i + 3 < romSize { return ld32(rom, i) }
            return UInt32(UInt16(truncatingIfNeeded: a >> 1)) | UInt32(UInt16(truncatingIfNeeded: (a + 2) >> 1)) << 16
        case 0xE, 0xF: return UInt32(cart.readSave(a)) * 0x0101_0101
        default: return openBus
        }
    }

    public func poke8(_ a: UInt32, _ v: UInt8) {
        switch a >> 24 {
        case 0x2: ewram[Int(a & 0x3FFFF)] = v
        case 0x3: iwram[Int(a & 0x7FFF)] = v
        case 0x4: if a & 0x00FF_FFFF < 0x400 { ioWrite8(Int(a & 0x3FF), v) }
        case 0x5: let i = Int(a & 0x3FE); pram[i] = v; pram[i + 1] = v            // 8-bit writes duplicate into both halves
        case 0x6:
            let i = vramIndex(a & ~1)
            let bitmap = (io[0] & 7) >= 3
            if i < (bitmap ? 0x14000 : 0x10000) { vram[i] = v; vram[i + 1] = v }  // OBJ area ignores 8-bit writes
        case 0x7: break                                                          // OAM ignores 8-bit writes
        case 0xE, 0xF: cart.writeSave(a, v)
        case 0x8...0xC: if cart.hasRTC { let i = romIndex(a); if UInt(bitPattern: i &- 0xC4) < 6 { cart.rtc.write16(i & ~1, UInt16(v)) } }
        default: break
        }
    }

    public func poke16(_ raw: UInt32, _ v: UInt16) {
        let a = raw & ~1
        switch a >> 24 {
        case 0x2: st16(ewram, Int(a & 0x3FFFF), v)
        case 0x3: st16(iwram, Int(a & 0x7FFF), v)
        case 0x4: if a & 0x00FF_FFFF < 0x400 { ioWrite16(Int(a & 0x3FF), v) }
        case 0x5: st16(pram, Int(a & 0x3FF), v)
        case 0x6: st16(vram, vramIndex(a), v)
        case 0x7: st16(oam, Int(a & 0x3FF), v)
        case 0xD where cart.isEEPROM(a, romSize: romSize): cart.writeEEPROM(v)
        case 0x8...0xC: if cart.hasRTC { let i = romIndex(a); if UInt(bitPattern: i &- 0xC4) < 6 { cart.rtc.write16(i, v) } }
        case 0xE, 0xF: cart.writeSave(raw, UInt8(truncatingIfNeeded: v >> (8 * (raw & 1))))   // an 8-bit bus: the byte that matches the low address bit
        default: break
        }
    }

    public func poke32(_ raw: UInt32, _ v: UInt32) {
        let a = raw & ~3
        switch a >> 24 {
        case 0x2: st32(ewram, Int(a & 0x3FFFF), v)
        case 0x3: st32(iwram, Int(a & 0x7FFF), v)
        case 0x4:
            if a & 0x00FF_FFFF < 0x400 {
                ioWrite16(Int(a & 0x3FF), UInt16(truncatingIfNeeded: v))
                ioWrite16(Int((a & 0x3FF) + 2), UInt16(truncatingIfNeeded: v >> 16))
            }
        case 0x5: st32(pram, Int(a & 0x3FF), v)
        case 0x6: st32(vram, vramIndex(a), v)
        case 0x7: st32(oam, Int(a & 0x3FF), v)
        case 0xD where cart.isEEPROM(a, romSize: romSize): cart.writeEEPROM(UInt16(truncatingIfNeeded: v))
        case 0x8...0xC:
            if cart.hasRTC { let i = romIndex(a); if UInt(bitPattern: i &- 0xC4) < 6 { cart.rtc.write16(i, UInt16(truncatingIfNeeded: v)); cart.rtc.write16(i + 2, UInt16(truncatingIfNeeded: v >> 16)) } }
        case 0xE, 0xF: cart.writeSave(raw, UInt8(truncatingIfNeeded: v >> (8 * (raw & 3))))
        default: break
        }
    }

    /// Raise the keypad interrupt if KEYCNT's condition holds for the current buttons.
    public func checkKeypadIRQ() {
        let cnt = ld16(io, 0x132)
        guard cnt & 0x4000 != 0 else { return }
        let mask = cnt & 0x3FF
        let pressed = ~keyInput & 0x3FF
        let hit = cnt & 0x8000 != 0 ? (pressed & mask) == mask && mask != 0 : (pressed & mask) != 0
        if hit { ifl |= 0x1000 }
    }

    // MARK: I/O registers
    private func ioRead8(_ o: Int) -> UInt8 { UInt8(truncatingIfNeeded: ioRead16(o & ~1) >> (8 * UInt16(o & 1))) }

    private func ioRead16(_ o: Int) -> UInt16 {
        switch o {
        case 0x004:
            let line = scanline, h = hcycle
            let stored = ld16(io, 4)
            var flags: UInt16 = 0
            if line >= 160 && line <= 226 { flags |= 1 }
            if h >= 1006 { flags |= 2 }
            if line == Int(stored >> 8) { flags |= 4 }
            return (stored & 0xFFF8) | flags
        case 0x006: return UInt16(scanline)
        case 0x130: return keyInput
        case 0x060..<0x0A0: return apu.read16(o)
        case 0x128: return sio.readCNT()
        case 0x0B0..<0x0E0: return dma.read16(o)
        case 0x100..<0x110: return timers.read16(o)
        case 0x200: return ie
        case 0x202: return ifl
        case 0x204: return waitcnt
        case 0x208: return ime
        default: return ld16(io, o)
        }
    }

    private func ioWrite16(_ o: Int, _ v: UInt16) {
        switch o {
        case 0x004: st16(io, 4, v & 0xFFF8)
        case 0x006, 0x130: break                                  // read-only
        case 0x200: ie = v & 0x3FFF
        case 0x202: ifl &= ~v                                     // write 1 to acknowledge
        case 0x204: waitcnt = v & 0x7FFF; rebuildWaits()
        case 0x208: ime = v & 1
        case 0x060..<0x0A8: apu.write16(o, v)
        case 0x128: sio.writeCNT(v)
        case 0x0B0..<0x0E0: st16(io, o, v); dma.write16(o, v)
        case 0x100..<0x110: st16(io, o, v); timers.write16(o, v)
        case 0x028..<0x030, 0x038..<0x040: st16(io, o, v); ppu.latchReference(o)
        case 0x132: st16(io, o, v); checkKeypadIRQ()
        case 0x300: ioWrite8(0x300, UInt8(truncatingIfNeeded: v)); ioWrite8(0x301, UInt8(truncatingIfNeeded: v >> 8))
        default: st16(io, o, v)
        }
    }

    private func ioWrite8(_ o: Int, _ v: UInt8) {
        switch o {
        case 0x202: ifl &= ~UInt16(v)
        case 0x203: ifl &= ~(UInt16(v) << 8)
        case 0x301: haltRequested = true                          // bit 7 selects STOP, otherwise HALT; both just halt for now
        case 0x300, 0x006, 0x007, 0x130, 0x131: break
        case 0x060..<0x0A8: apu.write8(o, v)
        default:
            // Read-modify-write on the containing 16-bit register so special registers keep their rules.
            let base = o & ~1
            var cur = (0x0B0..<0x110).contains(base) ? ld16(io, base) : ioRead16(base)
            if o & 1 == 0 { cur = (cur & 0xFF00) | UInt16(v) } else { cur = (cur & 0x00FF) | UInt16(v) << 8 }
            ioWrite16(base, cur)
        }
    }
}

// MARK: raw little-endian helpers
@inline(__always) func ld16(_ p: UnsafeMutablePointer<UInt8>, _ i: Int) -> UInt16 {
    UnsafeRawPointer(p + i).loadUnaligned(as: UInt16.self)
}
@inline(__always) func ld32(_ p: UnsafeMutablePointer<UInt8>, _ i: Int) -> UInt32 {
    UnsafeRawPointer(p + i).loadUnaligned(as: UInt32.self)
}
@inline(__always) func st16(_ p: UnsafeMutablePointer<UInt8>, _ i: Int, _ v: UInt16) {
    UnsafeMutableRawPointer(p + i).storeBytes(of: v, as: UInt16.self)
}
@inline(__always) func st32(_ p: UnsafeMutablePointer<UInt8>, _ i: Int, _ v: UInt32) {
    UnsafeMutableRawPointer(p + i).storeBytes(of: v, as: UInt32.self)
}

// MARK: save states
extension Bus {
    func save(_ w: inout StateWriter) {
        w.tag("BUS0")
        w.u64(cycles); w.u16(keyInput); w.u32(openBus); w.bool(haltRequested); w.u32(cpuPC); w.u32(biosLatch)
        w.u16(ie); w.u16(ifl); w.u16(ime); w.u32(nextSeqAddr); w.u16(waitcnt)
        w.u64(lcdNext); w.bool(nextIsHBlank); w.u64(curLineStart)
        w.raw(ewram, 0x40000); w.raw(iwram, 0x8000); w.raw(io, 0x400); w.raw(pram, 0x400); w.raw(vram, 0x18000); w.raw(oam, 0x400)
        ppu.save(&w); timers.save(&w); dma.save(&w); apu.save(&w); cart.save(&w)
    }

    func load(_ r: inout StateReader) {
        r.tag("BUS0")
        cycles = r.u64(); keyInput = r.u16(); openBus = r.u32(); haltRequested = r.bool(); cpuPC = r.u32(); biosLatch = r.u32()
        ie = r.u16(); ifl = r.u16(); ime = r.u16(); nextSeqAddr = r.u32(); waitcnt = r.u16(); rebuildWaits()
        lcdNext = r.u64(); nextIsHBlank = r.bool(); curLineStart = r.u64()
        r.raw(ewram, 0x40000); r.raw(iwram, 0x8000); r.raw(io, 0x400); r.raw(pram, 0x400); r.raw(vram, 0x18000); r.raw(oam, 0x400)
        ppu.load(&r); timers.load(&r); dma.load(&r); apu.load(&r); cart.load(&r)
        sio.restoreFromIO()
        reschedule()
    }
}
