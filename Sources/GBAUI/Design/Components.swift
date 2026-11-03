import AppKit
import GBARender
import SwiftUI

/// Renders (and caches) each game's generated cover from the iridescent shader, off the main thread.
actor CoverStore {
    static let shared = CoverStore()
    private var cache: [UUID: NSImage] = [:]

    func image(for game: Game) -> NSImage? {
        if let hit = cache[game.id] { return hit }
        guard let cg = CoverImageRenderer.shared.render(seed: Float(game.hue)) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[game.id] = image
        return image
    }
}

/// Full-bleed generated cover with the game's initials ghosted over it. Flat, sharp-cornered, no chrome.
struct CoverArt: View {
    let game: Game
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: 0.06)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                        .transition(.opacity)
                }
                Text(game.initials)
                    .font(Ed.display(geo.size.height * 0.46, whisper: true))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1).minimumScaleFactor(0.3)
            }
        }
        .task(id: game.id) {
            let loaded = await CoverStore.shared.image(for: game)
            withAnimation(Ed.ease) { image = loaded }
        }
    }
}

/// Library entry: image, then plain text below. "The card is content, not a container."
struct GameCard: View {
    let game: Game
    let onPlay: () -> Void
    let onFavorite: () -> Void
    let onRemove: () -> Void
    /// Selected by keyboard or controller navigation.
    var focused = false
    @State private var hovering = false

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .bottomLeading) {
                    CoverArt(game: game).scaleEffect(hovering || focused ? 1.06 : 1.0)
                    if hovering || focused {
                        Text("Play").font(Ed.body(13)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 7)
                            .overlay { Capsule().strokeBorder(Color.white.opacity(0.7), lineWidth: 1) }
                            .padding(16)
                            .transition(.opacity)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipped()
                .overlay { Rectangle().strokeBorder(focused ? Color.white : (hovering ? Color.white.opacity(0.5) : Ed.hairline), lineWidth: focused ? 2 : 1) }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(game.title).font(Ed.body(18)).foregroundStyle(hovering ? .white : .white.opacity(0.88)).lineLimit(1)
                    Spacer(minLength: 8)
                    if game.favorite { Image(systemName: "heart.fill").font(.system(size: 10)).foregroundStyle(.white) }
                    Tag(text: game.system.label)
                }
                Text(meta).eyebrow(Ed.dim).lineLimit(1).padding(.top, -6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Ed.ease, value: hovering)
        .animation(Ed.easeFast, value: focused)
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: onPlay)
            Button(game.favorite ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: game.favorite ? "heart.slash" : "heart", action: onFavorite)
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([game.url]) }
            Divider()
            Button("Remove from Library", systemImage: "trash", role: .destructive, action: onRemove)
        }
    }

    private var meta: String {
        var parts = [game.gameCode.isEmpty ? "—" : game.gameCode]
        if !game.fileExists { parts.append("File missing") }
        else if let d = game.lastPlayed { parts.append("Played " + d.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: "  ·  ")
    }
}

/// Atmosphere + huge light title. The title is the hero: nothing else competes with it.
struct EditorialHero<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var height: CGFloat = 440
    var seed: Float = 0.12
    var intensity: Float = 0.95
    @ViewBuilder var trailing: Trailing

    var body: some View {
        GeometryReader { geo in
            let size = min(max(geo.size.width * 0.17, 72), 200, height * 0.5, height - 210)
            ZStack(alignment: .bottomLeading) {
                IridescenceView(intensity: intensity, seed: seed)
                LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.0), .black], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
                VStack(alignment: .leading, spacing: 6) {
                    Text(eyebrow).eyebrow(.white.opacity(0.75))
                    Text(title).font(Ed.display(size)).tracking(-size * 0.035)
                        .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.4)
                }
                .padding(.horizontal, 40).padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, 40).padding(.bottom, 34)
            }
        }
        .frame(height: height)
        .clipped()
    }
}

extension EditorialHero where Trailing == EmptyView {
    init(eyebrow: String, title: String, height: CGFloat = 440, seed: Float = 0.12, intensity: Float = 0.95) {
        self.init(eyebrow: eyebrow, title: title, height: height, seed: seed, intensity: intensity) { EmptyView() }
    }
}
