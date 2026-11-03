import Foundation

/// The GBA's serial port in multi-player mode (the link cable for two to four consoles).
///
/// The parent (player 0) starts a transfer by setting SIOCNT's start bit; every console then shifts its SIOMLT_SEND word out in turn,
/// and each ends up with all the words in SIOMULTI0-3 (0xFFFF for a console that isn't there), then raises its serial interrupt.
/// Here the words travel as `LinkMessage`s, and the time a transfer takes follows the baud rate.
final class SIO {
    unowned let bus: Bus
    var link: SerialLink?

    private static let bitCycles = [1748, 437, 291, 146]           // 16.78 MHz / 9600, 38400, 57600, 115200 baud
    /// How long to wait for another console before deciding it isn't there: six frames.
    private static let timeoutCycles: UInt64 = 6 * 280_896

    private enum State {
        case idle
        case parentWaiting(replies: [Int: UInt16], endsAt: UInt64, deadline: UInt64)
        case childWaiting(deadline: UInt64)
    }
    private var state = State.idle
    private var error = false

    init(bus: Bus) { self.bus = bus }

    var active: Bool { link != nil || { if case .idle = state { return false } else { return true } }() }

    func reset() { state = .idle; error = false }

    // MARK: registers (raw values live in the I/O block so save states keep them)
    private var cnt: UInt16 { ld16(bus.io, 0x128) }
    private var multiMode: Bool { ld16(bus.io, 0x134) & 0x8000 == 0 && cnt & 0x3000 == 0x2000 }
    private var playerIndex: Int { link?.playerIndex ?? 0 }
    private var players: Int { link?.playerCount ?? 1 }

    func readCNT() -> UInt16 {
        var v = cnt & 0x7FFF & ~0x007C                              // keep baud, mode, IRQ enable and the busy bit; the rest is hardware's
        if multiMode {
            if playerIndex > 0 { v |= 0x04 }                        // SI: low for the parent, high for children
            if players > 1 { v |= 0x08 }                            // SD: every console is connected and ready
            v |= UInt16(playerIndex & 3) << 4
            if error { v |= 0x40 }
        } else {
            v = cnt
        }
        return v
    }

    func writeCNT(_ v: UInt16) {
        let wasBusy = cnt & 0x80 != 0
        st16(bus.io, 0x128, v & 0x7FFF)
        guard multiMode else { return }
        let baud = Int(v & 3)
        if v & 0x80 != 0 && !wasBusy && playerIndex == 0 { startAsParent(baud: baud) }
        else if playerIndex != 0 { st16(bus.io, 0x128, (v & 0x7FFF) & ~0x80 | (isBusy ? 0x80 : 0)) }     // only the parent may start a transfer
    }

    private var isBusy: Bool { if case .idle = state { return false } else { return true } }

    // MARK: parent
    private func startAsParent(baud: Int) {
        let word = ld16(bus.io, 0x12A)
        error = false
        for i in 0..<4 { st16(bus.io, 0x120 + i * 2, 0xFFFF) }
        st16(bus.io, 0x120, word)
        let n = max(players, 1)
        let duration = UInt64(n * 18 * SIO.bitCycles[baud & 3] + 100)
        state = .parentWaiting(replies: [:], endsAt: bus.cycles + duration, deadline: bus.cycles + duration + SIO.timeoutCycles)
        if n > 1 { link?.send(.gbaRequest(send: word, baud: baud), to: nil) }
    }

    // MARK: per-line service
    func service() {
        if let link {
            for (from, message) in link.receive() { handle(message, from: from) }
        }
        switch state {
        case .idle: break
        case .parentWaiting(let replies, let endsAt, let deadline):
            let needed = max(players, 1) - 1
            if bus.cycles >= endsAt && (replies.count >= needed || bus.cycles >= deadline) {
                if replies.count < needed { error = true }
                var words: [UInt16] = [ld16(bus.io, 0x120), 0xFFFF, 0xFFFF, 0xFFFF]
                for (id, w) in replies where id > 0 && id < 4 { words[id] = w }
                finish(words)
                if needed > 0 { link?.send(.gbaResult(words), to: nil) }
            }
        case .childWaiting(let deadline):
            if bus.cycles >= deadline { error = true; finish([0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF]) }
        }
    }

    private func handle(_ message: LinkMessage, from: Int) {
        switch (message, state) {
        case (.gbaReply(let w), .parentWaiting(var replies, let endsAt, let deadline)):
            replies[from] = w
            state = .parentWaiting(replies: replies, endsAt: endsAt, deadline: deadline)
        case (.gbaRequest(let word, let baud), _) where playerIndex > 0 && multiMode:
            for i in 0..<4 { st16(bus.io, 0x120 + i * 2, 0xFFFF) }
            st16(bus.io, 0x120, word)
            st16(bus.io, 0x128, cnt | 0x80)                          // busy while the transfer runs
            error = false
            state = .childWaiting(deadline: bus.cycles + UInt64(players * 18 * SIO.bitCycles[baud & 3]) + SIO.timeoutCycles)
            link?.send(.gbaReply(send: ld16(bus.io, 0x12A)), to: 0)
        case (.gbaResult(let words), .childWaiting):
            finish(words)
        default: break
        }
    }

    /// Store the four words, clear the busy bit and raise the serial interrupt if it is enabled.
    private func finish(_ words: [UInt16]) {
        for i in 0..<4 { st16(bus.io, 0x120 + i * 2, i < words.count ? words[i] : 0xFFFF) }
        st16(bus.io, 0x128, cnt & ~0x80)
        state = .idle
        if cnt & 0x4000 != 0 { bus.ifl |= 0x80 }
    }

    /// After a save state is loaded no transfer is in flight.
    func restoreFromIO() { state = .idle; error = false; st16(bus.io, 0x128, cnt & ~0x80) }
}
