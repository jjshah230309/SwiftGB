import Foundation

// The Game Boy's CPU (Sharp SM83). Every memory access, and every internal delay, is one `tick()`, so instruction timing
// follows from the structure of each instruction rather than from a lookup table.

private let flagZ: UInt8 = 0x80, flagN: UInt8 = 0x40, flagH: UInt8 = 0x20, flagC: UInt8 = 0x10

extension GBSystem {
    // MARK: register pairs
    var bc: UInt16 { get { UInt16(r[0]) << 8 | UInt16(r[1]) } set { r[0] = UInt8(newValue >> 8); r[1] = UInt8(truncatingIfNeeded: newValue) } }
    var de: UInt16 { get { UInt16(r[2]) << 8 | UInt16(r[3]) } set { r[2] = UInt8(newValue >> 8); r[3] = UInt8(truncatingIfNeeded: newValue) } }
    var hl: UInt16 { get { UInt16(r[4]) << 8 | UInt16(r[5]) } set { r[4] = UInt8(newValue >> 8); r[5] = UInt8(truncatingIfNeeded: newValue) } }
    var af: UInt16 { get { UInt16(r[7]) << 8 | UInt16(f) } set { r[7] = UInt8(newValue >> 8); f = UInt8(truncatingIfNeeded: newValue) & 0xF0 } }

    // MARK: memory with timing
    @inline(__always) func rd(_ a: UInt16) -> UInt8 { let v = read(a); tick(); return v }
    @inline(__always) func wr(_ a: UInt16, _ v: UInt8) { write(a, v); tick() }

    @inline(__always) func fetch8() -> UInt8 {
        let v = rd(pc)
        if haltBug { haltBug = false } else { pc &+= 1 }
        return v
    }

    @inline(__always) func fetch16() -> UInt16 { let lo = fetch8(); let hi = fetch8(); return UInt16(hi) << 8 | UInt16(lo) }

    @inline(__always) private func push16(_ v: UInt16) {
        sp &-= 1; wr(sp, UInt8(v >> 8))
        sp &-= 1; wr(sp, UInt8(truncatingIfNeeded: v))
    }

    @inline(__always) private func pop16() -> UInt16 {
        let lo = rd(sp); sp &+= 1
        let hi = rd(sp); sp &+= 1
        return UInt16(hi) << 8 | UInt16(lo)
    }

    // 8-bit operand by opcode index: B C D E H L (HL) A
    @inline(__always) private func getR(_ i: Int) -> UInt8 { i == 6 ? rd(hl) : r[i] }
    @inline(__always) private func setR(_ i: Int, _ v: UInt8) { if i == 6 { wr(hl, v) } else { r[i] = v } }

    private func pair(_ i: Int) -> UInt16 {
        switch i { case 0: return bc; case 1: return de; case 2: return hl; default: return sp }
    }
    private func setPair(_ i: Int, _ v: UInt16) {
        switch i { case 0: bc = v; case 1: de = v; case 2: hl = v; default: sp = v }
    }

    private func condition(_ c: Int) -> Bool {
        switch c { case 0: return f & flagZ == 0; case 1: return f & flagZ != 0; case 2: return f & flagC == 0; default: return f & flagC != 0 }
    }

    // MARK: ALU
    private func alu(_ op: Int, _ v: UInt8) {
        let a = r[7]
        switch op {
        case 0: // ADD
            let s = Int(a) + Int(v)
            f = (UInt8(truncatingIfNeeded: s) == 0 ? flagZ : 0) | ((Int(a & 0xF) + Int(v & 0xF)) > 0xF ? flagH : 0) | (s > 0xFF ? flagC : 0)
            r[7] = UInt8(truncatingIfNeeded: s)
        case 1: // ADC
            let c = Int((f >> 4) & 1)
            let s = Int(a) + Int(v) + c
            f = (UInt8(truncatingIfNeeded: s) == 0 ? flagZ : 0) | ((Int(a & 0xF) + Int(v & 0xF) + c) > 0xF ? flagH : 0) | (s > 0xFF ? flagC : 0)
            r[7] = UInt8(truncatingIfNeeded: s)
        case 2, 7: // SUB, CP
            let s = Int(a) - Int(v)
            f = flagN | (UInt8(truncatingIfNeeded: s) == 0 ? flagZ : 0) | ((Int(a & 0xF) - Int(v & 0xF)) < 0 ? flagH : 0) | (s < 0 ? flagC : 0)
            if op == 2 { r[7] = UInt8(truncatingIfNeeded: s) }
        case 3: // SBC
            let c = Int((f >> 4) & 1)
            let s = Int(a) - Int(v) - c
            f = flagN | (UInt8(truncatingIfNeeded: s) == 0 ? flagZ : 0) | ((Int(a & 0xF) - Int(v & 0xF) - c) < 0 ? flagH : 0) | (s < 0 ? flagC : 0)
            r[7] = UInt8(truncatingIfNeeded: s)
        case 4: r[7] = a & v; f = (r[7] == 0 ? flagZ : 0) | flagH
        case 5: r[7] = a ^ v; f = r[7] == 0 ? flagZ : 0
        default: r[7] = a | v; f = r[7] == 0 ? flagZ : 0
        }
    }

    private func inc8(_ v: UInt8) -> UInt8 {
        let n = v &+ 1
        f = (f & flagC) | (n == 0 ? flagZ : 0) | (v & 0xF == 0xF ? flagH : 0)
        return n
    }

    private func dec8(_ v: UInt8) -> UInt8 {
        let n = v &- 1
        f = (f & flagC) | flagN | (n == 0 ? flagZ : 0) | (v & 0xF == 0 ? flagH : 0)
        return n
    }

    private func addHL(_ v: UInt16) {
        let h = hl
        let s = Int(h) + Int(v)
        f = (f & flagZ) | ((Int(h & 0xFFF) + Int(v & 0xFFF)) > 0xFFF ? flagH : 0) | (s > 0xFFFF ? flagC : 0)
        hl = UInt16(truncatingIfNeeded: s)
        tick()
    }

    /// SP + signed 8-bit offset with the flags both ADD SP,e and LD HL,SP+e produce.
    private func spPlus(_ e: UInt8) -> UInt16 {
        let off = UInt16(bitPattern: Int16(Int8(bitPattern: e)))
        f = ((sp & 0xF) + (off & 0xF) > 0xF ? flagH : 0) | ((sp & 0xFF) + (off & 0xFF) > 0xFF ? flagC : 0)
        return sp &+ off
    }

    private func daa() {
        var a = r[7]
        var carry = f & flagC != 0
        if f & flagN == 0 {
            var adj: UInt8 = 0
            if carry || a > 0x99 { adj |= 0x60; carry = true }
            if f & flagH != 0 || a & 0x0F > 9 { adj |= 0x06 }
            a = a &+ adj
        } else {
            if carry { a = a &- 0x60 }
            if f & flagH != 0 { a = a &- 0x06 }
        }
        r[7] = a
        f = (f & flagN) | (a == 0 ? flagZ : 0) | (carry ? flagC : 0)
    }

    // MARK: CB-prefixed
    private func cbOperation(_ op: UInt8) {
        let i = Int(op & 7)
        let kind = Int(op >> 6), bit = Int((op >> 3) & 7)
        if kind == 1 {                                              // BIT
            let v = getR(i)
            f = (f & flagC) | flagH | (v & (1 << UInt8(bit)) == 0 ? flagZ : 0)
            return
        }
        let v = getR(i)
        var out: UInt8
        switch kind {
        case 2: out = v & ~(1 << UInt8(bit))                        // RES
        case 3: out = v | (1 << UInt8(bit))                         // SET
        default:
            let cIn: UInt8 = (f >> 4) & 1
            var c: UInt8
            switch bit {
            case 0: c = v >> 7; out = v << 1 | c                    // RLC
            case 1: c = v & 1; out = v >> 1 | c << 7                // RRC
            case 2: c = v >> 7; out = v << 1 | cIn                  // RL
            case 3: c = v & 1; out = v >> 1 | cIn << 7              // RR
            case 4: c = v >> 7; out = v << 1                        // SLA
            case 5: c = v & 1; out = (v >> 1) | (v & 0x80)          // SRA
            case 6: c = 0; out = v << 4 | v >> 4                    // SWAP
            default: c = v & 1; out = v >> 1                        // SRL
            }
            f = (out == 0 ? flagZ : 0) | (c != 0 ? flagC : 0)
        }
        setR(i, out)
    }

    // MARK: stepping

    /// Run one instruction (or take one interrupt, or idle one machine cycle while halted).
    func step() {
        if hdmaPending { serviceHDMA() }
        let pending = ie & ifr & 0x1F
        if halted {
            if pending == 0 { tick(); return }
            halted = false
        }
        if ime && pending != 0 { serviceInterrupt(); return }

        execute(fetch8())

        if eiPending > 0 { eiPending -= 1; if eiPending == 0 { ime = true } }
    }

    private func serviceInterrupt() {
        ime = false
        tick(); tick()
        sp &-= 1; wr(sp, UInt8(pc >> 8))
        let pending = ie & ifr & 0x1F                           // re-checked: the push may have rewritten IE (when SP points at FFFF)
        sp &-= 1; wr(sp, UInt8(truncatingIfNeeded: pc))
        tick()                                                  // loading the vector is the fifth machine cycle
        if pending == 0 { pc = 0; return }
        let bit = pending.trailingZeroBitCount
        ifr &= ~(1 << UInt8(bit))
        pc = 0x40 + UInt16(bit) * 8
    }

    private func execute(_ op: UInt8) {
        switch op {
        case 0x00: break
        case 0x01, 0x11, 0x21, 0x31: setPair(Int(op >> 4), fetch16())
        case 0x02: wr(bc, r[7])
        case 0x12: wr(de, r[7])
        case 0x22: let a = hl; wr(a, r[7]); hl = a &+ 1
        case 0x32: let a = hl; wr(a, r[7]); hl = a &- 1
        case 0x0A: r[7] = rd(bc)
        case 0x1A: r[7] = rd(de)
        case 0x2A: let a = hl; r[7] = rd(a); hl = a &+ 1
        case 0x3A: let a = hl; r[7] = rd(a); hl = a &- 1
        case 0x03, 0x13, 0x23, 0x33: let i = Int(op >> 4); setPair(i, pair(i) &+ 1); tick()
        case 0x0B, 0x1B, 0x2B, 0x3B: let i = Int(op >> 4); setPair(i, pair(i) &- 1); tick()
        case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C: let i = Int(op >> 3); setR(i, inc8(getR(i)))
        case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D: let i = Int(op >> 3); setR(i, dec8(getR(i)))
        case 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x36, 0x3E: let i = Int(op >> 3); setR(i, fetch8())
        case 0x07: let c = r[7] >> 7; r[7] = r[7] << 1 | c; f = c != 0 ? flagC : 0
        case 0x0F: let c = r[7] & 1; r[7] = r[7] >> 1 | c << 7; f = c != 0 ? flagC : 0
        case 0x17: let c = r[7] >> 7; r[7] = r[7] << 1 | (f >> 4) & 1; f = c != 0 ? flagC : 0
        case 0x1F: let c = r[7] & 1; r[7] = r[7] >> 1 | ((f >> 4) & 1) << 7; f = c != 0 ? flagC : 0
        case 0x08:
            let a = fetch16()
            wr(a, UInt8(truncatingIfNeeded: sp)); wr(a &+ 1, UInt8(sp >> 8))
        case 0x09, 0x19, 0x29, 0x39: addHL(pair(Int(op >> 4)))
        case 0x10: stop()
        case 0x18: let e = Int8(bitPattern: fetch8()); tick(); pc = UInt16(bitPattern: Int16(bitPattern: pc) &+ Int16(e))
        case 0x20, 0x28, 0x30, 0x38:
            let e = Int8(bitPattern: fetch8())
            if condition(Int((op >> 3) & 3)) { tick(); pc = UInt16(bitPattern: Int16(bitPattern: pc) &+ Int16(e)) }
        case 0x27: daa()
        case 0x2F: r[7] = ~r[7]; f |= flagN | flagH
        case 0x37: f = (f & flagZ) | flagC
        case 0x3F: f = (f & flagZ) | (f & flagC ^ flagC)
        case 0x76:
            if !ime && ie & ifr & 0x1F != 0 { haltBug = true } else { halted = true }
        case 0x40...0x7F:
            let dst = Int((op >> 3) & 7), src = Int(op & 7)
            setR(dst, getR(src))
        case 0x80...0xBF: alu(Int((op >> 3) & 7), getR(Int(op & 7)))
        case 0xC0, 0xC8, 0xD0, 0xD8:
            tick()
            if condition(Int((op >> 3) & 3)) { pc = pop16(); tick() }
        case 0xC9: pc = pop16(); tick()
        case 0xD9: pc = pop16(); tick(); ime = true
        case 0xC1, 0xD1, 0xE1: setPair(Int((op >> 4) & 3), pop16())
        case 0xF1: af = pop16()
        case 0xC5, 0xD5, 0xE5: tick(); push16(pair(Int((op >> 4) & 3)))
        case 0xF5: tick(); push16(af)
        case 0xC2, 0xCA, 0xD2, 0xDA:
            let a = fetch16()
            if condition(Int((op >> 3) & 3)) { tick(); pc = a }
        case 0xC3: let a = fetch16(); tick(); pc = a
        case 0xE9: pc = hl
        case 0xC4, 0xCC, 0xD4, 0xDC:
            let a = fetch16()
            if condition(Int((op >> 3) & 3)) { tick(); push16(pc); pc = a }
        case 0xCD: let a = fetch16(); tick(); push16(pc); pc = a
        case 0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE: alu(Int((op >> 3) & 7), fetch8())
        case 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF: tick(); push16(pc); pc = UInt16(op & 0x38)
        case 0xCB: cbOperation(fetch8())
        case 0xE0: let a = UInt16(0xFF00) | UInt16(fetch8()); wr(a, r[7])
        case 0xE2: wr(0xFF00 | UInt16(r[1]), r[7])
        case 0xEA: let a = fetch16(); wr(a, r[7])
        case 0xF0: let a = UInt16(0xFF00) | UInt16(fetch8()); r[7] = rd(a)
        case 0xF2: r[7] = rd(0xFF00 | UInt16(r[1]))
        case 0xFA: let a = fetch16(); r[7] = rd(a)
        case 0xE8: let e = fetch8(); sp = spPlus(e); f &= 0x30; tick(); tick()
        case 0xF8: let e = fetch8(); hl = spPlus(e); tick()
        case 0xF9: sp = hl; tick()
        case 0xF3: ime = false; eiPending = 0
        case 0xFB: if !ime { eiPending = 2 }
        default: break                                              // undefined opcodes: real hardware locks up; ignoring them is kinder to broken ROMs
        }
    }

    private func stop() {
        _ = fetch8()                                                // STOP is a two-byte instruction
        if isCGB && speedSwitchArmed {
            speedSwitchArmed = false
            doubleSpeed.toggle()
            sysCounter = 0
            for _ in 0..<2050 { tick() }                            // the switch takes about 2050 machine cycles
        }
    }
}
