import AppKit

/// Resizing the game window to whole multiples of the console's screen, anchored at its top-left corner.
public enum WindowSizing {
    /// Smallest the window may get while a game is running: the console's own resolution, roughly.
    public static let minimumGameSize = CGSize(width: 240, height: 160)
    public static let defaultScale = 4
    public static let maximumScale = 16

    /// The scale whose multiple of `game` is closest to the window's current content size.
    public static func currentScale(of window: NSWindow, game: CGSize) -> Int {
        let content = window.contentRect(forFrameRect: window.frame).size
        return max(1, Int((min(content.width / game.width, content.height / game.height)).rounded()))
    }

    /// The largest scale that still fits on the window's screen.
    public static func largestScale(for window: NSWindow, game: CGSize) -> Int {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return maximumScale }
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let fit = min(visible.width / game.width, (visible.height - chrome) / game.height)
        return max(1, min(maximumScale, Int(fit.rounded(.down))))
    }

    /// Make the content area exactly `scale` times the game's resolution (clamped to what fits), keeping the top-left corner put.
    @discardableResult
    public static func apply(scale requested: Int, game: CGSize, to window: NSWindow) -> Int {
        let scale = max(1, min(requested, largestScale(for: window, game: game)))
        let size = NSSize(width: game.width * CGFloat(scale), height: game.height * CGFloat(scale))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
        return scale
    }
}
