import AppKit
import GBACore
import SwiftUI

/// Settings > Controls: click a binding, press the new key or controller button.
struct ControlsSection: View {
    @EnvironmentObject private var input: InputSettings
    @ObservedObject var gamepad: GamepadInput
    @State private var recording: Recording?
    @State private var monitor: Any?

    private enum Recording: Equatable { case key(InputAction), pad(InputAction) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Action").eyebrow(); Spacer()
                Text("Keyboard").eyebrow().frame(width: 150, alignment: .leading)
                Text("Controller").eyebrow().frame(width: 150, alignment: .leading)
            }
            .padding(.vertical, 12)
            ForEach(InputAction.allCases, id: \.self) { action in
                HStack(spacing: 12) {
                    Text(action.title).font(Ed.body(16)).foregroundStyle(.white)
                    Spacer()
                    chip(recording == .key(action) ? "Press a key…" : keyNames(action), active: recording == .key(action),
                         empty: (input.bindings.keyboard[action] ?? []).isEmpty) { begin(.key(action)) } clear: { input.bindings.clearKeys(for: action) }
                    chip(recording == .pad(action) ? "Press a button…" : padNames(action), active: recording == .pad(action),
                         empty: (input.bindings.pad[action] ?? []).isEmpty) { begin(.pad(action)) } clear: { input.bindings.clearButtons(for: action) }
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { Rectangle().fill(Ed.hairline).frame(height: 1) }
            }
            HStack(spacing: 16) {
                Text(gamepad.controllerNames.isEmpty ? "No controller connected" : gamepad.controllerNames.joined(separator: ", "))
                    .font(Ed.body(13)).foregroundStyle(Ed.dim)
                Spacer()
                Button("Restore defaults") { stopRecording(); input.resetToDefaults() }.buttonStyle(GhostPillStyle(compact: true))
            }
            .padding(.top, 18)
        }
        .onDisappear { stopRecording() }
    }

    private func keyNames(_ a: InputAction) -> String {
        let keys = input.bindings.keyboard[a] ?? []
        return keys.isEmpty ? "—" : keys.map(KeyNames.name).joined(separator: " · ")
    }

    private func padNames(_ a: InputAction) -> String {
        let buttons = input.bindings.pad[a] ?? []
        return buttons.isEmpty ? "—" : buttons.map(\.title).joined(separator: " · ")
    }

    private func chip(_ text: String, active: Bool, empty: Bool, action: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(action: action) {
                Text(text).font(Ed.body(13)).foregroundStyle(active ? Color.black : (empty ? Ed.dim : Color.white)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background { Capsule().fill(active ? Color.white : Color.clear) }
                    .overlay { Capsule().strokeBorder(Color.white.opacity(active ? 0 : 0.3), lineWidth: 1) }
                    .contentShape(Capsule())            // the whole capsule is the click target; an empty binding is only a small "—"
            }
            .buttonStyle(.plain)
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Ed.dim)
                    .frame(width: 18, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).opacity(empty ? 0 : 1).allowsHitTesting(!empty).help("Remove binding")
        }
        .frame(width: 150)
    }

    // MARK: recording

    private func begin(_ target: Recording) {
        stopRecording()
        recording = target
        switch target {
        case .key(let action):
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                let code = event.keyCode
                if event.type == .flagsChanged {
                    // Only a modifier going down counts as a choice.
                    let masks: [UInt16: UInt] = [56: 0x2, 60: 0x4, 55: 0x8, 54: 0x10, 58: 0x20, 61: 0x40, 59: 0x1, 62: 0x2000]
                    guard let mask = masks[code], event.modifierFlags.rawValue & mask != 0 else { return event }
                }
                if code != 53 {                        // Esc cancels
                    input.bindings.clearKeys(for: action)
                    input.bindings.bind(key: code, to: action)
                }
                stopRecording()
                return nil
            }
        case .pad(let action):
            gamepad.capture = { button in
                input.bindings.clearButtons(for: action)
                input.bindings.bind(button: button, to: action)
                recording = nil
            }
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        gamepad.capture = nil
        recording = nil
    }
}
