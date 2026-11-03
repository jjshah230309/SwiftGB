import Foundation

extension ARM7TDMI {
    func execThumb(_ op: UInt32) {
        switch op >> 13 {
        case 0:
            if (op >> 11) & 3 == 3 {                                  // add / subtract (register or 3-bit immediate)
                let rd = Int(op & 7), rs = Int((op >> 3) & 7)
                let n = (op >> 6) & 7
                let b = op & 0x0400 != 0 ? n : r[Int(n)]
                r[rd] = op & 0x0200 != 0 ? addCore(r[rs], ~b, 1, true) : addCore(r[rs], b, 0, true)
            } else {                                                  // shift by immediate
                let rd = Int(op & 7), rs = Int((op >> 3) & 7)
                let (v, c) = shiftImm(r[rs], (op >> 11) & 3, (op >> 6) & 0x1F, carryIn)
                r[rd] = v
                setNZ(v); setCarry(c)
            }
        case 1:                                                       // MOV / CMP / ADD / SUB with 8-bit immediate
            let rd = Int((op >> 8) & 7), imm = op & 0xFF
            switch (op >> 11) & 3 {
            case 0: r[rd] = imm; setNZ(imm)
            case 1: _ = addCore(r[rd], ~imm, 1, true)
            case 2: r[rd] = addCore(r[rd], imm, 0, true)
            default: r[rd] = addCore(r[rd], ~imm, 1, true)
            }
        case 2:
            if op & 0x1000 == 0 {
                if op & 0x0800 != 0 {                                 // LDR rd, [pc, #imm]
                    let rd = Int((op >> 8) & 7)
                    let addr = (r[15] & ~3) &+ (op & 0xFF) * 4
                    r[rd] = bus.read32(addr)
                    bus.internalCycles(1)
                } else if op & 0x0400 == 0 {
                    thumbALU(op)
                } else {
                    thumbHiRegister(op)
                }
            } else {
                thumbLoadStoreRegister(op)
            }
        case 3:                                                       // load/store word/byte with immediate offset
            let rd = Int(op & 7), rb = Int((op >> 3) & 7)
            let imm = (op >> 6) & 0x1F
            let byte = op & 0x1000 != 0
            let addr = r[rb] &+ (byte ? imm : imm * 4)
            if op & 0x0800 != 0 {
                r[rd] = byte ? UInt32(bus.read8(addr)) : rotr(bus.read32(addr & ~3), (addr & 3) * 8)
                bus.internalCycles(1)
            } else if byte {
                bus.write8(addr, UInt8(truncatingIfNeeded: r[rd]))
            } else {
                bus.write32(addr, r[rd])
            }
        case 4:
            if op & 0x1000 == 0 {                                     // halfword with immediate offset
                let rd = Int(op & 7), rb = Int((op >> 3) & 7)
                let addr = r[rb] &+ ((op >> 6) & 0x1F) * 2
                if op & 0x0800 != 0 {
                    var v = UInt32(bus.read16(addr & ~1))
                    if addr & 1 != 0 { v = rotr(v, 8) }
                    r[rd] = v
                    bus.internalCycles(1)
                } else {
                    bus.write16(addr, UInt16(truncatingIfNeeded: r[rd]))
                }
            } else {                                                  // SP-relative load/store
                let rd = Int((op >> 8) & 7)
                let addr = r[13] &+ (op & 0xFF) * 4
                if op & 0x0800 != 0 {
                    r[rd] = rotr(bus.read32(addr & ~3), (addr & 3) * 8)
                    bus.internalCycles(1)
                } else {
                    bus.write32(addr, r[rd])
                }
            }
        case 5:
            if op & 0x1000 == 0 {                                     // ADD rd, pc/sp, #imm
                let rd = Int((op >> 8) & 7), imm = (op & 0xFF) * 4
                r[rd] = op & 0x0800 != 0 ? r[13] &+ imm : (r[15] & ~3) &+ imm
            } else if op & 0x0F00 == 0 {                              // ADD sp, #+-imm
                let imm = (op & 0x7F) * 4
                r[13] = op & 0x80 != 0 ? r[13] &- imm : r[13] &+ imm
            } else if op & 0x0600 == 0x0400 {
                thumbPushPop(op)
            } else {
                enterUndefined(returnAddress: currentAddr &+ 2)
            }
        case 6:
            if op & 0x1000 == 0 { thumbBlockTransfer(op) }
            else {
                let cond = (op >> 8) & 0xF
                if cond == 0xF {
                    let number = op & 0xFF
                    if useHLEBIOS { hleSWI(number) } else { enterSWI(returnAddress: currentAddr &+ 2) }
                } else if cond == 0xE {
                    enterUndefined(returnAddress: currentAddr &+ 2)
                } else if condition(cond) {
                    let off = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: op)) << 1)
                    jumpThumb(r[15] &+ off)
                }
            }
        default:
            switch (op >> 11) & 3 {
            case 0:                                                   // unconditional branch
                let off = UInt32(bitPattern: (Int32(bitPattern: op << 21) >> 21) << 1)
                jumpThumb(r[15] &+ off)
            case 2:                                                   // BL, first half: stash the upper offset in LR
                r[14] = r[15] &+ UInt32(bitPattern: (Int32(bitPattern: op << 21) >> 21) << 12)
            case 3:                                                   // BL, second half
                let target = r[14] &+ ((op & 0x7FF) << 1)
                r[14] = (currentAddr &+ 2) | 1
                jumpThumb(target)
            default:
                enterUndefined(returnAddress: currentAddr &+ 2)
            }
        }
    }

    // MARK: ALU operations (format 4)

    private func thumbALU(_ op: UInt32) {
        let rd = Int(op & 7), rs = Int((op >> 3) & 7)
        let a = r[rd], b = r[rs]
        let c = carryIn
        switch (op >> 6) & 0xF {
        case 0x0: let v = a & b; r[rd] = v; setNZ(v)
        case 0x1: let v = a ^ b; r[rd] = v; setNZ(v)
        case 0x2: let (v, cc) = shiftReg(a, 0, b & 0xFF, c); r[rd] = v; setNZ(v); setCarry(cc); bus.internalCycles(1)
        case 0x3: let (v, cc) = shiftReg(a, 1, b & 0xFF, c); r[rd] = v; setNZ(v); setCarry(cc); bus.internalCycles(1)
        case 0x4: let (v, cc) = shiftReg(a, 2, b & 0xFF, c); r[rd] = v; setNZ(v); setCarry(cc); bus.internalCycles(1)
        case 0x5: r[rd] = addCore(a, b, c, true)
        case 0x6: r[rd] = addCore(a, ~b, c, true)
        case 0x7: let (v, cc) = shiftReg(a, 3, b & 0xFF, c); r[rd] = v; setNZ(v); setCarry(cc); bus.internalCycles(1)
        case 0x8: setNZ(a & b)
        case 0x9: r[rd] = addCore(0, ~b, 1, true)                    // NEG
        case 0xA: _ = addCore(a, ~b, 1, true)
        case 0xB: _ = addCore(a, b, 0, true)
        case 0xC: let v = a | b; r[rd] = v; setNZ(v)
        case 0xD:
            let v = a &* b
            r[rd] = v; setNZ(v)
            bus.internalCycles(multiplyCyclesThumb(a))
        case 0xE: let v = a & ~b; r[rd] = v; setNZ(v)
        default: let v = ~b; r[rd] = v; setNZ(v)
        }
    }

    @inline(__always) private func multiplyCyclesThumb(_ rs: UInt32) -> Int {
        var v = rs
        if v & 0x8000_0000 != 0 { v = ~v }
        if v >> 8 == 0 { return 1 }
        if v >> 16 == 0 { return 2 }
        if v >> 24 == 0 { return 3 }
        return 4
    }

    // MARK: hi-register operations / BX (format 5)

    private func thumbHiRegister(_ op: UInt32) {
        let rd = Int((op & 7) | ((op >> 4) & 8)), rs = Int(((op >> 3) & 7) | ((op >> 3) & 8))
        switch (op >> 8) & 3 {
        case 0:
            let v = r[rd] &+ r[rs]
            if rd == 15 { jumpThumb(v) } else { r[rd] = v }
        case 1:
            _ = addCore(r[rd], ~r[rs], 1, true)
        case 2:
            let v = r[rs]
            if rd == 15 { jumpThumb(v) } else { r[rd] = v }
        default:
            let target = r[rs]
            if target & 1 != 0 { jumpThumb(target) } else { cpsr &= ~0x20; jumpARM(target) }
        }
    }

    // MARK: load/store with register offset (formats 7 and 8)

    private func thumbLoadStoreRegister(_ op: UInt32) {
        let rd = Int(op & 7), rb = Int((op >> 3) & 7), ro = Int((op >> 6) & 7)
        let addr = r[rb] &+ r[ro]
        if op & 0x0200 == 0 {
            switch (op >> 10) & 3 {
            case 0: bus.write32(addr, r[rd])
            case 1: bus.write8(addr, UInt8(truncatingIfNeeded: r[rd]))
            case 2: r[rd] = rotr(bus.read32(addr & ~3), (addr & 3) * 8); bus.internalCycles(1)
            default: r[rd] = UInt32(bus.read8(addr)); bus.internalCycles(1)
            }
        } else {
            switch (op >> 10) & 3 {
            case 0: bus.write16(addr, UInt16(truncatingIfNeeded: r[rd]))
            case 1: r[rd] = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: bus.read8(addr)))); bus.internalCycles(1)
            case 2:
                var v = UInt32(bus.read16(addr & ~1))
                if addr & 1 != 0 { v = rotr(v, 8) }
                r[rd] = v; bus.internalCycles(1)
            default:
                if addr & 1 != 0 { r[rd] = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: bus.read8(addr)))) }
                else { r[rd] = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: bus.read16(addr)))) }
                bus.internalCycles(1)
            }
        }
    }

    // MARK: PUSH / POP

    private func thumbPushPop(_ op: UInt32) {
        let list = op & 0xFF
        let extra = op & 0x0100 != 0
        let count = list.nonzeroBitCount + (extra ? 1 : 0)
        if op & 0x0800 == 0 {                                         // PUSH
            var addr = r[13] &- UInt32(count * 4)
            r[13] = addr
            for i in 0..<8 where list & (1 << UInt32(i)) != 0 { bus.write32(addr, r[i]); addr &+= 4 }
            if extra { bus.write32(addr, r[14]) }
        } else {                                                      // POP
            var addr = r[13]
            for i in 0..<8 where list & (1 << UInt32(i)) != 0 { r[i] = bus.read32(addr); addr &+= 4 }
            bus.internalCycles(1)
            if extra {
                let v = bus.read32(addr); addr &+= 4
                r[13] = addr
                jumpThumb(v)
            } else {
                r[13] = addr
            }
        }
    }

    // MARK: STMIA / LDMIA

    private func thumbBlockTransfer(_ op: UInt32) {
        let rb = Int((op >> 8) & 7)
        var list = op & 0xFF
        let base = r[rb]
        var count = list.nonzeroBitCount
        var emptyList = false
        if list == 0 { emptyList = true; count = 16 }               // empty list: transfers r15, base moves by 0x40
        let newBase = base &+ UInt32(count * 4)
        var addr = base & ~3
        let load = op & 0x0800 != 0
        let first = list.trailingZeroBitCount
        if load {
            if emptyList {
                let v = bus.read32(addr)
                r[rb] = newBase
                jumpThumb(v)
            } else {
                r[rb] = newBase                                       // a loaded base register overrides the writeback
                for i in 0..<8 where list & (1 << UInt32(i)) != 0 { r[i] = bus.read32(addr); addr &+= 4 }
            }
            bus.internalCycles(1)
        } else {
            if emptyList {
                bus.write32(addr, currentAddr &+ 6)
                r[rb] = newBase
            } else {
                for i in 0..<8 where list & (1 << UInt32(i)) != 0 {
                    var v = r[i]
                    if i == rb && i != first { v = newBase }
                    bus.write32(addr, v)
                    addr &+= 4
                }
                r[rb] = newBase
            }
        }
        list = 0
    }
}
