import GBACore
import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", favorites = "Favorites", recent = "Recent"
    var id: String { rawValue }
}

struct LibraryView: View {
    @Environment(EmulatorModel.self) private var model
    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    /// The game selected by the arrow keys or the controller.
    @State private var focusedID: UUID?
    @State private var gridWidth: Double = 1000
    @FocusState private var gridFocused: Bool

    private var library: LibraryStore { model.library }

    private var visible: [Game] {
        var list = library.games
        switch filter {
        case .all: break
        case .favorites: list = list.filter(\.favorite)
        case .recent:
            list = list.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.gameCode.localizedCaseInsensitiveContains(q) } }
        return list
    }

    private static let minimumCard = 270.0, cardSpacing = 30.0

    private func move(_ input: NavInput) {
        let list = visible
        guard !list.isEmpty else { return }
        if input == .confirm {
            if let id = focusedID, let game = list.first(where: { $0.id == id }) { model.play(game) } else { focusedID = list[0].id }
            return
        }
        guard input != .back else { focusedID = nil; return }
        let columns = GridNavigation.columns(width: gridWidth - 80, minimumItem: Self.minimumCard, spacing: Self.cardSpacing)
        let current = focusedID.flatMap { id in list.firstIndex { $0.id == id } }
        if let i = GridNavigation.next(from: current, direction: input, count: list.count, columns: columns) { focusedID = list[i].id }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                EditorialHero(eyebrow: library.games.isEmpty ? "Game Boy · Color · Advance" : "\(library.games.count) game\(library.games.count == 1 ? "" : "s")",
                              title: "Library") {
                    Button { library.presentOpenPanel() } label: {
                        RotatingBadge(text: "ADD A ROM · DROP A ROM · ")
                    }
                    .buttonStyle(.plain).help("Add .gba, .gb or .gbc ROM files")
                }

                VStack(alignment: .leading, spacing: 34) {
                    if let note = CoreFactory.limitations {
                        Text(note).font(Ed.body(13)).foregroundStyle(Ed.gray)
                    }
                    if let message = library.lastMessage {
                        Text(message).font(Ed.body(13)).foregroundStyle(.white)
                    }
                    if library.games.isEmpty { empty } else { filters; grid }
                }
                .padding(.horizontal, 40).padding(.top, 8).padding(.bottom, 80)
            }
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectHidden(true, for: .top)
        .background(HideScrollBackdrop())
        .ignoresSafeArea(edges: .top)
        .dropDestination(for: URL.self) { urls, _ in library.add(urls: urls); return true }
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { gridWidth = $0 }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(.left); return .handled }
        .onKeyPress(.rightArrow) { move(.right); return .handled }
        .onKeyPress(.upArrow) { move(.up); return .handled }
        .onKeyPress(.downArrow) { move(.down); return .handled }
        .onKeyPress(.return) { move(.confirm); return .handled }
        .onKeyPress(.escape) { focusedID = nil; return .handled }
        .onChange(of: focusedID) { _, id in if let id { withAnimation(Ed.ease) { proxy.scrollTo(id, anchor: .center) } } }
        .onChange(of: filter) { _, _ in focusedID = nil }
        .onAppear {
            gridFocused = true
            model.onNavigate = { move($0) }
        }
        .onDisappear { model.onNavigate = nil }
        }
    }

    private var filters: some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            ForEach(LibraryFilter.allCases) { f in
                Button { withAnimation(Ed.easeFast) { filter = f } } label: {
                    Text(f.rawValue).eyebrow(filter == f ? .white : Ed.dim)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .light)).foregroundStyle(Ed.gray)
                TextField("Search", text: $search).textFieldStyle(.plain).font(Ed.body(13)).frame(width: 150)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Ed.hairline).frame(height: 1) }
        }
        .padding(.top, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Ed.hairline).frame(height: 1).offset(y: 14) }
    }

    @ViewBuilder private var grid: some View {
        if visible.isEmpty {
            Text("Nothing matches.").font(Ed.display(40, whisper: true)).foregroundStyle(Ed.dim).padding(.top, 20)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimumCard, maximum: 440), spacing: Self.cardSpacing, alignment: .top)], spacing: 46) {
                ForEach(visible) { game in
                    GameCard(game: game,
                             onPlay: { model.play(game) },
                             onFavorite: { library.toggleFavorite(game) },
                             onRemove: { library.remove(game) },
                             focused: focusedID == game.id)
                        .id(game.id)
                }
            }
            .padding(.top, 14)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Drop a ROM to begin.").font(Ed.display(56, whisper: true)).tracking(-1.2).foregroundStyle(.white)
            Text("SwiftGB reads each ROM's header to name it. Games stay where they are; the library only remembers where.")
                .font(Ed.body(16)).foregroundStyle(Ed.gray).frame(maxWidth: 520, alignment: .leading)
            Button("Add ROMs") { library.presentOpenPanel() }.buttonStyle(GhostPillStyle())
        }
        .padding(.top, 30)
    }
}
