import Foundation

/// One parsed cheat instruction: write a value of 1, 2 or 4 bytes to an address, every frame.
public struct CheatWrite: Equatable, Sendable {
    public var address: UInt32
    public var value: UInt32
    public var size: Int
    public init(address: UInt32, value: UInt32, size: Int) { self.address = address; self.value = value; self.size = size }
}

public struct CheatParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public var description: String { "Line \(line): \(message)" }
}

/// Action Replay / GameShark style codes in their plain (decrypted) form, one `AAAAAAAA BBBBBBBB` pair per line:
///   0AAAAAAA 000000XX   write byte XX to address 0AAAAAAA
///   1AAAAAAA 0000XXXX   write halfword
///   2AAAAAAA XXXXXXXX   write word
/// where the leading hex digit is the code type and the remaining seven digits are the address
/// (e.g. 03007E00 -> 0x03007E00). Other code types, and the encrypted v1/v2 forms, are reported rather than guessed at.
public enum CheatParser {
    /// Game Boy / Color codes (GameShark): `01VVLLHH` writes byte VV to address HHLL.
    private static func parseGameBoy(_ text: String) -> Result<[CheatWrite], CheatParseError> {
        var writes = [CheatWrite]()
        for (index, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = index + 1
            let cleaned = raw.filter { !$0.isWhitespace && $0 != "-" }
            if cleaned.isEmpty { continue }
            guard cleaned.count == 8, cleaned.allSatisfy(\.isHexDigit) else {
                return .failure(CheatParseError(line: line, message: "expected 8 hex digits like 01FFD8C0, got “\(raw.trimmingCharacters(in: .whitespaces))”"))
            }
            let v = UInt32(cleaned, radix: 16)!
            let type = v >> 24, value = (v >> 16) & 0xFF, address = ((v & 0xFF) << 8) | ((v >> 8) & 0xFF)
            guard type == 0x01 else {
                return .failure(CheatParseError(line: line, message: "code type \(String(format: "%02X", type)) isn't supported. Only plain GameShark RAM writes (01VVLLHH) work"))
            }
            guard (address >= 0xA000 && address < 0xE000) || (address >= 0xFF80 && address < 0xFFFF) else {
                return .failure(CheatParseError(line: line, message: "address \(String(format: "%04X", address)) isn't cartridge RAM, work RAM or high RAM"))
            }
            writes.append(CheatWrite(address: address, value: value, size: 1))
        }
        return .success(writes)
    }

    public static func parse(_ text: String, gameBoy: Bool = false) -> Result<[CheatWrite], CheatParseError> {
        if gameBoy { return parseGameBoy(text) }
        var writes = [CheatWrite]()
        for (index, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = index + 1
            let cleaned = raw.filter { !$0.isWhitespace && $0 != "-" && $0 != ":" }
            if cleaned.isEmpty { continue }
            guard cleaned.count == 16, cleaned.allSatisfy(\.isHexDigit) else {
                return .failure(CheatParseError(line: line, message: "expected 16 hex digits (two groups of eight), got “\(raw.trimmingCharacters(in: .whitespaces))”"))
            }
            let a = UInt32(cleaned.prefix(8), radix: 16)!, b = UInt32(cleaned.suffix(8), radix: 16)!
            let type = a >> 28, address = a & 0x0FFF_FFFF
            switch type {
            case 0:
                guard b <= 0xFF else { return .failure(CheatParseError(line: line, message: "an 8-bit write needs a value of 00–FF")) }
                writes.append(CheatWrite(address: address, value: b, size: 1))
            case 1:
                guard b <= 0xFFFF else { return .failure(CheatParseError(line: line, message: "a 16-bit write needs a value of 0000–FFFF")) }
                writes.append(CheatWrite(address: address, value: b, size: 2))
            case 2:
                writes.append(CheatWrite(address: address, value: b, size: 4))
            default:
                return .failure(CheatParseError(line: line, message: "code type \(String(type, radix: 16).uppercased()) isn't supported. Only plain 8/16/32-bit write codes (starting 0, 1 or 2) work; encrypted v1/v2 codes must be converted first"))
            }
        }
        return .success(writes)
    }
}
