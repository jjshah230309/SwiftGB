import Foundation

/// Where a game's save file lives. Beside the ROM (so it's easy to find and compatible with other emulators' raw .sav files);
/// if that folder isn't writable, in the app's own Saves folder.
enum SaveStore {
    private static var override: String? { ProcessInfo.processInfo.environment["SWIFTGB_DATA_DIR"] }

    private static func fileName(_ game: Game) -> String { game.url.deletingPathExtension().lastPathComponent + ".sav" }

    private static func fallbackDirectory() -> URL {
        let base = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SwiftGB", isDirectory: true)
        let dir = base.appendingPathComponent("Saves", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Candidate locations, best first. (Tests that set SWIFTGB_DATA_DIR never touch the ROM's own folder.)
    private static func candidates(_ game: Game) -> [URL] {
        var list = [URL]()
        if override == nil { list.append(game.url.deletingLastPathComponent().appendingPathComponent(fileName(game))) }
        list.append(fallbackDirectory().appendingPathComponent(fileName(game)))
        return list
    }

    static func load(for game: Game) -> Data? {
        for url in candidates(game) { if let d = try? Data(contentsOf: url), !d.isEmpty { return d } }
        return nil
    }

    static func write(_ data: Data, for game: Game) {
        let list = candidates(game)
        // Keep writing where the existing save is, otherwise the first writable place.
        let target = list.first { FileManager.default.fileExists(atPath: $0.path) && FileManager.default.isWritableFile(atPath: $0.path) }
            ?? list.first { FileManager.default.isWritableFile(atPath: $0.deletingLastPathComponent().path) }
        guard let target else { NSLog("SwiftGB: no writable place for the save of \(game.title)"); return }
        do { try data.write(to: target, options: .atomic) } catch { NSLog("SwiftGB: couldn't write save \(target.path): \(error)") }
    }

    /// Copy the save that is there now into Saves/Backups, so importing another one can always be undone.
    static func backupExisting(for game: Game) {
        guard let current = load(for: game) else { return }
        let dir = fallbackDirectory().appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let name = game.url.deletingPathExtension().lastPathComponent + "-" + f.string(from: Date()) + ".sav"
        try? current.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}
