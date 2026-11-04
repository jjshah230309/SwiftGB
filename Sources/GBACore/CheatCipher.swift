import Foundation

/// The encryption on GameShark Advance and Action Replay codes: a 32-round cipher over each (first word, second word) pair,
/// keyed by four 32-bit seeds. Written from GBATEK's description of the encryption; decryption is its exact inverse.
/// A decrypted line `DEADFACE 0000xxyy` changes the seeds for every line after it.
public struct CheatCipher {
    public enum Generation: Sendable {
        case v1v2           // GameShark Advance, Action Replay v1 and v2
        case v3             // Action Replay v3
    }

    public let generation: Generation
    public private(set) var seeds: [UInt32] = [0, 0, 0, 0]
    private static let delta: UInt32 = 0x9E37_79B9

    public init(_ generation: Generation) {
        self.generation = generation
        changeSeeds(0)                                   // argument 0 gives the device's power-on keys
    }

    private var table1: [UInt8] { generation == .v3 ? CheatTables.v3Table1 : CheatTables.v1Table1 }
    private var table2: [UInt8] { generation == .v3 ? CheatTables.v3Table2 : CheatTables.v1Table2 }

    /// The four keys that follow a `DEADFACE 0000xxyy` code: seed i is made of four bytes, each the sum of one entry of each table.
    public mutating func changeSeeds(_ argument: UInt16) {
        let upper = Int(argument >> 8), lower = Int(argument & 0xFF)
        let t1 = table1, t2 = table2
        for i in 0..<4 {
            var s: UInt32 = 0
            for j in 0..<4 { s = (s << 8) | UInt32((Int(t1[(j + upper) & 0xFF]) + Int(t2[(lower + i) & 0xFF])) & 0xFF) }
            seeds[i] = s
        }
    }

    /// One line as printed on the device -> the code it stands for.
    public mutating func decrypt(_ line: (UInt32, UInt32)) -> (UInt32, UInt32) {
        var a = line.0, v = line.1
        var rolling: UInt32 = 0xC6EF_3720
        for _ in 0..<32 {
            v = v &- ((((a << 4) &+ seeds[2]) ^ (a &+ rolling)) ^ ((a >> 5) &+ seeds[3]))
            a = a &- ((((v << 4) &+ seeds[0]) ^ (v &+ rolling)) ^ ((v >> 5) &+ seeds[1]))
            rolling = rolling &- CheatCipher.delta
        }
        if a == 0xDEAD_FACE { changeSeeds(UInt16(truncatingIfNeeded: v)) }
        return (a, v)
    }

    /// The reverse, used by tests (and handy for anyone making codes).
    public mutating func encrypt(_ code: (UInt32, UInt32)) -> (UInt32, UInt32) {
        var a = code.0, v = code.1
        var rolling: UInt32 = 0
        for _ in 0..<32 {
            rolling = rolling &+ CheatCipher.delta
            a = a &+ ((((v << 4) &+ seeds[0]) ^ (v &+ rolling)) ^ ((v >> 5) &+ seeds[1]))
            v = v &+ ((((a << 4) &+ seeds[2]) ^ (a &+ rolling)) ^ ((a >> 5) &+ seeds[3]))
        }
        if code.0 == 0xDEAD_FACE { changeSeeds(UInt16(truncatingIfNeeded: code.1)) }
        return (a, v)
    }
}
