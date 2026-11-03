import Foundation

// The data-moving BIOS services (decompression, bit unpacking, affine set-up, resets), written from their documented formats.

extension ARM7TDMI {
    // MARK: waiting for interrupts

    /// IntrWait: enable interrupts, optionally forget stale flags, then sleep until the game's IRQ handler has set one of
    /// `mask`'s bits in the BIOS flag word at 0x03007FF8. The wait itself is carried out in `step()`.
    func startIntrWait(discard: Bool, mask: UInt16) {
        bus.poke16(0x0400_0208, 1)
        if discard { bus.poke16(0x0300_7FF8, bus.peek16(0x0300_7FF8) & ~mask) }
        intrWaitMask = mask
    }

    // MARK: resets

    func biosSoftReset() {
        let toEWRAM = bus.peek8(0x0300_7FFA) != 0
        for a in stride(from: UInt32(0x0300_7E00), to: 0x0300_8000, by: 4) { bus.poke32(a, 0) }
        resetToCartridgeEntry()
        intrWaitMask = 0
        jumpARM(toEWRAM ? 0x0200_0000 : 0x0800_0000)
    }

    func biosRegisterRamReset(_ flags: UInt32) {
        func clear(_ base: UInt32, _ bytes: Int) { for a in stride(from: base, to: base + UInt32(bytes), by: 4) { bus.poke32(a, 0) } }
        if flags & 0x01 != 0 { clear(0x0200_0000, 0x40000) }
        if flags & 0x02 != 0 { clear(0x0300_0000, 0x7E00) }
        if flags & 0x04 != 0 { clear(0x0500_0000, 0x400) }
        if flags & 0x08 != 0 { clear(0x0600_0000, 0x18000) }
        if flags & 0x10 != 0 { clear(0x0700_0000, 0x400) }
        if flags & 0x20 != 0 { for o in stride(from: 0x120, to: 0x12C, by: 2) { bus.poke16(0x0400_0000 + UInt32(o), 0) }; bus.poke16(0x0400_0134, 0x8000) }
        if flags & 0x40 != 0 {
            for o in stride(from: 0x60, to: 0x88, by: 2) { bus.poke16(0x0400_0000 + UInt32(o), 0) }
            bus.poke16(0x0400_0084, 0); bus.poke16(0x0400_0088, 0x0200)
        }
        if flags & 0x80 != 0 {
            for o in stride(from: 0x00, to: 0x60, by: 2) { bus.poke16(0x0400_0000 + UInt32(o), 0) }
            for o in [0x20, 0x26, 0x30, 0x36] { bus.poke16(0x0400_0000 + UInt32(o), 0x100) }
            for o in stride(from: 0xB0, to: 0x110, by: 2) { bus.poke16(0x0400_0000 + UInt32(o), 0) }
            bus.poke16(0x0400_0130 + 2, 0)
        }
    }

    // MARK: decompression

    /// Read the 4-byte header: (type nibble, size in bytes of the decompressed data, low nibble of byte 0).
    private func header(_ src: UInt32) -> (type: UInt32, size: Int, low: UInt32) {
        let h = bus.peek32(src)
        return ((h >> 4) & 0xF, Int(h >> 8), h & 0xF)
    }

    private func store(_ bytes: [UInt8], to dst: UInt32, toVRAM: Bool) {
        if toVRAM {
            var i = 0
            while i < bytes.count {
                let lo = UInt16(bytes[i]), hi = i + 1 < bytes.count ? UInt16(bytes[i + 1]) : 0
                bus.poke16(dst &+ UInt32(i), lo | hi << 8)
                i += 2
            }
        } else {
            for (i, b) in bytes.enumerated() { bus.poke8(dst &+ UInt32(i), b) }
        }
    }

    func biosLZ77(toVRAM: Bool) {
        var src = r[0]
        let (_, size, _) = header(src)
        src &+= 4
        var out = [UInt8](); out.reserveCapacity(size)
        while out.count < size {
            let flags = bus.peek8(src); src &+= 1
            for bit in 0..<8 where out.count < size {
                if flags & (0x80 >> UInt8(bit)) == 0 {
                    out.append(bus.peek8(src)); src &+= 1
                } else {
                    let b1 = Int(bus.peek8(src)), b2 = Int(bus.peek8(src &+ 1)); src &+= 2
                    let length = (b1 >> 4) + 3, disp = ((b1 & 0xF) << 8 | b2) + 1
                    for _ in 0..<length where out.count < size {
                        out.append(out.count >= disp ? out[out.count - disp] : 0)
                    }
                }
            }
        }
        store(out, to: r[1], toVRAM: toVRAM)
    }

    func biosRunLength(toVRAM: Bool) {
        var src = r[0]
        let (_, size, _) = header(src)
        src &+= 4
        var out = [UInt8](); out.reserveCapacity(size)
        while out.count < size {
            let flag = bus.peek8(src); src &+= 1
            if flag & 0x80 != 0 {
                let n = Int(flag & 0x7F) + 3, v = bus.peek8(src); src &+= 1
                for _ in 0..<n where out.count < size { out.append(v) }
            } else {
                let n = Int(flag & 0x7F) + 1
                for _ in 0..<n where out.count < size { out.append(bus.peek8(src)); src &+= 1 }
            }
        }
        store(out, to: r[1], toVRAM: toVRAM)
    }

    func biosHuffman() {
        let src = r[0], dst = r[1]
        let (_, size, dataBits) = header(src)
        guard dataBits == 4 || dataBits == 8 || dataBits == 2 || dataBits == 1 else { return }
        let treeBase = src &+ 4
        let treeBytes = (Int(bus.peek8(treeBase)) + 1) * 2
        var stream = treeBase &+ UInt32(treeBytes)
        var node = UInt32(1)                                            // offset of the current node from treeBase
        var word: UInt32 = 0, filled = 0
        var written = 0
        var outAddr = dst
        while written < size {
            let bits = bus.peek32(stream); stream &+= 4
            for b in stride(from: 31, through: 0, by: -1) where written < size {
                let bit = (bits >> UInt32(b)) & 1
                let n = bus.peek8(treeBase &+ node)
                let next = (node & ~1) &+ UInt32(n & 0x3F) &* 2 &+ 2
                let child = next &+ bit
                let isData = bit == 0 ? n & 0x80 != 0 : n & 0x40 != 0
                if isData {
                    let value = UInt32(bus.peek8(treeBase &+ child))
                    word |= value << UInt32(filled); filled += Int(dataBits)
                    if filled >= 32 { bus.poke32(outAddr, word); outAddr &+= 4; written += 4; word = 0; filled = 0 }
                    node = 1
                } else {
                    node = child
                }
            }
        }
    }

    func biosDiffUnfilter(bytes: Bool, toVRAM: Bool) {
        var src = r[0], dst = r[1]
        let (_, size, _) = header(src)
        src &+= 4
        if bytes {
            var acc: UInt8 = 0
            var out = [UInt8]()
            for i in 0..<size { acc = i == 0 ? bus.peek8(src) : acc &+ bus.peek8(src &+ UInt32(i)); out.append(acc) }
            store(out, to: dst, toVRAM: toVRAM)
        } else {
            var acc: UInt16 = 0
            for i in 0..<(size / 2) {
                let v = bus.peek16(src &+ UInt32(i * 2))
                acc = i == 0 ? v : acc &+ v
                bus.poke16(dst, acc); dst &+= 2
            }
        }
    }

    func biosBitUnPack() {
        let src = r[0], dst = r[1], info = r[2]
        let length = Int(bus.peek16(info))
        let srcWidth = Int(bus.peek8(info &+ 2)), dstWidth = Int(bus.peek8(info &+ 3))
        let offsetWord = bus.peek32(info &+ 4)
        let offset = offsetWord & 0x7FFF_FFFF, zeroFlag = offsetWord & 0x8000_0000 != 0
        guard [1, 2, 4, 8].contains(srcWidth), [1, 2, 4, 8, 16, 32].contains(dstWidth) else { return }
        let mask = UInt32((1 << srcWidth) - 1)
        var word: UInt32 = 0, filled = 0
        var out = dst
        for i in 0..<length {
            let byte = UInt32(bus.peek8(src &+ UInt32(i)))
            for pos in stride(from: 0, to: 8, by: srcWidth) {
                var v = (byte >> UInt32(pos)) & mask
                if v != 0 || zeroFlag { v = v &+ offset }
                word |= (dstWidth == 32 ? v : v & UInt32((1 << dstWidth) - 1)) << UInt32(filled)
                filled += dstWidth
                if filled >= 32 { bus.poke32(out, word); out &+= 4; word = 0; filled = 0 }
            }
        }
    }

    // MARK: affine parameters

    /// sin/cos as 1.14 fixed point for an angle given in the BIOS's 8-bit-significant form (upper byte of a 16-bit angle).
    private func sinCos(_ angle: UInt16) -> (sin: Int32, cos: Int32) {
        let theta = Double(angle >> 8) * 2 * Double.pi / 256
        return (Int32((sin(theta) * 16384).rounded()), Int32((cos(theta) * 16384).rounded()))
    }

    func biosObjAffineSet() {
        var src = r[0], dst = r[1]
        let count = Int(r[2]), stride = r[3]
        for _ in 0..<count {
            let sx = Int32(Int16(truncatingIfNeeded: bus.peek16(src))), sy = Int32(Int16(truncatingIfNeeded: bus.peek16(src &+ 2)))
            let (s, c) = sinCos(bus.peek16(src &+ 4))
            src &+= 8
            let pa = (c * sx) >> 14, pb = -((s * sx) >> 14), pc = (s * sy) >> 14, pd = (c * sy) >> 14
            for (i, v) in [pa, pb, pc, pd].enumerated() { bus.poke16(dst &+ UInt32(i) &* stride, UInt16(truncatingIfNeeded: v)) }
            dst &+= 4 &* stride
        }
    }

    func biosBgAffineSet() {
        var src = r[0], dst = r[1]
        let count = Int(r[2])
        for _ in 0..<count {
            let cx = Int32(bitPattern: bus.peek32(src)), cy = Int32(bitPattern: bus.peek32(src &+ 4))
            let dx = Int32(Int16(truncatingIfNeeded: bus.peek16(src &+ 8))), dy = Int32(Int16(truncatingIfNeeded: bus.peek16(src &+ 10)))
            let sx = Int32(Int16(truncatingIfNeeded: bus.peek16(src &+ 12))), sy = Int32(Int16(truncatingIfNeeded: bus.peek16(src &+ 14)))
            let (s, c) = sinCos(bus.peek16(src &+ 16))
            src &+= 20
            let pa = (c * sx) >> 14, pb = -((s * sx) >> 14), pc = (s * sy) >> 14, pd = (c * sy) >> 14
            let startX = cx &- (pa &* dx &+ pb &* dy), startY = cy &- (pc &* dx &+ pd &* dy)
            bus.poke16(dst, UInt16(truncatingIfNeeded: pa)); bus.poke16(dst &+ 2, UInt16(truncatingIfNeeded: pb))
            bus.poke16(dst &+ 4, UInt16(truncatingIfNeeded: pc)); bus.poke16(dst &+ 6, UInt16(truncatingIfNeeded: pd))
            bus.poke32(dst &+ 8, UInt32(bitPattern: startX)); bus.poke32(dst &+ 12, UInt32(bitPattern: startY))
            dst &+= 16
        }
    }
}
