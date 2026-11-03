/// The four 16-bit timers. Counters are computed lazily from the global cycle counter; only overflows are events,
/// so a running timer costs nothing between them.
final class Timers {
    unowned let bus: Bus
    private static let shifts: [UInt64] = [0, 6, 8, 10]          // prescaler 1, 64, 256, 1024

    var reload = [UInt16](repeating: 0, count: 4)
    var ctrl = [UInt16](repeating: 0, count: 4)
    var base = [UInt32](repeating: 0, count: 4)          // counter value at baseCycle
    var baseCycle = [UInt64](repeating: 0, count: 4)
    var overflowAt = [UInt64](repeating: .max, count: 4)
    /// Cycle of the earliest pending overflow (.max when nothing is running).
    private(set) var next: UInt64 = .max

    init(bus: Bus) { self.bus = bus }

    func reset() {
        for i in 0..<4 { reload[i] = 0; ctrl[i] = 0; base[i] = 0; baseCycle[i] = 0; overflowAt[i] = .max }
        next = .max
    }

    private func running(_ i: Int) -> Bool { ctrl[i] & 0x80 != 0 }
    private func cascading(_ i: Int) -> Bool { i > 0 && ctrl[i] & 4 != 0 }
    private func shift(_ i: Int) -> UInt64 { Timers.shifts[Int(ctrl[i] & 3)] }

    private func counter(_ i: Int) -> UInt16 {
        if !running(i) || cascading(i) { return UInt16(truncatingIfNeeded: base[i]) }
        return UInt16(truncatingIfNeeded: base[i] &+ UInt32(truncatingIfNeeded: (bus.cycles &- baseCycle[i]) >> shift(i)))
    }

    private func schedule(_ i: Int) {
        if running(i) && !cascading(i) {
            overflowAt[i] = baseCycle[i] &+ (UInt64(0x10000 - base[i]) << shift(i))
        } else {
            overflowAt[i] = .max
        }
        next = min(min(overflowAt[0], overflowAt[1]), min(overflowAt[2], overflowAt[3]))
    }

    func read16(_ offset: Int) -> UInt16 {
        let i = (offset - 0x100) >> 2
        if offset & 2 == 0 { service(); return counter(i) }
        return ctrl[i] & 0x00C7
    }

    func write16(_ offset: Int, _ v: UInt16) {
        let i = (offset - 0x100) >> 2
        if offset & 2 == 0 { reload[i] = v; return }
        service()
        let old = ctrl[i]
        let value = counter(i)
        ctrl[i] = v & 0x00C7
        let wasOn = old & 0x80 != 0, on = ctrl[i] & 0x80 != 0
        if !wasOn && on {
            base[i] = UInt32(reload[i]); baseCycle[i] = bus.cycles
        } else if wasOn && on && (old & 7) != (ctrl[i] & 7) {
            base[i] = UInt32(value); baseCycle[i] = bus.cycles          // prescaler/cascade changed: continue from the current count
        } else if wasOn && !on {
            base[i] = UInt32(value)                                    // frozen
        }
        schedule(i)
        bus.reschedule()
    }

    /// Process every overflow whose cycle has been reached.
    func service() {
        while next <= bus.cycles {
            var i = 0
            for k in 1..<4 where overflowAt[k] < overflowAt[i] { i = k }
            overflow(i, at: overflowAt[i])
        }
    }

    private func overflow(_ i: Int, at t: UInt64) {
        base[i] = UInt32(reload[i]); baseCycle[i] = t
        schedule(i)
        if ctrl[i] & 0x40 != 0 { bus.ifl |= UInt16(1) << UInt16(3 + i) }
        bus.apu.timerOverflow(i)
        if i < 3 && running(i + 1) && cascading(i + 1) {
            base[i + 1] += 1
            if base[i + 1] > 0xFFFF { overflow(i + 1, at: t) }
        }
    }
}

// MARK: save states
extension Timers {
    func save(_ w: inout StateWriter) {
        w.tag("TMR0")
        w.u16s(reload); w.u16s(ctrl); w.u32s(base); w.u64s(baseCycle); w.u64s(overflowAt); w.u64(next)
    }
    func load(_ r: inout StateReader) {
        r.tag("TMR0")
        r.u16s(&reload); r.u16s(&ctrl); r.u32s(&base); r.u64s(&baseCycle); r.u64s(&overflowAt); next = r.u64()
    }
}
