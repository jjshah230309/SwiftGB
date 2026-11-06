import AppKit
import Combine
import Foundation
import GBACore
import GBARender
import Network
import Observation

/// Owns the running game: the core thread, the audio output and the state the UI observes.
@MainActor @Observable
public final class EmulatorModel {
    public let library: LibraryStore
    public let mailbox = FrameMailbox()

    public private(set) var activeGame: Game?
    public private(set) var isPaused = false
    public private(set) var speed = 1.0
    public private(set) var pressedKeys: GBAKeys = []
    public private(set) var coreNote: String?
    public var alertMessage: String?
    /// A short confirmation ("Saved to slot 3"), shown over the picture for a moment.
    public private(set) var toast: String?
    public var showingCheats = false
    /// The running console's screen size in pixels (for sizing the window to whole multiples).
    public private(set) var screenSize = CGSize(width: 240, height: 160)
    public private(set) var isRewinding = false
    public private(set) var isFastForwarding = false
    public private(set) var stateDates: [Int: Date] = [:]
    public private(set) var autosaveDate: Date?
    /// Dates of every autosave still kept, newest first.
    public private(set) var autosaveHistory: [Date] = []
    public var showingLink = false
    public private(set) var link: NetworkLink?
    public private(set) var linkStatus = NetworkLink.Status.idle
    public private(set) var linkPlayers = 1
    public private(set) var discoveredHosts = [DiscoveredHost]()
    public private(set) var stats = StatsSnapshot()
    public private(set) var audioBuffered = 0
    public private(set) var isRecording = false
    /// The library (or any menu) installs a handler here to receive controller presses as navigation while no game is running.
    @ObservationIgnored public var onNavigate: ((NavInput) -> Void)?
    public private(set) var cheats: [Cheat] = []
    /// Why a cheat was switched off (parse errors), by cheat id.
    public private(set) var cheatErrors: [UUID: String] = [:]

    @ObservationIgnored private var session: EmulationSession?
    @ObservationIgnored private let audio = AudioOutput()
    @ObservationIgnored private var cancellable: AnyCancellable?
    @ObservationIgnored private var keys: GBAKeys = []
    @ObservationIgnored private var keyboardDown = Set<UInt16>()
    @ObservationIgnored private var padDown = Set<PadButton>()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var storage: GameStorage?
    @ObservationIgnored public let inputSettings: InputSettings
    @ObservationIgnored public let gamepad = GamepadInput()
    @ObservationIgnored private var inputCancellable: AnyCancellable?
    @ObservationIgnored private var settingsCancellables = Set<AnyCancellable>()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var recorder: VideoRecorder?

    public init(library: LibraryStore? = nil, settings: AppSettings, input: InputSettings? = nil) {
        self.settings = settings
        inputSettings = input ?? InputSettings()
        self.library = library ?? LibraryStore()
        audio.volume = settings.muted ? 0 : Float(settings.volume)
        cancellable = Publishers.CombineLatest(settings.$volume, settings.$muted)
            .sink { [weak audio] v, muted in audio?.volume = muted ? 0 : Float(v) }
        inputCancellable = inputSettings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.recomputeInput() } }
        }
        // Settings that change what a running game does take effect immediately.
        settings.$fastForwardSpeed.sink { [weak self] v in self?.session?.setFastForwardSpeed(v) }.store(in: &settingsCancellables)
        settings.$pictureOnGPU.sink { [weak self] on in
            self?.session?.perform { core, _ in
                let ok = core.setPictureOnGPU(on)
                if on && !ok { Task { @MainActor in self?.show("This Mac can't draw the picture on the GPU; using the CPU") } }
            }
        }.store(in: &settingsCancellables)
        settings.$rewindSeconds.sink { [weak self] v in self?.session?.setRewindSeconds(v) }.store(in: &settingsCancellables)
        settings.$autosave.sink { [weak self] schedule in self?.session?.setAutosave(interval: schedule.interval) }.store(in: &settingsCancellables)
        gamepad.onChange = { [weak self] buttons in
            guard let self else { return }
            if !self.isPlaying { self.navigate(from: buttons) }          // in the library the controller moves the focus instead
            self.padDown = buttons
            self.recomputeInput()
        }
        settings.$showStatistics.sink { [weak self] on in self?.setStatisticsPolling(on) }.store(in: &settingsCancellables)
        gamepad.start()
        // Quitting mid-game must still write the save.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    public var isPlaying: Bool { activeGame != nil }

    /// Diagnostics (used by tests and, later, a stats overlay).
    public var audioBufferedFrames: Int { audio.bufferedFrames }
    public var audioIsRunning: Bool { audio.isRunning }
    public var emulationFPS: Double { session?.measuredFPS ?? 0 }

    // MARK: lifecycle

    public func play(_ game: Game) {
        guard game.fileExists else {
            alertMessage = "“\(game.title)” can't be found at\n\(game.path)"
            return
        }
        guard let rom = try? Data(contentsOf: game.url) else {
            alertMessage = "Couldn't read “\(game.title)”."
            return
        }
        stop()
        let core = CoreFactory.makeCore(rom: rom, system: game.system)
        if let save = SaveStore.load(for: game) { core.loadSave(save) }
        let s = EmulationSession(core: core, mailbox: mailbox, audio: audio)
        s.onSave = { data in SaveStore.write(data, for: game) }
        let store = GameStorage(game: game)
        s.onAutosave = { [weak self] state, final in
            let model = self
            let write = { _ = store.writeAutosave(state) }
            if final { write() } else {
                DispatchQueue.global(qos: .utility).async { write(); Task { @MainActor in model?.autosaved() } }
            }
        }
        s.setFastForwardSpeed(settings.fastForwardSpeed)
        s.setAutosave(interval: settings.autosave.interval)
        s.setRewindSeconds(settings.rewindSeconds)
        if settings.pictureOnGPU { core.setPictureOnGPU(true) }
        session = s
        storage = store
        cheats = store.loadCheats()
        refreshStateDates()
        autosaveDate = store.autosaveDate
        autosaveHistory = store.autosaveEntries().map(\.date)
        keyboardDown = []; padDown = []; isRewinding = false; isFastForwarding = false
        keys = []
        pressedKeys = []
        isPaused = false
        speed = 1
        coreNote = core.statusNote
        screenSize = CGSize(width: core.screenWidth, height: core.screenHeight)
        activeGame = game
        library.markPlayed(game)
        audio.start()
        s.start()
        applyCheats()
    }

    public func stop() {
        if isRecording { toggleRecording() }
        session?.stop()
        session = nil
        audio.stop()
        activeGame = nil
        coreNote = nil
        keys = []
        pressedKeys = []
        keyboardDown = []; padDown = []
        isRewinding = false; isFastForwarding = false
        stats = StatsSnapshot()
        storage = nil; cheats = []; cheatErrors = [:]
    }

    public func togglePause() {
        isPaused.toggle()
        session?.setPaused(isPaused)
    }

    public func reset() { session?.requestReset() }

    public func setSpeed(_ s: Double) {
        speed = s
        session?.setSpeed(s)
    }

    /// One step up or down the speed ladder (½×, 1×, 2×, 4× … 256×, Unlimited).
    public func changeSpeed(faster: Bool) {
        setSpeed(faster ? EmulationSpeed.faster(than: speed) : EmulationSpeed.slower(than: speed))
        show("Speed \(EmulationSpeed.label(speed))")
    }

    /// Open a ROM file (Finder double-click, drag onto the app, `open -a`): add it to the library and play it.
    public func open(url: URL) {
        library.add(urls: [url])
        if let game = library.games.first(where: { $0.path == url.path }) { play(game) }
    }

    /// File > Open ROM…: add to the library and start the first one.
    public func openROM() {
        let before = Set(library.games.map(\.id))
        library.presentOpenPanel()
        if let first = library.games.first(where: { !before.contains($0.id) }) { play(first) }
    }

    // MARK: input

    /// Returns true if the key was consumed.
    public func handleKey(_ code: UInt16, down: Bool) -> Bool {
        if down, code == 53 {        // Esc: back to the library
            stop()
            return true
        }
        let bound = inputSettings.bindings.keyboard.values.contains { $0.contains(code) }
        guard bound else { return false }
        if down { keyboardDown.insert(code) } else { keyboardDown.remove(code) }
        recomputeInput()
        return true
    }

    /// Merge keyboard and controller into console buttons and the two hold-to-use hotkeys.
    private func recomputeInput() {
        let actions = inputSettings.bindings.actions(keys: keyboardDown, pad: padDown)
        keys = InputBindings.gbaKeys(for: actions)
        pressedKeys = keys
        session?.setKeys(keys)
        let rewind = actions.contains(.rewind) && settings.rewindSeconds > 0, forward = actions.contains(.fastForward)
        if rewind != isRewinding { isRewinding = rewind; session?.setRewinding(rewind) }
        if forward != isFastForwarding { isFastForwarding = forward; session?.setFastForward(forward) }
    }

    // MARK: link cable

    /// A console found on the local network that is hosting a link game.
    public struct DiscoveredHost: Identifiable, @unchecked Sendable {
        public let id: String
        public let name: String
        let endpoint: NWEndpoint
    }

    public func linkKind(for game: Game?) -> NetworkLink.Kind? {
        guard let game else { return nil }
        return game.system.isGameBoy ? .gameBoy : .gba
    }

    /// Which cable a new link should be: the running game's, if there is one.
    public var activeLinkKind: NetworkLink.Kind { linkKind(for: activeGame) ?? .gba }

    public func hostLink(kind: NetworkLink.Kind) {
        disconnectLink()
        adopt(NetworkLink.host(kind: kind))
    }

    public func joinLink(kind: NetworkLink.Kind, address: String) {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var host = text, port = NetworkLink.defaultPort
        if let colon = text.lastIndex(of: ":"), let p = UInt16(text[text.index(after: colon)...]) { host = String(text[..<colon]); port = p }
        disconnectLink()
        adopt(NetworkLink.join(kind: kind, host: host, port: port))
    }

    public func joinLink(kind: NetworkLink.Kind, host: DiscoveredHost) {
        disconnectLink()
        adopt(NetworkLink.join(kind: kind, endpoint: host.endpoint, label: host.name))
    }

    public func disconnectLink() {
        link?.close()
        link = nil
        linkStatus = .idle; linkPlayers = 1
        session?.perform { core, _ in core.attachLink(nil) }
    }

    private func adopt(_ l: NetworkLink) {
        link = l
        linkStatus = l.status; linkPlayers = l.playerCount
        l.onChange = { [weak self, weak l] status, players in
            Task { @MainActor in
                guard let self, let l, self.link === l else { return }
                self.linkStatus = status; self.linkPlayers = players
                if case .failed = status { self.session?.perform { core, _ in core.attachLink(nil) } }
            }
        }
        if let game = activeGame, linkKind(for: game) == l.kind { session?.perform { core, _ in core.attachLink(l) } }
    }

    /// Look for hosts on the local network (Bonjour) while the Link sheet is open.
    public func startBrowsingForLinks() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: NetworkLink.bonjourType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> DiscoveredHost? in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                return DiscoveredHost(id: name, name: name, endpoint: r.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.discoveredHosts = found }
        }
        b.start(queue: .main)
        browser = b
    }

    public func stopBrowsingForLinks() { browser?.cancel(); browser = nil; discoveredHosts = [] }

    // MARK: navigation (library)

    private var lastNavButtons = Set<PadButton>()

    /// Turn newly pressed controller buttons into navigation inputs.
    private func navigate(from buttons: Set<PadButton>) {
        let pressed = buttons.subtracting(lastNavButtons)
        lastNavButtons = buttons
        for b in pressed.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch b {
            case .dpadLeft: onNavigate?(.left)
            case .dpadRight: onNavigate?(.right)
            case .dpadUp: onNavigate?(.up)
            case .dpadDown: onNavigate?(.down)
            case .buttonA, .buttonMenu: onNavigate?(.confirm)
            case .buttonB: onNavigate?(.back)
            default: break
            }
        }
    }

    // MARK: statistics

    private func setStatisticsPolling(_ on: Bool) {
        statsTask?.cancel()
        guard on else { statsTask = nil; return }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let session = self.session {
                    self.stats = session.statsSnapshot()
                    self.audioBuffered = self.audio.bufferedFrames
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: recording

    /// Start recording the game to an MP4 in Movies/SwiftGB, or stop and close the file.
    public func toggleRecording() {
        guard isPlaying, let session else { return }
        if isRecording {
            session.setRecorder(nil)
            let finished = recorder
            recorder = nil; isRecording = false
            finished?.finish { [weak self] ok in
                let url = finished?.url
                Task { @MainActor in self?.show(ok ? "Recording saved to Movies/SwiftGB" : "The recording couldn't be saved"); _ = url }
            }
            return
        }
        guard let game = activeGame else { return }
        let dir = ProcessInfo.processInfo.environment["SWIFTGB_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Movies", isDirectory: true) }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("SwiftGB", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("\(game.title) \(f.string(from: Date())).mp4")
        do {
            let r = try VideoRecorder(url: url, width: Int(screenSize.width), height: Int(screenSize.height), framesPerSecond: session.framesPerSecond)
            recorder = r; isRecording = true
            session.setRecorder(r)
            show("Recording…")
        } catch {
            show("Couldn't start recording")
        }
    }

    // MARK: autosave

    private func autosaved() {
        autosaveDate = storage?.autosaveDate
        autosaveHistory = storage?.autosaveEntries().map(\.date) ?? []
        show("Autosaved")
    }

    /// Go back to the most recent autosave.
    /// `index` 0 is the newest; higher numbers are the older autosaves that are kept.
    public func loadAutosave(index: Int = 0) {
        guard let session, let storage else { return }
        let entries = storage.autosaveEntries()
        guard index < entries.count, let state = entries[index].load() else { show("There's no autosave yet"); return }
        if isPaused { togglePause() }
        session.perform { [weak self] core, _ in
            let model = self
            let ok = core.loadState(state)
            Task { @MainActor in model?.show(ok ? "Loaded the autosave" : "The autosave doesn't fit this game") }
        }
    }

    // MARK: save files

    /// Replace the game's save with a `.sav` from elsewhere (another emulator, a cartridge dumper, a backup) and restart the
    /// game so it reads it. The save that was there is copied to the app's Saves/Backups folder first.
    public func importSave() {
        guard let session, let game = activeGame else { return }
        let panel = NSOpenPanel()
        panel.title = "Import a save file for \(game.title)"
        panel.message = "Choose a .sav (or .srm) file. The game restarts so it can read it."
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSave(from: url)
    }

    private func importSave(from url: URL) {
        guard let session, let game = activeGame else { return }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { show("Couldn't read that file"); return }
        guard data.count <= 0x40_0000 else { show("That file is too big to be a save"); return }
        SaveStore.backupExisting(for: game)
        SaveStore.write(data, for: game)
        session.perform { [weak self] core, _ in
            let model = self
            core.loadSave(data)
            core.reset()
            Task { @MainActor in model?.show("Imported \(url.lastPathComponent)") }
        }
        if isPaused { togglePause() }
    }

    /// Copy the game's current save to a file of the player's choosing.
    public func exportSave() {
        guard let session, let game = activeGame else { return }
        session.perform { [weak self] core, _ in
            let model = self
            if let fresh = core.takeSaveIfChanged() { SaveStore.write(fresh, for: game) }
            Task { @MainActor in
                guard let data = SaveStore.load(for: game) else { model?.show("This game hasn't saved anything yet"); return }
                let panel = NSSavePanel()
                panel.title = "Export the save for \(game.title)"
                panel.nameFieldStringValue = game.url.deletingPathExtension().lastPathComponent + ".sav"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                model?.show((try? data.write(to: url, options: .atomic)) != nil ? "Exported the save" : "Couldn't write the file")
            }
        }
    }

    /// Load a save state from any file (a copy of one saved earlier, or from a backup).
    public func loadStateFile() {
        guard let session, let game = activeGame else { return }
        let panel = NSOpenPanel()
        panel.title = "Load a save state for \(game.title)"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let state = try? Data(contentsOf: url) else { return }
        // A battery save (.sav) is not a state; if that's what was chosen, import it as the save instead of failing.
        let isCompressed = StateCodec.decodeFile(state) != state
        if !isCompressed, [512, 8192, 32768, 65536, 131072].contains(state.count) { importSave(from: url); return }
        if isPaused { togglePause() }
        session.perform { [weak self] core, _ in
            let model = self
            let ok = core.loadState(StateCodec.decodeFile(state))
            Task { @MainActor in model?.show(ok ? "Loaded \(url.lastPathComponent)" : "That isn't a save state for this game") }
        }
    }

    /// Write the machine's current state to a file of the player's choosing.
    public func saveStateFile() {
        guard let session, let game = activeGame else { return }
        session.perform { [weak self] core, _ in
            let model = self
            let state = core.saveState()
            Task { @MainActor in
                guard let state else { model?.show("This core can't save states"); return }
                let panel = NSSavePanel()
                panel.title = "Save a state of \(game.title)"
                panel.nameFieldStringValue = game.url.deletingPathExtension().lastPathComponent + ".sgstate"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                model?.show((try? StateCodec.encodeFile(state).write(to: url, options: .atomic)) != nil ? "Saved the state" : "Couldn't write the file")
            }
        }
    }

    // MARK: window size

    private var gameWindow: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain } }

    /// Resize the window to the next larger or smaller whole multiple of the game's screen; `nil` goes to the default size.
    public func zoomWindow(by step: Int?) {
        guard isPlaying, let window = gameWindow else { return }
        if window.styleMask.contains(.fullScreen) { return }
        let scale = step.map { WindowSizing.currentScale(of: window, game: screenSize) + $0 } ?? WindowSizing.defaultScale
        let applied = WindowSizing.apply(scale: scale, game: screenSize, to: window)
        show("Window size \(applied)×")
    }

    // MARK: toast

    private func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: save states

    private func refreshStateDates() {
        guard let storage else { stateDates = [:]; return }
        var d = [Int: Date]()
        for slot in 1...GameStorage.slotCount { if let date = storage.stateDate(slot: slot) { d[slot] = date } }
        stateDates = d
    }

    public func saveState(slot: Int) {
        guard let session, let storage else { return }
        session.perform { [weak self] core, _ in
            let model = self
            guard let state = core.saveState() else {
                Task { @MainActor in model?.show("This core can't save states") }
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let ok = storage.writeState(state, slot: slot)
                Task { @MainActor in
                    model?.show(ok ? "Saved to slot \(slot)" : "Couldn't write slot \(slot)")
                    model?.refreshStateDates()
                }
            }
        }
    }

    public func loadState(slot: Int) {
        guard let session, let storage else { return }
        guard let state = storage.readState(slot: slot) else { show("Slot \(slot) is empty"); return }
        if isPaused { togglePause() }
        session.perform { [weak self] core, _ in
            let model = self
            let ok = core.loadState(state)
            Task { @MainActor in model?.show(ok ? "Loaded slot \(slot)" : "Slot \(slot) doesn't fit this game") }
        }
    }

    // MARK: screenshots

    public func takeScreenshot() {
        guard let session, let game = activeGame else { return }
        session.perform { [weak self] core, fb in
            let model = self
            let w = core.screenWidth, h = core.screenHeight
            let pixels = Array(UnsafeBufferPointer(start: fb, count: w * h))
            DispatchQueue.global(qos: .utility).async {
                let url = GameStorage.screenshotURL(for: game)
                var ok = false
                if let png = FrameImage.png(pixels: pixels, width: w, height: h, scale: 4) { ok = (try? png.write(to: url)) != nil }
                Task { @MainActor in model?.show(ok ? "Screenshot saved to Pictures/SwiftGB" : "Couldn't save the screenshot") }
            }
        }
    }

    // MARK: cheats

    /// What a code looks like for the running game's console.
    public var cheatFormatHint: String {
        activeGame?.system.isGameBoy == true
            ? "One code per line, GameShark style: 01VVLLHH writes byte VV to address HHLL (cartridge RAM, work RAM or high RAM)."
            : "One code per line, two groups of eight digits. GameShark Advance, Action Replay v1-v3 (plain or encrypted) and CodeBreaker (8 + 4 digits) all work; the format is detected unless you choose one."
    }

    public func addCheat(name: String, code: String, format: CheatFormat = .auto) {
        cheats.append(Cheat(name: name.isEmpty ? "Cheat \(cheats.count + 1)" : name, code: code, format: format))
        cheatsChanged()
    }

    public func setCheat(_ id: UUID, enabled: Bool) {
        guard let i = cheats.firstIndex(where: { $0.id == id }) else { return }
        cheats[i].enabled = enabled
        cheatsChanged()
    }

    public func removeCheat(_ id: UUID) {
        cheats.removeAll { $0.id == id }
        cheatsChanged()
    }

    /// Check a code without adding it, for live feedback in the editor.
    public func validate(code: String, format: CheatFormat = .auto) -> String? {
        if activeGame?.system.isGameBoy ?? false {
            if case .failure(let e) = CheatParser.parse(code, gameBoy: true) { return e.description }
            return nil
        }
        if case .failure(let e) = CheatCompiler.compile(code, format: format) { return e.description }
        return nil
    }

    /// What the text was recognised as, plus anything that was understood but can't do anything here.
    public func recognition(of code: String, format: CheatFormat = .auto) -> String? {
        guard activeGame?.system.isGameBoy != true, case .success(let p) = CheatCompiler.compile(code, format: format), !p.isEmpty else { return nil }
        return ([format == .auto ? "Recognised as \(p.format.shortTitle)." : nil].compactMap { $0 } + p.notes).joined(separator: "\n")
    }

    private func cheatsChanged() {
        storage?.saveCheats(cheats)
        applyCheats()
    }

    private func applyCheats() {
        var writes = [CheatWrite]()
        var programs = [CheatProgram]()
        var errors = [UUID: String]()
        let gameBoy = activeGame?.system.isGameBoy ?? false
        for cheat in cheats where cheat.enabled {
            if gameBoy {
                switch CheatParser.parse(cheat.code, gameBoy: true) {
                case .success(let w): writes += w
                case .failure(let e): errors[cheat.id] = e.description
                }
            } else {
                switch CheatCompiler.compile(cheat.code, format: cheat.format) {
                case .success(let p): programs.append(p)
                case .failure(let e): errors[cheat.id] = e.description
                }
            }
        }
        cheatErrors = errors
        let active = writes, program = CheatProgram.join(programs)
        session?.perform { core, _ in
            if gameBoy { core.setCheats(active) } else { core.setCheatProgram(program) }
        }
    }
}
