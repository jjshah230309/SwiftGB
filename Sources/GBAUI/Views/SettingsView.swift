import AppKit
import GBACore
import GBARender
import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(EmulatorModel.self) private var model
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                EditorialHero(eyebrow: "Preferences", title: "Settings", height: 340, seed: 0.58, intensity: 0.8)

                VStack(alignment: .leading, spacing: 56) {
                    section("Video") {
                        row("Scaling filter", "How the 240×160 screen is enlarged") {
                            TextChoice(options: ScreenFilter.allCases.map { ($0, $0.shortLabel) }, selection: $settings.filter)
                        }
                        row("Integer scaling", "Only whole multiples. Black borders, sharpest picture") {
                            PillToggle(isOn: $settings.integerScaling)
                        }
                        row("Scanlines", "Subtle LCD-style row shading") {
                            HairlineSlider(value: $settings.scanlines)
                        }
                        row("Resolution", "How many pixels the picture is drawn with. Native follows the window; the others fix the drawing height, from 144p up to 16K (or any height you type under Custom), and the system scales it to the window. Lower is lighter on the GPU and gives a chunkier picture") {
                            HStack(spacing: 10) {
                                if settings.resolution == .custom {
                                    NumberField(value: $settings.customHeight, range: 1...RenderResolution.maximumDimension, suffix: "p")
                                }
                                MenuChoice(options: RenderResolution.allCases.map { ($0, $0.label) }, selection: $settings.resolution)
                            }
                        }
                        row("Refresh rate", settings.unlimitedRefresh ? "Ignored while Unlimited is on" : "How often the picture is drawn, from 1 a second up to \(RefreshRate.ceiling) (or type your own under Custom). The game keeps its normal speed. \(DisplayInfo.summary)") {
                            HStack(spacing: 10) {
                                if settings.refreshRate == .custom {
                                    NumberField(value: $settings.customRefresh, range: RefreshRate.floor...RefreshRate.ceiling, suffix: "Hz")
                                }
                                MenuChoice(options: RefreshRate.allCases.map { ($0, $0.label) }, selection: $settings.refreshRate)
                            }
                            .opacity(settings.unlimitedRefresh ? 0.35 : 1)
                            .allowsHitTesting(!settings.unlimitedRefresh)
                        }
                        row("Draw picture on the GPU", "Experimental. The GPU draws the Game Boy Advance picture instead of the CPU, which takes about a quarter off the CPU load (cooler and quieter). The picture appears one frame (about 17 ms) later, and a game that changes colours, tiles or sprites in the middle of a frame shows those changes from the next frame, which a few games use for effects. Game Boy and Game Boy Color games are not affected") {
                            PillToggle(isOn: $settings.pictureOnGPU)
                        }
                        row("Unlimited", "Show frames as fast as the GPU can, with no vertical sync (tearing is possible). This is only how often the picture is drawn; it is not fast-forward and the game still runs at normal speed") {
                            PillToggle(isOn: $settings.unlimitedRefresh)
                        }
                    }
                    section("Audio") {
                        row("Volume", nil) { HairlineSlider(value: $settings.volume) }
                    }
                    section("Playback") {
                        row("Fast-forward speed", "How fast the game runs while the fast-forward key is held. Doubles at each step, up to as fast as this Mac can go") {
                            MenuChoice(options: EmulationSpeed.fastForwardChoices.map { ($0, EmulationSpeed.label($0)) }, selection: $settings.fastForwardSpeed)
                        }
                        row("Rewind", "How much play you can step back through while the rewind key is held. Off uses no memory for it and saves a little CPU; longer histories use more memory") {
                            MenuChoice(options: [0, 3, 6, 12, 30, 60, 120].map { ($0, $0 == 0 ? "Off" : "\($0) s") }, selection: $settings.rewindSeconds)
                        }
                        row("Autosave", "Saves the game's state in the background, and once more when you leave. Load it from the States menu or Emulation ▸ Load Autosave") {
                            PillToggle(isOn: $settings.autosave.enabled)
                        }
                        row("Autosave every", settings.autosave.enabled ? "Currently \(settings.autosave.summary)" : "Autosave is off") {
                            HStack(spacing: 10) {
                                TextField("", value: Binding(get: { settings.autosave.value }, set: { settings.autosave.value = min(max($0, 1), 999) }), format: .number)
                                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Ed.body(15)).foregroundStyle(.white)
                                    .frame(width: 56).padding(.vertical, 5).padding(.horizontal, 8)
                                    .overlay { Capsule().strokeBorder(Ed.hairline) }
                                MenuChoice(options: AutosaveSchedule.Unit.allCases.map { ($0, $0.label) }, selection: $settings.autosave.unit)
                            }
                            .opacity(settings.autosave.enabled ? 1 : 0.35)
                            .allowsHitTesting(settings.autosave.enabled)
                        }
                    }
                    section("Controls") {
                        ControlsSection(gamepad: model.gamepad)
                    }
                    section("About") {
                        row("Emulation core", CoreFactory.limitations) {
                            Tag(text: CoreFactory.isPlaceholder ? "Placeholder" : "Active")
                        }
                    }
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)                          // centred once the window is wider than the column
                .padding(.horizontal, 40).padding(.top, 10).padding(.bottom, 90)
            }
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectHidden(true, for: .top)
        .background(HideScrollBackdrop())
        .ignoresSafeArea(edges: .top)
        .background(Color.black)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).eyebrow().padding(.bottom, 14)
            Rectangle().fill(Ed.hairline).frame(height: 1)
            content()
        }
    }

    /// Title and detail on the left, the control on the right; when the window is too narrow for both the control drops underneath.
    private func row<Control: View>(_ title: String, _ detail: String?, @ViewBuilder control: () -> Control) -> some View {
        let label = VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Ed.body(18)).foregroundStyle(.white)
            if let detail { Text(detail).font(Ed.body(13)).foregroundStyle(Ed.dim).fixedSize(horizontal: false, vertical: true) }
        }
        let ctl = control().fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                label.frame(maxWidth: .infinity, alignment: .leading)
                ctl
            }
            VStack(alignment: .leading, spacing: 12) { label; ctl }
        }
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(Ed.hairline).frame(height: 1) }
    }
}

/// A small typed-in number, clamped to a range, for the "Custom…" choices.
private struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String
    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }), format: .number.grouping(.never))
                .textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Ed.body(15)).foregroundStyle(.white)
                .frame(width: 64).padding(.vertical, 5).padding(.horizontal, 8)
                .overlay { Capsule().strokeBorder(Ed.hairline) }
            Text(suffix).font(Ed.body(13)).foregroundStyle(Ed.dim)
        }
    }
}

private extension ScreenFilter {
    var shortLabel: String {
        switch self { case .sharp: return "Sharp"; case .nearest: return "Pixel"; case .smooth: return "Smooth" }
    }
}

/// What the screen the app is on can do, in a form for the settings page.
enum DisplayInfo {
    static var summary: String {
        guard let screen = NSScreen.main else { return "Presentation rate. Up to 240 Hz" }
        let scale = screen.backingScaleFactor
        let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
        return "This display: \(w)×\(h) at \(screen.maximumFramesPerSecond) Hz. Drawn natively at any size up to 16K, any rate up to 240 Hz"
    }
}
