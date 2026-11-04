import AppKit
import Foundation

/// Save-state slots and cheat lists, kept per game in the app's own folder.
public struct GameStorage {
    let game: Game
    public init(game: Game) { self.game = game }

    private static var base: URL {
        let root = ProcessInfo.processInfo.environment["SWIFTGB_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SwiftGB", isDirectory: true)
        return root
    }

    /// "<rom name>-<game code>": stable across library re-adds, and readable if someone goes looking.
    private var folderName: String {
        let stem = game.url.deletingPathExtension().lastPathComponent
        let safe = stem.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "_" }
        return String(safe) + "-" + game.gameCode
    }

    private func folder(_ kind: String) -> URL {
        let dir = Self.base.appendingPathComponent(kind, isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: states
    public static let slotCount = 9
    private func stateURL(_ slot: Int) -> URL { folder("States").appendingPathComponent("slot\(slot).sgstate") }

    public func writeState(_ state: Data, slot: Int) -> Bool {
        guard let packed = try? (state as NSData).compressed(using: .lzfse) as Data else { return false }
        do { try packed.write(to: stateURL(slot), options: .atomic); return true } catch { return false }
    }

    public func readState(slot: Int) -> Data? {
        guard let packed = try? Data(contentsOf: stateURL(slot)) else { return nil }
        return try? (packed as NSData).decompressed(using: .lzfse) as Data
    }

    public func stateDate(slot: Int) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: stateURL(slot).path))?[.modificationDate] as? Date
    }

    // MARK: autosave
    // The newest autosave is autosave.sgstate. Each time a new one is written the old one is kept as autosave-<time>.sgstate
    // (the eight newest are kept), so one bad moment (a session that barely started, a failed load) can never destroy good progress.
    private var autosaveURL: URL { folder("States").appendingPathComponent("autosave.sgstate") }
    public static let autosaveHistoryLimit = 8

    private func historyURLs() -> [URL] {
        let dir = folder("States")
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("autosave-") && $0.pathExtension == "sgstate" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    @discardableResult
    public func writeAutosave(_ state: Data) -> Bool {
        guard let packed = try? (state as NSData).compressed(using: .lzfse) as Data else { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: autosaveURL.path) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"; f.locale = Locale(identifier: "en_US_POSIX")
            let when = ((try? fm.attributesOfItem(atPath: autosaveURL.path))?[.modificationDate] as? Date) ?? Date()
            try? fm.moveItem(at: autosaveURL, to: folder("States").appendingPathComponent("autosave-\(f.string(from: when)).sgstate"))
            for old in historyURLs().dropFirst(Self.autosaveHistoryLimit) { try? fm.removeItem(at: old) }
        }
        do { try packed.write(to: autosaveURL, options: .atomic); return true } catch { return false }
    }

    private func read(_ url: URL) -> Data? {
        guard let packed = try? Data(contentsOf: url) else { return nil }
        return try? (packed as NSData).decompressed(using: .lzfse) as Data
    }

    /// The newest autosave.
    public func readAutosave() -> Data? { read(autosaveURL) }

    public var autosaveDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: autosaveURL.path))?[.modificationDate] as? Date
    }

    /// Every autosave still kept, newest first (index 0 is the current one).
    public func autosaveEntries() -> [(date: Date, load: () -> Data?)] {
        var urls = [autosaveURL] + historyURLs()
        urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        return urls.compactMap { u in
            guard let d = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { return nil }
            return (d, { self.read(u) })
        }
    }

    // MARK: cheats
    private var cheatsURL: URL { folder("Cheats").appendingPathComponent("cheats.json") }

    func loadCheats() -> [Cheat] {
        (try? Data(contentsOf: cheatsURL)).flatMap { try? JSONDecoder().decode([Cheat].self, from: $0) } ?? []
    }

    func saveCheats(_ cheats: [Cheat]) {
        if let data = try? JSONEncoder().encode(cheats) { try? data.write(to: cheatsURL, options: .atomic) }
    }

    // MARK: screenshots
    static func screenshotURL(for game: Game) -> URL {
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("SwiftGB", isDirectory: true)
        let override = ProcessInfo.processInfo.environment["SWIFTGB_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Screenshots", isDirectory: true) }
        let target = override ?? dir
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return target.appendingPathComponent("\(game.title) \(f.string(from: Date())).png")
    }
}

public struct Cheat: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var code: String
    public var enabled = true
}

/// PNG data for an ARGB frame, scaled up by whole pixels so it stays sharp.
enum FrameImage {
    static func png(pixels: [UInt32], width: Int, height: Int, scale: Int) -> Data? {
        var out = [UInt32](repeating: 0, count: width * scale * height * scale)
        for y in 0..<(height * scale) {
            for x in 0..<(width * scale) { out[y * width * scale + x] = pixels[(y / scale) * width + x / scale] }
        }
        return out.withUnsafeMutableBytes { raw -> Data? in
            guard let ctx = CGContext(data: raw.baseAddress, width: width * scale, height: height * scale, bitsPerComponent: 8,
                                      bytesPerRow: width * scale * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  let image = ctx.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
    }
}
