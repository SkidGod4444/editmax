import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// The notch drawer: a shape over the camera notch (or a small pill at the top of a screen without one) that
// takes files dropped on it into the Assets library, and offers new downloads. It is an NSPanel that never becomes key
// or main and never activates EditMax: the user can drop a file on it from any app and stay in that app.
//
// Collapsed, the panel is the notch plus 20 pt each side, drawn black so it reads as the notch. A file drag or the
// pointer makes it grow down into the drawer (a spring), which is Liquid Glass (dark, so its white text reads on any
// wallpaper); the pointer leaving or the drag exiting folds it back. The pill of a screen without a notch is glass too. The
// panel's frame is set to the drawer's size before it grows and back to the notch's size after it has folded, so the
// panel never covers more of the menu bar than it shows.

/// Where the notch is and how big the panel is in each state, in screen points. Pure, so it is tested with the
/// numbers of a real MacBook screen.
struct NotchGeometry: Equatable {
    var screen: CGRect
    /// The notch, or the pill's place on a screen without one.
    var notch: CGRect
    var isPill: Bool

    /// Black drawn on each side of the notch (and the extra hit area), so it looks like the notch.
    static let side: CGFloat = 20
    /// The small outward curves where the shape meets the top edge of the screen.
    static let ear: CGFloat = 6
    /// Room around the open drawer for its shadow.
    static let margin: CGFloat = 16
    static let drawerWidth: CGFloat = 440
    /// Height of the drawer's content under the notch: the drawer is about 190 pt tall on a MacBook.
    static let contentHeight: CGFloat = 161
    static let peekContentHeight: CGFloat = 66
    static let pill = CGSize(width: 120, height: 8)
    static let pillHit = CGSize(width: 160, height: 24)

    /// The notch of a screen from its safe area and the widths of the menu bar either side of it, or nil when the
    /// screen has none. The widths (not the areas' x) are used, so it holds wherever the screen sits in the arrangement.
    static func notch(screen: CGRect, safeTop: CGFloat, leftWidth: CGFloat?, rightWidth: CGFloat?) -> CGRect? {
        guard safeTop > 0, let l = leftWidth, let r = rightWidth else { return nil }
        let w = screen.width - l - r
        guard w > 0 else { return nil }
        return CGRect(x: screen.minX + l, y: screen.maxY - safeTop, width: w, height: safeTop)
    }

    static func pill(on screen: CGRect) -> NotchGeometry {
        NotchGeometry(screen: screen, notch: CGRect(x: screen.midX - pill.width / 2, y: screen.maxY - pill.height, width: pill.width, height: pill.height), isPill: true)
    }

    /// The screen with a notch, else a pill on the main screen (the one with the menu bar).
    @MainActor static func current() -> NotchGeometry? {
        for s in NSScreen.screens {
            if let n = notch(screen: s.frame, safeTop: s.safeAreaInsets.top, leftWidth: s.auxiliaryTopLeftArea?.width, rightWidth: s.auxiliaryTopRightArea?.width) {
                return NotchGeometry(screen: s.frame, notch: n, isPill: false)
            }
        }
        return NSScreen.screens.first.map { pill(on: $0.frame) }
    }

    /// Where the drawer's content starts below the top of the screen.
    var contentTop: CGFloat { isPill ? notch.height + 4 : notch.height }
    /// The black body when collapsed (ears not included).
    var collapsedBody: CGSize { isPill ? Self.pill : CGSize(width: notch.width + 2 * Self.side, height: notch.height) }
    var openBody: CGSize { CGSize(width: Self.drawerWidth, height: contentTop + Self.contentHeight) }
    var peekBody: CGSize { CGSize(width: Self.drawerWidth, height: contentTop + Self.peekContentHeight) }

    /// The panel when collapsed: the notch, 20 pt each side and the ears; a pill gets a menu-bar-high hit area.
    var collapsedFrame: CGRect {
        let size = isPill ? CGSize(width: Self.pillHit.width + 2 * Self.ear, height: Self.pillHit.height)
                          : CGSize(width: collapsedBody.width + 2 * Self.ear, height: notch.height)
        return CGRect(x: notch.midX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
    }
    /// The panel around an open body: the body, its ears and room for the shadow.
    func frame(around body: CGSize) -> CGRect {
        let size = CGSize(width: body.width + 2 * Self.ear + 2 * Self.margin, height: body.height + Self.margin)
        return CGRect(x: notch.midX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
    }
}

/// The panel itself: borderless, non-activating, above the menu bar, on every Space and over full-screen apps.
final class NotchDrawerPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false   // a panel hides with its app by default; this one stays while the user is elsewhere
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel's content view: tracks the pointer (in any app, active or not) and holds the SwiftUI drawer.
private final class NotchDrawerContentView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// The hosting view takes the first click: the panel is never key, and the click must reach the button under it.
private final class NotchDrawerHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The drawer's state and its actions. The drop handler and the Downloads handling are plain methods, so tests call
/// them with real files and no panel on screen.
@MainActor
final class NotchDrawer: ObservableObject {
    static let shared = NotchDrawer()

    enum Mode: Equatable { case collapsed, open, peek }
    @Published private(set) var mode: Mode = .collapsed
    /// A file drag is over the drawer.
    @Published private(set) var dragging = false
    /// The last confirmation ("Added 2 files to Assets"), shown for a few seconds.
    @Published private(set) var message: String?
    /// New files in Downloads since launch, newest first (at most `maxDownloads`).
    @Published private(set) var downloads: [URL] = []
    /// The download the drawer is peeking at.
    @Published private(set) var peeking: URL?
    @Published private(set) var geometry: NotchGeometry?
    /// Downloads is being watched (Settings ▸ Files ▸ Watch Downloads, and macOS let EditMax read it).
    @Published private(set) var watching = false
    /// Downloads cannot be read (the user said no to macOS's question).
    @Published private(set) var downloadsDenied = false

    static let maxDownloads = 5
    static let peekSeconds: Double = 4
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.78)

    private var panel: NotchDrawerPanel?
    private var watcher: DownloadsWatcher?
    private var started = false
    private var hovering = false
    private var collapseTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var bag: Set<AnyCancellable> = []

    // MARK: Lifecycle

    /// Called once the splash has gone (AppDelegate); never under XCTest. Shows the panel and starts the Downloads
    /// watcher as the two settings say, and follows them from then on.
    func start() {
        guard !AppDelegate.isTesting, !started else { return }
        started = true
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &bag)
        // ui_click "drawer.open" opens it without a real drag (the menu bar menu has "Open the drawer" too).
        UIRegistry.shared.setTap("drawer.open", count: 1) { [weak self] in self?.open() }
        applySettings()
    }

    /// Settings ▸ Files changed (or start): show or hide the panel, start or stop watching Downloads.
    func applySettings() {
        guard started else { return }
        let s = AppSettings.shared
        if s.notchDrawer { showPanel() } else { hidePanel() }
        if s.notchDrawer && s.watchDownloads { startWatching() } else { stopWatching() }
    }

    var isShowing: Bool { panel?.isVisible ?? false }

    private func showPanel() {
        guard let g = NotchGeometry.current() else { return }
        geometry = g
        if panel == nil {
            let p = NotchDrawerPanel(frame: g.collapsedFrame)
            let content = NotchDrawerContentView(frame: CGRect(origin: .zero, size: g.collapsedFrame.size))
            content.onHover = { [weak self] inside in self?.hover(inside) }
            let host = NotchDrawerHostingView(rootView: NotchDrawerView(drawer: self))
            host.sizingOptions = []
            host.frame = content.bounds
            host.autoresizingMask = [.width, .height]
            content.addSubview(host)
            p.contentView = content
            panel = p
        }
        mode = .collapsed
        panel?.setFrame(g.collapsedFrame, display: true)
        panel?.orderFrontRegardless()   // shown without activating EditMax
        DebugLog.event("drawer-show", ["pill": g.isPill])
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        mode = .collapsed
    }

    /// The screens changed (a display plugged in, the resolution, the arrangement): back over the notch.
    func reposition() {
        guard let p = panel, p.isVisible, let g = NotchGeometry.current() else { return }
        geometry = g
        p.setFrame(frame(for: mode, in: g), display: true)
    }

    private func frame(for mode: Mode, in g: NotchGeometry) -> CGRect {
        switch mode {
        case .collapsed: return g.collapsedFrame
        case .open: return g.frame(around: g.openBody)
        case .peek: return g.frame(around: g.peekBody)
        }
    }

    // MARK: Open and close

    /// Opens the drawer without a drag (the menu bar menu, ui_click "drawer.open"). It folds back after a while if the
    /// pointer never comes to it.
    func open() {
        guard AppSettings.shared.notchDrawer || panel == nil else { return }
        set(.open)
        scheduleCollapse(after: 6)
    }

    func close() { set(.collapsed) }

    /// The pointer came onto the drawer or left it.
    func hover(_ inside: Bool) {
        hovering = inside
        hoverTask?.cancel()
        if inside {
            collapseTask?.cancel()
            guard mode != .open else { return }
            // A short wait, so a pointer passing on its way to the menu bar does not pop it open.
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled, let self, self.hovering else { return }
                self.set(.open)
            }
        } else {
            scheduleCollapse(after: 0.45)
        }
    }

    /// A file drag came over the drawer.
    func dragEntered() {
        dragging = true
        collapseTask?.cancel()
        if mode != .open { set(.open) }
    }

    /// The drag left without dropping.
    func dragExited() {
        dragging = false
        scheduleCollapse(after: 0.45)
    }

    private func scheduleCollapse(after seconds: Double) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            // Not while the pointer is on it, a drag is over it, or a button is held (a download being dragged out).
            if self.dragging || self.pointerInside || NSEvent.pressedMouseButtons != 0 { self.scheduleCollapse(after: 0.5); return }
            self.set(.collapsed)
        }
    }

    private var pointerInside: Bool {
        guard let p = panel, p.isVisible else { return hovering }
        return p.frame.contains(NSEvent.mouseLocation)
    }

    /// Changes the state: the panel first grows to hold both the old and the new shape, then the shape springs from one
    /// to the other, and once the spring has settled the panel takes the new size.
    ///
    /// Both sizes are centred on the notch, so the panel only ever grows outward and down. It is laid out at once, outside
    /// the spring: left to the next pass, SwiftUI animated the shape's move to the wider panel's centre together with its
    /// size, so the drawer slid in from the left instead of growing out from behind the camera.
    private func set(_ new: Mode) {
        guard new != mode else { return }
        if new != .peek { peeking = nil }
        // macOS said no to Downloads earlier: try again when the drawer opens, in case the user has since allowed it.
        if new == .open, downloadsDenied, started, AppSettings.shared.notchDrawer, AppSettings.shared.watchDownloads { startWatching() }
        if let p = panel, let g = geometry {
            let target = frame(for: new, in: g)
            let room = p.frame.union(target)
            if room != p.frame {
                p.setFrame(room, display: false)
                p.contentView?.layoutSubtreeIfNeeded()
            }
            if room != target {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(420))
                    guard let self, self.mode == new else { return }
                    p.setFrame(target, display: true)
                    p.contentView?.layoutSubtreeIfNeeded()
                }
            }
        }
        withAnimation(Self.spring) { mode = new }
        DebugLog.event("drawer-mode", ["mode": "\(new)"])
    }

    // MARK: Dropping and adding

    /// Files dropped on the drawer: copied into the Assets library (source drawer). Only the library changes: no
    /// project, selection, inspector tab or layout is touched, whatever is open.
    @discardableResult
    func handleDrop(_ urls: [URL]) async -> LibraryAddResult {
        dragging = false
        let r = await AssetLibrary.shared.addFiles(urls, source: .drawer, copy: true)
        show(r.message)
        Self.showInLibrary(r)
        DebugLog.event("drawer-drop", ["files": urls.count, "added": r.added.count, "failed": r.failures.count])
        scheduleCollapse(after: 2.2)
        return r
    }

    /// The Add button on a download: copied into the library (source download), as a drop is.
    @discardableResult
    func addDownload(_ url: URL) async -> LibraryAddResult {
        let r = await AssetLibrary.shared.addFiles([url], source: .download, copy: true)
        show(r.added.isEmpty && r.failures.isEmpty ? "Already in Assets" : r.message)
        Self.showInLibrary(r)
        if mode == .peek { scheduleCollapse(after: 1.8) }
        return r
    }

    /// Open editor windows switch their media panel to Library and point at what just went in (the user asked for this:
    /// a drop on the notch should show where it landed). Only that panel changes, never the layout or the inspector.
    static func showInLibrary(_ r: LibraryAddResult) {
        let paths = (r.added + r.existing).map(\.path)
        guard !paths.isEmpty else { return }
        NotificationCenter.default.post(name: .editmaxShowInLibrary, object: nil, userInfo: ["paths": paths])
    }

    /// True when the library already holds this file (as a copy of it, or the file itself).
    func isInLibrary(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return AssetLibrary.shared.all.contains { $0.original == path || $0.path == path }
    }

    /// A finished download from the watcher: listed in the drawer, and the drawer peeks at it for a few seconds.
    func handleNewDownload(_ url: URL) {
        downloads.removeAll { $0 == url }
        downloads.insert(url, at: 0)
        if downloads.count > Self.maxDownloads { downloads.removeLast(downloads.count - Self.maxDownloads) }
        guard mode == .collapsed else { return }   // already open: the row shows it
        set(.peek)
        peeking = url
        scheduleCollapse(after: Self.peekSeconds)
    }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled, let self, self.message == text else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.message = nil }
        }
    }

    // MARK: Downloads

    private func startWatching() {
        if watcher == nil { watcher = DownloadsWatcher { [weak self] url in self?.handleNewDownload(url) } }
        watcher?.start()
        downloadsDenied = watcher?.denied ?? false
        watching = watcher?.isRunning ?? false
    }

    private func stopWatching() {
        watcher?.stop()
        watching = false
        downloads = []
    }

    #if DEBUG
    /// The offscreen previews put the drawer in a state without a panel.
    func preview(mode: Mode, geometry: NotchGeometry, downloads: [URL] = [], peeking: URL? = nil, message: String? = nil, dragging: Bool = false, watching: Bool = true) {
        self.mode = mode; self.geometry = geometry; self.downloads = downloads; self.peeking = peeking; self.message = message; self.dragging = dragging
        self.watching = watching; downloadsDenied = false
    }
    #endif
}

// MARK: The drawer

/// The notch's shape: a body with rounded bottom corners and small outward curves where it meets the top of the
/// screen, so it reads as the notch growing down.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var ear: CGFloat = NotchGeometry.ear
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, ear) }
        set { bottomRadius = newValue.first; ear = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let e = min(ear, r.width / 4), b = min(bottomRadius, (r.width - 2 * e) / 2, r.height)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + e + b, y: r.maxY), control: CGPoint(x: r.minX + e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - b), control: CGPoint(x: r.maxX - e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// What the panel shows: the shape (black while folded over the notch, glass otherwise), and inside it when open the
/// drop zone and "New in Downloads", or when peeking the one new download.
struct NotchDrawerView: View {
    @ObservedObject var drawer: NotchDrawer
    @ObservedObject private var library = AssetLibrary.shared

    private var g: NotchGeometry { drawer.geometry ?? .pill(on: CGRect(x: 0, y: 0, width: 1352, height: 878)) }

    private var body0: CGSize {
        switch drawer.mode {
        case .collapsed: return g.collapsedBody
        case .open: return g.openBody
        case .peek: return g.peekBody
        }
    }

    var body: some View {
        let size = body0
        let open = drawer.mode != .collapsed
        let ear = g.isPill && !open ? 0 : NotchGeometry.ear   // the pill hangs from the top edge without ears
        let shape = NotchShape(bottomRadius: open ? 22 : (g.isPill ? g.collapsedBody.height / 2 : 9), ear: ear)
        let asNotch = !open && !g.isPill   // folded over a real notch: black, so it reads as the notch itself
        shape
            .fill(Color.black.opacity(asNotch ? 1 : 0))
            .frame(width: size.width + 2 * ear, height: size.height)
            .overlay(alignment: .top) {
                if open {
                    Group {
                        if drawer.mode == .peek, let url = drawer.peeking { peek(url) } else { openContent }
                    }
                    .padding(.top, g.contentTop)
                    .padding(.horizontal, ear + 18)
                    .frame(width: size.width + 2 * ear, height: size.height, alignment: .top)
                    .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.08)))
                }
            }
            .clipShape(shape)
            .liquidGlass(in: shape, tint: Color.black.opacity(0.3), visible: !asNotch)
            .shadow(color: .black.opacity(open ? 0.3 : 0), radius: 12, y: 4)
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], delegate: Drop(drawer: drawer))
    }

    // MARK: Open

    private var openContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            dropZone.padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("NEW IN DOWNLOADS").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.white.opacity(0.5))
                downloadsRow
            }
        }
    }

    private var dropZone: some View {
        let on = drawer.dragging
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(on ? Color.accentColor : Color.white.opacity(0.22), style: StrokeStyle(lineWidth: on ? 2 : 1.2, dash: [6, 4]))
            .background(on ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                HStack(spacing: 10) {
                    if let m = drawer.message {
                        Image(systemName: m.hasPrefix("Could not") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 18)).foregroundStyle(m.hasPrefix("Could not") ? Color.orange : Color.green)
                        Text(m).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    } else {
                        Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 18)).foregroundStyle(on ? Color.accentColor : .white.opacity(0.7))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Drop to add to Assets").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            Text("Copied into EditMax; footage on a drive stays there").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 62)
            .uiTap("drawer.close") { drawer.close() }   // handler only: the driver folds it back
    }

    @ViewBuilder private var downloadsRow: some View {
        if drawer.downloadsDenied {
            note("EditMax cannot see Downloads. Allow it in System Settings ▸ Privacy & Security ▸ Files and Folders.")
        } else if !drawer.watching {
            note("Watching Downloads is off in Settings ▸ Files.")
        } else if drawer.downloads.isEmpty {
            note("Nothing new yet. Media you download shows up here.")
        } else {
            // Newest first; the rest scroll sideways (a trackpad scroll works without EditMax being active).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(drawer.downloads, id: \.self) { url in DownloadChip(drawer: drawer, url: url, inLibrary: inLibrary(url)).frame(width: 190) }
                }
            }
            .frame(height: 40)
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(2).frame(height: 40, alignment: .leading)
    }

    private func inLibrary(_ url: URL) -> Bool {
        _ = library.all.count   // re-evaluated as the library changes
        return drawer.isInLibrary(url)
    }

    // MARK: Peek

    private func peek(_ url: URL) -> some View {
        HStack(spacing: 12) {
            DownloadIcon(url: url).frame(width: 52, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(drawer.message ?? "New in Downloads").font(.system(size: 10, weight: .semibold)).foregroundStyle(drawer.message == nil ? .white.opacity(0.55) : .green)
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            AddButton(drawer: drawer, url: url, inLibrary: inLibrary(url), id: "drawer.peek.add")
        }
        .padding(.top, 10)
        .onDrag { NSItemProvider(object: url as NSURL) } preview: { Label(url.lastPathComponent, systemImage: "doc").padding(6) }
    }

    private struct Drop: DropDelegate {
        let drawer: NotchDrawer
        func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
        func dropEntered(info: DropInfo) { drawer.dragEntered() }
        func dropExited(info: DropInfo) { drawer.dragExited() }
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
        func performDrop(info: DropInfo) -> Bool {
            let providers = info.itemProviders(for: [.fileURL])
            Task { @MainActor in await drawer.handleDrop(await LibraryDrag.urls(from: providers)) }
            return true
        }
    }
}

/// One new download in the drawer: its picture, name and an Add button. Drag it out to the Finder or a project.
private struct DownloadChip: View {
    @ObservedObject var drawer: NotchDrawer
    let url: URL
    let inLibrary: Bool

    var body: some View {
        HStack(spacing: 7) {
            DownloadIcon(url: url).frame(width: 34, height: 26)
            Text(url.lastPathComponent).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            AddButton(drawer: drawer, url: url, inLibrary: inLibrary, id: "drawer.add.\(url.lastPathComponent)", compact: true)
        }
        .padding(.leading, 5).padding(.trailing, 6).frame(height: 40)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: url as NSURL) } preview: { Label(url.lastPathComponent, systemImage: "doc").padding(6) }
        .help("Drag into a project or to the Finder")
        .pointer()
        .uiFrame("drawer.download.\(url.lastPathComponent)")
    }
}

private struct AddButton: View {
    @ObservedObject var drawer: NotchDrawer
    let url: URL
    let inLibrary: Bool
    let id: String
    var compact = false

    var body: some View {
        Button { add() } label: {
            Group {
                if inLibrary { Image(systemName: "checkmark") } else { Text("Add") }
            }
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(inLibrary ? Color.green : .white)
            .padding(.horizontal, compact ? 8 : 12).frame(height: compact ? 22 : 26)
            .background(inLibrary ? Color.white.opacity(0.08) : Color.accentColor, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).focusable(false)
        .help(inLibrary ? "In Assets" : "Add to Assets (copied into EditMax)")
        .pointer().disabled(inLibrary)
        .uiFrame(id).uiTap(id) { add() }
    }

    private func add() { guard !inLibrary else { return }; Task { await drawer.addDownload(url) } }
}

/// A download's picture: the image itself or a video frame when there is one, else its kind's symbol.
private struct DownloadIcon: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        // The picture fills whatever size the caller gives and never spills past it.
        Color.white.opacity(0.1)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: LibraryText.symbol(AssetLibrary.kind(of: url) ?? .video)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: url) {
            switch AssetLibrary.kind(of: url) {
            case .image: image = await Task.detached(priority: .utility) { LibraryThumbnails.imageThumbnail(url, maxPixels: 160) }.value
            case .video: image = await ProjectLibrary.poster(url: url, kind: .video, at: 0.5)
            default: break
            }
        }
    }
}
