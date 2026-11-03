import Foundation
import GBACore

// BIOS data services, interrupt waiting, and cartridge hardware (EEPROM, Flash ID mode, real-time clock),
// checked with hand-built inputs whose results are worked out from the documented formats.

func servicesSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name)" + (detail.isEmpty ? "" : ": \(detail)"))
    }
    func hex(_ v: UInt32) -> String { String(v, radix: 16) }
    func make(romTag: String? = nil, size: Int = 0x1000) -> GBASystem {
        var rom = Data(count: size)
        if let tag = romTag { rom.replaceSubrange(0x100..<(0x100 + tag.utf8.count), with: Array(tag.utf8)) }
        let g = GBASystem(); g.load(rom: rom); return g
    }
    func putBytes(_ g: GBASystem, _ a: UInt32, _ bytes: [UInt8]) { for (i, b) in bytes.enumerated() { g.bus.poke8(a + UInt32(i), b) } }
    func getBytes(_ g: GBASystem, _ a: UInt32, _ n: Int) -> [UInt8] { (0..<n).map { g.bus.peek8(a + UInt32($0)) } }
    let io: UInt32 = 0x0400_0000

    // --- decompression and unpacking ---------------------------------------------------------
    do {
        let g = make()
        // "ABCABCABCABC": three literals, then one back-reference (length 9, distance 3)
        putBytes(g, 0x0200_0000, [0x10, 12, 0, 0, 0x10, 0x41, 0x42, 0x43, 0x60, 0x02])
        _ = g.callBIOS(0x11, r0: 0x0200_0000, r1: 0x0200_0100)
        check("LZ77 (WRAM) overlapping back-reference", getBytes(g, 0x0200_0100, 12) == Array("ABCABCABCABC".utf8))
        _ = g.callBIOS(0x12, r0: 0x0200_0000, r1: 0x0600_0000)
        check("LZ77 (VRAM) writes the same bytes", getBytes(g, 0x0600_0000, 12) == Array("ABCABCABCABC".utf8))
    }
    do {
        let g = make()
        putBytes(g, 0x0200_0000, [0x30, 9, 0, 0, 0x82, 0x58, 0x03, 0x61, 0x62, 0x63, 0x64])    // 5 x 'X', then literal "abcd"
        _ = g.callBIOS(0x14, r0: 0x0200_0000, r1: 0x0200_0100)
        check("run-length decode", getBytes(g, 0x0200_0100, 9) == Array("XXXXXabcd".utf8))
    }
    do {
        let g = make()
        // two-leaf tree: root 0xC0 (both children are data), leaves 'A' and 'B'; bits 0,1,1,1 -> "ABBB"
        putBytes(g, 0x0200_0000, [0x28, 4, 0, 0,  1, 0xC0, 0x41, 0x42,  0, 0, 0, 0x70])
        _ = g.callBIOS(0x13, r0: 0x0200_0000, r1: 0x0200_0100)
        check("Huffman decode", getBytes(g, 0x0200_0100, 4) == Array("ABBB".utf8), "\(getBytes(g, 0x0200_0100, 4))")
    }
    do {
        let g = make()
        putBytes(g, 0x0200_0000, [0b1011_0001])
        putBytes(g, 0x0200_0010, [1, 0, 1, 4, 0, 0, 0, 0])                      // 1 source byte, 1-bit units -> 4-bit units, no offset
        _ = g.callBIOS(0x10, r0: 0x0200_0000, r1: 0x0200_0100, r2: 0x0200_0010)
        check("BitUnPack 1bpp -> 4bpp", g.bus.peek32(0x0200_0100) == 0x1011_0001, hex(g.bus.peek32(0x0200_0100)))
        putBytes(g, 0x0200_0010, [1, 0, 1, 4, 1, 0, 0, 0x80])                   // offset 1, applied to zeros too
        _ = g.callBIOS(0x10, r0: 0x0200_0000, r1: 0x0200_0100, r2: 0x0200_0010)
        check("BitUnPack with offset and zero flag", g.bus.peek32(0x0200_0100) == 0x2122_1112, hex(g.bus.peek32(0x0200_0100)))
    }
    do {
        let g = make()
        putBytes(g, 0x0200_0000, [0x81, 4, 0, 0, 10, 5, 5, 5])
        _ = g.callBIOS(0x16, r0: 0x0200_0000, r1: 0x0200_0100)
        check("Diff 8-bit unfilter", getBytes(g, 0x0200_0100, 4) == [10, 15, 20, 25])
    }

    // --- affine set-up ----------------------------------------------------------------------
    do {
        let g = make()
        let b = g.bus
        func half(_ a: UInt32) -> Int { Int(Int16(truncatingIfNeeded: b.peek16(a))) }
        b.poke16(0x0200_0000, 0x100); b.poke16(0x0200_0002, 0x100); b.poke16(0x0200_0004, 0)
        _ = g.callBIOS(0x0F, r0: 0x0200_0000, r1: 0x0200_0100, r2: 1, r3: 2)
        check("ObjAffineSet identity", [half(0x0200_0100), half(0x0200_0102), half(0x0200_0104), half(0x0200_0106)] == [0x100, 0, 0, 0x100])
        b.poke16(0x0200_0004, 0x4000)                                           // 90 degrees
        _ = g.callBIOS(0x0F, r0: 0x0200_0000, r1: 0x0200_0100, r2: 1, r3: 2)
        check("ObjAffineSet 90 degrees", [half(0x0200_0100), half(0x0200_0102), half(0x0200_0104), half(0x0200_0106)] == [0, -0x100, 0x100, 0], "\([half(0x0200_0100), half(0x0200_0102), half(0x0200_0104), half(0x0200_0106)])")
        b.poke32(0x0200_0200, 120 << 8); b.poke32(0x0200_0204, 80 << 8)         // texture centre
        b.poke16(0x0200_0208, 120); b.poke16(0x0200_020A, 80)                   // display centre
        b.poke16(0x0200_020C, 0x100); b.poke16(0x0200_020E, 0x100); b.poke16(0x0200_0210, 0)
        _ = g.callBIOS(0x0E, r0: 0x0200_0200, r1: 0x0200_0300, r2: 1)
        check("BgAffineSet identity maps the centres onto each other", half(0x0200_0300) == 0x100 && half(0x0200_0306) == 0x100 && b.peek32(0x0200_0308) == 0 && b.peek32(0x0200_030C) == 0)
    }

    // --- resets -------------------------------------------------------------------------------
    do {
        let g = make()
        let b = g.bus
        b.poke32(0x0200_0040, 0xAAAA_AAAA); b.poke32(0x0500_0010, 0xBBBB_BBBB)
        _ = g.callBIOS(0x01, r0: 0x01)
        check("RegisterRamReset clears only what was asked", b.peek32(0x0200_0040) == 0 && b.peek32(0x0500_0010) == 0xBBBB_BBBB)
        _ = g.callBIOS(0x01, r0: 0x04)
        check("RegisterRamReset can clear palette", b.peek32(0x0500_0010) == 0)
        b.poke8(0x0300_7FFA, 1)
        _ = g.callBIOS(0x00)
        check("SoftReset honours the return-to-RAM flag", g.cpu.r[15] == 0x0200_0000, hex(g.cpu.r[15]))
    }

    // --- IntrWait with a real handler ---------------------------------------------------------
    do {
        let g = make()
        let b = g.bus
        let program: [UInt32] = [
            0xE3A0_0301, 0xE3A0_1008, 0xE1C0_10B4,                          // DISPSTAT: VBlank IRQ on
            0xE3A0_1001, 0xE280_0C02, 0xE1C0_10B0, 0xE1C0_10B8,             // IE = 1, IME = 1
            0xE3A0_2403, 0xE3A0_3402, 0xE283_3C01, 0xE282_2C7F, 0xE282_20FC, 0xE582_3000,   // [0x03007FFC] = handler
            0xEF05_0000,                                                    // VBlankIntrWait
            0xE3A0_A001, 0xEAFF_FFFE,                                       // r10 = 1; spin
        ]
        for (i, w) in program.enumerated() { b.poke32(0x0200_0000 + UInt32(i * 4), w) }
        let handler: [UInt32] = [
            0xE3A0_2403, 0xE282_2C7F, 0xE282_20F8, 0xE1D2_30B0, 0xE383_3001, 0xE1C2_30B0,    // BIOS flags |= 1
            0xE3A0_4301, 0xE284_4C02, 0xE3A0_5001, 0xE1C4_50B2,                              // acknowledge IF
            0xE12F_FF1E,                                                                     // bx lr
        ]
        for (i, w) in handler.enumerated() { b.poke32(0x0200_0100 + UInt32(i * 4), w) }
        g.cpu.r[15] = 0x0200_0000
        var steps = 0
        while g.cpu.r[10] != 1 && b.cycles < 600_000 && steps < 5_000_000 { g.cpu.step(); steps += 1 }
        check("VBlankIntrWait returns only after a real VBlank", g.cpu.r[10] == 1 && b.cycles >= 160 * 1232, "r10=\(g.cpu.r[10]) cycles=\(b.cycles)")
        check("VBlankIntrWait consumes the flag", b.peek16(0x0300_7FF8) & 1 == 0)
        check("the wait slept instead of spinning", steps < 2000, "\(steps) steps")
    }

    // --- Flash identification -----------------------------------------------------------------
    do {
        let g = make(romTag: "FLASH_V123"), b = g.bus
        b.poke8(0x0E00_5555, 0xAA); b.poke8(0x0E00_2AAA, 0x55); b.poke8(0x0E00_5555, 0x90)
        check("Flash ID mode reports a 64K chip", b.peek8(0x0E00_0000) == 0x32 && b.peek8(0x0E00_0001) == 0x1B)
        b.poke8(0x0E00_5555, 0xAA); b.poke8(0x0E00_2AAA, 0x55); b.poke8(0x0E00_5555, 0xF0)
        check("Flash leaves ID mode", b.peek8(0x0E00_0000) == 0xFF)
        let h = make(romTag: "FLASH1M_V102"), c = h.bus
        c.poke8(0x0E00_5555, 0xAA); c.poke8(0x0E00_2AAA, 0x55); c.poke8(0x0E00_5555, 0x90)
        check("Flash 1M reports a 128K chip", c.peek8(0x0E00_0000) == 0x62 && c.peek8(0x0E00_0001) == 0x13)
    }

    // --- EEPROM through DMA3 ------------------------------------------------------------------
    func eepromRoundTrip(addressBits: Int, tag: String) {
        let g = make(romTag: tag), b = g.bus
        let sizeName = addressBits == 6 ? "512 B" : "8 KB"
        func bits(_ v: UInt64, _ n: Int) -> [UInt16] { (0..<n).map { UInt16((v >> UInt64(n - 1 - $0)) & 1) } }
        func dma(src: UInt32, dst: UInt32, count: Int) {
            b.poke32(io + 0xD4, src); b.poke32(io + 0xD8, dst)
            b.poke32(io + 0xDC, UInt32(count) | UInt32(0x8000) << 16)
            b.cycles += 100_000; b.runEvents()
        }
        let block = 5
        let payload: UInt64 = 0x0123_4567_89AB_CDEF
        let write = [1, 0].map { UInt16($0) } + bits(UInt64(block), addressBits) + bits(payload, 64) + [0]
        for (i, v) in write.enumerated() { b.poke16(0x0200_0000 + UInt32(i * 2), v) }
        dma(src: 0x0200_0000, dst: 0x0D00_0000, count: write.count)
        let request = [1, 1].map { UInt16($0) } + bits(UInt64(block), addressBits) + [0]
        for (i, v) in request.enumerated() { b.poke16(0x0200_1000 + UInt32(i * 2), v) }
        dma(src: 0x0200_1000, dst: 0x0D00_0000, count: request.count)
        dma(src: 0x0D00_0000, dst: 0x0200_2000, count: 68)
        var got: UInt64 = 0
        for i in 4..<68 { got = got << 1 | UInt64(b.peek16(0x0200_2000 + UInt32(i * 2)) & 1) }
        check("EEPROM \(sizeName): write then read back a block", got == payload, hex(UInt32(truncatingIfNeeded: got)))
        check("EEPROM \(sizeName): first four read bits are zero", (0..<4).allSatisfy { b.peek16(0x0200_2000 + UInt32($0 * 2)) & 1 == 0 })
        let save = b.cart.saveData()
        check("EEPROM \(sizeName): save file has the right size", save?.count == (addressBits == 6 ? 512 : 8192), "\(save?.count ?? -1)")
        check("EEPROM \(sizeName): save bytes hold the block", save.map { Array($0[(block * 8)..<(block * 8 + 8)]) } == [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
        check("EEPROM \(sizeName): marks the save dirty once", b.cart.takeSave() != nil && b.cart.takeSave() == nil)
    }
    eepromRoundTrip(addressBits: 6, tag: "EEPROM_V124")
    eepromRoundTrip(addressBits: 14, tag: "EEPROM_V124")

    // --- save file round trip -----------------------------------------------------------------
    do {
        let g = make(romTag: "SRAM_V113"), b = g.bus
        b.poke8(0x0E00_0010, 0x42)
        let save = b.cart.takeSave()
        let h = make(romTag: "SRAM_V113")
        if let save { h.bus.cart.loadSave(save) }
        check("SRAM save file survives a reload", save?.count == 0x8000 && h.bus.peek8(0x0E00_0010) == 0x42)
    }

    // --- real-time clock ----------------------------------------------------------------------
    do {
        let g = make(romTag: "SIIRTC_V001"), b = g.bus
        func pins(_ v: UInt16) { b.poke16(0x0800_00C4, v) }
        func sendByte(_ byte: UInt8) {
            for i in 0..<8 {
                let sio = UInt16((byte >> UInt8(i)) & 1) << 1
                pins(4 | sio); pins(4 | sio | 1)
            }
        }
        func readByte() -> UInt8 {
            var v: UInt8 = 0
            for i in 0..<8 {
                pins(4); pins(4 | 1)
                v |= UInt8((b.peek16(0x0800_00C4) >> 1) & 1) << UInt8(i)
            }
            return v
        }
        func begin() { b.poke16(0x0800_00C6, 7); pins(1); pins(5) }          // all pins output; CS rises with SCK high
        func end() { pins(1); pins(0) }
        b.poke16(0x0800_00C8, 1); b.poke16(0x0800_00C6, 7)
        begin(); sendByte(0x16); sendByte(0x40); end()                       // status: 24-hour mode
        begin(); sendByte(0x26)                                              // write date/time
        for byte: UInt8 in [0x31, 0x03, 0x14, 0x05, 0x13, 0x45, 0x30] { sendByte(byte) }
        end()
        begin(); sendByte(0xA6)                                              // read date/time
        b.poke16(0x0800_00C6, 5)                                             // SIO becomes an input
        let back = (0..<7).map { _ in readByte() }
        end()
        check("RTC: date and weekday read back as written", Array(back[0..<4]) == [0x31, 0x03, 0x14, 0x05], "\(back.map { String($0, radix: 16) })")
        check("RTC: time reads back and keeps running", back[4] == 0x13 && back[5] == 0x45 && back[6] >= 0x30 && back[6] <= 0x33, "\(back.map { String($0, radix: 16) })")
        b.poke16(0x0800_00C8, 0)
        check("RTC: reads fall through to the ROM when disabled", b.peek16(0x0800_00C4) == 0)
    }

    print(failures == 0 ? "PASS: BIOS services and cartridge self-check" : "FAIL: \(failures) check(s)")
    return failures == 0 ? 0 : 1
}
