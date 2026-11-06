import SwiftUI
import AVFoundation
import AppKit

/// The player's picture, aspect-fit. Titles, stills, color and transitions are all in the frames themselves (the compositor).
struct PreviewView: NSViewRepresentable {
    @ObservedObject var controller: PlayerController
    /// False while the project has no clips: a double-click then does nothing (there is nothing to show full screen).
    var canFullScreen = true
    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView(player: controller.player)
        updateNSView(v, context: context)
        return v
    }
    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.onDoubleClick = canFullScreen ? { [weak controller] in if let controller { FullScreenPreview.shared.toggle(controller, keys: nil) } } : nil
    }
}

/// The preview filling the screen: a borderless black window showing the same player (so play, scrub and edits stay
/// live), on the screen the editor is on, with a transport bar (play/pause, scrubber, time, leave) that hides while the
/// mouse rests. Esc, double-click or the preview button leaves; the editor's keys (space, J/K/L, arrows) still work.
@MainActor final class FullScreenPreview {
    static let shared = FullScreenPreview()
    private var window: FullScreenWindow?
    var isShowing: Bool { window != nil }

    /// `keys`: the editor's key handler (space, J/K/L, arrows, I/O…), so the full-screen picture answers the same keys as the window.
    func toggle(_ controller: PlayerController, keys: ((NSEvent) -> Bool)?) { if window != nil { close() } else { show(controller, keys: keys ?? lastKeys) } }
    private var lastKeys: ((NSEvent) -> Bool)?

    func show(_ controller: PlayerController, keys: ((NSEvent) -> Bool)?) {
        lastKeys = keys
        let player = controller.player
        guard window == nil, let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let w = FullScreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))   // above the menu bar and the Dock
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.animationBehavior = .none
        let v = PlayerLayerView(player: player)
        v.layer?.backgroundColor = .black
        v.onDoubleClick = { [weak self] in self?.close() }
        let controls = FullScreenControlsState()
        let host = NSHostingView(rootView: FullScreenControls(controller: controller, state: controls, leave: { [weak self] in self?.close() }))
        host.frame = v.bounds; host.autoresizingMask = [.width, .height]
        v.addSubview(host)
        v.controls = controls
        w.contentView = v
        w.player = player
        w.keys = keys
        w.onLeave = { [weak self] in self?.close() }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func close() {
        guard let w = window else { return }
        window = nil
        w.orderOut(nil)
        w.contentView = nil
    }
}

final class FullScreenWindow: NSWindow {
    var onLeave: (() -> Void)?
    var keys: ((NSEvent) -> Bool)?
    weak var player: AVPlayer?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onLeave?() }   // Esc
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onLeave?()                                                                   // Esc
        case 3 where event.modifierFlags.contains([.command, .shift]): onLeave?()             // ⇧⌘F again
        default:
            if keys?(event) == true { return }                                                // the editor's own keys
            if event.keyCode == 49, let p = player { p.rate == 0 ? p.play() : p.pause(); return }   // space when no handler was given
            super.keyDown(with: event)
        }
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = CGColor(gray: 0.08, alpha: 1)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    var onDoubleClick: (() -> Void)?
    /// Full-screen only: the transport bar's visibility, poked by mouse movement.
    var controls: FullScreenControlsState? { didSet { if controls != nil, trackingArea == nil { updateTrackingAreas() } } }
    private var trackingArea: NSTrackingArea?
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) } }
    override func mouseMoved(with event: NSEvent) { controls?.poke(); super.mouseMoved(with: event) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard controls != nil else { return }
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); trackingArea = t
    }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}


/// Whether the full-screen transport bar is showing; it hides 2.5 s after the mouse last moved, unless the mouse is on it.
@MainActor final class FullScreenControlsState: ObservableObject {
    @Published var visible = true
    @Published var hovering = false { didSet { if hovering { visible = true } else { poke() } } }
    private var hideTask: Task<Void, Never>?
    func poke() {
        visible = true
        NSCursor.unhide()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, !self.hovering else { return }
            self.visible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// Play/pause, a scrubber, the time and a Leave button along the bottom of the full-screen picture.
struct FullScreenControls: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var state: FullScreenControlsState
    let leave: () -> Void
    @State private var scrubbing: Double? = nil

    private var duration: Double { max(0.01, controller.lastOutput?.duration.seconds ?? 0) }
    private func tc(_ t: Double) -> String { String(format: "%d:%05.2f", Int(t) / 60, t - Double(Int(t) / 60 * 60)) }

    var body: some View {
        VStack {
            Spacer()
            // One Liquid Glass pill over the picture: glass buttons beside a glass capsule (scrubber + times), merged by the
            // container; nothing is glass-on-glass. Sized to content and centred, 12 pt off the bottom edge.
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Button { controller.togglePlay() } label: { Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .semibold)).frame(width: 16, height: 16) }
                        .glassButtonStyle().buttonBorderShape(.circle).focusable(false).keyboardShortcut(.space, modifiers: []).pointer().uiFrame("fullscreen.play").help(controller.isPlaying ? "Pause (space)" : "Play (space)")
                    HStack(spacing: 10) {
                        Text(tc(scrubbing ?? controller.currentTime)).font(.system(size: 13, weight: .semibold, design: .monospaced)).monospacedDigit().frame(width: 64, alignment: .trailing)
                        Slider(value: Binding(get: { scrubbing ?? min(controller.currentTime, duration) }, set: { scrubbing = $0; controller.seek(to: $0) }), in: 0...duration, onEditingChanged: { editing in if !editing { scrubbing = nil } })
                            .frame(width: 480)
                            .pointer().uiFrame("fullscreen.scrubber")
                        Text(tc(duration)).font(.system(size: 13, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    }
                    .padding(.horizontal, 16).frame(height: 36)
                    .liquidGlass()
                    Button { leave() } label: { Label("Leave full screen", systemImage: "arrow.down.right.and.arrow.up.left").labelStyle(.iconOnly).font(.system(size: 14, weight: .semibold)).frame(width: 16, height: 16) }
                        .glassButtonStyle().buttonBorderShape(.circle).focusable(false).pointer().uiFrame("fullscreen.leave").help("Leave full screen (Esc)")
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
            .onHover { state.hovering = $0 }
            .opacity(state.visible ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: state.visible)
        }
        .onAppear { state.poke() }
    }
}


/// Play/pause, frame steps, scrubber and time under the picture when the timeline is hidden (focus layout).
struct TransportBar: View {
    @ObservedObject var player: PlayerController
    let fps: Double
    @State private var scrubbing: Double? = nil
    private var duration: Double { max(0.01, player.lastOutput?.duration.seconds ?? 0) }
    private func tc(_ t: Double) -> String { String(format: "%02d:%05.2f", Int(t) / 60, t - Double(Int(t) / 60 * 60)) }
    /// A single Liquid Glass pill meant to float over the picture: the three transport buttons are glass, the scrubber and
    /// times sit in one glass capsule, and the container merges them. Place it with `.overlay(alignment: .bottom)` on the
    /// preview; it keeps 12 pt from the edges on its own.
    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Button { player.step(frames: -1, fps: fps) } label: { Image(systemName: "backward.frame.fill").font(.system(size: 12, weight: .medium)).frame(width: 14, height: 14) }
                        .help("Back one frame (←)").focusable(false).pointer().uiFrame("focus.stepBack")
                    Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .semibold)).frame(width: 14, height: 14) }
                        .help("Play or pause (space)").focusable(false).pointer().uiFrame("focus.play")
                        .uiTap("focus.play") { player.togglePlay() }
                    Button { player.step(frames: 1, fps: fps) } label: { Image(systemName: "forward.frame.fill").font(.system(size: 12, weight: .medium)).frame(width: 14, height: 14) }
                        .help("Forward one frame (→)").focusable(false).pointer().uiFrame("focus.stepForward")
                }
                .glassButtonStyle().buttonBorderShape(.circle)
                HStack(spacing: 10) {
                    Text(tc(scrubbing ?? player.currentTime)).font(.system(size: 13, weight: .semibold, design: .monospaced)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    Slider(value: Binding(get: { scrubbing ?? min(player.currentTime, duration) }, set: { scrubbing = $0; player.seek(to: $0) }), in: 0...duration, onEditingChanged: { if !$0 { scrubbing = nil } })
                        .frame(minWidth: 160, maxWidth: 520)
                        .pointer().uiFrame("focus.scrubber")
                    Text(tc(duration)).font(.system(size: 13, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                }
                .padding(.horizontal, 14).frame(height: 32)
                .liquidGlass()
            }
        }
        .padding(12)
    }
}


/// Labels and the draggable divider over the preview in the before/after view. The picture is letterboxed inside the
/// view, so the divider is placed within the fitted picture rect, not the whole view.
struct CompareOverlay: View {
    @ObservedObject var player: PlayerController
    let aspect: Double
    /// The split when the drag began: the divider follows the mouse's travel, so grabbing it off-centre never makes it jump.
    @State private var dragStart: Double?
    var body: some View {
        GeometryReader { geo in
            let full = geo.size
            let w = min(full.width, full.height * aspect), h = w / aspect
            let rect = CGRect(x: (full.width - w) / 2, y: (full.height - h) / 2, width: w, height: h)
            ZStack(alignment: .topLeading) {
                if player.compareMode == .split {
                    let x = rect.minX + rect.width * player.compareSplit
                    // The line sits exactly on the split; the handle and its hit strip stop short of the picture's edges so
                    // the divider can always be grabbed again, even when it has been pushed all the way to one side.
                    let grip: CGFloat = 16
                    let hx = min(max(x, rect.minX + grip), rect.maxX - grip)
                    tag("BEFORE").position(x: rect.minX + 34, y: rect.minY + 14)
                    tag("AFTER").position(x: rect.maxX - 30, y: rect.minY + 14)
                    Rectangle().fill(.white).frame(width: 2, height: rect.height).position(x: x, y: rect.midY).allowsHitTesting(false)
                    ZStack {
                        Rectangle().fill(.white.opacity(0.001)).frame(width: grip * 2)
                        Circle().fill(.white).frame(width: 14, height: 14).overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.black))
                    }
                    .frame(width: grip * 2, height: rect.height)
                    .contentShape(Rectangle())
                    .pointer().uiFrame("preview.compareDivider")
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("compare"))
                        .onChanged { g in
                            let from = dragStart ?? player.compareSplit
                            if dragStart == nil { dragStart = from }
                            player.compareSplit = min(1, max(0, from + g.translation.width / max(1, rect.width)))
                        }
                        .onEnded { _ in dragStart = nil })
                    .position(x: hx, y: rect.midY)
                } else {
                    tag("BEFORE").position(x: rect.minX + 34, y: rect.minY + 14)
                }
            }
        }
        .coordinateSpace(name: "compare")
        .allowsHitTesting(player.compareMode == .split)
    }
    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
    }
}
