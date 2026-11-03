import Foundation

/// A Game Boy cartridge: ROM, optional battery RAM, and the mapper chip that switches banks.
final class GBCartridge {
    enum Mapper { case none, mbc1, mbc2, mbc3, mbc5 }

    let rom: UnsafeMutablePointer<UInt8>
    let romSize: Int
    let romBankMask: Int
    private(set) var ram: UnsafeMutablePointer<UInt8>
    private(set) var ramSize: Int

    let mapper: Mapper
    let hasBattery: Bool
    let hasRTC: Bool
    /// nil when the cartridge uses hardware this core doesn't have (MBC6/7, HuC, ...).
    let unsupportedReason: String?
    let title: String
    /// 0x80 = works on both, 0xC0 = Color only, anything else = original Game Boy.
    let cgbFlag: UInt8
    var supportsColor: Bool { cgbFlag & 0x80 != 0 }

    // bank registers
    private var ramEnabled = false
    private var bank1 = 1, bank2 = 0, mode = 0          // MBC1
    private var romBank = 1, ramBank = 0                  // MBC3/5 (romBank is 9 bits on MBC5)
    /// Byte offsets into `rom` for the two 16 KB windows.
    private(set) var offset0 = 0, offsetN = 0x4000
    private(set) var dirty = false

    // MBC3 real-time clock
    private var rtcBase = Date()                          // moment the registers below were last exact
    private var rtcRegs = [UInt8](repeating: 0, count: 5) // s, m, h, day low, day high (bit0 = day 8, bit6 = halt, bit7 = carry)
    private var rtcLatched = [UInt8](repeating: 0, count: 5)
    private var rtcSelect = 0
    private var latchArmed = false

    init(rom data: Data) {
        romSize = max(data.count, 0x8000)
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: romSize)
        p.initialize(repeating: 0xFF, count: romSize)
        data.copyBytes(to: p, count: data.count)
        rom = p
        var banks = 2
        while banks * 0x4000 < romSize { banks *= 2 }
        romBankMask = banks - 1

        func byte(_ i: Int) -> UInt8 { i < data.count ? data[data.startIndex + i] : 0 }
        cgbFlag = byte(0x143)
        title = String((0x134..<0x13F).map { byte($0) }.prefix { $0 >= 0x20 && $0 < 0x7F }.map { Character(UnicodeScalar($0)) })

        let type = byte(0x147)
        var m = Mapper.none, battery = false, rtc = false, reason: String? = nil
        switch type {
        case 0x00, 0x08: m = .none
        case 0x09: m = .none; battery = true
        case 0x01, 0x02: m = .mbc1
        case 0x03: m = .mbc1; battery = true
        case 0x05: m = .mbc2
        case 0x06: m = .mbc2; battery = true
        case 0x0F: m = .mbc3; battery = true; rtc = true
        case 0x10: m = .mbc3; battery = true; rtc = true
        case 0x11, 0x12: m = .mbc3
        case 0x13: m = .mbc3; battery = true
        case 0x19, 0x1A, 0x1C, 0x1D: m = .mbc5
        case 0x1B, 0x1E: m = .mbc5; battery = true
        default: reason = "This cartridge type (0x\(String(type, radix: 16, uppercase: true))) isn't supported yet"
        }
        mapper = m; hasBattery = battery; hasRTC = rtc; unsupportedReason = reason

        let ramCode = byte(0x149)
        var rs = [0, 0x800, 0x2000, 0x8000, 0x20000, 0x10000][min(Int(ramCode), 5)]
        if m == .mbc2 { rs = 512 }
        if m == .none && type == 0x08 && rs == 0 { rs = 0x2000 }
        ramSize = rs
        ram = UnsafeMutablePointer<UInt8>.allocate(capacity: max(rs, 1))
        ram.initialize(repeating: m == .mbc2 ? 0xFF : 0, count: max(rs, 1))
        updateBanks()
    }

    deinit { rom.deallocate(); ram.deallocate() }

    // MARK: banking
    private func updateBanks() {
        switch mapper {
        case .none: offset0 = 0; offsetN = 0x4000
        case .mbc1:
            offset0 = (mode == 1 ? (bank2 << 5) & romBankMask : 0) * 0x4000
            offsetN = (((bank2 << 5) | bank1) & romBankMask) * 0x4000
        case .mbc2, .mbc3, .mbc5:
            offset0 = 0
            offsetN = (romBank & romBankMask) * 0x4000
        }
    }

    // MARK: ROM area
    @inline(__always) func readROM(_ a: UInt16) -> UInt8 {
        a < 0x4000 ? rom[offset0 + Int(a)] : rom[offsetN + Int(a) - 0x4000]
    }

    func writeROM(_ a: UInt16, _ v: UInt8) {
        switch mapper {
        case .none: break
        case .mbc1:
            switch a >> 13 {
            case 0: ramEnabled = v & 0x0F == 0x0A
            case 1: bank1 = Int(v & 0x1F); if bank1 == 0 { bank1 = 1 }
            case 2: bank2 = Int(v & 3)
            default: mode = Int(v & 1)
            }
        case .mbc2:
            if a < 0x4000 {
                if a & 0x100 == 0 { ramEnabled = v & 0x0F == 0x0A } else { romBank = Int(v & 0x0F); if romBank == 0 { romBank = 1 } }
            }
        case .mbc3:
            switch a >> 13 {
            case 0: ramEnabled = v & 0x0F == 0x0A
            case 1: romBank = Int(v & 0x7F); if romBank == 0 { romBank = 1 }
            case 2: rtcSelect = Int(v); if v < 4 { ramBank = Int(v) }
            default:
                if v == 0 { latchArmed = true } else if v == 1 && latchArmed { latchRTC(); latchArmed = false } else { latchArmed = false }
            }
        case .mbc5:
            switch a >> 12 {
            case 0, 1: ramEnabled = v & 0x0F == 0x0A
            case 2: romBank = (romBank & 0x100) | Int(v)
            case 3: romBank = (romBank & 0xFF) | (Int(v & 1) << 8)
            case 4, 5: ramBank = Int(v & 0x0F)
            default: break
            }
        }
        updateBanks()
    }

    // MARK: RAM area
    private func ramIndex(_ a: UInt16) -> Int? {
        guard ramSize > 0 else { return nil }
        switch mapper {
        case .mbc2: return Int(a & 0x1FF)
        case .mbc1: return ((mode == 1 ? bank2 : 0) * 0x2000 + Int(a & 0x1FFF)) % ramSize
        case .mbc3, .mbc5: return (ramBank * 0x2000 + Int(a & 0x1FFF)) % ramSize
        case .none: return Int(a & 0x1FFF) % ramSize
        }
    }

    func readRAM(_ a: UInt16) -> UInt8 {
        guard ramEnabled || mapper == .none else { return 0xFF }
        if mapper == .mbc3 && hasRTC && rtcSelect >= 8 && rtcSelect <= 0x0C { return rtcLatched[rtcSelect - 8] }
        guard let i = ramIndex(a) else { return 0xFF }
        return mapper == .mbc2 ? ram[i] | 0xF0 : ram[i]
    }

    func writeRAM(_ a: UInt16, _ v: UInt8) {
        guard ramEnabled || mapper == .none else { return }
        if mapper == .mbc3 && hasRTC && rtcSelect >= 8 && rtcSelect <= 0x0C { writeRTC(rtcSelect - 8, v); return }
        guard let i = ramIndex(a) else { return }
        let value = mapper == .mbc2 ? v | 0xF0 : v
        if ram[i] != value { ram[i] = value; dirty = true }
    }

    // MARK: real-time clock
    /// Bring the clock registers up to date with the host clock (unless the halt bit is set).
    private func advanceRTC() {
        let now = Date()
        defer { rtcBase = now }
        guard rtcRegs[4] & 0x40 == 0 else { return }
        var seconds = Int(now.timeIntervalSince(rtcBase))
        guard seconds > 0 else { return }
        rtcBase = rtcBase.addingTimeInterval(Double(seconds))
        var total = Int(rtcRegs[0]) + Int(rtcRegs[1]) * 60 + Int(rtcRegs[2]) * 3600 + (Int(rtcRegs[3]) | (Int(rtcRegs[4] & 1) << 8)) * 86400
        total += seconds; seconds = 0
        let days = total / 86400
        var carry = rtcRegs[4] & 0x80
        if days > 511 { carry = 0x80 }
        rtcRegs[0] = UInt8(total % 60); rtcRegs[1] = UInt8(total / 60 % 60); rtcRegs[2] = UInt8(total / 3600 % 24)
        rtcRegs[3] = UInt8((days % 512) & 0xFF)
        rtcRegs[4] = (rtcRegs[4] & 0x40) | carry | UInt8(((days % 512) >> 8) & 1)
        dirty = true
    }

    private func latchRTC() { guard hasRTC else { return }; advanceRTC(); rtcLatched = rtcRegs }

    private func writeRTC(_ index: Int, _ v: UInt8) {
        advanceRTC()
        switch index {
        case 0: rtcRegs[0] = v % 60
        case 1: rtcRegs[1] = v % 60
        case 2: rtcRegs[2] = v % 24
        case 3: rtcRegs[3] = v
        default: rtcRegs[4] = v & 0xC1
        }
        rtcLatched = rtcRegs
        dirty = true
    }

    // MARK: persistence
    /// Battery RAM, followed by the clock (registers and the time they were exact) for MBC3 timer cartridges.
    func saveData() -> Data? {
        guard hasBattery, ramSize > 0 || hasRTC else { return nil }
        var d = Data(bytes: ram, count: ramSize)
        if hasRTC {
            advanceRTC()
            d.append(contentsOf: rtcRegs)
            var t = UInt64(bitPattern: Int64(rtcBase.timeIntervalSince1970))
            for _ in 0..<8 { d.append(UInt8(t & 255)); t >>= 8 }
        }
        return d
    }

    func takeSave() -> Data? {
        guard dirty else { return nil }
        dirty = false
        return saveData()
    }

    func loadSave(_ d: Data) {
        guard hasBattery else { return }
        let n = min(d.count, ramSize)
        d.copyBytes(to: ram, count: n)
        if hasRTC, d.count >= ramSize + 13 {
            for i in 0..<5 { rtcRegs[i] = d[d.startIndex + ramSize + i] }
            var t: UInt64 = 0
            for i in 0..<8 { t |= UInt64(d[d.startIndex + ramSize + 5 + i]) << UInt64(8 * i) }
            rtcBase = Date(timeIntervalSince1970: Double(Int64(bitPattern: t)))
            advanceRTC()
            rtcLatched = rtcRegs
        }
        dirty = false
    }

    func markDirty() { dirty = true }
}

// MARK: save states
extension GBCartridge {
    func save(_ w: inout StateWriter) {
        w.tag("GCT0")
        w.raw(ram, max(ramSize, 1))
        w.bool(ramEnabled); w.int(bank1); w.int(bank2); w.int(mode); w.int(romBank); w.int(ramBank)
        w.u8s(rtcRegs); w.u8s(rtcLatched); w.int(rtcSelect); w.bool(latchArmed); w.double(rtcBase.timeIntervalSince1970)
    }

    func load(_ r: inout StateReader) {
        r.tag("GCT0")
        r.raw(ram, max(ramSize, 1))
        ramEnabled = r.bool(); bank1 = r.int(); bank2 = r.int(); mode = r.int(); romBank = r.int(); ramBank = r.int()
        r.u8s(&rtcRegs); r.u8s(&rtcLatched); rtcSelect = r.int(); latchArmed = r.bool(); rtcBase = Date(timeIntervalSince1970: r.double())
        updateBanks()
        dirty = true
    }
}
