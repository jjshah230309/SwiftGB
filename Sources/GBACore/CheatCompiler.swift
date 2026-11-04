import Foundation

/// Turns the text a person types (or copies from a code list) into a `CheatProgram`.
/// Understands GameShark Advance and Action Replay v1-v3 (raw and encrypted) and CodeBreaker, and says exactly
/// which line it can't handle and why, instead of guessing.
public enum CheatCompiler {
    struct Line { var a: UInt32; var b: UInt32; var src: Int; var twelve: Bool }
    typealias Failure = CheatParseError
    private static func fail(_ line: Int, _ message: String) -> Failure { CheatParseError(line: line, message: message) }

    // MARK: entry point

    public static func compile(_ text: String, format: CheatFormat = .auto) -> Result<CheatProgram, CheatParseError> {
        let lines: [Line]
        switch tokenize(text) {
        case .success(let l): lines = l
        case .failure(let e): return .failure(e)
        }
        if lines.isEmpty { return .success(CheatProgram(ops: [], format: format == .auto ? .gameShark : format)) }

        if format != .auto { return compile(lines, as: format) }

        let candidates: [CheatFormat] = lines.contains(where: \.twelve) ? [.codeBreaker]
            : [.gameShark, .actionReplayV3, .encryptedV12, .encryptedV3]
        var best: Failure?
        for f in candidates {
            switch compile(lines, as: f) {
            case .success(let p): return .success(p)
            case .failure(let e):
                // The most informative complaint is the one from the interpretation that got furthest — but a plain
                // (unencrypted) reading beats an encrypted one, since garbage "decrypts" fail almost at once.
                if best == nil || (e.line > best!.line && (f == .gameShark || f == .actionReplayV3)) { best = e }
            }
        }
        return .failure(best!)
    }

    private static func compile(_ lines: [Line], as format: CheatFormat) -> Result<CheatProgram, CheatParseError> {
        switch format {
        case .codeBreaker:
            return compileCodeBreaker(lines)
        case .gameShark, .actionReplayV3, .encryptedV12, .encryptedV3:
            if let twelve = lines.first(where: \.twelve) {
                return .failure(fail(twelve.src, "this line has 12 digits, which is the CodeBreaker layout. Choose the CodeBreaker format"))
            }
            var work = lines
            if format == .encryptedV12 || format == .encryptedV3 {
                var cipher = CheatCipher(format == .encryptedV3 ? .v3 : .v1v2)
                for i in work.indices { let d = cipher.decrypt((work[i].a, work[i].b)); work[i].a = d.0; work[i].b = d.1 }
            }
            let v3 = format == .actionReplayV3 || format == .encryptedV3
            let result = v3 ? compileActionReplayV3(work) : compileGameShark(work)
            return result.map { CheatProgram(ops: $0.0, format: format, notes: $0.1) }
        case .auto:
            return compile(lines, as: .gameShark)
        }
    }

    // MARK: text -> words

    static func tokenize(_ text: String) -> Result<[Line], Failure> {
        var out = [Line]()
        var pending: (a: UInt32, src: Int)?
        for (index, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let n = index + 1
            let cleaned = raw.filter { !$0.isWhitespace && $0 != "-" && $0 != ":" && $0 != "," }
            if cleaned.isEmpty { continue }
            guard cleaned.allSatisfy(\.isHexDigit) else {
                return .failure(fail(n, "“\(raw.trimmingCharacters(in: .whitespaces))” has characters that aren't hex digits (0-9, A-F)"))
            }
            switch cleaned.count {
            case 8:
                let v = UInt32(cleaned, radix: 16)!
                if let p = pending { out.append(Line(a: p.a, b: v, src: p.src, twelve: false)); pending = nil } else { pending = (v, n) }
            case 12, 16:
                if let p = pending { return .failure(fail(p.src, "a lone group of 8 digits; codes come as two groups of eight")) }
                let twelve = cleaned.count == 12
                out.append(Line(a: UInt32(cleaned.prefix(8), radix: 16)!, b: UInt32(cleaned.suffix(cleaned.count - 8), radix: 16)!, src: n, twelve: twelve))
            default:
                return .failure(fail(n, "expected 16 hex digits (two groups of eight; 8 + 4 for CodeBreaker), got “\(raw.trimmingCharacters(in: .whitespaces))”"))
            }
        }
        if let p = pending { return .failure(fail(p.src, "a lone group of 8 digits; codes come as two groups of eight")) }
        return .success(out)
    }

    /// An address the memory map really has at its canonical place (RAM, I/O, palette, VRAM, OAM). Checking the size, not just the
    /// region, is what lets a plain GameShark line be told apart from an Action Replay v3 line that happens to look like one.
    static func isMappedAddress(_ a: UInt32) -> Bool {
        let offset = a & 0x00FF_FFFF
        switch (a >> 24) & 0xF {
        case 2: return offset < 0x4_0000
        case 3: return offset < 0x8000
        case 4: return offset < 0x400
        case 5: return offset < 0x400
        case 6: return offset < 0x1_8000
        case 7: return offset < 0x400
        default: return false
        }
    }

    private static func hex(_ v: UInt32, _ digits: Int = 8) -> String { String(format: "%0\(digits)X", v) }

    // MARK: GameShark Advance / Action Replay v1-v2 (decrypted)

    static func compileGameShark(_ L: [Line]) -> Result<([CheatOp], [String]), Failure> {
        var ops = [CheatOp](), notes = [String]()
        var i = 0
        while i < L.count {
            let l = L[i], a = l.a, b = l.b
            func err(_ m: String) -> Result<([CheatOp], [String]), Failure> { .failure(fail(l.src, m)) }
            if b == 0x001D_C0DE { ops.append(CheatOp(.noop)); i += 1; continue }          // game-ID code: only the device needs it
            if a == 0xDEAD_FACE { ops.append(CheatOp(.noop)); i += 1; continue }          // seed change (already applied while decrypting)
            let type = a >> 28, addr = a & 0x0FFF_FFFF
            switch type {
            case 0, 1, 2:
                let size = 1 << type
                let limit: UInt32 = type == 0 ? 0xFF : type == 1 ? 0xFFFF : 0xFFFF_FFFF
                guard isMappedAddress(addr) else { return err("address \(hex(addr, 7)) isn't RAM, I/O, palette, VRAM or OAM") }
                guard b <= limit else { return err("a \(size * 8)-bit write needs a value that fits in \(size * 2) hex digits") }
                ops.append(CheatOp(.write(address: addr, value: b, size: size, count: 1)))
            case 3:
                guard a & 0x0FFF_0000 == 0 else { return err("a 3 code is 3000cccc; the middle digits must be zero") }
                let count = Int(a & 0xFFFF), needed = (count + 1) / 2
                guard i + needed < L.count || needed == 0 else { return err("this group write needs \(needed) following line(s) holding \(count) addresses") }
                var addresses = [UInt32]()
                for k in 0..<needed {
                    let g = L[i + 1 + k]
                    for x in [g.a, g.b] where addresses.count < count {
                        guard isMappedAddress(x & 0x0FFF_FFFF) else { return .failure(fail(g.src, "address \(hex(x)) isn't RAM, I/O, palette, VRAM or OAM")) }
                        addresses.append(x & 0x0FFF_FFFF)
                    }
                }
                ops.append(CheatOp(.group(value: b, addresses: addresses), lines: 1 + needed))
                i += needed
            case 6:
                let hi = b >> 16
                guard hi == 0 || hi == 0x1000 else { return err("a ROM patch is 6aaaaaaa 0000xxxx (or 1000xxxx before boot)") }
                ops.append(CheatOp(.romPatch(offset: Int(addr >> 1) & ~1, value: UInt16(truncatingIfNeeded: b))))
            case 8:
                if a == 0x80F0_0000 { notes.append("line \(l.src): slowdown code ignored (the emulator has no code-handler loop to slow down)"); ops.append(CheatOp(.noop)) }
                else {
                    let sel = (a >> 20) & 0xF
                    guard (a >> 28) == 8, sel == 1 || sel == 2 else { return err("unknown 8-code “\(hex(a)) \(hex(b))”") }
                    notes.append("line \(l.src): this writes only while the GameShark button is held, and there is no such button here, so it never runs")
                    ops.append(CheatOp(.noop))
                }
            case 0xD:
                guard b <= 0xFFFF else { return err("a D code compares a 16-bit value, so the value must be 0000-FFFF") }
                ops.append(CheatOp(.condition(address: addr, value: b, size: 2, compare: .eq, onFail: .lines(1))))
            case 0xE:
                guard (a >> 24) == 0xE0 else { return err("an E code is E0zzxxxx aaaaaaaa") }
                ops.append(CheatOp(.condition(address: b & 0x0FFF_FFFF, value: a & 0xFFFF, size: 2, compare: .eq, onFail: .lines(Int((a >> 16) & 0xFF)))))
            case 0xF:
                notes.append("line \(l.src): hook/master code ignored (cheats are applied once per frame, no hook needed)")
                ops.append(CheatOp(.noop))
            default:
                return err("code type \(String(type, radix: 16).uppercased()) isn't part of the GameShark Advance / Action Replay v1-v2 set. If this is an Action Replay v3 or CodeBreaker code, pick that format")
            }
            i += 1
        }
        return .success((ops, notes))
    }

    // MARK: Action Replay v3 (decrypted)

    private static let arConditions: [UInt32: (CheatCompare, Int)] = [
        0x08: (.eq, 1), 0x0A: (.eq, 2), 0x0C: (.eq, 4),
        0x10: (.ne, 1), 0x12: (.ne, 2), 0x14: (.ne, 4),
        0x18: (.lt, 1), 0x1A: (.lt, 2), 0x1C: (.lt, 4),
        0x20: (.gt, 1), 0x21: (.gt, 2), 0x22: (.gt, 4),
        0x28: (.ltu, 1), 0x2A: (.ltu, 2), 0x2C: (.ltu, 4),
        0x30: (.gtu, 1), 0x32: (.gtu, 2), 0x34: (.gtu, 4),
        0x38: (.and, 1), 0x39: (.and, 2), 0x3A: (.and, 4),
    ]

    /// The address in an Action Replay v3 word: bits 23-20 are the memory region (2 = external RAM, 3 = internal RAM…),
    /// bits 19-0 the offset inside it.
    private static func arAddress(_ w: UInt32) -> UInt32 { (((w >> 20) & 0xF) << 24) | (w & 0xF_FFFF) }

    static func compileActionReplayV3(_ L: [Line]) -> Result<([CheatOp], [String]), Failure> {
        var ops = [CheatOp](), notes = [String]()
        var i = 0
        while i < L.count {
            let l = L[i], a = l.a, b = l.b
            func err(_ m: String) -> Result<([CheatOp], [String]), Failure> { .failure(fail(l.src, m)) }
            if b == 0x001D_C0DE { ops.append(CheatOp(.noop)); i += 1; continue }
            if a == 0xDEAD_FACE { ops.append(CheatOp(.noop)); i += 1; continue }
            let b0 = a >> 24
            if b0 == 0xC4 { notes.append("line \(l.src): master code ignored (cheats are applied once per frame, no hook needed)"); ops.append(CheatOp(.noop)); i += 1; continue }

            if a == 0 {
                // Special codes live in the second word.
                switch b {
                case 0x4000_0000: ops.append(CheatOp(.endBlock))
                case 0x6000_0000: ops.append(CheatOp(.runAll))
                case _ where b & 0xFFFF_00FF == 0x0800_0000: ops.append(CheatOp(.noop)); notes.append("line \(l.src): slowdown code ignored")
                case _ where [0x10, 0x12, 0x14].contains(b >> 24):
                    guard i + 1 < L.count else { return err("this code needs a second line") }
                    ops.append(CheatOp(.noop, lines: 2)); i += 1
                    notes.append("line \(l.src): this writes only while the Action Replay button is held, and there is no such button here, so it never runs")
                case _ where [0x18, 0x1A, 0x1C, 0x1E].contains(b >> 24):
                    return err("Action Replay v3 ROM patches aren't supported: the references disagree on how their address maps into the ROM, and a wrong guess would corrupt the game")
                case _ where [0x80, 0x82, 0x84].contains(b >> 24):
                    guard i + 1 < L.count else { return err("a slide code needs a second line") }
                    let n = L[i + 1]
                    let size = [0x80: 1, 0x82: 2, 0x84: 4][b >> 24]!
                    let start = size == 1 ? n.a & 0xFF : size == 2 ? n.a & 0xFFFF : n.a
                    let count = Int((n.b >> 16) & 0xFF)
                    var used = 2
                    if size == 4, i + 2 < L.count, L[i + 2].a == 0x8000_0000, L[i + 2].b == 0 { used = 3 }
                    ops.append(CheatOp(.slide(address: arAddress(b), value: start, size: size, count: count, valueStep: n.b >> 24, addressStep: (n.b & 0xFFFF) * UInt32(size)), lines: used))
                    i += used - 1
                default:
                    ops.append(CheatOp(.stop))                              // 00000000 xxxxxxxx: end of the list
                }
                i += 1; continue
            }

            let address = arAddress(a)
            let low6 = b0 & 0x3F, variant = b0 >> 6
            let skip: CheatSkip = [CheatSkip.lines(1), .lines(2), .block, .disable][Int(variant)]
            switch b0 {
            case 0x00: ops.append(CheatOp(.write(address: address, value: b & 0xFF, size: 1, count: Int(b >> 8) + 1)))
            case 0x02: ops.append(CheatOp(.write(address: address, value: b & 0xFFFF, size: 2, count: Int(b >> 16) + 1)))
            case 0x04: ops.append(CheatOp(.write(address: address, value: b, size: 4, count: 1)))
            case 0x40: ops.append(CheatOp(.pointerWrite(address: address, value: b & 0xFF, size: 1, offset: b >> 8)))
            case 0x42: ops.append(CheatOp(.pointerWrite(address: address, value: b & 0xFFFF, size: 2, offset: (b >> 16) * 2)))
            case 0x44: ops.append(CheatOp(.pointerWrite(address: address, value: b, size: 4, offset: 0)))
            case 0x80: ops.append(CheatOp(.add(address: address, value: b & 0xFF, size: 1)))
            case 0x82: ops.append(CheatOp(.add(address: address, value: b & 0xFFFF, size: 2)))
            case 0x84: ops.append(CheatOp(.add(address: address, value: b, size: 4)))
            case 0xC6: ops.append(CheatOp(.write(address: 0x0400_0000 | (a & 0xFFFF), value: b & 0xFFFF, size: 2, count: 1)))
            case 0xC7: ops.append(CheatOp(.write(address: 0x0400_0000 | (a & 0xFFFF), value: b, size: 4, count: 1)))
            default:
                if low6 == 0x0E { ops.append(CheatOp(.always(skip))) }
                else if let (cmp, size) = arConditions[low6] {
                    let mask: UInt32 = size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFF_FFFF
                    ops.append(CheatOp(.condition(address: address, value: b & mask, size: size, compare: cmp, onFail: skip)))
                } else {
                    return err("code type \(hex(b0, 2)) isn't an Action Replay v3 code. If it's a GameShark Advance or CodeBreaker code, pick that format")
                }
            }
            i += 1
        }
        return .success((ops, notes))
    }

    // MARK: CodeBreaker (unencrypted)

    static func compileCodeBreaker(_ L: [Line]) -> Result<CheatProgram, Failure> {
        var ops = [CheatOp](), notes = [String]()
        var i = 0
        while i < L.count {
            let l = L[i], a = l.a, b = l.b
            func err(_ m: String) -> Result<CheatProgram, Failure> { .failure(fail(l.src, m)) }
            guard l.twelve else { return err("CodeBreaker codes are 8 digits + 4 digits") }
            let type = a >> 28, addr = a & 0x0FFF_FFFF
            func ramOK() -> Bool { isMappedAddress(addr) }
            switch type {
            case 0, 1:
                notes.append("line \(l.src): master/hook code ignored (cheats are applied once per frame, no hook needed)")
                ops.append(CheatOp(.noop))
            case 3:
                guard ramOK() else { return err("address \(hex(addr, 7)) isn't RAM, I/O, palette, VRAM or OAM") }
                guard b <= 0xFF else { return err("a 3 code writes one byte: 3aaaaaaa 00xx") }
                ops.append(CheatOp(.write(address: addr, value: b, size: 1, count: 1)))
            case 8:
                guard ramOK() else { return err("address \(hex(addr, 7)) isn't RAM, I/O, palette, VRAM or OAM") }
                ops.append(CheatOp(.write(address: addr, value: b, size: 2, count: 1)))
            case 6:
                guard ramOK() else { return err("address \(hex(addr, 7)) isn't RAM, I/O, palette, VRAM or OAM") }
                ops.append(CheatOp(.and16(address: addr, value: UInt16(b))))
            case 4:
                guard ramOK() else { return err("address \(hex(addr, 7)) isn't RAM, I/O, palette, VRAM or OAM") }
                guard i + 1 < L.count else { return err("a slide code needs a second line") }
                let n = L[i + 1]
                ops.append(CheatOp(.slide(address: addr, value: b, size: 2, count: Int(n.a & 0xFFFF), valueStep: n.a >> 16, addressStep: n.b * 2), lines: 2))
                i += 1
            case 7:
                ops.append(CheatOp(.condition(address: addr, value: b, size: 2, compare: .eq, onFail: .lines(1))))
            case 0xA:
                ops.append(CheatOp(.condition(address: addr, value: b, size: 2, compare: .ne, onFail: .lines(1))))
            case 0xD:
                guard a == 0xD000_0020 else { return err("a D code is the button check D0000020 yyyy") }
                ops.append(CheatOp(.buttons(UInt16(b) & 0x03FF, onFail: .lines(1))))
            case 9:
                return err("this is an encrypted CodeBreaker code (it starts with 9). The CodeBreaker scrambling isn't published anywhere I could verify, so it can't be decrypted here. Enter the unencrypted form of the codes instead")
            default:
                return err("code type \(String(type, radix: 16).uppercased()) isn't a CodeBreaker Advance code")
            }
            i += 1
        }
        return .success(CheatProgram(ops: ops, format: .codeBreaker, notes: notes))
    }
}
