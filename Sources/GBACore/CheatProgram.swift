import Foundation

/// The cheat-device families the app understands. `auto` looks at the text and decides.
public enum CheatFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case gameShark          // GameShark Advance / Action Replay v1-v2, decrypted: 0aaaaaaa 000000xx …
    case actionReplayV3     // Action Replay v3 / v4, decrypted
    case encryptedV12       // GameShark Advance / Action Replay v1-v2 as printed on the device (scrambled)
    case encryptedV3        // Action Replay v3 as printed on the device (scrambled)
    case codeBreaker        // CodeBreaker / GameShark SP, unencrypted: 3aaaaaaa 00xx …

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "Detect automatically"
        case .gameShark: return "GameShark Advance / Action Replay v1-v2 (raw)"
        case .actionReplayV3: return "Action Replay v3 (raw)"
        case .encryptedV12: return "GameShark Advance / Action Replay v1-v2 (encrypted)"
        case .encryptedV3: return "Action Replay v3 (encrypted)"
        case .codeBreaker: return "CodeBreaker (raw)"
        }
    }
    public var shortTitle: String {
        switch self {
        case .auto: return "Auto"
        case .gameShark: return "GameShark / AR v1-2"
        case .actionReplayV3: return "Action Replay v3"
        case .encryptedV12: return "Encrypted GS / AR v1-2"
        case .encryptedV3: return "Encrypted AR v3"
        case .codeBreaker: return "CodeBreaker"
        }
    }
}

public enum CheatCompare: Sendable { case eq, ne, lt, gt, ltu, gtu, and }

/// What a failed condition does.
public enum CheatSkip: Sendable, Equatable {
    case lines(Int)      // skip the next n code lines
    case block           // skip until an "end of conditional" code (or the end of the list)
    case disable         // stop running this cheat list for the frame
}

/// One decoded cheat instruction. `lines` is how many source lines it came from (conditionals count lines, not instructions).
public struct CheatOp: Sendable {
    public enum Kind: Sendable {
        case write(address: UInt32, value: UInt32, size: Int, count: Int)
        case pointerWrite(address: UInt32, value: UInt32, size: Int, offset: UInt32)
        case add(address: UInt32, value: UInt32, size: Int)
        case and16(address: UInt32, value: UInt16)
        case slide(address: UInt32, value: UInt32, size: Int, count: Int, valueStep: UInt32, addressStep: UInt32)
        case group(value: UInt32, addresses: [UInt32])
        case romPatch(offset: Int, value: UInt16)
        case condition(address: UInt32, value: UInt32, size: Int, compare: CheatCompare, onFail: CheatSkip)
        case buttons(UInt16, onFail: CheatSkip)
        case always(CheatSkip)
        case endBlock
        case runAll
        case stop
        case reset                 // a new cheat begins: forget any open condition from the previous one
        case noop
    }
    public var kind: Kind
    public var lines: Int
    public init(_ kind: Kind, lines: Int = 1) { self.kind = kind; self.lines = lines }
}

/// A compiled cheat list, ready to run once per frame.
public struct CheatProgram: Sendable {
    public var ops: [CheatOp]
    public var format: CheatFormat
    /// Things that were understood but can't do anything here (device buttons, hooks…), one sentence each.
    public var notes: [String]
    public init(ops: [CheatOp] = [], format: CheatFormat = .gameShark, notes: [String] = []) { self.ops = ops; self.format = format; self.notes = notes }
    public var isEmpty: Bool { ops.isEmpty }
    /// Several cheats as one list; each starts with a clean slate, so one cheat's open condition never affects the next.
    public static func join(_ programs: [CheatProgram]) -> CheatProgram {
        var out = CheatProgram(ops: [], format: programs.first?.format ?? .gameShark, notes: [])
        for p in programs { out.ops.append(CheatOp(.reset)); out.ops += p.ops; out.notes += p.notes }
        return out
    }
    public static func fromWrites(_ writes: [CheatWrite]) -> CheatProgram {
        CheatProgram(ops: writes.map { CheatOp(.write(address: $0.address, value: $0.value, size: $0.size, count: 1)) })
    }
}

/// Runs a `CheatProgram` against the machine, once per frame, after the frame has been emulated.
public final class CheatEngine {
    private var program = CheatProgram()
    private var originals = [Int: UInt16]()           // ROM halfwords replaced by patch codes, so they can be put back
    private weak var patchedBus: Bus?

    public init() {}
    public var isEmpty: Bool { program.isEmpty }

    public func set(_ writes: [CheatWrite]) { program = .fromWrites(writes) }

    /// Replace the active cheats. Patches from the previous list are undone first.
    func set(_ new: CheatProgram, bus: Bus) {
        restoreROM(bus)
        program = new
    }

    func restoreROM(_ bus: Bus) {
        if patchedBus === bus, let rom = bus.rom {
            for (offset, value) in originals where offset + 1 < bus.romSize {
                rom[offset] = UInt8(truncatingIfNeeded: value); rom[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            }
        }
        originals.removeAll()
    }

    /// Writes may reach RAM, I/O, palette, VRAM and OAM; never the BIOS, the cartridge or the save chip.
    private func allowed(_ a: UInt32) -> Bool {
        switch a >> 24 { case 0x2, 0x3, 0x4, 0x5, 0x6, 0x7: return true; default: return false }
    }

    private func read(_ bus: Bus, _ a: UInt32, _ size: Int) -> UInt32 {
        switch size {
        case 1: return UInt32(bus.peek8(a))
        case 2: return UInt32(bus.peek16(a))
        default: return bus.peek32(a)
        }
    }

    private func write(_ bus: Bus, _ a: UInt32, _ v: UInt32, _ size: Int) {
        guard allowed(a) else { return }
        switch size {
        case 1: bus.poke8(a, UInt8(truncatingIfNeeded: v))
        case 2: bus.poke16(a, UInt16(truncatingIfNeeded: v))
        default: bus.poke32(a, v)
        }
    }

    private func signed(_ v: UInt32, _ size: Int) -> Int64 {
        switch size {
        case 1: return Int64(Int8(truncatingIfNeeded: v))
        case 2: return Int64(Int16(truncatingIfNeeded: v))
        default: return Int64(Int32(truncatingIfNeeded: v))
        }
    }

    private func holds(_ c: CheatCompare, mem: UInt32, value: UInt32, size: Int) -> Bool {
        switch c {
        case .eq: return mem == value
        case .ne: return mem != value
        case .ltu: return mem < value
        case .gtu: return mem > value
        case .lt: return signed(mem, size) < signed(value, size)
        case .gt: return signed(mem, size) > signed(value, size)
        case .and: return mem & value != 0
        }
    }

    func apply(to bus: Bus) {
        if program.ops.isEmpty { return }
        if patchedBus !== bus { originals.removeAll(); patchedBus = bus }
        var skipLines = 0
        var skipBlock = false
        var halted = false

        for op in program.ops {
            // These always run, so a conditional block can be closed and a "run everything" code can override it.
            switch op.kind {
            case .reset: halted = false; skipBlock = false; skipLines = 0; continue
            case .stop: halted = true; continue
            case .endBlock, .runAll: if !halted { skipBlock = false; skipLines = 0 }; continue
            default: break
            }
            if halted || skipBlock { continue }
            if skipLines > 0 { skipLines -= op.lines; continue }

            func fail(_ s: CheatSkip) -> Bool {          // returns true when the whole list must stop
                switch s {
                case .lines(let n): skipLines = n
                case .block: skipBlock = true
                case .disable: return true
                }
                return false
            }

            switch op.kind {
            case .write(let a, let v, let size, let count):
                var address = a
                for _ in 0..<count { write(bus, address, v, size); address &+= UInt32(size) }
            case .pointerWrite(let a, let v, let size, let offset):
                let target = bus.peek32(a) &+ offset
                write(bus, target, v, size)
            case .add(let a, let v, let size):
                write(bus, a, read(bus, a, size) &+ v, size)
            case .and16(let a, let v):
                write(bus, a, read(bus, a, 2) & UInt32(v), 2)
            case .slide(let a, let v, let size, let count, let vs, let ass):
                var address = a, value = v
                for _ in 0..<count { write(bus, address, value, size); address &+= ass; value &+= vs }
            case .group(let v, let addresses):
                for a in addresses { write(bus, a, v, 4) }
            case .romPatch(let offset, let v):
                if let rom = bus.rom, offset >= 0, offset & 1 == 0, offset + 1 < bus.romSize {
                    if originals[offset] == nil { originals[offset] = UInt16(rom[offset]) | UInt16(rom[offset + 1]) << 8 }
                    rom[offset] = UInt8(truncatingIfNeeded: v); rom[offset + 1] = UInt8(truncatingIfNeeded: v >> 8)
                }
            case .condition(let a, let v, let size, let c, let onFail):
                if !holds(c, mem: read(bus, a, size), value: v, size: size), fail(onFail) { halted = true }
            case .buttons(let expected, let onFail):
                if bus.keyInput & 0x03FF != expected, fail(onFail) { halted = true }
            case .always(let s):
                if fail(s) { halted = true }
            case .endBlock, .runAll, .stop, .reset, .noop: break
            }
        }
    }
}
