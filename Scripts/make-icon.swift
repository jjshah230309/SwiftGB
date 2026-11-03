// Draws the SwiftGB app icon at every size macOS wants, as PNGs inside an .iconset folder.
//   swift Scripts/make-icon.swift Branding/AppIcon.iconset && iconutil -c icns Branding/AppIcon.iconset -o Resources/AppIcon.icns
//
// The icon is the app's own look in one picture: a black rounded square, a hairline-outlined 3:2 screen, and inside it the same
// olive / khaki / sage iridescence as the library hero, with faint LCD scanlines.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

/// Draw the whole icon on a 1024 x 1024 design grid (Apple's template: an 824-point body with room for a shadow).
func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Soft shadow under the body
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.55))
    ctx.addPath(bodyPath); ctx.setFillColor(color(0x0B0B0B)); ctx.fillPath()
    ctx.restoreGState()

    // Body: near-black with a whisper of light from the top
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let top = CGGradient(colorsSpace: space, colors: [color(0x1A1A1A), color(0x090909)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(top, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Screen (3:2, like the console's own), sitting a little above centre
    let w: CGFloat = 604, h: CGFloat = 403
    let screen = CGRect(x: 512 - w / 2, y: 578 - h / 2, width: w, height: h)

    // Glow behind the screen
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let glow = CGGradient(colorsSpace: space, colors: [color(0x948151, 0.40), color(0x948151, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 470, options: [])
    ctx.restoreGState()

    // Iridescent fill
    ctx.saveGState()
    ctx.clip(to: screen)
    let base = CGGradient(colorsSpace: space, colors: [color(0x39422F), color(0x1B2016)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    func blob(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
        let g = CGGradient(colorsSpace: space, colors: [color(hex, alpha), color(hex, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: screen.minX + cx * w, y: screen.minY + cy * h), startRadius: 0,
                               endCenter: CGPoint(x: screen.minX + cx * w, y: screen.minY + cy * h), endRadius: r, options: [])
    }
    blob(0.26, 0.66, 340, 0xC9AE6A, 1.0)       // gold
    blob(0.74, 0.28, 380, 0x72804B, 1.0)       // sage
    blob(0.64, 0.82, 250, 0x9AA06A, 0.85)      // olive
    blob(0.16, 0.14, 240, 0x5A3F22, 0.90)      // umber
    blob(0.32, 0.72, 150, 0xF3E6B8, 0.75)      // a bright khaki core
    // A glassy sweep across the top
    let sweep = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.20), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sweep, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.minX, y: screen.midY), options: [])
    // Faint LCD rows
    ctx.setFillColor(color(0x000000, 0.075))
    var y = screen.minY
    while y < screen.maxY { ctx.fill(CGRect(x: screen.minX, y: y, width: w, height: 3)); y += 12 }
    ctx.restoreGState()

    // Hairline outline: the app's only chrome
    ctx.setStrokeColor(color(0xFFFFFF, 0.94)); ctx.setLineWidth(11)
    ctx.stroke(screen.insetBy(dx: -4, dy: -4))

    // Controls, drawn in the same hairline: a d-pad on the left, two buttons on the right
    ctx.setStrokeColor(color(0xFFFFFF, 0.62)); ctx.setLineWidth(9); ctx.setLineJoin(.round)
    let cx: CGFloat = 268, cy: CGFloat = 238, arm: CGFloat = 26, len: CGFloat = 52
    let cross = CGMutablePath()
    cross.addLines(between: [CGPoint(x: cx - arm, y: cy + len), CGPoint(x: cx + arm, y: cy + len), CGPoint(x: cx + arm, y: cy + arm), CGPoint(x: cx + len, y: cy + arm),
                             CGPoint(x: cx + len, y: cy - arm), CGPoint(x: cx + arm, y: cy - arm), CGPoint(x: cx + arm, y: cy - len), CGPoint(x: cx - arm, y: cy - len),
                             CGPoint(x: cx - arm, y: cy - arm), CGPoint(x: cx - len, y: cy - arm), CGPoint(x: cx - len, y: cy + arm), CGPoint(x: cx - arm, y: cy + arm)])
    cross.closeSubpath()
    ctx.addPath(cross); ctx.strokePath()
    for (bx, by) in [(CGFloat(716), CGFloat(214)), (CGFloat(784), CGFloat(266))] {
        ctx.strokeEllipse(in: CGRect(x: bx - 32, y: by - 32, width: 64, height: 64))
    }
}

func render(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(ctx)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: out)
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    write(render(size: base), to: "\(out)/icon_\(base)x\(base).png")
    write(render(size: base * 2), to: "\(out)/icon_\(base)x\(base)@2x.png")
}
write(render(size: 1024), to: (out as NSString).deletingLastPathComponent + "/icon-preview-1024.png")
print("wrote \(out)")
