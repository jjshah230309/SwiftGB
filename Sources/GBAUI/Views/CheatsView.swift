import GBACore
import SwiftUI

/// The cheat list for the running game: switch codes on and off, add new ones.
struct CheatsView: View {
    @Environment(EmulatorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var code = ""

    private var problem: String? { code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model.validate(code: code) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.activeGame?.title ?? "").eyebrow()
                    Text("Cheats").font(Ed.display(34, whisper: true)).foregroundStyle(.white)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(GhostPillStyle(compact: true))
            }
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(Ed.hairline).frame(height: 1)
                    if model.cheats.isEmpty {
                        Text("No cheats yet. Add a code below.").font(Ed.body(14)).foregroundStyle(Ed.dim).padding(.vertical, 18)
                    }
                    ForEach(model.cheats) { cheat in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 14) {
                                PillToggle(isOn: Binding(get: { cheat.enabled }, set: { model.setCheat(cheat.id, enabled: $0) }))
                                Text(cheat.name).font(Ed.body(16)).foregroundStyle(.white).lineLimit(1)
                                Spacer()
                                Button { model.removeCheat(cheat.id) } label: { Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Ed.dim) }
                                    .buttonStyle(.plain).help("Delete")
                            }
                            Text(cheat.code.split(whereSeparator: \.isNewline).joined(separator: "  ·  "))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ed.dim).lineLimit(2)
                            if let why = model.cheatErrors[cheat.id] { Text(why).font(Ed.body(12)).foregroundStyle(.white.opacity(0.8)) }
                        }
                        .padding(.vertical, 14)
                        .overlay(alignment: .bottom) { Rectangle().fill(Ed.hairline).frame(height: 1) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Add a cheat").eyebrow().padding(.top, 20)
                TextField("Name", text: $name).textFieldStyle(.plain).font(Ed.body(15))
                    .padding(10).overlay(RoundedRectangle(cornerRadius: 0).strokeBorder(Ed.hairline))
                TextEditor(text: $code).font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
                    .frame(height: 78).padding(6).overlay(RoundedRectangle(cornerRadius: 0).strokeBorder(Ed.hairline))
                    .overlay(alignment: .topLeading) {
                        if code.isEmpty { Text(model.activeGame?.system.isGameBoy == true ? "01FFD8C0" : "03007E00 000000FF").font(.system(size: 13, design: .monospaced)).foregroundStyle(Ed.dim).padding(11).allowsHitTesting(false) }
                    }
                Text(problem ?? model.cheatFormatHint)
                    .font(Ed.body(12)).foregroundStyle(problem == nil ? Ed.dim : Color.white)
                HStack {
                    Spacer()
                    Button("Add") { model.addCheat(name: name, code: code); name = ""; code = "" }
                        .buttonStyle(GhostPillStyle(compact: true))
                        .disabled(problem != nil || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 460, idealWidth: 560, maxWidth: .infinity, minHeight: 460, idealHeight: 640, maxHeight: .infinity)
        .background(Color.black)
        .background(ResizableWindow())
        .preferredColorScheme(.dark)
    }
}
