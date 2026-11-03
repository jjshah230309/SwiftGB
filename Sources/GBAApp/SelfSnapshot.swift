import AppKit
import GBARender
import GBAUI

/// Verification aid driven purely by environment variables (inert unless set):
///   SWIFTGB_SNAPSHOT=/path/prefix   write <prefix>-library.png after launch
///   SWIFTGB_AUTOPLAY=/path/x.gba    then open that ROM, write <prefix>-playing.png,
///                                    hold "A" + "Right", write <prefix>-keys.png
///   SWIFTGB_QUIT=1                  quit when finished
/// It captures only this app's own window, so it needs no screen-recording permission.
@MainActor
enum SelfSnapshot {
    private static var installed = false

    static func installIfRequested(model: EmulatorModel) {
        guard !installed, let prefix = ProcessInfo.processInfo.environment["SWIFTGB_SNAPSHOT"] else { return }
        installed = true
        let env = ProcessInfo.processInfo.environment
        let autoplay = env["SWIFTGB_AUTOPLAY"]
        let quit = env["SWIFTGB_QUIT"] == "1"
        if let dir = env["SWIFTGB_ADD_DIR"] {      // pre-populate the library from a folder of .gba files
            let files = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            model.library.add(urls: files.filter { $0.pathExtension == "gba" })
        }

        if let size = env["SWIFTGB_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            after(0.2) { NSApp.windows.first(where: { $0.isVisible })?.setContentSize(NSSize(width: size[0], height: size[1])) }
        }
        NSApp.activate(ignoringOtherApps: true)
        after(0.5) { NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil) }
        if env["SWIFTGB_DUMP_VIEWS"] == "1" {
            after(1.5) {
                guard let w = NSApp.windows.first(where: { $0.isVisible }), let root = w.contentView?.superview else { return }
                func dump(_ v: NSView, _ depth: Int) {
                    NSLog("VIEWTREE %@%@ frame=%@ hidden=%d", String(repeating: "  ", count: depth), String(describing: type(of: v)), NSStringFromRect(v.frame), v.isHidden ? 1 : 0)
                    if depth < 5 { v.subviews.forEach { dump($0, depth + 1) } }
                }
                dump(root, 0)
            }
        }
        after(2.5) { write("\(prefix)-library.png") }
        if let autoplay {
            after(3.0) { model.open(url: URL(fileURLWithPath: autoplay)) }
            for (i, t) in [3.3, 3.8, 4.4, 5.0, 5.5].enumerated() { after(t) { write("\(prefix)-playing\(i).png") } }
            after(6.0) { _ = model.handleKey(6, down: true); _ = model.handleKey(124, down: true) }   // Z (A) + Right
            after(7.0) {
                write("\(prefix)-keys.png")
                NSLog("SwiftGB diag: audioRunning=\(model.audioIsRunning) audioBuffered=\(model.audioBufferedFrames) emulationFPS=\(model.emulationFPS)")
            }
            if env["SWIFTGB_M6"] == "1" {
                // Drives the M6 features through the same model calls the menus and keys use, and logs what the model reports.
                let log = "\(prefix)-m6.log"
                func note(_ s: String) {
                    let line = "\(String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))) \(s)\n"
                    if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(toFile: log, atomically: true, encoding: .utf8) }
                }
                after(4.5) { model.saveState(slot: 3) }
                after(5.0) { note("after save: toast=\(model.toast ?? "nil") slots=\(model.stateDates.keys.sorted())") }
                after(5.5) { model.loadState(slot: 3) }
                after(5.9) { note("after load: toast=\(model.toast ?? "nil")"); model.takeScreenshot() }
                after(6.4) { note("after screenshot: toast=\(model.toast ?? "nil")"); model.addCheat(name: "Test", code: "03007E00 000000AB\n13007E10 00001234") }
                after(6.6) { note("cheats=\(model.cheats.count) errors=\(model.cheatErrors.count)"); model.addCheat(name: "Bad", code: "83007E00 000000FF") }
                after(6.8) { note("bad cheat errors=\(model.cheatErrors.count): \(model.cheatErrors.values.first ?? "")") }
                after(7.5) { _ = model.handleKey(13, down: true) }
                after(8.0) { note("rewind held: isRewinding=\(model.isRewinding)") }
                after(8.8) { _ = model.handleKey(13, down: false); _ = model.handleKey(48, down: true) }
                after(9.2) { note("fast-forward held: isFastForwarding=\(model.isFastForwarding) fps=\(model.emulationFPS)") }
                after(9.6) { _ = model.handleKey(48, down: false); note("released: rewinding=\(model.isRewinding) ff=\(model.isFastForwarding)") }
            }
            after(10.0) { write("\(prefix)-hud-hidden.png") }          // HUD should have auto-hidden by now
            after(10.5) { model.stop() }
            after(11.5) { write("\(prefix)-library2.png") }            // back in the library, with the game present
        }
        after(autoplay == nil ? 3.5 : 12.0) { if quit { NSApp.terminate(nil) } }
    }

    /// SWIFTGB_DUMP_MENU=<file>: write every menu item with its key equivalent, to check shortcuts without a screen.
    static func dumpMenuIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SWIFTGB_DUMP_MENU"] else { return }
        after(1.5) {
            var lines = [String]()
            func symbols(_ item: NSMenuItem) -> String {
                guard !item.keyEquivalent.isEmpty else { return "" }
                let m = item.keyEquivalentModifierMask
                var s = ""
                if m.contains(.control) { s += "⌃" }
                if m.contains(.option) { s += "⌥" }
                if m.contains(.shift) { s += "⇧" }
                if m.contains(.command) { s += "⌘" }
                let k = item.keyEquivalent
                let names: [String: String] = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\r": "↩", "\u{8}": "⌫", " ": "Space"]
                return s + (names[k] ?? k.uppercased())
            }
            func walk(_ menu: NSMenu, _ prefix: String) {
                for item in menu.items where !item.isSeparatorItem {
                    let name = prefix + item.title
                    if let sub = item.submenu { walk(sub, name + " ▸ ") }
                    else { lines.append("\(name)\t\(symbols(item))\t\(item.isEnabled ? "" : "(disabled)")") }
                }
            }
            if let main = NSApp.mainMenu { walk(main, "") }
            if ProcessInfo.processInfo.environment["SWIFTGB_PRESS_SETTINGS"] == "1" {
                // Do what ⌘, does: fire the menu item that carries that key equivalent, then see what windows exist.
                func find(_ menu: NSMenu) -> NSMenuItem? {
                    for item in menu.items {
                        if item.keyEquivalent == ",", item.keyEquivalentModifierMask == .command { return item }
                        if let sub = item.submenu, let hit = find(sub) { return hit }
                    }
                    return nil
                }
                let before = NSApp.windows.filter { $0.isVisible }.count
                if let item = NSApp.mainMenu.flatMap(find), let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                    lines.append("PRESS ⌘, -> sent \"\(item.title)\" (enabled=\(item.isEnabled))")
                } else { lines.append("PRESS ⌘, -> no menu item carries ⌘,") }
                after(1.0) {
                    let wins = NSApp.windows.filter { $0.isVisible }
                    lines.append("windows visible before: \(before), after: \(wins.count): " + wins.map { "[\($0.title.isEmpty ? "untitled" : $0.title) \(Int($0.frame.width))x\(Int($0.frame.height))]" }.joined(separator: " "))
                    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
                return
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// SWIFTGB_WINDOW_TEST=<file> (+ SWIFTGB_WINDOW_ROM=<rom>): check that windows can be resized and that the zoom commands snap to whole multiples.
    static func windowTestIfRequested(model: EmulatorModel) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SWIFTGB_WINDOW_TEST"] else { return }
        var lines = [String]()
        func note(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        func size(_ w: NSWindow) -> String { let c = w.contentRect(forFrameRect: w.frame).size; return "\(Int(c.width))x\(Int(c.height))" }
        func describe(_ name: String, _ w: NSWindow) { note("\(name): resizable=\(w.styleMask.contains(.resizable)) content=\(size(w)) min=\(Int(w.contentMinSize.width))x\(Int(w.contentMinSize.height))") }
        func mainWindow() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.title == "SwiftGB" } }
        after(1.5) {
            if let w = mainWindow() {
                describe("main window (library)", w)
                w.setContentSize(NSSize(width: 500, height: 400)); note("  asked for 500x400 in the library -> \(size(w)) (clamped to the library minimum)")
                w.setContentSize(NSSize(width: 1100, height: 800)); note("  asked for 1100x800 -> \(size(w))")
            }
            if let item = NSApp.mainMenu?.items.compactMap({ $0.submenu?.items.first { $0.keyEquivalent == "," } }).first, let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        }
        after(3.5) {
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.title.hasSuffix("Settings") }) {
                describe("settings window", w)
                w.setContentSize(NSSize(width: 900, height: 700)); note("  grown to 900x700 -> \(size(w))")
                w.setContentSize(NSSize(width: 300, height: 200)); note("  shrunk to 300x200 -> \(size(w)) (clamped to its minimum)")
                w.close()
            } else { note("settings window: not found") }
            if let rom = env["SWIFTGB_WINDOW_ROM"] { model.open(url: URL(fileURLWithPath: rom)) }
        }
        after(5.0) {
            guard let w = mainWindow() else { note("no main window while playing"); return }
            note("playing \(Int(model.screenSize.width))x\(Int(model.screenSize.height)): content=\(size(w)) min=\(Int(w.contentMinSize.width))x\(Int(w.contentMinSize.height))")
            w.setContentSize(NSSize(width: 100, height: 100)); note("  asked for 100x100 while playing -> \(size(w)) (clamped to the in-game minimum)")
            model.zoomWindow(by: nil)
        }
        after(6.0) { if let w = mainWindow() { note("  default size -> \(size(w))") }; model.zoomWindow(by: 1) }
        after(7.0) { if let w = mainWindow() { note("  larger -> \(size(w))") }; model.zoomWindow(by: -1); model.zoomWindow(by: -1) }
        after(8.0) { if let w = mainWindow() { note("  smaller twice -> \(size(w))") }; model.zoomWindow(by: -1); model.zoomWindow(by: -1); model.zoomWindow(by: -1) }
        after(9.0) { if let w = mainWindow() { note("  smaller again (floor) -> \(size(w))") }; model.zoomWindow(by: 40) }
        after(10.5) { model.showingCheats = true }
        after(11.5) {
            if let sheet = mainWindow()?.attachedSheet { note("cheats sheet: resizable=\(sheet.styleMask.contains(.resizable)) size=\(Int(sheet.frame.width))x\(Int(sheet.frame.height))") }
            else { note("cheats sheet: not presented") }
        }
        after(10.0) { if let w = mainWindow() { note("  absurdly large -> \(size(w)) on a screen of \(Int((w.screen ?? NSScreen.main)!.visibleFrame.width))x\(Int((w.screen ?? NSScreen.main)!.visibleFrame.height))") } }
    }

    /// SWIFTGB_RENDER_TEST=<file>: render the screen pipeline offscreen at 1080p up to 16K and report, plus how fast it can present with no cap.
    static func renderTestIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SWIFTGB_RENDER_TEST"] else { return }
        DispatchQueue.main.async {
            let lines = refreshSelfTest()
            try? lines.joined(separator: "\n").write(toFile: path + ".refresh", atomically: true, encoding: .utf8)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var lines = [String]()
            for (name, w, h) in [("1080p", 1920, 1080), ("4K", 3840, 2160), ("8K", 7680, 4320), ("16K", 15360, 8640), ("16384 square", 16384, 16384), ("over the limit", 16385, 8640)] {
                let r = ScreenRenderer.offscreenSelfTest(width: w, height: h, frames: 3)
                lines.append("\(r.ok ? "ok  " : "FAIL") \(name): \(r.detail)  \(String(format: "%.1f", r.millis)) ms/frame")
            }
            let t = ScreenRenderer.offscreenSelfTest(width: 1920, height: 1080, frames: 600)
            lines.append("uncapped throughput at 1080p: \(String(format: "%.0f", 1000 / max(t.millis, 0.001))) presents/second (no vsync, \(String(format: "%.2f", t.millis)) ms each)")
            let u = ScreenRenderer.offscreenSelfTest(width: 7680, height: 4320, frames: 60)
            lines.append("uncapped throughput at 8K: \(String(format: "%.0f", 1000 / max(u.millis, 0.001))) presents/second")
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
    }

    private typealias CaptureFn = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?

    private static func capture(_ window: NSWindow) -> CGImage? {
        // The Swift overlay marks CGWindowListCreateImage unavailable, but the symbol is still exported;
        // for a process's OWN windows it needs no screen-recording permission.
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let fn = unsafeBitCast(sym, to: CaptureFn.self)
            if let img = fn(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                            [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue() { return img }
        }
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private static func write(_ path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.windowNumber > 0 }) else {
            NSLog("SwiftGB snapshot: no visible window"); return
        }
        guard let image = capture(window) else {
            NSLog("SwiftGB snapshot: capture failed for window \(window.windowNumber)"); return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            NSLog("SwiftGB snapshot: wrote \(path) (\(image.width)x\(image.height))")
        }
    }
}
