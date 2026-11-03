import AppKit
import MetalKit
import SwiftUI

/// MTKView that also receives keyboard input for the emulated pad.
public final class GameMTKView: MTKView {
    /// (keyCode, isDown) -> handled?
    public var onKey: ((UInt16, Bool) -> Bool)?

    // MARK: refresh rate
    private var driver: UnlimitedDriver?

    /// The fastest refresh rate of the screen this view is on.
    public var displayMaximumRate: Int { window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60 }

    /// Apply the refresh-rate settings: a capped rate goes through the view's own display link, "unlimited" through a loop
    /// that presents as fast as the GPU can take frames, with vertical sync off.
    public func applyRefresh(_ settings: RenderSettings) {
        let metal = layer as? CAMetalLayer
        if settings.unlimited {
            metal?.displaySyncEnabled = false
            isPaused = true
            if driver == nil { driver = UnlimitedDriver(view: self) }
        } else {
            driver?.stop(); driver = nil
            metal?.displaySyncEnabled = true
            preferredFramesPerSecond = min(settings.refreshRate.target(displayMaximum: displayMaximumRate), RefreshRate.ceiling)
            isPaused = false
        }
    }

    // MARK: resolution
    private var resolution = RenderResolution.native

    public func applyResolution(_ r: RenderResolution) {
        guard r != resolution else { return }
        resolution = r
        updateDrawableSize()
    }

    /// Native: the drawable tracks the window in real pixels. Otherwise it is pinned to the chosen height at the window's shape.
    public func updateDrawableSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if let size = resolution.drawableSize(aspect: Double(bounds.width / bounds.height)) {
            autoResizeDrawable = false
            drawableSize = CGSize(width: size.width, height: size.height)
        } else {
            autoResizeDrawable = true
            drawableSize = convertToBacking(bounds).size
        }
    }

    public override func layout() { super.layout(); updateDrawableSize() }

    func stopDriving() { driver?.stop(); driver = nil }

    public override var acceptsFirstResponder: Bool { true }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    public override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        if onKey?(event.keyCode, true) != true { super.keyDown(with: event) }
    }
    public override func keyUp(with event: NSEvent) {
        if onKey?(event.keyCode, false) != true { super.keyUp(with: event) }
    }
    /// Modifier keys have no keyDown/keyUp; report their edges as ordinary key events using each side's own key code.
    private static let modifierMasks: [UInt16: UInt] = [56: 0x2, 60: 0x4, 55: 0x8, 54: 0x10, 58: 0x20, 61: 0x40, 59: 0x1, 62: 0x2000]
    private var modifiersDown = Set<UInt16>()

    public override func flagsChanged(with event: NSEvent) {
        guard let mask = Self.modifierMasks[event.keyCode] else { return }
        let down = event.modifierFlags.rawValue & mask != 0
        if down != modifiersDown.contains(event.keyCode) {
            if down { modifiersDown.insert(event.keyCode) } else { modifiersDown.remove(event.keyCode) }
            _ = onKey?(event.keyCode, down)
        }
    }
}

/// Calls `draw()` in a tight loop on its own thread. Each call waits for a free drawable and for the GPU to have room,
/// so the rate settles at whatever the machine can sustain.
private final class UnlimitedDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private weak var view: GameMTKView?

    init(view: GameMTKView) {
        self.view = view
        let t = Thread { [weak self] in self?.loop() }
        t.name = "SwiftGB.present"
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() { lock.lock(); running = false; lock.unlock() }
    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func loop() {
        while isRunning {
            autoreleasepool {
                guard let view else { stop(); return }
                // A window nobody can see has nothing to present to; don't spin on it.
                if let window = view.window, !window.occlusionState.contains(.visible) { Thread.sleep(forTimeInterval: 0.05); return }
                view.draw()
            }
        }
    }
}

/// A delegate that only counts how often the view asks it to draw.
private final class CountingDelegate: NSObject, MTKViewDelegate {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) { lock.lock(); n += 1; lock.unlock() }
}

/// Check, on a real view, that each refresh setting reaches the display link and that "unlimited" really lifts the cap.
/// Must run on the main thread. Returns one line per check.
@MainActor
public func refreshSelfTest() -> [String] {
    var lines = [String]()
    let view = GameMTKView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
    let counter = CountingDelegate()
    view.delegate = counter
    view.enableSetNeedsDisplay = false
    let metal = view.layer as? CAMetalLayer
    lines.append("layer is a CAMetalLayer: \(metal != nil)")
    for rate in RefreshRate.allCases {
        view.applyRefresh(RenderSettings(refreshRate: rate))
        let want = min(rate.target(displayMaximum: view.displayMaximumRate), RefreshRate.ceiling)
        lines.append("\(view.preferredFramesPerSecond == want && !view.isPaused && metal?.displaySyncEnabled == true ? "ok  " : "FAIL") \(rate.label): preferredFramesPerSecond=\(view.preferredFramesPerSecond) (display max \(view.displayMaximumRate)) sync=\(metal?.displaySyncEnabled ?? false)")
    }
    view.applyRefresh(RenderSettings(refreshRate: .hz240, unlimited: true))
    let before = counter.count
    let t0 = DispatchTime.now().uptimeNanoseconds
    Thread.sleep(forTimeInterval: 0.5)
    let n = counter.count - before
    let rate = Double(n) / (Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
    lines.append("\(view.isPaused && metal?.displaySyncEnabled == false && rate > 480 ? "ok  " : "FAIL") unlimited: vsync off, own loop drew \(n) times in 0.5 s = \(Int(rate))/s (a 240 Hz cap would be 120)")
    view.applyRefresh(RenderSettings(refreshRate: .hz60))
    let mark = counter.count
    Thread.sleep(forTimeInterval: 0.3)
    lines.append("\(metal?.displaySyncEnabled == true ? "ok  " : "FAIL") turning Unlimited off restores vsync; loop stopped: \(counter.count - mark) extra draws in 0.3 s")
    view.stopDriving()
    // Resolution: fixed heights at the view's shape (200x150 = 4:3), and back to native.
    view.layout()
    for r in RenderResolution.allCases {
        view.applyResolution(r)
        view.updateDrawableSize()
        let size = view.drawableSize
        if let want = r.drawableSize(aspect: 200.0 / 150.0) {
            lines.append("\(Int(size.height) == want.height && Int(size.width) == want.width && !view.autoResizeDrawable ? "ok  " : "FAIL") resolution \(r.label): drawable \(Int(size.width))x\(Int(size.height)) (wanted \(want.width)x\(want.height))")
        } else {
            lines.append("\(view.autoResizeDrawable ? "ok  " : "FAIL") resolution \(r.label): follows the view (\(Int(size.width))x\(Int(size.height)))")
        }
    }
    return lines
}

/// SwiftUI host for the Metal screen.
public struct ScreenView: NSViewRepresentable {
    public let mailbox: FrameMailbox
    public var settings: RenderSettings
    public var onKey: (UInt16, Bool) -> Bool

    public init(mailbox: FrameMailbox, settings: RenderSettings, onKey: @escaping (UInt16, Bool) -> Bool) {
        self.mailbox = mailbox
        self.settings = settings
        self.onKey = onKey
    }

    public func makeCoordinator() -> ScreenRenderer { ScreenRenderer(mailbox: mailbox) }

    public func makeNSView(context: Context) -> GameMTKView {
        let view = GameMTKView()
        let renderer = context.coordinator
        view.device = renderer.device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true                  // the drawable follows the view at native pixels, however large the display
        view.delegate = renderer
        view.onKey = onKey
        view.applyRefresh(settings)
        view.applyResolution(settings.resolution)
        return view
    }

    public func updateNSView(_ view: GameMTKView, context: Context) {
        context.coordinator.settings = settings
        view.onKey = onKey
        view.applyRefresh(settings)
        view.applyResolution(settings.resolution)
    }

    public static func dismantleNSView(_ view: GameMTKView, coordinator: ScreenRenderer) { view.stopDriving() }
}

enum ScreenPipeline {
    static let shared: (device: MTLDevice, pipeline: MTLRenderPipelineState)? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        do {
            let library = try device.makeLibrary(source: ScreenShader.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "screen_vertex")
            d.fragmentFunction = library.makeFunction(name: "screen_fragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return (device, try device.makeRenderPipelineState(descriptor: d))
        } catch {
            NSLog("SwiftGB: failed to build screen pipeline: \(error)")
            return nil
        }
    }()
}

/// Compile every shader up front, off the main thread, so the first navigation/game start doesn't stall.
public func warmUpRenderer() {
    DispatchQueue.global(qos: .utility).async {
        _ = IridescencePipeline.shared
        _ = ScreenPipeline.shared
    }
}

/// Draws the latest emulator frame, letterboxed, using a ring of textures so the CPU never overwrites one in use by the GPU.
public final class ScreenRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice?
    private let mailbox: FrameMailbox
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var textures: [MTLTexture] = []
    private var ringIndex = 0
    private var current: MTLTexture?
    private var seenGeneration: UInt64 = 0
    private var staging: [UInt32] = []
    private let inFlight = DispatchSemaphore(value: 3)
    public var settings = RenderSettings()

    private struct Params {
        var texSize: SIMD2<Float> = .zero
        var viewSize: SIMD2<Float> = .zero
        var filter: Int32 = 0
        var scanlines: Float = 0
    }

    public init(mailbox: FrameMailbox) {
        self.mailbox = mailbox
        self.device = ScreenPipeline.shared?.device
        self.queue = device?.makeCommandQueue()
        self.pipeline = ScreenPipeline.shared?.pipeline
        super.init()
        if device == nil { NSLog("SwiftGB: no Metal device") }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let device, let queue, let pipeline,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else { return }

        // Pull a new frame if the emulator produced one.
        if let (gen, w, h) = mailbox.copyIfNew(since: seenGeneration, into: &staging) {
            seenGeneration = gen
            if textures.isEmpty || textures[0].width != w || textures[0].height != h {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
                td.storageMode = .shared
                td.usage = .shaderRead
                textures = (0..<3).compactMap { _ in device.makeTexture(descriptor: td) }
                ringIndex = 0
            }
            if !textures.isEmpty {
                ringIndex = (ringIndex + 1) % textures.count
                let tex = textures[ringIndex]
                staging.withUnsafeBytes { raw in
                    tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: w * 4)
                }
                current = tex
            }
        }
        guard let tex = current, let cb = queue.makeCommandBuffer() else { return }

        inFlight.wait()
        cb.addCompletedHandler { [inFlight] _ in inFlight.signal() }

        guard encode(cb, pass: pass, targetWidth: drawable.texture.width, targetHeight: drawable.texture.height, tex: tex, pipeline: pipeline) else { inFlight.signal(); return }
        cb.present(drawable)
        cb.commit()
    }

    /// Letterbox (optionally integer-scaled) the picture into a target of the given pixel size and encode the draw.
    private func encode(_ cb: MTLCommandBuffer, pass: MTLRenderPassDescriptor, targetWidth: Int, targetHeight: Int,
                        tex: MTLTexture, pipeline: MTLRenderPipelineState) -> Bool {
        let dw = Double(targetWidth), dh = Double(targetHeight)
        let tw = Double(tex.width), th = Double(tex.height)
        var scale = min(dw / tw, dh / th)
        if settings.integerScaling, scale >= 1 { scale = scale.rounded(.down) }
        let vw = tw * scale, vh = th * scale

        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
        enc.setViewport(MTLViewport(originX: (dw - vw) / 2, originY: (dh - vh) / 2, width: vw, height: vh, znear: 0, zfar: 1))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(tex, index: 0)
        var p = Params(texSize: SIMD2(Float(tw), Float(th)), viewSize: SIMD2(Float(vw), Float(vh)),
                       filter: Int32(settings.filter.rawValue), scanlines: settings.scanlines)
        enc.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        return true
    }

    /// Render a test picture into an offscreen target of `width` x `height` pixels, the way the window would, and check the result.
    /// Used to confirm the pipeline really works at very large sizes (up to 16K) without needing a display of that size.
    public static func offscreenSelfTest(width: Int, height: Int, frames: Int = 1) -> (ok: Bool, millis: Double, detail: String) {
        guard let shared = ScreenPipeline.shared, let queue = shared.device.makeCommandQueue() else { return (false, 0, "no Metal device") }
        let device = shared.device
        guard width <= 16384, height <= 16384 else { return (false, 0, "larger than Metal's 16384-pixel limit") }
        let renderer = ScreenRenderer(mailbox: FrameMailbox())

        // A 240x160 picture: left half red, right half blue, so both ends of the output can be checked.
        let src = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 240, height: 160, mipmapped: false)
        src.storageMode = .shared; src.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: src) else { return (false, 0, "couldn't make the source texture") }
        var pixels = [UInt32](repeating: 0, count: 240 * 160)
        for y in 0..<160 { for x in 0..<240 { pixels[y * 240 + x] = x < 120 ? 0xFFFF0000 : 0xFF0000FF } }
        pixels.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, 240, 160), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 960) }

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.storageMode = .shared; td.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: td) else { return (false, 0, "couldn't allocate a \(width)x\(height) target") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<frames {
            guard let cb = queue.makeCommandBuffer(), renderer.encode(cb, pass: pass, targetWidth: width, targetHeight: height, tex: tex, pipeline: shared.pipeline) else {
                return (false, 0, "couldn't encode")
            }
            cb.commit(); cb.waitUntilCompleted()
            if let e = cb.error { return (false, 0, "GPU error: \(e.localizedDescription)") }
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(frames)

        // Read back one pixel near the left and one near the right of the picture, at the vertical centre.
        func pixel(_ x: Int, _ y: Int) -> UInt32 {
            var v: UInt32 = 0
            target.getBytes(&v, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return v
        }
        let scale = min(Double(width) / 240, Double(height) / 160)
        let w = 240 * scale, left = (Double(width) - w) / 2
        let l = pixel(Int(left + w * 0.25), height / 2), r = pixel(Int(left + w * 0.75), height / 2), corner = pixel(0, 0)
        let ok = (l & 0x00FFFFFF) != 0 && (r & 0x00FFFFFF) != 0 && l != r && (corner & 0x00FFFFFF) == 0
        return (ok, ms, "\(width)x\(height): left \(String(l, radix: 16)) right \(String(r, radix: 16)) corner \(String(corner, radix: 16))")
    }
}
