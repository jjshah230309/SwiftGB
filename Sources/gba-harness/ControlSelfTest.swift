import Foundation
import GBACore

// Input bindings (keyboard + controller, rebinding, persistence) and cheat codes.

func controlSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name)" + (detail.isEmpty ? "" : ": \(detail)"))
    }

    // --- bindings -----------------------------------------------------------------------------
    var b = InputBindings.defaults
    check("Z is A by default", b.actions(keys: [6], pad: []) == [.a])
    check("held keys combine", b.actions(keys: [6, 126, 123], pad: []) == [.a, .up, .left])
    check("both Start keys work", b.actions(keys: [76], pad: []) == [.start] && b.actions(keys: [36], pad: []) == [.start])
    check("Tab is fast-forward, W is rewind", b.actions(keys: [48, 13], pad: []) == [.fastForward, .rewind])
    check("controller east button is A, south is B (console layout)", b.actions(keys: [], pad: [.buttonB]) == [.a] && b.actions(keys: [], pad: [.buttonA]) == [.b])
    check("keyboard and controller combine", b.actions(keys: [6], pad: [.dpadLeft, .rightShoulder]) == [.a, .left, .r])
    check("nothing held, nothing pressed", b.actions(keys: [], pad: []).isEmpty)
    check("actions become console keys; hotkeys don't", InputBindings.gbaKeys(for: [.a, .start, .fastForward]) == [.a, .start])

    b.bind(key: 6, to: .b)
    check("rebinding steals the key from its old action", b.actions(keys: [6], pad: []) == [.b] && !(b.keyboard[.a] ?? []).contains(6))
    check("the old binding of the target stays too", b.actions(keys: [7], pad: []) == [.b])
    b.bind(key: 8, to: .a, replacing: nil)
    b.bind(key: 9, to: .a, replacing: 8)
    check("replacing swaps one key for another", b.keyboard[.a] == [9])
    b.bind(button: .buttonX, to: .l)
    check("controller rebinding", b.actions(keys: [], pad: [.buttonX]) == [.l])
    b.bind(button: .buttonB, to: .select)
    check("controller binding steals too", b.actions(keys: [], pad: [.buttonB]) == [.select])
    b.clearKeys(for: .start)
    check("clearing removes keyboard bindings only", b.actions(keys: [36], pad: []).isEmpty && b.actions(keys: [], pad: [.buttonMenu]) == [.start])

    let data = b.encoded()
    check("bindings survive a save and load", InputBindings.decode(data) == b)
    check("garbage decodes to nil, not a crash", InputBindings.decode(Data([1, 2, 3])) == nil && InputBindings.decode(nil) == nil)
    var seen = Set<UInt16>()
    var clash = false
    for (action, codes) in InputBindings.defaults.keyboard { for c in codes { if !seen.insert(c).inserted { clash = true; print("    clash on \(c) at \(action)") } } }
    check("default keys don't clash", !clash)
    check("key names", KeyNames.name(6) == "Z" && KeyNames.name(126) == "↑" && KeyNames.name(200) == "Key 200")

    // --- cheats -------------------------------------------------------------------------------
    func parsed(_ s: String) -> [CheatWrite]? { if case .success(let w) = CheatParser.parse(s) { return w } else { return nil } }
    func failure(_ s: String) -> CheatParseError? { if case .failure(let e) = CheatParser.parse(s) { return e } else { return nil } }

    check("8-bit write parses", parsed("03007E00 000000FF") == [CheatWrite(address: 0x0300_7E00, value: 0xFF, size: 1)])
    check("16-bit write parses", parsed("13007E10 0000ABCD") == [CheatWrite(address: 0x0300_7E10, value: 0xABCD, size: 2)])
    check("32-bit write parses", parsed("23007E20 DEADBEEF") == [CheatWrite(address: 0x0300_7E20, value: 0xDEAD_BEEF, size: 4)])
    check("lowercase, spacing and blank lines are tolerated", parsed("\n 03007e00   000000ff \n\n13007e10 0000abcd\n")?.count == 2)
    check("run-together digits are accepted", parsed("03007E00000000FF")?.count == 1)
    check("too short is an error naming the line", failure("03007E00 000000FF\n03007E00 00FF")?.line == 2)
    check("non-hex is an error", failure("0300ZE00 000000FF") != nil)
    check("an unsupported type is explained, not guessed", failure("83007E00 000000FF")?.message.contains("isn't supported") == true)
    check("an 8-bit value out of range is refused", failure("03007E00 00000100") != nil)
    check("a 16-bit value out of range is refused", failure("13007E00 00010000") != nil)
    check("an empty list is fine and does nothing", parsed("")?.isEmpty == true)

    func gbParsed(_ s: String) -> [CheatWrite]? { if case .success(let w) = CheatParser.parse(s, gameBoy: true) { return w } else { return nil } }
    func gbFailure(_ s: String) -> CheatParseError? { if case .failure(let e) = CheatParser.parse(s, gameBoy: true) { return e } else { return nil } }
    check("Game Boy: GameShark code 01FFD8C0 writes FF to C0D8", gbParsed("01FFD8C0") == [CheatWrite(address: 0xC0D8, value: 0xFF, size: 1)])
    check("Game Boy: dashes, spaces and case are tolerated", gbParsed("01ff-d8c0\n 0142 34 DF")?.count == 2)
    check("Game Boy: high RAM is allowed", gbParsed("019980FF") == [CheatWrite(address: 0xFF80, value: 0x99, size: 1)])
    check("Game Boy: other code types are explained", gbFailure("91FFD8C0")?.message.contains("isn't supported") == true)
    check("Game Boy: ROM and register addresses are refused", gbFailure("01FF0040") != nil && gbFailure("01FF00FF") != nil)
    check("Game Boy: wrong length is refused", gbFailure("01FFD8") != nil)

    var rom = Data(count: 0x1000)
    rom.replaceSubrange(0..<4, with: [0xFE, 0xFF, 0xFF, 0xEA])
    let c = GBAConsole(rom: rom)
    let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 240 * 160); defer { fb.deallocate() }
    let bus = c.machine.bus
    c.setCheats(parsed("03007E00 000000FF\n13007E10 0000ABCD\n23007E20 DEADBEEF\n08000000 00000012\n04000000 00000000")!)
    c.runFrame(framebuffer: fb)
    check("cheats are written into RAM every frame", bus.peek8(0x0300_7E00) == 0xFF && bus.peek16(0x0300_7E10) == 0xABCD && bus.peek32(0x0300_7E20) == 0xDEAD_BEEF)
    bus.poke8(0x0300_7E00, 0)
    c.runFrame(framebuffer: fb)
    check("…and written again after the game overwrites them", bus.peek8(0x0300_7E00) == 0xFF)
    check("cheats can't touch the ROM or hardware registers", bus.peek8(0x0800_0000) == 0xFE && bus.peek16(0x0400_0000) == 0)
    c.setCheats([])
    bus.poke8(0x0300_7E00, 0); c.runFrame(framebuffer: fb)
    check("clearing cheats stops them", bus.peek8(0x0300_7E00) == 0)

    // --- speed ladder ---------------------------------------------------------------------------
    check("speed ladder doubles from 1x up to unlimited", EmulationSpeed.ladder == [0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256, .infinity])
    check("fast-forward choices are powers of two then unlimited", EmulationSpeed.fastForwardChoices == [2, 4, 8, 16, 32, 64, 128, 256, .infinity])
    check("every fast-forward choice is 2^n", EmulationSpeed.fastForwardChoices.dropLast().allSatisfy { log2($0) == log2($0).rounded() })
    check("labels", EmulationSpeed.label(0.5) == "½×" && EmulationSpeed.label(8) == "8×" && EmulationSpeed.label(.infinity) == "Unlimited")
    check("faster steps up the ladder and stops at unlimited", EmulationSpeed.faster(than: 1) == 2 && EmulationSpeed.faster(than: 256) == .infinity && EmulationSpeed.faster(than: .infinity) == .infinity)
    check("slower steps down and stops at half speed", EmulationSpeed.slower(than: 8) == 4 && EmulationSpeed.slower(than: .infinity) == 256 && EmulationSpeed.slower(than: 0.5) == 0.5)
    check("frame pacing: 4x makes each frame a quarter as long", abs(EmulationSpeed.frameInterval(framesPerSecond: 60, speed: 4)! - 1.0 / 240) < 1e-12)
    check("frame pacing: unlimited has no interval at all", EmulationSpeed.frameInterval(framesPerSecond: 60, speed: .infinity) == nil)
    check("unlimited survives being stored as a number", EmulationSpeed.decode(EmulationSpeed.encode(.infinity), fallback: 4) == .infinity && EmulationSpeed.decode(EmulationSpeed.encode(16), fallback: 4) == 16)
    check("a missing or nonsense stored speed falls back", EmulationSpeed.decode(nil, fallback: 4) == 4 && EmulationSpeed.decode(0, fallback: 4) == 4)

    // --- autosave schedule ----------------------------------------------------------------------
    check("autosave: 5 minutes is 300 seconds", AutosaveSchedule(enabled: true, value: 5, unit: .minutes).interval == 300)
    check("autosave: seconds, minutes and hours", AutosaveSchedule(value: 30, unit: .seconds).interval == 30 && AutosaveSchedule(value: 2, unit: .hours).interval == 7200)
    check("autosave: off has no interval", AutosaveSchedule(enabled: false, value: 5, unit: .minutes).interval == nil)
    check("autosave: values are clamped to 1...999", AutosaveSchedule(value: 0).value == 1 && AutosaveSchedule(value: 100000).value == 999 && AutosaveSchedule(value: -4).value == 1)
    check("autosave: summary wording", AutosaveSchedule(value: 1, unit: .hours).summary == "every 1 hour" && AutosaveSchedule(value: 15, unit: .seconds).summary == "every 15 seconds" && AutosaveSchedule(enabled: false).summary == "Off")
    let schedule = AutosaveSchedule(enabled: true, value: 90, unit: .seconds)
    check("autosave: survives being stored", AutosaveSchedule.decode(schedule.encoded()) == schedule)
    check("autosave: stored junk decodes to nil", AutosaveSchedule.decode(Data([0xFF])) == nil)
    check("autosave: a hand-edited out-of-range value is re-clamped", AutosaveSchedule.decode(Data(#"{"enabled":true,"value":0,"unit":"minutes"}"#.utf8))?.value == 1)

    // --- frame statistics -----------------------------------------------------------------------
    var st = FrameStats(capacity: 100)
    for i in 1...100 { st.record(milliseconds: Double(i)) }
    check("stats: average of 1...100 ms is 50.5", abs(st.average - 50.5) < 1e-9)
    check("stats: worst and 99th percentile", st.worst == 100 && st.p99 == 99, "worst \(st.worst) p99 \(st.p99)")
    check("stats: headroom is budget / average (16.67 ms / 50.5 ms at 60 fps)", abs(st.headroom(framesPerSecond: 60) - (1000.0 / 60) / 50.5) < 1e-9)
    check("stats: 84 of the 100 frames overran a 60 fps budget", st.overruns(framesPerSecond: 60) == 84)
    var ring = FrameStats(capacity: 10)
    for i in 1...25 { ring.record(milliseconds: Double(i)) }
    check("stats: only the most recent frames count (16...25 → 20.5)", ring.count == 10 && abs(ring.average - 20.5) < 1e-9)
    ring.reset()
    check("stats: reset and empty are all zeros", ring.count == 0 && ring.average == 0 && ring.worst == 0 && ring.p99 == 0 && ring.headroom(framesPerSecond: 60) == 0)
    var steady = FrameStats(capacity: 60)
    for _ in 0..<60 { steady.record(milliseconds: 4) }
    check("stats: a steady 4 ms frame has 4.2x headroom at 60 fps and no overruns", abs(steady.headroom(framesPerSecond: 60) - 1000.0 / 60 / 4) < 1e-9 && steady.overruns(framesPerSecond: 60) == 0)

    // --- grid navigation ------------------------------------------------------------------------
    func nav(_ i: Int?, _ d: NavInput, count: Int = 10, columns: Int = 4) -> Int? { GridNavigation.next(from: i, direction: d, count: count, columns: columns) }
    check("grid: right and left move one card", nav(0, .right) == 1 && nav(5, .left) == 4)
    check("grid: the row ends stop movement", nav(3, .right) == 3 && nav(4, .left) == 4 && nav(0, .left) == 0)
    check("grid: up and down move a whole row", nav(1, .down) == 5 && nav(5, .up) == 1 && nav(4, .up) == 0)
    check("grid: the last item has nothing to its right", nav(9, .right) == 9)
    check("grid: down into a shorter last row lands on its last card", nav(6, .down) == 9 && nav(7, .down) == 9 && nav(5, .down) == 9)
    check("grid: the top and bottom rows stop movement", nav(2, .up) == 2 && nav(8, .down) == 8 && nav(9, .down) == 9)
    check("grid: nothing focused yet starts at the first card", nav(nil, .down) == 0 && nav(99, .left) == 0 && nav(-1, .up) == 0)
    check("grid: empty or zero-column grids have nowhere to go", nav(0, .right, count: 0) == nil && nav(0, .right, columns: 0) == nil)
    check("grid: confirm and back don't move", nav(6, .confirm) == 6 && nav(6, .back) == 6)
    check("grid: a single column moves only up and down", nav(2, .down, count: 5, columns: 1) == 3 && nav(2, .right, count: 5, columns: 1) == 2)
    check("grid: every card of a 10-card, 4-column grid can be reached from the first with the four directions", {
        var seen: Set<Int> = [0], frontier = [0]
        while let i = frontier.popLast() {
            for d in [NavInput.left, .right, .up, .down] { if let j = nav(i, d), seen.insert(j).inserted { frontier.append(j) } }
        }
        return seen.count == 10
    }())
    check("grid: column count follows the width like an adaptive grid", GridNavigation.columns(width: 1000, minimumItem: 270, spacing: 30) == 3 && GridNavigation.columns(width: 270, minimumItem: 270, spacing: 30) == 1 && GridNavigation.columns(width: 100, minimumItem: 270, spacing: 30) == 1 && GridNavigation.columns(width: 1230, minimumItem: 270, spacing: 30) == 4)

    print(failures == 0 ? "PASS: controls and cheats self-check" : "FAIL: \(failures) check(s)")
    return failures == 0 ? 0 : 1
}
