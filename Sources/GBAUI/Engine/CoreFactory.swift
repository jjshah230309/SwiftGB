import Foundation
import GBACore

/// The single place that decides which emulator core runs a ROM.
public enum CoreFactory {
    /// True only while the app is using the test-pattern stand-in (never, now that the console core exists).
    public static let isPlaceholder = false

    /// What the console core can't do yet, shown in the library and settings so it's never a surprise.
    public static let limitations: String? = "Save states, rewind, cheats, controller support and key remapping are available. Timing is approximate, so some games may glitch."

    public static func makeCore(rom: Data, system: GameSystem) -> EmulatorCore {
        system.isGameBoy ? GBConsole(rom: rom) : GBAConsole(rom: rom)
    }
}
