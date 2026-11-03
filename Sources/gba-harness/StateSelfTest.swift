import Foundation
import GBACore

// Save states: a restored machine must behave exactly like the one that was saved, byte for byte, frame after frame.

func stateSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name)" + (detail.isEmpty ? "" : ": \(detail)"))
    }
    func fnv(_ h: inout UInt32, _ v: UInt32) { h = (h ^ v) &* 0x0100_0193 }
    func fnvBytes(_ h: inout UInt32, _ p: UnsafePointer<UInt8>, _ n: Int) { for i in 0..<n { fnv(&h, UInt32(p[i])) } }

    let audio = UnsafeMutablePointer<Int16>.allocate(capacity: 2 * 4096)
    let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 240 * 160)
    defer { audio.deallocate(); fb.deallocate() }

    /// Everything observable after a frame: picture, sound, registers, time and all memories.
    func fingerprint(_ c: GBAConsole) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        c.runFrame(framebuffer: fb)
        for i in 0..<(240 * 160) { fnv(&h, fb[i]) }
        let n = c.readAudio(into: audio, maxFrames: 4096)
        for i in 0..<(n * 2) { fnv(&h, UInt32(bitPattern: Int32(audio[i]))) }
        let m = c.machine, b = m.bus
        for i in 0..<16 { fnv(&h, m.cpu.r[i]) }
        fnv(&h, m.cpu.cpsr); fnv(&h, UInt32(truncatingIfNeeded: b.cycles)); fnv(&h, UInt32(b.ifl)); fnv(&h, UInt32(b.ie))
        fnvBytes(&h, b.ewram, 0x40000); fnvBytes(&h, b.iwram, 0x8000); fnvBytes(&h, b.vram, 0x18000)
        fnvBytes(&h, b.pram, 0x400); fnvBytes(&h, b.oam, 0x400); fnvBytes(&h, b.io, 0x400)
        return h
    }
    func run(_ c: GBAConsole, _ frames: Int) -> [UInt32] { (0..<frames).map { _ in fingerprint(c) } }

    // --- real test ROMs -----------------------------------------------------------------------
    for name in ["arm/arm.gba", "nes/nes.gba", "ppu/stripes.gba"] {
        guard let rom = FileManager.default.contents(atPath: "TestROMs/jsmolka-gba-tests/\(name)") else { check("\(name): ROM present", false); continue }
        let a = GBAConsole(rom: rom)
        _ = run(a, 20)
        guard let state = a.saveState() else { check("\(name): can save", false); continue }
        let expected = run(a, 30)
        let b = GBAConsole(rom: rom)
        check("\(name): state loads into a fresh machine", b.loadState(state))
        check("\(name): 30 frames after loading match the original", run(b, 30) == expected)
        check("\(name): state taken afterwards is byte-identical", a.saveState() == b.saveState())
        let c = GBAConsole(rom: rom)
        _ = c.loadState(state)
        check("\(name): load then save reproduces the state exactly", c.saveState() == state)
    }

    // --- a machine with video, DMA, timers, sound and a half-finished flash command -------------
    var rom = Data(count: 0x2000)
    rom.replaceSubrange(0..<4, with: [0xFE, 0xFF, 0xFF, 0xEA])               // b .
    rom.replaceSubrange(0x100..<0x107, with: Array("FLASH_V".utf8))
    func busyMachine() -> GBAConsole {
        let c = GBAConsole(rom: rom), b = c.machine.bus
        let io: UInt32 = 0x0400_0000
        // picture: mode 0, BG0 with a tile, one sprite, per-line scroll fed by HBlank DMA
        b.poke16(io, 0x1100); b.poke16(io + 8, (1 << 2) | (4 << 8))
        for i in 0..<32 { b.vram[0x4000 + 32 + i] = UInt8(truncatingIfNeeded: i * 7 + 1); b.vram[0x10000 + i] = UInt8(truncatingIfNeeded: i * 5 + 3) }
        for i in 0..<64 { b.poke16(0x0600_2000 + UInt32(i * 2), 1) }
        for i in 0..<128 { b.poke16(0x0700_0000 + UInt32(i * 8), 0x200) }
        b.poke16(0x0700_0000, 40); b.poke16(0x0700_0002, 60)
        for i in 1...15 { b.poke16(0x0500_0000 + UInt32(i * 2), UInt16(i * 0x0421)); b.poke16(0x0500_0200 + UInt32(i * 2), UInt16(0x7FFF - i * 0x0421)) }
        for i in 0..<160 { b.poke16(0x0200_4000 + UInt32(i * 2), UInt16((i * 3) & 0xFF)) }
        b.poke32(io + 0xD4, 0x0200_4000); b.poke32(io + 0xD8, io + 0x10)
        b.poke32(io + 0xDC, 1 | (0x8000 | 0x200 | 2 << 12 | 2 << 5) << 16)       // HBlank DMA3 -> BG0HOFS, repeat
        // sound: PSG pulse + noise, FIFO A through timer 0 and DMA1
        b.poke16(io + 0x84, 0x80); b.poke16(io + 0x80, 0x9977); b.poke16(io + 0x82, 0x0B0A)
        b.poke16(io + 0x62, 0xF100 | 2 << 6); b.poke16(io + 0x64, 0x8000 | 1700)
        b.poke16(io + 0x78, 0xA100); b.poke16(io + 0x7C, 0x8000 | 0x25)
        for i in 0..<4096 { b.poke8(0x0200_8000 + UInt32(i), UInt8(truncatingIfNeeded: (i / 24 % 2 == 0) ? 60 : -60)) }
        b.poke32(io + 0xBC, 0x0200_8000); b.poke32(io + 0xC0, io + 0xA0)
        b.poke32(io + 0xC4, 4 | (0x8000 | 0x400 | 0x200 | 3 << 12 | 2 << 5) << 16)
        b.poke16(io + 0x100, 0xFE00); b.poke16(io + 0x102, 0x0080)
        b.poke16(io + 0x104, 0xFF00); b.poke16(io + 0x106, 0x0084)                // a cascaded timer too
        return c
    }
    do {
        let a = busyMachine()
        _ = run(a, 25)
        let b = a.machine.bus
        b.poke8(0x0E00_5555, 0xAA); b.poke8(0x0E00_2AAA, 0x55)                    // flash command left half-way
        guard let state = a.saveState() else { check("busy: can save", false); return 1 }
        func finish(_ c: GBAConsole) -> [UInt32] {
            c.machine.bus.poke8(0x0E00_5555, 0xA0); c.machine.bus.poke8(0x0E00_0010, 0x5A)
            var out = run(c, 30)
            out.append(UInt32(c.machine.bus.peek8(0x0E00_0010)))
            return out
        }
        let expected = finish(a)
        check("busy: the scenario really changes every frame", Set(expected.dropLast()).count == 30, "\(Set(expected.dropLast()).count) distinct of 30")
        let probe = busyMachine()
        _ = run(probe, 10)
        var loud = 0
        for _ in 0..<5 { probe.runFrame(framebuffer: fb); let n = probe.readAudio(into: audio, maxFrames: 4096); for i in 0..<(n * 2) where abs(Int(audio[i])) > 500 { loud += 1 } }
        check("busy: sound is actually playing", loud > 500, "\(loud) loud samples")
        let c = busyMachine()
        check("busy: state loads", c.loadState(state))
        let got = finish(c)
        check("busy: 30 frames of video/sound/DMA/timers match", Array(got.dropLast()) == Array(expected.dropLast()))
        check("busy: the half-finished flash command completes after loading", got.last == 0x5A && expected.last == 0x5A)
        check("busy: states afterwards are byte-identical", a.saveState() == c.saveState())
        check("busy: state size is sensible", state.count > 400_000 && state.count < 700_000, "\(state.count) bytes")

        // --- bad input is refused and harmless ---
        let before = c.saveState()
        check("truncated state is rejected", !c.loadState(state.prefix(state.count / 2)) )
        check("a rejected load changes nothing", c.saveState() == before)
        var corrupt = state; corrupt[corrupt.count - 1] ^= 0xFF
        check("corrupted trailer is rejected", !c.loadState(corrupt) && c.saveState() == before)
        let other = GBAConsole(rom: Data(count: 0x2000))
        check("a state from another ROM is rejected", !other.loadState(state))
    }

    // --- rewind ---------------------------------------------------------------------------------
    do {
        let c = busyMachine()
        let rewind = RewindBuffer(capacity: 40, interval: 5)
        var history = [UInt32]()
        for _ in 0..<100 { rewind.record(c); history.append(fingerprint(c)) }
        check("rewind: keeps a snapshot every 5 frames", rewind.depth == 20, "\(rewind.depth)")
        check("rewind: restores a snapshot", rewind.rewind(c))
        check("rewind: replaying from it reproduces frames 96-100", run(c, 5) == Array(history[95..<100]))
        check("rewind: and again, further back", rewind.rewind(c) && rewind.rewind(c) && run(c, 10) == Array(history[85..<95]) )
        var steps = 0
        while rewind.rewind(c) { steps += 1; if steps > 100 { break } }
        check("rewind: runs out cleanly at the oldest snapshot", steps == 17 && !rewind.rewind(c), "\(steps) more steps")
        let small = RewindBuffer(capacity: 3, interval: 5)
        let d = busyMachine()
        for _ in 0..<60 { small.record(d); _ = fingerprint(d) }
        check("rewind: capacity limit drops the oldest", small.depth == 3)
    }

    print(failures == 0 ? "PASS: save-state self-check" : "FAIL: \(failures) save-state check(s)")
    return failures == 0 ? 0 : 1
}
