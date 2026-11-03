import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
public final class LibraryStore {
    public private(set) var games: [Game] = []
    /// Result of the last add operation, for a one-line message in the UI.
    public var lastMessage: String?

    private let fileURL: URL

    public init(directory: URL? = nil) {
        // SWIFTGB_DATA_DIR lets tests run against a throwaway library instead of the user's.
        let override = ProcessInfo.processInfo.environment["SWIFTGB_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let base = directory ?? override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftGB", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("library.json")
        load()
    }

    // MARK: adding

    public func add(urls: [URL]) {
        var added = 0, skipped = 0, unsupported = 0
        for url in urls {
            guard let system = GameSystem(fileExtension: url.pathExtension) else { unsupported += 1; continue }
            if games.contains(where: { $0.path == url.path }) { skipped += 1; continue }
            // Prefer the file name (usually the full, readable title); the header title is the fallback.
            let named = prettify(url.deletingPathExtension().lastPathComponent)
            if system == .gba {
                guard let header = GBAHeader.read(from: url) else { unsupported += 1; continue }
                games.append(Game(system: .gba, title: named.isEmpty ? header.title : named, gameCode: header.gameCode, path: url.path))
            } else {
                guard let header = GBHeader.read(from: url) else { unsupported += 1; continue }
                games.append(Game(system: system, title: named.isEmpty ? header.title : named, gameCode: header.gameCode, path: url.path))
            }
            added += 1
        }
        games.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        save()
        var parts: [String] = []
        if added > 0 { parts.append("Added \(added) game\(added == 1 ? "" : "s")") }
        if skipped > 0 { parts.append("\(skipped) already in library") }
        if unsupported > 0 { parts.append("\(unsupported) not a .gba, .gb or .gbc ROM") }
        lastMessage = parts.isEmpty ? nil : parts.joined(separator: " · ")
        let shown = lastMessage
        if shown != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if self?.lastMessage == shown { self?.lastMessage = nil }
            }
        }
    }

    public func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add Game ROMs"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["gba", "gb", "gbc"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    // MARK: editing

    public func remove(_ game: Game) { games.removeAll { $0.id == game.id }; save() }

    public func toggleFavorite(_ game: Game) {
        guard let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[i].favorite.toggle(); save()
    }

    public func markPlayed(_ game: Game) {
        guard let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[i].lastPlayed = Date(); save()
    }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.iso.decode([Game].self, from: data) else { return }
        games = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder.iso.encode(games) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func prettify(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]; return e }
}
private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
