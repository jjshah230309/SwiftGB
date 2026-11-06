import Foundation

// The boundary between the emulator core and everything else (UI, renderer, audio, harness).
// A real console core and the placeholder test-pattern core both implement this.

/// GBA button state. Bit layout matches the hardware KEYINPUT register, but active-HIGH here (1 = pressed).
public struct GBAKeys: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let a      = GBAKeys(rawValue: 1 << 0)
    public static let b      = GBAKeys(rawValue: 1 << 1)
    public static let select = GBAKeys(rawValue: 1 << 2)
    public static let start  = GBAKeys(rawValue: 1 << 3)
    public static let right  = GBAKeys(rawValue: 1 << 4)
    public static let left   = GBAKeys(rawValue: 1 << 5)
    public static let up     = GBAKeys(rawValue: 1 << 6)
    public static let down   = GBAKeys(rawValue: 1 << 7)
    public static let r      = GBAKeys(rawValue: 1 << 8)
    public static let l      = GBAKeys(rawValue: 1 << 9)
}

/// An emulated machine. Single-owner: all calls must come from one thread at a time.
public protocol EmulatorCore: AnyObject {
    /// Human-readable status, shown in the UI so a placeholder core is never mistaken for real emulation.
    var statusNote: String? { get }
    var screenWidth: Int { get }
    var screenHeight: Int { get }
    /// Native video refresh rate (GBA: 16,777,216 / 280,896 ≈ 59.7275 Hz).
    var framesPerSecond: Double { get }
    var audioSampleRate: Int { get }

    func reset()
    func setKeys(_ keys: GBAKeys)
    /// Run exactly one video frame; write `screenWidth * screenHeight` pixels, 0xAARRGGBB, row-major.
    func runFrame(framebuffer: UnsafeMutablePointer<UInt32>)
    /// Drain audio produced so far as interleaved stereo Int16. Returns the number of stereo frames written.
    func readAudio(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int

    /// Give the cartridge its previously stored save data. Call before the first frame.
    func loadSave(_ data: Data)
    /// The save data if it has changed since the last call, otherwise nil.
    func takeSaveIfChanged() -> Data?

    /// Snapshot of the whole machine, or nil if this core can't. Take it between frames.
    func saveState() -> Data?
    /// Restore a snapshot from `saveState()`. Returns false (and changes nothing) if it doesn't fit.
    func loadState(_ data: Data) -> Bool

    /// Replace the active cheats with these writes (applied once per frame).
    func setCheats(_ writes: [CheatWrite])
    /// Replace the active cheats with a compiled list from any supported cheat device (Game Boy Advance only).
    func setCheatProgram(_ program: CheatProgram)

    /// Plug a link cable in (or with nil, unplug it).
    func attachLink(_ link: SerialLink?)
    /// Draw the picture on the GPU instead of the CPU (Game Boy Advance only). Returns false if that isn't possible.
    @discardableResult func setPictureOnGPU(_ on: Bool) -> Bool
}

public extension EmulatorCore {
    func loadSave(_ data: Data) {}
    func takeSaveIfChanged() -> Data? { nil }
    func saveState() -> Data? { nil }
    func loadState(_ data: Data) -> Bool { false }
    func setCheats(_ writes: [CheatWrite]) {}
    func setCheatProgram(_ program: CheatProgram) {}
    func attachLink(_ link: SerialLink?) {}
    @discardableResult func setPictureOnGPU(_ on: Bool) -> Bool { false }
}

public enum GBAConstants {
    public static let screenWidth = 240
    public static let screenHeight = 160
    public static let cpuHz = 16_777_216
    public static let cyclesPerFrame = 280_896            // 1232 cycles x 228 lines
    public static let framesPerSecond = Double(cpuHz) / Double(cyclesPerFrame)
}
