import GBACore
import GBARender
import SwiftUI

struct EmulationView: View {
    @Environment(EmulatorModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var hudVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var lastPointer = CGPoint(x: -100, y: -100)

    var body: some View {
        ZStack {
            ScreenView(mailbox: model.mailbox, settings: settings.renderSettings) { code, down in
                MainActor.assumeIsolated { model.handleKey(code, down: down) }
            }
            .ignoresSafeArea()

            if hudVisible { hud.transition(.opacity) }
            statusOverlay
        }
        .sheet(isPresented: Bindable(model).showingCheats) { CheatsView().environment(model) }
        .background(Color.black)
        .onContinuousHover { phase in
            // Only a real pointer move reveals the HUD (showing/hiding it re-fires hover under a parked cursor).
            if case .active(let p) = phase, abs(p.x - lastPointer.x) + abs(p.y - lastPointer.y) > 4 {
                lastPointer = p
                reveal()
            }
        }
        .onAppear { reveal() }
        .onChange(of: model.isPaused) { _, paused in if paused { reveal() } }
    }

    private func reveal() {
        withAnimation(Ed.easeFast) { hudVisible = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !model.isPaused else { return }
            withAnimation(Ed.ease) { hudVisible = false }
        }
    }

    private var hud: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).frame(height: 150)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom).frame(height: 130)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.isPaused ? "Paused" : "Now playing").eyebrow(.white.opacity(0.7))
                        Text(model.activeGame?.title ?? "").font(Ed.display(34, whisper: true)).tracking(-0.6)
                            .foregroundStyle(.white).lineLimit(1)
                    }
                    .padding(.leading, 78)       // clear of the window controls
                    Spacer()
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                            Button("Reset") { model.reset() }
                            Menu {
                                ForEach(EmulationSpeed.ladder, id: \.self) { s in
                                    Button { model.setSpeed(s) } label: {
                                        if model.speed == s { Label(speedLabel(s), systemImage: "checkmark") } else { Text(speedLabel(s)) }
                                    }
                                }
                            } label: { GhostPillChrome(glass: true, compact: true) { Text(speedLabel(model.speed)) } }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                            statesMenu
                            toolsMenu
                            Button("Library") { model.stop() }
                        }
                        .buttonStyle(GhostPillStyle(glass: true, compact: true))
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if let note = model.coreNote {
                        Text(note).eyebrow(.white.opacity(0.6)).frame(maxWidth: 420, alignment: .leading)
                    }
                    Spacer()
                    KeyEcho(pressed: model.pressedKeys)
                }
            }
            .padding(.top, 20).padding(.horizontal, 28).padding(.bottom, 24)
        }
    }

    private var statesMenu: some View {
        Menu {
            Section("Save") {
                ForEach(1...GameStorage.slotCount, id: \.self) { n in Button("Slot \(n)") { model.saveState(slot: n) } }
            }
            Section("Autosave") {
                Button(model.autosaveDate.map { "Load autosave — \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Load autosave — none yet") { model.loadAutosave() }
                    .disabled(model.autosaveDate == nil)
            }
            Section("Load") {
                ForEach(1...GameStorage.slotCount, id: \.self) { n in
                    Button(model.stateDates[n].map { "Slot \(n) — \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Slot \(n) — empty") { model.loadState(slot: n) }
                        .disabled(model.stateDates[n] == nil)
                }
            }
        } label: { GhostPillChrome(glass: true, compact: true) { Text("States") } }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var toolsMenu: some View {
        Menu {
            Button("Screenshot") { model.takeScreenshot() }
            Button("Cheats…") { model.showingCheats = true }
            Button(model.link == nil ? "Link…" : "Link — \(model.linkPlayers) console\(model.linkPlayers == 1 ? "" : "s")…") { model.showingLink = true }
        } label: { GhostPillChrome(glass: true, compact: true) { Text("Tools") } }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    /// Rewind / fast-forward indicator and the short confirmation messages; visible even when the HUD has faded.
    private var statusOverlay: some View {
        VStack {
            if model.isRecording {
                Text("● REC").eyebrow(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background { Capsule().fill(Color.black.opacity(0.55)) }
                    .overlay { Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1) }
                    .padding(.top, model.isRewinding || model.isFastForwarding ? 8 : 22)
                    .transition(.opacity)
            }
            if model.isRewinding || model.isFastForwarding {
                Text(model.isRewinding ? "◀◀  Rewinding" : (model.speed.isInfinite || settings.fastForwardSpeed.isInfinite ? "▶▶  Fast-forward · Unlimited" : "▶▶  Fast-forward · \(EmulationSpeed.label(max(model.speed, settings.fastForwardSpeed)))")).eyebrow(.white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background { Capsule().fill(Color.black.opacity(0.55)) }
                    .overlay { Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1) }
                    .padding(.top, 22)
                    .transition(.opacity)
            }
            Spacer()
            if settings.showStatistics { statisticsBlock }
            if let toast = model.toast {
                Text(toast).font(Ed.body(14)).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background { Capsule().fill(Color.black.opacity(0.6)) }
                    .overlay { Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1) }
                    .padding(.bottom, 70)
                    .transition(.opacity)
            }
        }
        .animation(Ed.easeFast, value: model.toast)
        .animation(Ed.easeFast, value: model.isRewinding)
        .animation(Ed.easeFast, value: model.isFastForwarding)
        .allowsHitTesting(false)
    }

    /// Frame cost, headroom and sound buffer: what to look at to see whether this Mac is keeping up.
    private var statisticsBlock: some View {
        let s = model.stats
        return VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "%.1f fps   ·   %.2f ms avg   ·   %.2f ms p99   ·   %.2f ms worst", s.framesPerSecond, s.averageMs, s.p99Ms, s.worstMs))
            Text(String(format: "%.1f× headroom   ·   %d slow frame%@ in the last 2 s   ·   sound buffer %d samples", s.headroom, s.overruns, s.overruns == 1 ? "" : "s", model.audioBuffered))
        }
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background { Rectangle().fill(Color.black.opacity(0.55)) }
        .overlay { Rectangle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1) }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 28).padding(.bottom, 8)
    }

    private func speedLabel(_ s: Double) -> String { EmulationSpeed.label(s) }
}

/// Pad buttons as quiet typography; each lights up white while held, which makes input visibly verifiable.
private struct KeyEcho: View {
    let pressed: GBAKeys
    private let keys: [(String, GBAKeys)] = [("L", .l), ("R", .r), ("Select", .select), ("Start", .start),
                                             ("←", .left), ("↑", .up), ("↓", .down), ("→", .right), ("B", .b), ("A", .a)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(keys, id: \.0) { name, key in
                Text(name).font(Ed.label(11)).textCase(.uppercase).tracking(1.2)
                    .foregroundStyle(pressed.contains(key) ? Color.white : Color.white.opacity(0.32))
                    .animation(Ed.easeFast, value: pressed.contains(key))
            }
        }
    }
}
