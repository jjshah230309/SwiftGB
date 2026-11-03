import Foundation
import GBACore

// Timer, DMA, LCD-event and keypad behaviour, checked against GBATEK's documented rules by driving the bus directly.

func hardwareSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ got: UInt64, _ want: UInt64) {
        let ok = got == want
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name)" + (ok ? "" : String(format: ": got %llX want %llX", got, want)))
    }
    func fresh() -> GBASystem { let g = GBASystem(); g.load(rom: Data(count: 0x200)); return g }
    func advance(_ g: GBASystem, to cycle: UInt64) { g.bus.cycles = cycle; g.bus.runEvents() }
    let io: UInt32 = 0x0400_0000

    // --- timers -------------------------------------------------------------------------------
    do {
        let g = fresh(), b = g.bus
        b.poke16(io + 0x100, 0xFFF0); b.poke16(io + 0x102, 0x00C0)       // prescaler 1, IRQ, enable
        advance(g, to: 8)
        check("timer: counts one per cycle", UInt64(b.peek16(io + 0x100)), 0xFFF8)
        check("timer: no overflow yet", UInt64(b.ifl & 8), 0)
        advance(g, to: 17)
        check("timer: overflow raises its IRQ", UInt64(b.ifl & 8), 8)
        check("timer: reloads and keeps counting", UInt64(b.peek16(io + 0x100)), 0xFFF1)
    }
    do {
        let g = fresh(), b = g.bus
        b.poke16(io + 0x100, 0); b.poke16(io + 0x102, 0x0082)             // prescaler 256
        advance(g, to: 256 * 40 + 5)
        check("timer: prescaler 256", UInt64(b.peek16(io + 0x100)), 40)
        b.poke16(io + 0x102, 0x0002)                                      // stop
        advance(g, to: 256 * 90)
        check("timer: stopping freezes the count", UInt64(b.peek16(io + 0x100)), 40)
        b.poke16(io + 0x102, 0x0083); b.poke16(io + 0x100, 0)             // (reload write while stopped does not disturb)
    }
    do {
        let g = fresh(), b = g.bus
        b.poke16(io + 0x100, 0xFFFF); b.poke16(io + 0x102, 0x0080)        // timer 0 overflows every cycle
        b.poke16(io + 0x104, 0); b.poke16(io + 0x106, 0x00C4)             // timer 1 cascades, IRQ on overflow
        advance(g, to: 50)
        check("timer: cascade counts the other timer's overflows", UInt64(b.peek16(io + 0x104)), 50)
        b.poke16(io + 0x104, 0xFFFF)                                      // reload value for the next overflow
    }
    do {
        let g = fresh(), b = g.bus
        b.poke16(io + 0x104, 0xFFFE); b.poke16(io + 0x106, 0x00C0)        // timer 1: 2 cycles to overflow, IRQ
        b.poke16(io + 0x108, 0x0000); b.poke16(io + 0x10A, 0x00C0)        // timer 2 free-running too
        advance(g, to: 3)
        check("timer 1 IRQ is IF bit 4", UInt64(b.ifl & 0x10), 0x10)
        check("timer 2 has not overflowed", UInt64(b.ifl & 0x20), 0)
    }

    // --- DMA ----------------------------------------------------------------------------------
    do {
        let g = fresh(), b = g.bus
        for i in 0..<4 { b.poke32(0x0200_0000 + UInt32(i * 4), 0x1111_1111 * UInt32(i + 1)) }
        b.poke32(io + 0xD4, 0x0200_0000); b.poke32(io + 0xD8, 0x0300_0000)
        b.poke32(io + 0xDC, 4 | 0x8400 << 16)                             // DMA3, 4 words, 32-bit, immediate
        advance(g, to: 100)
        check("dma: immediate 32-bit copy, word 0", UInt64(b.peek32(0x0300_0000)), 0x1111_1111)
        check("dma: immediate 32-bit copy, word 3", UInt64(b.peek32(0x0300_000C)), 0x4444_4444)
        check("dma: enable bit clears when done", UInt64(b.peek16(io + 0xDE) & 0x8000), 0)
    }
    do {
        let g = fresh(), b = g.bus
        for i in 0..<4 { b.poke16(0x0300_0000 + UInt32(i * 2), UInt16(0x100 + i)) }
        b.poke32(io + 0xD4, 0x0300_0000); b.poke32(io + 0xD8, 0x0300_0106)
        b.poke32(io + 0xDC, 4 | (0x8000 | 1 << 5) << 16)                  // 16-bit, destination decrements
        advance(g, to: 100)
        check("dma: decrementing destination, first unit lands highest", UInt64(b.peek16(0x0300_0106)), 0x100)
        check("dma: decrementing destination, last unit lands lowest", UInt64(b.peek16(0x0300_0100)), 0x103)
    }
    do {
        let g = fresh(), b = g.bus
        b.poke32(0x0200_0000, 0xABCD_1234)
        b.poke32(io + 0xD4, 0x0200_0000); b.poke32(io + 0xD8, 0x0300_0000)
        b.poke32(io + 0xDC, 8 | (0x8000 | 2 << 7 | 0x400) << 16)          // source fixed, 8 words
        advance(g, to: 200)
        check("dma: fixed source fills the destination", UInt64(b.peek32(0x0300_001C)), 0xABCD_1234)
    }
    do {
        let g = fresh(), b = g.bus
        b.poke16(0x0200_0000, 0x7777)
        b.poke32(io + 0xD4, 0x0200_0000); b.poke32(io + 0xD8, 0x0300_0000)
        b.poke32(io + 0xDC, 1 | (0x8000 | 1 << 12) << 16)                 // VBlank timing, 1 halfword
        advance(g, to: 100 * 1232)
        check("dma: VBlank-timed channel waits", UInt64(b.peek16(0x0300_0000)), 0)
        advance(g, to: 160 * 1232 + 4)
        check("dma: VBlank-timed channel runs at line 160", UInt64(b.peek16(0x0300_0000)), 0x7777)
    }
    do {
        let g = fresh(), b = g.bus
        for i in 0..<4 { b.poke16(0x0200_0000 + UInt32(i * 2), UInt16(0x500 + i)) }
        b.poke32(io + 0xD4, 0x0200_0000); b.poke32(io + 0xD8, 0x0300_0000)
        b.poke32(io + 0xDC, 1 | (0x8000 | 0x200 | 2 << 12 | 3 << 5 | 0x4000) << 16)   // HBlank, repeat, dest reload, IRQ
        for line in 0..<3 { advance(g, to: UInt64(line * 1232 + 1010)) }     // the CPU would visit each HBlank in turn
        check("dma: HBlank repeat moves one unit per line (3 lines)", UInt64(b.peek16(0x0300_0000)), 0x502)
        check("dma: repeating channel stays enabled", UInt64(b.peek16(io + 0xDE) & 0x8000), 0x8000)
        check("dma: completion IRQ is IF bit 11", UInt64(b.ifl & 0x800), 0x800)
    }

    // --- LCD events and keypad ----------------------------------------------------------------
    do {
        let g = fresh(), b = g.bus
        b.poke16(io + 4, 0x0008 | 0x0010 | 0x0020 | 5 << 8)               // VBlank/HBlank/VCount IRQs, VCount = 5
        advance(g, to: 5 * 1232 + 1007)
        check("lcd: HBlank IRQ", UInt64(b.ifl & 2), 2)
        check("lcd: VCount match IRQ", UInt64(b.ifl & 4), 4)
        check("lcd: no VBlank before line 160", UInt64(b.ifl & 1), 0)
        advance(g, to: 160 * 1232 + 1)
        check("lcd: VBlank IRQ at line 160", UInt64(b.ifl & 1), 1)
        check("lcd: VCOUNT reads 160", UInt64(b.peek16(io + 6)), 160)
    }
    do {
        let g = fresh(), b = g.bus
        b.poke16(io + 0x132, 0x4000 | 0x0001 | 0x0008)                    // IRQ on A or Start
        b.keyInput = 0x3FF & ~UInt16(8); b.checkKeypadIRQ()
        check("keypad: IRQ when a selected key is pressed", UInt64(b.ifl & 0x1000), 0x1000)
        let h = fresh(); h.bus.poke16(io + 0x132, 0xC000 | 0x0003)        // AND mode: A and B
        h.bus.keyInput = 0x3FF & ~UInt16(1); h.bus.checkKeypadIRQ()
        check("keypad: AND mode needs every selected key", UInt64(h.bus.ifl & 0x1000), 0)
        h.bus.keyInput = 0x3FF & ~UInt16(3); h.bus.checkKeypadIRQ()
        check("keypad: AND mode fires with all of them", UInt64(h.bus.ifl & 0x1000), 0x1000)
    }

    print(failures == 0 ? "PASS: hardware self-check" : "FAIL: \(failures) hardware check(s)")
    return failures == 0 ? 0 : 1
}
