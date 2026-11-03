import Foundation

/// The Game Boy's LCD controller. Timing is event-driven in dots: a line is 456 dots (OAM scan 80, drawing 172+, then HBlank),
/// there are 144 visible lines and 10 of VBlank. Each visible line is rendered in one go when drawing ends.
final class GBPPU {
    unowned let system: GBSystem
    let frame = UnsafeMutablePointer<UInt32>.allocate(capacity: 160 * 144)
    /// The 2-bit shade of every pixel after palette lookup (original Game Boy only; kept for tests).
    let shades = UnsafeMutablePointer<UInt8>.allocate(capacity: 160 * 144)

    // registers
    var lcdc: UInt8 = 0x91
    var statEnable: UInt8 = 0
    var scy: UInt8 = 0, scx: UInt8 = 0, lyc: UInt8 = 0
    var bgp: UInt8 = 0xFC, obp0: UInt8 = 0xFF, obp1: UInt8 = 0xFF
    var wy: UInt8 = 0, wx: UInt8 = 0
    // Color palettes (8 palettes x 4 colours x 2 bytes each)
    var bcps: UInt8 = 0, ocps: UInt8 = 0
    var bgPalette = [UInt8](repeating: 0xFF, count: 64)
    var objPalette = [UInt8](repeating: 0xFF, count: 64)

    // timing state
    var ly = 0
    var mode = 0
    var coincidence = false
    private var statLine = false
    var windowLine = 0
    private var windowTriggered = false
    var frameReady = false
    var nextEvent: UInt64 = .max
    private var lineStart: UInt64 = 0
    private enum Phase { case toMode3, toMode0, toNextLine }
    private var phase = Phase.toMode3
    private var mode3Length = 172

    // per-line scratch
    private let bgIndex = UnsafeMutablePointer<UInt8>.allocate(capacity: 160)
    private let bgPriority = UnsafeMutablePointer<Bool>.allocate(capacity: 160)
    private let spriteClaimed = UnsafeMutablePointer<Bool>.allocate(capacity: 160)

    /// Classic Game Boy greens, lightest to darkest.
    static let dmgColors: [UInt32] = [0xFFE0F8D0, 0xFF88C070, 0xFF346856, 0xFF081820]

    var lcdOn: Bool { lcdc & 0x80 != 0 }
    var inHBlank: Bool { lcdOn && mode == 0 }

    init(system: GBSystem) {
        self.system = system
        frame.initialize(repeating: GBPPU.dmgColors[0], count: 160 * 144)
        shades.initialize(repeating: 0, count: 160 * 144)
    }

    deinit { frame.deallocate(); shades.deallocate(); bgIndex.deallocate(); bgPriority.deallocate(); spriteClaimed.deallocate() }

    func powerOnState() {
        lcdc = 0x91; bgp = 0xFC; obp0 = 0xFF; obp1 = 0xFF
        if system.isCGB { for i in 0..<64 { bgPalette[i] = 0xFF; objPalette[i] = 0xFF } }
        beginLine(0, at: 0)
    }

    // MARK: registers
    func read(_ o: UInt8) -> UInt8 {
        switch o {
        case 0x40: return lcdc
        case 0x41: return 0x80 | statEnable | (lcdOn ? (coincidence ? 4 : 0) | UInt8(mode) : 0)
        case 0x42: return scy
        case 0x43: return scx
        case 0x44: return lcdOn ? UInt8(ly) : 0
        case 0x45: return lyc
        case 0x46: return system.io[0x46]
        case 0x47: return bgp
        case 0x48: return obp0
        case 0x49: return obp1
        case 0x4A: return wy
        default: return wx
        }
    }

    func write(_ o: UInt8, _ v: UInt8) {
        switch o {
        case 0x40:
            let wasOn = lcdOn
            lcdc = v
            if wasOn && !lcdOn { turnOff() } else if !wasOn && lcdOn { beginLine(0, at: system.dots) }
            system.nextEvent = nextEvent
        case 0x41: statEnable = v & 0x78; updateStatLine()
        case 0x42: scy = v
        case 0x43: scx = v
        case 0x44: break
        case 0x45: lyc = v; if lcdOn { coincidence = ly == Int(lyc); updateStatLine() }
        case 0x47: bgp = v
        case 0x48: obp0 = v
        case 0x49: obp1 = v
        case 0x4A: wy = v
        case 0x4B: wx = v
        default: break
        }
    }

    func readPalette(_ o: UInt8) -> UInt8 {
        switch o {
        case 0x68: return bcps | 0x40
        case 0x69: return bgPalette[Int(bcps & 0x3F)]
        case 0x6A: return ocps | 0x40
        default: return objPalette[Int(ocps & 0x3F)]
        }
    }

    func writePalette(_ o: UInt8, _ v: UInt8) {
        switch o {
        case 0x68: bcps = v & 0xBF
        case 0x69:
            bgPalette[Int(bcps & 0x3F)] = v
            if bcps & 0x80 != 0 { bcps = 0x80 | ((bcps &+ 1) & 0x3F) }
        case 0x6A: ocps = v & 0xBF
        default:
            objPalette[Int(ocps & 0x3F)] = v
            if ocps & 0x80 != 0 { ocps = 0x80 | ((ocps &+ 1) & 0x3F) }
        }
    }

    // MARK: timing
    private func turnOff() {
        ly = 0; mode = 0; coincidence = false; statLine = false; nextEvent = .max; windowLine = 0; windowTriggered = false
        for i in 0..<(160 * 144) { frame[i] = system.isCGB ? 0xFFFFFFFF : GBPPU.dmgColors[0]; shades[i] = 0 }
    }

    private func updateStatLine() {
        let line = lcdOn && ((mode == 0 && statEnable & 0x08 != 0) || (mode == 1 && statEnable & 0x10 != 0)
                             || (mode == 2 && statEnable & 0x20 != 0) || (coincidence && statEnable & 0x40 != 0))
        if line && !statLine { system.ifr |= 0x02 }
        statLine = line
    }

    private func beginLine(_ n: Int, at t: UInt64) {
        ly = n
        lineStart = t
        coincidence = n == Int(lyc)
        if n == 0 { windowLine = 0; windowTriggered = false }
        if n < 144 {
            mode = 2
            phase = .toMode3
            nextEvent = t + 80
        } else {
            mode = 1
            if n == 144 { system.ifr |= 0x01; frameReady = true }
            phase = .toNextLine
            nextEvent = t + 456
        }
        updateStatLine()
    }

    func advance(to dots: UInt64) {
        guard lcdOn else { nextEvent = .max; return }
        while nextEvent <= dots {
            let t = nextEvent
            switch phase {
            case .toMode3:
                mode = 3
                mode3Length = 172 + Int(scx & 7) + spritesOnLine(ly) * 6 + (windowWillShow() ? 6 : 0)
                phase = .toMode0
                nextEvent = t + UInt64(mode3Length)
                updateStatLine()
            case .toMode0:
                renderLine(ly)
                mode = 0
                if system.isCGB && system.hdmaActive { system.hdmaPending = true }
                phase = .toNextLine
                nextEvent = lineStart + 456
                updateStatLine()
            case .toNextLine:
                beginLine((ly + 1) % 154, at: lineStart + 456)
            }
        }
    }

    private func windowWillShow() -> Bool {
        lcdc & 0x20 != 0 && wx <= 166 && (windowTriggered || ly == Int(wy))
    }

    private func spritesOnLine(_ y: Int) -> Int {
        guard lcdc & 2 != 0 else { return 0 }
        let h = lcdc & 4 != 0 ? 16 : 8
        var n = 0
        for i in 0..<40 {
            let sy = Int(system.oam[i * 4]) - 16
            if y >= sy && y < sy + h { n += 1; if n == 10 { break } }
        }
        return n
    }

    // MARK: rendering
    private func argb555(_ lo: UInt8, _ hi: UInt8) -> UInt32 {
        let c = UInt32(lo) | UInt32(hi) << 8
        let r = c & 31, g = (c >> 5) & 31, b = (c >> 10) & 31
        return 0xFF00_0000 | ((r << 3 | r >> 2) << 16) | ((g << 3 | g >> 2) << 8) | (b << 3 | b >> 2)
    }

    private func renderLine(_ y: Int) {
        let sys = system
        let out = frame + y * 160, shadeOut = shades + y * 160
        let cgb = sys.isCGB
        let vram = sys.vram
        for x in 0..<160 { bgIndex[x] = 0; bgPriority[x] = false; spriteClaimed[x] = false }

        // Background colour per pixel (index 0...3 and, for Color, its palette), then window over it.
        let bgOn = cgb || lcdc & 1 != 0
        if bgOn {
            let mapBase = lcdc & 0x08 != 0 ? 0x1C00 : 0x1800
            let py = (y + Int(scy)) & 255
            for x in 0..<160 {
                let px = (x + Int(scx)) & 255
                drawBackgroundPixel(x, mapBase: mapBase, px: px, py: py, out: out, shadeOut: shadeOut)
            }
        } else {
            for x in 0..<160 { out[x] = cgb ? 0xFFFFFFFF : GBPPU.dmgColors[0]; shadeOut[x] = 0 }
        }

        if lcdc & 0x20 != 0 && Int(wx) <= 166 && (cgb || lcdc & 1 != 0) {
            if y == Int(wy) { windowTriggered = true }
            if windowTriggered {
                let mapBase = lcdc & 0x40 != 0 ? 0x1C00 : 0x1800
                let startX = Int(wx) - 7
                for x in max(0, startX)..<160 {
                    drawBackgroundPixel(x, mapBase: mapBase, px: x - startX, py: windowLine, out: out, shadeOut: shadeOut)
                }
                windowLine += 1
            }
        } else if lcdc & 0x20 != 0 && y == Int(wy) {
            windowTriggered = true
        }

        if lcdc & 2 != 0 { drawSprites(y, out: out, shadeOut: shadeOut) }
    }

    private func drawBackgroundPixel(_ x: Int, mapBase: Int, px: Int, py: Int, out: UnsafeMutablePointer<UInt32>, shadeOut: UnsafeMutablePointer<UInt8>) {
        let vram = system.vram
        let mapIndex = mapBase + (py >> 3) * 32 + (px >> 3)
        let tile = Int(vram[mapIndex])
        var attr: UInt8 = 0
        if system.isCGB { attr = vram[0x2000 + mapIndex] }
        let tileAddr = lcdc & 0x10 != 0 ? tile * 16 : 0x1000 + Int(Int8(truncatingIfNeeded: tile)) * 16
        var line = py & 7
        if attr & 0x40 != 0 { line = 7 - line }
        let base = (attr & 0x08 != 0 ? 0x2000 : 0) + tileAddr + line * 2
        let lo = vram[base], hi = vram[base + 1]
        var bit = 7 - (px & 7)
        if attr & 0x20 != 0 { bit = 7 - bit }
        let idx = Int((hi >> UInt8(bit)) & 1) << 1 | Int((lo >> UInt8(bit)) & 1)
        bgIndex[x] = UInt8(idx)
        if system.isCGB {
            bgPriority[x] = attr & 0x80 != 0
            let p = Int(attr & 7) * 8 + idx * 2
            out[x] = argb555(bgPalette[p], bgPalette[p + 1])
        } else {
            let shade = Int((bgp >> UInt8(idx * 2)) & 3)
            out[x] = GBPPU.dmgColors[shade]; shadeOut[x] = UInt8(shade)
        }
    }

    private func drawSprites(_ y: Int, out: UnsafeMutablePointer<UInt32>, shadeOut: UnsafeMutablePointer<UInt8>) {
        let sys = system, vram = sys.vram, oam = sys.oam
        let tall = lcdc & 4 != 0
        let height = tall ? 16 : 8
        var chosen = [Int]()
        for i in 0..<40 {
            let sy = Int(oam[i * 4]) - 16
            if y >= sy && y < sy + height { chosen.append(i); if chosen.count == 10 { break } }
        }
        let cgb = sys.isCGB
        if !(cgb && sys.opri == 0) { chosen.sort { (a, b) in
            let xa = Int(oam[a * 4 + 1]), xb = Int(oam[b * 4 + 1])
            return xa != xb ? xa < xb : a < b
        } }
        let objOnTop = cgb && lcdc & 1 == 0
        for i in chosen {
            let sy = Int(oam[i * 4]) - 16, sx = Int(oam[i * 4 + 1]) - 8
            var tile = Int(oam[i * 4 + 2])
            let attr = oam[i * 4 + 3]
            var row = y - sy
            if attr & 0x40 != 0 { row = height - 1 - row }
            if tall { tile = (tile & 0xFE) | (row >> 3); row &= 7 }
            let base = (cgb && attr & 0x08 != 0 ? 0x2000 : 0) + tile * 16 + row * 2
            let lo = vram[base], hi = vram[base + 1]
            for px in 0..<8 {
                let x = sx + px
                if x < 0 || x >= 160 || spriteClaimed[x] { continue }
                let bit = attr & 0x20 != 0 ? px : 7 - px
                let idx = Int((hi >> UInt8(bit)) & 1) << 1 | Int((lo >> UInt8(bit)) & 1)
                if idx == 0 { continue }
                spriteClaimed[x] = true
                if cgb {
                    if !objOnTop && bgIndex[x] != 0 && (attr & 0x80 != 0 || bgPriority[x]) { continue }
                    let p = Int(attr & 7) * 8 + idx * 2
                    out[x] = argb555(objPalette[p], objPalette[p + 1])
                } else {
                    if attr & 0x80 != 0 && bgIndex[x] != 0 { continue }
                    let pal = attr & 0x10 != 0 ? obp1 : obp0
                    let shade = Int((pal >> UInt8(idx * 2)) & 3)
                    out[x] = GBPPU.dmgColors[shade]; shadeOut[x] = UInt8(shade)
                }
            }
        }
    }
}

// MARK: save states
extension GBPPU {
    func save(_ w: inout StateWriter) {
        w.tag("GPU0")
        w.u8(lcdc); w.u8(statEnable); w.u8(scy); w.u8(scx); w.u8(lyc); w.u8(bgp); w.u8(obp0); w.u8(obp1); w.u8(wy); w.u8(wx)
        w.u8(bcps); w.u8(ocps); w.u8s(bgPalette); w.u8s(objPalette)
        w.int(ly); w.int(mode); w.bool(coincidence); w.bool(statLine); w.int(windowLine); w.bool(windowTriggered); w.bool(frameReady)
        w.u64(nextEvent); w.u64(lineStart); w.u8(phase == .toMode3 ? 0 : phase == .toMode0 ? 1 : 2); w.int(mode3Length)
    }

    func load(_ r: inout StateReader) {
        r.tag("GPU0")
        lcdc = r.u8(); statEnable = r.u8(); scy = r.u8(); scx = r.u8(); lyc = r.u8(); bgp = r.u8(); obp0 = r.u8(); obp1 = r.u8(); wy = r.u8(); wx = r.u8()
        bcps = r.u8(); ocps = r.u8(); r.u8s(&bgPalette); r.u8s(&objPalette)
        ly = r.int(); mode = r.int(); coincidence = r.bool(); statLine = r.bool(); windowLine = r.int(); windowTriggered = r.bool(); frameReady = r.bool()
        nextEvent = r.u64(); lineStart = r.u64()
        switch r.u8() { case 0: phase = .toMode3; case 1: phase = .toMode0; default: phase = .toNextLine }
        mode3Length = r.int()
    }
}
