import Foundation

/// How a game stores its save data. Chosen by scanning the ROM for the library ID strings Nintendo's SDK left in it.
public enum SaveKind: Sendable { case sram, flash64, flash128, eeprom }

/// Everything on the cartridge besides the ROM itself: battery SRAM, Flash, serial EEPROM and the real-time clock.
public final class Cartridge {
    public private(set) var kind: SaveKind = .sram
    /// True when an ID string was found; otherwise SRAM is assumed (reads 0xFF until written).
    public private(set) var detected = false
    public private(set) var hasRTC = false
    /// Set whenever save data changes; cleared by `takeSave()`.
    public private(set) var dirty = false

    /// Backing store for SRAM (32 KB) and Flash (64 or 128 KB).
    private let store = UnsafeMutablePointer<UInt8>.allocate(capacity: 0x20000)
    let eeprom = EEPROM()
    let rtc = RTC()

    init() { store.initialize(repeating: 0xFF, count: 0x20000) }
    deinit { store.deallocate() }

    // MARK: detection
    func configure(rom: UnsafePointer<UInt8>?, size: Int) {
        kind = .sram; detected = false; hasRTC = false; dirty = false
        store.initialize(repeating: 0xFF, count: 0x20000)
        eeprom.reset(); rtc.reset(); flash.reset()
        guard let rom else { return }
        let patterns: [(String, SaveKind?)] = [
            ("FLASH1M_V", .flash128), ("FLASH512_V", .flash64), ("FLASH_V", .flash64),
            ("EEPROM_V", .eeprom), ("SRAM_F_V", .sram), ("SRAM_V", .sram), ("SIIRTC_V", nil),
        ]
        let bytes = patterns.map { ($0.0.utf8.map { UInt8($0) }, $0.1) }
        var i = 0
        while i + 16 <= size {
            let b = rom[i]
            if b == 0x46 || b == 0x45 || b == 0x53 {                      // 'F', 'E', 'S'
                for (pat, k) in bytes where rom[i] == pat[0] && i + pat.count <= size {
                    var match = true
                    for j in 1..<pat.count where rom[i + j] != pat[j] { match = false; break }
                    if match {
                        if let k { if !detected { kind = k; detected = true } } else { hasRTC = true }
                    }
                }
            }
            i += 4
        }
        eeprom.large = size > 0x0100_0000
    }

    // MARK: CPU-visible save area (0x0E000000...)
    func readSave(_ a: UInt32) -> UInt8 {
        switch kind {
        case .sram, .eeprom: return store[Int(a & 0x7FFF)]
        case .flash64, .flash128: return flash.read(store, Int(a & 0xFFFF), is128: kind == .flash128)
        }
    }

    func writeSave(_ a: UInt32, _ v: UInt8) {
        switch kind {
        case .sram, .eeprom:
            let i = Int(a & 0x7FFF)
            if store[i] != v { store[i] = v; dirty = true }
        case .flash64, .flash128:
            if flash.write(store, Int(a & 0xFFFF), v, is128: kind == .flash128) { dirty = true }
        }
    }

    // MARK: flash chip
    private let flash = Flash()

    private final class Flash {
        enum State { case ready, gotAA, gotCommand, program, bank }
        var state = State.ready
        var eraseArmed = false, idMode = false
        var bank = 0

        func reset() { state = .ready; eraseArmed = false; idMode = false; bank = 0 }

        func read(_ s: UnsafeMutablePointer<UInt8>, _ a: Int, is128: Bool) -> UInt8 {
            if idMode && a < 2 { return is128 ? (a == 0 ? 0x62 : 0x13) : (a == 0 ? 0x32 : 0x1B) }   // Sanyo / Panasonic
            return s[(is128 ? bank << 16 : 0) | a]
        }

        /// Returns true if stored data changed.
        func write(_ s: UnsafeMutablePointer<UInt8>, _ a: Int, _ v: UInt8, is128: Bool) -> Bool {
            let base = is128 ? bank << 16 : 0
            switch state {
            case .program:
                state = .ready
                let old = s[base | a], new = old & v                  // programming can only clear bits
                if new != old { s[base | a] = new; return true }
                return false
            case .bank:
                state = .ready
                if is128 && a == 0 { bank = Int(v & 1) }
                return false
            case .ready:
                if a == 0x5555 && v == 0xAA { state = .gotAA } else if v == 0xF0 { idMode = false }
                return false
            case .gotAA:
                state = (a == 0x2AAA && v == 0x55) ? .gotCommand : .ready
                return false
            case .gotCommand:
                state = .ready
                switch v {
                case 0x90 where a == 0x5555: idMode = true
                case 0xF0 where a == 0x5555: idMode = false
                case 0xA0 where a == 0x5555: state = .program
                case 0xB0 where a == 0x5555: state = .bank
                case 0x80 where a == 0x5555: eraseArmed = true
                case 0x10 where a == 0x5555 && eraseArmed:
                    eraseArmed = false
                    s.update(repeating: 0xFF, count: is128 ? 0x20000 : 0x10000)
                    return true
                case 0x30 where eraseArmed:
                    eraseArmed = false
                    (s + (base | (a & 0xF000))).update(repeating: 0xFF, count: 0x1000)
                    return true
                default: break
                }
                return false
            }
        }
    }

    // MARK: EEPROM region (0x0D000000...)
    @inline(__always) func isEEPROM(_ a: UInt32, romSize: Int) -> Bool {
        kind == .eeprom && (romSize <= 0x0100_0000 || (a & 0x01FF_FF00) == 0x01FF_FF00)
    }
    func readEEPROM() -> UInt16 { eeprom.readBit() }
    func writeEEPROM(_ v: UInt16) { if eeprom.writeBit(UInt8(v & 1)) { dirty = true } }
    func eepromDMAHint(count: Int) { eeprom.hint(count: count) }

    // MARK: persistence
    public func markDirty() { dirty = true }
    /// The save file contents, or nil if this cartridge has nothing to store yet.
    public func saveData() -> Data? {
        switch kind {
        case .sram: return Data(bytes: store, count: 0x8000)
        case .flash64: return Data(bytes: store, count: 0x10000)
        case .flash128: return Data(bytes: store, count: 0x20000)
        case .eeprom: return eeprom.size == 0 ? nil : Data(eeprom.data[0..<eeprom.size])
        }
    }

    /// Hand over the save file if it changed since last asked.
    public func takeSave() -> Data? {
        guard dirty else { return nil }
        dirty = false
        return saveData()
    }

    public func loadSave(_ data: Data) {
        switch kind {
        case .sram: data.copyBytes(to: store, count: min(data.count, 0x8000))
        case .flash64: data.copyBytes(to: store, count: min(data.count, 0x10000))
        case .flash128: data.copyBytes(to: store, count: min(data.count, 0x20000))
        case .eeprom: eeprom.load(data)
        }
        dirty = false
    }
}

/// Serial EEPROM (512 bytes or 8 KB) spoken to one bit per 16-bit access, normally through DMA3.
final class EEPROM {
    var data = [UInt8](repeating: 0xFF, count: 8192)
    /// 0 until known; 6 for the 512-byte part, 14 for the 8 KB part.
    private(set) var addressBits = 0
    var large = false
    var size: Int { addressBits == 6 ? 512 : addressBits == 14 ? 8192 : 0 }

    private var bits = [UInt8]()
    private var reading = false
    private var readPos = 0
    private var readBuffer: UInt64 = 0

    func reset() { data = [UInt8](repeating: 0xFF, count: 8192); addressBits = 0; bits = []; reading = false; readPos = 0 }

    /// A DMA to or from the EEPROM tells us the address width through its length (9/73 bits = small, 17/81 = large).
    func hint(count: Int) {
        guard addressBits == 0 else { return }
        if count == 9 || count == 73 { addressBits = 6 } else if count == 17 || count == 81 { addressBits = 14 }
    }

    func load(_ d: Data) {
        let n = min(d.count, 8192)
        for i in 0..<n { data[i] = d[d.startIndex + i] }
        addressBits = d.count <= 512 ? 6 : 14
    }

    func readBit() -> UInt16 {
        guard reading else { return 1 }                                 // idle/ready
        defer { readPos += 1; if readPos >= 68 { reading = false } }
        return readPos < 4 ? 0 : UInt16((readBuffer >> UInt64(63 - (readPos - 4))) & 1)
    }

    /// Feed one bit; returns true when a write to the chip completed (so the save is dirty).
    func writeBit(_ bit: UInt8) -> Bool {
        if reading { reading = false; bits = [] }
        bits.append(bit)
        guard bits.count >= 2, addressBits != 0 else { return false }
        let isRead = bits[0] == 1 && bits[1] == 1
        let isWrite = bits[0] == 1 && bits[1] == 0
        guard isRead || isWrite else { bits = []; return false }
        let total = 2 + addressBits + (isWrite ? 64 : 0) + 1
        guard bits.count == total else { return false }
        var address = 0
        for i in 0..<addressBits { address = address << 1 | Int(bits[2 + i]) }
        address &= (addressBits == 6 ? 0x3F : 0x3FF)
        var changed = false
        if isRead {
            var v: UInt64 = 0
            for k in 0..<8 { v = v << 8 | UInt64(data[address * 8 + k]) }
            readBuffer = v; readPos = 0; reading = true
        } else {
            for k in 0..<8 {
                var byte: UInt8 = 0
                for b in 0..<8 { byte = byte << 1 | bits[2 + addressBits + k * 8 + b] }
                if data[address * 8 + k] != byte { data[address * 8 + k] = byte; changed = true }
            }
        }
        bits = []
        return changed
    }
}

/// The Seiko S-3511-style real-time clock on the cartridge's GPIO pins (ROM addresses 0xC4-0xC9).
/// Pins: bit 0 = SCK, bit 1 = SIO, bit 2 = CS. Bytes travel least-significant bit first.
final class RTC {
    private var data: UInt8 = 0, direction: UInt8 = 0, control: UInt8 = 0
    private var cs = false, sck = false
    private enum Stage { case idle, command, send, receive }
    private var stage = Stage.idle
    private var bitsIn = 0, byteIn: UInt8 = 0
    private var command = 0
    private var buffer = [UInt8](), bytePos = 0, bitPos = 0
    private var outBit: UInt8 = 0
    private var expected = 0
    private var status: UInt8 = 0
    private var offset: TimeInterval = 0              // game-set clock minus the host clock

    func reset() {
        data = 0; direction = 0; control = 0; cs = false; sck = false; stage = .idle
        status = 0; offset = 0
    }

    /// nil means "not mine, return the ROM's own bytes".
    func read16(_ addr: Int) -> UInt16? {
        guard control & 1 != 0 else { return nil }
        switch addr {
        case 0xC4:
            var v = data & direction
            if direction & 2 == 0 { v |= outBit << 1 }                    // SIO as an input carries the clock's answer
            return UInt16(v & 0xF)
        case 0xC6: return UInt16(direction)
        case 0xC8: return UInt16(control)
        default: return nil
        }
    }

    func write16(_ addr: Int, _ v: UInt16) {
        switch addr {
        case 0xC4:
            data = UInt8(v & 0xF)
            pins(data & direction)
        case 0xC6: direction = UInt8(v & 0xF)
        case 0xC8: control = UInt8(v & 1)
        default: break
        }
    }

    private func pins(_ p: UInt8) {
        let newSCK = p & 1 != 0, newSIO = p & 2 != 0, newCS = p & 4 != 0
        if !cs && newCS { stage = .command; bitsIn = 0; byteIn = 0 }
        if cs && !newCS { stage = .idle }
        if newCS && !sck && newSCK { clock(newSIO) }
        cs = newCS; sck = newSCK
    }

    private func clock(_ sio: Bool) {
        switch stage {
        case .idle: break
        case .command:
            byteIn |= (sio ? 1 : 0) << UInt8(bitsIn); bitsIn += 1
            if bitsIn == 8 { beginCommand(byteIn) }
        case .send:
            outBit = (buffer[bytePos] >> UInt8(bitPos)) & 1
            bitPos += 1
            if bitPos == 8 { bitPos = 0; bytePos += 1; if bytePos == buffer.count { stage = .idle } }
        case .receive:
            byteIn |= (sio ? 1 : 0) << UInt8(bitsIn); bitsIn += 1
            if bitsIn == 8 {
                buffer.append(byteIn); byteIn = 0; bitsIn = 0
                if buffer.count == expected { finishWrite() }
            }
        }
    }

    private func beginCommand(_ byte: UInt8) {
        guard byte & 0x0F == 0x06 else { stage = .idle; return }
        command = Int((byte >> 4) & 7)
        let isRead = byte & 0x80 != 0
        let length: Int
        switch command { case 1: length = 1; case 2: length = 7; case 3: length = 3; case 4: length = 3; case 5: length = 1; default: length = 0 }
        if isRead {
            switch command {
            case 1: buffer = [status]
            case 2: buffer = dateTimeBytes(includeDate: true)
            case 3: buffer = dateTimeBytes(includeDate: false)
            default: buffer = [UInt8](repeating: 0, count: max(length, 1))
            }
            bytePos = 0; bitPos = 0; stage = length == 0 ? .idle : .send
        } else {
            if command == 0 { offset = 0; status = 0; stage = .idle; return }   // reset
            buffer = []; expected = length; bitsIn = 0; byteIn = 0
            stage = length == 0 ? .idle : .receive
        }
    }

    private func finishWrite() {
        switch command {
        case 1: status = buffer[0] & 0x6A
        case 2: setDateTime(buffer)
        case 3: setDateTime([0, 1, 1, 0] + buffer)
        default: break
        }
        stage = .idle
    }

    private static func bcd(_ v: Int) -> UInt8 { UInt8((v / 10) << 4 | v % 10) }
    private static func unbcd(_ b: UInt8) -> Int { Int(b >> 4) * 10 + Int(b & 15) }

    private func now() -> Date { Date().addingTimeInterval(offset) }

    private func dateTimeBytes(includeDate: Bool) -> [UInt8] {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: now())
        var hour = c.hour ?? 0
        var hourByte: UInt8
        if status & 0x40 != 0 { hourByte = RTC.bcd(hour) }
        else { let pm: UInt8 = hour >= 12 ? 0x80 : 0; hour %= 12; hourByte = RTC.bcd(hour) | pm }
        let time = [hourByte, RTC.bcd(c.minute ?? 0), RTC.bcd(c.second ?? 0)]
        guard includeDate else { return time }
        return [RTC.bcd((c.year ?? 2000) % 100), RTC.bcd(c.month ?? 1), RTC.bcd(c.day ?? 1), RTC.bcd(((c.weekday ?? 1) - 1) % 7)] + time
    }

    private func setDateTime(_ b: [UInt8]) {
        guard b.count == 7 else { return }
        var comps = DateComponents()
        comps.year = 2000 + RTC.unbcd(b[0]); comps.month = max(1, RTC.unbcd(b[1])); comps.day = max(1, RTC.unbcd(b[2]))
        var hour = RTC.unbcd(b[4] & 0x7F)
        if status & 0x40 == 0 && b[4] & 0x80 != 0 { hour += 12 }
        comps.hour = hour; comps.minute = RTC.unbcd(b[5]); comps.second = RTC.unbcd(b[6])
        comps.timeZone = TimeZone.current
        if let target = Calendar(identifier: .gregorian).date(from: comps) { offset = target.timeIntervalSinceNow }
    }
}

// MARK: save states
extension Cartridge {
    func save(_ w: inout StateWriter) {
        w.tag("CRT0")
        w.u8(kind == .sram ? 0 : kind == .flash64 ? 1 : kind == .flash128 ? 2 : 3)
        w.raw(store, 0x20000)
        w.u8(flash.state == .ready ? 0 : flash.state == .gotAA ? 1 : flash.state == .gotCommand ? 2 : flash.state == .program ? 3 : 4)
        w.bool(flash.eraseArmed); w.bool(flash.idMode); w.int(flash.bank)
        eeprom.save(&w); rtc.save(&w)
    }

    func load(_ r: inout StateReader) {
        r.tag("CRT0")
        let before = saveData()
        let k = r.u8()
        if k != (kind == .sram ? 0 : kind == .flash64 ? 1 : kind == .flash128 ? 2 : 3) { r.markFailed() }
        r.raw(store, 0x20000)
        switch r.u8() { case 1: flash.state = .gotAA; case 2: flash.state = .gotCommand; case 3: flash.state = .program; case 4: flash.state = .bank; default: flash.state = .ready }
        flash.eraseArmed = r.bool(); flash.idMode = r.bool(); flash.bank = r.int()
        eeprom.load(&r); rtc.load(&r)
        if saveData() != before { dirty = true }                        // write the restored memory back out only if it differs
    }
}

extension EEPROM {
    func save(_ w: inout StateWriter) {
        w.u8s(data); w.int(addressBits); w.u32(UInt32(bits.count)); w.u8s(bits); w.bool(reading); w.int(readPos); w.u64(readBuffer)
    }
    func load(_ r: inout StateReader) {
        r.u8s(&data); addressBits = r.int(); _ = r.u32(); bits = r.dynamicU8s(); reading = r.bool(); readPos = r.int(); readBuffer = r.u64()
    }
}

extension RTC {
    func save(_ w: inout StateWriter) {
        w.u8(data); w.u8(direction); w.u8(control); w.bool(cs); w.bool(sck)
        w.u8(stage == .idle ? 0 : stage == .command ? 1 : stage == .send ? 2 : 3)
        w.int(bitsIn); w.u8(byteIn); w.int(command); w.u32(UInt32(buffer.count)); w.u8s(buffer); w.int(bytePos); w.int(bitPos)
        w.u8(outBit); w.int(expected); w.u8(status); w.double(offset)
    }
    func load(_ r: inout StateReader) {
        data = r.u8(); direction = r.u8(); control = r.u8(); cs = r.bool(); sck = r.bool()
        switch r.u8() { case 1: stage = .command; case 2: stage = .send; case 3: stage = .receive; default: stage = .idle }
        bitsIn = r.int(); byteIn = r.u8(); command = r.int(); _ = r.u32(); buffer = r.dynamicU8s(); bytePos = r.int(); bitPos = r.int()
        outBit = r.u8(); expected = r.int(); status = r.u8(); offset = r.double()
    }
}
