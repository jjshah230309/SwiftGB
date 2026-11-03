import Combine
import Foundation
import GBACore
import GBARender

/// User preferences, persisted in UserDefaults. Every field here is wired to something real.
@MainActor
public final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published public var filter: ScreenFilter { didSet { defaults.set(filter.rawValue, forKey: "filter") } }
    @Published public var integerScaling: Bool { didSet { defaults.set(integerScaling, forKey: "integerScaling") } }
    @Published public var scanlines: Double { didSet { defaults.set(scanlines, forKey: "scanlines") } }
    @Published public var volume: Double { didSet { defaults.set(volume, forKey: "volume") } }
    @Published public var refreshRate: RefreshRate { didSet { defaults.set(refreshRate.rawValue, forKey: "refreshRate") } }
    /// Present as fast as the GPU allows. Independent of emulation speed.
    @Published public var unlimitedRefresh: Bool { didSet { defaults.set(unlimitedRefresh, forKey: "unlimitedRefresh") } }
    @Published public var resolution: RenderResolution { didSet { defaults.set(resolution.rawValue, forKey: "resolution") } }
    /// How fast the hold-to-fast-forward key runs the game (a power of two, or unlimited).
    @Published public var fastForwardSpeed: Double { didSet { defaults.set(EmulationSpeed.encode(fastForwardSpeed), forKey: "fastForwardSpeed") } }
    @Published public var autosave: AutosaveSchedule { didSet { if let d = autosave.encoded() { defaults.set(d, forKey: "autosave") } } }
    @Published public var showStatistics: Bool { didSet { defaults.set(showStatistics, forKey: "showStatistics") } }
    @Published public var muted: Bool { didSet { defaults.set(muted, forKey: "muted") } }

    public init() {
        let d = UserDefaults.standard
        filter = ScreenFilter(rawValue: d.object(forKey: "filter") as? Int ?? 0) ?? .sharp
        integerScaling = d.object(forKey: "integerScaling") as? Bool ?? false
        scanlines = d.object(forKey: "scanlines") as? Double ?? 0
        volume = d.object(forKey: "volume") as? Double ?? 0.8
        refreshRate = RefreshRate(rawValue: d.object(forKey: "refreshRate") as? Int ?? 0) ?? .display
        unlimitedRefresh = d.object(forKey: "unlimitedRefresh") as? Bool ?? false
        muted = d.object(forKey: "muted") as? Bool ?? false
        showStatistics = d.object(forKey: "showStatistics") as? Bool ?? false
        resolution = RenderResolution(rawValue: d.object(forKey: "resolution") as? Int ?? 0) ?? .native
        fastForwardSpeed = EmulationSpeed.decode(d.object(forKey: "fastForwardSpeed") as? Double, fallback: EmulationSpeed.defaultFastForward)
        autosave = AutosaveSchedule.decode(d.data(forKey: "autosave")) ?? AutosaveSchedule()
    }

    public var renderSettings: RenderSettings {
        RenderSettings(filter: filter, integerScaling: integerScaling, scanlines: Float(scanlines), refreshRate: refreshRate, unlimited: unlimitedRefresh, resolution: resolution)
    }
}
