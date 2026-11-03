import Foundation
import GBACore

// Game Boy hardware checks that the public test ROMs don't cover: mapper chips, the cartridge clock, timers, DMA, joypad,
// sprites, colour palettes, sound pitch and save states. Built from hand-made ROMs and values worked out from the documentation.

func gbSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name)" + (detail.isEmpty ? "" : ": \(detail)"))
    }
    func hex(_ v: Int) -> String { String(v, radix: 16) }

    /// A ROM of `banks` 16 KB banks whose first byte of each bank is the bank number, spinning in `jr $` at the entry point.
    func makeROM(type: UInt8 = 0, banks: Int = 2, ramCode: UInt8 = 0, cgb: UInt8 = 0, title: String = "TEST") -> Data {
        var d = Data(count: banks * 0x4000)
        for b in 0..<banks { d[b * 0x4000 + 0x3FFF] = UInt8(truncatingIfNeeded: b); if b > 0 { d[b * 0x4000] = UInt8(truncatingIfNeeded: b) } }
        d[0x100] = 0x18; d[0x101] = 0xFE                              // jr $
        for (i, c) in title.utf8.enumerated() where i < 11 { d[0x134 + i] = c }
        d[0x143] = cgb; d[0x147] = type; d[0x149] = ramCode
        var bankCode: UInt8 = 0
        var n = 2; while n < banks { n *= 2; bankCode += 1 }
        _ = bankCode
        return d
    }
    func console(_ rom: Data) -> GBConsole { GBConsole(rom: rom) }

    // --- mappers --------------------------------------------------------------------------------
    do {
        let c = console(makeROM(type: 0x01, banks: 64))
        c.poke(0x2000, 5)
        check("MBC1: ROM bank 5 at 4000", c.peek(0x4000) == 5)
        c.poke(0x2000, 0)
        check("MBC1: bank 0 selects bank 1", c.peek(0x4000) == 1)
        c.poke(0x4000, 1); c.poke(0x2000, 2)
        check("MBC1: upper bits come from the second register (bank 0x22)", c.peek(0x4000) == 0x22)
        c.poke(0x6000, 1)
        check("MBC1: mode 1 also remaps the lower window (bank 0x20)", c.peek(0x0000) == 0x20, hex(Int(c.peek(0x0000))))
    }
    do {
        let c = console(makeROM(type: 0x03, banks: 4, ramCode: 3))
        c.poke(0xA000, 0x77)
        check("MBC1: RAM is disabled until enabled", c.peek(0xA000) == 0xFF)
        c.poke(0x0000, 0x0A); c.poke(0xA000, 0x77)
        check("MBC1: RAM works once enabled", c.peek(0xA000) == 0x77)
        c.poke(0x6000, 1); c.poke(0x4000, 2); c.poke(0xA000, 0x33)
        c.poke(0x4000, 0)
        check("MBC1: RAM banks are separate in mode 1", c.peek(0xA000) == 0x77)
        check("MBC1: battery save is reported", c.takeSaveIfChanged() != nil)
    }
    do {
        let c = console(makeROM(type: 0x05, banks: 16))
        c.poke(0x0000, 0x0A)
        c.poke(0xA005, 0xAB)
        check("MBC2: 4-bit RAM keeps only the low nibble", c.peek(0xA005) == 0xFB, hex(Int(c.peek(0xA005))))
        check("MBC2: RAM mirrors every 512 bytes", c.peek(0xA205) == 0xFB)
        c.poke(0x2100, 7)
        check("MBC2: ROM bank register needs address bit 8", c.peek(0x4000) == 7)
        c.poke(0x2000, 3)                                            // bit 8 clear: that's the RAM-enable register, not a bank
        check("MBC2: …and the other address doesn't change the bank", c.peek(0x4000) == 7)
    }
    do {
        let c = console(makeROM(type: 0x1B, banks: 512, ramCode: 4))
        c.poke(0x2000, 0x34); c.poke(0x3000, 1)
        check("MBC5: nine-bit ROM bank (0x134)", c.peek(0x4000) == UInt8(truncatingIfNeeded: 0x134))
        c.poke(0x2000, 0)
        c.poke(0x0000, 0x0A); c.poke(0x4000, 3); c.poke(0xA000, 0x5C); c.poke(0x4000, 4); c.poke(0xA000, 0x6D); c.poke(0x4000, 3)
        check("MBC5: 16 RAM banks", c.peek(0xA000) == 0x5C)
    }
    do {  // MBC3 with the real-time clock
        let c = console(makeROM(type: 0x10, banks: 8, ramCode: 3))
        c.poke(0x0000, 0x0A)
        c.poke(0x4000, 0x08); c.poke(0xA000, 42)                    // seconds = 42
        c.poke(0x4000, 0x09); c.poke(0xA000, 7)                     // minutes
        c.poke(0x4000, 0x0A); c.poke(0xA000, 5)                     // hours
        c.poke(0x4000, 0x0B); c.poke(0xA000, 9)                     // day
        c.poke(0x6000, 0); c.poke(0x6000, 1)
        c.poke(0x4000, 0x09)
        check("MBC3: clock minutes read back after a latch", c.peek(0xA000) == 7)
        c.poke(0x4000, 0x0A)
        check("MBC3: clock hours", c.peek(0xA000) == 5)
        c.poke(0x4000, 0x0B)
        check("MBC3: clock day", c.peek(0xA000) == 9)
        c.poke(0x4000, 0x00); c.poke(0xA000, 0x66)
        check("MBC3: RAM and the clock share the window", c.peek(0xA000) == 0x66)
        let save = c.takeSaveIfChanged()
        check("MBC3: save file holds RAM plus the clock", save?.count == 0x8000 + 13, "\(save?.count ?? 0)")
        let d = console(makeROM(type: 0x10, banks: 8, ramCode: 3))
        if let save { d.loadSave(save) }
        d.poke(0x0000, 0x0A); d.poke(0x6000, 0); d.poke(0x6000, 1); d.poke(0x4000, 0x0A)
        check("MBC3: the clock survives a save and reload", d.peek(0xA000) == 5)
    }
    do {
        let c = console(makeROM(type: 0xFC, banks: 2))
        check("an unsupported mapper is reported, not silently run", c.statusNote?.contains("isn't supported") == true)
    }

    // --- timer ----------------------------------------------------------------------------------
    do {
        let c = console(makeROM())
        c.poke(0xFF07, 0x05)                                          // enabled, 262144 Hz: one count per 16 clocks = 4 machine cycles
        c.poke(0xFF05, 0)
        c.idle(40)
        check("timer: TIMA counts every 4 machine cycles at 262144 Hz", c.peek(0xFF05) == 10, "\(c.peek(0xFF05))")
        let d0 = c.peek(0xFF04)
        c.idle(64)
        check("timer: DIV counts every 64 machine cycles", c.peek(0xFF04) == d0 &+ 1)
        c.poke(0xFF04, 0)
        check("timer: writing DIV resets it", c.peek(0xFF04) == 0)
        c.poke(0xFF06, 0xAB); c.poke(0xFF05, 0xFF); c.clearInterruptFlags()
        c.idle(4)
        check("timer: overflow itself shows 00 until the reload cycle", c.peek(0xFF05) == 0x00 && c.interruptFlags & 4 == 0)
        c.idle(1)
        check("timer: overflow reads 00 for a cycle, then reloads from TMA with the interrupt", c.peek(0xFF05) == 0xAB && c.interruptFlags & 4 != 0, "tima=\(hex(Int(c.peek(0xFF05)))) if=\(c.interruptFlags)")
        c.poke(0xFF07, 0x00); let t = c.peek(0xFF05); c.idle(100)
        check("timer: disabled timer holds", c.peek(0xFF05) == t)
    }

    // --- joypad ---------------------------------------------------------------------------------
    do {
        let c = console(makeROM())
        c.poke(0xFF00, 0x20)                                          // select directions
        check("joypad: nothing pressed reads high", c.peek(0xFF00) & 0x0F == 0x0F)
        c.clearInterruptFlags()
        c.setKeys([.right, .a])
        check("joypad: directions line shows Right as 0", c.peek(0xFF00) & 0x0F == 0x0E)
        check("joypad: a selected line going low raises the interrupt", c.interruptFlags & 0x10 != 0)
        c.poke(0xFF00, 0x10)
        check("joypad: buttons line shows A as 0", c.peek(0xFF00) & 0x0F == 0x0E)
        c.poke(0xFF00, 0x30)
        check("joypad: nothing selected reads high", c.peek(0xFF00) & 0x0F == 0x0F)
    }

    // --- OAM DMA --------------------------------------------------------------------------------
    do {
        let c = console(makeROM())
        for i in 0..<0xA0 { c.poke(0xC000 + UInt16(i), UInt8(i ^ 0x5A)) }
        c.poke(0xFF46, 0xC0)
        c.idle(170)
        var same = true
        for i in 0..<0xA0 where c.peek(0xFE00 + UInt16(i)) != UInt8(i ^ 0x5A) { same = false }
        check("OAM DMA: 160 bytes copied into OAM", same)
    }

    // --- video: BG, window, sprites ---------------------------------------------------------------
    func frame(_ c: GBConsole) { let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 160 * 144); c.runFrame(framebuffer: fb); c.runFrame(framebuffer: fb); fb.deallocate() }
    func solidTile(_ c: GBConsole, _ addr: UInt16, _ idx: Int) { for row in 0..<8 { c.poke(addr + UInt16(row * 2), idx & 1 != 0 ? 0xFF : 0); c.poke(addr + UInt16(row * 2) + 1, idx & 2 != 0 ? 0xFF : 0) } }
    do {
        let c = console(makeROM())
        c.poke(0xFF40, 0x00)                                          // LCD off while we set up
        solidTile(c, 0x8010, 3)                                       // tile 1: colour 3
        c.poke(0x9800, 1)                                             // map (0,0) = tile 1
        c.poke(0xFF47, 0xE4)                                          // identity palette
        for i in 0..<16 { c.poke(0x8000 + UInt16(i), 0) }
        c.poke(0xFF40, 0x91)
        frame(c)
        let s = c.shadeIndices()
        check("BG: tile at the top-left, colour 3 → shade 3", s[0] == 3 && s[7] == 3 && s[7 * 160] == 3)
        check("BG: the rest is colour 0", s[8] == 0 && s[8 * 160] == 0)
        c.poke(0xFF47, 0x1B)                                          // reversed palette
        frame(c)
        check("BG: palette reverses the shades", c.shadeIndices()[0] == 0 && c.shadeIndices()[8] == 3)
        c.poke(0xFF43, 4); frame(c)
        check("BG: SCX scrolls the picture", c.shadeIndices()[0] == 0 && c.shadeIndices()[3] == 0 && c.shadeIndices()[4] == 3)
        c.poke(0xFF43, 0)
    }
    do {
        let c = console(makeROM())
        c.poke(0xFF40, 0x00)
        solidTile(c, 0x8010, 1); solidTile(c, 0x8020, 2); solidTile(c, 0x8030, 3)
        c.poke(0xFF47, 0xE4); c.poke(0xFF48, 0xE4); c.poke(0xFF49, 0xE4)
        // BG tile 1 (colour 1) everywhere on row 0 of the map so sprites can sit over/under it
        for x in 0..<32 { c.poke(0x9800 + UInt16(x), 1) }
        for i in 0..<160 { c.poke(0xFE00 + UInt16(i), 0) }
        c.poke(0xFE00, 16 + 0); c.poke(0xFE01, 8 + 20); c.poke(0xFE02, 3); c.poke(0xFE03, 0)       // sprite 0: colour 3 at x=20
        c.poke(0xFE04, 16 + 0); c.poke(0xFE05, 8 + 20); c.poke(0xFE06, 2); c.poke(0xFE07, 0)       // sprite 1: same spot, colour 2
        c.poke(0xFE08, 16 + 0); c.poke(0xFE09, 8 + 40); c.poke(0xFE0A, 3); c.poke(0xFE0B, 0x80)    // sprite 2 behind BG colour 1+
        c.poke(0xFE0C, 16 + 0); c.poke(0xFE0D, 8 + 60); c.poke(0xFE0E, 3); c.poke(0xFE0F, 0x10)    // sprite 3 via OBP1
        c.poke(0xFF49, 0x1B)
        c.poke(0xFF40, 0x93)
        frame(c)
        let s = c.shadeIndices()
        check("sprites: same x, lower OAM index wins", s[20] == 3)
        check("sprites: pixels beside the sprite stay BG", s[19] == 1 && s[28] == 1)
        check("sprites: behind-BG flag hides the sprite over BG colours 1-3", s[40] == 1)
        check("sprites: OBP1 is used when attribute bit 4 is set", s[60] == 0, "shade \(s[60])")
        check("sprites: only 8 rows tall", s[8 * 160 + 20] == 0)
        c.poke(0xFE03, 0x20); c.poke(0xFE01, 8 + 20); c.poke(0xFE04, 0); frame(c)               // x-flip on a symmetric solid tile: unchanged
        check("sprites: flipping a solid tile changes nothing", c.shadeIndices()[20] == 3)
    }
    do {  // 8x16 sprites and the 10-per-line limit
        let c = console(makeROM())
        c.poke(0xFF40, 0x00)
        solidTile(c, 0x8020, 1); solidTile(c, 0x8030, 3)             // 16-row sprite: tile 2 (top) colour 1, tile 3 (bottom) colour 3
        for i in 0..<160 { c.poke(0xFE00 + UInt16(i), 0) }
        c.poke(0xFF48, 0xE4)
        for k in 0..<11 { c.poke(0xFE00 + UInt16(k * 4), 16); c.poke(0xFE01 + UInt16(k * 4), UInt8(8 + k * 12)); c.poke(0xFE02 + UInt16(k * 4), 2) }
        c.poke(0xFF40, 0x96)                                          // OBJ on, 8x16
        frame(c)
        let s = c.shadeIndices()
        check("sprites: 8x16 top half uses the even tile", s[0 * 160 + 0] == 1 && s[0 * 160 + 12] == 1)
        check("sprites: 10 per line, the 11th is dropped", s[108] == 1 && s[120] == 0, "x=108: \(s[108]) x=120: \(s[120])")
        check("sprites: 8x16 bottom half uses the next tile", s[8 * 160 + 0] == 3)
    }
    do {  // Color: palettes, attributes, banks
        let c = console(makeROM(cgb: 0x80))
        check("a Color cartridge runs in colour mode", c.isColor)
        c.poke(0xFF40, 0x00)
        c.poke(0xFF68, 0x80)                                          // BG palette 0, auto-increment
        for v: UInt8 in [0x1F, 0x00, 0xE0, 0x03, 0x00, 0x7C, 0xFF, 0x7F] { c.poke(0xFF69, v) }   // red, green, blue, white
        check("Color: palette index auto-increments", c.peek(0xFF68) == 0xC8)
        solidTile(c, 0x8010, 1)
        c.poke(0x9800, 1)
        c.poke(0xFF40, 0x91)
        let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 160 * 144); defer { fb.deallocate() }
        c.runFrame(framebuffer: fb); c.runFrame(framebuffer: fb)
        check("Color: tile colour 1 is palette entry 1 (pure green)", fb[0] == 0xFF00FF00, String(fb[0], radix: 16))
        // tile attributes: palette 1, bank 1, flipped
        c.poke(0xFF40, 0x00)
        c.poke(0xFF4F, 1); c.poke(0x9800, 0x01)                      // attribute: palette 1
        c.poke(0xFF4F, 0)
        c.poke(0xFF68, 0x88)
        for v: UInt8 in [0x00, 0x00, 0x00, 0x7C] { c.poke(0xFF69, v) }                           // palette 1: colour 1 is blue
        c.poke(0xFF40, 0x91); c.runFrame(framebuffer: fb); c.runFrame(framebuffer: fb)
        check("Color: the attribute map picks palette 1 (pure blue)", fb[0] == 0xFF0000FF, String(fb[0], radix: 16))
        check("Color: VRAM bank register reads back", { c.poke(0xFF4F, 1); let v = c.peek(0xFF4F); c.poke(0xFF4F, 0); return v == 0xFF }())
    }
    do {  // Color: general DMA
        let c = console(makeROM(cgb: 0x80))
        for i in 0..<32 { c.poke(0xC000 + UInt16(i), UInt8(0xA0 + i)) }
        c.poke(0xFF51, 0xC0); c.poke(0xFF52, 0x00); c.poke(0xFF53, 0x00); c.poke(0xFF54, 0x40)    // C000 -> 8040
        c.poke(0xFF55, 1)                                              // general DMA, two 16-byte blocks
        check("Color: general DMA copies into VRAM", c.peek(0x8040) == 0xA0 && c.peek(0x805F) == 0xBF)
        check("Color: DMA status reads done", c.peek(0xFF55) == 0xFF)
    }

    // --- sound ----------------------------------------------------------------------------------
    do {
        let c = console(makeROM())
        c.poke(0xFF26, 0x80); c.poke(0xFF25, 0x11); c.poke(0xFF24, 0x77)
        c.poke(0xFF11, 0x80); c.poke(0xFF12, 0xF0)
        c.poke(0xFF13, UInt8(1750 & 255)); c.poke(0xFF14, 0x80 | UInt8(1750 >> 8))              // 131072 / (2048 - 1750) = 439.8 Hz
        var out = [Int16]()
        let buf = UnsafeMutablePointer<Int16>.allocate(capacity: 2 * 8192); defer { buf.deallocate() }
        for _ in 0..<200 {
            c.idle(4000)
            let n = c.readAudio(into: buf, maxFrames: 8192)
            for i in 0..<n { out.append(buf[i * 2]) }
        }
        let tail = out.dropFirst(4800)
        var crossings = 0, prev = tail.first ?? 0
        for v in tail.dropFirst() { if prev <= 0 && v > 0 { crossings += 1 }; prev = v }
        let f = Double(crossings) / (Double(tail.count) / 48_000)
        check("sound: pulse pitch", abs(f - 439.8) < 4, String(format: "%.1f Hz (expected 439.8) over %d samples", f, out.count))
        check("sound: audible level", (tail.map { abs(Int($0)) }.max() ?? 0) > 2000)
        check("sound: NR52 reports the channel on", c.peek(0xFF26) & 0x81 == 0x81)
        c.poke(0xFF26, 0x00)
        check("sound: power off silences and clears", c.peek(0xFF26) & 0x0F == 0 && c.peek(0xFF12) == 0)
    }

    // --- save states ----------------------------------------------------------------------------
    func fingerprint(_ c: GBConsole) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        func mix(_ v: UInt32) { h = (h ^ v) &* 0x0100_0193 }
        let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 160 * 144); defer { fb.deallocate() }
        let buf = UnsafeMutablePointer<Int16>.allocate(capacity: 2 * 4096); defer { buf.deallocate() }
        c.runFrame(framebuffer: fb)
        for i in 0..<(160 * 144) { mix(fb[i]) }
        let n = c.readAudio(into: buf, maxFrames: 4096)
        for i in 0..<(n * 2) { mix(UInt32(bitPattern: Int32(buf[i]))) }
        mix(UInt32(c.programCounter)); mix(UInt32(truncatingIfNeeded: c.cycleCount))
        for a in stride(from: 0xC000, to: 0xE000, by: 1) { mix(UInt32(c.peek(UInt16(a)))) }
        for a in stride(from: 0x8000, to: 0xA000, by: 1) { mix(UInt32(c.peek(UInt16(a)))) }
        for a in stride(from: 0xFF00, to: 0x10000, by: 1) { mix(UInt32(c.peek(UInt16(a)))) }
        return h
    }
    for (name, path) in [("cpu_instrs 06", "TestROMs/gb-test-roms/src/cpu_instrs/individual/06-ld r,r.gb"),
                         ("dmg-acid2", "TestROMs/gb-test-roms/acid2/dmg-acid2.gb"), ("cgb-acid2", "TestROMs/gb-test-roms/acid2/cgb-acid2.gbc"),
                         ("combined cpu_instrs (MBC1)", "TestROMs/gb-test-roms/src/cpu_instrs/cpu_instrs.gb")] {
        guard let rom = FileManager.default.contents(atPath: path) else { check("\(name): ROM present", false); continue }
        let a = GBConsole(rom: rom)
        for _ in 0..<40 { _ = fingerprint(a) }
        guard let state = a.saveState() else { check("\(name): can save", false); continue }
        let expected = (0..<20).map { _ in fingerprint(a) }
        let b = GBConsole(rom: rom)
        check("\(name): state loads into a fresh machine", b.loadState(state))
        check("\(name): 20 frames after loading match the original", (0..<20).map { _ in fingerprint(b) } == expected)
        check("\(name): states taken afterwards are byte-identical", a.saveState() == b.saveState())
        let long = Data(state.prefix(state.count / 2))
        check("\(name): a truncated state is refused and harmless", { let before = b.saveState(); return !b.loadState(long) && b.saveState() == before }())
    }
    do {
        let a = console(makeROM(title: "A")), b = console(makeROM(banks: 4, title: "B"))
        if let s = a.saveState() { check("a state from another ROM is refused", !b.loadState(s)) }
    }
    do {  // rewind works for this core too
        guard let rom = FileManager.default.contents(atPath: "TestROMs/gb-test-roms/acid2/cgb-acid2.gbc") else { return 1 }
        let c = GBConsole(rom: rom)
        let rewind = RewindBuffer(capacity: 20, interval: 5)
        var history = [UInt32]()
        for _ in 0..<40 { rewind.record(c); history.append(fingerprint(c)) }
        check("rewind: restores and replays the same frames", rewind.rewind(c) && (0..<5).map { _ in fingerprint(c) } == Array(history[35..<40]))
    }

    print(failures == 0 ? "PASS: Game Boy self-check" : "FAIL: \(failures) Game Boy check(s)")
    return failures == 0 ? 0 : 1
}
