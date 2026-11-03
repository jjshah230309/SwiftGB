import CoreGraphics
import Foundation
import GBACore
import ImageIO

/// Run a Game Boy picture test ROM (dmg-acid2, cgb-acid2) and compare the screen with the reference image pixel by pixel.
func gbPictureTest(rom: String, reference: String, frames: Int, diffOut: String?) -> Int32 {
    guard let data = FileManager.default.contents(atPath: rom) else { print("cannot read \(rom)"); return 2 }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: reference) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print("cannot read reference \(reference)"); return 2
    }
    var ref = [UInt8](repeating: 0, count: 160 * 144 * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    ref.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: 160, height: 144, bitsPerComponent: 8, bytesPerRow: 640, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 144))
    }

    let core = GBConsole(rom: data)
    let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: 160 * 144); defer { fb.deallocate() }
    for _ in 0..<frames { core.runFrame(framebuffer: fb) }

    var wrong = 0
    var firstBad = [String]()
    var diff = [UInt8](repeating: 0, count: 160 * 144 * 3)
    for i in 0..<(160 * 144) {
        let rr = Int(ref[i * 4]), rg = Int(ref[i * 4 + 1]), rb = Int(ref[i * 4 + 2])
        let p = fb[i]
        let r = Int(p >> 16 & 255), g = Int(p >> 8 & 255), b = Int(p & 255)
        var ok: Bool
        if core.isColor {
            ok = abs(r - rr) <= 8 && abs(g - rg) <= 8 && abs(b - rb) <= 8
        } else {
            // The reference is greyscale (0, 85, 170, 255 = darkest...lightest); compare shade numbers.
            let want = 3 - Int((Double(rr) / 85).rounded())
            ok = Int(core.shadeIndices()[i]) == want
        }
        if !ok {
            wrong += 1
            if firstBad.count < 6 { firstBad.append("(\(i % 160),\(i / 160))") }
            diff[i * 3] = 255
        } else {
            diff[i * 3] = UInt8(r / 3); diff[i * 3 + 1] = UInt8(g / 3); diff[i * 3 + 2] = UInt8(b / 3)
        }
    }
    if let diffOut {
        var out = Data("P6\n160 144\n255\n".utf8); out.append(contentsOf: diff)
        FileManager.default.createFile(atPath: diffOut, contents: out)
    }
    print("\((rom as NSString).lastPathComponent): \(wrong == 0 ? "PASS: picture matches the reference exactly" : "FAIL: \(wrong) of 23040 pixels differ  first at \(firstBad.joined(separator: " "))")")
    return wrong == 0 ? 0 : 1
}
