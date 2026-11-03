import Foundation

/// The Game Boy / Game Boy Color core behind the app-facing `EmulatorCore` interface.
public final class GBConsole: EmulatorCore {
    private var system: GBSystem
    private let rom: Data
    private let romHash: UInt32
    private var cheatWrites = [CheatWrite]()
    private var linkAttached: SerialLink?

    /// A Game Boy Color game runs in colour mode; everything else runs as the original Game Boy.
    public let isColor: Bool
    public let title: String
    private let note: String?

    public var statusNote: String? { note }
    public var screenWidth: Int { 160 }
    public var screenHeight: Int { 144 }
    public var framesPerSecond: Double { 4_194_304.0 / 70_224.0 }
    public var audioSampleRate: Int { 48_000 }

    public init(rom: Data) {
        self.rom = rom
        let c = GBCartridge(rom: rom)
        isColor = c.supportsColor
        title = c.title
        note = c.unsupportedReason
        romHash = GBConsole.fnv(rom)
        system = GBSystem(cart: c, color: c.supportsColor)
    }

    private static func fnv(_ data: Data) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        data.withUnsafeBytes { for b in $0 { h = (h ^ UInt32(b)) &* 0x0100_0193 } }
        return h
    }

    /// Everything the harness and tests need to look inside.
    var machine: GBSystem { system }
    /// Bytes the game has sent out of the serial port so far.
    public var serialOutput: [UInt8] { system.serialLog }
    public var programCounter: UInt16 { system.pc }
    public var cycleCount: UInt64 { system.dots }
    public var lcdIsOn: Bool { system.ppu.lcdOn }
    /// Read a byte the way the CPU would, without spending time (for tools).
    public func peek(_ address: UInt16) -> UInt8 { system.readRaw(address) }
    /// Write a byte through the memory map without spending time (for tools and tests).
    public func poke(_ address: UInt16, _ value: UInt8) { system.write(address, value) }
    /// Let `machineCycles` CPU cycles pass with the CPU idle (timers, video, sound and DMA keep running).
    public func idle(_ machineCycles: Int) { for _ in 0..<machineCycles { system.tick() } }
    public var interruptFlags: UInt8 { system.ifr }
    public func clearInterruptFlags() { system.ifr = 0 }
    /// One instruction, for debugging.
    public func debugStep(_ n: Int) { for _ in 0..<n { system.step() } }
    public var debugDescription: String { "pc=\(String(system.pc, radix: 16)) dots=\(system.dots) next=\(system.nextEvent) ppuNext=\(system.ppu.nextEvent) ly=\(system.ppu.ly) mode=\(system.ppu.mode) lcdc=\(String(system.ppu.lcdc, radix: 16)) ime=\(system.ime) ie=\(system.ie) if=\(system.ifr) halted=\(system.halted)" }
    /// The 2-bit shade of each pixel of the last frame (original Game Boy mode only).
    public func shadeIndices() -> [UInt8] { Array(UnsafeBufferPointer(start: system.ppu.shades, count: 160 * 144)) }

    public func reset() {
        let old = system.cart
        let kept = old.saveData()                                   // a reset restarts the game, not the cartridge's battery memory
        let wasDirty = old.dirty
        let fresh = GBCartridge(rom: rom)
        if let kept { fresh.loadSave(kept) }
        if wasDirty { fresh.markDirty() }
        system = GBSystem(cart: fresh, color: fresh.supportsColor)
        system.link = linkAttached                          // a reset doesn't unplug the cable
    }

    public func setKeys(_ keys: GBAKeys) {
        system.setKeys(a: keys.contains(.a), b: keys.contains(.b), select: keys.contains(.select), start: keys.contains(.start),
                       right: keys.contains(.right), left: keys.contains(.left), up: keys.contains(.up), down: keys.contains(.down))
    }

    public func runFrame(framebuffer: UnsafeMutablePointer<UInt32>) {
        let s = system
        let start = s.dots
        s.ppu.frameReady = false
        while !s.ppu.frameReady {
            s.step()
            if !s.ppu.lcdOn && s.dots &- start >= 70_224 { break }          // with the screen off there are no frames, so keep time anyway
        }
        applyCheats()
        framebuffer.update(from: s.ppu.frame, count: 160 * 144)
    }

    public func readAudio(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int {
        system.apu.drain(into: buffer, maxFrames: maxFrames)
    }

    // MARK: saves, states, cheats
    public func loadSave(_ data: Data) { system.cart.loadSave(data) }
    public func takeSaveIfChanged() -> Data? { system.cart.takeSave() }

    public func setCheats(_ writes: [CheatWrite]) { cheatWrites = writes }
    public func attachLink(_ link: SerialLink?) { linkAttached = link; system.link = link }

    private func applyCheats() {
        for w in cheatWrites where w.size == 1 {
            let a = UInt16(truncatingIfNeeded: w.address)
            if (a >= 0xA000 && a < 0xE000) || (a >= 0xFF80 && a < 0xFFFF) { system.write(a, UInt8(truncatingIfNeeded: w.value)) }
        }
    }

    public func saveState() -> Data? {
        var w = StateWriter()
        w.tag("SGBG"); w.u32(1); w.u32(romHash)
        system.save(&w)
        w.tag("END0")
        return Data(w.bytes)
    }

    public func loadState(_ data: Data) -> Bool {
        guard let backup = saveState() else { return false }
        func attempt(_ d: Data) -> Bool {
            var r = StateReader(d)
            r.tag("SGBG")
            guard r.u32() == 1, r.u32() == romHash else { return false }
            system.load(&r)
            r.tag("END0")
            return !r.failed && r.atEnd
        }
        if attempt(data) { return true }
        _ = attempt(backup)
        return false
    }
}
