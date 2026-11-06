import Foundation

/// A rolling history of compressed save states, taken every few frames, for stepping a game backwards.
/// Single-owner, like the core it records.
public final class RewindBuffer {
    private var snapshots = [Data]()
    private var frames = 0
    private var capacity: Int
    private let interval: Int

    /// `capacity` snapshots, one every `interval` frames: the defaults reach back about 12 seconds.
    public init(capacity: Int = 150, interval: Int = 5) {
        self.capacity = capacity
        self.interval = interval
    }

    /// Keep `seconds` of history (about 12 snapshots a second of play); 0 stops recording and frees everything.
    public func configure(seconds: Int) {
        capacity = max(0, seconds) * 12
        if capacity == 0 { clear() } else if snapshots.count > capacity { snapshots.removeFirst(snapshots.count - capacity) }
    }
    public var isEnabled: Bool { capacity > 0 }

    public var depth: Int { snapshots.count }

    public func clear() { snapshots.removeAll(); frames = 0 }

    /// Call once before running each forward frame.
    public func record(_ core: EmulatorCore) {
        guard capacity > 0 else { return }
        defer { frames += 1 }
        guard frames % interval == 0 else { return }
        // NSData's compression hands back autoreleased objects; the emulation thread never drains a pool, so without this
        // every snapshot ever taken stays in memory (tens of GB after an hour at unlimited speed).
        let packed: Data? = autoreleasepool {
            guard let state = core.saveState() else { return nil }
            return try? (state as NSData).compressed(using: .lz4) as Data
        }
        guard let packed else { return }
        snapshots.append(packed)
        if snapshots.count > capacity { snapshots.removeFirst(snapshots.count - capacity) }
    }

    /// Restore the most recent snapshot and discard it. Returns false if there is nothing left to go back to.
    @discardableResult
    public func rewind(_ core: EmulatorCore) -> Bool {
        while let packed = snapshots.popLast() {
            let restored: Bool = autoreleasepool {
                guard let state = try? (packed as NSData).decompressed(using: .lz4) as Data else { return false }
                return core.loadState(state)
            }
            if restored {
                frames = 0                                  // going forward again captures right away
                return true
            }
        }
        return false
    }
}
