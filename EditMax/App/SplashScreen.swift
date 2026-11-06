import SwiftUI
import AppKit

/// The launch splash: a borderless card with the app icon alone, centred, landing with a spring and one pass of light. It floats above every window, so the app delegate
/// shows it only for a launch that activated the app (a background launch, `open -g`, gets none), and it fades out
/// once the MCP server is listening (or after `maxSeconds` at the latest). `-nosplash` on the command line skips it.
@MainActor
final class SplashScreen {
    static let shared = SplashScreen()
    private var window: NSWindow?
    private var shownAt = Date.distantPast
    private let minSeconds = max(1.5, SplashView.choreographySeconds)
    private let maxSeconds = 5.0
    private var dismissing = false
    private var holding = false
    /// Windows kept out of sight while the splash is up (restored documents, Home), put back when it fades.
    private var hidden: [NSWindow] = []
    private var sweep: Timer?
    /// Runs once the splash has faded (or right away when there is no splash): the app's own windows open after it.
    private var onDismiss: [() -> Void] = []
    var isShowing: Bool { window != nil }
    func afterDismiss(_ run: @escaping () -> Void) { if window == nil { run() } else { onDismiss.append(run) } }

    func show() {
        guard !ProcessInfo.processInfo.arguments.contains("-nosplash"), window == nil else { return }
        let a = ProcessInfo.processInfo.arguments
        let frozen = a.firstIndex(of: "-splash-t").flatMap { a.indices.contains($0 + 1) ? Double(a[$0 + 1]) : nil }
        let loop = a.contains("-splash-loop")
        holding = frozen != nil || loop   // `-splash-t <seconds>` holds one moment; `-splash-loop` replays it; both keep the window up
        let view = NSHostingView(rootView: SplashView(frozen: frozen, loop: loop))
        view.frame = NSRect(x: 0, y: 0, width: SplashView.width, height: SplashView.height)
        let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        w.animationBehavior = .none
        w.center()
        w.alphaValue = 0
        w.orderFront(nil)   // never takes the key window
        w.animator().alphaValue = 1
        window = w
        shownAt = Date()
        DebugLog.event("splash-show", ["windowNumber": w.windowNumber])
        // Nothing of the app shows until the splash is gone: state restoration and Finder opens bring document windows
        // up on their own schedule, so keep sweeping them out of sight while the splash is up.
        if !holding {
            hideAppWindows()
            sweep = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in Task { @MainActor in self?.hideAppWindows() } }
        }
    }

    /// Fades the splash out as soon as the minimum time has passed and the MCP server is up, or at `maxSeconds`.
    func dismissWhenReady() {
        guard window != nil, !dismissing, !holding else { return }
        dismissing = true
        Task { @MainActor in
            while Date().timeIntervalSince(shownAt) < maxSeconds {
                let ready = Date().timeIntervalSince(shownAt) >= minSeconds && MCPService.shared.status != .stopped
                if ready { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            dismiss()
        }
    }

    /// Fully transparent and deaf to the mouse rather than ordered out: a window that is still "visible" to AppKit
    /// keeps the document machinery from reacting to an app with no windows (it would put up an Open panel).
    private func hideAppWindows() {
        for w in NSApp.windows where w !== window && w.isVisible && w.alphaValue > 0 && w.styleMask.contains(.titled) && w.level == .normal && !(w is NSPanel) {
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            if !hidden.contains(where: { $0 === w }) { hidden.append(w) }
        }
    }

    func dismiss() {
        guard let w = window else { return }
        window = nil
        sweep?.invalidate(); sweep = nil
        // Only windows that still exist on screen come back: a document closed while the splash was up (the empty
        // untitled one DocumentGroup makes at launch) must not be ordered back in as a zombie.
        let back = hidden.filter(\.isVisible); hidden = []
        for h in back { h.ignoresMouseEvents = false; h.animator().alphaValue = 1 }
        back.first?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            w.animator().alphaValue = 0
        }, completionHandler: { Task { @MainActor in w.orderOut(nil) } })
        DebugLog.event("splash-dismiss", ["seconds": (Date().timeIntervalSince(shownAt) * 100).rounded() / 100])
        let pending = onDismiss; onDismiss = []
        pending.forEach { $0() }
    }
}

private struct SplashView: View {
    @ObservedObject private var mcp = MCPService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let start = Date()
    /// A fixed moment on the clock (seconds), for stills and `-splash-t`; nil runs live.
    let frozen: Double?
    /// Replays the choreography every `loopSeconds` (`-splash-loop`), for watching it.
    let loop: Bool
    private static let loopSeconds = 3.8
    init(animated: Bool = true, frozen: Double? = nil, loop: Bool = false) { self.frozen = animated ? frozen : 3; self.loop = loop }

    static let width: CGFloat = 320
    static let height: CGFloat = 292
    private static let icon: CGFloat = 108
    /// The whole choreography is over by here; the splash never leaves before it.
    static let choreographySeconds = 2.2

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0"
        return short
    }
    private var ready: Bool { if case .running = mcp.status { return true } else { return false } }

    // The clock. Everything below is a pure function of `t`, so a still at any moment is exact. The clock only ever
    // stops for a frozen still; readiness never interrupts the choreography.
    var body: some View {
        SwiftUI.TimelineView(.animation(paused: frozen != nil)) { tl in
            let elapsed = tl.date.timeIntervalSince(start)
            card(frozen ?? (loop ? elapsed.truncatingRemainder(dividingBy: Self.loopSeconds) : elapsed))
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Choreography (2.2 s)
    // 0.00–0.90  the icon settles: a spring from 88 % with a soft overshoot, its shadow deepening as it lands
    // 0.55–1.75  one pass of light crosses the metal of the icon, left to right
    // 0.70–1.20  the name fades in, still
    // 0.55 →      a loading bar climbs under the icon and completes when the server is up (not before 1.7 s); then the card fades

    private func card(_ t: Double) -> some View {
        ZStack {
            Color.clear   // the card itself is Liquid Glass (a dark-tinted material before macOS 26), see below
            // Glass depth: a faint light from the top edge, nothing more.
            LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.45))
            VStack(spacing: 0) {
                icon(t)
                Text("EditMax")
                    .font(.system(size: 20, weight: .semibold)).tracking(-0.2)
                    .opacity(ease(stage(t, 0.7, 0.5)))
                    .padding(.top, 16)
                Text("Your edit, on your word.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .opacity(ease(stage(t, 0.85, 0.5)))
                    .padding(.top, 6)
                loadingBar(t).padding(.top, 24)
            }
            .padding(.bottom, 16)   // the version sits below; the group rides a little above centre
            VStack {
                Spacer()
                Text("Version \(Self.version) · by Saidev Dhal")
                    .font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
                    .opacity(stage(t, 0.8, 0.4))
                    .padding(.bottom, 20)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
    }

    /// The icon lands with a spring; a band of light then crosses it once, confined to the icon's own shape.
    private func icon(_ t: Double) -> some View {
        let land = reduceMotion ? 1 : spring(stage(t, 0, 0.9))
        let sheen = reduceMotion ? 1 : ease(stage(t, 0.55, 1.2))
        let size = Self.icon
        let image = Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
        return image
            .frame(width: size, height: size)
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.0), location: 0.35),
                                       .init(color: .white.opacity(0.42), location: 0.5),
                                       .init(color: .white.opacity(0.0), location: 0.65), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: size * 0.9, height: size * 2.2)
                    .rotationEffect(.degrees(22))
                    .offset(x: -size * 1.1 + sheen * size * 2.2)
                    .blendMode(.plusLighter)
                    .opacity(sheen > 0 && sheen < 1 ? 1 : 0)
                    .mask(image.frame(width: size, height: size))
            }
            .scaleEffect(0.88 + 0.12 * land)
            .opacity(min(1, stage(t, 0, reduceMotion ? 0.6 : 0.4) * 1.2))
            .shadow(color: .black.opacity(0.45 * land), radius: 18 * land, y: 10 * land)
    }

    /// A thin bar under the icon: it climbs steadily while the app starts (never quite to the end on its own) and
    /// completes the moment the agent server is up, once the icon has landed.
    private func loadingBar(_ t: Double) -> some View {
        let climb = 0.88 * (1 - exp(-t / 1.6))
        let full = ready && t >= 1.7
        let p = full ? 1 : climb
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.10))
            Capsule().fill(Color.white.opacity(full ? 0.9 : 0.6)).frame(width: 160 * p)
        }
        .frame(width: 160, height: 1.5)
        .animation(.easeOut(duration: 0.35), value: full)
        .opacity(stage(t, 0.55, 0.4))
    }

    // MARK: Easing
    private func stage(_ t: Double, _ from: Double, _ duration: Double) -> Double { min(1, max(0, (t - from) / duration)) }
    private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    /// A critically-damped-ish spring: a small overshoot, settled by x = 1.
    private func spring(_ x: Double) -> Double { 1 - exp(-5.2 * x) * cos(3.4 * x) * (1 - x * 0.2) }
}

extension SplashScreen {
    /// `-splash-render <png>`: writes one frame of the splash to a file at 2× (a check of the design without a window).
    static func renderIfRequested() {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-splash-render"), i + 1 < a.count else { return }
        let r = ImageRenderer(content: SplashView(animated: false).environment(\.colorScheme, .dark))
        r.scale = 2
        r.proposedSize = ProposedViewSize(width: SplashView.width, height: SplashView.height)
        if let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: a[i + 1]))
            DebugLog.event("splash-render", ["path": a[i + 1]])
        }
    }
}
