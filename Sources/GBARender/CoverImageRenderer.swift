import CoreGraphics
import Foundation
import Metal

/// Renders one still frame of the iridescent field to an image, so every game gets its own cover from the same shader.
public final class CoverImageRenderer: @unchecked Sendable {
    public static let shared = CoverImageRenderer()

    private let device: MTLDevice? = IridescencePipeline.shared?.device
    private let pipeline: MTLRenderPipelineState? = IridescencePipeline.shared?.pipeline
    private var queue: MTLCommandQueue?
    private let lock = NSLock()

    private init() { queue = device?.makeCommandQueue() }

    /// `seed` in 0...1 picks a distinct (but stable) composition.
    public func render(seed: Float, width: Int = 640, height: Int = 360) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let device, let queue, let pipeline else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var p = IridescenceParams(resolution: SIMD2(Float(width), Float(height)), time: 20 + seed * 40,
                                  seed: seed, intensity: 0.92, grain: 1)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&p, length: MemoryLayout<IridescenceParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
