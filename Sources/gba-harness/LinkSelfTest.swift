import Foundation
import GBACore

// The link cable: GBA multi-player mode and the Game Boy serial port, between consoles on an in-memory cable.
// Hand-written programs run on the Game Boy end to end; the GBA side is driven through its registers.

func linkSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name)" + (detail.isEmpty ? "" : ": \(detail)"))
    }
    func hex(_ v: Int) -> String { String(v, radix: 16) }
    let io: UInt32 = 0x0400_0000
    let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 240 * 160); defer { fb.deallocate() }

    // --- GBA multi-player ---------------------------------------------------------------------
    var gbaRom = Data(count: 0x400)
    gbaRom.replaceSubrange(0..<4, with: [0xFE, 0xFF, 0xFF, 0xEA])            // b .
    func gbaConsoles(_ n: Int, cable: LoopbackCable) -> [GBAConsole] {
        (0..<n).map { i in
            let c = GBAConsole(rom: gbaRom)
            c.attachLink(cable.plugIn(player: i))
            return c
        }
    }
    func configure(_ c: GBAConsole, send: UInt16, baud: UInt16 = 3, irq: Bool = true) {
        let b = c.machine.bus
        b.poke16(io + 0x134, 0)                                               // RCNT: not general-purpose mode
        b.poke16(io + 0x128, 0x2000 | baud | (irq ? 0x4000 : 0))             // SIOCNT: multi-player mode
        b.poke16(io + 0x12A, send)
    }
    func cnt(_ c: GBAConsole) -> UInt16 { c.machine.bus.peek16(io + 0x128) }
    func word(_ c: GBAConsole, _ i: Int) -> UInt16 { c.machine.bus.peek16(io + 0x120 + UInt32(i * 2)) }
    func frames(_ cs: [GBAConsole], _ n: Int) { for _ in 0..<n { for c in cs { c.runFrame(framebuffer: fb) } } }
    func start(_ c: GBAConsole) { c.machine.bus.poke16(io + 0x128, cnt(c) | 0x80) }

    do {
        let cable = LoopbackCable()
        let cs = gbaConsoles(2, cable: cable)
        configure(cs[0], send: 0x1234); configure(cs[1], send: 0xABCD)
        check("parent: ID 0, SI low, SD high (cable connected)", cnt(cs[0]) & 0x3C == 0x08, hex(Int(cnt(cs[0]))))
        check("child: ID 1, SI high, SD high", cnt(cs[1]) & 0x3C == 0x1C, hex(Int(cnt(cs[1]))))
        start(cs[0])
        check("the start bit reads back as busy on the parent", cnt(cs[0]) & 0x80 != 0)
        frames(cs, 2)
        check("transfer finishes: busy clears on both", cnt(cs[0]) & 0x80 == 0 && cnt(cs[1]) & 0x80 == 0)
        check("both consoles end up with the same four words (1234, ABCD, FFFF, FFFF)",
              [0, 1].allSatisfy { word(cs[$0], 0) == 0x1234 && word(cs[$0], 1) == 0xABCD && word(cs[$0], 2) == 0xFFFF && word(cs[$0], 3) == 0xFFFF })
        check("the serial interrupt is raised on both", cs[0].machine.bus.ifl & 0x80 != 0 && cs[1].machine.bus.ifl & 0x80 != 0)

        cs[0].machine.bus.ifl = 0; cs[1].machine.bus.ifl = 0
        cs[1].machine.bus.poke16(io + 0x128, cnt(cs[1]) | 0x80)
        frames(cs, 2)
        check("a child can't start a transfer", cnt(cs[1]) & 0x80 == 0 && cs[0].machine.bus.ifl & 0x80 == 0)

        configure(cs[0], send: 0x1111, irq: false); configure(cs[1], send: 0x2222, irq: false)
        start(cs[0]); frames(cs, 2)
        check("without the interrupt-enable bit no interrupt is raised", cs[0].machine.bus.ifl & 0x80 == 0 && word(cs[1], 0) == 0x1111 && word(cs[0], 1) == 0x2222)
    }
    do {  // four consoles
        let cable = LoopbackCable()
        let cs = gbaConsoles(4, cable: cable)
        for (i, c) in cs.enumerated() { configure(c, send: UInt16(0x1111 * (i + 1))) }
        check("four consoles get IDs 0...3", cs.enumerated().allSatisfy { Int((cnt($0.element) >> 4) & 3) == $0.offset })
        start(cs[0]); frames(cs, 2)
        check("all four words reach all four consoles", cs.allSatisfy { word($0, 0) == 0x1111 && word($0, 1) == 0x2222 && word($0, 2) == 0x3333 && word($0, 3) == 0x4444 })
    }
    do {  // timing follows the baud rate
        let cable = LoopbackCable()
        let cs = gbaConsoles(2, cable: cable)
        configure(cs[0], send: 1, baud: 0); configure(cs[1], send: 2, baud: 0)       // 9600 baud: 2 consoles x 18 bits x 1748 cycles = ~63k
        start(cs[0])
        for _ in 0..<30 { for c in cs { c.machine.run(cycles: 1_000) } }
        check("at 9600 baud the transfer is still running after 30,000 cycles", cnt(cs[0]) & 0x80 != 0)
        for _ in 0..<45 { for c in cs { c.machine.run(cycles: 1_000) } }
        check("…and has finished by 75,000", cnt(cs[0]) & 0x80 == 0 && word(cs[0], 1) == 2)
        configure(cs[0], send: 3, baud: 3); configure(cs[1], send: 4, baud: 3)
        start(cs[0])
        for _ in 0..<8 { for c in cs { c.machine.run(cycles: 1_000) } }
        check("at 115200 baud it is done in about 6,000 cycles", cnt(cs[0]) & 0x80 == 0 && word(cs[1], 0) == 3)
    }
    do {  // a missing console
        let cable = LoopbackCable()
        let cs = gbaConsoles(3, cable: cable)
        for (i, c) in cs.enumerated() { configure(c, send: UInt16(i + 1)) }
        cable.unplug(player: 2)
        start(cs[0]); frames([cs[0], cs[1]], 3)
        check("an unplugged console reads 0xFFFF and the transfer still completes", cnt(cs[0]) & 0x80 == 0 && word(cs[0], 2) == 0xFFFF && word(cs[0], 1) == 2)
    }
    do {  // the parent vanishes mid-transfer: the child must not hang
        let cable = LoopbackCable()
        let cs = gbaConsoles(2, cable: cable)
        configure(cs[0], send: 1); configure(cs[1], send: 2)
        start(cs[0])
        cs[0].runFrame(framebuffer: fb)                                      // the request goes out
        cs[1].runFrame(framebuffer: fb)                                      // the child takes it and goes busy…
        cable.unplug(player: 0)                                              // …then the cable is pulled before the result comes
        frames([cs[1]], 8)
        check("a child whose parent disappears gives up with the error bit set", cnt(cs[1]) & 0x80 == 0 && cnt(cs[1]) & 0x40 != 0, hex(Int(cnt(cs[1]))))
    }
    do {  // no cable at all
        let c = GBAConsole(rom: gbaRom)
        configure(c, send: 0x5555)
        check("alone: SD is low (no partner)", cnt(c) & 0x08 == 0)
        start(c); frames([c], 2)
        check("alone: the transfer completes with only its own word", cnt(c) & 0x80 == 0 && word(c, 0) == 0x5555 && word(c, 1) == 0xFFFF)
    }
    do {  // normal mode is left alone, and registers survive a state
        let cable = LoopbackCable()
        let cs = gbaConsoles(2, cable: cable)
        cs[0].machine.bus.poke16(io + 0x128, 0x0000 | 0x80)                  // normal mode, start bit: not a multi-player transfer
        frames(cs, 1)
        check("normal mode doesn't trigger a multi-player transfer", cs[1].machine.bus.peek16(io + 0x120) == 0)
        configure(cs[0], send: 0x7777)
        guard let state = cs[0].saveState() else { return 1 }
        let fresh = GBAConsole(rom: gbaRom)
        check("a state loads", fresh.loadState(state))
        check("SIO registers survive a save state", fresh.machine.bus.peek16(io + 0x12A) == 0x7777 && fresh.machine.bus.peek16(io + 0x128) & 0x3000 == 0x2000)
    }

    // --- Game Boy serial ----------------------------------------------------------------------
    /// A ROM that sends `out`, waits for the transfer to finish, and stores what it received at C000. `master` picks the clock.
    func gbLinkROM(out: UInt8, master: Bool, delayLoops: UInt8 = 0) -> Data {
        var rom = Data(count: 0x8000)
        rom.replaceSubrange(0x100..<0x104, with: [0x00, 0xC3, 0x50, 0x01])      // nop; jp $0150
        var code: [UInt8] = []
        if delayLoops > 0 { code += [0x3E, delayLoops, 0x3D, 0x20, 0xFD] }     // ld a,n; (dec a; jr nz,-3): burn time before starting
        code += [0x3E, out, 0xE0, 0x01,                                         // ld a,out; ldh (SB),a
                 0x3E, master ? 0x81 : 0x80, 0xE0, 0x02,                        // ld a,$81/$80; ldh (SC),a
                 0xF0, 0x02, 0xCB, 0x7F, 0x20, 0xFA,                            // wait: ldh a,(SC); bit 7,a; jr nz,wait
                 0xF0, 0x01, 0xEA, 0x00, 0xC0,                                  // ldh a,(SB); ld ($C000),a
                 0x18, 0xFE]                                                    // jr $
        rom.replaceSubrange(0x150..<(0x150 + code.count), with: code)
        return rom
    }
    func gbFrames(_ cs: [GBConsole], _ n: Int) { let f = UnsafeMutablePointer<UInt32>.allocate(capacity: 160 * 144); defer { f.deallocate() }; for _ in 0..<n { for c in cs { c.runFrame(framebuffer: f) } } }
    do {
        let cable = LoopbackCable(capacity: 2)
        let a = GBConsole(rom: gbLinkROM(out: 0x42, master: true)), b = GBConsole(rom: gbLinkROM(out: 0x99, master: false))
        a.attachLink(cable.plugIn(player: 0)); b.attachLink(cable.plugIn(player: 1))
        gbFrames([a, b], 8)
        check("Game Boy link: the master receives the slave's byte (0x99)", a.peek(0xC000) == 0x99, hex(Int(a.peek(0xC000))))
        check("Game Boy link: the slave receives the master's byte (0x42)", b.peek(0xC000) == 0x42, hex(Int(b.peek(0xC000))))
        check("Game Boy link: both raise the serial interrupt flag", a.interruptFlags & 8 != 0 && b.interruptFlags & 8 != 0)
    }
    do {  // the master goes first, the slave only gets ready a few frames later
        let cable = LoopbackCable(capacity: 2)
        let a = GBConsole(rom: gbLinkROM(out: 0x11, master: true)), b = GBConsole(rom: gbLinkROM(out: 0x22, master: false, delayLoops: 250))
        a.attachLink(cable.plugIn(player: 0)); b.attachLink(cable.plugIn(player: 1))
        gbFrames([a, b], 20)
        check("Game Boy link: a slave that arms a little late still gets the byte", b.peek(0xC000) == 0x11 && a.peek(0xC000) == 0x22, "master got \(hex(Int(a.peek(0xC000)))), slave got \(hex(Int(b.peek(0xC000))))")
    }
    do {  // nobody on the other end
        let a = GBConsole(rom: gbLinkROM(out: 0x33, master: true))
        gbFrames([a], 8)
        check("Game Boy alone: the byte shifted in is 0xFF, as with no cable", a.peek(0xC000) == 0xFF)
        let cable = LoopbackCable(capacity: 2)
        let m = GBConsole(rom: gbLinkROM(out: 0x44, master: true))
        m.attachLink(cable.plugIn(player: 0))
        gbFrames([m], 20)
        check("Game Boy: a cable with nothing at the far end behaves the same", m.peek(0xC000) == 0xFF)
        let b = GBConsole(rom: gbLinkROM(out: 0x55, master: true))
        b.attachLink(cable.plugIn(player: 1))
        gbFrames([m, b], 1)
    }
    do {  // an unready slave: the master gets 0xFF after a timeout
        let cable = LoopbackCable(capacity: 2)
        let m = GBConsole(rom: gbLinkROM(out: 0x66, master: true))
        var idle = Data(count: 0x8000); idle.replaceSubrange(0x100..<0x103, with: [0x18, 0xFE, 0x00])    // never arms its port
        let s = GBConsole(rom: idle)
        m.attachLink(cable.plugIn(player: 0)); s.attachLink(cable.plugIn(player: 1))
        gbFrames([m, s], 30)
        check("Game Boy link: a slave that never arms leaves the master with 0xFF", m.peek(0xC000) == 0xFF)
    }

    print(failures == 0 ? "PASS: link cable self-check" : "FAIL: \(failures) link check(s)")
    return failures == 0 ? 0 : 1
}
