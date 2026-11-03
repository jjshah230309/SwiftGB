import Foundation

/// Emulation speed as a multiple of real time. `.infinity` means "as fast as the machine can go".
public enum EmulationSpeed {
    /// Every step the speed menu offers: half speed, normal, then doubling up to unlimited.
    public static let ladder: [Double] = [0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256, .infinity]
    /// What the hold-to-fast-forward key may run at: powers of two, then unlimited.
    public static let fastForwardChoices: [Double] = [2, 4, 8, 16, 32, 64, 128, 256, .infinity]
    public static let defaultFastForward = 4.0

    public static func label(_ s: Double) -> String {
        if s.isInfinite { return "Unlimited" }
        if s == 0.5 { return "½×" }
        if s < 1 { return String(format: "%.2g×", s) }
        return "\(Int(s))×"
    }

    /// The next step up the ladder (stays at unlimited), or down (stays at the lowest).
    public static func faster(than s: Double) -> Double { ladder.first { $0 > s } ?? .infinity }
    public static func slower(than s: Double) -> Double { ladder.last { $0 < s } ?? ladder[0] }

    /// Seconds each frame should take at this speed, or nil when there is no pacing at all.
    public static func frameInterval(framesPerSecond: Double, speed: Double) -> Double? {
        speed.isInfinite ? nil : 1 / framesPerSecond / max(speed, 0.01)
    }

    // Stored as a plain number: unlimited can't be written to preferences as infinity.
    public static func encode(_ s: Double) -> Double { s.isInfinite ? -1 : s }
    public static func decode(_ v: Double?, fallback: Double) -> Double {
        guard let v else { return fallback }
        return v < 0 ? .infinity : (v > 0 ? v : fallback)
    }
}

/// How often the game's state is saved automatically. Chosen by the user in any of seconds, minutes or hours; can be off.
public struct AutosaveSchedule: Codable, Equatable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case seconds, minutes, hours
        public var label: String { rawValue.capitalized }
        public var seconds: Double { switch self { case .seconds: return 1; case .minutes: return 60; case .hours: return 3600 } }
    }

    public var enabled: Bool
    public var value: Int
    public var unit: Unit

    public init(enabled: Bool = true, value: Int = 5, unit: Unit = .minutes) {
        self.enabled = enabled
        self.value = min(max(value, 1), 999)
        self.unit = unit
    }

    /// Seconds between autosaves, or nil when autosave is off.
    public var interval: TimeInterval? { enabled ? Double(value) * unit.seconds : nil }

    public var summary: String {
        guard enabled else { return "Off" }
        return "Every \(value) \(value == 1 ? String(unit.label.dropLast()) : unit.label)".lowercased()
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ data: Data?) -> AutosaveSchedule? {
        guard let data, let s = try? JSONDecoder().decode(AutosaveSchedule.self, from: data) else { return nil }
        return AutosaveSchedule(enabled: s.enabled, value: s.value, unit: s.unit)      // re-clamps anything hand-edited
    }
}
