import Foundation

/// What two linked consoles say to each other. The same few messages cover both link cables.
public enum LinkMessage: Equatable, Sendable {
    /// GBA multi-player: the parent starts a transfer and sends its own word; `baud` is the SIOCNT baud-rate code (0...3).
    case gbaRequest(send: UInt16, baud: Int)
    /// GBA multi-player: a child's answer, the word in its send register.
    case gbaReply(send: UInt16)
    /// GBA multi-player: the finished transfer, one word per console (0xFFFF for a console that isn't there).
    case gbaResult([UInt16])
    /// Game Boy: a byte shifted out by whichever side started the transfer.
    case gbByte(UInt8)
    /// Game Boy: the other side's byte, shifted back in the same transfer.
    case gbReply(UInt8)
}

/// A cable between this console and one or more others. Implemented by the network layer in the app and by `LoopbackCable` in tests.
/// All calls are non-blocking; messages arrive whenever the other side has sent them.
public protocol SerialLink: AnyObject, Sendable {
    /// This console's place on the cable: 0 is the parent (master), 1...3 are children. A Game Boy link has players 0 and 1.
    var playerIndex: Int { get }
    /// Consoles on the cable right now, counting this one. 1 means nothing else is plugged in.
    var playerCount: Int { get }
    /// `player` nil means every other console.
    func send(_ message: LinkMessage, to player: Int?)
    /// Everything that has arrived since the last call, oldest first.
    func receive() -> [(from: Int, message: LinkMessage)]
}

/// A cable inside one process, for tests: up to four ends that hand messages to each other instantly.
public final class LoopbackCable: @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [[(from: Int, message: LinkMessage)]]
    private var present: [Bool]

    public init(capacity: Int = 4) {
        inbox = Array(repeating: [], count: capacity)
        present = Array(repeating: false, count: capacity)
    }

    /// Plug a console in as `player`.
    public func plugIn(player: Int) -> SerialLink {
        lock.lock(); present[player] = true; lock.unlock()
        return End(cable: self, index: player)
    }

    public func unplug(player: Int) { lock.lock(); present[player] = false; inbox[player].removeAll(); lock.unlock() }

    fileprivate var count: Int { lock.lock(); defer { lock.unlock() }; return present.filter { $0 }.count }

    fileprivate func deliver(_ message: LinkMessage, from: Int, to: Int?) {
        lock.lock(); defer { lock.unlock() }
        for p in inbox.indices where p != from && present[p] && (to == nil || to == p) { inbox[p].append((from, message)) }
    }

    fileprivate func take(_ player: Int) -> [(from: Int, message: LinkMessage)] {
        lock.lock(); defer { lock.unlock() }
        let out = inbox[player]; inbox[player].removeAll(); return out
    }

    private final class End: SerialLink, @unchecked Sendable {
        let cable: LoopbackCable
        let index: Int
        init(cable: LoopbackCable, index: Int) { self.cable = cable; self.index = index }
        var playerIndex: Int { index }
        var playerCount: Int { cable.count }
        func send(_ message: LinkMessage, to player: Int?) { cable.deliver(message, from: index, to: player) }
        func receive() -> [(from: Int, message: LinkMessage)] { cable.take(index) }
    }
}
