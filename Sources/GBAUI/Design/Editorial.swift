import AppKit
import SwiftUI

// Design language: a monochrome editorial gallery. Pure black / white / greys for every control and word;
// the ONLY colour is the iridescent field (media). Sharp 0pt corners everywhere except full-pill buttons & tags.
// No shadows, no gradients on controls, hairline 1px borders, slow expo-out motion.

enum Ed {
    static let gray = Color(white: 0.62)
    static let dim = Color(white: 0.43)
    static let hairline = Color.white.opacity(0.14)
    static let ghostBorder = Color.white.opacity(0.30)

    /// cubic-bezier(0.19, 1, 0.22, 1): fast start, long gentle settle.
    static let ease = Animation.timingCurve(0.19, 1, 0.22, 1, duration: 1.0)
    static let easeFast = Animation.timingCurve(0.19, 1, 0.22, 1, duration: 0.55)

    static func display(_ size: CGFloat, whisper: Bool = false) -> Font {
        .custom(whisper ? "AvenirNext-UltraLight" : "AvenirNext-Regular", size: size)
    }
    static func body(_ size: CGFloat) -> Font { .custom("AvenirNext-Regular", size: size) }
    static func label(_ size: CGFloat = 11) -> Font { .custom("AvenirNext-Medium", size: size) }
}

extension View {
    /// Small uppercase tracked label (nav links, section labels, metadata).
    func eyebrow(_ color: Color = Ed.gray) -> some View {
        self.font(Ed.label()).textCase(.uppercase).tracking(1.6).foregroundStyle(color)
    }
}

// MARK: - Ghost pill (the one expressive control)

/// Transparent, 1px translucent border, full-pill radius. `glass` adds a clear Liquid Glass layer for use over moving imagery.
struct GhostPillChrome<Content: View>: View {
    var glass = false
    var compact = false
    var pressed = false
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        content
            .font(Ed.body(compact ? 13 : 15))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 18 : 28)
            .padding(.vertical, compact ? 7 : 11)
            .background { Capsule().fill(Color.white.opacity(pressed ? 0.24 : (hover ? 0.12 : 0))) }
            .overlay { Capsule().strokeBorder(Color.white.opacity(hover ? 0.75 : 0.30), lineWidth: 1) }
            .modifier(OptionalClearGlass(enabled: glass))
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .animation(Ed.easeFast, value: hover)
            .animation(Ed.easeFast, value: pressed)
    }
}

private struct OptionalClearGlass: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.glassEffect(.clear, in: .capsule) } else { content }
    }
}

struct GhostPillStyle: ButtonStyle {
    var glass = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        GhostPillChrome(glass: glass, compact: compact, pressed: configuration.isPressed) { configuration.label }
    }
}

/// Small bordered tag ("GBA"): the same 75px-radius language as the buttons.
struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(Ed.label(10)).textCase(.uppercase).tracking(1.2).foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1) }
    }
}

// MARK: - Hairline controls

/// Text options in a row; the selected one is circled by a pill. Replaces the stock segmented/menu pickers.
struct TextChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button { withAnimation(Ed.easeFast) { selection = option.0 } } label: {
                    Text(option.1).font(Ed.body(13))
                        .foregroundStyle(on ? Color.white : Ed.gray)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .overlay { Capsule().strokeBorder(Color.white.opacity(on ? 0.6 : 0), lineWidth: 1) }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A pill showing the current choice that opens a menu of the others; for lists too long to lay out in a row.
struct MenuChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { selection = option.0 } label: {
                    if option.0 == selection { Label(option.1, systemImage: "checkmark") } else { Text(option.1) }
                }
            }
        } label: {
            GhostPillChrome(compact: true) {
                HStack(spacing: 8) {
                    Text(options.first { $0.0 == selection }?.1 ?? "").frame(minWidth: 70, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

struct PillToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { withAnimation(Ed.easeFast) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().strokeBorder(Color.white.opacity(isOn ? 0.8 : 0.35), lineWidth: 1)
                Circle().fill(isOn ? Color.white : Color.white.opacity(0.45)).frame(width: 14, height: 14).padding(.horizontal, 5)
            }
            .frame(width: 46, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 1px line with a small round thumb.
struct HairlineSlider: View {
    @Binding var value: Double          // 0...1
    var width: CGFloat = 220
    @State private var dragging = false
    var body: some View {
        let thumb: CGFloat = dragging ? 16 : 12
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.25)).frame(height: 1)
            Rectangle().fill(Color.white).frame(width: max(0, CGFloat(value) * width), height: 1)
            Circle().fill(Color.white).frame(width: thumb, height: thumb)
                .offset(x: CGFloat(value) * (width - thumb))
        }
        .frame(width: width, height: 28)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in dragging = true; value = min(1, max(0, g.location.x / width)) }
            .onEnded { _ in dragging = false })
        .animation(Ed.easeFast, value: dragging)
    }
}

/// Circular text that rotates slowly around a still arrow: a typographic punctuation mark, used as the "add a ROM" prompt.
/// The ring is rasterised once and spun by a Core Animation layer animation, which the window server runs on its own:
/// no per-frame work in this process (a SwiftUI repeating animation cost ~17% of a core on the main thread).
struct RotatingBadge: View {
    let text: String
    var size: CGFloat = 104

    var body: some View {
        ZStack {
            SpinningLayer(image: Self.rasterize(ring), size: size, period: 24)
            Image(systemName: "arrow.down").font(.system(size: 15, weight: .ultraLight)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var ring: some View {
        let chars = Array(text)
        return ZStack {
            ForEach(Array(chars.enumerated()), id: \.offset) { i, c in
                Text(String(c)).font(Ed.label(10)).foregroundStyle(.white)
                    .offset(y: -size / 2 + 8)
                    .rotationEffect(.degrees(Double(i) / Double(chars.count) * 360))
            }
        }
        .frame(width: size, height: size)
    }

    @MainActor private static func rasterize<V: View>(_ view: V) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.cgImage
    }
}

private struct SpinningLayer: NSViewRepresentable {
    let image: CGImage?
    let size: CGFloat
    let period: CFTimeInterval

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        let ring = CALayer()
        ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ring.position = CGPoint(x: size / 2, y: size / 2)
        ring.contents = image
        ring.contentsGravity = .resizeAspect
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        ring.add(spin, forKey: "spin")
        host.layer?.addSublayer(ring)
        return host
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
