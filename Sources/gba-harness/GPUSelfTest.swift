import Foundation
import GBACore

// The GPU picture path against the CPU renderer: random video setups (every mode, windows, blending, mosaic, sprites,
// affine) must give the identical picture, then real ROMs run side by side.

private struct Rng {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
}

func gpuSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name)" + (detail.isEmpty ? "" : ": \(detail)"))
    }
    let probe = GBASystem(); probe.load(rom: Data(count: 0x200))
    guard probe.bus.ppu.setUsesGPU(true, pipelined: false) else { print("SKIP no usable GPU"); return 0 }

    var bad = 0, firstBad = "", colorsSeen = 0
    let scenes = 1500
    var rng = Rng(s: 0x9E37_79B9_7F4A_7C15)
    for scene in 0..<scenes {
        let gba = GBASystem(); gba.load(rom: Data(count: 0x200))
        let bus = gba.bus
        // Video memory: sparse (about half the bytes zero, so layers are often transparent).
        for i in 0..<0x18000 { bus.vram[i] = rng.chance(45) ? 0 : UInt8(truncatingIfNeeded: rng.next()) }
        for i in 0..<0x400 { bus.pram[i] = UInt8(truncatingIfNeeded: rng.next()) }
        // Sprites: a mix of regular, affine, double-size, windows, semi-transparent; some hidden.
        for i in 0..<128 {
            var a0 = UInt16(truncatingIfNeeded: rng.next()), a1 = UInt16(truncatingIfNeeded: rng.next()), a2 = UInt16(truncatingIfNeeded: rng.next())
            a0 = (a0 & 0xFF00) | UInt16(rng.int(180))                          // y
            if rng.chance(55) { a0 |= 0x200; a0 &= ~0x100 }                      // hidden
            if rng.chance(80) { a0 &= ~0x0C00 | (rng.chance(30) ? 0x0400 : 0) }  // mostly normal mode
            a1 = (a1 & 0xFE00) | UInt16(rng.int(260))                           // x
            a2 = (a2 & 0xFC00) | UInt16(rng.chance(50) ? rng.int(1024) : 512 + rng.int(512))
            let b = 0x0700_0000 + UInt32(i * 8)
            bus.poke16(b, a0); bus.poke16(b + 2, a1); bus.poke16(b + 4, a2)
        }
        for i in 0..<0x200 where i % 4 == 3 || true { _ = i }
        for g in 0..<32 {                                                      // affine parameters near identity, sometimes wild
            let wild = rng.chance(30)
            func p(_ base: Int) -> UInt16 { UInt16(bitPattern: Int16(truncatingIfNeeded: base + (wild ? rng.int(0x400) - 0x200 : rng.int(0x40) - 0x20))) }
            let b = 0x0700_0000 + UInt32(g * 32)
            bus.poke16(b + 6, p(0x100)); bus.poke16(b + 14, p(0)); bus.poke16(b + 22, p(0)); bus.poke16(b + 30, p(0x100))
        }
        // Registers.
        let mode = rng.chance(8) ? 3 + rng.int(3) : rng.int(3)
        var dispcnt = mode | (rng.int(2) << 4) | (rng.int(2) << 6)
        dispcnt |= (rng.chance(80) ? 0xF00 : rng.int(16) << 8) & 0xF00
        dispcnt |= (rng.chance(60) ? 0x1000 : 0) | (rng.int(8) << 13 & 0xE000)
        if rng.chance(2) { dispcnt |= 0x80 }
        func io(_ o: UInt32, _ v: Int) { bus.poke16(0x0400_0000 + o, UInt16(truncatingIfNeeded: v)) }
        io(0, dispcnt)
        for n in 0..<4 {
            var cnt = rng.int(4) | (rng.int(4) << 2) | (rng.int(2) << 6) | (rng.int(2) << 7) | (rng.int(32) << 8) | (rng.int(2) << 13) | (rng.int(4) << 14)
            if rng.chance(70) { cnt &= ~0x40 }
            io(UInt32(8 + 2 * n), cnt)
            io(UInt32(0x10 + 4 * n), rng.int(512)); io(UInt32(0x12 + 4 * n), rng.int(512))
        }
        for base: UInt32 in [0x20, 0x30] {
            let wild = rng.chance(25)
            func pm(_ k: Int) -> Int { k + (wild ? rng.int(0x300) - 0x180 : rng.int(0x20) - 0x10) }
            io(base, pm(0x100)); io(base + 2, pm(0)); io(base + 4, pm(0)); io(base + 6, pm(0x100))
            bus.poke32(0x0400_0000 + base + 8, UInt32(truncatingIfNeeded: rng.int(1 << 20) << (rng.chance(50) ? 4 : 0)) & 0x0FFF_FFFF)
            bus.poke32(0x0400_0000 + base + 12, UInt32(truncatingIfNeeded: rng.int(1 << 20) << (rng.chance(50) ? 4 : 0)) & 0x0FFF_FFFF)
        }
        io(0x40, rng.int(0x10000)); io(0x42, rng.int(0x10000)); io(0x44, rng.int(0xA0 << 8) | rng.int(0xA0))
        io(0x46, rng.int(0xA0 << 8) | rng.int(0xA0)); io(0x48, rng.int(0x10000)); io(0x4A, rng.int(0x10000))
        io(0x4C, rng.int(0x100)); io(0x50, rng.chance(75) ? rng.int(0x10000) : 0); io(0x52, rng.int(0x10000)); io(0x54, rng.int(32))

        let ppu = bus.ppu
        ppu.setUsesGPU(false)
        ppu.reloadReferences()
        for l in 0..<160 { ppu.renderLine(l) }
        let cpu = Array(UnsafeBufferPointer(start: ppu.frame, count: 240 * 160))
        colorsSeen += Set(cpu).count
        ppu.setUsesGPU(true, pipelined: false)
        ppu.reloadReferences()
        for l in 0..<160 { ppu.renderLine(l) }
        ppu.finishFrame()
        let gpu = Array(UnsafeBufferPointer(start: ppu.frame, count: 240 * 160))
        if cpu != gpu {
            bad += 1
            if firstBad.isEmpty {
                let i = zip(cpu, gpu).enumerated().first { $0.element.0 != $0.element.1 }!.offset
                firstBad = String(format: "scene %d (mode %d, dispcnt %04X) pixel (%d,%d): cpu %08X gpu %08X", scene, mode, dispcnt, i % 240, i / 240, cpu[i], gpu[i])
            }
        }
    }
    check("\(scenes) random video setups draw identically on CPU and GPU", bad == 0, bad == 0 ? "" : "\(bad) differ; first: \(firstBad)")

    check("the random scenes are busy (not just blank screens)", colorsSeen / scenes > 40, "\(colorsSeen / scenes) distinct colours per scene on average")

    // Real software, run side by side from the same start (frames differ only if something changes video memory mid-frame).
    var roms = ["TestROMs/jsmolka-gba-tests/ppu/hello.gba", "TestROMs/jsmolka-gba-tests/ppu/shades.gba", "TestROMs/jsmolka-gba-tests/ppu/stripes.gba", "TestROMs/jsmolka-gba-tests/nes/nes.gba"]
    if let extra = ProcessInfo.processInfo.environment["GPU_TEST_ROM"] { roms.append(extra) }
    for path in roms {
        guard let rom = FileManager.default.contents(atPath: path) else { continue }
        let a = GBAConsole(rom: rom), b = GBAConsole(rom: rom)
        b.setPictureOnGPU(true, pipelined: false)
        let fa = UnsafeMutablePointer<UInt32>.allocate(capacity: 240 * 160), fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 240 * 160)
        defer { fa.deallocate(); fb.deallocate() }
        var differing = 0, frames = 600
        for f in 0..<frames {
            let keys: GBAKeys = f % 120 < 4 ? [.start] : (f % 50 < 3 ? [.a] : [])
            a.setKeys(keys); b.setKeys(keys)
            a.runFrame(framebuffer: fa); b.runFrame(framebuffer: fb)
            if f >= 2, memcmp(fa, fb, 240 * 160 * 4) != 0 {       // the first frame or two draw before the game has set up video memory
                differing += 1
                if differing == 1 { var n = 0, firstLine = -1; for i in 0..<(240 * 160) where fa[i] != fb[i] { n += 1; if firstLine < 0 { firstLine = i / 240 } }; print("    first differing frame \(f): \(n) pixels, from line \(firstLine)") }
            }
        }
        frames = 600
        check("\((path as NSString).lastPathComponent): \(frames) frames side by side (after the first two)", differing == 0, "\(differing) frames differ")
    }
    // The pipelined mode (what the app uses) shows each picture one frame late, and otherwise matches exactly.
    if let rom = FileManager.default.contents(atPath: "TestROMs/jsmolka-gba-tests/nes/nes.gba") {
        let a = GBAConsole(rom: rom), b = GBAConsole(rom: rom)
        b.setPictureOnGPU(true)
        let fa = UnsafeMutablePointer<UInt32>.allocate(capacity: 240 * 160), fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 240 * 160)
        defer { fa.deallocate(); fb.deallocate() }
        var previous = [UInt32](repeating: 0, count: 240 * 160), late = 0
        for f in 0..<400 {
            a.runFrame(framebuffer: fa); b.runFrame(framebuffer: fb)
            if f >= 3, memcmp(previous, fb, 240 * 160 * 4) != 0 { late += 1 }
            previous = Array(UnsafeBufferPointer(start: fa, count: 240 * 160))
        }
        check("pipelined GPU drawing equals the CPU picture one frame later", late == 0, "\(late) frames differ")
    }

    print(failures == 0 ? "PASS GPU picture self-test" : "FAIL \(failures) GPU picture check(s) failed")
    return failures == 0 ? 0 : 1
}
