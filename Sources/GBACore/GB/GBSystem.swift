import Foundation

/// A Game Boy / Game Boy Color: CPU registers, memory map, timer, joypad, serial port and DMA, with a PPU and APU attached.
/// Time is counted in "dots" (4.19 MHz, the LCD clock). One CPU machine cycle is 4 dots, or 2 in CGB double-speed mode.
final class GBSystem {
    let cart: GBCartridge
    let isCGB: Bool
    lazy var ppu = GBPPU(system: self)
    lazy var apu = GBAPU(system: self)

    // MARK: memory
    let vram = GBSystem.alloc(0x4000)          // two 8 KB banks
    let wram = GBSystem.alloc(0x8000)          // eight 4 KB banks
    let oam = GBSystem.alloc(0xA0)
    let hram = GBSystem.alloc(0x80)            // FF80-FFFE (+ one spare byte)
    let io = GBSystem.alloc(0x80)              // raw store for registers with no behaviour of their own
    var vramBank = 0, wramBank = 1

    private static func alloc(_ n: Int) -> UnsafeMutablePointer<UInt8> {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p
    }

    // MARK: CPU registers (b, c, d, e, h, l, -, a at indices 0...7, matching the opcode encoding)
    let r = GBSystem.alloc(8)
    var f: UInt8 = 0
    var sp: UInt16 = 0xFFFE, pc: UInt16 = 0x0100
    var ime = false
    var eiPending = 0
    var halted = false
    var haltBug = false
    var stopped = false

    // MARK: time
    var dots: UInt64 = 0
    var doubleSpeed = false
    var speedSwitchArmed = false
    var nextEvent: UInt64 = 0
    var ifr: UInt8 = 0xE1
    var ie: UInt8 = 0

    // MARK: timer
    var sysCounter: UInt16 = 0xABCC
    var tima: UInt8 = 0, tma: UInt8 = 0, tac: UInt8 = 0
    var timaReload = 0                         // machine cycles until TIMA reloads from TMA after an overflow (0 = none pending)

    // MARK: joypad, serial
    var joypadSelect: UInt8 = 0x30
    var buttons: UInt8 = 0x0F, directions: UInt8 = 0x0F   // active low, as the register reports them
    var serialData: UInt8 = 0, serialControl: UInt8 = 0
    var serialCycles = 0
    /// Every byte the game has sent out of the link port (Blargg's test ROMs print their verdict this way).
    var serialLog = [UInt8]()
    /// The link cable, if one is plugged in.
    var link: SerialLink?
    fileprivate var linkAwaitingReply = false
    fileprivate var linkReply: UInt8?
    /// A byte that arrived while this console wasn't ready for it, kept for a few frames in case it gets ready.
    fileprivate var linkQueued: (byte: UInt8, expires: UInt64)?
    private var linkDeadline: UInt64 = 0
    private static let linkPatience: UInt64 = 12 * 70_224

    // MARK: DMA
    var oamDMAActive = false, oamDMAIndex = 0, oamDMASource: UInt16 = 0, oamDMAStart = 0
    var hdmaSource: UInt16 = 0, hdmaDest: UInt16 = 0
    var hdmaBlocks = 0                         // blocks left in a running HBlank DMA
    var hdmaActive = false, hdmaPending = false

    var rpRegister: UInt8 = 0, opri: UInt8 = 0

    init(cart: GBCartridge, color: Bool) {
        self.cart = cart
        isCGB = color
        for i in 0..<8 { r[i] = 0 }
        if color { r[7] = 0x11; f = 0x80; r[0] = 0; r[1] = 0; r[2] = 0xFF; r[3] = 0x56; r[4] = 0; r[5] = 0x0D; sysCounter = 0x1E00 }
        else { r[7] = 0x01; f = 0xB0; r[0] = 0; r[1] = 0x13; r[2] = 0; r[3] = 0xD8; r[4] = 0x01; r[5] = 0x4D }
        for i in 0..<0x80 { io[i] = 0xFF }
        ppu.powerOnState()
        // What the boot ROM leaves the sound chip in.
        for (a, v) in [(0x26, 0x80), (0x25, 0xF3), (0x24, 0x77), (0x10, 0x80), (0x11, 0xBF), (0x12, 0xF3), (0x14, 0xBF), (0x16, 0x3F), (0x19, 0xBF), (0x1A, 0x7F), (0x1B, 0xFF), (0x1C, 0x9F), (0x1E, 0xBF), (0x20, 0xFF), (0x23, 0xBF)] as [(Int, Int)] {
            apu.write(UInt8(a), UInt8(v))
        }
        apu.silenceChannels()
        nextEvent = ppu.nextEvent
    }

    deinit { vram.deallocate(); wram.deallocate(); oam.deallocate(); hram.deallocate(); io.deallocate(); r.deallocate() }

    // MARK: - time

    /// One CPU machine cycle: advance the timer, serial, OAM DMA and the clock, and run whatever event has come due.
    @inline(__always) func tick() {
        stepTimer()
        dots &+= doubleSpeed ? 2 : 4
        if oamDMAActive || oamDMAStart > 0 { stepOAMDMA() }
        if serialCycles > 0 { stepSerial() }
        if dots >= nextEvent { runEvents() }
    }

    func runEvents() {
        if link != nil { serviceLink() }
        ppu.advance(to: dots)
        nextEvent = ppu.nextEvent
    }

    private func stepTimer() {
        let old = sysCounter
        sysCounter &+= 4
        if timaReload > 0 {
            timaReload -= 1
            if timaReload == 0 { tima = tma; ifr |= 0x04 }
        }
        if tac & 4 != 0 {
            let mask = GBSystem.timerMask(tac)
            if old & mask != 0 && sysCounter & mask == 0 { incrementTIMA() }
        }
    }

    @inline(__always) private static func timerMask(_ tac: UInt8) -> UInt16 {
        switch tac & 3 { case 0: return 0x200; case 1: return 0x008; case 2: return 0x020; default: return 0x080 }
    }

    private func incrementTIMA() {
        if tima == 0xFF { tima = 0; timaReload = 1 } else { tima &+= 1 }
    }

    private var timerSignal: Bool { tac & 4 != 0 && sysCounter & GBSystem.timerMask(tac) != 0 }

    private func stepSerial() {
        serialCycles -= 4
        guard serialCycles <= 0 else { return }
        if linkAwaitingReply {
            if let r = linkReply { finishSerial(r) }
            else if dots >= linkDeadline { finishSerial(0xFF) }      // the other end never answered
            else { serialCycles = 4 }                                // keep waiting for its byte
            return
        }
        finishSerial(0xFF)                                           // nothing is plugged in: the line reads high
    }

    private func finishSerial(_ incoming: UInt8) {
        serialCycles = 0; linkAwaitingReply = false; linkReply = nil
        serialLog.append(serialData)
        serialData = incoming
        serialControl &= ~0x80
        ifr |= 0x08
    }

    /// A byte from the other console arrived while this one waits on an external clock: swap bytes and answer.
    private func receiveByte(_ b: UInt8) {
        let mine = serialData
        serialLog.append(mine)
        serialData = b
        serialControl &= ~0x80
        ifr |= 0x08
        link?.send(.gbReply(mine), to: nil)
    }

    /// Read what the other console has sent. Called whenever the video unit has an event, a few times per line.
    func serviceLink() {
        guard let link else { return }
        for (_, message) in link.receive() {
            switch message {
            case .gbByte(let b):
                if serialControl & 0x81 == 0x80 { receiveByte(b) } else { linkQueued = (b, dots + GBSystem.linkPatience) }
            case .gbReply(let b):
                if linkAwaitingReply { linkReply = b }
            default: break
            }
        }
        if let q = linkQueued, dots >= q.expires { linkQueued = nil; link.send(.gbReply(0xFF), to: nil) }    // nobody took it
    }

    private func stepOAMDMA() {
        if oamDMAStart > 0 {
            oamDMAStart -= 1
            if oamDMAStart == 0 { oamDMAActive = true; oamDMAIndex = 0 }
            return
        }
        let src = oamDMASource &+ UInt16(oamDMAIndex)
        oam[oamDMAIndex] = readRaw(src >= 0xE000 ? src &- 0x2000 : src)
        oamDMAIndex += 1
        if oamDMAIndex >= 0xA0 { oamDMAActive = false }
    }

    // MARK: - memory map

    /// Read without the DMA bus-conflict rule (used by the DMA engines themselves).
    func readRaw(_ a: UInt16) -> UInt8 {
        switch a >> 12 {
        case 0...7: return cart.readROM(a)
        case 8, 9: return vram[vramBank << 13 | Int(a & 0x1FFF)]
        case 0xA, 0xB: return cart.readRAM(a)
        case 0xC, 0xE: return wram[Int(a & 0xFFF)]
        case 0xD: return wram[wramBank << 12 | Int(a & 0xFFF)]
        default:
            if a < 0xFE00 { return a & 0x1000 != 0 ? wram[wramBank << 12 | Int(a & 0xFFF)] : wram[Int(a & 0xFFF)] }
            if a < 0xFEA0 { return oam[Int(a - 0xFE00)] }
            if a < 0xFF00 { return 0xFF }
            if a < 0xFF80 { return readIO(UInt8(a & 0xFF)) }
            if a == 0xFFFF { return ie }
            return hram[Int(a - 0xFF80)]
        }
    }

    @inline(__always) func read(_ a: UInt16) -> UInt8 {
        if oamDMAActive && a < 0xFF80 { return 0xFF }          // the CPU is cut off from everything but HRAM during OAM DMA
        return readRaw(a)
    }

    func write(_ a: UInt16, _ v: UInt8) {
        if oamDMAActive && a < 0xFF80 { return }
        switch a >> 12 {
        case 0...7: cart.writeROM(a, v)
        case 8, 9: vram[vramBank << 13 | Int(a & 0x1FFF)] = v
        case 0xA, 0xB: cart.writeRAM(a, v)
        case 0xC, 0xE: wram[Int(a & 0xFFF)] = v
        case 0xD: wram[wramBank << 12 | Int(a & 0xFFF)] = v
        default:
            if a < 0xFE00 { if a & 0x1000 != 0 { wram[wramBank << 12 | Int(a & 0xFFF)] = v } else { wram[Int(a & 0xFFF)] = v } }
            else if a < 0xFEA0 { oam[Int(a - 0xFE00)] = v }
            else if a < 0xFF00 { }
            else if a < 0xFF80 { writeIO(UInt8(a & 0xFF), v) }
            else if a == 0xFFFF { ie = v }
            else { hram[Int(a - 0xFF80)] = v }
        }
    }

    // MARK: - I/O registers

    func readIO(_ o: UInt8) -> UInt8 {
        switch o {
        case 0x00: return joypadValue()
        case 0x01: return serialData
        case 0x02: return serialControl | (isCGB ? 0x7C : 0x7E)
        case 0x04: return UInt8(sysCounter >> 8)
        case 0x05: return tima
        case 0x06: return tma
        case 0x07: return tac | 0xF8
        case 0x0F: return ifr | 0xE0
        case 0x10...0x3F: return apu.read(o)
        case 0x40...0x4B: return ppu.read(o)
        case 0x4D: return isCGB ? (doubleSpeed ? 0x80 : 0) | (speedSwitchArmed ? 1 : 0) | 0x7E : 0xFF
        case 0x4F: return isCGB ? UInt8(vramBank) | 0xFE : 0xFF
        case 0x55: return isCGB ? (hdmaActive ? UInt8(hdmaBlocks - 1) & 0x7F : 0xFF) : 0xFF
        case 0x56: return isCGB ? rpRegister | 0x3E : 0xFF
        case 0x68...0x6B: return isCGB ? ppu.readPalette(o) : 0xFF
        case 0x6C: return isCGB ? opri | 0xFE : 0xFF
        case 0x70: return isCGB ? UInt8(wramBank) | 0xF8 : 0xFF
        default: return io[Int(o)]
        }
    }

    func writeIO(_ o: UInt8, _ v: UInt8) {
        switch o {
        case 0x00: joypadSelect = v & 0x30; updateJoypad()
        case 0x01: serialData = v
        case 0x02:
            serialControl = v & 0x83
            if v & 0x81 == 0x81 {                                    // internal clock: 8 bits at 8192 Hz (or fast mode)
                serialCycles = isCGB && v & 2 != 0 ? 16 * 8 : 512 * 8
                if let link, link.playerCount > 1 {
                    linkAwaitingReply = true; linkReply = nil; linkDeadline = dots + GBSystem.linkPatience
                    link.send(.gbByte(serialData), to: nil)
                }
            } else if v & 0x81 == 0x80, let q = linkQueued {         // external clock, and a byte was already waiting for us
                linkQueued = nil
                receiveByte(q.byte)
            }
        case 0x04:
            let before = timerSignal
            sysCounter = 0
            if before { incrementTIMA() }
        case 0x05: tima = v; timaReload = 0                     // a write during the reload cycle wins and cancels it
        case 0x06: tma = v
        case 0x07:
            let before = timerSignal
            tac = v & 7
            if before && !timerSignal { incrementTIMA() }
        case 0x0F: ifr = v & 0x1F
        case 0x10...0x3F: apu.write(o, v)
        case 0x46:
            oamDMASource = UInt16(v) << 8; oamDMAStart = 2; oamDMAActive = false
            io[0x46] = v
        case 0x40...0x4B: ppu.write(o, v)
        case 0x4D: if isCGB { speedSwitchArmed = v & 1 != 0 }
        case 0x4F: if isCGB { vramBank = Int(v & 1) }
        case 0x51: hdmaSource = UInt16(v) << 8 | hdmaSource & 0xFF
        case 0x52: hdmaSource = hdmaSource & 0xFF00 | UInt16(v & 0xF0)
        case 0x53: hdmaDest = UInt16(v & 0x1F) << 8 | hdmaDest & 0xFF
        case 0x54: hdmaDest = hdmaDest & 0xFF00 | UInt16(v & 0xF0)
        case 0x55: if isCGB { startHDMA(v) }
        case 0x56: rpRegister = v & 0xC1
        case 0x68...0x6B: if isCGB { ppu.writePalette(o, v) }
        case 0x6C: if isCGB { opri = v & 1 }
        case 0x70: if isCGB { wramBank = max(1, Int(v & 7)) }
        default: io[Int(o)] = v
        }
    }

    // MARK: - joypad

    private func joypadValue() -> UInt8 {
        var low: UInt8 = 0x0F
        if joypadSelect & 0x10 == 0 { low &= directions }
        if joypadSelect & 0x20 == 0 { low &= buttons }
        return 0xC0 | joypadSelect | low
    }

    /// The Joypad interrupt fires when a selected line goes from high to low.
    var lastJoypadLow: UInt8 = 0x0F
    func updateJoypad() {
        let low = joypadValue() & 0x0F
        if lastJoypadLow & ~low != 0 { ifr |= 0x10 }
        lastJoypadLow = low
    }

    // MARK: - HDMA (Color only)

    private func startHDMA(_ v: UInt8) {
        let blocks = Int(v & 0x7F) + 1
        if hdmaActive && v & 0x80 == 0 { hdmaActive = false; hdmaPending = false; return }     // writing 0 stops a running HBlank transfer
        if v & 0x80 != 0 {
            hdmaActive = true; hdmaBlocks = blocks
            if ppu.inHBlank { hdmaPending = true }                                           // already in HBlank: the first block goes now
        } else {
            for _ in 0..<blocks { copyHDMABlock() }
        }
    }

    /// Copy 16 bytes, spending the machine cycles the hardware does (the CPU is halted meanwhile).
    func copyHDMABlock() {
        for i in 0..<16 {
            let v = readRaw(hdmaSource &+ UInt16(i))
            vram[vramBank << 13 | Int((hdmaDest &+ UInt16(i)) & 0x1FFF)] = v
        }
        hdmaSource &+= 16; hdmaDest = (hdmaDest &+ 16) & 0x1FFF
        for _ in 0..<(doubleSpeed ? 16 : 8) { tick() }
    }

    /// Called between instructions: run one block of a pending HBlank DMA.
    func serviceHDMA() {
        hdmaPending = false
        guard hdmaActive else { return }
        copyHDMABlock()
        hdmaBlocks -= 1
        if hdmaBlocks == 0 { hdmaActive = false }
    }

    // MARK: - input

    func setKeys(a: Bool, b: Bool, select: Bool, start: Bool, right: Bool, left: Bool, up: Bool, down: Bool) {
        buttons = 0x0F & ~((a ? 1 : 0) | (b ? 2 : 0) | (select ? 4 : 0) | (start ? 8 : 0))
        directions = 0x0F & ~((right ? 1 : 0) | (left ? 2 : 0) | (up ? 4 : 0) | (down ? 8 : 0))
        updateJoypad()
    }
}

// MARK: save states
extension GBSystem {
    func save(_ w: inout StateWriter) {
        w.tag("GBS0")
        w.raw(vram, 0x4000); w.raw(wram, 0x8000); w.raw(oam, 0xA0); w.raw(hram, 0x80); w.raw(io, 0x80)
        w.int(vramBank); w.int(wramBank)
        for i in 0..<8 { w.u8(r[i]) }
        w.u8(f); w.u16(sp); w.u16(pc); w.bool(ime); w.int(eiPending); w.bool(halted); w.bool(haltBug); w.bool(stopped)
        w.u64(dots); w.bool(doubleSpeed); w.bool(speedSwitchArmed); w.u64(nextEvent); w.u8(ifr); w.u8(ie)
        w.u16(sysCounter); w.u8(tima); w.u8(tma); w.u8(tac); w.int(timaReload)
        w.u8(joypadSelect); w.u8(buttons); w.u8(directions); w.u8(lastJoypadLow)
        w.u8(serialData); w.u8(serialControl); w.int(serialCycles)
        w.bool(oamDMAActive); w.int(oamDMAIndex); w.u16(oamDMASource); w.int(oamDMAStart)
        w.u16(hdmaSource); w.u16(hdmaDest); w.int(hdmaBlocks); w.bool(hdmaActive); w.bool(hdmaPending)
        w.u8(rpRegister); w.u8(opri)
        ppu.save(&w); apu.save(&w); cart.save(&w)
    }

    func load(_ rd: inout StateReader) {
        rd.tag("GBS0")
        rd.raw(vram, 0x4000); rd.raw(wram, 0x8000); rd.raw(oam, 0xA0); rd.raw(hram, 0x80); rd.raw(io, 0x80)
        vramBank = rd.int(); wramBank = rd.int()
        for i in 0..<8 { r[i] = rd.u8() }
        f = rd.u8(); sp = rd.u16(); pc = rd.u16(); ime = rd.bool(); eiPending = rd.int(); halted = rd.bool(); haltBug = rd.bool(); stopped = rd.bool()
        dots = rd.u64(); doubleSpeed = rd.bool(); speedSwitchArmed = rd.bool(); nextEvent = rd.u64(); ifr = rd.u8(); ie = rd.u8()
        sysCounter = rd.u16(); tima = rd.u8(); tma = rd.u8(); tac = rd.u8(); timaReload = rd.int()
        joypadSelect = rd.u8(); buttons = rd.u8(); directions = rd.u8(); lastJoypadLow = rd.u8()
        serialData = rd.u8(); serialControl = rd.u8(); serialCycles = rd.int()
        oamDMAActive = rd.bool(); oamDMAIndex = rd.int(); oamDMASource = rd.u16(); oamDMAStart = rd.int()
        hdmaSource = rd.u16(); hdmaDest = rd.u16(); hdmaBlocks = rd.int(); hdmaActive = rd.bool(); hdmaPending = rd.bool()
        rpRegister = rd.u8(); opri = rd.u8()
        ppu.load(&rd); apu.load(&rd); cart.load(&rd)
        clearLinkState()
    }

    private func clearLinkState() { linkAwaitingReply = false; linkReply = nil; linkQueued = nil }
}
