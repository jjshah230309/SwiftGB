import Foundation
import GBACore
import GBARender
import os

/// Runs one core on a dedicated, high-priority thread, paced to the core's native frame rate.
/// Everything that touches the core (states, screenshots, cheats) is a job executed on that thread between frames.
public final class EmulationSession: @unchecked Sendable {
    public typealias Job = @Sendable (EmulatorCore, UnsafePointer<UInt32>) -> Void

    private let core: EmulatorCore
    private let mailbox: FrameMailbox
    private let audio: AudioOutput
    private let lock = NSLock()
    private var keys: GBAKeys = []
    private var paused = false
    private var speed = 1.0
    private var fastForward = false
    private var fastForwardSpeed = EmulationSpeed.defaultFastForward
    private var autosaveInterval: TimeInterval?
    private var rewinding = false
    private var rewindSeconds = 12
    private var rewindDirty = true
    private var quit = false
    private var resetRequested = false
    private var jobs = [Job]()
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    private let rewindBuffer = RewindBuffer()
    public private(set) var measuredFPS = 0.0
    /// Seconds a session must have run before leaving it writes an autosave.
    public nonisolated(unsafe) static var minimumSessionForExitAutosave: TimeInterval = 30
    private var stats = FrameStats()
    private var recorder: VideoRecorder?
    /// Instruments shows these intervals (subsystem dev.swiftgb) when profiling: the cost of each frame and of sound hand-off.
    private static let signposter = OSSignposter(subsystem: "dev.swiftgb", category: "emulation")
    /// Called on the emulation thread whenever the cartridge's save data has changed (at most about once a second, and once more on exit).
    public var onSave: (@Sendable (Data) -> Void)?

    /// Called on the emulation thread with a save state, every autosave interval and once more as the session ends
    /// (`final` is true then, and the callback should finish its work before returning).
    public var onAutosave: (@Sendable (Data, _ final: Bool) -> Void)?

    public init(core: EmulatorCore, mailbox: FrameMailbox, audio: AudioOutput) {
        self.core = core
        self.mailbox = mailbox
        self.audio = audio
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "SwiftGB.emulation"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Ask the thread to finish and wait for it, so the final save has been handed over before this returns.
    public func stop() {
        lock.lock(); quit = true; lock.unlock()
        if thread != nil { _ = finished.wait(timeout: .now() + 1) }
    }

    public func setKeys(_ k: GBAKeys) { lock.lock(); keys = k; lock.unlock() }
    public func setPaused(_ p: Bool) { lock.lock(); paused = p; lock.unlock() }
    public func setSpeed(_ s: Double) { lock.lock(); speed = s.isInfinite ? s : max(0.1, s); lock.unlock() }
    /// `.infinity` = unlimited.
    public func setFastForwardSpeed(_ s: Double) { lock.lock(); fastForwardSpeed = s; lock.unlock() }
    /// nil turns autosave off (including the save on exit).
    public func setAutosave(interval: TimeInterval?) { lock.lock(); autosaveInterval = interval; lock.unlock() }
    public var framesPerSecond: Double { core.framesPerSecond }

    /// Start (or with nil, stop) feeding every emulated frame and its sound to a recording.
    public func setRecorder(_ r: VideoRecorder?) { lock.lock(); recorder = r; lock.unlock() }

    /// Recent frame-time statistics, for the on-screen display.
    public func statsSnapshot() -> StatsSnapshot {
        lock.lock(); defer { lock.unlock() }
        var snap = StatsSnapshot()
        snap.framesPerSecond = measuredFPS
        snap.averageMs = stats.average; snap.p99Ms = stats.p99; snap.worstMs = stats.worst
        snap.headroom = stats.headroom(framesPerSecond: core.framesPerSecond)
        snap.overruns = stats.overruns(framesPerSecond: core.framesPerSecond)
        return snap
    }

    public func setFastForward(_ on: Bool) { lock.lock(); fastForward = on; lock.unlock() }
    /// How much history rewind keeps, in seconds; 0 switches it off and frees its memory.
    public func setRewindSeconds(_ s: Int) { lock.lock(); rewindSeconds = max(0, s); rewindDirty = true; lock.unlock() }
    public func setRewinding(_ on: Bool) { lock.lock(); rewinding = on; lock.unlock() }
    public func requestReset() { lock.lock(); resetRequested = true; lock.unlock() }

    /// Run `work` on the emulation thread before the next frame (also while paused). It receives the core and the latest picture.
    public func perform(_ work: @escaping Job) { lock.lock(); jobs.append(work); lock.unlock() }

    private func run() {
        defer { finished.signal() }
        let startedAt = Date()
        let w = core.screenWidth, h = core.screenHeight
        let fb = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
        fb.initialize(repeating: 0xFF00_0000, count: w * h)
        let audioScratch = UnsafeMutablePointer<Int16>.allocate(capacity: 4096 * 2)
        defer { fb.deallocate(); audioScratch.deallocate() }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func nanosToTicks(_ ns: Double) -> UInt64 { UInt64(ns * Double(timebase.denom) / Double(timebase.numer)) }

        var nextDeadline = mach_absolute_time()
        var fpsWindowStart = mach_absolute_time()
        var fpsFrames = 0
        var frameCounter = 0
        var lastSaveCheck = mach_absolute_time()
        var lastAutosave = mach_absolute_time()

        while true {
            lock.lock()
            let q = quit, p = paused, k = keys, s = speed, ff = fastForward, ffSpeed = fastForwardSpeed, rewRequested = rewinding, doReset = resetRequested, autosave = autosaveInterval, newRewind = rewindDirty ? rewindSeconds : nil
            let pending = jobs
            jobs.removeAll()
            resetRequested = false
            rewindDirty = false
            lock.unlock()
            if let newRewind { rewindBuffer.configure(seconds: newRewind) }
            let rew = rewRequested && rewindBuffer.isEnabled          // with rewind off the key does nothing
            if q { break }
            if doReset { core.reset(); rewindBuffer.clear() }
            for job in pending { job(core, UnsafePointer(fb)) }

            if p {
                Thread.sleep(forTimeInterval: 0.016)
                nextDeadline = mach_absolute_time()
                continue
            }

            core.setKeys(k)
            var effectiveSpeed = ff ? max(s, ffSpeed) : s
            if rew {
                // Step back one snapshot (about five frames), show a frame from there, stay silent.
                if rewindBuffer.rewind(core) {
                    core.runFrame(framebuffer: fb)
                    mailbox.publish(fb, width: w, height: h)
                }
                _ = core.readAudio(into: audioScratch, maxFrames: 4096)
                effectiveSpeed = 1
            } else {
                rewindBuffer.record(core)
                let frameStart = mach_absolute_time()
                let frameSignpost = EmulationSession.signposter.beginInterval("frame")
                core.runFrame(framebuffer: fb)
                EmulationSession.signposter.endInterval("frame", frameSignpost)
                let work = Double(mach_absolute_time() - frameStart) * Double(timebase.numer) / Double(timebase.denom) / 1e6
                // Far above real time most frames are never shown, so don't copy every one to the screen.
                frameCounter &+= 1
                if effectiveSpeed <= 4 || frameCounter % 4 == 0 { mailbox.publish(fb, width: w, height: h) }
                let n = core.readAudio(into: audioScratch, maxFrames: 4096)
                if effectiveSpeed <= 1.01 { audio.push(audioScratch, frames: n) }     // no audio while fast-forwarding
                lock.lock()
                stats.record(milliseconds: work)
                let rec = recorder
                lock.unlock()
                rec?.append(frame: UnsafePointer(fb), audio: audioScratch, audioFrames: n)     // recordings keep their sound at any speed
            }

            fpsFrames += 1
            let now = mach_absolute_time()
            if let autosave, !rew, now - lastAutosave >= nanosToTicks(autosave * 1e9) {
                lastAutosave = now
                if let state = core.saveState() { onAutosave?(state, false) }
            }
            if now - lastSaveCheck > nanosToTicks(1e9) {
                lastSaveCheck = now
                if let data = core.takeSaveIfChanged() { onSave?(data) }
            }
            if now - fpsWindowStart > nanosToTicks(1e9) {
                measuredFPS = Double(fpsFrames)
                fpsFrames = 0
                fpsWindowStart = now
            }

            guard let interval = EmulationSpeed.frameInterval(framesPerSecond: core.framesPerSecond, speed: effectiveSpeed) else {
                nextDeadline = mach_absolute_time()               // unlimited: no pacing, run flat out
                continue
            }
            nextDeadline += nanosToTicks(interval * 1e9)
            let after = mach_absolute_time()
            if nextDeadline > after {
                mach_wait_until(nextDeadline)
            } else if after - nextDeadline > nanosToTicks(100e6) {
                nextDeadline = after      // fell badly behind: resync instead of sprinting to catch up
            }
        }
        if let data = core.takeSaveIfChanged() { onSave?(data) }
        lock.lock(); let finalAutosave = autosaveInterval != nil; lock.unlock()
        // A session that only just started has nothing worth keeping, and must not push out a good autosave.
        if finalAutosave, Date().timeIntervalSince(startedAt) >= EmulationSession.minimumSessionForExitAutosave, let state = core.saveState() { onAutosave?(state, true) }
    }
}
