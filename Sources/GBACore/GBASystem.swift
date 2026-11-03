import Foundation

/// A GBA: bus + CPU (video, audio, timers and DMA join in later milestones).
public final class GBASystem {
    public let bus = Bus()
    public let cpu: ARM7TDMI
    /// Identifies the loaded ROM so a state can't be loaded into a different game.
    public private(set) var romHash: UInt32 = 0

    public init() { cpu = ARM7TDMI(bus: bus) }

    public func load(rom: Data, bios: Data? = nil) {
        bus.loadROM(rom)
        romHash = GBASystem.fnv(rom)
        if let bios { bus.loadBIOS(bios); cpu.useHLEBIOS = false } else { cpu.useHLEBIOS = true }
        cpu.resetToCartridgeEntry()
        bus.cycles = 0
        bus.resetEvents()
        // The real BIOS leaves the BG2/BG3 matrices as identity before the cartridge starts; bitmap modes depend on it.
        for o in [0x20, 0x26, 0x30, 0x36] { st16(bus.io, o, 0x100) }
    }

    /// Invoke a native BIOS service directly (for self-checks): sets r0-r3, runs it, returns r0-r3.
    public func callBIOS(_ number: UInt32, r0: UInt32 = 0, r1: UInt32 = 0, r2: UInt32 = 0, r3: UInt32 = 0) -> [UInt32] {
        cpu.r[0] = r0; cpu.r[1] = r1; cpu.r[2] = r2; cpu.r[3] = r3
        cpu.hleSWI(number)
        return [cpu.r[0], cpu.r[1], cpu.r[2], cpu.r[3]]
    }

    /// Run until at least `cycles` bus cycles have elapsed. Returns the number of instructions executed.
    @discardableResult
    public func run(cycles: UInt64) -> UInt64 {
        let target = bus.cycles &+ cycles
        let before = cpu.instructionCount
        while bus.cycles < target { cpu.step() }
        return cpu.instructionCount &- before
    }
}

// MARK: save states
extension GBASystem {
    static func fnv(_ data: Data) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        data.withUnsafeBytes { for b in $0 { h = (h ^ UInt32(b)) &* 0x0100_0193 } }
        return h
    }

    private static let stateVersion: UInt32 = 1

    /// Everything needed to resume exactly where the machine is now. Take it between frames.
    public func saveState() -> Data {
        var w = StateWriter()
        w.tag("SGBS"); w.u32(GBASystem.stateVersion); w.u32(romHash)
        cpu.save(&w); bus.save(&w)
        w.tag("END0")
        return Data(w.bytes)
    }

    /// Restore a state made by `saveState()` for the same ROM. On any problem the machine is left as it was and false is returned.
    @discardableResult
    public func loadState(_ data: Data) -> Bool {
        let backup = saveState()
        func attempt(_ d: Data) -> Bool {
            var r = StateReader(d)
            r.tag("SGBS")
            guard r.u32() == GBASystem.stateVersion, r.u32() == romHash else { return false }
            cpu.load(&r); bus.load(&r)
            r.tag("END0")
            return !r.failed && r.atEnd
        }
        if attempt(data) { return true }
        _ = attempt(backup)
        return false
    }
}
