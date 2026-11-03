import AppKit
import AVFoundation
import Foundation
import GBACore
import GBARender
import GBAUI

// Headless checks of the app's engine layer. Nothing here opens a window or plays a sound.
//   gbaui-harness            run everything
//   gbaui-harness speed      just the speed/pacing checks (others: render, autosave, storage)

_ = NSApplication.shared                // AppKit views need the application object to exist; this shows nothing

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if !ok { failures += 1 }
    print("  \(ok ? "ok  " : "FAIL") \(name)" + (detail.isEmpty ? "" : ": \(detail)"))
}

/// A core that does almost no work per frame, so what is measured is the session's pacing and not emulation cost.
final class StubCore: EmulatorCore, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var frames: Int { lock.lock(); defer { lock.unlock() }; return count }
    var statusNote: String? { nil }
    var screenWidth: Int { 240 }
    var screenHeight: Int { 160 }
    var framesPerSecond: Double { 60 }
    var audioSampleRate: Int { 48_000 }
    /// Pretend each frame costs this long, to look like a Mac that can't keep up.
    var workMilliseconds = 0.0
    func reset() {}
    func setKeys(_ keys: GBAKeys) {}
    func runFrame(framebuffer: UnsafeMutablePointer<UInt32>) {
        if workMilliseconds > 0 { Thread.sleep(forTimeInterval: workMilliseconds / 1000) }
        lock.lock(); count += 1; lock.unlock(); framebuffer[0] = UInt32(truncatingIfNeeded: count)
    }
    func readAudio(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int { 0 }
    func saveState() -> Data? { Data("stub\(frames)".utf8) }
    func loadState(_ data: Data) -> Bool { true }
}

func newSession(_ core: EmulatorCore) -> EmulationSession { EmulationSession(core: core, mailbox: FrameMailbox(), audio: AudioOutput()) }

/// Frames per second the core was driven at over `seconds`.
func measure(_ core: StubCore, _ seconds: Double) -> Double {
    let a = core.frames, t0 = DispatchTime.now().uptimeNanoseconds
    Thread.sleep(forTimeInterval: seconds)
    return Double(core.frames - a) / (Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
}

let only = CommandLine.arguments.dropFirst().first

// MARK: speed
if only == nil || only == "speed" {
    print("speed and pacing")
    let core = StubCore()
    let s = newSession(core)
    s.start()
    Thread.sleep(forTimeInterval: 0.3)
    for speed in [1.0, 0.5, 2, 4, 8, 16] {
        s.setSpeed(speed)
        Thread.sleep(forTimeInterval: 0.2)
        let fps = measure(core, 1.0)
        let want = 60 * speed
        check("\(EmulationSpeed.label(speed)) runs at \(Int(want)) frames/s", abs(fps - want) / want < 0.15, String(format: "%.1f frames/s", fps))
    }
    s.setSpeed(.infinity)
    Thread.sleep(forTimeInterval: 0.2)
    let free = measure(core, 0.5)
    check("Unlimited has no pacing at all", free > 60 * 256 * 2, String(format: "%.0f frames/s (the 256× step would be 15360)", free))

    s.setSpeed(1)
    s.setFastForwardSpeed(8)
    Thread.sleep(forTimeInterval: 0.2)
    check("normal speed before the key is held", abs(measure(core, 1.0) - 60) < 9)
    s.setFastForward(true)
    Thread.sleep(forTimeInterval: 0.2)
    let held = measure(core, 1.0)
    check("holding fast-forward runs at the chosen 8×", abs(held - 480) / 480 < 0.15, String(format: "%.0f frames/s", held))
    s.setFastForwardSpeed(.infinity)
    Thread.sleep(forTimeInterval: 0.2)
    check("fast-forward can be set to Unlimited, live", measure(core, 0.5) > 60 * 256 * 2)
    s.setFastForwardSpeed(2)
    Thread.sleep(forTimeInterval: 0.2)
    check("…and back down to 2× without restarting", abs(measure(core, 1.0) - 120) / 120 < 0.15)
    s.setFastForward(false)
    Thread.sleep(forTimeInterval: 0.2)
    check("releasing returns to normal speed", abs(measure(core, 1.0) - 60) < 9)

    // The session thread must keep taking jobs even when running flat out.
    s.setSpeed(.infinity)
    let done = DispatchSemaphore(value: 0)
    let t0 = DispatchTime.now().uptimeNanoseconds
    s.perform { _, _ in done.signal() }
    let ran = done.wait(timeout: .now() + 1) == .success
    check("jobs still run promptly while Unlimited", ran && DispatchTime.now().uptimeNanoseconds - t0 < 200_000_000)
    s.stop()
}

// MARK: link over the network
if only == nil || only == "link" {
    print("link cable over TCP on this Mac (no Bonjour: it would ask for network permission)")

    func waitFor(_ timeout: Double = 4, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.02) }
        return condition()
    }
    final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var items = [(from: Int, message: LinkMessage)]()
        func pull(_ link: SerialLink) { let new = link.receive(); lock.lock(); items += new; lock.unlock() }
        func contains(_ from: Int, _ m: LinkMessage) -> Bool { lock.lock(); defer { lock.unlock() }; return items.contains { $0.from == from && $0.message == m } }
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    }
    func arrives(_ link: SerialLink, _ box: Mailbox, from: Int, _ m: LinkMessage) -> Bool { waitFor(2) { box.pull(link); return box.contains(from, m) } }

    let host = NetworkLink.host(kind: .gba, port: nil, advertise: false)
    var port: UInt16 = 0
    check("the host starts listening on a port", waitFor { if case .listening(let p) = host.status { port = p; return true }; return false }, "port \(port)")
    check("alone on the cable at first", host.playerCount == 1 && host.playerIndex == 0)

    let c1 = NetworkLink.join(kind: .gba, host: "127.0.0.1", port: port)
    check("a client joins", waitFor { c1.status == .connected && host.playerCount == 2 && c1.playerCount == 2 })
    check("the host is player 0, the first client player 1", host.playerIndex == 0 && c1.playerIndex == 1)

    let hostBox = Mailbox(), c1Box = Mailbox()
    host.send(.gbaRequest(send: 0x1234, baud: 2), to: nil)
    check("host → client: a transfer request", arrives(c1, c1Box, from: 0, .gbaRequest(send: 0x1234, baud: 2)))
    c1.send(.gbaReply(send: 0xBEEF), to: 0)
    check("client → host: its word, tagged with the client's number", arrives(host, hostBox, from: 1, .gbaReply(send: 0xBEEF)))
    host.send(.gbaResult([0x1234, 0xBEEF, 0xFFFF, 0xFFFF]), to: nil)
    check("host → client: the four-word result", arrives(c1, c1Box, from: 0, .gbaResult([0x1234, 0xBEEF, 0xFFFF, 0xFFFF])))
    c1.send(.gbByte(0x5A), to: 0); host.send(.gbReply(0xA5), to: nil)
    check("single bytes and replies survive too", arrives(host, hostBox, from: 1, .gbByte(0x5A)) && arrives(c1, c1Box, from: 0, .gbReply(0xA5)))

    let c2 = NetworkLink.join(kind: .gba, host: "127.0.0.1", port: port)
    check("a second client makes three consoles, and everyone learns the count", waitFor { host.playerCount == 3 && c1.playerCount == 3 && c2.playerCount == 3 })
    check("each client gets its own number", Set([c1.playerIndex, c2.playerIndex]) == [1, 2])
    let c2Box = Mailbox()
    host.send(.gbaReply(send: 7), to: c2.playerIndex)
    check("a message addressed to one client reaches only that client", arrives(c2, c2Box, from: 0, .gbaReply(send: 7)))
    Thread.sleep(forTimeInterval: 0.2); c1Box.pull(c1)
    check("…and not the others", !c1Box.contains(0, .gbaReply(send: 7)))
    c1.send(.gbaReply(send: 9), to: 2)
    Thread.sleep(forTimeInterval: 0.2); c2Box.pull(c2)
    check("a client's message goes to the host, never to another client", !c2Box.contains(1, .gbaReply(send: 9)))

    let c3 = NetworkLink.join(kind: .gba, host: "127.0.0.1", port: port)
    check("a fourth console fits (the GBA cable takes four)", waitFor { host.playerCount == 4 && c3.status == .connected })
    let c4 = NetworkLink.join(kind: .gba, host: "127.0.0.1", port: port)
    var refused = false
    check("a fifth is turned away and the cable is unharmed", waitFor { if case .failed = c4.status { refused = true }; return refused } && host.playerCount == 4)

    let wrong = NetworkLink.host(kind: .gba, port: nil, advertise: false)
    var wrongPort: UInt16 = 0
    _ = waitFor { if case .listening(let p) = wrong.status { wrongPort = p; return true }; return false }
    let gb = NetworkLink.join(kind: .gameBoy, host: "127.0.0.1", port: wrongPort)
    var why = ""
    check("a Game Boy can't join a GBA cable, and is told why", waitFor { if case .failed(let w) = gb.status { why = w; return true }; return false } && why.contains("Game Boy Advance"), why)
    check("…which doesn't disturb the host", wrong.playerCount == 1)
    wrong.close()

    c1.close()
    check("a client leaving is noticed by the host and the others", waitFor { host.playerCount == 3 && c2.playerCount == 3 })
    host.close()
    check("the host closing drops the clients", waitFor { if case .failed = c2.status { return true }; return false } && c2.playerCount == 1)
    c2.close(); c3.close(); c4.close(); gb.close()

    check("local addresses are well-formed IPv4", LocalAddresses.ipv4().allSatisfy { $0.split(separator: ".").count == 4 && $0.split(separator: ".").allSatisfy { Int($0) != nil } })

    // Two consoles on a real TCP link, running programs.
    func gbLinkROM(out: UInt8, master: Bool) -> Data {
        var rom = Data(count: 0x8000)
        rom.replaceSubrange(0x100..<0x104, with: [0x00, 0xC3, 0x50, 0x01])
        let code: [UInt8] = [0x3E, out, 0xE0, 0x01, 0x3E, master ? 0x81 : 0x80, 0xE0, 0x02, 0xF0, 0x02, 0xCB, 0x7F, 0x20, 0xFA, 0xF0, 0x01, 0xEA, 0x00, 0xC0, 0x18, 0xFE]
        rom.replaceSubrange(0x150..<(0x150 + code.count), with: code)
        return rom
    }
    do {
        let h = NetworkLink.host(kind: .gameBoy, port: nil, advertise: false)
        var p: UInt16 = 0
        _ = waitFor { if case .listening(let x) = h.status { p = x; return true }; return false }
        let j = NetworkLink.join(kind: .gameBoy, host: "127.0.0.1", port: p)
        _ = waitFor { h.playerCount == 2 && j.status == .connected }
        let a = GBConsole(rom: gbLinkROM(out: 0x42, master: true)), b = GBConsole(rom: gbLinkROM(out: 0x99, master: false))
        a.attachLink(h); b.attachLink(j)
        let f = UnsafeMutablePointer<UInt32>.allocate(capacity: 160 * 144); defer { f.deallocate() }
        let done = waitFor(5) { a.runFrame(framebuffer: f); b.runFrame(framebuffer: f); return a.peek(0xC000) == 0x99 && b.peek(0xC000) == 0x42 }
        check("two Game Boys exchange bytes over TCP (0x42 ↔ 0x99)", done, "master got \(String(a.peek(0xC000), radix: 16)), slave got \(String(b.peek(0xC000), radix: 16))")
        h.close(); j.close()
    }
    do {
        var rom = Data(count: 0x400); rom.replaceSubrange(0..<4, with: [0xFE, 0xFF, 0xFF, 0xEA])
        let h = NetworkLink.host(kind: .gba, port: nil, advertise: false)
        var p: UInt16 = 0
        _ = waitFor { if case .listening(let x) = h.status { p = x; return true }; return false }
        let j1 = NetworkLink.join(kind: .gba, host: "127.0.0.1", port: p), j2 = NetworkLink.join(kind: .gba, host: "127.0.0.1", port: p)
        _ = waitFor { h.playerCount == 3 && j1.playerCount == 3 && j2.playerCount == 3 }
        let links: [SerialLink] = [h, j1, j2]
        let cs = links.map { l -> GBAConsole in let c = GBAConsole(rom: rom); c.attachLink(l); return c }
        let io: UInt32 = 0x0400_0000
        // Players get their number from the order they connected, so read it back instead of assuming.
        for (c, l) in zip(cs, links) {
            c.machine.bus.poke16(io + 0x134, 0); c.machine.bus.poke16(io + 0x128, 0x2003 | 0x4000)
            c.machine.bus.poke16(io + 0x12A, UInt16(0x1000 * (l.playerIndex + 1)))
        }
        cs[0].machine.bus.poke16(io + 0x128, 0x2003 | 0x4000 | 0x80)
        let f = UnsafeMutablePointer<UInt32>.allocate(capacity: 240 * 160); defer { f.deallocate() }
        let all = waitFor(5) {
            for c in cs { c.runFrame(framebuffer: f) }
            return cs.allSatisfy { $0.machine.bus.peek16(io + 0x128) & 0x80 == 0 && $0.machine.bus.peek16(io + 0x120) == 0x1000 }
        }
        let words = cs.map { c in (0..<4).map { String(c.machine.bus.peek16(io + 0x120 + UInt32($0 * 2)), radix: 16) } }
        check("three GBAs exchange words over TCP: all see 1000, 2000, 3000, FFFF", all && words.allSatisfy { $0 == ["1000", "2000", "3000", "ffff"] }, "\(words)")
        check("…and each raised its serial interrupt", cs.allSatisfy { $0.machine.bus.ifl & 0x80 != 0 })
        h.close(); j1.close(); j2.close()
    }
}

// MARK: statistics
if only == nil || only == "stats" {
    print("session statistics")
    let fast = StubCore()
    let a = newSession(fast)
    a.start()
    Thread.sleep(forTimeInterval: 1.6)
    let s1 = a.statsSnapshot()
    a.stop()
    check("an easy core shows tiny frame times and plenty of headroom", s1.averageMs < 3 && s1.headroom > 5, String(format: "avg %.3f ms, headroom %.0fx", s1.averageMs, s1.headroom))
    check("percentiles are ordered: average ≤ p99 ≤ worst", s1.averageMs <= s1.p99Ms + 1e-9 && s1.p99Ms <= s1.worstMs + 1e-9)
    check("measured rate is the 60 fps target", abs(s1.framesPerSecond - 60) < 6, String(format: "%.1f fps", s1.framesPerSecond))
    check("an easy core has (almost) no slow frames; a stray one is the machine being busy", s1.overruns <= 2, "\(s1.overruns) of the last 2 s, worst \(String(format: "%.1f", s1.worstMs)) ms")

    let slow = StubCore(); slow.workMilliseconds = 25
    let b = newSession(slow)
    b.start()
    Thread.sleep(forTimeInterval: 1.5)
    let s2 = b.statsSnapshot()
    b.stop()
    check("a core too slow for real time reports it (25 ms/frame vs a 16.7 ms budget)", s2.averageMs > 22 && s2.headroom < 1 && s2.overruns > 10, String(format: "avg %.1f ms, headroom %.2fx, %d slow frames", s2.averageMs, s2.headroom, s2.overruns))
}

// MARK: recording
if only == nil || only == "record" {
    print("recording")
    let dir = NSTemporaryDirectory() + "gbaui-record-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    func inspect(_ url: URL, name: String, expectWidth: Int, expectHeight: Int, expectSeconds: Double, expectFrames: Int) async {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            check("\(name): duration is \(expectSeconds) s", abs(duration - expectSeconds) < 0.15, String(format: "%.3f s", duration))
            let vtracks = try await asset.loadTracks(withMediaType: .video)
            let atracks = try await asset.loadTracks(withMediaType: .audio)
            check("\(name): one video track and one audio track", vtracks.count == 1 && atracks.count == 1)
            if let v = vtracks.first {
                let size = try await v.load(.naturalSize)
                check("\(name): video is \(expectWidth)x\(expectHeight) (whole-pixel enlargement)", Int(size.width) == expectWidth && Int(size.height) == expectHeight, "\(Int(size.width))x\(Int(size.height))")
                let reader = try AVAssetReader(asset: asset)
                let out = AVAssetReaderTrackOutput(track: v, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(out); reader.startReading()
                var n = 0
                while out.copyNextSampleBuffer() != nil { n += 1 }
                check("\(name): \(expectFrames) frames stored", abs(n - expectFrames) <= 2, "\(n)")
            }
            if let a = atracks.first {
                let range = try await a.load(.timeRange)
                check("\(name): audio runs as long as the video", abs(range.duration.seconds - expectSeconds) < 0.2, String(format: "%.3f s", range.duration.seconds))
                let formats = try await a.load(.formatDescriptions)
                let rate = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
                check("\(name): audio is 48 kHz", rate == 48_000, "\(rate ?? 0)")
            }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            let (image, _) = try await gen.image(at: CMTime(seconds: expectSeconds / 2, preferredTimescale: 600))
            var distinct = Set<UInt32>()
            if let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), let data = { ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return ctx.data }() {
                let px = data.assumingMemoryBound(to: UInt32.self)
                for i in stride(from: 0, to: image.width * image.height, by: 997) { distinct.insert(px[i] & 0x00F0F0F0) }
            }
            check("\(name): a frame from the middle is a real picture, not blank", distinct.count >= 3, "\(distinct.count) distinct colours")
        } catch {
            check("\(name): file can be opened", false, "\(error)")
        }
    }

    func record(_ name: String, core: EmulatorCore, seconds: Double, scale: Int) async -> (URL, Int)? {
        let url = URL(fileURLWithPath: dir + "/\(name).mp4")
        guard let rec = try? VideoRecorder(url: url, width: core.screenWidth, height: core.screenHeight, scale: scale, framesPerSecond: core.framesPerSecond) else { check("\(name): recorder starts", false); return nil }
        let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: core.screenWidth * core.screenHeight); defer { fb.deallocate() }
        let audio = UnsafeMutablePointer<Int16>.allocate(capacity: 2 * 4096); defer { audio.deallocate() }
        let frames = Int((seconds * core.framesPerSecond).rounded())
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<frames {
            core.runFrame(framebuffer: fb)
            let n = core.readAudio(into: audio, maxFrames: 4096)
            rec.append(frame: fb, audio: audio, audioFrames: n)
        }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        let ok: Bool = await withCheckedContinuation { c in rec.finish { c.resume(returning: $0) } }
        check("\(name): file finished", ok)
        check("\(name): recorded faster than real time and still stamped by emulated time", wall < seconds, String(format: "%.1f s of game in %.2f s", seconds, wall))
        return ok ? (url, frames) : nil
    }

    if let rom = FileManager.default.contents(atPath: "TestROMs/gb-test-roms/acid2/dmg-acid2.gb"),
       let (url, frames) = await record("gameboy", core: GBConsole(rom: rom), seconds: 3, scale: 5) {
        await inspect(url, name: "Game Boy", expectWidth: 800, expectHeight: 720, expectSeconds: Double(frames) / (4_194_304.0 / 70_224.0), expectFrames: frames)
    }
    if let rom = FileManager.default.contents(atPath: "TestROMs/jsmolka-gba-tests/ppu/shades.gba"),
       let (url, frames) = await record("gba", core: GBAConsole(rom: rom), seconds: 3, scale: 5) {
        await inspect(url, name: "GBA", expectWidth: 1200, expectHeight: 800, expectSeconds: Double(frames) / GBAConstants.framesPerSecond, expectFrames: frames)
    }

    // Through the real session, flat out: the file's length must follow emulated frames, not the clock.
    if let rom = FileManager.default.contents(atPath: "TestROMs/gb-test-roms/acid2/cgb-acid2.gbc") {
        let core = GBConsole(rom: rom)
        let s = newSession(core)
        let url = URL(fileURLWithPath: dir + "/session.mp4")
        if let rec = try? VideoRecorder(url: url, width: 160, height: 144, framesPerSecond: core.framesPerSecond) {
            s.setSpeed(.infinity)
            s.setRecorder(rec)
            s.start()
            Thread.sleep(forTimeInterval: 1.0)
            s.setRecorder(nil)
            s.stop()
            let written = rec.framesWritten
            let ok: Bool = await withCheckedContinuation { c in rec.finish { c.resume(returning: $0) } }
            check("a small requested size is enlarged to at least 640 px on the short side", VideoRecorder.effectiveScale(width: 160, height: 144, requested: 1) == 5 && VideoRecorder.effectiveScale(width: 240, height: 160, requested: 2) == 4 && VideoRecorder.effectiveScale(width: 160, height: 144, requested: 8) == 8)
            check("session recording at Unlimited speed produces a file", ok && written > 100, "\(written) frames in 1 s of wall time")
            let d = try? await AVURLAsset(url: url).load(.duration).seconds
            check("…whose length is frames ÷ 59.73, not elapsed time (fast-forward doesn't speed it up)", d.map { abs($0 - Double(written) / core.framesPerSecond) < 0.1 && $0 > 1.5 } ?? false, d.map { String(format: "%.2f s for %d frames", $0, written) } ?? "unreadable")
        }
    }
}

// MARK: where does session recording spend its time?
if only == "recspeed" {
    print("session recording rate (diagnostic)")
    guard let rom = FileManager.default.contents(atPath: "TestROMs/gb-test-roms/acid2/cgb-acid2.gbc") else { exit(2) }
    let dir = NSTemporaryDirectory() + "gbaui-recspeed-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    for (label, scale, record) in [("no recorder", 0, false), ("recorder, scale 3", 3, true), ("recorder, scale 5", 5, true), ("recorder, scale 1", 1, true)] {
        let core = GBConsole(rom: rom)
        let s = newSession(core)
        s.setSpeed(.infinity)
        var rec: VideoRecorder?
        if record { rec = try? VideoRecorder(url: URL(fileURLWithPath: dir + "/\(scale).mp4"), width: 160, height: 144, scale: scale, framesPerSecond: core.framesPerSecond); s.setRecorder(rec) }
        let before = core.cycleCount
        s.start()
        Thread.sleep(forTimeInterval: 2.0)
        s.setRecorder(nil)
        s.stop()
        let frames = Double(core.cycleCount - before) / 70_224
        print(String(format: "  %@: %.0f emulated frames/s, %d frames written", label, frames / 2, rec?.framesWritten ?? 0))
        if let rec { let _: Bool = await withCheckedContinuation { c in rec.finish { c.resume(returning: $0) } } }
    }
    exit(0)
}

// MARK: autosave
if only == nil || only == "autosave" {
    print("autosave")
    guard let rom = FileManager.default.contents(atPath: "TestROMs/jsmolka-gba-tests/arm/arm.gba") else { print("  missing test ROM"); exit(2) }

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var states = [(Data, Bool)]()
        func add(_ d: Data, _ final: Bool) { lock.lock(); states.append((d, final)); lock.unlock() }
        var snapshot: [(Data, Bool)] { lock.lock(); defer { lock.unlock() }; return states }
    }

    do {
        let core = GBAConsole(rom: rom)
        let s = newSession(core)
        let got = Collector()
        s.onAutosave = { got.add($0, $1) }
        s.setAutosave(interval: 1)
        s.start()
        Thread.sleep(forTimeInterval: 3.6)
        let beforeStop = got.snapshot
        check("an autosave about every second (3 in 3.6 s)", beforeStop.count == 3 && beforeStop.allSatisfy { !$0.1 }, "\(beforeStop.count) saves")
        s.stop()
        let all = got.snapshot
        check("one more, flagged final, as the session ends", all.count == 4 && all.last?.1 == true, "\(all.count) saves, last final=\(all.last?.1 ?? false)")
        let fresh = GBAConsole(rom: rom)
        check("every autosave loads into a fresh machine", all.allSatisfy { fresh.loadState($0.0) })
        check("autosaves differ as the game advances", Set(all.map { $0.0 }).count == all.count)
    }
    do {
        let s = newSession(GBAConsole(rom: rom))
        let got = Collector()
        s.onAutosave = { got.add($0, $1) }
        s.setAutosave(interval: nil)
        s.start()
        Thread.sleep(forTimeInterval: 1.5)
        s.stop()
        check("with autosave off nothing is saved, not even on exit", got.snapshot.isEmpty, "\(got.snapshot.count) saves")
    }
    do {
        let s = newSession(StubCore())
        let got = Collector()
        s.onAutosave = { got.add($0, $1) }
        s.setAutosave(interval: 3600)
        s.start()
        Thread.sleep(forTimeInterval: 0.5)
        s.setAutosave(interval: 0.5)
        Thread.sleep(forTimeInterval: 1.4)
        let live = got.snapshot.count
        check("changing the interval takes effect while running (1 h → 0.5 s)", live >= 2 && live <= 3, "\(live) saves")
        s.setAutosave(interval: nil)
        let atOff = got.snapshot.count
        Thread.sleep(forTimeInterval: 1.0)
        check("turning it off stops it", got.snapshot.count == atOff)
        s.stop()
    }
    do {
        let s = newSession(StubCore())
        let got = Collector()
        s.onAutosave = { got.add($0, $1) }
        s.setAutosave(interval: 0.5)
        s.setPaused(true)
        s.start()
        Thread.sleep(forTimeInterval: 1.4)
        check("no autosave while paused", got.snapshot.filter { !$0.1 }.isEmpty)
        s.stop()
    }
}

// MARK: storage
if only == nil || only == "storage" {
    print("autosave storage")
    let dir = NSTemporaryDirectory() + "gbaui-harness-\(getpid())"
    setenv("SWIFTGB_DATA_DIR", dir, 1)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let game = Game(system: .gba, title: "Harness Game", gameCode: "TEST", path: "/nonexistent/harness.gba")
    let store = GameStorage(game: game)
    check("no autosave to begin with", store.readAutosave() == nil && store.autosaveDate == nil)
    let state = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
    check("an autosave is written", store.writeAutosave(state))
    check("…and read back identically", store.readAutosave() == state)
    check("…with a date", store.autosaveDate.map { abs($0.timeIntervalSinceNow) < 5 } ?? false)
    check("a numbered slot is separate from the autosave", store.writeState(Data("slot".utf8), slot: 1) && store.readAutosave() == state && store.readState(slot: 1) == Data("slot".utf8))
    let newer = Data("newer".utf8)
    _ = store.writeAutosave(newer)
    check("a new autosave replaces the old one", store.readAutosave() == newer)
    let other = GameStorage(game: Game(system: .gb, title: "Other", gameCode: "ABCD", path: "/x/other.gb"))
    check("each game has its own autosave", other.readAutosave() == nil)
}

// MARK: rendering
if only == nil || only == "render" {
    print("rendering (offscreen, no window)")
    for line in MainActor.assumeIsolated({ refreshSelfTest() }) {
        let ok = !line.hasPrefix("FAIL")
        if !ok { failures += 1 }
        print("  " + (line.hasPrefix("ok") || line.hasPrefix("FAIL") ? line : "ok   " + line))
    }
    for (name, w, h) in [("1080p", 1920, 1080), ("4K", 3840, 2160), ("8K", 7680, 4320), ("16K", 15360, 8640)] {
        let r = ScreenRenderer.offscreenSelfTest(width: w, height: h, frames: 2)
        check("draws correctly at \(name)", r.ok, String(format: "%@ in %.1f ms", r.detail, r.millis))
    }
    check("resolution presets stay inside Metal's limit", RenderResolution.allCases.allSatisfy {
        guard let s = $0.drawableSize(aspect: 32.0 / 9.0) else { return $0 == .native }
        return s.width <= 16384 && s.height <= 16384
    })
    check("16K keeps the window's shape", RenderResolution.k16.drawableSize(aspect: 16.0 / 9.0).map { $0.width == 15360 && $0.height == 8640 } ?? false)
    check("an ultra-wide window at 16K is capped, not rejected", RenderResolution.k16.drawableSize(aspect: 5)?.width == 16384)
    check("native has no fixed size", RenderResolution.native.drawableSize(aspect: 1.5) == nil)
}

print(failures == 0 ? "PASS: UI engine checks" : "FAIL: \(failures) UI engine check(s)")
exit(failures == 0 ? 0 : 1)
