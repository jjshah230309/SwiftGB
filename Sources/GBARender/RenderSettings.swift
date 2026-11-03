import Foundation

public enum ScreenFilter: Int, CaseIterable, Sendable, Identifiable {
    case sharp = 0      // sharp-bilinear: crisp pixels, smooth edges at non-integer scales
    case nearest = 1    // hard pixels
    case smooth = 2     // plain bilinear

    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .sharp: return "Sharp Bilinear"
        case .nearest: return "Nearest (Pixel Perfect)"
        case .smooth: return "Smooth"
        }
    }
}

/// How often the picture is presented. This is the display refresh rate, and has nothing to do with emulation speed:
/// the game keeps running at its own pace whatever this is set to (fast-forward is a separate control).
public enum RefreshRate: Int, CaseIterable, Sendable, Identifiable {
    case display = 0          // follow the screen the window is on
    case hz60 = 60, hz120 = 120, hz144 = 144, hz165 = 165, hz240 = 240

    public var id: Int { rawValue }
    public var label: String { self == .display ? "Display" : "\(rawValue) Hz" }

    /// The rate to ask the view for, given the fastest the screen can do.
    public func target(displayMaximum: Int) -> Int { self == .display ? displayMaximum : rawValue }
    public var next: RefreshRate { let all = RefreshRate.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }

    /// The highest rate the app will ask a display for.
    public static let ceiling = 240
}

/// How many pixels the picture is drawn with. "Native" follows the window; the others fix the height of the drawable
/// (the width follows the window's shape) and the system scales it to the window, so this trades sharpness for speed or the reverse.
public enum RenderResolution: Int, CaseIterable, Sendable, Identifiable {
    case native = 0
    case p720 = 720, p1080 = 1080, p1440 = 1440, k4 = 2160, k5 = 2880, k8 = 4320, k16 = 8640

    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .native: return "Native"
        case .p720: return "720p"; case .p1080: return "1080p"; case .p1440: return "1440p"
        case .k4: return "4K"; case .k5: return "5K"; case .k8: return "8K"; case .k16: return "16K"
        }
    }

    /// The drawable size for a view of the given shape, or nil for native. Never beyond Metal's 16384-pixel limit.
    public func drawableSize(aspect: Double) -> (width: Int, height: Int)? {
        guard self != .native, aspect > 0 else { return nil }
        var h = Double(rawValue), w = (h * aspect).rounded()
        if w > 16384 { w = 16384; h = (w / aspect).rounded() }
        return (max(1, Int(w)), max(1, Int(h)))
    }

    public static let maximumDimension = 16384
}

public struct RenderSettings: Equatable, Sendable {
    public var filter: ScreenFilter = .sharp
    public var integerScaling: Bool = false
    /// 0...1 strength of the LCD/CRT scanline darkening.
    public var scanlines: Float = 0
    public var refreshRate: RefreshRate = .display
    /// Present frames as fast as the GPU allows, with no display synchronisation (so tearing is possible).
    public var unlimited: Bool = false
    public var resolution: RenderResolution = .native

    public init(filter: ScreenFilter = .sharp, integerScaling: Bool = false, scanlines: Float = 0,
                refreshRate: RefreshRate = .display, unlimited: Bool = false, resolution: RenderResolution = .native) {
        self.filter = filter
        self.integerScaling = integerScaling
        self.scanlines = scanlines
        self.refreshRate = refreshRate
        self.unlimited = unlimited
        self.resolution = resolution
    }
}
