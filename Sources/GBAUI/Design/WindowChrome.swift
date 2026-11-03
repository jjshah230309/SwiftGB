import AppKit
import SwiftUI

/// Strips the system title-bar material so the hero runs edge to edge under the window controls.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = .black
            window.isMovableByWindowBackground = false
            // The title-bar container still draws a decoration layer over full-bleed content; hide only that layer
            // (the traffic lights and the drag region live in sibling views and are untouched).
            if let frame = window.contentView?.superview {
                for v in frame.subviews where String(describing: type(of: v)).hasSuffix("TitlebarDecorationView") { v.isHidden = true }
            }
        }
    }
}

/// Gives a window (a Settings window or a sheet, which SwiftUI makes fixed-size by default) draggable edges, and optionally
/// remembers where the user left it.
public struct ResizableWindow: NSViewRepresentable {
    public var autosaveName: String?
    public init(autosaveName: String? = nil) { self.autosaveName = autosaveName }

    public func makeNSView(context: Context) -> NSView { Probe(autosaveName: autosaveName) }
    public func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        let autosaveName: String?
        init(autosaveName: String?) { self.autosaveName = autosaveName; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The scene may restyle its window after the content attaches; say it again a few times.
            for delay in [0.05, 0.3, 1.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.apply() } }
        }

        private func apply() {
            guard let window else { return }
            if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
            if let autosaveName, window.frameAutosaveName != autosaveName { window.setFrameAutosaveName(autosaveName) }
        }
    }
}

/// macOS 26 puts a 32pt "BackdropView" at the top of every scroll view that sits under the title bar, which dims a
/// full-bleed hero. There is no public switch for it, so hide exactly that view (matched by class name) once it exists.
/// If the class ever disappears this does nothing.
struct HideScrollBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.schedule() }

    private final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }

        func schedule() {
            for delay in [0.0, 0.15, 0.6, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let root = self?.window?.contentView?.superview else { return }
                    Self.hideBackdrops(in: root)
                }
            }
        }

        private static func hideBackdrops(in view: NSView) {
            if String(describing: type(of: view)).hasSuffix("BackdropView") { view.isHidden = true }
            view.subviews.forEach { hideBackdrops(in: $0) }
        }
    }
}
