import Foundation
import GBACore
import Network

/// A link cable over the network: one console hosts, up to three more join (a Game Boy link is just two).
/// Messages go over TCP in small length-prefixed frames. The host is player 0 and relays for the others.
public final class NetworkLink: SerialLink, @unchecked Sendable {
    public enum Kind: UInt8, Sendable { case gba = 0, gameBoy = 1
        public var maxPlayers: Int { self == .gba ? 4 : 2 }
        public var label: String { self == .gba ? "Game Boy Advance" : "Game Boy" }
    }
    public enum Status: Equatable, Sendable {
        case idle
        case listening(port: UInt16)
        case joining(String)
        case connected
        case failed(String)
    }

    public static let bonjourType = "_swiftgb-link._tcp"
    public static let defaultPort: UInt16 = 7655
    private static let protocolVersion: UInt8 = 1

    public let kind: Kind
    public let isHost: Bool
    private let queue = DispatchQueue(label: "SwiftGB.link")
    private let lock = NSLock()

    private final class Peer {
        let connection: NWConnection
        var index: Int
        var buffer = Data()
        var joined = false
        init(_ c: NWConnection, index: Int) { connection = c; self.index = index }
    }

    private var listener: NWListener?
    private var peers: [Peer] = []                  // host: every joined or joining client. client: just the host's connection.
    private var myIndex = 0
    private var count = 1
    private var inbox: [(from: Int, message: LinkMessage)] = []
    private var currentStatus = Status.idle
    private var closed = false

    /// Called (on an arbitrary queue) whenever the status or the number of consoles on the cable changes.
    public var onChange: (@Sendable (Status, Int) -> Void)?

    private init(kind: Kind, isHost: Bool) { self.kind = kind; self.isHost = isHost }

    // MARK: SerialLink
    public var playerIndex: Int { lock.lock(); defer { lock.unlock() }; return myIndex }
    public var playerCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    public var status: Status { lock.lock(); defer { lock.unlock() }; return currentStatus }

    public func receive() -> [(from: Int, message: LinkMessage)] {
        lock.lock(); defer { lock.unlock() }
        let out = inbox; inbox.removeAll(); return out
    }

    public func send(_ message: LinkMessage, to player: Int?) {
        let frame = Wire.frame(Wire.encode(message))
        lock.lock()
        let targets = isHost ? peers.filter { $0.joined && (player == nil || $0.index == player) } : peers.filter { $0.joined }
        lock.unlock()
        if !isHost && player != nil && player != 0 { return }
        for p in targets { p.connection.send(content: frame, completion: .contentProcessed { _ in }) }
    }

    // MARK: hosting
    /// Listen for consoles to join. `port` nil picks any free port (see `Status.listening`). With `advertise` the game shows up
    /// on the local network for other copies of the app to find.
    public static func host(kind: Kind, port: UInt16? = defaultPort, advertise: Bool = true, name: String = Host.current().localizedName ?? "SwiftGB") -> NetworkLink {
        let link = NetworkLink(kind: kind, isHost: true)
        link.startListening(port: port, advertise: advertise, name: name)
        return link
    }

    private func startListening(port: UInt16?, advertise: Bool, name: String) {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        do {
            let l = try port.map { try NWListener(using: params, on: NWEndpoint.Port(rawValue: $0)!) } ?? NWListener(using: params)
            if advertise { l.service = NWListener.Service(name: "\(name) · \(kind.label)", type: NetworkLink.bonjourType) }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self else { return }
                switch state {
                case .ready: if let p = l?.port?.rawValue { self.set(.listening(port: p)) }
                case .failed(let e): self.set(.failed("Couldn't start listening: \(e.localizedDescription)"))
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            lock.lock(); listener = l; lock.unlock()
            l.start(queue: queue)
        } catch {
            set(.failed("Couldn't start listening: \(error.localizedDescription)"))
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let full = peers.filter { $0.joined }.count + 1 >= kind.maxPlayers
        lock.unlock()
        if full { connection.cancel(); return }
        let peer = Peer(connection, index: -1)
        lock.lock(); peers.append(peer); lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .failed, .cancelled: self.drop(peer)
            default: break
            }
        }
        connection.start(queue: queue)
        read(peer)
    }

    // MARK: joining
    public static func join(kind: Kind, host: String, port: UInt16 = defaultPort) -> NetworkLink {
        let link = NetworkLink(kind: kind, isHost: false)
        link.connect(NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: defaultPort)!), label: "\(host):\(port)")
        return link
    }

    public static func join(kind: Kind, endpoint: NWEndpoint, label: String) -> NetworkLink {
        let link = NetworkLink(kind: kind, isHost: false)
        link.connect(endpoint, label: label)
        return link
    }

    private func connect(_ endpoint: NWEndpoint, label: String) {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.connectionTimeout = 8
        let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        let peer = Peer(connection, index: 0)
        lock.lock(); peers = [peer]; lock.unlock()
        set(.joining(label))
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready: connection.send(content: Wire.frame([Wire.join, NetworkLink.protocolVersion, self.kind.rawValue]), completion: .contentProcessed { _ in })
            case .failed(let e): self.lost("Couldn't connect: \(e.localizedDescription)"); _ = peer
            case .cancelled: break
            case .waiting(let e): self.set(.joining("\(label) — waiting: \(e.localizedDescription)"))
            default: break
            }
        }
        connection.start(queue: queue)
        read(peer)
    }

    // MARK: closing
    public func close() {
        lock.lock()
        closed = true
        let ps = peers, l = listener
        peers = []; listener = nil; count = 1; currentStatus = .idle
        lock.unlock()
        for p in ps { p.connection.cancel() }
        l?.cancel()
        onChange?(.idle, 1)
    }

    // MARK: reading
    private func read(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak peer] data, _, complete, error in
            guard let self, let peer else { return }
            if let data, !data.isEmpty {
                peer.buffer.append(data)
                if !self.drain(peer) { return }
            }
            if complete || error != nil {
                if self.isHost { self.drop(peer) } else { self.lost("The connection ended") }
                return
            }
            self.read(peer)
        }
    }

    /// Process every complete frame in the peer's buffer. Returns false if the peer was dropped for sending garbage.
    private func drain(_ peer: Peer) -> Bool {
        while peer.buffer.count >= 2 {
            let len = Int(peer.buffer[peer.buffer.startIndex]) << 8 | Int(peer.buffer[peer.buffer.startIndex + 1])
            guard len >= 1, len <= 64 else { reject(peer, "bad frame"); return false }
            guard peer.buffer.count >= 2 + len else { return true }
            let body = [UInt8](peer.buffer[(peer.buffer.startIndex + 2)..<(peer.buffer.startIndex + 2 + len)])
            peer.buffer.removeFirst(2 + len)
            if !handle(body, from: peer) { return false }
        }
        return true
    }

    private func handle(_ body: [UInt8], from peer: Peer) -> Bool {
        switch body[0] {
        case Wire.join where isHost:
            guard body.count == 3, body[1] == NetworkLink.protocolVersion else { reject(peer, "different version of SwiftGB"); return false }
            guard body[2] == kind.rawValue else { reject(peer, "this is a \(kind.label) game, not a \(Kind(rawValue: body[2])?.label ?? "different") one"); return false }
            lock.lock()
            let used = Set(peers.filter { $0.joined }.map(\.index))
            guard let index = (1..<kind.maxPlayers).first(where: { !used.contains($0) }) else { lock.unlock(); reject(peer, "the cable is full"); return false }
            peer.index = index; peer.joined = true
            count = peers.filter { $0.joined }.count + 1
            let n = count
            lock.unlock()
            peer.connection.send(content: Wire.frame([Wire.hello, UInt8(index), UInt8(n)]), completion: .contentProcessed { _ in })
            broadcastRoster()
            changed()
        case Wire.hello where !isHost:
            guard body.count == 3 else { return true }
            lock.lock(); myIndex = Int(body[1]); count = Int(body[2]); peer.joined = true; lock.unlock()     // from now on the host connection is the cable
            set(.connected)
        case Wire.roster where !isHost:
            guard body.count == 2 else { return true }
            lock.lock(); count = Int(body[1]); lock.unlock()
            changed()
        case Wire.rejected where !isHost:
            lost("The host refused the connection: " + String(decoding: body.dropFirst(), as: UTF8.self))
            return false
        default:
            if let message = Wire.decode(body) {
                lock.lock(); inbox.append((from: isHost ? peer.index : 0, message: message)); lock.unlock()
            }
        }
        return true
    }

    private func reject(_ peer: Peer, _ reason: String) {
        peer.connection.send(content: Wire.frame([Wire.rejected] + Array(reason.utf8.prefix(60))), completion: .contentProcessed { _ in peer.connection.cancel() })
        lock.lock(); peers.removeAll { $0 === peer }; lock.unlock()
    }

    private func drop(_ peer: Peer) {
        lock.lock()
        let had = peers.contains { $0 === peer }
        peers.removeAll { $0 === peer }
        count = peers.filter { $0.joined }.count + 1
        lock.unlock()
        peer.connection.cancel()
        if had { broadcastRoster(); changed() }
    }

    private func lost(_ why: String) {
        lock.lock()
        let was = closed
        let ps = peers; peers = []; count = 1; myIndex = 0
        lock.unlock()
        for p in ps { p.connection.cancel() }
        if !was { set(.failed(why)) }
    }

    private func broadcastRoster() {
        lock.lock(); let targets = peers.filter { $0.joined }; let n = count; lock.unlock()
        for p in targets { p.connection.send(content: Wire.frame([Wire.roster, UInt8(n)]), completion: .contentProcessed { _ in }) }
    }

    private func set(_ s: Status) {
        lock.lock(); currentStatus = s; let n = count; lock.unlock()
        onChange?(s, n)
    }

    private func changed() {
        lock.lock(); let s = currentStatus; let n = count; lock.unlock()
        onChange?(s, n)
    }

    // MARK: wire format
    enum Wire {
        static let join: UInt8 = 0x01, hello: UInt8 = 0x02, roster: UInt8 = 0x03, rejected: UInt8 = 0x04
        static let gbaRequest: UInt8 = 0x10, gbaReply: UInt8 = 0x11, gbaResult: UInt8 = 0x12, gbByte: UInt8 = 0x20, gbReply: UInt8 = 0x21

        /// Two bytes of length (of what follows) and then the body.
        static func frame(_ body: [UInt8]) -> Data { Data([UInt8(body.count >> 8), UInt8(body.count & 255)] + body) }

        static func encode(_ m: LinkMessage) -> [UInt8] {
            switch m {
            case .gbaRequest(let w, let baud): return [gbaRequest, UInt8(w >> 8), UInt8(w & 255), UInt8(baud & 3)]
            case .gbaReply(let w): return [gbaReply, UInt8(w >> 8), UInt8(w & 255)]
            case .gbaResult(let ws): return [gbaResult] + ws.prefix(4).flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
            case .gbByte(let b): return [gbByte, b]
            case .gbReply(let b): return [gbReply, b]
            }
        }

        static func decode(_ b: [UInt8]) -> LinkMessage? {
            func w(_ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
            switch b[0] {
            case gbaRequest where b.count == 4: return .gbaRequest(send: w(1), baud: Int(b[3] & 3))
            case gbaReply where b.count == 3: return .gbaReply(send: w(1))
            case gbaResult where b.count == 9: return .gbaResult([w(1), w(3), w(5), w(7)])
            case gbByte where b.count == 2: return .gbByte(b[1])
            case gbReply where b.count == 2: return .gbReply(b[1])
            default: return nil
            }
        }
    }
}

/// The addresses other consoles on the network can use to reach this Mac.
public enum LocalAddresses {
    public static func ipv4() -> [String] {
        var result = [String]()
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [] }
        defer { freeifaddrs(first) }
        var p: UnsafeMutablePointer<ifaddrs>? = start
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { result.append(String(cString: host)) }
            }
            p = cur.pointee.ifa_next
        }
        return result
    }
}
