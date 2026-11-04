import Foundation

/// The real console core: a GBASystem driven one video frame at a time behind the app-facing `EmulatorCore` interface.
public final class GBAConsole: EmulatorCore {
    private var system = GBASystem()
    private let rom: Data
    private let bios: Data?
    private var frameTarget: UInt64 = 0
    private let cheats = CheatEngine()
    private var linkAttached: SerialLink?

    public var statusNote: String? { nil }
    public var screenWidth: Int { GBAConstants.screenWidth }
    public var screenHeight: Int { GBAConstants.screenHeight }
    public var framesPerSecond: Double { GBAConstants.framesPerSecond }
    public var audioSampleRate: Int { 48_000 }

    /// The machine underneath, for the harness and diagnostics.
    public var machine: GBASystem { system }

    public init(rom: Data, bios: Data? = nil) {
        self.rom = rom
        self.bios = bios
        reset()
    }

    public func reset() {
        let kept = system.bus.cart.saveData()                 // a reset restarts the game, not the cartridge's memory
        let wasDirty = system.bus.cart.dirty
        system = GBASystem()
        system.load(rom: rom, bios: bios)
        system.bus.link = linkAttached                // a reset doesn't unplug the cable
        frameTarget = UInt64(160 * 1232)              // a frame ends as VBlank begins, so input is sampled as late as possible
        if let kept { system.bus.cart.loadSave(kept); if wasDirty { system.bus.cart.markDirty() } }
    }

    public func setCheats(_ writes: [CheatWrite]) { cheats.set(.fromWrites(writes), bus: system.bus) }
    public func setCheatProgram(_ program: CheatProgram) { cheats.set(program, bus: system.bus) }
    public func attachLink(_ link: SerialLink?) { linkAttached = link; system.bus.link = link }

    public func saveState() -> Data? { system.saveState() }

    public func loadState(_ data: Data) -> Bool {
        guard system.loadState(data) else { return false }
        // States are taken between frames: the next frame ends at the first boundary after the restored cycle count.
        let first = UInt64(160 * 1232), frame = UInt64(GBAConstants.cyclesPerFrame)
        let c = system.bus.cycles
        frameTarget = c < first ? first : ((c - first) / frame + 1) * frame + first
        return true
    }

    public func loadSave(_ data: Data) { system.bus.cart.loadSave(data) }
    public func takeSaveIfChanged() -> Data? { system.bus.cart.takeSave() }

    public func setKeys(_ keys: GBAKeys) {
        system.bus.keyInput = ~keys.rawValue & 0x03FF
        system.bus.checkKeypadIRQ()
    }

    public func runFrame(framebuffer: UnsafeMutablePointer<UInt32>) {
        let bus = system.bus
        while bus.cycles < frameTarget { system.cpu.step() }
        frameTarget += UInt64(GBAConstants.cyclesPerFrame)
        if !cheats.isEmpty { cheats.apply(to: bus) }
        framebuffer.update(from: bus.ppu.frame, count: GBAConstants.screenWidth * GBAConstants.screenHeight)
    }

    public func readAudio(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int {
        system.bus.apu.drain(into: buffer, maxFrames: maxFrames)
    }
}
