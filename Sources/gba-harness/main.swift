import Foundation
import GBACore

// Headless harness.
//   gba-harness <rom.gba> [--max-cycles N] [--bios file]   run a ROM until it parks in its idle loop, report r12
//   gba-harness [frames]                                   exercise the placeholder core (plumbing check)
//
// The public test ROMs (jsmolka/gba-tests) leave 0 in r12 when every test passed, or the number of the first failing test.

/// Print the middle band of the mode-4 frame as ASCII so the on-screen result text can be read without a renderer.
func dumpMode4Text(_ bus: Bus) {
    let base = (bus.peek16(0x0400_0000) & 0x10) != 0 ? 0xA000 : 0
    var bg = [UInt8: Int]()
    for y in 70..<100 { for x in 0..<240 { bg[bus.vram[base + y * 240 + x], default: 0] += 1 } }
    let background = bg.max { $0.value < $1.value }?.key ?? 0
    for y in 72..<92 {
        var line = ""
        for x in 40..<200 { line += bus.vram[base + y * 240 + x] == background ? " " : "#" }
        if line.contains("#") { print(line) }
    }
}

func runROM(path: String, maxCycles: UInt64, biosPath: String?) -> Int32 {
    guard let rom = FileManager.default.contents(atPath: path) else { print("cannot read \(path)"); return 2 }
    let bios = biosPath.flatMap { FileManager.default.contents(atPath: $0) }
    let gba = GBASystem()
    gba.load(rom: rom, bios: bios)
    let cpu = gba.cpu
    var parked = 0
    let t0 = DispatchTime.now().uptimeNanoseconds
    while gba.bus.cycles < maxCycles {
        let pc = cpu.r[15]
        cpu.step()
        if cpu.r[15] == pc && !cpu.halted { parked += 1; if parked >= 4 { break } } else { parked = 0 }
    }
    let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    let r12 = cpu.r[12]
    let idle = parked >= 4
    print(String(format: "%@  pc=%08X  r12=%u  cycles=%llu  instructions=%llu  %.1f MIPS  %@",
                 (path as NSString).lastPathComponent, cpu.r[15], r12, gba.bus.cycles, cpu.instructionCount,
                 Double(cpu.instructionCount) / max(secs, 1e-9) / 1e6, idle ? "[reached idle loop]" : "[TIMED OUT before idle loop]"))
    if args.contains("--ascii") { dumpMode4Text(gba.bus) }
    if !idle { return 3 }
    if r12 == 0 { print("PASS: all tests passed"); return 0 }
    print("FAIL: first failing test number = \(r12)")
    return 1
}

/// Run a ROM for a fixed number of cycles (ignoring the idle loop) and report speed as a multiple of real time.
func bench(path: String, cycles: UInt64) -> Int32 {
    guard let rom = FileManager.default.contents(atPath: path) else { print("cannot read \(path)"); return 2 }
    let gba = GBASystem()
    gba.load(rom: rom)
    let t0 = DispatchTime.now().uptimeNanoseconds
    gba.run(cycles: cycles)
    let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    let instr = Double(gba.cpu.instructionCount)
    print(String(format: "bench: %.0fM cycles in %.2fs = %.1fx real time (GBA = 16.78M cycles/s)   %.1f MIPS   %.1f cycles/instr",
                 Double(cycles) / 1e6, secs, Double(cycles) / 16_777_216 / secs, instr / secs / 1e6, Double(cycles) / instr))
    return 0
}

/// Check the native BIOS maths against mathematically defined answers (angles are in 1/65536 of a turn).
func biosSelfTest() -> Int32 {
    let gba = GBASystem()
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name): \(detail)")
    }
    func s32(_ v: UInt32) -> Int32 { Int32(bitPattern: v) }
    func u(_ v: Int32) -> UInt32 { UInt32(bitPattern: v) }

    var r = gba.callBIOS(0x06, r0: 7, r1: 2);          check("Div 7/2", s32(r[0]) == 3 && s32(r[1]) == 1 && s32(r[3]) == 3, "q=\(s32(r[0])) rem=\(s32(r[1])) |q|=\(s32(r[3]))")
    r = gba.callBIOS(0x06, r0: u(-7), r1: 2);           check("Div -7/2", s32(r[0]) == -3 && s32(r[1]) == -1 && s32(r[3]) == 3, "q=\(s32(r[0])) rem=\(s32(r[1])) |q|=\(s32(r[3]))")
    r = gba.callBIOS(0x07, r0: 2, r1: 7);               check("DivArm 7/2 (swapped args)", s32(r[0]) == 3 && s32(r[1]) == 1, "q=\(s32(r[0])) rem=\(s32(r[1]))")
    r = gba.callBIOS(0x08, r0: 0x10000);                check("Sqrt 65536", r[0] == 256, "\(r[0])")
    r = gba.callBIOS(0x08, r0: 99);                     check("Sqrt 99", r[0] == 9, "\(r[0])")
    r = gba.callBIOS(0x08, r0: 0xFFFF_FFFF);            check("Sqrt 0xFFFFFFFF", r[0] == 65535, "\(r[0])")
    // ArcTan: input tan(theta) in 1.14 fixed point; output angle in 1/65536 turns. tan(45 deg) = 1.0 -> 0x2000.
    r = gba.callBIOS(0x09, r0: 0x4000);                 check("ArcTan(1.0) ~ 45deg = 0x2000", abs(s32(r[0]) - 0x2000) <= 0x40, String(format: "0x%X", r[0]))
    r = gba.callBIOS(0x09, r0: 0);                      check("ArcTan(0) = 0", s32(r[0]) == 0, "\(s32(r[0]))")
    r = gba.callBIOS(0x09, r0: u(-0x4000));             check("ArcTan(-1.0) ~ -45deg", abs(s32(r[0]) + 0x2000) <= 0x40, "\(s32(r[0]))")
    // ArcTan2(x, y): full-circle angle, 0 = +x axis, counter-clockwise.
    let cases: [(Int32, Int32, Int32, String)] = [(1, 0, 0, "+x"), (0, 1, 0x4000, "+y"), (-1, 0, 0x8000, "-x"), (0, -1, 0xC000, "-y"),
                                                  (1, 1, 0x2000, "45"), (-1, 1, 0x6000, "135"), (-1, -1, 0xA000, "225"), (1, -1, 0xE000, "315")]
    for (x, y, want, name) in cases {
        r = gba.callBIOS(0x0A, r0: u(x * 0x1000), r1: u(y * 0x1000))
        check("ArcTan2 \(name)", abs(s32(r[0]) - want) <= 0x40, String(format: "got 0x%04X want 0x%04X", r[0], want))
    }
    print(failures == 0 ? "PASS: BIOS maths self-check" : "FAIL: \(failures) BIOS maths check(s)")
    return failures == 0 ? 0 : 1
}

/// Run a ROM through the real console core for N frames, optionally holding keys, and write the last frame as a PPM.
/// Time the sound hardware alone: every PSG channel on, 10 emulated seconds.
func benchAudio() -> Int32 {
    let g = GBASystem(); g.load(rom: Data(count: 0x200))
    let io: UInt32 = 0x0400_0000, b = g.bus
    b.poke16(io + 0x84, 0x80); b.poke16(io + 0x80, 0xFF77); b.poke16(io + 0x82, 2)
    b.poke16(io + 0x62, 0xF000 | 2 << 6); b.poke16(io + 0x64, 0x8000 | 1750)
    b.poke16(io + 0x68, 0xF000 | 2 << 6); b.poke16(io + 0x6C, 0x8000 | 1800)
    b.poke16(io + 0x70, 0x80); b.poke16(io + 0x72, 0x2000); b.poke16(io + 0x74, 0x8000 | 1900)
    b.poke16(io + 0x78, 0xF000); b.poke16(io + 0x7C, 0x8000 | 0x33)
    let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 2 * 4096)
    defer { scratch.deallocate() }
    let t0 = DispatchTime.now().uptimeNanoseconds
    var frames = 0
    for _ in 0..<(60 * 10) {
        b.cycles += UInt64(GBAConstants.cyclesPerFrame); b.runEvents()
        frames += b.apu.drain(into: scratch, maxFrames: 4096)
    }
    let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    print(String(format: "audio bench: 10 s of 4-channel sound (%d samples) in %.3f s = %.1f%% of one core in real time", frames, secs, secs / 10 * 100))
    return 0
}

/// What continuous rewind recording costs: time per snapshot and compressed size.
func benchRewind() -> Int32 {
    guard let rom = FileManager.default.contents(atPath: "TestROMs/jsmolka-gba-tests/nes/nes.gba") else { return 2 }
    let c = GBAConsole(rom: rom)
    let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 240 * 160); defer { fb.deallocate() }
    for _ in 0..<30 { c.runFrame(framebuffer: fb) }
    var raw = 0, packed = 0, count = 0
    var t = 0.0
    for _ in 0..<50 {
        c.runFrame(framebuffer: fb)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let state = c.saveState()!
        let z = try! (state as NSData).compressed(using: .lz4) as Data
        t += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        raw += state.count; packed += z.count; count += 1
    }
    print(String(format: "rewind snapshot: %.2f ms each, %d KB raw -> %d KB compressed; 150 snapshots = %.1f MB; one every 5 frames = %.2f%% of a frame budget",
                 t / Double(count), raw / count / 1024, packed / count / 1024, Double(packed / count * 150) / 1_048_576, t / Double(count) / 5 / (1000 / 59.7275) * 100))
    return 0
}

/// Write 16-bit stereo PCM as a WAV file and print what the sound looks like: loudness per second, peaks, clipping, DC offset.
func writeWAV(_ path: String, _ pcm: [Int16], rate: Int) {
    var d = Data()
    func u32(_ v: Int) { d.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 255) }) }
    func u16(_ v: Int) { d.append(contentsOf: (0..<2).map { UInt8((v >> (8 * $0)) & 255) }) }
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count * 2); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(pcm.count * 2)
    pcm.withUnsafeBytes { d.append(contentsOf: $0) }
    FileManager.default.createFile(atPath: path, contents: d)
    let frames = pcm.count / 2
    print(String(format: "wrote %@: %.1f s of 48 kHz stereo", (path as NSString).lastPathComponent, Double(frames) / Double(rate)))
    var line = "  loudness (RMS, % of full scale) per 2 s:"
    var sec = 0
    while (sec + 1) * rate * 2 <= frames {
        let a = sec * rate * 2 * 2, b = a + rate * 2 * 2
        let rms = (a..<b).reduce(0.0) { $0 + Double(pcm[$1]) * Double(pcm[$1]) } / Double(b - a)
        line += String(format: " %.1f", rms.squareRoot() / 327.68)
        sec += 1
    }
    print(line)
    let peak = pcm.map { abs(Int($0)) }.max() ?? 0
    let clipped = pcm.filter { $0 == 32767 || $0 == -32768 }.count
    let dc = pcm.isEmpty ? 0 : Double(pcm.reduce(0) { $0 + Int($1) }) / Double(pcm.count)
    // Silence gaps: runs of 0.25 s with nothing at all
    var silentRuns = 0, run = 0
    for i in stride(from: 0, to: pcm.count, by: 2) { if pcm[i] == 0 && pcm[i + 1] == 0 { run += 1; if run == rate / 4 { silentRuns += 1 } } else { run = 0 } }
    print(String(format: "  peak %.1f%%   clipped samples %d   DC offset %.1f   silent stretches over 0.25 s: %d", Double(peak) / 327.68, clipped, dc, silentRuns))
}

func renderFrames(path: String, frames: Int, out: String?, keys: UInt16, script: [(Int, UInt16)] = [], shots: [Int] = [], saveIn: String? = nil, saveOut: String? = nil, wav: String? = nil) -> Int32 {
    guard let rom = FileManager.default.contents(atPath: path) else { print("cannot read \(path)"); return 2 }
    let core = GBAConsole(rom: rom)
    core.setKeys(GBAKeys(rawValue: keys))
    if let saveIn, let d = FileManager.default.contents(atPath: saveIn) { core.loadSave(d); print("loaded save file (\(d.count) bytes)") }
    let audioScratch = UnsafeMutablePointer<Int16>.allocate(capacity: 2 * 4096); defer { audioScratch.deallocate() }
    var pcm = [Int16]()
    let n = core.screenWidth * core.screenHeight
    let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
    defer { fb.deallocate() }
    let t0 = DispatchTime.now().uptimeNanoseconds
    func writePPM(_ file: String) {
        var data = Data("P6\n240 160\n255\n".utf8)
        for i in 0..<n { let p = fb[i]; data.append(contentsOf: [UInt8(p >> 16 & 255), UInt8(p >> 8 & 255), UInt8(p & 255)]) }
        FileManager.default.createFile(atPath: file, contents: data)
    }
    var pending = script.sorted { $0.0 < $1.0 }
    for f in 0..<frames {
        while let next = pending.first, next.0 <= f { core.setKeys(GBAKeys(rawValue: next.1)); pending.removeFirst() }
        core.runFrame(framebuffer: fb)
        let got = core.readAudio(into: audioScratch, maxFrames: 4096)
        if wav != nil { pcm.append(contentsOf: UnsafeBufferPointer(start: audioScratch, count: got * 2)) }
        if shots.contains(f + 1), let out { writePPM("\(out)-\(f + 1).ppm") }
    }
    if let saveOut {
        if let d = core.takeSaveIfChanged() {
            FileManager.default.createFile(atPath: saveOut, contents: d)
            let used = d.filter { $0 != 0xFF }.count
            print("wrote save file: \(d.count) bytes, \(used) of them not erased")
        } else { print("no save data was written by the game") }
    }
    if let wav { writeWAV(wav, pcm, rate: 48_000) }
    let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    var crc: UInt32 = 0x811C_9DC5
    for i in 0..<n { crc = (crc ^ fb[i]) &* 0x0100_0193 }
    print(String(format: "%@: %d frames in %.2fs = %.1fx real time   frame hash %08X   pc=%08X",
                 (path as NSString).lastPathComponent, frames, secs, Double(frames) / GBAConstants.framesPerSecond / secs, crc, core.machine.cpu.r[15]))
    if let out, shots.isEmpty { writePPM(out) }
    return 0
}

/// Run a Game Boy test ROM headlessly. Blargg's ROMs report over the serial port: "Passed" or "Failed" when done.
func runGameBoyROM(path: String, maxFrames: Int, quiet: Bool, out: String? = nil) -> Int32 {
    guard let rom = FileManager.default.contents(atPath: path) else { print("cannot read \(path)"); return 2 }
    let core = GBConsole(rom: rom)
    let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 160 * 144); defer { fb.deallocate() }
    let t0 = DispatchTime.now().uptimeNanoseconds
    var frames = 0
    var verdict: Int32 = 3
    var ramVerdict = false
    while frames < maxFrames {
        core.runFrame(framebuffer: fb)
        frames += 1
        let text = String(decoding: core.serialOutput, as: UTF8.self)
        if text.contains("Passed") { verdict = 0; break }
        if text.contains("Failed") { verdict = 1; break }
        // Newer Blargg ROMs: signature DE B0 61 at A001, status at A000 (0x80 while running, 0 = passed), text from A004.
        if core.peek(0xA001) == 0xDE && core.peek(0xA002) == 0xB0 && core.peek(0xA003) == 0x61 && core.peek(0xA000) != 0x80 {
            verdict = core.peek(0xA000) == 0 ? 0 : 1; ramVerdict = true; break
        }
    }
    let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    if let out {
        var data = Data("P6\n160 144\n255\n".utf8)
        for i in 0..<(160 * 144) { let p = fb[i]; data.append(contentsOf: [UInt8(p >> 16 & 255), UInt8(p >> 8 & 255), UInt8(p & 255)]) }
        FileManager.default.createFile(atPath: out, contents: data)
    }
    var text = String(decoding: core.serialOutput, as: UTF8.self).replacingOccurrences(of: "\n\n", with: "\n")
    if ramVerdict || (core.peek(0xA001) == 0xDE && core.peek(0xA002) == 0xB0) {
        var a: UInt16 = 0xA004, bytes = [UInt8]()
        while bytes.count < 400, core.peek(a) != 0 { bytes.append(core.peek(a)); a += 1 }
        text += String(decoding: bytes, as: UTF8.self)
    }
    if !quiet { print(text) }
    print(String(format: "%@: %@ after %d frames (%.1fx real time)  pc=%04X",
                 (path as NSString).lastPathComponent, verdict == 0 ? "PASS" : verdict == 1 ? "FAIL" : "NO VERDICT", frames,
                 Double(frames) / GBConstantsFPS / max(secs, 1e-9), core.programCounter))
    return verdict
}
let GBConstantsFPS = 4_194_304.0 / 70_224.0

/// How long each frame of a ROM takes, against the 1/60 s budget. Works for GBA and Game Boy ROMs.
func frameTimes(path: String, frames: Int, script: [(Int, UInt16)]) -> Int32 {
    guard let rom = FileManager.default.contents(atPath: path) else { print("cannot read \(path)"); return 2 }
    let isGB = path.lowercased().hasSuffix(".gb") || path.lowercased().hasSuffix(".gbc")
    let core: EmulatorCore = isGB ? GBConsole(rom: rom) : GBAConsole(rom: rom)
    let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: core.screenWidth * core.screenHeight); defer { fb.deallocate() }
    let audio = UnsafeMutablePointer<Int16>.allocate(capacity: 2 * 4096); defer { audio.deallocate() }
    var stats = FrameStats(capacity: frames)
    var pending = script.sorted { $0.0 < $1.0 }
    for f in 0..<frames {
        while let next = pending.first, next.0 <= f { core.setKeys(GBAKeys(rawValue: next.1)); pending.removeFirst() }
        let t0 = DispatchTime.now().uptimeNanoseconds
        core.runFrame(framebuffer: fb)
        _ = core.readAudio(into: audio, maxFrames: 4096)
        stats.record(milliseconds: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    let fps = core.framesPerSecond
    print(String(format: "%@: %d frames   avg %.2f ms   p99 %.2f ms   worst %.2f ms   budget %.2f ms   headroom %.1fx   frames over budget: %d",
                 (path as NSString).lastPathComponent, frames, stats.average, stats.p99, stats.worst, 1000 / fps, stats.headroom(framesPerSecond: fps), stats.overruns(framesPerSecond: fps)))
    return stats.worst < 1000 / fps ? 0 : 1
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--frame-times"), let rom = args.first(where: { let l = $0.lowercased(); return l.hasSuffix(".gba") || l.hasSuffix(".gb") || l.hasSuffix(".gbc") }) {
    var frames = 600
    if let i = args.firstIndex(of: "--frames"), i + 1 < args.count, let v = Int(args[i + 1]) { frames = v }
    var script = [(Int, UInt16)]()
    if let i = args.firstIndex(of: "--script"), i + 1 < args.count {
        for part in args[i + 1].split(separator: ",") { let kv = part.split(separator: ":"); if kv.count == 2, let f = Int(kv[0]), let m = UInt16(kv[1], radix: 16) { script.append((f, m)) } }
    }
    exit(frameTimes(path: rom, frames: frames, script: script))
}
if args.contains("--gb-picture"), args.count >= 3 {
    // --gb-picture <rom> <reference.png> [--diff out.ppm]
    var diff: String? = nil
    if let i = args.firstIndex(of: "--diff"), i + 1 < args.count { diff = args[i + 1] }
    exit(gbPictureTest(rom: args[1], reference: args[2], frames: 120, diffOut: diff))
}
if args.contains("--gb-screen-hash"), let rom = args.first(where: { $0.lowercased().hasSuffix(".gb") || $0.lowercased().hasSuffix(".gbc") }), let data = FileManager.default.contents(atPath: rom) {
    // Hash of the screen after N frames, for ROMs that only report on screen. Goldens are recorded after looking at the picture.
    var frames = 300
    if let i = args.firstIndex(of: "--max-frames"), i + 1 < args.count, let v = Int(args[i + 1]) { frames = v }
    let core = GBConsole(rom: data)
    let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 160 * 144)
    for _ in 0..<frames { core.runFrame(framebuffer: fb) }
    var h: UInt32 = 0x811C_9DC5
    for i in 0..<(160 * 144) { h = (h ^ fb[i]) &* 0x0100_0193 }
    print(String(format: "%08X", h))
    exit(0)
}
if args.contains("--gb-app-sim"), let romPath = args.first(where: { $0.hasSuffix(".gb") || $0.hasSuffix(".gbc") }), let data = FileManager.default.contents(atPath: romPath) {
    // Mimics what the app's session does around the core: input every frame, rewind recording, a state save/load, a cheat list.
    let core = GBConsole(rom: data)
    let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 160 * 144)
    let rewind = RewindBuffer()
    func white() -> Bool { (0..<(160 * 144)).allSatisfy { fb[$0] == fb[0] } }
    for f in 0..<200 {
        core.setKeys([])
        rewind.record(core)
        core.runFrame(framebuffer: fb)
        if f == 90 { print("frame 90: uniform=\(white())") }
        if f == 100, let st = core.saveState() { print("saved \(st.count) bytes"); core.setCheats([]); print("load ok=\(core.loadState(st))") }
        if f == 101 { print("frame 101 after load: uniform=\(white())") }
    }
    print("frame 199: uniform=\(white())")
    exit(0)
}
if args.contains("--gb-debug"), let rom = args.first(where: { $0.lowercased().hasSuffix(".gb") || $0.lowercased().hasSuffix(".gbc") }), let data = FileManager.default.contents(atPath: rom) {
    let core = GBConsole(rom: data)
    for _ in 0..<10 { core.debugStep(20000); print(core.debugDescription) }
    exit(0)
}
if args.contains("--gb"), let rom = args.first(where: { $0.lowercased().hasSuffix(".gb") || $0.lowercased().hasSuffix(".gbc") }) {
    var frames = 3000
    if let i = args.firstIndex(of: "--max-frames"), i + 1 < args.count, let v = Int(args[i + 1]) { frames = v }
    var out: String? = nil
    if let i = args.firstIndex(of: "--out"), i + 1 < args.count { out = args[i + 1] }
    exit(runGameBoyROM(path: rom, maxFrames: frames, quiet: args.contains("--quiet"), out: out))
}
if let rom = args.first(where: { $0.lowercased().hasSuffix(".gba") }), let fi = args.firstIndex(of: "--frames"), fi + 1 < args.count, let frames = Int(args[fi + 1]) {
    var out: String? = nil
    var keys: UInt16 = 0
    if let i = args.firstIndex(of: "--out"), i + 1 < args.count { out = args[i + 1] }
    if let i = args.firstIndex(of: "--keys"), i + 1 < args.count, let v = UInt16(args[i + 1], radix: 16) { keys = v }
    // --script 300:0008,306:0000 presses/releases buttons at those frames (hex GBAKeys masks); --shots 300,600 writes <out>-<frame>.ppm
    var script = [(Int, UInt16)]()
    if let i = args.firstIndex(of: "--script"), i + 1 < args.count {
        for part in args[i + 1].split(separator: ",") { let kv = part.split(separator: ":"); if kv.count == 2, let f = Int(kv[0]), let m = UInt16(kv[1], radix: 16) { script.append((f, m)) } }
    }
    var shots = [Int]()
    if let i = args.firstIndex(of: "--shots"), i + 1 < args.count { shots = args[i + 1].split(separator: ",").compactMap { Int($0) } }
    var saveIn: String? = nil, saveOut: String? = nil, wav: String? = nil
    if let i = args.firstIndex(of: "--save-in"), i + 1 < args.count { saveIn = args[i + 1] }
    if let i = args.firstIndex(of: "--save-out"), i + 1 < args.count { saveOut = args[i + 1] }
    if let i = args.firstIndex(of: "--wav"), i + 1 < args.count { wav = args[i + 1] }
    exit(renderFrames(path: rom, frames: frames, out: out, keys: keys, script: script, shots: shots, saveIn: saveIn, saveOut: saveOut, wav: wav))
}
if args.contains("--bios-selftest") { exit(biosSelfTest()) }
if args.contains("--ppu-selftest") { exit(ppuSelfTest()) }
if args.contains("--hw-selftest") { exit(hardwareSelfTest()) }
if args.contains("--bench-rewind") { exit(benchRewind()) }
if args.contains("--bench-audio") { exit(benchAudio()) }
if args.contains("--services-selftest") { exit(servicesSelfTest()) }
if args.contains("--state-selftest") { exit(stateSelfTest()) }
if args.contains("--control-selftest") { exit(controlSelfTest()) }
if args.contains("--gb-selftest") { exit(gbSelfTest()) }
if args.contains("--link-selftest") { exit(linkSelfTest()) }
if args.contains("--apu-selftest") { exit(apuSelfTest()) }
if args.contains("--bench"), let rom = args.first(where: { $0.lowercased().hasSuffix(".gba") }) {
    exit(bench(path: rom, cycles: 600_000_000))
}
if let rom = args.first(where: { $0.lowercased().hasSuffix(".gba") }) {
    var maxCycles: UInt64 = 400_000_000
    var bios: String? = nil
    if let i = args.firstIndex(of: "--max-cycles"), i + 1 < args.count, let v = UInt64(args[i + 1]) { maxCycles = v }
    if let i = args.firstIndex(of: "--bios"), i + 1 < args.count { bios = args[i + 1] }
    exit(runROM(path: rom, maxCycles: maxCycles, biosPath: bios))
}

// Placeholder-core plumbing check.
let frames = Int(args.first ?? "") ?? 600
let core: EmulatorCore = TestPatternCore()
let n = core.screenWidth * core.screenHeight
let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
defer { fb.deallocate() }
let audio = UnsafeMutablePointer<Int16>.allocate(capacity: 4096 * 2)
defer { audio.deallocate() }
if let note = core.statusNote { print("NOTE: \(note)") }
let start = DispatchTime.now().uptimeNanoseconds
var audioFrames = 0
for _ in 0..<frames {
    core.runFrame(framebuffer: fb)
    audioFrames += core.readAudio(into: audio, maxFrames: 4096)
}
let secs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
print(String(format: "frames=%d  time=%.3fs  speed=%.1fx realtime  audioFrames=%d", frames, secs, Double(frames) / core.framesPerSecond / secs, audioFrames))
