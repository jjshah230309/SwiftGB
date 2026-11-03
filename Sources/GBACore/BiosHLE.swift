import Foundation

// High-level emulation of the BIOS software-interrupt services, written from the documented behaviour of each call.
// The app ships no Nintendo BIOS; this serves the same calls natively. Unknown calls are logged and ignored.

extension ARM7TDMI {
    func hleSWI(_ n: UInt32) {
        switch n {
        case 0x00: biosSoftReset()
        case 0x01: biosRegisterRamReset(r[0])
        case 0x02, 0x03: halted = true                             // Halt / Stop (no sleep power state is modelled)
        case 0x04: startIntrWait(discard: r[0] != 0, mask: UInt16(truncatingIfNeeded: r[1]))
        case 0x05: startIntrWait(discard: true, mask: 1)           // VBlankIntrWait
        case 0x06: biosDiv(r[0], r[1])
        case 0x07: biosDiv(r[1], r[0])
        case 0x08: r[0] = isqrt(r[0])
        case 0x09: r[0] = UInt32(bitPattern: Int32(biosArcTan(Int32(bitPattern: r[0]))))
        case 0x0A: r[0] = biosArcTan2(x: Int32(bitPattern: r[0]), y: Int32(bitPattern: r[1]))
        case 0x0B: biosCpuSet()
        case 0x0C: biosCpuFastSet()
        case 0x0D: r[0] = 0xBAAE_187F                              // GetBiosChecksum
        case 0x0E: biosBgAffineSet()
        case 0x0F: biosObjAffineSet()
        case 0x10: biosBitUnPack()
        case 0x11: biosLZ77(toVRAM: false)
        case 0x12: biosLZ77(toVRAM: true)
        case 0x13: biosHuffman()
        case 0x14: biosRunLength(toVRAM: false)
        case 0x15: biosRunLength(toVRAM: true)
        case 0x16: biosDiffUnfilter(bytes: true, toVRAM: false)
        case 0x17: biosDiffUnfilter(bytes: true, toVRAM: true)
        case 0x18: biosDiffUnfilter(bytes: false, toVRAM: true)
        case 0x19: break                                           // SoundBias: the mixer has no analogue stage to bias
        default:
            if hleWarned.insert(n).inserted { NSLog("GBACore: BIOS call 0x%02X not implemented yet", n) }
        }
        bus.biosLatch = 0xE3A0_2004                                  // what BIOS reads see after a software interrupt
        bus.internalCycles(8)
    }

    private func biosDiv(_ num: UInt32, _ den: UInt32) {
        let n = Int32(bitPattern: num), d = Int32(bitPattern: den)
        if d == 0 {                                                // the real BIOS hangs; return something sane
            r[0] = n < 0 ? 0xFFFF_FFFF : 1; r[1] = num; r[3] = 1
            return
        }
        let (q, _) = n.dividedReportingOverflow(by: d)
        let rem = n.remainderReportingOverflow(dividingBy: d).partialValue
        r[0] = UInt32(bitPattern: q)
        r[1] = UInt32(bitPattern: rem)
        r[3] = UInt32(bitPattern: q < 0 ? 0 &- q : q)             // |quotient| (wraps for Int32.min)
    }

    private func isqrt(_ v: UInt32) -> UInt32 {
        var x = UInt32(Double(v).squareRoot())
        while UInt64(x) * UInt64(x) > UInt64(v) { x -= 1 }
        while UInt64(x + 1) * UInt64(x + 1) <= UInt64(v) { x += 1 }
        return x
    }

    /// Polynomial arctangent: input is tan(theta) as 1.14 fixed point, output is theta in 1/65536 turns scaled to +-0x4000.
    private func biosArcTan(_ tan: Int32) -> Int32 {
        let a = tan
        let b = -((a &* a) >> 14)
        var c: Int32 = 0xA9
        c = ((c &* b) >> 14) &+ 0x390
        c = ((b &* c) >> 14) &+ 0x91C
        c = ((b &* c) >> 14) &+ 0xFB6
        c = ((b &* c) >> 14) &+ 0x16AA
        c = ((b &* c) >> 14) &+ 0x2081
        c = ((b &* c) >> 14) &+ 0x3651
        c = ((b &* c) >> 14) &+ 0xA2F9
        return (a &* c) >> 16
    }

    private func biosArcTan2(x: Int32, y: Int32) -> UInt32 {
        func at(_ n: Int32, _ d: Int32) -> Int32 { biosArcTan(Int32(truncatingIfNeeded: (Int64(n) << 14) / Int64(d))) }
        var res: Int32
        if y == 0 { res = x >= 0 ? 0 : 0x8000 }
        else if x == 0 { res = y >= 0 ? 0x4000 : 0xC000 }
        else if y >= 0 {
            if x >= 0 { res = x >= y ? at(y, x) : 0x4000 &- at(x, y) }
            else { res = (0 &- x) >= y ? 0x8000 &+ at(y, x) : 0x4000 &- at(x, y) }
        } else {
            if x <= 0 { res = (0 &- x) >= (0 &- y) ? 0x8000 &+ at(y, x) : 0xC000 &- at(x, y) }
            else { res = x >= (0 &- y) ? 0x10000 &+ at(y, x) : 0xC000 &- at(x, y) }
        }
        return UInt32(truncatingIfNeeded: res) & 0xFFFF
    }

    private func biosCpuSet() {
        var src = r[0], dst = r[1]
        let ctl = r[2]
        let count = Int(ctl & 0x1F_FFFF)
        let fill = ctl & (1 << 24) != 0, word = ctl & (1 << 26) != 0
        if word {
            src &= ~3; dst &= ~3
            let v = bus.peek32(src)
            for _ in 0..<count {
                bus.poke32(dst, fill ? v : bus.peek32(src))
                if !fill { src &+= 4 }
                dst &+= 4
            }
        } else {
            src &= ~1; dst &= ~1
            let v = bus.peek16(src)
            for _ in 0..<count {
                bus.poke16(dst, fill ? v : bus.peek16(src))
                if !fill { src &+= 2 }
                dst &+= 2
            }
        }
    }

    private func biosCpuFastSet() {
        var src = r[0] & ~3, dst = r[1] & ~3
        let ctl = r[2]
        let count = (Int(ctl & 0x1F_FFFF) + 7) & ~7
        let fill = ctl & (1 << 24) != 0
        let v = bus.peek32(src)
        for _ in 0..<count {
            bus.poke32(dst, fill ? v : bus.peek32(src))
            if !fill { src &+= 4 }
            dst &+= 4
        }
    }
}

nonisolated(unsafe) private var hleWarned = Set<UInt32>()
