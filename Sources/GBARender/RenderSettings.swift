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
    case hz1 = 1, hz5 = 5, hz10 = 10, hz15 = 15, hz24 = 24, hz30 = 30
    case hz60 = 60, hz120 = 120, hz144 = 144, hz165 = 165, hz240 = 240
    case custom = -1          // a number the player types in (`RenderSettings.customRefresh`)

    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .display: return "Display"
        case .custom: return "Custom…"
        default: return "\(rawValue) Hz"
        }
    }

    /// The rate to ask the view for, given the fastest the screen can do and the typed-in value for `.custom`.
    public func target(displayMaximum: Int, custom value: Int = 30) -> Int {
        switch self {
        case .display: return displayMaximum
        case .custom: return RefreshRate.clamp(value)
        default: return rawValue
        }
    }
    public var next: RefreshRate { let all = RefreshRate.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }

    /// The highest rate the app will ask a display for, and the lowest (one picture a second).
    public static let ceiling = 240
    public static let floor = 1
    public static func clamp(_ v: Int) -> Int { min(max(v, floor), ceiling) }
}

/// How many pixels the picture is drawn with. "Native" follows the window; the others fix the height of the drawable
/// (the width follows the window's shape) and the system scales it to the window, so this trades sharpness for speed or the reverse.
public enum RenderResolution: Int, CaseIterable, Sendable, Identifiable {
    case native = 0
    case p144 = 144, p240 = 240, p360 = 360, p480 = 480
    case p720 = 720, p1080 = 1080, p1440 = 1440, k4 = 2160, k5 = 2880, k8 = 4320, k16 = 8640
    case custom = -1          // a height the player types in (`RenderSettings.customHeight`)

    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .native: return "Native"
        case .custom: return "Custom…"
        case .p144: return "144p"; case .p240: return "240p"; case .p360: return "360p"; case .p480: return "480p"
        case .p720: return "720p"; case .p1080: return "1080p"; case .p1440: return "1440p"
        case .k4: return "4K"; case .k5: return "5K"; case .k8: return "8K"; case .k16: return "16K"
        }
    }

    /// The drawable size for a view of the given shape, or nil for native. Never beyond Metal's 16384-pixel limit.
    public func drawableSize(aspect: Double, customHeight: Int = 480) -> (width: Int, height: Int)? {
        guard self != .native, aspect > 0 else { return nil }
        var h = Double(self == .custom ? RenderResolution.clamp(customHeight) : rawValue), w = (h * aspect).rounded()
        if w > 16384 { w = 16384; h = (w / aspect).rounded() }
        return (max(1, Int(w)), max(1, Int(h)))
    }

    public static let maximumDimension = 16384
    /// Typed-in heights run from 1 pixel (a blur of one colour) up to what Metal can draw.
    public static func clamp(_ v: Int) -> Int { min(max(v, 1), maximumDimension) }
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
    /// Used when `resolution` is `.custom`: the drawing height in pixels.
    public var customHeight: Int = 480
    /// Used when `refreshRate` is `.custom`: pictures per second.
    public var customRefresh: Int = 30

    public init(filter: ScreenFilter = .sharp, integerScaling: Bool = false, scanlines: Float = 0,
                refreshRate: RefreshRate = .display, unlimited: Bool = false, resolution: RenderResolution = .native,
                customHeight: Int = 480, customRefresh: Int = 30) {
        self.customHeight = customHeight
        self.customRefresh = customRefresh
        self.filter = filter
        self.integerScaling = integerScaling
        self.scanlines = scanlines
        self.refreshRate = refreshRate
        self.unlimited = unlimited
        self.resolution = resolution
    }
}
