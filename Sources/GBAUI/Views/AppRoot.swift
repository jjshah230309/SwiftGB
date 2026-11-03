import AppKit
import SwiftUI

enum AppRoute: String, CaseIterable, Identifiable {
    case library, settings
    var id: String { rawValue }
    var title: String { rawValue }
}

/// Root view: a black gallery with a transparent top bar. No sidebar, no stock chrome.
public struct AppRoot: View {
    @Environment(EmulatorModel.self) private var model
    @State private var route: AppRoute =
        AppRoute(rawValue: ProcessInfo.processInfo.environment["SWIFTGB_SECTION"] ?? "") ?? .library

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea().background(WindowChrome())
            if model.isPlaying {
                EmulationView().transition(.opacity)
            } else {
                Group {
                    switch route {
                    case .library: LibraryView()
                    case .settings: SettingsView()
                    }
                }
                .id(route)
                .transition(.opacity)
                TopBar(route: $route).transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(Ed.ease, value: route)
        .animation(Ed.easeFast, value: model.isPlaying)
        .preferredColorScheme(.dark)
        .tint(.white)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: model.isPlaying ? WindowSizing.minimumGameSize.width : 760, minHeight: model.isPlaying ? WindowSizing.minimumGameSize.height : 520)
        .sheet(isPresented: Bindable(model).showingLink) { LinkView().environment(model) }
        .alert("SwiftGB", isPresented: Binding(get: { model.alertMessage != nil },
                                               set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.alertMessage ?? "") }
    }
}

struct TopBar: View {
    @Binding var route: AppRoute
    @Environment(EmulatorModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Text("swiftgb").font(Ed.body(18)).tracking(-0.2).foregroundStyle(.white)
                .padding(.leading, 96)
            Spacer()
            HStack(spacing: 30) {
                ForEach(AppRoute.allCases) { r in NavLink(title: r.title, active: route == r) { route = r } }
            }
            Button("Add ROMs") { model.library.presentOpenPanel() }
                .buttonStyle(GhostPillStyle(glass: true, compact: true))
                .padding(.leading, 34)
        }
        .padding(.trailing, 34)
        .frame(height: 44)
        .background {
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 96).frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
    }
}

private struct NavLink: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).eyebrow(active || hover ? .white : Ed.gray)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Ed.easeFast, value: hover)
        .animation(Ed.easeFast, value: active)
    }
}
