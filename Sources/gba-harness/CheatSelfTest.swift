import Foundation
import GBACore

// Every cheat-device family: decryption, auto-detection, each code type's effect on a running machine, and the refusals.

func cheatSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name)" + (detail.isEmpty ? "" : ": \(detail)"))
    }
    func hex(_ v: UInt32) -> String { String(format: "%08X", v) }

    // --- the cipher ------------------------------------------------------------------------------
    var c3 = CheatCipher(.v3)
    let d3 = c3.decrypt((0xF705_6CA0, 0xE3B2_65B6))
    check("AR v3 test vector decrypts (F7056CA0 E3B265B6 -> 42305008 014C0001)", d3.0 == 0x4230_5008 && d3.1 == 0x014C_0001, "\(hex(d3.0)) \(hex(d3.1))")
    for gen in [CheatCipher.Generation.v1v2, .v3] {
        var enc = CheatCipher(gen), dec = CheatCipher(gen)
        let lines: [(UInt32, UInt32)] = [(0x0300_7E00, 0xFF), (0xDEAD_FACE, 0x0000_1234), (0x2300_7E20, 0xDEAD_BEEF), (0xDEAD_FACE, 0x0000_00AB), (0x1300_7E10, 0xABCD)]
        var ok = true
        for l in lines { let e = enc.encrypt(l); let d = dec.decrypt(e); if d.0 != l.0 || d.1 != l.1 { ok = false } }
        check("\(gen) encrypt/decrypt round-trips across seed changes", ok)
    }
    var s1 = CheatCipher(.v1v2), s3 = CheatCipher(.v3)
    check("the two generations start with different keys", s1.seeds != s3.seeds)
    let before = s1.seeds; s1.changeSeeds(0x0102)
    check("DEADFACE changes the keys", s1.seeds != before)

    // --- a machine to run codes against ------------------------------------------------------------
    var rom = Data(count: 0x1000)
    rom.replaceSubrange(0..<4, with: [0xFE, 0xFF, 0xFF, 0xEA])
    let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 240 * 160); defer { fb.deallocate() }

    func program(_ text: String, _ format: CheatFormat = .auto) -> CheatProgram? {
        if case .success(let p) = CheatCompiler.compile(text, format: format) { return p } else { return nil }
    }
    func failure(_ text: String, _ format: CheatFormat = .auto) -> CheatParseError? {
        if case .failure(let e) = CheatCompiler.compile(text, format: format) { return e } else { return nil }
    }
    /// Run one frame with the code active after `setup` has prepared memory.
    func run(_ text: String, _ format: CheatFormat = .auto, frames: Int = 1, setup: (Bus) -> Void = { _ in }) -> Bus? {
        guard let p = program(text, format) else { print("    (did not compile: \(failure(text, format)?.description ?? "?"))"); return nil }
        let console = GBAConsole(rom: rom)
        let bus = console.machine.bus
        setup(bus)
        console.setCheatProgram(p)
        for _ in 0..<frames { console.runFrame(framebuffer: fb) }
        return bus
    }
    let base: UInt32 = 0x0300_7E00
    func w8(_ o: UInt32) -> (Bus?) -> UInt8? { { $0?.peek8(base + o) } }

    // --- Action Replay v3, decrypted ---------------------------------------------------------------
    var bus = run("00307E00 000002AA\n02307E10 0001ABCD\n04307E20 DEADBEEF")
    check("ARv3: 8-bit fill writes x+1 bytes", bus?.peek8(base) == 0xAA && bus?.peek8(base + 2) == 0xAA && bus?.peek8(base + 3) == 0)
    check("ARv3: 16-bit fill", bus?.peek16(base + 0x10) == 0xABCD && bus?.peek16(base + 0x12) == 0xABCD)
    check("ARv3: 32-bit write", bus?.peek32(base + 0x20) == 0xDEAD_BEEF)

    bus = run("44307E40 12345678\n40307E40 000010AA\n42307E40 0002BBCC") { $0.poke32(base + 0x40, 0x0300_7F00) }
    check("ARv3: pointer 8-bit", bus?.peek8(0x0300_7F10) == 0xAA)
    check("ARv3: pointer 16-bit", bus?.peek16(0x0300_7F04) == 0xBBCC)
    check("ARv3: pointer 32-bit", bus?.peek32(0x0300_7F00) == 0x1234_5678)

    bus = run("80307E50 00000010\n82307E52 00000100\n84307E54 00010000") { $0.poke8(base + 0x50, 5); $0.poke16(base + 0x52, 7); $0.poke32(base + 0x54, 9) }
    check("ARv3: add codes", bus?.peek8(base + 0x50) == 0x15 && bus?.peek16(base + 0x52) == 0x107 && bus?.peek32(base + 0x54) == 0x10009)
    bus = run("80307E50 00000010", frames: 3) { $0.poke8(base + 0x50, 5) }
    check("ARv3: add codes accumulate every frame", bus?.peek8(base + 0x50) == 5 + 3 * 0x10)

    bus = run("C6000008 00000C0F")
    check("ARv3: 16-bit I/O write", bus?.peek16(0x0400_0008) == 0x0C0F, String(format: "%04X", bus?.peek16(0x0400_0008) ?? 0))

    let eq = { (b: Bus) in b.poke16(base + 0x60, 0x1234) }
    bus = run("0A307E60 00001234\n04307E64 11111111\n0A307E60 00000001\n04307E68 22222222", setup: eq)
    check("ARv3: if-equal runs the next line only when true", bus?.peek32(base + 0x64) == 0x1111_1111 && bus?.peek32(base + 0x68) == 0)
    bus = run("4A307E60 00000001\n04307E70 00000001\n04307E74 00000002\n04307E78 00000003", setup: eq)
    check("ARv3: two-line variant skips two", bus?.peek32(base + 0x70) == 0 && bus?.peek32(base + 0x74) == 0 && bus?.peek32(base + 0x78) == 3)
    bus = run("8A307E60 00000001\n04307E70 00000001\n04307E74 00000002\n00000000 40000000\n04307E78 00000003", setup: eq)
    check("ARv3: multi-line variant skips to the end-of-condition code", bus?.peek32(base + 0x70) == 0 && bus?.peek32(base + 0x74) == 0 && bus?.peek32(base + 0x78) == 3)
    bus = run("8A307E60 00001234\n04307E70 00000001\n04307E74 00000002\n00000000 40000000", setup: eq)
    check("ARv3: multi-line variant runs everything when true", bus?.peek32(base + 0x70) == 1 && bus?.peek32(base + 0x74) == 2)
    bus = run("CA307E60 00000001\n04307E80 00000005", setup: eq)
    check("ARv3: disable variant stops the list when false", bus?.peek32(base + 0x80) == 0)
    bus = run("CA307E60 00001234\n04307E80 00000005", setup: eq)
    check("ARv3: …and does nothing when true", bus?.peek32(base + 0x80) == 5)
    bus = run("8A307E60 00000001\n04307E70 00000001\n00000000 60000000\n04307E74 00000002", setup: eq)
    check("ARv3: 'run everything' overrides an open condition", bus?.peek32(base + 0x70) == 0 && bus?.peek32(base + 0x74) == 2)
    bus = run("0E300000 00000000\n04307E70 00000001\n04307E74 00000002")
    check("ARv3: always-skip drops the next line", bus?.peek32(base + 0x70) == 0 && bus?.peek32(base + 0x74) == 2)
    bus = run("04307E70 00000001\n00000000 00000000\n04307E74 00000002")
    check("ARv3: 00000000 ends the list", bus?.peek32(base + 0x70) == 1 && bus?.peek32(base + 0x74) == 0)

    // Comparisons: signed vs unsigned, AND, all three widths.
    let mem = { (b: Bus) in b.poke8(base + 0x90, 0xFF); b.poke16(base + 0x92, 0x8000); b.poke32(base + 0x94, 0x8000_0000) }
    func fires(_ code: String) -> Bool { run(code + "\n04307EF0 00000001", setup: mem)?.peek32(base + 0xF0) == 1 }
    check("ARv3: signed less-than sees 0xFF as -1 (8-bit)", fires("18307E90 00000000"))
    check("ARv3: unsigned less-than does not (8-bit)", !fires("28307E90 00000000"))
    check("ARv3: signed greater-than (16-bit, 0x8000 is negative)", !fires("21307E92 00000000") && fires("21307E92 0000FFFF") == false)
    check("ARv3: unsigned greater-than (16-bit)", fires("32307E92 00007FFF"))
    check("ARv3: signed less-than (32-bit)", fires("1C307E94 00000000"))
    check("ARv3: unsigned greater-than (32-bit)", fires("34307E94 7FFFFFFF"))
    check("ARv3: not-equal", fires("10307E90 00000000") && !fires("10307E90 000000FF"))
    check("ARv3: AND is true when any bit matches", fires("39307E92 00008001") && !fires("39307E92 00000001"))
    check("ARv3: 32-bit equal", fires("0C307E94 80000000"))

    bus = run("00000000 80307EC0\n00000001 02030004")
    check("ARv3: 8-bit slide", bus?.peek8(base + 0xC0) == 1 && bus?.peek8(base + 0xC4) == 3 && bus?.peek8(base + 0xC8) == 5 && bus?.peek8(base + 0xCC) == 0)
    bus = run("00000000 82307ED0\n0000AAAA 01020002")
    check("ARv3: 16-bit slide (address step counts halfwords)", bus?.peek16(base + 0xD0) == 0xAAAA && bus?.peek16(base + 0xD4) == 0xAAAB)
    bus = run("00000000 84307EE0\n11111111 10020001\n80000000 00000000")
    check("ARv3: 32-bit slide with its trailing workaround line", bus?.peek32(base + 0xE0) == 0x1111_1111 && bus?.peek32(base + 0xE4) == 0x1111_1121)
    check("ARv3: ROM patches are refused with a reason", failure("00000000 18300000\n00001234 00000000", .actionReplayV3)?.message.contains("ROM patches") == true)
    check("ARv3: button writes are accepted but noted", program("00000000 10307E00\n000000FF 00000000", .actionReplayV3)?.notes.isEmpty == false)
    check("ARv3: master and ID codes are accepted", program("C4000100 00000010\n12345678 001DC0DE\n04307E70 00000001", .actionReplayV3)?.ops.count == 3)
    check("ARv3: an unknown type says so", failure("06307E00 00000000", .actionReplayV3)?.message.contains("isn't an Action Replay v3 code") == true)

    // --- GameShark Advance / Action Replay v1-v2, decrypted ----------------------------------------
    bus = run("03007F00 000000FF\n13007F02 0000ABCD\n23007F04 DEADBEEF")
    check("GSA: 8/16/32-bit writes", bus?.peek8(0x0300_7F00) == 0xFF && bus?.peek16(0x0300_7F02) == 0xABCD && bus?.peek32(0x0300_7F04) == 0xDEAD_BEEF)
    check("GSA: auto-detected as GameShark", program("03007F00 000000FF")?.format == .gameShark)
    bus = run("30000003 CAFEBABE\n03007F10 03007F20\n03007F30 00000000")
    check("GSA: group write fills every listed address", bus?.peek32(0x0300_7F10) == 0xCAFE_BABE && bus?.peek32(0x0300_7F20) == 0xCAFE_BABE && bus?.peek32(0x0300_7F30) == 0xCAFE_BABE)
    check("GSA: a group write that runs out of lines is an error", failure("30000004 CAFEBABE\n03007F10 03007F20", .gameShark) != nil)
    let gmem = { (b: Bus) in b.poke16(0x0300_7F40, 0x1111) }
    bus = run("D3007F40 00001111\n13007F44 0000ABCD\nD3007F40 00002222\n13007F46 00001234", setup: gmem)
    check("GSA: D (16-bit if-equal) guards one line", bus?.peek16(0x0300_7F44) == 0xABCD && bus?.peek16(0x0300_7F46) == 0)
    bus = run("E0021111 03007F40\n13007F50 00000001\n13007F52 00000002\n13007F54 00000003", setup: gmem)
    check("GSA: E (multi-line if-equal) runs zz lines when equal", bus?.peek16(0x0300_7F50) == 1 && bus?.peek16(0x0300_7F52) == 2 && bus?.peek16(0x0300_7F54) == 3)
    bus = run("E0022222 03007F40\n13007F50 00000001\n13007F52 00000002\n13007F54 00000003", setup: gmem)
    check("GSA: …and skips them when not", bus?.peek16(0x0300_7F50) == 0 && bus?.peek16(0x0300_7F52) == 0 && bus?.peek16(0x0300_7F54) == 3)

    // ROM patch: reads of the ROM change, and go back when the cheat is removed.
    do {
        let console = GBAConsole(rom: rom)
        let rb = console.machine.bus
        let original = rb.peek16(0x0800_0008)
        console.setCheatProgram(program("60000010 00001234")!)
        console.runFrame(framebuffer: fb)
        let patched = rb.peek16(0x0800_0008)
        console.setCheatProgram(CheatProgram())
        check("GSA: ROM patch changes what the game reads", patched == 0x1234, String(format: "%04X", patched))
        check("GSA: …and removing the cheat puts the ROM back", rb.peek16(0x0800_0008) == original)
    }
    check("GSA: button-held and slowdown codes are accepted but noted", program("80100000 000000FF\n80F00000 00000001")?.notes.count == 2)
    check("GSA: hook and ID codes are accepted", program("F0000100 00000001\n12345678 001DC0DE\n03007F00 000000FF", .gameShark)?.ops.count == 3)
    check("a line that fits both GameShark and AR v3 by shape goes to the one whose addresses exist", program("04307E70 00000001")?.format == .actionReplayV3)
    check("GSA: an address outside RAM is refused", failure("0A000000 000000FF", .gameShark) != nil)
    check("GSA: a too-large 8-bit value is refused with the line number", failure("03007F00 000000FF\n03007F01 00000100", .gameShark)?.line == 2)

    // --- CodeBreaker ----------------------------------------------------------------------------------
    bus = run("33007F00 00FF\n83007F02 ABCD")
    check("CodeBreaker: 3 (8-bit) and 8 (16-bit) writes", bus?.peek8(0x0300_7F00) == 0xFF && bus?.peek16(0x0300_7F02) == 0xABCD)
    check("CodeBreaker: 12-digit lines are auto-detected", program("33007F00 00FF")?.format == .codeBreaker)
    bus = run("63007F04 00F0") { $0.poke16(0x0300_7F04, 0x1234) }
    check("CodeBreaker: 6 ANDs the halfword", bus?.peek16(0x0300_7F04) == 0x0030)
    bus = run("43007F10 0001\n00010003 0002")
    check("CodeBreaker: 4 slide writes count values, stepping value and address", bus?.peek16(0x0300_7F10) == 1 && bus?.peek16(0x0300_7F14) == 2 && bus?.peek16(0x0300_7F18) == 3 && bus?.peek16(0x0300_7F1C) == 0)
    let cmem = { (b: Bus) in b.poke16(0x0300_7F20, 0x1111) }
    bus = run("73007F20 1111\n83007F24 BEEF\n73007F20 2222\n83007F26 CAFE", setup: cmem)
    check("CodeBreaker: 7 (if equal) guards one line", bus?.peek16(0x0300_7F24) == 0xBEEF && bus?.peek16(0x0300_7F26) == 0)
    bus = run("A3007F20 2222\n83007F28 CAFE\nA3007F20 1111\n83007F2A 0BAD", setup: cmem)
    check("CodeBreaker: A (if not equal) guards one line", bus?.peek16(0x0300_7F28) == 0xCAFE && bus?.peek16(0x0300_7F2A) == 0)
    bus = run("D0000020 03FF\n83007F30 1111\nD0000020 03FE\n83007F32 2222")
    check("CodeBreaker: D0000020 button check (no buttons held)", bus?.peek16(0x0300_7F30) == 0x1111 && bus?.peek16(0x0300_7F32) == 0)
    do {
        let console = GBAConsole(rom: rom); let b = console.machine.bus
        console.setCheatProgram(program("D0000020 03FE\n83007F30 1111")!)
        console.setKeys(GBAKeys(rawValue: 1))
        console.runFrame(framebuffer: fb)
        check("CodeBreaker: …and fires while A is held", b.peek16(0x0300_7F30) == 0x1111)
    }
    check("CodeBreaker: master and hook lines are accepted", program("0000DB72 000A\n10000A40 0007\n33007F00 00FF")?.ops.count == 3)
    check("CodeBreaker: an encrypted (9…) code is refused with the reason", failure("9A4E1100 0000", .codeBreaker)?.message.contains("encrypted") == true)
    check("CodeBreaker: 12-digit lines under another format point at CodeBreaker", failure("33007F00 00FF", .gameShark)?.message.contains("CodeBreaker") == true)

    // --- encrypted -------------------------------------------------------------------------------------
    func encrypted(_ lines: [(UInt32, UInt32)], _ gen: CheatCipher.Generation) -> String {
        var e = CheatCipher(gen)
        return lines.map { let x = e.encrypt($0); return hex(x.0) + " " + hex(x.1) }.joined(separator: "\n")
    }
    let plainV12: [(UInt32, UInt32)] = [(0x0300_7F00, 0xFF), (0x1300_7F02, 0xABCD), (0xDEAD_FACE, 0x0000_0123), (0x2300_7F04, 0xDEAD_BEEF)]
    let textV12 = encrypted(plainV12, .v1v2)
    check("encrypted GS/AR v1-v2 is detected", program(textV12)?.format == .encryptedV12, program(textV12).map { "\($0.format)" } ?? failure(textV12)?.description ?? "")
    bus = run(textV12)
    check("…and decrypts, follows the key change, and runs", bus?.peek8(0x0300_7F00) == 0xFF && bus?.peek16(0x0300_7F02) == 0xABCD && bus?.peek32(0x0300_7F04) == 0xDEAD_BEEF)
    let plainV3: [(UInt32, UInt32)] = [(0x0430_7F10, 0x1234_5678), (0xDEAD_FACE, 0x0000_0042), (0x0230_7F14, 0x0000_BEEF), (0x0A30_7F10, 0x1234_5678), (0x0430_7F18, 0x0000_0001)]
    let textV3 = encrypted(plainV3, .v3)
    check("encrypted AR v3 is detected", program(textV3)?.format == .encryptedV3, program(textV3).map { "\($0.format)" } ?? failure(textV3)?.description ?? "")
    bus = run(textV3)
    check("…and runs, conditionals included", bus?.peek32(0x0300_7F10) == 0x1234_5678 && bus?.peek16(0x0300_7F14) == 0xBEEF && bus?.peek32(0x0300_7F18) == 1)
    check("choosing the wrong generation fails cleanly rather than guessing", failure(textV3, .encryptedV12) != nil)

    // --- text handling -----------------------------------------------------------------------------------
    check("eight-digit halves on separate lines are paired", program("03007F00\n000000FF")?.ops.count == 1)
    check("separators and lowercase are tolerated", program("0300-7f00 : 0000-00ff")?.ops.count == 1)
    check("a non-hex character is reported with its line", failure("03007F00 000000FF\n0300ZF00 000000FF")?.line == 2)
    check("a wrong length is reported with its line", failure("03007F00 000000FF\n03007F00 00FF00")?.line == 2)
    check("an empty list is fine", program("")?.isEmpty == true)
    check("several cheats don't leak conditions into each other", {
        let a = program("0A307E60 00000001")!, b = program("04307E70 00000001")!
        let console = GBAConsole(rom: rom)
        console.setCheatProgram(CheatProgram.join([a, b]))
        console.runFrame(framebuffer: fb)
        return console.machine.bus.peek32(0x0300_7E70) == 1
    }())

    print(failures == 0 ? "PASS cheat self-test" : "FAIL \(failures) cheat check(s) failed")
    return failures == 0 ? 0 : 1
}
