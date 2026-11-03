import Foundation

// ARM7TDMI interpreter (ARMv4T): ARM and Thumb state, banked registers, barrel shifter, exceptions.
// Written from the architecture description; the pipeline is modelled by the "PC reads as address + 8 (ARM) / + 4 (Thumb)"
// rule rather than by simulating prefetch stages.

@inline(__always) func rotr(_ v: UInt32, _ n: UInt32) -> UInt32 {
    let n = n & 31
    return n == 0 ? v : (v >> n) | (v << (32 - n))
}

/// Barrel shifter for an immediate shift amount (the encoding where 0 means 32 for LSR/ASR and RRX for ROR).
@inline(__always) func shiftImm(_ v: UInt32, _ type: UInt32, _ amt: UInt32, _ c: UInt32) -> (UInt32, UInt32) {
    switch type {
    case 0:
        if amt == 0 { return (v, c) }
        return (v << amt, (v >> (32 - amt)) & 1)
    case 1:
        if amt == 0 { return (0, v >> 31) }
        return (v >> amt, (v >> (amt - 1)) & 1)
    case 2:
        if amt == 0 { return (UInt32(bitPattern: Int32(bitPattern: v) >> 31), v >> 31) }
        return (UInt32(bitPattern: Int32(bitPattern: v) >> Int32(amt)), (v >> (amt - 1)) & 1)
    default:
        if amt == 0 { return ((c << 31) | (v >> 1), v & 1) }          // RRX
        return (rotr(v, amt), (v >> (amt - 1)) & 1)
    }
}

/// Barrel shifter for a shift amount taken from a register (low byte; 0 leaves value and carry untouched).
@inline(__always) func shiftReg(_ v: UInt32, _ type: UInt32, _ amt: UInt32, _ c: UInt32) -> (UInt32, UInt32) {
    if amt == 0 { return (v, c) }
    switch type {
    case 0:
        if amt < 32 { return (v << amt, (v >> (32 - amt)) & 1) }
        return (0, amt == 32 ? v & 1 : 0)
    case 1:
        if amt < 32 { return (v >> amt, (v >> (amt - 1)) & 1) }
        return (0, amt == 32 ? v >> 31 : 0)
    case 2:
        if amt < 32 { return (UInt32(bitPattern: Int32(bitPattern: v) >> Int32(amt)), (v >> (amt - 1)) & 1) }
        return (UInt32(bitPattern: Int32(bitPattern: v) >> 31), v >> 31)
    default:
        let a = amt & 31
        if a == 0 { return (v, v >> 31) }
        return (rotr(v, a), (v >> (a - 1)) & 1)
    }
}

public final class ARM7TDMI {
    public let bus: Bus
    /// r0-r15 of the current mode. During execution r15 holds (address of current instruction + 8) in ARM state, (+ 4) in Thumb.
    public let r = UnsafeMutablePointer<UInt32>.allocate(capacity: 16)
    public var cpsr: UInt32 = 0x1F

    // Banked state, indexed by register group: 0 usr/sys, 1 fiq, 2 irq, 3 svc, 4 abt, 5 und
    var spsrBank = [UInt32](repeating: 0, count: 6)
    var bankSP = [UInt32](repeating: 0, count: 6)
    var bankLR = [UInt32](repeating: 0, count: 6)
    var fiqHi = [UInt32](repeating: 0, count: 5)        // r8-r12 while NOT in FIQ mode: user copies; while in FIQ: see usrHi
    var usrHi = [UInt32](repeating: 0, count: 5)

    public var halted = false
    /// While non-zero the CPU is inside IntrWait/VBlankIntrWait, waiting for one of these bits in the BIOS interrupt flags.
    var intrWaitMask: UInt16 = 0
    /// With no real BIOS image, SWI is serviced natively (see BiosHLE.swift) instead of through the exception vector.
    public var useHLEBIOS = true
    var branched = false
    var currentAddr: UInt32 = 0
    /// The two-stage prefetch queue: opcodes already fetched for the next two instructions. A write to memory after a
    /// fetch does not change them (self-modifying code only takes effect beyond the queue), and any jump empties it.
    var pipe0: UInt32 = 0
    var pipe1: UInt32 = 0
    var pipeValid = false
    public internal(set) var instructionCount: UInt64 = 0

    public init(bus: Bus) {
        self.bus = bus
        r.initialize(repeating: 0, count: 16)
    }

    deinit { r.deallocate() }

    // MARK: state helpers

    @inline(__always) static func group(_ mode: UInt32) -> Int {
        switch mode & 0x1F {
        case 0x11: return 1
        case 0x12: return 2
        case 0x13: return 3
        case 0x17: return 4
        case 0x1B: return 5
        default: return 0
        }
    }

    @inline(__always) var currentGroup: Int { ARM7TDMI.group(cpsr) }
    @inline(__always) var isThumb: Bool { cpsr & 0x20 != 0 }
    @inline(__always) var carryIn: UInt32 { (cpsr >> 29) & 1 }

    /// Write the whole CPSR, swapping register banks if the mode changed.
    func setCPSR(_ new: UInt32) {
        let old = ARM7TDMI.group(cpsr), nu = ARM7TDMI.group(new)
        if old != nu {
            bankSP[old] = r[13]; bankLR[old] = r[14]
            if old == 1 { for i in 0..<5 { fiqHi[i] = r[8 + i]; r[8 + i] = usrHi[i] } }
            if nu == 1 { for i in 0..<5 { usrHi[i] = r[8 + i]; r[8 + i] = fiqHi[i] } }
            r[13] = bankSP[nu]; r[14] = bankLR[nu]
        }
        cpsr = new
    }

    var spsr: UInt32 {
        get { let g = currentGroup; return g == 0 ? cpsr : spsrBank[g] }
        set { let g = currentGroup; if g != 0 { spsrBank[g] = newValue } }
    }

    /// Read a register as seen by user mode (for LDM/STM with the S bit).
    func userReg(_ i: Int) -> UInt32 {
        let g = currentGroup
        if g == 0 { return r[i] }
        if i >= 8 && i <= 12 { return g == 1 ? usrHi[i - 8] : r[i] }
        if i == 13 { return bankSP[0] }
        if i == 14 { return bankLR[0] }
        return r[i]
    }

    func setUserReg(_ i: Int, _ v: UInt32) {
        let g = currentGroup
        if g == 0 { r[i] = v; return }
        if i >= 8 && i <= 12 { if g == 1 { usrHi[i - 8] = v } else { r[i] = v }; return }
        if i == 13 { bankSP[0] = v; return }
        if i == 14 { bankLR[0] = v; return }
        r[i] = v
    }

    /// Put the CPU into the state a GBA is in after the BIOS boot sequence, ready to run the cartridge.
    public func resetToCartridgeEntry() {
        for i in 0..<16 { r[i] = 0 }
        bus.biosLatch = 0xE129_F000
        bankSP = [0x0300_7F00, 0x0300_7F00, 0x0300_7FA0, 0x0300_7FE0, 0x0300_7F00, 0x0300_7F00]
        bankLR = [UInt32](repeating: 0, count: 6)
        spsrBank = [UInt32](repeating: 0, count: 6)
        cpsr = 0x1F
        r[13] = bankSP[0]
        r[15] = 0x0800_0000
        halted = false
        pipeValid = false
    }

    // MARK: conditions

    @inline(__always) func condition(_ c: UInt32) -> Bool {
        let n = cpsr >> 31 & 1, z = cpsr >> 30 & 1, cf = cpsr >> 29 & 1, v = cpsr >> 28 & 1
        switch c {
        case 0x0: return z == 1
        case 0x1: return z == 0
        case 0x2: return cf == 1
        case 0x3: return cf == 0
        case 0x4: return n == 1
        case 0x5: return n == 0
        case 0x6: return v == 1
        case 0x7: return v == 0
        case 0x8: return cf == 1 && z == 0
        case 0x9: return cf == 0 || z == 1
        case 0xA: return n == v
        case 0xB: return n != v
        case 0xC: return z == 0 && n == v
        case 0xD: return z == 1 || n != v
        case 0xE: return true
        default: return false
        }
    }

    // MARK: flags / ALU

    @inline(__always) func setNZ(_ v: UInt32) {
        cpsr = (cpsr & 0x3FFF_FFFF) | (v & 0x8000_0000) | (v == 0 ? 0x4000_0000 : 0)
    }

    @inline(__always) func setCarry(_ c: UInt32) { cpsr = (cpsr & ~0x2000_0000) | (c << 29) }

    /// a + b + c, optionally setting N Z C V. Subtraction is addCore(a, ~b, carry).
    @inline(__always) func addCore(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ flags: Bool) -> UInt32 {
        let wide = UInt64(a) + UInt64(b) + UInt64(c)
        let res = UInt32(truncatingIfNeeded: wide)
        if flags {
            let carry = UInt32(truncatingIfNeeded: wide >> 32)
            let ov = ((a ^ res) & (b ^ res)) >> 31
            cpsr = (cpsr & 0x0FFF_FFFF) | (res & 0x8000_0000) | (res == 0 ? 0x4000_0000 : 0) | (carry << 29) | (ov << 28)
        }
        return res
    }

    // MARK: branching

    @inline(__always) func jumpARM(_ target: UInt32) {
        r[15] = target & ~3
        branched = true
        pipeValid = false                    // refilled (and charged) by the next step
    }

    @inline(__always) func jumpThumb(_ target: UInt32) {
        r[15] = target & ~1
        branched = true
        pipeValid = false
    }

    /// Jump after a write to r15 in whichever state the CPU is now in.
    @inline(__always) func jumpCurrentState(_ target: UInt32) {
        if isThumb { jumpThumb(target) } else { jumpARM(target) }
    }

    // MARK: exceptions

    func enterException(mode: UInt32, vector: UInt32, returnAddress: UInt32, disableFIQ: Bool) {
        let old = cpsr
        var new = (cpsr & ~0x3F) | mode | 0x80
        if disableFIQ { new |= 0x40 }
        setCPSR(new)
        spsr = old
        r[14] = returnAddress
        halted = false
        jumpARM(vector)
    }

    func enterIRQ() {
        // lr = address of the next instruction + 4, so the handler returns with SUBS PC, LR, #4
        if useHLEBIOS {
            let old = cpsr
            setCPSR((cpsr & ~0x3F) | 0x12 | 0x80)
            spsr = old
            r[14] = r[15] &+ 4
            halted = false
            // Native version of the BIOS IRQ stub: push {r0-r3, r12, lr}; r0 = 0x04000000; lr = return stub; jump to the user handler.
            var sp = r[13] &- 24
            r[13] = sp
            for reg in [0, 1, 2, 3, 12, 14] { bus.poke32(sp, r[reg]); sp &+= 4 }
            r[0] = 0x0400_0000
            r[14] = ARM7TDMI.hleIRQReturn
            bus.biosLatch = 0xE25E_F004                                  // what a BIOS read sees while a handler runs
            bus.internalCycles(6)
            jumpARM(bus.peek32(0x0300_7FFC))
        } else {
            enterException(mode: 0x12, vector: 0x18, returnAddress: r[15] &+ 4, disableFIQ: false)
        }
    }

    /// Address the native IRQ stub hands to user handlers as their return address (inside BIOS space, never really executed).
    static let hleIRQReturn: UInt32 = 0x0000_0138

    /// The tail of the BIOS IRQ stub: pop the saved registers and return from the exception.
    func hleIRQReturnStub() {
        var sp = r[13]
        for reg in [0, 1, 2, 3, 12, 14] { r[reg] = bus.peek32(sp); sp &+= 4 }
        r[13] = sp
        bus.biosLatch = 0xE55E_C002
        bus.internalCycles(6)
        let target = r[14] &- 4
        setCPSR(spsr)
        jumpCurrentState(target)
    }

    func enterUndefined(returnAddress: UInt32) {
        enterException(mode: 0x1B, vector: 0x04, returnAddress: returnAddress, disableFIQ: false)
    }

    func enterSWI(returnAddress: UInt32) {
        enterException(mode: 0x13, vector: 0x08, returnAddress: returnAddress, disableFIQ: false)
    }

    // MARK: stepping

    /// Execute one instruction (or take one interrupt). Returns bus cycles consumed.
    @discardableResult
    public func step() -> Int {
        let start = bus.cycles
        if intrWaitMask != 0 && cpsr & 0x1F != 0x12 {                  // (the IRQ handler itself must run normally)
            let flags = bus.peek16(0x0300_7FF8)
            if flags & intrWaitMask != 0 { bus.poke16(0x0300_7FF8, flags & ~intrWaitMask); intrWaitMask = 0 }
            else { halted = true }
        }
        if halted {
            if bus.ie & bus.ifl != 0 { halted = false }
            else {                                                    // sleep until the next LCD event instead of burning steps
                bus.cycles = max(bus.cycles &+ 1, bus.nextEvent)
                bus.runEvents()
                return Int(bus.cycles - start)
            }
        }
        if bus.haltRequested { bus.haltRequested = false; halted = true; bus.internalCycles(1); return 1 }
        if cpsr & 0x80 == 0 && bus.irqPending {
            enterIRQ()
            if bus.cycles >= bus.nextEvent { bus.runEvents() }
            return Int(bus.cycles - start)
        }
        if intrWaitMask != 0 && cpsr & 0x1F != 0x12 {                  // woke but cannot take the interrupt yet: keep waiting
            bus.internalCycles(1)
            if bus.cycles >= bus.nextEvent { bus.runEvents() }
            return Int(bus.cycles - start)
        }
        instructionCount &+= 1
        if cpsr & 0x20 == 0 { stepARM() } else { stepThumb() }
        if bus.cycles >= bus.nextEvent { bus.runEvents() }
        return Int(bus.cycles - start)
    }

    @inline(__always) private func stepARM() {
        let addr = r[15]
        currentAddr = addr
        if useHLEBIOS && addr == ARM7TDMI.hleIRQReturn { hleIRQReturnStub(); return }
        bus.cpuPC = addr
        if !pipeValid { pipe0 = bus.read32(addr); pipe1 = bus.read32(addr &+ 4); pipeValid = true }
        let op = pipe0
        pipe0 = pipe1
        pipe1 = bus.read32(addr &+ 8)         // the fetch that overlaps this instruction's execution
        bus.openBus = pipe1
        r[15] = addr &+ 8
        branched = false
        let cond = op >> 28
        if cond != 0xE && !condition(cond) {
            r[15] = addr &+ 4
            return
        }
        execARM(op)
        if !branched { r[15] = addr &+ 4 }
    }

    @inline(__always) private func stepThumb() {
        let addr = r[15]
        currentAddr = addr
        bus.cpuPC = addr
        if !pipeValid { pipe0 = UInt32(bus.read16(addr)); pipe1 = UInt32(bus.read16(addr &+ 2)); pipeValid = true }
        let op = pipe0
        pipe0 = pipe1
        pipe1 = UInt32(bus.read16(addr &+ 4))
        bus.openBus = pipe1 | (pipe1 << 16)
        r[15] = addr &+ 4
        branched = false
        execThumb(op)
        if !branched { r[15] = addr &+ 2 }
    }
}

// MARK: save states
extension ARM7TDMI {
    func save(_ w: inout StateWriter) {
        w.tag("CPU0")
        for i in 0..<16 { w.u32(r[i]) }
        w.u32(cpsr); w.u32s(spsrBank); w.u32s(bankSP); w.u32s(bankLR); w.u32s(fiqHi); w.u32s(usrHi)
        w.bool(halted); w.u16(intrWaitMask); w.bool(branched); w.u32(currentAddr)
        w.u32(pipe0); w.u32(pipe1); w.bool(pipeValid); w.u64(instructionCount)
    }

    func load(_ rd: inout StateReader) {
        rd.tag("CPU0")
        for i in 0..<16 { r[i] = rd.u32() }
        cpsr = rd.u32(); rd.u32s(&spsrBank); rd.u32s(&bankSP); rd.u32s(&bankLR); rd.u32s(&fiqHi); rd.u32s(&usrHi)
        halted = rd.bool(); intrWaitMask = rd.u16(); branched = rd.bool(); currentAddr = rd.u32()
        pipe0 = rd.u32(); pipe1 = rd.u32(); pipeValid = rd.bool(); instructionCount = rd.u64()
    }
}
