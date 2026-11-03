import Foundation

/// Little-endian byte stream used for save states. Arrays carry their length so a mismatch is caught on load.
struct StateWriter {
    private(set) var bytes = [UInt8]()
    init() { bytes.reserveCapacity(600_000) }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 255)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> UInt32(8 * i)) & 255)) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8((v >> UInt64(8 * i)) & 255)) } }
    mutating func int(_ v: Int) { u64(UInt64(bitPattern: Int64(v))) }
    mutating func double(_ v: Double) { u64(v.bitPattern) }
    mutating func tag(_ s: StaticString) { s.withUTF8Buffer { bytes.append(contentsOf: $0) } }

    mutating func raw(_ p: UnsafePointer<UInt8>, _ n: Int) { u32(UInt32(n)); bytes.append(contentsOf: UnsafeBufferPointer(start: p, count: n)) }
    mutating func u32s(_ a: [UInt32]) { u32(UInt32(a.count)); for v in a { u32(v) } }
    mutating func u16s(_ a: [UInt16]) { u32(UInt32(a.count)); for v in a { u16(v) } }
    mutating func u64s(_ a: [UInt64]) { u32(UInt32(a.count)); for v in a { u64(v) } }
    mutating func u8s(_ a: [UInt8]) { u32(UInt32(a.count)); bytes.append(contentsOf: a) }
    mutating func i8s(_ a: [Int8]) { u8s(a.map { UInt8(bitPattern: $0) }) }
}

struct StateReader {
    private let bytes: [UInt8]
    private var pos = 0
    /// Set once anything doesn't fit; every later read then returns zeros so callers can finish and check once.
    private(set) var failed = false

    init(_ data: Data) { bytes = [UInt8](data) }
    var atEnd: Bool { pos == bytes.count }
    mutating func markFailed() { failed = true }

    private mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
        guard !failed, n >= 0, pos + n <= bytes.count else { failed = true; return nil }
        defer { pos += n }
        return bytes[pos..<(pos + n)]
    }

    mutating func u8() -> UInt8 { take(1)?.first ?? 0 }
    mutating func bool() -> Bool { u8() != 0 }
    mutating func u16() -> UInt16 { guard let s = take(2) else { return 0 }; return s.enumerated().reduce(0) { $0 | UInt16($1.element) << UInt16(8 * $1.offset) } }
    mutating func u32() -> UInt32 { guard let s = take(4) else { return 0 }; return s.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32(8 * $1.offset) } }
    mutating func u64() -> UInt64 { guard let s = take(8) else { return 0 }; return s.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) } }
    mutating func int() -> Int { Int(Int64(bitPattern: u64())) }
    mutating func double() -> Double { Double(bitPattern: u64()) }
    mutating func tag(_ s: StaticString) { s.withUTF8Buffer { expected in if let got = take(expected.count), !got.elementsEqual(expected) { failed = true } } }

    /// Copy a block into `p`, which must have exactly `n` bytes of room and match what was written.
    mutating func raw(_ p: UnsafeMutablePointer<UInt8>, _ n: Int) {
        guard Int(u32()) == n, let s = take(n) else { failed = true; return }
        s.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: n) }
    }
    private mutating func count(_ expected: Int) -> Bool { let c = Int(u32()); if c != expected { failed = true; return false }; return true }
    mutating func u32s(_ a: inout [UInt32]) { if count(a.count) { for i in 0..<a.count { a[i] = u32() } } }
    mutating func u16s(_ a: inout [UInt16]) { if count(a.count) { for i in 0..<a.count { a[i] = u16() } } }
    mutating func u64s(_ a: inout [UInt64]) { if count(a.count) { for i in 0..<a.count { a[i] = u64() } } }
    mutating func u8s(_ a: inout [UInt8]) { if count(a.count) { for i in 0..<a.count { a[i] = u8() } } }
    mutating func i8s(_ a: inout [Int8]) { var t = a.map { UInt8(bitPattern: $0) }; u8s(&t); a = t.map { Int8(bitPattern: $0) } }
    /// A variable-length byte array (e.g. EEPROM bit buffers).
    mutating func dynamicU8s() -> [UInt8] {
        let n = Int(u32())
        guard let s = take(n) else { return [] }
        return Array(s)
    }
}
