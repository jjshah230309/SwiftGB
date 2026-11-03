import Foundation
import GBACore

// Builds small scenes directly in video memory, renders scanlines, and checks pixels against values worked out by hand.
// This covers the parts of the PPU the public test ROMs do not (flips, scrolling, sprites, windows, blending, affine, mosaic).

private func bgr(_ r: Int, _ g: Int, _ b: Int) -> UInt16 { UInt16(r | g << 5 | b << 10) }
private func argb(_ c: UInt16) -> UInt32 {
    let r = UInt32(c & 31), g = UInt32((c >> 5) & 31), b = UInt32((c >> 10) & 31)
    return 0xFF00_0000 | ((r << 3 | r >> 2) << 16) | ((g << 3 | g >> 2) << 8) | (b << 3 | b >> 2)
}

private final class Scene {
    let gba = GBASystem()
    var bus: Bus { gba.bus }
    init() {
        gba.load(rom: Data(count: 0x200))
        for i in 0..<128 { bus.poke16(0x0700_0000 + UInt32(i * 8), 0x200) }        // hide every sprite
    }
    func io(_ o: UInt32, _ v: UInt16) { bus.poke16(0x0400_0000 + o, v) }
    func pal(_ i: Int, _ c: UInt16) { bus.poke16(0x0500_0000 + UInt32(i * 2), c) }
    func objPal(_ i: Int, _ c: UInt16) { pal(256 + i, c) }
    func vram(_ off: Int, _ v: UInt8) { bus.vram[off] = v }
    func vram16(_ off: Int, _ v: UInt16) { bus.vram[off] = UInt8(v & 255); bus.vram[off + 1] = UInt8(v >> 8) }
    func oam(_ i: Int, _ a0: UInt16, _ a1: UInt16, _ a2: UInt16) {
        let b = 0x0700_0000 + UInt32(i * 8)
        bus.poke16(b, a0); bus.poke16(b + 2, a1); bus.poke16(b + 4, a2)
    }
    func oamParam(group: Int, _ pa: Int16, _ pb: Int16, _ pc: Int16, _ pd: Int16) {
        let b = 0x0700_0000 + UInt32(group * 32)
        bus.poke16(b + 6, UInt16(bitPattern: pa)); bus.poke16(b + 14, UInt16(bitPattern: pb))
        bus.poke16(b + 22, UInt16(bitPattern: pc)); bus.poke16(b + 30, UInt16(bitPattern: pd))
    }
    /// A 4bpp tile whose first row reads indices 1...8 left to right (other rows empty).
    func rampTile4(at off: Int) { for i in 0..<4 { vram(off + i, UInt8((2 * i + 1) | (2 * i + 2) << 4)) } }
    /// An 8bpp tile whose first row reads indices 1...8.
    func rampTile8(at off: Int) { for i in 0..<8 { vram(off + i, UInt8(i + 1)) } }
    func solidTile4(at off: Int, index: UInt8) { for i in 0..<32 { vram(off + i, index | index << 4) } }
    func render(_ y: Int) { bus.ppu.reloadReferences(); bus.ppu.renderLine(y) }
    /// Render lines 0...y in order, so affine/bitmap reference points advance like they do on hardware.
    func renderThrough(_ y: Int) { bus.ppu.reloadReferences(); for l in 0...y { bus.ppu.renderLine(l) } }
    func px(_ x: Int, _ y: Int) -> UInt32 { bus.ppu.frame[y * 240 + x] }
}

func ppuSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ got: UInt32, _ want: UInt32) {
        let ok = got == want
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(name)" + (ok ? "" : String(format: ": got %08X want %08X", got, want)))
    }
    let backdropColor = bgr(1, 2, 3)

    // --- text backgrounds ---------------------------------------------------------------------
    do {
        let s = Scene()
        s.io(0, 0x0100); s.io(8, (1 << 2) | (4 << 8))                    // mode 0, BG0; char block 1, screen block 4
        s.pal(0, backdropColor)
        for k in 1...8 { s.pal(32 + k, bgr(k * 3, 31 - k, k)) }          // palette bank 2
        s.rampTile4(at: 0x4000 + 32)                                      // tile 1
        for i in 0..<32 { s.vram(0x4000 + 64 + i, i < 28 ? 0 : 0x11) }    // tile 2: only its last row is filled
        s.vram16(0x2000, 1 | 2 << 12)                                     // map (0,0): tile 1, palette 2
        s.vram16(0x2002, 1 | 0x400 | 2 << 12)                             // map (1,0): h-flipped
        s.vram16(0x2004, 2 | 0x800 | 2 << 12)                             // map (2,0): v-flipped tile 2
        s.render(0)
        check("text 4bpp: tile pixels left to right", s.px(0, 0), argb(bgr(3, 30, 1)))
        check("text 4bpp: last pixel of tile", s.px(7, 0), argb(bgr(24, 23, 8)))
        check("text 4bpp: h-flip reverses the row", s.px(8, 0), argb(bgr(24, 23, 8)))
        check("text 4bpp: h-flip, far end", s.px(15, 0), argb(bgr(3, 30, 1)))
        check("text 4bpp: v-flip brings the last row to the top", s.px(16, 0), argb(bgr(3, 30, 1)))
        check("text 4bpp: transparent index shows backdrop", s.px(24, 0), argb(backdropColor))
        s.render(1)
        check("text 4bpp: empty row is transparent", s.px(0, 1), argb(backdropColor))

        s.io(0x10, 3)                                                     // BG0HOFS = 3
        s.render(0)
        check("text scroll: h-offset 3 starts at the 4th texel", s.px(0, 0), argb(bgr(12, 27, 4)))
    }
    do {  // 8bpp
        let s = Scene()
        s.io(0, 0x0100); s.io(8, (1 << 2) | (4 << 8) | 0x80)
        for k in 1...8 { s.pal(k, bgr(k, 0, 31 - k)) }
        s.rampTile8(at: 0x4000 + 3 * 64)
        s.vram16(0x2000, 3)
        s.render(0)
        check("text 8bpp: first texel", s.px(0, 0), argb(bgr(1, 0, 30)))
        check("text 8bpp: eighth texel", s.px(7, 0), argb(bgr(8, 0, 23)))
    }
    do {  // 512x256 background: second screen block sits to the right
        let s = Scene()
        s.io(0, 0x0100); s.io(8, (1 << 2) | (4 << 8) | (1 << 14))
        s.pal(1, bgr(31, 0, 0))
        s.solidTile4(at: 0x4000 + 32, index: 1)
        s.vram16(0x2800, 1)                                               // block 1, map (0,0)
        s.io(0x10, 250)
        s.render(0)
        check("512-wide BG: before the seam is empty", s.px(5, 0), argb(0))
        check("512-wide BG: after the seam shows block 1", s.px(6, 0), argb(bgr(31, 0, 0)))
    }
    do {  // mosaic
        let s = Scene()
        s.io(0, 0x0100); s.io(8, (1 << 2) | (4 << 8) | 0x40); s.io(0x4C, 3)
        for k in 1...8 { s.pal(k, bgr(k, k, k)) }
        s.rampTile4(at: 0x4000 + 32); s.vram16(0x2000, 1)
        s.render(0)
        check("mosaic 4x: second pixel repeats the first", s.px(1, 0), argb(bgr(1, 1, 1)))
        check("mosaic 4x: next block takes its own colour", s.px(4, 0), argb(bgr(5, 5, 5)))
    }

    // --- bitmap modes -------------------------------------------------------------------------
    do {
        let s = Scene()
        s.io(0, 3 | 0x400); s.vram16((2 * 240 + 5) * 2, bgr(31, 0, 0)); s.renderThrough(2)
        check("mode 3: direct colour", s.px(5, 2), argb(bgr(31, 0, 0)))
        let t = Scene()
        t.pal(7, bgr(0, 31, 0)); t.vram(0xA000 + 3 * 240 + 9, 7); t.vram(3 * 240 + 9, 0)
        t.io(0, 4 | 0x400); t.renderThrough(3)
        check("mode 4: frame 0 ignores page 1", t.px(9, 3), argb(0))
        t.io(0, 4 | 0x400 | 0x10); t.renderThrough(3)
        check("mode 4: page flip bit selects 0xA000", t.px(9, 3), argb(bgr(0, 31, 0)))
        let u = Scene()
        u.pal(0, backdropColor)
        u.io(0, 5 | 0x400); u.vram16((127 * 160 + 159) * 2, bgr(0, 0, 31)); u.renderThrough(127)
        check("mode 5: bottom-right of the 160x128 bitmap", u.px(159, 127), argb(bgr(0, 0, 31)))
        check("mode 5: outside the bitmap is backdrop", u.px(160, 127), argb(backdropColor))
    }

    // --- affine background --------------------------------------------------------------------
    do {
        let s = Scene()
        s.io(0, 2 | 0x400); s.io(0x0C, (1 << 2) | (4 << 8) | 0x2000)      // BG2: 128x128, wrapping
        for k in 1...8 { s.pal(k, bgr(k, 31 - k, 0)) }
        s.rampTile8(at: 0x4000 + 64); s.vram(0x2000, 1)
        s.render(0)
        check("affine BG: identity matrix, first texel", s.px(0, 0), argb(bgr(1, 30, 0)))
        check("affine BG: identity matrix, eighth texel", s.px(7, 0), argb(bgr(8, 23, 0)))
        check("affine BG: wraps at the 128-pixel edge", s.px(128, 0), argb(bgr(1, 30, 0)))
        s.io(0x20, 0x80)                                                  // PA = 0.5: texture magnified 2x
        s.render(0)
        check("affine BG: PA=0.5 doubles pixels", s.px(3, 0), argb(bgr(2, 29, 0)))
        s.io(0x0C, (1 << 2) | (4 << 8)); s.io(0x20, 0x100); s.render(0)   // wrap off
        check("affine BG: no wrap leaves the outside transparent", s.px(128, 0), argb(0))
    }

    // --- sprites ------------------------------------------------------------------------------
    do {
        let s = Scene()
        s.io(0, 0x1040)                                                   // OBJ on, 1D mapping, mode 0 (no BGs)
        for k in 1...8 { s.objPal(16 + k, bgr(k, 0, 31 - k)) }
        s.rampTile4(at: 0x10000)
        s.oam(0, 20, 10, 1 << 12)                                         // 8x8 at (10,20), palette 1
        s.render(20)
        check("sprite: first texel at its x", s.px(10, 20), argb(bgr(1, 0, 30)))
        check("sprite: last texel", s.px(17, 20), argb(bgr(8, 0, 23)))
        check("sprite: nothing outside it", s.px(18, 20), argb(0))
        s.render(19); check("sprite: nothing above it", s.px(10, 19), argb(0))
        s.oam(0, 20, 10 | 0x1000, 1 << 12); s.render(20)
        check("sprite: h-flip", s.px(10, 20), argb(bgr(8, 0, 23)))
        s.oam(0, 20, 0x1FF, 1 << 12); s.render(20)                        // x = -1: first texel is off-screen
        check("sprite: negative x clips at the left edge", s.px(0, 20), argb(bgr(2, 0, 29)))
    }
    do {  // priorities
        let s = Scene()
        s.io(0, 0x1140)                                                   // OBJ + BG0
        s.io(8, (1 << 2) | (4 << 8) | 1)                                  // BG0 priority 1
        s.pal(1, bgr(31, 0, 0)); s.objPal(1, bgr(0, 31, 0))
        s.solidTile4(at: 0x4000 + 32, index: 1); s.vram16(0x2000, 1)
        s.solidTile4(at: 0x10000, index: 1)
        s.oam(0, 0, 0, 0 << 10)                                           // sprite priority 0
        s.render(0)
        check("priority: sprite 0 over BG priority 1", s.px(0, 0), argb(bgr(0, 31, 0)))
        s.oam(0, 0, 0, 1 << 10); s.render(0)
        check("priority: equal priority, sprite wins", s.px(0, 0), argb(bgr(0, 31, 0)))
        s.oam(0, 0, 0, 2 << 10); s.render(0)
        check("priority: sprite 2 behind BG priority 1", s.px(0, 0), argb(bgr(31, 0, 0)))
    }
    do {  // two sprites on the same pixel
        let s = Scene()
        s.io(0, 0x1040)
        s.objPal(1, bgr(31, 0, 0)); s.objPal(2, bgr(0, 0, 31))
        s.solidTile4(at: 0x10000, index: 1); s.solidTile4(at: 0x10000 + 32, index: 2)
        s.oam(3, 0, 0, 0); s.oam(5, 0, 0, 1)
        s.render(0)
        check("sprites: lower OAM index wins at equal priority", s.px(0, 0), argb(bgr(31, 0, 0)))
    }
    do {  // affine sprites
        let s = Scene()
        s.io(0, 0x1040)
        for k in 1...8 { s.objPal(k, bgr(k, 0, 31 - k)) }
        s.rampTile4(at: 0x10000)
        s.oamParam(group: 0, 0x100, 0, 0, 0x100)
        s.oam(0, 20 | 0x100, 10, 0); s.render(20)
        check("affine sprite: identity matrix matches a normal sprite", s.px(10, 20), argb(bgr(1, 0, 30)))
        s.oam(0, 20 | 0x300, 10, 0); s.render(24)
        check("affine sprite: double-size box centres the sprite", s.px(14, 24), argb(bgr(1, 0, 30)))
        check("affine sprite: double-size box leaves its margin empty", s.px(10, 24), argb(0))
    }

    // --- windows and blending -----------------------------------------------------------------
    do {
        let s = Scene()
        s.io(0, 0x0100 | 0x2000)                                          // BG0 + WIN0
        s.io(8, (1 << 2) | (4 << 8))
        s.pal(0, backdropColor); s.pal(1, bgr(31, 0, 0))
        s.solidTile4(at: 0x4000 + 32, index: 1)
        for i in 0..<32 { s.vram16(0x2000 + i * 2, 1) }
        s.io(0x40, 16 << 8 | 32); s.io(0x44, 0 << 8 | 160)
        s.io(0x48, 0x0001); s.io(0x4A, 0x0000)                            // BG0 visible only inside WIN0
        s.render(0)
        check("window: BG shown inside WIN0", s.px(20, 0), argb(bgr(31, 0, 0)))
        check("window: BG hidden outside WIN0", s.px(40, 0), argb(backdropColor))
        check("window: WIN0 right edge is exclusive", s.px(32, 0), argb(backdropColor))
        check("window: WIN0 left edge is inclusive", s.px(16, 0), argb(bgr(31, 0, 0)))
    }
    do {
        let s = Scene()
        s.io(0, 0x0100); s.io(8, (1 << 2) | (4 << 8))
        s.pal(0, bgr(0, 0, 31)); s.pal(1, bgr(16, 0, 0))
        s.solidTile4(at: 0x4000 + 32, index: 1); s.vram16(0x2000, 1)
        s.io(0x50, 0x0001 | 1 << 6 | 0x20 << 8); s.io(0x52, 8 | 8 << 8)   // alpha: BG0 over backdrop, 8/16 each
        s.render(0)
        check("alpha blend: 50% red over blue", s.px(0, 0), argb(bgr(8, 0, 15)))
        s.io(0x50, 0x0001 | 2 << 6); s.io(0x54, 8); s.render(0)
        check("brighten: halfway to white", s.px(0, 0), argb(bgr(23, 15, 15)))
        s.io(0x50, 0x0001 | 3 << 6); s.render(0)
        check("darken: halfway to black", s.px(0, 0), argb(bgr(8, 0, 0)))
        s.io(0x50, 0x0002 | 1 << 6 | 0x20 << 8); s.render(0)
        check("blend: layer that is not a first target is untouched", s.px(0, 0), argb(bgr(16, 0, 0)))
    }
    do {  // semi-transparent sprite over a BG
        let s = Scene()
        s.io(0, 0x1140); s.io(8, (1 << 2) | (4 << 8) | 1)
        s.pal(1, bgr(0, 0, 30)); s.objPal(1, bgr(30, 0, 0))
        s.solidTile4(at: 0x4000 + 32, index: 1); s.vram16(0x2000, 1)
        s.solidTile4(at: 0x10000, index: 1)
        s.oam(0, 0 | 0x400, 0, 0)                                         // semi-transparent mode
        s.io(0x50, 0x0100); s.io(0x52, 8 | 8 << 8)                        // BG0 is a second target
        s.render(0)
        check("semi-transparent sprite blends with the BG below", s.px(0, 0), argb(bgr(15, 0, 15)))
    }
    do {
        let s = Scene()
        s.io(0, 0x0080); s.render(0)
        check("forced blank is white", s.px(0, 0), 0xFFFF_FFFF)
    }

    print(failures == 0 ? "PASS: PPU self-check" : "FAIL: \(failures) PPU check(s)")
    return failures == 0 ? 0 : 1
}
