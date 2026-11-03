/// The four DMA channels. A triggered channel runs to completion between two CPU instructions and charges the bus time it uses.
final class DMA {
    unowned let bus: Bus

    var sad = [UInt32](repeating: 0, count: 4)
    var dad = [UInt32](repeating: 0, count: 4)
    var cntL = [UInt16](repeating: 0, count: 4)
    var cntH = [UInt16](repeating: 0, count: 4)
    var isrc = [UInt32](repeating: 0, count: 4)
    var idst = [UInt32](repeating: 0, count: 4)
    var icount = [UInt32](repeating: 0, count: 4)
    var dmaLatch: UInt32 = 0
    /// Channels triggered and waiting to run.
    var pending: UInt8 = 0

    init(bus: Bus) { self.bus = bus }

    func reset() {
        for i in 0..<4 { sad[i] = 0; dad[i] = 0; cntL[i] = 0; cntH[i] = 0; isrc[i] = 0; idst[i] = 0; icount[i] = 0 }
        pending = 0; dmaLatch = 0
    }

    func read16(_ offset: Int) -> UInt16 {
        let r = (offset - 0xB0) % 12
        return r == 10 ? cntH[(offset - 0xB0) / 12] : 0               // everything else is write-only
    }

    func write16(_ offset: Int, _ v: UInt16) {
        let ch = (offset - 0xB0) / 12
        switch (offset - 0xB0) % 12 {
        case 0: sad[ch] = (sad[ch] & 0xFFFF_0000) | UInt32(v)
        case 2: sad[ch] = (sad[ch] & 0x0000_FFFF) | UInt32(v) << 16
        case 4: dad[ch] = (dad[ch] & 0xFFFF_0000) | UInt32(v)
        case 6: dad[ch] = (dad[ch] & 0x0000_FFFF) | UInt32(v) << 16
        case 8: cntL[ch] = v
        default:
            let wasOn = cntH[ch] & 0x8000 != 0
            cntH[ch] = v & (ch == 3 ? 0xFFE0 : 0xF7E0)
            if cntH[ch] & 0x8000 == 0 {
                pending &= ~(1 << UInt8(ch))
            } else if !wasOn {
                isrc[ch] = sad[ch] & (ch == 0 ? 0x07FF_FFFF : 0x0FFF_FFFF)
                idst[ch] = dad[ch] & (ch == 3 ? 0x0FFF_FFFF : 0x07FF_FFFF)
                icount[ch] = UInt32(cntL[ch]); if icount[ch] == 0 { icount[ch] = ch == 3 ? 0x10000 : 0x4000 }
                if (cntH[ch] >> 12) & 3 == 0 { pending |= 1 << UInt8(ch) }
                bus.reschedule()
            }
        }
    }

    /// 1 = VBlank, 2 = HBlank. Channels set to that start timing are queued.
    func trigger(timing: UInt16) {
        for ch in 0..<4 where cntH[ch] & 0x8000 != 0 && (cntH[ch] >> 12) & 3 == timing { pending |= 1 << UInt8(ch) }
        if pending != 0 { bus.reschedule() }
    }

    /// Sound FIFO request: queue whichever of channels 1 and 2 is armed with special timing and aimed at that FIFO.
    func triggerSound(fifo: Int) {
        let target: UInt32 = fifo == 0 ? 0x0400_00A0 : 0x0400_00A4
        for ch in 1...2 where cntH[ch] & 0x8000 != 0 && (cntH[ch] >> 12) & 3 == 3 && (dad[ch] & 0x0FFF_FFFF) == target {
            pending |= 1 << UInt8(ch)
        }
        if pending != 0 { bus.reschedule() }
    }

    func run() {
        while pending != 0 {
            let ch = pending.trailingZeroBitCount
            pending &= ~(1 << UInt8(ch))
            transfer(ch)
        }
    }

    private func transfer(_ ch: Int) {
        let control = cntH[ch]
        let timing = (control >> 12) & 3
        let sound = timing == 3 && (ch == 1 || ch == 2)
        let word = sound || control & 0x400 != 0
        let size: UInt32 = word ? 4 : 2
        let srcCtrl = (control >> 7) & 3, dstCtrl = (control >> 5) & 3
        let sStep: Int64 = srcCtrl == 1 ? -Int64(size) : srcCtrl == 2 ? 0 : Int64(size)
        let dStep: Int64 = sound ? 0 : (dstCtrl == 1 ? -Int64(size) : dstCtrl == 2 ? 0 : Int64(size))
        var s = isrc[ch], d = idst[ch]
        var n = sound ? 4 : icount[ch]
        bus.cycles &+= 2
        bus.breakSequence()
        if (d >> 24 == 0xD || s >> 24 == 0xD) && bus.cart.kind == .eeprom { bus.cart.eepromDMAHint(count: Int(n)) }
        var first = true
        while n > 0 {
            let sa = s & ~(size - 1), da = d & ~(size - 1)
            let value: UInt32
            if sa >= 0x0200_0000 {
                value = word ? bus.peek32(sa) : { let h = UInt32(bus.peek16(sa)); return h | h << 16 }()
                dmaLatch = value
            } else {
                value = dmaLatch                                       // BIOS and unmapped space read back the last transferred value
            }
            bus.cycles &+= UInt64(bus.accessCost(sa, Int(size), sequential: !first) + bus.accessCost(da, Int(size), sequential: !first))
            if da >= 0x0200_0000 {
                if word { bus.poke32(da, value) } else { bus.poke16(da, UInt16(truncatingIfNeeded: value)) }
            }
            first = false
            s = UInt32(truncatingIfNeeded: Int64(s) + sStep)
            d = UInt32(truncatingIfNeeded: Int64(d) + dStep)
            n -= 1
        }
        isrc[ch] = s; idst[ch] = d
        if control & 0x4000 != 0 { bus.ifl |= UInt16(1) << UInt16(8 + ch) }
        if control & 0x200 != 0 && timing != 0 {
            if !sound {
                icount[ch] = UInt32(cntL[ch]); if icount[ch] == 0 { icount[ch] = ch == 3 ? 0x10000 : 0x4000 }
                if dstCtrl == 3 { idst[ch] = dad[ch] & (ch == 3 ? 0x0FFF_FFFF : 0x07FF_FFFF) }
            }
        } else {
            cntH[ch] &= ~0x8000
        }
        bus.breakSequence()
    }
}

// MARK: save states
extension DMA {
    func save(_ w: inout StateWriter) {
        w.tag("DMA0")
        w.u32s(sad); w.u32s(dad); w.u16s(cntL); w.u16s(cntH); w.u32s(isrc); w.u32s(idst); w.u32s(icount); w.u32(dmaLatch); w.u8(pending)
    }
    func load(_ r: inout StateReader) {
        r.tag("DMA0")
        r.u32s(&sad); r.u32s(&dad); r.u16s(&cntL); r.u16s(&cntH); r.u32s(&isrc); r.u32s(&idst); r.u32s(&icount); dmaLatch = r.u32(); pending = r.u8()
    }
}
