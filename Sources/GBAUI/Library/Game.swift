import Foundation

/// Which console a game is for, decided by its file type.
public enum GameSystem: String, Codable, Sendable {
    case gba, gb, gbc

    public var label: String { rawValue.uppercased() }
    public var isGameBoy: Bool { self != .gba }

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "gba": self = .gba
        case "gb": self = .gb
        case "gbc": self = .gbc
        default: return nil
        }
    }
}

public struct Game: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var system: GameSystem
    public var title: String
    public var gameCode: String
    public var path: String
    public var added: Date
    public var lastPlayed: Date?
    public var favorite: Bool

    public init(id: UUID = UUID(), system: GameSystem = .gba, title: String, gameCode: String, path: String,
                added: Date = Date(), lastPlayed: Date? = nil, favorite: Bool = false) {
        self.id = id; self.system = system; self.title = title; self.gameCode = gameCode; self.path = path
        self.added = added; self.lastPlayed = lastPlayed; self.favorite = favorite
    }

    // Libraries saved before Game Boy support have no `system`; those are all GBA games.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        system = try c.decodeIfPresent(GameSystem.self, forKey: .system) ?? .gba
        title = try c.decode(String.self, forKey: .title)
        gameCode = try c.decode(String.self, forKey: .gameCode)
        path = try c.decode(String.self, forKey: .path)
        added = try c.decode(Date.self, forKey: .added)
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        favorite = try c.decode(Bool.self, forKey: .favorite)
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var fileExists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Stable 0...1 value derived from the title, used to colour generated cover art.
    public var hue: Double {
        var h: UInt64 = 1469598103934665603
        for b in title.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 1000) / 1000
    }

    public var initials: String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(3)
        if words.count == 1, let only = words.first { return String(only.prefix(3)).uppercased() }
        let s = words.compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? system.label : s.uppercased()
    }
}

/// Fields of the GBA cartridge header (offsets per the public GBA header layout).
public struct GBAHeader: Sendable {
    public let title: String
    public let gameCode: String
    public let makerCode: String
    /// 0x96 fixed byte present at 0xB2.
    public let fixedByteOK: Bool
    /// Complement checksum over 0xA0...0xBC matches the byte at 0xBD.
    public let checksumOK: Bool

    public var looksValid: Bool { fixedByteOK && checksumOK }

    public static func read(from url: URL) -> GBAHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 0xC0), data.count == 0xC0 else { return nil }
        let bytes = [UInt8](data)
        func text(_ r: Range<Int>) -> String {
            String(decoding: bytes[r].prefix(while: { $0 != 0 }), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var sum: UInt8 = 0
        for i in 0xA0...0xBC { sum = sum &- bytes[i] }
        sum = sum &- 0x19
        return GBAHeader(title: text(0xA0..<0xAC), gameCode: text(0xAC..<0xB0), makerCode: text(0xB0..<0xB2),
                         fixedByteOK: bytes[0xB2] == 0x96, checksumOK: sum == bytes[0xBD])
    }
}

/// The parts of a Game Boy cartridge header the library needs.
public struct GBHeader: Sendable {
    public let title: String
    /// The cartridge's global checksum, used as a short identifier (there is no game code on these).
    public let gameCode: String
    public let headerChecksumOK: Bool

    public static func read(from url: URL) -> GBHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 0x150), data.count == 0x150 else { return nil }
        let b = [UInt8](data)
        let title = String(decoding: b[0x134..<0x13F].prefix { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        var x: UInt8 = 0
        for i in 0x134...0x14C { x = x &- b[i] &- 1 }
        return GBHeader(title: title, gameCode: String(format: "%02X%02X", b[0x14E], b[0x14F]), headerChecksumOK: x == b[0x14D])
    }
}
