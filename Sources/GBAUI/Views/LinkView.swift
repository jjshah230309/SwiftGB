import GBACore
import SwiftUI

/// Link cable: host a game for another copy of the app to join, or join one. Works for GBA (up to four) and Game Boy (two).
struct LinkView: View {
    @Environment(EmulatorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind: NetworkLink.Kind = .gba
    @State private var address = ""

    private var status: String {
        switch model.linkStatus {
        case .idle: return "Not linked"
        case .listening(let port): return model.linkPlayers > 1 ? "Linked: \(model.linkPlayers) consoles on the cable" : "Waiting for another console on port \(port)…"
        case .joining(let what): return "Joining \(what)…"
        case .connected: return "Linked: \(model.linkPlayers) consoles on the cable"
        case .failed(let why): return why
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local network").eyebrow()
                    Text("Link").font(Ed.display(34, whisper: true)).foregroundStyle(.white)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(GhostPillStyle(compact: true))
            }
            .padding(.bottom, 18)

            Rectangle().fill(Ed.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(status).font(Ed.body(16)).foregroundStyle(.white)
                if model.link != nil {
                    Text("A link game needs the same kind of game on every console: both Game Boy Advance, or both Game Boy.").font(Ed.body(12)).foregroundStyle(Ed.dim)
                }
            }
            .padding(.vertical, 16)
            Rectangle().fill(Ed.hairline).frame(height: 1)

            if model.activeGame == nil {
                Picker("Console", selection: $kind) {
                    Text("Game Boy Advance").tag(NetworkLink.Kind.gba); Text("Game Boy / Color").tag(NetworkLink.Kind.gameBoy)
                }
                .pickerStyle(.segmented).labelsHidden().padding(.top, 16)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Host").eyebrow()
                        Text("Start a link game for another console to join. Share one of these addresses, or they can pick you from the list on their screen.")
                            .font(Ed.body(13)).foregroundStyle(Ed.dim).fixedSize(horizontal: false, vertical: true)
                        let addresses = LocalAddresses.ipv4()
                        if !addresses.isEmpty {
                            Text(addresses.map { "\($0):\(NetworkLink.defaultPort)" }.joined(separator: "   ")).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                        }
                        Button("Host a link game") { model.hostLink(kind: effectiveKind) }.buttonStyle(GhostPillStyle(compact: true))
                    }
                    Rectangle().fill(Ed.hairline).frame(height: 1)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Join").eyebrow()
                        if model.discoveredHosts.isEmpty {
                            Text("Looking for link games on this network…").font(Ed.body(13)).foregroundStyle(Ed.dim)
                        }
                        ForEach(model.discoveredHosts) { host in
                            Button { model.joinLink(kind: effectiveKind, host: host) } label: {
                                HStack { Text(host.name).font(Ed.body(15)).foregroundStyle(.white); Spacer(); Text("Join").font(Ed.body(13)).foregroundStyle(Ed.gray) }
                                    .padding(.vertical, 8).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottom) { Rectangle().fill(Ed.hairline).frame(height: 1) }
                        }
                        HStack(spacing: 10) {
                            TextField("Address, e.g. 192.168.1.20", text: $address).textFieldStyle(.plain).font(Ed.body(14))
                                .padding(8).overlay(Rectangle().strokeBorder(Ed.hairline))
                                .onSubmit { model.joinLink(kind: effectiveKind, address: address) }
                            Button("Join") { model.joinLink(kind: effectiveKind, address: address) }
                                .buttonStyle(GhostPillStyle(compact: true)).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .padding(.top, 18)
            }

            HStack {
                Spacer()
                Button("Disconnect") { model.disconnectLink() }.buttonStyle(GhostPillStyle(compact: true)).disabled(model.link == nil)
            }
            .padding(.top, 14)
        }
        .padding(28)
        .frame(minWidth: 460, idealWidth: 540, maxWidth: .infinity, minHeight: 480, idealHeight: 600, maxHeight: .infinity)
        .background(Color.black)
        .background(ResizableWindow())
        .preferredColorScheme(.dark)
        .onAppear { kind = model.activeLinkKind; model.startBrowsingForLinks() }
        .onDisappear { model.stopBrowsingForLinks() }
    }

    private var effectiveKind: NetworkLink.Kind { model.activeGame == nil ? kind : model.activeLinkKind }
}
