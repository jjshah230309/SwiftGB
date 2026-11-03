import Foundation

extension ARM7TDMI {
    func execARM(_ op: UInt32) {
        switch (op >> 25) & 7 {
        case 0:
            if op & 0x90 == 0x90 {                               // bit 7 and bit 4 set: multiply / swap / halfword transfer
                if op & 0x60 == 0 {
                    if op & 0x0100_0000 == 0 {
                        if op & 0x0080_0000 == 0 { armMultiply(op) } else { armMultiplyLong(op) }
                    } else {
                        armSwap(op)
                    }
                } else {
                    armHalfwordTransfer(op)
                }
            } else if op & 0x0190_0000 == 0x0100_0000 {          // TST/TEQ/CMP/CMN encodings with S = 0: PSR transfer / BX
                if op & 0x0FFF_FFF0 == 0x012F_FF10 { armBX(op) }
                else if op & 0x0FBF_0FFF == 0x010F_0000 { armMRS(op) }
                else if op & 0x0FB0_FFF0 == 0x0120_F000 { armMSR(op, value: r[Int(op & 0xF)]) }
                else { enterUndefined(returnAddress: currentAddr &+ 4) }
            } else {
                armDataProcessing(op)
            }
        case 1:
            if op & 0x01B0_0000 == 0x0120_0000 {                 // MSR with immediate
                let imm = op & 0xFF, rot = ((op >> 8) & 0xF) * 2
                armMSR(op, value: rotr(imm, rot))
            } else if op & 0x0190_0000 == 0x0100_0000 {
                enterUndefined(returnAddress: currentAddr &+ 4)
            } else {
                armDataProcessing(op)
            }
        case 2: armSingleTransfer(op)
        case 3:
            if op & 0x10 != 0 { enterUndefined(returnAddress: currentAddr &+ 4) } else { armSingleTransfer(op) }
        case 4: armBlockTransfer(op)
        case 5:
            let off = UInt32(bitPattern: (Int32(bitPattern: op << 8) >> 8) << 2)
            if op & 0x0100_0000 != 0 { r[14] = currentAddr &+ 4 }
            jumpARM(currentAddr &+ 8 &+ off)
        case 7 where op & 0x0100_0000 != 0:
            let number = (op >> 16) & 0xFF
            if useHLEBIOS { hleSWI(number) } else { enterSWI(returnAddress: currentAddr &+ 4) }
        default:
            enterUndefined(returnAddress: currentAddr &+ 4)      // coprocessor instructions: no coprocessors on the GBA
        }
    }

    // MARK: data processing

    private func armDataProcessing(_ op: UInt32) {
        let opcode = (op >> 21) & 0xF
        let s = op & 0x0010_0000 != 0
        let rn = Int((op >> 16) & 0xF), rd = Int((op >> 12) & 0xF)
        let c = carryIn
        var shifterCarry = c
        var op2: UInt32
        var a = r[rn]

        if op & 0x0200_0000 != 0 {
            let imm = op & 0xFF, rot = ((op >> 8) & 0xF) * 2
            op2 = rotr(imm, rot)
            if rot != 0 { shifterCarry = op2 >> 31 }
        } else {
            let rm = Int(op & 0xF)
            var v = r[rm]
            let type = (op >> 5) & 3
            if op & 0x10 != 0 {                                    // shift amount from a register: extra internal cycle, PC reads +12
                if rm == 15 { v = v &+ 4 }
                if rn == 15 { a = a &+ 4 }
                bus.internalCycles(1)
                (op2, shifterCarry) = shiftReg(v, type, r[Int((op >> 8) & 0xF)] & 0xFF, c)
            } else {
                (op2, shifterCarry) = shiftImm(v, type, (op >> 7) & 0x1F, c)
            }
        }

        var result: UInt32 = 0
        var write = true
        let setFlags = s && rd != 15 || (s && opcode >= 8 && opcode <= 11)
        switch opcode {
        case 0x0: result = a & op2; if setFlags { setNZ(result); setCarry(shifterCarry) }
        case 0x1: result = a ^ op2; if setFlags { setNZ(result); setCarry(shifterCarry) }
        case 0x2: result = addCore(a, ~op2, 1, setFlags)
        case 0x3: result = addCore(op2, ~a, 1, setFlags)
        case 0x4: result = addCore(a, op2, 0, setFlags)
        case 0x5: result = addCore(a, op2, c, setFlags)
        case 0x6: result = addCore(a, ~op2, c, setFlags)
        case 0x7: result = addCore(op2, ~a, c, setFlags)
        case 0x8: write = false; let t = a & op2; setNZ(t); setCarry(shifterCarry)
        case 0x9: write = false; let t = a ^ op2; setNZ(t); setCarry(shifterCarry)
        case 0xA: write = false; _ = addCore(a, ~op2, 1, true)
        case 0xB: write = false; _ = addCore(a, op2, 0, true)
        case 0xC: result = a | op2; if setFlags { setNZ(result); setCarry(shifterCarry) }
        case 0xD: result = op2; if setFlags { setNZ(result); setCarry(shifterCarry) }
        case 0xE: result = a & ~op2; if setFlags { setNZ(result); setCarry(shifterCarry) }
        default: result = ~op2; if setFlags { setNZ(result); setCarry(shifterCarry) }
        }

        guard write else {
            // Quirk: TST/TEQ/CMP/CMN with Rd = r15 and S = 1 also copy SPSR into CPSR (no pipeline flush).
            if rd == 15 { setCPSR(spsr) }
            return
        }
        if rd == 15 {
            if s {                                                  // exception return: CPSR <- SPSR
                let saved = spsr
                setCPSR(saved)
            }
            jumpCurrentState(result)
        } else {
            r[rd] = result
        }
    }

    // MARK: PSR transfer

    private func armMRS(_ op: UInt32) {
        let rd = Int((op >> 12) & 0xF)
        r[rd] = op & 0x0040_0000 != 0 ? spsr : cpsr
    }

    private func armMSR(_ op: UInt32, value: UInt32) {
        var mask: UInt32 = 0
        if op & 0x0008_0000 != 0 { mask |= 0xFF00_0000 }
        if op & 0x0004_0000 != 0 { mask |= 0x00FF_0000 }
        if op & 0x0002_0000 != 0 { mask |= 0x0000_FF00 }
        if op & 0x0001_0000 != 0 { mask |= 0x0000_00FF }
        if op & 0x0040_0000 != 0 {
            if currentGroup != 0 { spsr = (spsr & ~mask) | (value & mask) }
        } else {
            if cpsr & 0x1F == 0x10 { mask &= 0xFF00_0000 }          // user mode may only change the flags
            setCPSR((cpsr & ~mask) | (value & mask))
        }
    }

    private func armBX(_ op: UInt32) {
        let target = r[Int(op & 0xF)]
        if target & 1 != 0 { cpsr |= 0x20; jumpThumb(target) } else { cpsr &= ~0x20; jumpARM(target) }
    }

    // MARK: multiply / swap

    @inline(__always) private func multiplyCycles(_ rs: UInt32, signed: Bool) -> Int {
        var v = rs
        if signed && v & 0x8000_0000 != 0 { v = ~v }
        if v >> 8 == 0 { return 1 }
        if v >> 16 == 0 { return 2 }
        if v >> 24 == 0 { return 3 }
        return 4
    }

    private func armMultiply(_ op: UInt32) {
        let rd = Int((op >> 16) & 0xF), rn = Int((op >> 12) & 0xF), rs = Int((op >> 8) & 0xF), rm = Int(op & 0xF)
        var res = r[rm] &* r[rs]
        let acc = op & 0x0020_0000 != 0
        if acc { res = res &+ r[rn] }
        bus.internalCycles(multiplyCycles(r[rs], signed: true) + (acc ? 1 : 0))
        r[rd] = res
        if op & 0x0010_0000 != 0 { setNZ(res) }
    }

    private func armMultiplyLong(_ op: UInt32) {
        let hi = Int((op >> 16) & 0xF), lo = Int((op >> 12) & 0xF), rs = Int((op >> 8) & 0xF), rm = Int(op & 0xF)
        let signed = op & 0x0040_0000 != 0, acc = op & 0x0020_0000 != 0
        var res: UInt64
        if signed {
            res = UInt64(bitPattern: Int64(Int32(bitPattern: r[rm])) &* Int64(Int32(bitPattern: r[rs])))
        } else {
            res = UInt64(r[rm]) &* UInt64(r[rs])
        }
        if acc { res = res &+ ((UInt64(r[hi]) << 32) | UInt64(r[lo])) }
        bus.internalCycles(multiplyCycles(r[rs], signed: signed) + (acc ? 2 : 1))
        r[lo] = UInt32(truncatingIfNeeded: res)
        r[hi] = UInt32(truncatingIfNeeded: res >> 32)
        if op & 0x0010_0000 != 0 {
            cpsr = (cpsr & 0x3FFF_FFFF) | (UInt32(truncatingIfNeeded: res >> 32) & 0x8000_0000) | (res == 0 ? 0x4000_0000 : 0)
        }
    }

    private func armSwap(_ op: UInt32) {
        let rn = Int((op >> 16) & 0xF), rd = Int((op >> 12) & 0xF), rm = Int(op & 0xF)
        let addr = r[rn]
        let src = r[rm]
        if op & 0x0040_0000 != 0 {
            let old = UInt32(bus.read8(addr))
            bus.write8(addr, UInt8(truncatingIfNeeded: src))
            r[rd] = old
        } else {
            let old = rotr(bus.read32(addr & ~3), (addr & 3) * 8)
            bus.write32(addr, src)
            r[rd] = old
        }
        bus.internalCycles(1)
    }

    // MARK: single data transfer

    private func armSingleTransfer(_ op: UInt32) {
        let load = op & 0x0010_0000 != 0, byte = op & 0x0040_0000 != 0
        let up = op & 0x0080_0000 != 0, pre = op & 0x0100_0000 != 0, wb = op & 0x0020_0000 != 0
        let rn = Int((op >> 16) & 0xF), rd = Int((op >> 12) & 0xF)
        let offset: UInt32
        if op & 0x0200_0000 == 0 {
            offset = op & 0xFFF
        } else {
            offset = shiftImm(r[Int(op & 0xF)], (op >> 5) & 3, (op >> 7) & 0x1F, carryIn).0
        }
        let base = r[rn]
        let moved = up ? base &+ offset : base &- offset
        let addr = pre ? moved : base
        let writeBack = !pre || wb

        if load {
            let value = byte ? UInt32(bus.read8(addr)) : rotr(bus.read32(addr & ~3), (addr & 3) * 8)
            bus.internalCycles(1)
            if writeBack && rn != rd { r[rn] = moved }
            if rd == 15 { jumpARM(value) } else { r[rd] = value }
        } else {
            var value = r[rd]
            if rd == 15 { value = value &+ 4 }
            if byte { bus.write8(addr, UInt8(truncatingIfNeeded: value)) } else { bus.write32(addr, value) }
            if writeBack { r[rn] = moved }
        }
    }

    private func armHalfwordTransfer(_ op: UInt32) {
        let load = op & 0x0010_0000 != 0
        let up = op & 0x0080_0000 != 0, pre = op & 0x0100_0000 != 0, wb = op & 0x0020_0000 != 0
        let rn = Int((op >> 16) & 0xF), rd = Int((op >> 12) & 0xF)
        let offset: UInt32 = op & 0x0040_0000 != 0 ? ((op >> 4) & 0xF0) | (op & 0xF) : r[Int(op & 0xF)]
        let base = r[rn]
        let moved = up ? base &+ offset : base &- offset
        let addr = pre ? moved : base
        let writeBack = !pre || wb
        let kind = (op >> 5) & 3                                     // 1 = H, 2 = SB, 3 = SH

        if load {
            var value: UInt32
            switch kind {
            case 1:
                value = UInt32(bus.read16(addr & ~1))
                if addr & 1 != 0 { value = rotr(value, 8) }
            case 2:
                value = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: bus.read8(addr))))
            default:
                if addr & 1 != 0 {                                    // misaligned LDRSH behaves like LDRSB
                    value = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: bus.read8(addr))))
                } else {
                    value = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: bus.read16(addr))))
                }
            }
            bus.internalCycles(1)
            if writeBack && rn != rd { r[rn] = moved }
            if rd == 15 { jumpARM(value) } else { r[rd] = value }
        } else {
            var value = r[rd]
            if rd == 15 { value = value &+ 4 }
            bus.write16(addr, UInt16(truncatingIfNeeded: value))
            if writeBack { r[rn] = moved }
        }
    }

    // MARK: block transfer

    private func armBlockTransfer(_ op: UInt32) {
        let pre = op & 0x0100_0000 != 0, up = op & 0x0080_0000 != 0
        let sBit = op & 0x0040_0000 != 0, wb = op & 0x0020_0000 != 0, load = op & 0x0010_0000 != 0
        let rn = Int((op >> 16) & 0xF)
        var list = op & 0xFFFF
        let base = r[rn]
        var count = list.nonzeroBitCount
        if list == 0 { list = 0x8000; count = 16 }                  // empty list: transfers r15 and moves the base by 0x40
        let size = UInt32(count * 4)
        let newBase = up ? base &+ size : base &- size
        var addr: UInt32 = up ? (pre ? base &+ 4 : base) : (pre ? base &- size : base &- size &+ 4)
        addr &= ~3
        let hasPC = list & 0x8000 != 0
        let userBank = sBit && !(load && hasPC)
        let first = list.trailingZeroBitCount

        if load {
            if wb { r[rn] = newBase }                                 // a loaded base register overrides the writeback
            var pcValue: UInt32? = nil
            for i in 0..<16 where list & (1 << UInt32(i)) != 0 {
                let v = bus.read32(addr)
                addr &+= 4
                if i == 15 { pcValue = v } else if userBank { setUserReg(i, v) } else { r[i] = v }
            }
            bus.internalCycles(1)
            if let pc = pcValue {
                if sBit { setCPSR(spsr) }
                jumpCurrentState(pc)
            }
        } else {
            for i in 0..<16 where list & (1 << UInt32(i)) != 0 {
                var v: UInt32
                if i == 15 { v = r[15] &+ 4 }
                else if userBank { v = userReg(i) }
                else { v = r[i] }
                if i == rn && wb && i != first { v = newBase }
                bus.write32(addr, v)
                addr &+= 4
            }
            if wb { r[rn] = newBase }
        }
    }
}
