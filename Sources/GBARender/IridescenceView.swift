import AppKit
import MetalKit
import SwiftUI

struct IridescenceParams {
    var resolution: SIMD2<Float> = .zero
    var time: Float = 0
    var seed: Float = 0
    var intensity: Float = 1
    var grain: Float = 1
}

enum IridescencePipeline {
    /// Compiled once per process (compiling MSL on the main thread at every navigation caused visible stalls).
    static let shared: (device: MTLDevice, pipeline: MTLRenderPipelineState)? = {
        guard let device = MTLCreateSystemDefaultDevice(), let pipeline = make(device: device) else { return nil }
        return (device, pipeline)
    }()

    static func make(device: MTLDevice) -> MTLRenderPipelineState? {
        do {
            let library = try device.makeLibrary(source: IridescenceShader.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "iri_vertex")
            d.fragmentFunction = library.makeFunction(name: "iri_fragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("SwiftGB: iridescence pipeline failed: \(error)")
            return nil
        }
    }
}

/// Renders the field at reduced resolution and low frame rate, and stops entirely when the window is hidden.
public final class IridescenceMTKView: MTKView {
    var resolutionScale: CGFloat = 0.5
    var animated = true { didSet { applyPause() } }
    private var windowVisible = true { didSet { applyPause() } }
    private var appActive = true { didSet { applyPause() } }
    private var observer: NSObjectProtocol?
    private var appObservers: [NSObjectProtocol] = []

    override public func layout() { super.layout(); updateDrawableSize() }
    override public func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        windowVisible = window.occlusionState.contains(.visible)
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
            self?.windowVisible = window?.occlusionState.contains(.visible) ?? true
        }
        if appObservers.isEmpty {
            appActive = NSApp.isActive
            let nc = NotificationCenter.default
            appObservers = [
                nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.appActive = true },
                nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.appActive = false },
            ]
        }
        updateDrawableSize()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func updateDrawableSize() {
        let s = (window?.backingScaleFactor ?? 2) * resolutionScale
        let size = CGSize(width: max(1, bounds.width * s), height: max(1, bounds.height * s))
        if drawableSize != size { drawableSize = size; if isPaused { setNeedsDisplay(bounds) } }
    }

    func applyPause() {
        let forced = ProcessInfo.processInfo.environment["SWIFTGB_FORCE_ANIM"] == "1"   // test hook: measure cost while backgrounded
        let run = animated && ((windowVisible && appActive) || forced)
        isPaused = !run
        enableSetNeedsDisplay = !run
        if !run { setNeedsDisplay(bounds) }
    }
}

public struct IridescenceView: NSViewRepresentable {
    public var intensity: Float
    public var seed: Float
    public var animated: Bool

    public init(intensity: Float = 1, seed: Float = 0, animated: Bool = true) {
        self.intensity = intensity
        self.seed = seed
        self.animated = animated
    }

    public func makeCoordinator() -> IridescenceRenderer { IridescenceRenderer() }

    public func makeNSView(context: Context) -> IridescenceMTKView {
        let view = IridescenceMTKView()
        view.device = context.coordinator.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.preferredFramesPerSecond = 24
        view.delegate = context.coordinator
        view.animated = animated
        view.applyPause()
        return view
    }

    public func updateNSView(_ view: IridescenceMTKView, context: Context) {
        context.coordinator.intensity = intensity
        context.coordinator.seed = seed
        view.animated = animated
    }
}

public final class IridescenceRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice? = IridescencePipeline.shared?.device
    private var queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState? = IridescencePipeline.shared?.pipeline
    private let start = CACurrentMediaTime()
    var intensity: Float = 1
    var seed: Float = 0

    override init() {
        super.init()
        queue = device?.makeCommandQueue()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let queue, let pipeline, let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor, let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var p = IridescenceParams(resolution: SIMD2(Float(drawable.texture.width), Float(drawable.texture.height)),
                                  time: Float(CACurrentMediaTime() - start) + seed * 30,
                                  seed: seed, intensity: intensity, grain: 1)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&p, length: MemoryLayout<IridescenceParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}
