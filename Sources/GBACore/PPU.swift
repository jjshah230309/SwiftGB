/// The picture processing unit: renders one scanline at a time into a 240x160 ARGB frame.
/// Layers are drawn into per-line buffers (BGR555, bit 15 = transparent) and then composed with windows and blending.
public final class PPU {
    unowned let bus: Bus
    private let io: UnsafeMutablePointer<UInt8>
    private let vram: UnsafeMutablePointer<UInt8>
    private let pram: UnsafeMutablePointer<UInt8>
    private let oam: UnsafeMutablePointer<UInt8>

    public let frame = UnsafeMutablePointer<UInt32>.allocate(capacity: 240 * 160)

    private static let clear: UInt16 = 0x8000
    private let bg = UnsafeMutablePointer<UInt16>.allocate(capacity: 4 * 240)
    private let objColor = UnsafeMutablePointer<UInt16>.allocate(capacity: 240)
    private let objPrio = UnsafeMutablePointer<UInt8>.allocate(capacity: 240)
    private let objSemi = UnsafeMutablePointer<Bool>.allocate(capacity: 240)
    private let objWindow = UnsafeMutablePointer<Bool>.allocate(capacity: 240)

    /// Internal affine reference points for BG2 (index 0) and BG3 (index 1); they advance by PB/PD every line.
    var refX: [Int32] = [0, 0]
    var refY: [Int32] = [0, 0]

    init(bus: Bus) {
        self.bus = bus
        io = bus.io; vram = bus.vram; pram = bus.pram; oam = bus.oam
        frame.initialize(repeating: 0xFF00_0000, count: 240 * 160)
    }

    func reset() {
        refX = [0, 0]; refY = [0, 0]
        frame.update(repeating: 0xFF00_0000, count: 240 * 160)
    }

    // MARK: register helpers
    @inline(__always) private func reg(_ o: Int) -> Int { Int(ld16(io, o)) }

    private func signExtend28(_ v: UInt32) -> Int32 { Int32(bitPattern: v << 4) >> 4 }

    /// Called after a write to BG2X/Y or BG3X/Y: the written value takes effect immediately as the internal reference.
    func latchReference(_ offset: Int) {
        let n = offset >= 0x38 ? 1 : 0
        let b = n == 0 ? 0x28 : 0x38
        refX[n] = signExtend28(ld32(io, b))
        refY[n] = signExtend28(ld32(io, b + 4))
    }

    /// Start of a frame: reload both reference points from their registers.
    public func reloadReferences() { latchReference(0x28); latchReference(0x38) }

    @inline(__always) private func vram8(_ a: Int) -> UInt8 { a < 0x18000 ? vram[a] : 0 }
    @inline(__always) private func bgColor(_ index: Int) -> UInt16 { ld16(pram, index * 2) & 0x7FFF }
    @inline(__always) private func objPaletteColor(_ index: Int) -> UInt16 { ld16(pram, 0x200 + index * 2) & 0x7FFF }

    // MARK: scanline
    public func renderLine(_ line: Int) {
        let dispcnt = reg(0)
        let out = frame + line * 240
        if dispcnt & 0x80 != 0 {                                       // forced blank: white
            out.update(repeating: 0xFFFF_FFFF, count: 240)
            advanceReferences()
            return
        }
        let mode = dispcnt & 7
        for i in 0..<(4 * 240) { bg[i] = PPU.clear }

        for n in 0..<4 where dispcnt & (0x100 << n) != 0 {
            let layer = bg + n * 240
            switch mode {
            case 0: renderText(n, line, layer)
            case 1: if n < 2 { renderText(n, line, layer) } else if n == 2 { renderAffine(n, line, layer) }
            case 2: if n >= 2 { renderAffine(n, line, layer) }
            case 3, 4, 5: if n == 2 { renderBitmap(mode, line, layer, dispcnt) }
            default: break
            }
            if reg(8 + 2 * n) & 0x40 != 0 { applyHorizontalMosaic(layer) }
        }

        for i in 0..<240 { objColor[i] = PPU.clear; objPrio[i] = 4; objSemi[i] = false; objWindow[i] = false }
        if dispcnt & 0x1000 != 0 { renderSprites(line, dispcnt) }

        compose(line, dispcnt, out)
        advanceReferences()
    }

    private func advanceReferences() {
        refX[0] = refX[0] &+ Int32(Int16(truncatingIfNeeded: reg(0x22)))
        refY[0] = refY[0] &+ Int32(Int16(truncatingIfNeeded: reg(0x26)))
        refX[1] = refX[1] &+ Int32(Int16(truncatingIfNeeded: reg(0x32)))
        refY[1] = refY[1] &+ Int32(Int16(truncatingIfNeeded: reg(0x36)))
    }

    private func applyHorizontalMosaic(_ layer: UnsafeMutablePointer<UInt16>) {
        let h = (reg(0x4C) & 15) + 1
        if h == 1 { return }
        for x in 0..<240 { layer[x] = layer[x - x % h] }
    }

    private func mosaicLine(_ n: Int, _ line: Int) -> Int {
        guard reg(8 + 2 * n) & 0x40 != 0 else { return line }
        let v = ((reg(0x4C) >> 4) & 15) + 1
        return line - line % v
    }

    // MARK: backgrounds
    private func renderText(_ n: Int, _ line: Int, _ out: UnsafeMutablePointer<UInt16>) {
        let cnt = reg(8 + 2 * n)
        let charBase = ((cnt >> 2) & 3) * 0x4000
        let mapBase = ((cnt >> 8) & 31) * 0x800
        let is256 = cnt & 0x80 != 0
        let size = (cnt >> 14) & 3
        let hofs = reg(0x10 + 4 * n) & 0x1FF
        let vofs = reg(0x12 + 4 * n) & 0x1FF
        let wmask = size & 1 != 0 ? 511 : 255
        let hmask = size & 2 != 0 ? 511 : 255
        let y = (mosaicLine(n, line) + vofs) & hmask
        for x in 0..<240 {
            let px = (x + hofs) & wmask
            var block = 0
            switch size {
            case 1: block = px >> 8
            case 2: block = y >> 8
            case 3: block = (px >> 8) + ((y >> 8) << 1)
            default: break
            }
            let entry = Int(ld16(vram, mapBase + block * 0x800 + (((y & 255) >> 3) * 32 + ((px & 255) >> 3)) * 2))
            var fx = px & 7, fy = y & 7
            if entry & 0x400 != 0 { fx = 7 - fx }
            if entry & 0x800 != 0 { fy = 7 - fy }
            let tile = entry & 0x3FF
            if is256 {
                let idx = Int(vram8(charBase + tile * 64 + fy * 8 + fx))
                if idx != 0 { out[x] = bgColor(idx) }
            } else {
                let byte = vram8(charBase + tile * 32 + fy * 4 + (fx >> 1))
                let idx = Int(fx & 1 != 0 ? byte >> 4 : byte & 15)
                if idx != 0 { out[x] = bgColor((entry >> 12) * 16 + idx) }
            }
        }
    }

    private func renderAffine(_ n: Int, _ line: Int, _ out: UnsafeMutablePointer<UInt16>) {
        let cnt = reg(8 + 2 * n)
        let charBase = ((cnt >> 2) & 3) * 0x4000
        let mapBase = ((cnt >> 8) & 31) * 0x800
        let dim = 128 << ((cnt >> 14) & 3)
        let wrap = cnt & 0x2000 != 0
        let pbase = n == 2 ? 0x20 : 0x30
        let pa = Int32(Int16(truncatingIfNeeded: reg(pbase))), pc = Int32(Int16(truncatingIfNeeded: reg(pbase + 4)))
        var cx = refX[n - 2], cy = refY[n - 2]
        let tilesPerRow = dim >> 3
        for x in 0..<240 {
            var px = Int(cx >> 8), py = Int(cy >> 8)
            cx = cx &+ pa; cy = cy &+ pc
            if wrap { px &= dim - 1; py &= dim - 1 } else if px < 0 || py < 0 || px >= dim || py >= dim { continue }
            let tile = Int(vram8(mapBase + (py >> 3) * tilesPerRow + (px >> 3)))
            let idx = Int(vram8(charBase + tile * 64 + (py & 7) * 8 + (px & 7)))
            if idx != 0 { out[x] = bgColor(idx) }
        }
    }

    private func renderBitmap(_ mode: Int, _ line: Int, _ out: UnsafeMutablePointer<UInt16>, _ dispcnt: Int) {
        let frameBase = (mode != 3 && dispcnt & 0x10 != 0) ? 0xA000 : 0
        let pa = Int32(Int16(truncatingIfNeeded: reg(0x20))), pc = Int32(Int16(truncatingIfNeeded: reg(0x24)))
        var cx = refX[0], cy = refY[0]
        let width = mode == 5 ? 160 : 240
        let height = mode == 5 ? 128 : 160
        for x in 0..<240 {
            let px = Int(cx >> 8), py = Int(cy >> 8)
            cx = cx &+ pa; cy = cy &+ pc
            if px < 0 || py < 0 || px >= width || py >= height { continue }
            switch mode {
            case 3: out[x] = ld16(vram, (py * 240 + px) * 2) & 0x7FFF
            case 4:
                let idx = Int(vram[frameBase + py * 240 + px])
                if idx != 0 { out[x] = bgColor(idx) }
            default: out[x] = ld16(vram, frameBase + (py * 160 + px) * 2) & 0x7FFF
            }
        }
    }

    // MARK: sprites
    private static let spriteSizes: [[(Int, Int)]] = [
        [(8, 8), (16, 16), (32, 32), (64, 64)],
        [(16, 8), (32, 8), (32, 16), (64, 32)],
        [(8, 16), (8, 32), (16, 32), (32, 64)],
    ]

    private func renderSprites(_ line: Int, _ dispcnt: Int) {
        let oneDimensional = dispcnt & 0x40 != 0
        let bitmapMode = (dispcnt & 7) >= 3
        for i in 0..<128 {
            let a0 = Int(ld16(oam, i * 8)), a1 = Int(ld16(oam, i * 8 + 2)), a2 = Int(ld16(oam, i * 8 + 4))
            let affine = a0 & 0x100 != 0
            if !affine && a0 & 0x200 != 0 { continue }                // disabled
            let gfxMode = (a0 >> 10) & 3
            if gfxMode == 3 { continue }
            let shape = (a0 >> 14) & 3
            if shape == 3 { continue }
            let (w, h) = PPU.spriteSizes[shape][(a1 >> 14) & 3]
            let double = affine && a0 & 0x200 != 0
            let boxW = double ? w * 2 : w, boxH = double ? h * 2 : h
            let y0 = a0 & 0xFF
            let dy = (line - y0) & 0xFF
            if dy >= boxH { continue }
            var x0 = a1 & 0x1FF; if x0 >= 256 { x0 -= 512 }
            let is256 = a0 & 0x2000 != 0
            let baseTile = a2 & 0x3FF
            let prio = UInt8((a2 >> 10) & 3)
            let palette = (a2 >> 12) & 15
            let rowTiles = oneDimensional ? (w >> 3) * (is256 ? 2 : 1) : 32
            var pa = 0x100, pb = 0, pc = 0, pd = 0x100
            var flipH = false, flipV = false
            if affine {
                let g = ((a1 >> 9) & 31) * 32
                pa = Int(Int16(truncatingIfNeeded: ld16(oam, g + 6))); pb = Int(Int16(truncatingIfNeeded: ld16(oam, g + 14)))
                pc = Int(Int16(truncatingIfNeeded: ld16(oam, g + 22))); pd = Int(Int16(truncatingIfNeeded: ld16(oam, g + 30)))
            } else {
                flipH = a1 & 0x1000 != 0; flipV = a1 & 0x2000 != 0
            }
            for bx in 0..<boxW {
                let sx = x0 + bx
                if sx < 0 || sx >= 240 { continue }
                var tx: Int, ty: Int
                if affine {
                    let ex = bx - boxW / 2, ey = dy - boxH / 2
                    tx = ((pa * ex + pb * ey) >> 8) + w / 2
                    ty = ((pc * ex + pd * ey) >> 8) + h / 2
                    if tx < 0 || ty < 0 || tx >= w || ty >= h { continue }
                } else {
                    tx = flipH ? w - 1 - bx : bx
                    ty = flipV ? h - 1 - dy : dy
                }
                var tile = baseTile + (ty >> 3) * rowTiles + (tx >> 3) * (is256 ? 2 : 1)
                tile &= 0x3FF
                if bitmapMode && tile < 512 { continue }
                let color: UInt16
                if is256 {
                    let idx = Int(vram8(0x10000 + tile * 32 + (ty & 7) * 8 + (tx & 7)))
                    if idx == 0 { continue }
                    color = objPaletteColor(idx)
                } else {
                    let byte = vram8(0x10000 + tile * 32 + (ty & 7) * 4 + ((tx & 7) >> 1))
                    let idx = Int(tx & 1 != 0 ? byte >> 4 : byte & 15)
                    if idx == 0 { continue }
                    color = objPaletteColor(palette * 16 + idx)
                }
                if gfxMode == 2 { objWindow[sx] = true; continue }
                if objColor[sx] == PPU.clear || prio < objPrio[sx] {
                    objColor[sx] = color; objPrio[sx] = prio; objSemi[sx] = gfxMode == 1
                }
            }
        }
    }

    // MARK: composition
    private func compose(_ line: Int, _ dispcnt: Int, _ out: UnsafeMutablePointer<UInt32>) {
        let backdrop = bgColor(0)
        let bldcnt = reg(0x50), bldalpha = reg(0x52), bldy = reg(0x54)
        let effect = (bldcnt >> 6) & 3
        let first = bldcnt & 0x3F, second = (bldcnt >> 8) & 0x3F
        let eva = min(16, bldalpha & 31), evb = min(16, (bldalpha >> 8) & 31), evy = min(16, bldy & 31)

        let win0 = dispcnt & 0x2000 != 0, win1 = dispcnt & 0x4000 != 0, winObj = dispcnt & 0x8000 != 0
        let anyWindow = win0 || win1 || winObj
        let winin = reg(0x48), winout = reg(0x4A)
        var in0y = false, in1y = false
        var w0x1 = 0, w0x2 = 0, w1x1 = 0, w1x2 = 0
        if win0 {
            let v = reg(0x44); in0y = within(line, v >> 8, v & 255)
            w0x1 = reg(0x40) >> 8; w0x2 = reg(0x40) & 255
        }
        if win1 {
            let v = reg(0x46); in1y = within(line, v >> 8, v & 255)
            w1x1 = reg(0x42) >> 8; w1x2 = reg(0x42) & 255
        }
        let bgPrio = (0..<4).map { UInt8(reg(8 + 2 * $0) & 3) }
        let bgOn = (0..<4).map { dispcnt & (0x100 << $0) != 0 }

        for x in 0..<240 {
            var mask = 0x3F
            if anyWindow {
                if win0 && in0y && within(x, w0x1, w0x2) { mask = winin & 0xFF }
                else if win1 && in1y && within(x, w1x1, w1x2) { mask = winin >> 8 }
                else if winObj && objWindow[x] { mask = winout >> 8 }
                else { mask = winout & 0xFF }
            }

            var topColor = backdrop, topLayer = 5, secondColor = backdrop, secondLayer = 5
            var found = 0
            search: for p in 0..<4 {
                if mask & 0x10 != 0 && objColor[x] != PPU.clear && Int(objPrio[x]) == p {
                    if found == 0 { topColor = objColor[x]; topLayer = 4; found = 1 }
                    else { secondColor = objColor[x]; secondLayer = 4; break search }
                }
                for n in 0..<4 where bgOn[n] && mask & (1 << n) != 0 && Int(bgPrio[n]) == p && bg[n * 240 + x] != PPU.clear {
                    if found == 0 { topColor = bg[n * 240 + x]; topLayer = n; found = 1 }
                    else { secondColor = bg[n * 240 + x]; secondLayer = n; break search }
                }
            }

            var color = topColor
            if mask & 0x20 != 0 {
                if topLayer == 4 && objSemi[x] && second & (1 << secondLayer) != 0 {
                    color = blendAlpha(topColor, secondColor, eva, evb)
                } else if first & (1 << topLayer) != 0 {
                    switch effect {
                    case 1: if second & (1 << secondLayer) != 0 { color = blendAlpha(topColor, secondColor, eva, evb) }
                    case 2: color = brighten(topColor, evy)
                    case 3: color = darken(topColor, evy)
                    default: break
                    }
                }
            }
            out[x] = PPU.argb(color)
        }
    }

    @inline(__always) private func within(_ v: Int, _ a: Int, _ b: Int) -> Bool {
        a <= b ? (v >= a && v < b) : (v >= a || v < b)
    }

    @inline(__always) private static func argb(_ c: UInt16) -> UInt32 {
        let r = UInt32(c & 31), g = UInt32((c >> 5) & 31), b = UInt32((c >> 10) & 31)
        return 0xFF00_0000 | ((r << 3 | r >> 2) << 16) | ((g << 3 | g >> 2) << 8) | (b << 3 | b >> 2)
    }

    private func blendAlpha(_ a: UInt16, _ b: UInt16, _ ea: Int, _ eb: Int) -> UInt16 {
        func ch(_ s: UInt16) -> UInt16 {
            let x = Int((a >> s) & 31), y = Int((b >> s) & 31)
            return UInt16(min(31, (x * ea + y * eb) >> 4)) << s
        }
        return ch(0) | ch(5) | ch(10)
    }

    private func brighten(_ a: UInt16, _ ev: Int) -> UInt16 {
        func ch(_ s: UInt16) -> UInt16 { let x = Int((a >> s) & 31); return UInt16(x + (((31 - x) * ev) >> 4)) << s }
        return ch(0) | ch(5) | ch(10)
    }

    private func darken(_ a: UInt16, _ ev: Int) -> UInt16 {
        func ch(_ s: UInt16) -> UInt16 { let x = Int((a >> s) & 31); return UInt16(x - ((x * ev) >> 4)) << s }
        return ch(0) | ch(5) | ch(10)
    }
}

// MARK: save states
extension PPU {
    func save(_ w: inout StateWriter) {
        w.tag("PPU0")
        w.u32s(refX.map { UInt32(bitPattern: $0) }); w.u32s(refY.map { UInt32(bitPattern: $0) })
    }
    func load(_ r: inout StateReader) {
        r.tag("PPU0")
        var x = [UInt32](repeating: 0, count: 2), y = [UInt32](repeating: 0, count: 2)
        r.u32s(&x); r.u32s(&y)
        refX = x.map { Int32(bitPattern: $0) }; refY = y.map { Int32(bitPattern: $0) }
    }
}
