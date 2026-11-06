import SwiftUI

/// Liquid Glass with a fallback. On macOS 26 these are the real `glassEffect` / `GlassEffectContainer` / glass button
/// styles; on macOS 15 the same calls render a material with a hairline, so one code path serves both. Use them only on
/// the control layer that floats over content (overlay buttons, HUDs, transport pills, the chat bar, the tab strip,
/// chips); panels, lists and inspectors stay opaque, standard controls.
/// `-noglass` on the command line forces the pre-26 material path on any system, so the fallback can be seen here.
enum GlassCompat {
    /// Settable so the offscreen previews in the tests can draw the fallback: real glass is composited by the window
    /// server and comes out blank (or white, when tinted) in an offscreen render.
    nonisolated(unsafe) static var forceFallback = ProcessInfo.processInfo.arguments.contains("-noglass") || !AppSettings.bool(AppSettings.Key.liquidGlass, default: true)
}

extension View {
    /// A glass surface in `shape`. `tint` colours it; `interactive` makes it react to hover/press (macOS 26 only).
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *), !GlassCompat.forceFallback {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .background { if let tint { shape.fill(tint) } }
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// Same as `liquidGlass(in: Capsule())`.
    func liquidGlass(tint: Color? = nil, interactive: Bool = false) -> some View {
        liquidGlass(in: Capsule(), tint: tint, interactive: interactive)
    }

    @available(macOS 26, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }

    /// `.buttonStyle(.glass)` / `.glassProminent` on macOS 26, bordered / borderedProminent before it.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *), !GlassCompat.forceFallback {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// `GlassEffectContainer` on macOS 26 (neighbouring glass shapes blend and morph), a plain group before it.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26, *), !GlassCompat.forceFallback {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

extension Color {
    /// The one selection blue for tinted glass (selected tab, active overlay button, chosen chip): the accent at a
    /// strength that reads as the same light blue on every surface. Tinting glass at a low opacity turns the accent
    /// into a different, darker blue on each background, so every selected glass control uses this one value.
    static let glassSelection = Color.accentColor.opacity(0.85)
}

/// A window-level material: blurs what is behind the window (the desktop, other windows), the way Finder's sidebar and
/// content do. The window must be non-opaque with a clear background. `.sidebar` is Liquid Glass on macOS 26 and the
/// translucent sidebar before it; `.underWindowBackground` is the frosted content area. Kept active so the window
/// reads the same when it is not key.
struct BehindWindowMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// True on macOS 26 and later: lets a view pick a lighter treatment where glass already supplies depth.
var hasLiquidGlass: Bool { if #available(macOS 26, *), !GlassCompat.forceFallback { return true } else { return false } }
