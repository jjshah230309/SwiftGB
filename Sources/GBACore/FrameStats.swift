import Foundation

/// Rolling frame-time statistics: how long the emulator took to produce each of the last ~two seconds of frames.
/// Values are milliseconds of work per frame, not time between frames, so they show headroom even while the loop is idle-waiting.
public struct FrameStats: Sendable {
    private var times: [Double]
    private var next = 0
    private var filled = 0

    public init(capacity: Int = 120) { times = [Double](repeating: 0, count: max(capacity, 1)) }

    public mutating func record(milliseconds: Double) {
        times[next] = milliseconds
        next = (next + 1) % times.count
        filled = min(filled + 1, times.count)
    }

    public mutating func reset() { next = 0; filled = 0 }

    public var count: Int { filled }
    private var window: ArraySlice<Double> { times[0..<filled] }

    public var average: Double { filled == 0 ? 0 : window.reduce(0, +) / Double(filled) }
    public var worst: Double { window.max() ?? 0 }
    /// The time that 99% of recent frames came in under.
    public var p99: Double {
        guard filled > 0 else { return 0 }
        let sorted = window.sorted()
        let rank = Int((Double(filled) * 0.99).rounded(.up))             // 1-based position of the 99th percentile
        return sorted[min(max(rank, 1), filled) - 1]
    }

    /// How many times faster than real time the core could run, judged by its average work per frame
    /// (2.0 means it uses half of each frame's time budget).
    public func headroom(framesPerSecond: Double) -> Double {
        let a = average
        return a > 0 ? (1000 / framesPerSecond) / a : 0
    }

    /// Frames that took longer than their budget: each one is a stutter or a dropped frame at 1x.
    public func overruns(framesPerSecond: Double) -> Int {
        let budget = 1000 / framesPerSecond
        return window.filter { $0 > budget }.count
    }
}

/// What the on-screen statistics display shows.
public struct StatsSnapshot: Sendable, Equatable {
    public var framesPerSecond = 0.0
    public var averageMs = 0.0
    public var p99Ms = 0.0
    public var worstMs = 0.0
    public var headroom = 0.0
    public var overruns = 0
    public init() {}
}

/// Move through a grid of items, as a controller or the arrow keys would.
public enum NavInput: Sendable { case left, right, up, down, confirm, back }

public enum GridNavigation {
    /// The index to focus after moving `direction` from `index` in a grid of `count` items laid out `columns` across, row by row.
    /// Moving off an edge stays put; moving down from a column the last (shorter) row lacks lands on that row's last item.
    public static func next(from index: Int?, direction: NavInput, count: Int, columns: Int) -> Int? {
        guard count > 0, columns > 0 else { return nil }
        guard let i = index, i >= 0, i < count else { return 0 }
        let row = i / columns, col = i % columns
        switch direction {
        case .left: return col > 0 ? i - 1 : i
        case .right: return (col < columns - 1 && i + 1 < count) ? i + 1 : i
        case .up: return row > 0 ? i - columns : i
        case .down:
            if i + columns < count { return i + columns }
            let lastRow = (count - 1) / columns
            return row < lastRow ? count - 1 : i
        case .confirm, .back: return i
        }
    }

    /// How many columns an adaptive grid with this minimum item width and spacing fits in `width`.
    public static func columns(width: Double, minimumItem: Double, spacing: Double) -> Int {
        max(1, Int(((width + spacing) / (minimumItem + spacing)).rounded(.down)))
    }
}
