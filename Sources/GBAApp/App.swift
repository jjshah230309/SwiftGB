import GBACore
import GBARender
import GBAUI
import SwiftUI

@main
struct SwiftGBApp: App {
    private let settings: AppSettings
    @State private var model: EmulatorModel

    init() {
        let s = AppSettings()
        settings = s
        _model = State(initialValue: EmulatorModel(settings: s))
        NSApplication.shared.setActivationPolicy(.regular)
        warmUpRenderer()
    }

    var body: some Scene {
        WindowGroup("SwiftGB") {
            AppRoot()
                .environment(model)
                .environmentObject(settings)
                .onOpenURL { model.open(url: $0) }
                .onAppear { SelfSnapshot.installIfRequested(model: model); SelfSnapshot.dumpMenuIfRequested(); SelfSnapshot.renderTestIfRequested(); SelfSnapshot.windowTestIfRequested(model: model) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model, settings: settings) }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(model.inputSettings)
                .environment(model)
                .frame(minWidth: 540, idealWidth: 680, minHeight: 420, idealHeight: 640)
                .background(ResizableWindow(autosaveName: "SwiftGBSettings"))
        }
        .windowResizability(.contentMinSize)
    }
}

struct AppCommands: Commands {
    let model: EmulatorModel
    @ObservedObject var settings: AppSettings

    var body: some Commands {
        // File
        CommandGroup(replacing: .newItem) {
            Button("Open ROM…") { model.openROM() }.keyboardShortcut("o")
        }

        // View
        CommandGroup(after: .toolbar) {
            Button("Enter Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [.command, .control])
            Divider()
            Button("Increase Window Size") { model.zoomWindow(by: 1) }.keyboardShortcut("=").disabled(!model.isPlaying)
            Button("Decrease Window Size") { model.zoomWindow(by: -1) }.keyboardShortcut("-").disabled(!model.isPlaying)
            Button("Default Window Size") { model.zoomWindow(by: nil) }.keyboardShortcut("0").disabled(!model.isPlaying)
            Divider()
            Toggle("Integer Scaling", isOn: $settings.integerScaling).keyboardShortcut("i", modifiers: [.command, .option])
            Button("Toggle Scanlines") { settings.scanlines = settings.scanlines > 0 ? 0 : 0.5 }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Next Scaling Filter") {
                let all = ScreenFilter.allCases
                settings.filter = all[(all.firstIndex(of: settings.filter)! + 1) % all.count]
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Divider()
            Menu("Refresh Rate") {
                ForEach(RefreshRate.allCases) { rate in
                    Toggle(rate.label, isOn: Binding(get: { settings.refreshRate == rate }, set: { _ in settings.refreshRate = rate }))
                }
            }
            Button("Next Refresh Rate") { settings.refreshRate = settings.refreshRate.next }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Toggle("Unlimited Refresh Rate", isOn: $settings.unlimitedRefresh).keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
            Toggle("Show Statistics", isOn: $settings.showStatistics).keyboardShortcut("t", modifiers: [.command, .option])
        }

        // Emulation
        CommandMenu("Emulation") {
            Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                .keyboardShortcut("p").disabled(!model.isPlaying)
            Button("Reset") { model.reset() }
                .keyboardShortcut("r").disabled(!model.isPlaying)
            Button("Stop and Return to Library") { model.stop() }
                .keyboardShortcut(".").disabled(!model.isPlaying)
            Divider()
            Menu("Speed") {
                ForEach(Array(EmulationSpeed.ladder.enumerated()), id: \.offset) { i, s in
                    let item = Toggle(EmulationSpeed.label(s), isOn: Binding(get: { model.speed == s }, set: { _ in model.setSpeed(s) }))
                    if i < 9 { item.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control]) } else { item }
                }
                Divider()
                Button("Faster") { model.changeSpeed(faster: true) }.keyboardShortcut("]")
                Button("Slower") { model.changeSpeed(faster: false) }.keyboardShortcut("[")
            }
            .disabled(!model.isPlaying)
            Divider()
            Menu("Save State") {
                ForEach(1...9, id: \.self) { n in
                    Button("Slot \(n)") { model.saveState(slot: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command, .option])
                }
            }
            .disabled(!model.isPlaying)
            Menu("Load State") {
                ForEach(1...9, id: \.self) { n in
                    Button(model.stateDates[n] != nil ? "Slot \(n)" : "Slot \(n) (empty)") { model.loadState(slot: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command])
                        .disabled(model.stateDates[n] == nil)
                }
            }
            .disabled(!model.isPlaying)
            Button("Load Autosave") { model.loadAutosave() }
                .keyboardShortcut("l").disabled(!model.isPlaying || model.autosaveDate == nil)
            Button("Load State from File…") { model.loadStateFile() }.disabled(!model.isPlaying)
            Button("Save State to File…") { model.saveStateFile() }.disabled(!model.isPlaying)
            Divider()
            Button("Import Save File…") { model.importSave() }
                .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(!model.isPlaying)
            Button("Export Save File…") { model.exportSave() }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!model.isPlaying)
            Divider()
            Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!model.isPlaying)
            Button("Take Screenshot") { model.takeScreenshot() }
                .keyboardShortcut("s", modifiers: [.command, .option]).disabled(!model.isPlaying)
            Button("Cheats…") { model.showingCheats = true }
                .keyboardShortcut("k").disabled(!model.isPlaying)
            Button("Link…") { model.showingLink = true }
                .keyboardShortcut("j")
            Button("Disconnect Link") { model.disconnectLink() }
                .keyboardShortcut("j", modifiers: [.command, .option]).disabled(model.link == nil)
            Divider()
            Button("Volume Up") { settings.volume = min(1, settings.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { settings.volume = max(0, settings.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Toggle("Mute", isOn: $settings.muted).keyboardShortcut("m", modifiers: [.command, .control])
        }
    }
}
