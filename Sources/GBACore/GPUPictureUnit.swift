import Foundation
import Metal

/// Draws the Game Boy Advance picture on the GPU instead of the CPU (an opt-in alternative to the scanline renderer in `PPU`).
///
/// While the frame is emulated the PPU only *records* each scanline's video registers (a few dozen bytes). When the frame ends,
/// one compute pass draws every pixel from those records plus a copy of video memory. The result is the same picture as the
/// CPU renderer for any game that sets up video memory before the frame; the one difference is that changes to palette, tile
/// data or sprites made *during* the frame (by HBlank DMA or interrupts) show up for the whole frame rather than from the line
/// they were made on. Register changes (scrolling, windows, blending) are recorded per line, so those effects work.
final class GPUPictureUnit {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    /// Two sets of buffers, so the GPU can still be drawing frame N while the CPU records the lines of frame N+1.
    private struct Slot {
        let lines: MTLBuffer          // 160 line records, 128 bytes each
        let vram: MTLBuffer, pram: MTLBuffer, oam: MTLBuffer
        let out: MTLBuffer
    }
    private var slots = [Slot]()
    private var current = 0
    private var pending: (command: MTLCommandBuffer, slot: Int)?

    /// When true (the default) the picture handed back is the previous frame's, so the CPU never waits for the GPU; the picture is
    /// one frame (about 17 ms) late. When false each frame is waited for and shown at once (used by the tests).
    var pipelined = true

    static let recordSize = 128
    static let vramSize = 0x18000

    /// Nil if there is no GPU or the shader doesn't compile; the caller then keeps using the CPU.
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        guard let library = try? device.makeLibrary(source: GPUPictureUnit.source, options: nil),
              let function = library.makeFunction(name: "drawPicture"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        func buffer(_ n: Int) -> MTLBuffer? { device.makeBuffer(length: n, options: .storageModeShared) }
        for _ in 0..<2 {
            guard let l = buffer(160 * Self.recordSize), let v = buffer(Self.vramSize), let p = buffer(0x400), let o = buffer(0x400),
                  let out = buffer(240 * 160 * 4) else { return nil }
            memset(l.contents(), 0, l.length)
            slots.append(Slot(lines: l, vram: v, pram: p, oam: o, out: out))
        }
        self.device = device; self.queue = queue; self.pipeline = pipeline
    }

    /// Remember how line `line` is set up: registers 0x00-0x5F and the affine reference points as they are before the line draws.
    func record(line: Int, io: UnsafePointer<UInt8>, refX: [Int32], refY: [Int32]) {
        let base = slots[current].lines.contents() + line * Self.recordSize
        memcpy(base, io, 96)
        let ints = base.advanced(by: 96).assumingMemoryBound(to: Int32.self)
        ints[0] = refX[0]; ints[1] = refX[1]; ints[2] = refY[0]; ints[3] = refY[1]
        base.advanced(by: 112).assumingMemoryBound(to: UInt32.self)[0] = 1        // valid
    }

    /// Copy the finished picture of the frame the GPU was working on into `frame`.
    private func harvest(into frame: UnsafeMutablePointer<UInt32>) {
        guard let p = pending else { return }
        p.command.waitUntilCompleted()
        memcpy(frame, slots[p.slot].out.contents(), 240 * 160 * 4)
        let base = slots[p.slot].lines.contents()
        for l in 0..<160 { base.advanced(by: l * Self.recordSize + 112).assumingMemoryBound(to: UInt32.self)[0] = 0 }
        pending = nil
    }

    /// Draw the frame whose lines were just recorded. Lines that weren't recorded keep whatever `frame` already holds.
    func render(vram: UnsafePointer<UInt8>, pram: UnsafePointer<UInt8>, oam: UnsafePointer<UInt8>, frame: UnsafeMutablePointer<UInt32>) {
        harvest(into: frame)                                      // the previous frame's picture, if it was left running
        let slot = slots[current]
        memcpy(slot.vram.contents(), vram, Self.vramSize)
        memcpy(slot.pram.contents(), pram, 0x400)
        memcpy(slot.oam.contents(), oam, 0x400)
        memcpy(slot.out.contents(), frame, 240 * 160 * 4)
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(slot.lines, offset: 0, index: 0)
        enc.setBuffer(slot.vram, offset: 0, index: 1)
        enc.setBuffer(slot.pram, offset: 0, index: 2)
        enc.setBuffer(slot.oam, offset: 0, index: 3)
        enc.setBuffer(slot.out, offset: 0, index: 4)
        enc.dispatchThreads(MTLSize(width: 240, height: 160, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        enc.endEncoding()
        cb.commit()
        pending = (cb, current)
        current = 1 - current
        if !pipelined { harvest(into: frame) }
    }

    // The shader mirrors PPU.swift pixel for pixel; keep the two in step.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Line { ushort r[48]; int refX[2]; int refY[2]; uint valid; uint pad[3]; };

    inline int ld16(device const uchar* p, int o) { return int(p[o]) | (int(p[o + 1]) << 8); }
    inline int vram8(device const uchar* v, int a) { return a < 0x18000 ? int(v[a]) : 0; }
    inline int bgColor(device const uchar* pram, int i) { return ld16(pram, i * 2) & 0x7FFF; }
    inline int objColor16(device const uchar* pram, int i) { return ld16(pram, 0x200 + i * 2) & 0x7FFF; }
    inline int wrapMul(int a, int b) { return int(uint(a) * uint(b)); }
    inline bool within(int v, int a, int b) { return a <= b ? (v >= a && v < b) : (v >= a || v < b); }

    inline uint argb(int c) {
        uint r = uint(c & 31), g = uint((c >> 5) & 31), b = uint((c >> 10) & 31);
        return 0xFF000000u | (((r << 3) | (r >> 2)) << 16) | (((g << 3) | (g >> 2)) << 8) | ((b << 3) | (b >> 2));
    }
    inline int blendAlpha(int a, int b, int ea, int eb) {
        int out = 0;
        for (int s = 0; s <= 10; s += 5) {
            int x = (a >> s) & 31, y = (b >> s) & 31;
            out |= min(31, (x * ea + y * eb) >> 4) << s;
        }
        return out;
    }
    inline int brighten(int a, int ev) {
        int out = 0;
        for (int s = 0; s <= 10; s += 5) { int x = (a >> s) & 31; out |= (x + (((31 - x) * ev) >> 4)) << s; }
        return out;
    }
    inline int darken(int a, int ev) {
        int out = 0;
        for (int s = 0; s <= 10; s += 5) { int x = (a >> s) & 31; out |= (x - ((x * ev) >> 4)) << s; }
        return out;
    }

    constant int CLEAR = 0x8000;

    inline int textPixel(constant Line& L, device const uchar* vram, device const uchar* pram, int n, int x, int line) {
        int cnt = L.r[4 + n];
        int charBase = ((cnt >> 2) & 3) * 0x4000, mapBase = ((cnt >> 8) & 31) * 0x800;
        bool is256 = (cnt & 0x80) != 0;
        int size = (cnt >> 14) & 3;
        int hofs = L.r[8 + 2 * n] & 0x1FF, vofs = L.r[9 + 2 * n] & 0x1FF;
        int wmask = (size & 1) ? 511 : 255, hmask = (size & 2) ? 511 : 255;
        int ml = line;
        if (cnt & 0x40) { int v = ((L.r[0x26] >> 4) & 15) + 1; ml = line - line % v; }
        int y = (ml + vofs) & hmask;
        int px = (x + hofs) & wmask;
        int block = 0;
        if (size == 1) block = px >> 8; else if (size == 2) block = y >> 8; else if (size == 3) block = (px >> 8) + ((y >> 8) << 1);
        int entry = ld16(vram, mapBase + block * 0x800 + (((y & 255) >> 3) * 32 + ((px & 255) >> 3)) * 2);
        int fx = px & 7, fy = y & 7;
        if (entry & 0x400) fx = 7 - fx;
        if (entry & 0x800) fy = 7 - fy;
        int tile = entry & 0x3FF;
        if (is256) {
            int idx = vram8(vram, charBase + tile * 64 + fy * 8 + fx);
            return idx != 0 ? bgColor(pram, idx) : CLEAR;
        }
        int byte = vram8(vram, charBase + tile * 32 + fy * 4 + (fx >> 1));
        int idx = (fx & 1) ? (byte >> 4) : (byte & 15);
        return idx != 0 ? bgColor(pram, (entry >> 12) * 16 + idx) : CLEAR;
    }

    inline int affinePixel(constant Line& L, device const uchar* vram, device const uchar* pram, int n, int x) {
        int cnt = L.r[4 + n];
        int charBase = ((cnt >> 2) & 3) * 0x4000, mapBase = ((cnt >> 8) & 31) * 0x800;
        int dim = 128 << ((cnt >> 14) & 3);
        bool wrap = (cnt & 0x2000) != 0;
        int pbase = n == 2 ? 0x10 : 0x18;                       // register offset / 2
        int pa = short(L.r[pbase]), pc = short(L.r[pbase + 2]);
        int cx = int(uint(L.refX[n - 2]) + uint(wrapMul(pa, x))), cy = int(uint(L.refY[n - 2]) + uint(wrapMul(pc, x)));
        int px = cx >> 8, py = cy >> 8;
        if (wrap) { px &= dim - 1; py &= dim - 1; }
        else if (px < 0 || py < 0 || px >= dim || py >= dim) return CLEAR;
        int tilesPerRow = dim >> 3;
        int tile = vram8(vram, mapBase + (py >> 3) * tilesPerRow + (px >> 3));
        int idx = vram8(vram, charBase + tile * 64 + (py & 7) * 8 + (px & 7));
        return idx != 0 ? bgColor(pram, idx) : CLEAR;
    }

    inline int bitmapPixel(constant Line& L, device const uchar* vram, device const uchar* pram, int mode, int x, int dispcnt) {
        int frameBase = (mode != 3 && (dispcnt & 0x10)) ? 0xA000 : 0;
        int pa = short(L.r[0x10]), pc = short(L.r[0x12]);
        int width = mode == 5 ? 160 : 240, height = mode == 5 ? 128 : 160;
        int cx = int(uint(L.refX[0]) + uint(wrapMul(pa, x))), cy = int(uint(L.refY[0]) + uint(wrapMul(pc, x)));
        int px = cx >> 8, py = cy >> 8;
        if (px < 0 || py < 0 || px >= width || py >= height) return CLEAR;
        if (mode == 3) return ld16(vram, (py * 240 + px) * 2) & 0x7FFF;
        if (mode == 4) { int idx = int(vram[frameBase + py * 240 + px]); return idx != 0 ? bgColor(pram, idx) : CLEAR; }
        return ld16(vram, frameBase + (py * 160 + px) * 2) & 0x7FFF;
    }

    kernel void drawPicture(constant Line* lines [[buffer(0)]],
                            device const uchar* vram [[buffer(1)]],
                            device const uchar* pram [[buffer(2)]],
                            device const uchar* oam [[buffer(3)]],
                            device uint* out [[buffer(4)]],
                            uint2 gid [[thread_position_in_grid]]) {
        int x = int(gid.x), line = int(gid.y);
        if (x >= 240 || line >= 160) return;
        constant Line& L = lines[line];
        if (L.valid == 0) return;
        int dispcnt = L.r[0];
        if (dispcnt & 0x80) { out[line * 240 + x] = 0xFFFFFFFFu; return; }
        int mode = dispcnt & 7;

        // Backgrounds
        int bg[4] = { CLEAR, CLEAR, CLEAR, CLEAR };
        int mosaicH = (L.r[0x26] & 15) + 1;
        for (int n = 0; n < 4; n++) {
            if (!(dispcnt & (0x100 << n))) continue;
            int xs = x;
            if ((L.r[4 + n] & 0x40) && mosaicH != 1) xs = x - x % mosaicH;
            int c = CLEAR;
            if (mode == 0) c = textPixel(L, vram, pram, n, xs, line);
            else if (mode == 1) { if (n < 2) c = textPixel(L, vram, pram, n, xs, line); else if (n == 2) c = affinePixel(L, vram, pram, n, xs); }
            else if (mode == 2) { if (n >= 2) c = affinePixel(L, vram, pram, n, xs); }
            else if (mode >= 3 && mode <= 5) { if (n == 2) c = bitmapPixel(L, vram, pram, mode, xs, dispcnt); }
            bg[n] = c;
        }

        // Sprites
        int objColor = CLEAR, objPrio = 4;
        bool objSemi = false, objWin = false;
        if (dispcnt & 0x1000) {
            bool oneD = (dispcnt & 0x40) != 0, bitmapMode = mode >= 3;
            for (int i = 0; i < 128; i++) {
                int a0 = ld16(oam, i * 8), a1 = ld16(oam, i * 8 + 2), a2 = ld16(oam, i * 8 + 4);
                bool affine = (a0 & 0x100) != 0;
                if (!affine && (a0 & 0x200)) continue;
                int gfxMode = (a0 >> 10) & 3;
                if (gfxMode == 3) continue;
                int shape = (a0 >> 14) & 3;
                if (shape == 3) continue;
                int sz = (a1 >> 14) & 3;
                int w, h;
                if (shape == 0) { w = 8 << sz; h = 8 << sz; }
                else if (shape == 1) { const int W[4] = {16, 32, 32, 64}, H[4] = {8, 8, 16, 32}; w = W[sz]; h = H[sz]; }
                else { const int W[4] = {8, 8, 16, 32}, H[4] = {16, 32, 32, 64}; w = W[sz]; h = H[sz]; }
                bool dbl = affine && (a0 & 0x200) != 0;
                int boxW = dbl ? w * 2 : w, boxH = dbl ? h * 2 : h;
                int dy = (line - (a0 & 0xFF)) & 0xFF;
                if (dy >= boxH) continue;
                int x0 = a1 & 0x1FF; if (x0 >= 256) x0 -= 512;
                int bx = x - x0;
                if (bx < 0 || bx >= boxW) continue;
                bool is256 = (a0 & 0x2000) != 0;
                int baseTile = a2 & 0x3FF, prio = (a2 >> 10) & 3, palette = (a2 >> 12) & 15;
                int rowTiles = oneD ? (w >> 3) * (is256 ? 2 : 1) : 32;
                int tx, ty;
                if (affine) {
                    int g = ((a1 >> 9) & 31) * 32;
                    int pa = short(ld16(oam, g + 6)), pb = short(ld16(oam, g + 14)), pc = short(ld16(oam, g + 22)), pd = short(ld16(oam, g + 30));
                    int ex = bx - boxW / 2, ey = dy - boxH / 2;
                    tx = ((pa * ex + pb * ey) >> 8) + w / 2;
                    ty = ((pc * ex + pd * ey) >> 8) + h / 2;
                    if (tx < 0 || ty < 0 || tx >= w || ty >= h) continue;
                } else {
                    tx = (a1 & 0x1000) ? w - 1 - bx : bx;
                    ty = (a1 & 0x2000) ? h - 1 - dy : dy;
                }
                int tile = (baseTile + (ty >> 3) * rowTiles + (tx >> 3) * (is256 ? 2 : 1)) & 0x3FF;
                if (bitmapMode && tile < 512) continue;
                int color;
                if (is256) {
                    int idx = vram8(vram, 0x10000 + tile * 32 + (ty & 7) * 8 + (tx & 7));
                    if (idx == 0) continue;
                    color = objColor16(pram, idx);
                } else {
                    int byte = vram8(vram, 0x10000 + tile * 32 + (ty & 7) * 4 + ((tx & 7) >> 1));
                    int idx = (tx & 1) ? (byte >> 4) : (byte & 15);
                    if (idx == 0) continue;
                    color = objColor16(pram, palette * 16 + idx);
                }
                if (gfxMode == 2) { objWin = true; continue; }
                if (objColor == CLEAR || prio < objPrio) { objColor = color; objPrio = prio; objSemi = gfxMode == 1; }
            }
        }

        // Composition
        int backdrop = ld16(pram, 0) & 0x7FFF;
        int bldcnt = L.r[0x28], bldalpha = L.r[0x29], bldy = L.r[0x2A];
        int effect = (bldcnt >> 6) & 3, first = bldcnt & 0x3F, second = (bldcnt >> 8) & 0x3F;
        int eva = min(16, bldalpha & 31), evb = min(16, (bldalpha >> 8) & 31), evy = min(16, bldy & 31);
        bool win0 = (dispcnt & 0x2000) != 0, win1 = (dispcnt & 0x4000) != 0, winObj = (dispcnt & 0x8000) != 0;
        int winin = L.r[0x24], winout = L.r[0x25];
        int mask = 0x3F;
        if (win0 || win1 || winObj) {
            bool in0 = false, in1 = false;
            if (win0) { int v = L.r[0x22]; in0 = within(line, v >> 8, v & 255) && within(x, L.r[0x20] >> 8, L.r[0x20] & 255); }
            if (win1) { int v = L.r[0x23]; in1 = within(line, v >> 8, v & 255) && within(x, L.r[0x21] >> 8, L.r[0x21] & 255); }
            if (in0) mask = winin & 0xFF;
            else if (in1) mask = winin >> 8;
            else if (winObj && objWin) mask = winout >> 8;
            else mask = winout & 0xFF;
        }

        int order[4], orderPrio[4], orderCount = 0;
        for (int p = 0; p < 4; p++)
            for (int n = 0; n < 4; n++)
                if ((dispcnt & (0x100 << n)) && (L.r[4 + n] & 3) == p) { order[orderCount] = n; orderPrio[orderCount] = p; orderCount++; }

        int topColor = backdrop, topLayer = 5, secondColor = backdrop, secondLayer = 5;
        bool objVisible = (mask & 0x10) != 0 && objColor != CLEAR;
        int objP = objVisible ? objPrio : 4;
        bool objPending = objVisible;
        int found = 0, k = 0;
        while (true) {
            int layer = -1, c = 0;
            if (objPending && (k >= orderCount || objP <= orderPrio[k])) { layer = 4; c = objColor; objPending = false; }
            else if (k < orderCount) {
                int n = order[k]; k++;
                if (mask & (1 << n)) { int v = bg[n]; if (v != CLEAR) { layer = n; c = v; } }
                if (layer < 0) continue;
            } else break;
            if (found == 0) {
                topColor = c; topLayer = layer; found = 1;
                bool wantSecond = (mask & 0x20) != 0 && ((layer == 4 && objSemi) || (effect == 1 && (first & (1 << layer)) != 0));
                if (!wantSecond) break;
            } else { secondColor = c; secondLayer = layer; break; }
        }
        int color = topColor;
        if (mask & 0x20) {
            if (topLayer == 4 && objSemi && (second & (1 << secondLayer))) color = blendAlpha(topColor, secondColor, eva, evb);
            else if (first & (1 << topLayer)) {
                if (effect == 1) { if (second & (1 << secondLayer)) color = blendAlpha(topColor, secondColor, eva, evb); }
                else if (effect == 2) color = brighten(topColor, evy);
                else if (effect == 3) color = darken(topColor, evy);
            }
        }
        out[line * 240 + x] = argb(color);
    }
    """
}
