import SwiftUI
import AVFoundation
import AppKit

/// The player's picture, aspect-fit. Titles, stills, color and transitions are all in the frames themselves (the compositor).
struct PreviewView: NSViewRepresentable {
    @ObservedObject var controller: PlayerController
    /// False while the project has no clips: a double-click then does nothing (there is nothing to show full screen).
    var canFullScreen = true
    /// The project's frame rate, for the full-screen timecode.
    var fps: Double = 30
    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView(player: controller.player)
        updateNSView(v, context: context)
        return v
    }
    func updateNSView(_ view: PlayerLayerView, context: Context) {
        let fps = fps
        view.onDoubleClick = canFullScreen ? { [weak controller] in if let controller { FullScreenPreview.shared.toggle(controller, keys: nil, fps: fps) } } : nil
    }
}

/// The preview filling the screen: a borderless black window showing the same player (so play, scrub and edits stay
/// live), on the screen the editor is on, with a transport bar (play/pause, scrubber, time, leave) that hides while the
/// mouse rests. Esc, double-click or the preview button leaves, and so does any other EditMax window coming forward (a
/// dialog, Home, Settings), which would otherwise open behind it; the editor's keys (space, J/K/L, arrows) still work.
@MainActor final class FullScreenPreview {
    static let shared = FullScreenPreview()
    private var window: FullScreenWindow?
    var isShowing: Bool { window != nil }

    /// `keys`: the editor's key handler (space, J/K/L, arrows, I/O…), so the full-screen picture answers the same keys as the window.
    func toggle(_ controller: PlayerController, keys: ((NSEvent) -> Bool)?, fps: Double) { if window != nil { close() } else { show(controller, keys: keys ?? lastKeys, fps: fps) } }
    private var lastKeys: ((NSEvent) -> Bool)?

    func show(_ controller: PlayerController, keys: ((NSEvent) -> Bool)?, fps: Double) {
        lastKeys = keys
        let player = controller.player
        guard window == nil, let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let w = FullScreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.level = Self.level
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.animationBehavior = .none
        let v = PlayerLayerView(player: player)
        v.layer?.backgroundColor = .black
        v.onDoubleClick = { [weak self] in self?.close() }
        let controls = FullScreenControlsState()
        let host = NSHostingView(rootView: FullScreenControls(controller: controller, state: controls, fps: fps, leave: { [weak self] in self?.close() }))
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
        // Another EditMax window coming forward (a Save or Open panel, an alert, Home, Settings, a new project: a menu
        // shortcut still works here) ends full screen, so it never opens hidden behind the picture with the app
        // waiting on it. Delivered at once, inside a modal panel's own run loop too.
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { [weak self] n in
            guard let other = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.otherWindowBecameKey(other) }
        }
    }

    /// Above the menu bar, the Dock, the menu bar's icons and the notch drawer; below menus and tooltips, so the
    /// transport bar's tooltips show. (It was the screen-shielding level, over everything including those.)
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)

    private var keyObserver: NSObjectProtocol?

    func otherWindowBecameKey(_ other: NSWindow) {
        guard let w = window, other !== w, !(other is NotchDrawerPanel) else { return }
        close()
    }

    func close() {
        guard let w = window else { return }
        window = nil
        if let o = keyObserver { NotificationCenter.default.removeObserver(o); keyObserver = nil }
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
    /// Around the aspect-fit picture; the program monitor paints the strip it reserves for its buttons the same.
    static let letterbox = CGColor(gray: 0.08, alpha: 1)
    let playerLayer = AVPlayerLayer()
    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = Self.letterbox
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
    let fps: Double
    let leave: () -> Void
    @State private var scrubbing: Double? = nil

    private var duration: Double { max(0.01, controller.lastOutput?.duration.seconds ?? 0) }
    /// The editor's timecode (minutes:seconds.frames), so a time reads the same here as under the timeline.
    private func tc(_ t: Double) -> String { Timecode.string(t, fps: fps) }

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
    /// The editor's timecode (minutes:seconds.frames): decimal seconds looked the same but meant another time.
    private func tc(_ t: Double) -> String { Timecode.string(t, fps: fps) }
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


/// Where the picture goes in the monitor so the floating chrome (the button group, the version banner) never covers
/// it. The picture is aspect-fit; while the chrome fits in the letterbox above it, the picture keeps the whole monitor.
/// When the chrome would cover it (scopes on, a narrow window, a version banner over a full-width picture) the picture
/// gives up a strip at the top instead, painted like the letterbox, so the buttons always sit beside the picture.
enum MonitorLayout {
    /// Space kept between the chrome and the picture.
    static let gap: CGFloat = 10

    /// The aspect-fit rect of a picture `aspect` (width / height) wide in `size`, below `top`.
    static func picture(in size: CGSize, aspect: Double, top: CGFloat = 0) -> CGRect {
        let room = CGSize(width: max(0, size.width), height: max(0, size.height - top))
        guard aspect > 0, room.width > 0, room.height > 0 else { return CGRect(x: 0, y: top, width: room.width, height: room.height) }
        let w = min(room.width, room.height * aspect), h = w / aspect
        return CGRect(x: (room.width - w) / 2, y: top + (room.height - h) / 2, width: w, height: h)
    }

    /// The strip to keep above the picture: 0 while no `chrome` rect comes within `gap` of the full-size picture,
    /// otherwise down to just under the lowest chrome.
    static func topInset(size: CGSize, aspect: Double, chrome: [CGRect]) -> CGFloat {
        let pic = picture(in: size, aspect: aspect)
        let live = chrome.filter { $0.width > 0 && $0.height > 0 }
        let covers = live.contains { c in c.maxX > pic.minX && c.minX < pic.maxX && c.maxY + gap > pic.minY && c.minY < pic.maxY }
        guard covers, let bottom = live.map(\.maxY).max() else { return 0 }
        return min(bottom + gap, max(0, size.height - 40))   // a sliver of picture always stays
    }
}

extension CompareStyle {
    var title: String { self == .split ? "Split at a divider" : "Whole picture before" }
    /// Half the frame inset for the split, the whole frame for "before": the button wears the style it turns on.
    var symbol: String { self == .split ? "rectangle.lefthalf.inset.filled" : "rectangle.inset.filled" }
}

/// The program monitor: the picture (empty state, before/after, source viewer over it), the floating buttons (scopes,
/// before/after, full screen, focus), the banner while an older version is shown, then the scopes and build errors.
struct ProgramMonitor: View {
    @ObservedObject var document: EditMaxDocument
    @ObservedObject var player: PlayerController
    @ObservedObject var state: EditorState
    /// Full screen on or off; the editor owns it (the View menu and the key handler use it too).
    let toggleFullScreen: () -> Void
    /// Previews only: a still drawn in place of the player's picture (an offscreen render cannot capture video layers).
    var still: CGImage? = nil

    /// Where the chrome sits, in the monitor's space, so the picture can step out from under it.
    @State private var controlsFrame: CGRect = .zero
    @State private var bannerFrame: CGRect = .zero
    private static let space = "programMonitor"

    private var noClips: Bool { document.project.allClips.isEmpty }
    private var aspect: Double { Double(document.project.settings.width) / Double(max(1, document.project.settings.height)) }
    private var viewing: ProjectVersion? { state.viewingVersion.flatMap { $0.isCurrent ? nil : $0 } }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let inset = MonitorLayout.topInset(size: geo.size, aspect: aspect, chrome: [controlsFrame, viewing == nil ? .zero : bannerFrame])
                ZStack(alignment: .top) {
                    picture.padding(.top, inset)
                    chrome
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .coordinateSpace(name: Self.space)
            .background(Color(cgColor: PlayerLayerView.letterbox))
            .overlay { SourceViewerHost(document: document) }   // last, so the source viewer covers the program's chrome (SourceViewer.swift)
            if player.scopesEnabled { ScopesView(data: player.scopes) }
            if let e = player.buildError { Text(e).font(.caption).foregroundStyle(.red).padding(4) }
        }
    }

    /// The picture and what is drawn on it: the empty state and the before/after labels and divider.
    private var picture: some View {
        PreviewView(controller: player, canFullScreen: !noClips, fps: document.project.settings.fps)
            .overlay { if let still { Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fit).allowsHitTesting(false) } }
            .overlay {
                if noClips {
                    VStack(spacing: 8) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 72, height: 72).opacity(0.55)
                        Text("Drop a clip on the timeline to see it here").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay { if player.compareMode != .off { CompareOverlay(player: player, aspect: aspect) } }
    }

    /// The button group top right and, while an older version is shown, its banner under it: stacked, so the banner
    /// never runs under the buttons (its Restore button used to sit beneath Scopes and Compare).
    private var chrome: some View {
        VStack(spacing: 8) {
            controls
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { controlsFrame = $0 }
                .frame(maxWidth: .infinity, alignment: .trailing)
            if let v = viewing {
                banner(v)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { bannerFrame = $0 }
            }
        }
        .padding(10)
    }

    /// The floating control layer: one glass group, icon-only, tinted when active.
    private var controls: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                overlayButton("waveform.path.ecg", active: player.scopesEnabled,
                              help: player.scopesEnabled ? "Hide the scopes" : "Show the scopes (waveform and histogram)") { player.scopesEnabled.toggle() }
                    .uiFrame("preview.scopes")
                compareButton
                overlayButton("arrow.up.left.and.arrow.down.right", active: false,
                              help: noClips ? "Add a clip to the timeline to view it full screen" : "Show the preview full screen (⇧⌘F, or double-click the preview; Esc leaves)") { toggleFullScreen() }
                    .disabled(noClips)
                    .uiFrame("preview.fullscreen").uiTap("preview.fullscreen") { toggleFullScreen() }
                overlayButton(state.focusMode ? "rectangle.3.group" : "rectangle.split.2x1", active: state.focusMode,
                              help: state.focusMode ? "Back to the full editor (⌥⌘F)" : "Focus: just the player and the chat (⌥⌘F)") { toggleFocus() }
                    .uiFrame("preview.focus").uiTap("preview.focus") { toggleFocus() }
            }
        }
    }

    /// Before/after as a split button, the way Mac editors do a toggle that has a mode: the left part turns it on (the
    /// way it was last shown) or off, so the tint always says whether the picture is the graded one; the arrow's menu
    /// picks split or whole picture. It used to cycle split, whole picture, off, and the middle state looked like off.
    private var compareButton: some View {
        let graded = document.project.hasColorGrade, on = player.compareMode != .off, style = player.compareStyle
        return HStack(spacing: 0) {
            Button { player.toggleCompare() } label: {
                Image(systemName: style.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 26)
                    .foregroundStyle(on ? Color.white : .primary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusable(false)
            .help(!graded ? "Before / after compares the color grade; no clip is graded yet"
                  : on ? "Showing before / after (\(style.title.lowercased())). Click to show only the graded picture (⌥⌘B)"
                  : "Show before / after the color grade (\(style.title.lowercased())) (⌥⌘B)")
            .pointer()
            .uiFrame("preview.compare").uiTap("preview.compare") { if graded { player.toggleCompare() } }
            Rectangle().fill((on ? Color.white : Color.primary).opacity(0.25)).frame(width: 1, height: 14)
            Menu {
                Picker("Before / after", selection: Binding(get: { player.compareStyle }, set: { player.showCompare($0) })) {
                    ForEach(CompareStyle.allCases, id: \.self) { s in Label(s.title, systemImage: s.symbol).tag(s) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Show Only the Graded Picture") { player.compareMode = .off }.disabled(!on)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 26)
                    .foregroundStyle(on ? Color.white : .secondary)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false).fixedSize()
            .help("Choose how before / after shows: split at a divider, or the whole picture before")
            .pointer()
            .uiFrame("preview.compareStyle")
            .uiTap("preview.compare.split") { if graded { player.showCompare(.split) } }
            .uiTap("preview.compare.before") { if graded { player.showCompare(.before) } }
        }
        .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous), tint: on ? Color.glassSelection : nil, interactive: true)
        .disabled(!graded)
    }

    /// Orange glass under the buttons: what is shown, back to the live project, or make that version the project.
    private func banner(_ v: ProjectVersion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
            Text("Viewing version: \(v.label) · \(v.date.formatted(date: .omitted, time: .shortened))").lineLimit(1).truncationMode(.middle)
            Button("Back to current") { backToCurrent() }.controlSize(.small).fixedSize().pointer().uiFrame("preview.versionBack")
                .uiTap("preview.versionBack") { backToCurrent() }
            Button("Restore") { restore(v) }.controlSize(.small).buttonStyle(.borderedProminent).fixedSize().pointer().uiFrame("preview.versionRestore")
                .uiTap("preview.versionRestore", key: v.id) { restore(v) }
        }
        .font(.system(size: 12)).foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .liquidGlass(tint: .orange.opacity(0.75))
        .uiFrame("preview.versionBanner")
    }

    private func backToCurrent() { state.viewingVersion = nil; player.view(nil) }
    private func restore(_ v: ProjectVersion) { state.viewingVersion = nil; player.view(nil); try? document.restore(version: v, origin: .user) }
    private func toggleFocus() { state.focusMode.toggle(); if state.focusMode, state.chat == nil { state.chat = ChatSession(document: document) } }

    /// One floating glass button over the picture. `.pointer()` sits inside `.disabled` at the call site.
    private func overlayButton(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 26)
                .foregroundStyle(active ? Color.white : .primary)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain).focusable(false)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous), tint: active ? Color.glassSelection : nil, interactive: true)
        .help(help)
        .pointer()
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
            let rect = MonitorLayout.picture(in: geo.size, aspect: aspect)
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
