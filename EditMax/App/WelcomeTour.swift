import AppKit
import AVFoundation
import MCP
import SwiftUI

/// The welcome demo. On a first launch (no projects yet), after the splash and Home, EditMax opens a scratch project and
/// shows itself being used: a guide cursor flies to the real controls and clicks them, so the clips come in, go on the
/// timeline, play, get cut and Chat gets asked, while a voice explains and one blue line beside the cursor says the same
/// in short. The person only watches; Esc or Skip ends it. Then Home again, then the crash-report card.
/// Help ▸ Welcome Tour plays it again, on a fresh scratch project. Nothing it does touches the person's own projects.
///
/// It drives EditMax the way the MCP UI driver does (in-process events and the views' own handlers), never with
/// system-level input. Its layer is a child window of the project window: it catches stray clicks so nobody trips the
/// demo up, and while it runs the keyboard is held except for Esc and ⌘ shortcuts.
struct DemoBeat: Equatable {
    enum Action: Equatable { case none, importMedia, addClips, play(seconds: Double), cut, askChat(String), pointAtExport, outro }
    /// The recording, `demo-<voice>.m4a` (or .mp3, .wav) in the app's resources; without one the line runs silent for its
    /// reading time.
    let voice: String
    /// The one row beside the cursor.
    let caption: String
    /// What the voice says.
    let line: String
    var keys: [String] = []
    let action: Action

    /// How long the line takes at an unhurried pace, for a beat without a recording.
    var readingTime: Double { max(1.8, Double(line.split(separator: " ").count) / 2.6 + 0.4) }

    static let script: [DemoBeat] = [
        .init(voice: "intro", caption: "Hi! This is EditMax", line: "Hi! Let me show you around EditMax. It only takes a minute.", action: .none),
        .init(voice: "import", caption: "Bring in your footage", line: "First, bring in your footage. Drop files on the Media list, or click plus.", action: .importMedia),
        .init(voice: "timeline", caption: "Double-click to add a clip", line: "Double-click a clip to put it on the timeline.", action: .addClips),
        .init(voice: "play", caption: "Space plays it", line: "Press Space to play it back.", keys: ["Space"], action: .play(seconds: 2.6)),
        .init(voice: "cut", caption: "Press S to cut", line: "Put the playhead where you want a cut, and press S.", keys: ["S"], action: .cut),
        .init(voice: "chat", caption: "Or just ask Chat", line: "Or just ask. Tell Chat what you want, and it makes the edit for you. Every change can be undone.",
              action: .askChat("Cut the pauses and add a title")),
        .init(voice: "export", caption: "Export with ⌘E", line: "When it looks right, export it. Your project saves by itself.", keys: ["⌘", "E"], action: .pointAtExport),
        .init(voice: "outro", caption: "Your turn!", line: "That's it. Now go make something great.", action: .outro),
    ]

    /// The clips the demo imports, from the app's resources.
    static let media = ["waves.mp4", "snowboard.mp4", "trail.mp4"]
}

/// Plays the demo's recorded lines. Silent in the unit tests; muted keeps the timing and drops the sound.
@MainActor
final class DemoVoice {
    var enabled = !AppDelegate.isTesting
    var muted = false { didSet { player?.volume = muted ? 0 : 1 } }
    private var player: AVAudioPlayer?

    static func url(_ voice: String) -> URL? {
        for ext in ["m4a", "mp3", "wav"] { if let u = Bundle.main.url(forResource: "demo-\(voice)", withExtension: ext) { return u } }
        return nil
    }

    /// Starts the line and returns how long it lasts; nil without a recording.
    func say(_ voice: String) -> Double? {
        stop()
        guard let url = Self.url(voice), let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        if enabled { p.volume = muted ? 0 : 1; p.prepareToPlay(); p.play(); player = p }
        return p.duration
    }

    func stop() { player?.stop(); player = nil }
}

/// What the demo works with in a project window. Weak: the window owns them.
struct DemoParts {
    weak var document: EditMaxDocument?
    weak var state: EditorState?
    weak var player: PlayerController?
}

struct TourRipple: Identifiable, Equatable {
    let id = UUID()
    let point: CGPoint
}

/// The guide cursor's flight: a quadratic arc that bows upward (or a straight glide), eased at both ends, the pointer
/// turned along the path and a little larger mid-flight.
struct TourFlight: Equatable {
    let from: CGPoint
    let to: CGPoint
    let start: Date
    let duration: Double
    var arc = true

    init(from: CGPoint, to: CGPoint, start: Date, duration: Double? = nil, arc: Bool = true) {
        self.from = from; self.to = to; self.start = start; self.arc = arc
        self.duration = duration ?? min(max(hypot(to.x - from.x, to.y - from.y) / 900, 0.55), 1.2)
    }

    /// Already where it is going.
    static func resting(at p: CGPoint) -> TourFlight { TourFlight(from: p, to: p, start: .distantPast) }

    private var control: CGPoint {
        let d = hypot(to.x - from.x, to.y - from.y)
        return CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - (arc ? min(d * 0.2, 90) : 0))
    }

    /// The pointer's tip, its turn in degrees from the resting pose, its scale, and whether it has landed.
    func sample(at date: Date) -> (point: CGPoint, angle: Double, scale: Double, landed: Bool) {
        let p = min(max(date.timeIntervalSince(start) / duration, 0), 1)
        guard p < 1 else { return (to, 0, 1, true) }
        let t = p * p * (3 - 2 * p)
        let u = 1 - t, c = control
        let point = CGPoint(x: u * u * from.x + 2 * u * t * c.x + t * t * to.x, y: u * u * from.y + 2 * u * t * c.y + t * t * to.y)
        guard arc else { return (point, 0, 1, false) }
        let dx = 2 * u * (c.x - from.x) + 2 * t * (to.x - c.x), dy = 2 * u * (c.y - from.y) + 2 * t * (to.y - c.y)
        // At rest the arrow's tip leads up and to the left (about -112° from +x in top-left coordinates).
        let heading = atan2(dy, dx) * 180 / .pi
        let angle = (dx == 0 && dy == 0) ? 0 : heading - TourPointer.restingHeading
        // Settle back to the resting pose over the last fifth of the flight.
        let settle = p > 0.8 ? (1 - p) / 0.2 : 1
        return (point, angle * settle, 1 + sin(p * .pi) * 0.25, false)
    }
}

@MainActor
final class WelcomeTour: ObservableObject {
    static let shared = WelcomeTour()
    /// Raised when the demo changes enough to play it again for everyone who saw it.
    static let version = 2
    static let completedKey = "tour.completedVersion"
    static let mutedKey = "tour.muted"
    /// Scratch projects live here while the demo plays, never in the library.
    nonisolated static var demoRoot: URL { CodemaxInstaller.supportDirectory.appendingPathComponent("Demo", isDirectory: true) }

    var defaults: UserDefaults = .standard
    /// Tests: the layer goes off screen.
    var offscreen = false
    /// Tests: every wait is this fraction of its length.
    var pace = 1.0
    /// Tests: does each beat's action instead of EditMax.
    var performer: ((DemoBeat) async throws -> Void)?
    let voice = DemoVoice()

    @Published private(set) var flight: TourFlight?
    @Published private(set) var ring: CGRect?
    @Published private(set) var caption = ""
    @Published private(set) var keys: [String] = []
    @Published private(set) var pressed: Set<String> = []
    @Published private(set) var pressing = false
    @Published private(set) var ripples: [TourRipple] = []
    @Published private(set) var shown = false
    @Published var muted = false { didSet { voice.muted = muted; defaults.set(muted, forKey: Self.mutedKey) } }

    private(set) var isRunning = false
    var completed: Bool { defaults.integer(forKey: Self.completedKey) >= Self.version }
    var cursorWindow: NSPanel? { overlay }

    private var parts: [UUID: DemoParts] = [:]
    private var window: NSWindow?
    private var overlay: TourPanel?
    private var task: Task<Void, Never>?
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    private var demoURL: URL?
    private var demoDoc: UUID?
    private var then: (() -> Void)?
    private var startedThisLaunch = false

    // MARK: Project windows

    func register(_ doc: UUID, _ p: DemoParts) { parts[doc] = p }

    func unregister(_ doc: UUID) {
        parts.removeValue(forKey: doc)
        if demoDoc == doc { skip() }   // its window went away
    }

    // MARK: Starting

    /// Debug check: `-EditMaxTourDemo YES` plays the demo at launch even when it was seen, and in a background launch.
    var forced: Bool { UserDefaults.standard.bool(forKey: "EditMaxTourDemo") }

    /// A first launch: the demo not seen yet and no projects of the person's own.
    var wantsFirstRun: Bool {
        guard !AppDelegate.isTesting, !startedThisLaunch, !isRunning else { return false }
        if forced { return true }
        guard !completed else { return false }
        let files = (try? FileManager.default.contentsOfDirectory(at: ProjectLibrary.directory, includingPropertiesForKeys: nil)) ?? []
        return !files.contains { ProjectLibrary.extensions.contains($0.pathExtension.lowercased()) }
    }

    /// After the splash, over Home: plays the demo on a scratch project; `then` runs when it ends or is skipped, at once
    /// when there is no demo to play (a project already open, or not a first launch).
    func startFirstRun(then: @escaping () -> Void) {
        guard wantsFirstRun, NSDocumentController.shared.documents.isEmpty else { if !isRunning { then() }; return }
        startedThisLaunch = true
        play(then: then, delay: 1.2)
    }

    /// Help ▸ Welcome Tour.
    func replay() {
        guard !isRunning else { return }
        play(then: nil, delay: 0)
    }

    /// Scratch projects a quit left behind.
    static func cleanLeftovers() { try? FileManager.default.removeItem(at: demoRoot) }

    private func play(then: (() -> Void)?, delay: Double) {
        isRunning = true
        self.then = then
        muted = defaults.bool(forKey: Self.mutedKey)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
                let (doc, window) = try await self.openDemoProject()
                try await self.run(DemoBeat.script, doc: doc, in: window)
            } catch is CancellationError {
            } catch {
                DebugLog.error("demo", error, [:])
            }
            self.finish(skipped: false)
        }
    }

    /// Writes an empty 16:9 project to a scratch folder, opens it, and waits for its window.
    private func openDemoProject() async throws -> (UUID, NSWindow) {
        let dir = Self.demoRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var p = try Templates.project(named: "YouTube 16:9 1080p")
        p.name = "EditMax demo"
        let url = dir.appendingPathComponent("EditMax demo.emx")
        try EditMaxDocument.encoder.encode(p).write(to: url, options: .atomic)
        demoURL = url
        ProjectLibrary.shared.open(url)
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(100))
            guard let (id, _) = parts.first(where: { $0.value.document?.fileURL?.standardizedFileURL == url.standardizedFileURL }),
                  let window = NSDocumentController.shared.document(for: url)?.windowControllers.first?.window, window.isVisible else { continue }
            try await Task.sleep(for: .milliseconds(700))   // the panes settle
            return (id, window)
        }
        throw EditError.invalid("the demo project did not open")
    }

    // MARK: Playing

    /// Plays `beats` over `window`. The unit tests call it with an offscreen window and a `performer`.
    func run(_ beats: [DemoBeat], doc: UUID?, in window: NSWindow) async throws {
        isRunning = true
        demoDoc = doc
        attach(to: window)
        flight = .resting(at: stageCenter)
        withAnimation(.easeOut(duration: 0.4)) { shown = true }
        DebugLog.event("demo-started", ["version": Self.version])
        try await pause(0.5)
        for beat in beats {
            guard isRunning else { throw CancellationError() }
            let began = Date()
            let said = voice.say(beat.voice)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { caption = beat.caption; keys = beat.keys; pressed = [] }
            if let performer { try await performer(beat) } else { try await perform(beat) }
            let left = (said ?? beat.readingTime) * pace - Date().timeIntervalSince(began)
            if left > 0 { try await Task.sleep(for: .seconds(left)) }
            try await pause(0.35)
        }
    }

    /// Esc, Skip, or the window going away.
    func skip() {
        guard isRunning else { return }
        DebugLog.event("demo-skipped", ["at": caption])
        finish(skipped: true)
    }

    /// Ends the demo either way: the layer goes, the scratch project closes and is deleted, Home comes back, then `then`.
    func finish(skipped: Bool) {
        guard isRunning else { return }
        isRunning = false
        if !skipped { DebugLog.event("demo-finished", [:]) }
        task?.cancel(); task = nil
        voice.stop()
        defaults.set(Self.version, forKey: Self.completedKey)
        if let m = keyMonitor { NSEvent.removeMonitor(m) }; keyMonitor = nil
        if let o = resizeObserver { NotificationCenter.default.removeObserver(o) }; resizeObserver = nil
        withAnimation(.easeOut(duration: 0.25)) { shown = false }
        if let overlay {
            let hide = { [weak overlay] in if let overlay { overlay.parent?.removeChildWindow(overlay); overlay.orderOut(nil) } }
            if offscreen { hide() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: hide) }
        }
        if let doc = demoDoc { parts[doc]?.state?.chat?.input = "" }
        demoDoc = nil
        if let url = demoURL {
            demoURL = nil
            NSDocumentController.shared.document(for: url)?.close()
            // Gone before Home lists projects again, and once more after anything a last autosave wrote.
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: folder)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { try? FileManager.default.removeItem(at: folder) }
            if NSDocumentController.shared.documents.isEmpty { HomeWindow.shared.show() }
        }
        flight = nil; ring = nil; caption = ""; keys = []; pressed = []; ripples = []; pressing = false
        window = nil
        let then = self.then
        self.then = nil
        then?()
    }

    private func attach(to window: NSWindow) {
        self.window = window
        let overlay = self.overlay ?? TourPanel(clickThrough: false)
        overlay.contentView = NSHostingView(rootView: DemoOverlay(tour: self))
        self.overlay = overlay
        if !offscreen { window.addChildWindow(overlay, ordered: .above) }
        layout()
        overlay.orderFront(nil)
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return e }
                if e.keyCode == 53 { self.skip(); return nil }   // Esc
                return e.modifierFlags.contains(.command) ? e : nil   // the demo has the keyboard; ⌘Q and the like still work
            }
        }
    }

    private func layout() {
        guard let window, let overlay else { return }
        overlay.setFrame(offscreen ? CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: window.frame.size) : window.frame, display: true)
    }

    private var stageCenter: CGPoint {
        let s = overlay?.frame.size ?? window?.frame.size ?? .zero
        return CGPoint(x: s.width / 2, y: s.height / 2)
    }

    private func pause(_ s: Double) async throws { try await Task.sleep(for: .seconds(max(0, s * pace))) }

    // MARK: The beats

    private func perform(_ beat: DemoBeat) async throws {
        guard let doc = demoDoc, let p = parts[doc], let document = p.document, let state = p.state, let player = p.player else { return }
        switch beat.action {
        case .none:
            break
        case .importMedia:
            if let r = try await waitFor("media.import") {
                let at = CGPoint(x: r.midX, y: r.midY)
                try await fly(to: at, ring: r)
                try await tap(at: at)   // the + opens a file panel: the demo brings its own clips in instead
            }
            let paths = DemoBeat.media.compactMap { Bundle.main.path(forResource: ($0 as NSString).deletingPathExtension, ofType: "mp4") }
            _ = try await ToolExecutor(document: document, origin: .user).importMedia(paths: paths)
            try await pause(0.6)
        case .addClips:
            for name in DemoBeat.media.prefix(2) {
                guard let r = try await waitFor("media.\(name)") else { continue }
                let at = CGPoint(x: r.minX + min(27, r.width / 2), y: r.midY)   // on the thumbnail
                try await fly(to: at, ring: r)
                try await click("media.\(name)", at: at, in: r, count: 2)
                try await pause(0.45)
            }
        case .play(let seconds):
            guard let r = try await waitFor("toolbar.play") else { break }
            let at = CGPoint(x: r.midX, y: r.midY)
            try await fly(to: at, ring: r)
            press("Space")
            try await click("toolbar.play", at: at, in: r, count: 1)
            try await pause(seconds)
            try await click("toolbar.play", at: at, in: r, count: 1)
        case .cut:
            guard let track = document.project.tracks.first(where: { !$0.clips.isEmpty }), let clip = track.clips.first,
                  let lane = try await waitFor("lane.\(track.name)") else { break }
            let pps = CGFloat(state.pixelsPerSecond)
            func x(_ t: Double) -> CGFloat { lane.minX + CGFloat(t) * pps }
            let on = CGPoint(x: x(clip.start + clip.duration * 0.25), y: lane.midY)
            try await fly(to: on, ring: nil)
            try await tap(at: on)
            state.selectedClipIDs = [clip.id]
            try await pause(0.35)
            // Drag the playhead along the ruler to where the cut goes.
            let rulerY = rect("ruler")?.midY ?? lane.minY - 24
            let cutAt = clip.start + clip.duration * 0.55
            let from = CGPoint(x: x(player.currentTime), y: rulerY), to = CGPoint(x: x(cutAt), y: rulerY)
            try await fly(to: from, ring: nil)
            withAnimation(.easeOut(duration: 0.08)) { pressing = true }
            let glide = TourFlight(from: from, to: to, start: Date(), duration: 0.9, arc: false)
            flight = glide
            while true {
                let s = glide.sample(at: Date())
                document.seekRequest = (time: Double((s.point.x - lane.minX) / pps), play: false)
                if s.landed { break }
                try await Task.sleep(for: .milliseconds(33))
            }
            objectWillChange.send()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { pressing = false }
            try await pause(0.3)
            let mark = CGRect(x: to.x - 1, y: lane.minY, width: 2, height: lane.height)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { ring = Self.ring(around: CGPoint(x: to.x, y: lane.midY), in: mark.insetBy(dx: -12, dy: 0)) }
            press("S")
            _ = try await UIDriver.key("s", modifiers: [], in: window)
            try await pause(0.4)
        case .askChat(let text):
            guard let r = try await chatTab() else { break }
            let at = CGPoint(x: r.midX, y: r.midY)
            try await fly(to: at, ring: r)
            try await click("tab.chat", at: at, in: r, count: 1)
            guard let field = try await waitFor("chat.input"), let chat = state.chat else { break }
            let into = CGPoint(x: field.minX + min(40, field.width / 2), y: field.midY)
            try await fly(to: into, ring: nil)
            try await tap(at: into)
            for ch in text {   // typed as a person would, never sent
                chat.input.append(ch)
                try await pause(Double.random(in: 0.03...0.075))
            }
        case .pointAtExport:
            guard let r = exportButton() else { break }
            try await fly(to: CGPoint(x: r.midX, y: r.midY), ring: r)   // the button opens a save panel: pointed at, not clicked
            press("⌘"); try await pause(0.15); press("E")
        case .outro:
            withAnimation(.easeOut(duration: 0.2)) { ring = nil }
            try await fly(to: stageCenter, ring: nil)
        }
    }

    /// Moves the cursor to `p` along an arc, then rings the control there.
    private func fly(to p: CGPoint, ring r: CGRect?) async throws {
        let from = flight.map { $0.sample(at: Date()).point } ?? p
        withAnimation(.easeOut(duration: 0.15)) { ring = nil }
        let f = TourFlight(from: from, to: p, start: Date())
        flight = f
        try await Task.sleep(for: .seconds(f.duration * pace + 0.02))
        objectWillChange.send()   // landed: the cursor's timeline stops
        if let r { withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) { ring = Self.ring(around: p, in: r) } }
        try await pause(0.18)
    }

    /// The cursor presses: it dips and a ripple spreads from its tip.
    private func tap(at p: CGPoint, count: Int = 1) async throws {
        for i in 0..<count {
            withAnimation(.easeOut(duration: 0.07)) { pressing = true }
            ripples.append(TourRipple(point: p))
            try await Task.sleep(for: .milliseconds(Int(90 * min(pace, 1))))
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { pressing = false }
            if i + 1 < count { try await Task.sleep(for: .milliseconds(Int(80 * min(pace, 1)))) }
        }
        let done = Set(ripples.map(\.id))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.ripples.removeAll { done.contains($0.id) } }
    }

    /// Presses the control, with the cursor's press drawn at the same moment. The control's own handler runs, as the MCP
    /// driver runs it while EditMax is in the background, so the demo behaves the same in front or behind; a control
    /// without one gets an in-process click at the point.
    private func click(_ id: String, at p: CGPoint, in r: CGRect, count: Int) async throws {
        guard let window else { return }
        async let shown: Void = tap(at: p, count: count)
        if let handler = UIRegistry.shared.tap(id, count: count) {
            try await Task.sleep(for: .milliseconds(Int(70 * min(pace, 1))))   // as the press lands
            handler()
        } else {
            let target = try UIDriver.target(.string(id), dx: Double(p.x - r.midX), dy: Double(p.y - r.midY), in: window)
            _ = try await UIDriver.click(target, count: count)
        }
        try await shown
    }

    /// A keycap in the line lights up.
    private func press(_ key: String) {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) { _ = pressed.insert(key) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { _ = self?.pressed.remove(key) }
        }
    }

    // MARK: Where things are

    /// A control's frame in the cursor layer's top-left points.
    private func rect(_ id: String) -> CGRect? {
        guard let window, let overlay, let e = UIRegistry.shared.elements(in: window).visible.first(where: { $0.id == id }) else { return nil }
        return UIDriver.convert(e.rect, from: window, to: overlay)
    }

    private func waitFor(_ id: String) async throws -> CGRect? {
        for _ in 0..<30 {
            if let r = rect(id) { return r }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The Chat tab: the strip is one frame (`inspector.tabs`, padded 12 × 8) of equal tabs 4 points apart; the tabs
    /// themselves only have handlers.
    private func chatTab() async throws -> CGRect? {
        guard let strip = try await waitFor("inspector.tabs") else { return nil }
        return Self.tab(.chat, in: strip)
    }

    static func tab(_ tab: EditorState.InspectorTab, in strip: CGRect) -> CGRect {
        let all = EditorState.InspectorTab.allCases, inner = strip.insetBy(dx: 12, dy: 8)
        let n = CGFloat(all.count), i = CGFloat(all.firstIndex(of: tab) ?? 0)
        let w = (inner.width - 4 * (n - 1)) / n
        return CGRect(x: inner.minX + i * (w + 4), y: inner.minY, width: w, height: inner.height)
    }

    /// Export is a title-bar button: no probe there, so it is found by its tooltip.
    private func exportButton() -> CGRect? {
        guard let window, let overlay, let frameView = window.contentView?.superview,
              let button = Self.find(in: frameView, where: { ($0.toolTip ?? "").hasPrefix("Export the movie") }) else { return nil }
        let screen = window.convertToScreen(button.convert(button.bounds, to: nil))
        return UIDriver.fromBase(overlay.convertFromScreen(screen), overlay)
    }

    private static func find(in v: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(v) { return v }
        for s in v.subviews { if let hit = find(in: s, where: match) { return hit } }
        return nil
    }

    /// An icon-sized box around the point the cursor clicks: never the whole row or tab.
    static func ring(around p: CGPoint, in r: CGRect) -> CGRect {
        let w = min(r.width, 30) + 8, h = min(r.height, 26) + 8
        return CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
    }

    /// The person's own pointer size: the system arrow (without its shadow margin) times the size set in
    /// Accessibility ▸ Display ▸ Pointer.
    static var pointerSize: CGSize {
        let image = NSCursor.arrow.image.size
        let setting = UserDefaults(suiteName: "com.apple.universalaccess")?.double(forKey: "mouseDriverCursorSize") ?? 1
        let s = min(max(setting, 1), 4)
        return CGSize(width: (max(image.width, 14) - 4) * s, height: (max(image.height, 20) - 3) * s)
    }
}

/// A borderless, non-activating child window over the project window.
final class TourPanel: NSPanel {
    init(clickThrough: Bool) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 440, height: 220), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        ignoresMouseEvents = clickThrough
        animationBehavior = .none
    }
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }   // the keyboard stays in the project window
}

// MARK: - The layer

private struct DemoOverlay: View {
    @ObservedObject var tour: WelcomeTour

    var body: some View {
        ZStack(alignment: .bottom) {
            // Clicks land here, not on the project: the demo is driving.
            Color.black.opacity(0.005).contentShape(Rectangle()).onTapGesture {}
            if let f = tour.flight {
                SwiftUI.TimelineView(.animation(minimumInterval: nil, paused: f.sample(at: Date()).landed)) { ctx in
                    let s = f.sample(at: ctx.date)
                    DemoCursorView(tip: s.point, angle: s.angle * 0.35, scale: 1 + (s.scale - 1) * 0.5, ring: tour.ring, caption: tour.caption,
                                   keys: tour.keys, pressed: tour.pressed, pressing: tour.pressing, ripples: tour.ripples)
                }
                .id(f.start)
            }
            DemoSkipPill(muted: $tour.muted, skip: { tour.skip() }).padding(.bottom, 18)
        }
        .opacity(tour.shown ? 1 : 0)
    }
}

/// The pointer, the ring around the control, the ripples and the one-line caption: drawn at given values, so a preview
/// can freeze any moment.
struct DemoCursorView: View {
    let tip: CGPoint
    var angle = 0.0
    var scale = 1.0
    var ring: CGRect?
    var caption = ""
    var keys: [String] = []
    var pressed: Set<String> = []
    var pressing = false
    var ripples: [TourRipple] = []
    var pointer = WelcomeTour.pointerSize

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let ring { DemoRing(rect: ring).transition(.scale(scale: 1.6).combined(with: .opacity)) }
                ForEach(ripples) { DemoRipple(point: $0.point) }
                TourPointer(size: pointer)
                    .scaleEffect(scale * (pressing ? 0.8 : 1), anchor: .topLeading)
                    .rotationEffect(.degrees(angle), anchor: .topLeading)
                    .offset(x: tip.x, y: tip.y)
                if !caption.isEmpty {
                    // Beside the pointer on whichever side has room; the zero-size frame lets the line grow away from it.
                    let left = tip.x + 300 > geo.size.width
                    let up = tip.y + pointer.height + 44 > geo.size.height
                    DemoBubble(caption: caption, keys: keys, pressed: pressed)
                        .frame(width: 0, height: 0, alignment: left ? .trailing : .leading)
                        .offset(x: tip.x + (left ? -10 : pointer.width + 8), y: tip.y + (up ? -16 : pointer.height + 10))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: caption)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: ring)
    }
}

/// The one blue row: what is happening, with the keys for it.
struct DemoBubble: View {
    let caption: String
    var keys: [String] = []
    var pressed: Set<String> = []

    var body: some View {
        HStack(spacing: 7) {
            Text(caption).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            ForEach(keys, id: \.self) { DemoKeycap(label: $0, down: pressed.contains($0)) }
        }
        .padding(.leading, 12).padding(.trailing, keys.isEmpty ? 12 : 5).padding(.vertical, keys.isEmpty ? 6 : 4)
        .background(Capsule().fill(LinearGradient(colors: [Color.accentColor.opacity(0.92), Color.accentColor], startPoint: .top, endPoint: .bottom)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
        .shadow(color: Color.accentColor.opacity(0.45), radius: 12, y: 4)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .fixedSize()
        .id(caption)
        .transition(.asymmetric(insertion: .scale(scale: 0.7, anchor: .leading).combined(with: .opacity), removal: .opacity))
    }
}

struct DemoKeycap: View {
    let label: String
    var down = false
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(down ? .white : Color.accentColor)
            .padding(.horizontal, label.count > 1 ? 7 : 0)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(down ? Color.white.opacity(0.25) : Color.white))
            .shadow(color: .black.opacity(down ? 0 : 0.25), radius: 0, y: down ? 0 : 1.5)
            .offset(y: down ? 1.5 : 0)
            .scaleEffect(down ? 0.92 : 1)
    }
}

/// The box around the icon being clicked, breathing softly.
private struct DemoRing: View {
    let rect: CGRect
    @State private var glow = false
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.12)))
            .shadow(color: Color.accentColor.opacity(glow ? 0.75 : 0.3), radius: glow ? 9 : 4)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { glow = true } }
    }
}

private struct DemoRipple: View {
    let point: CGPoint
    @State private var grown = false
    var body: some View {
        Circle()
            .strokeBorder(Color.accentColor, lineWidth: grown ? 0.5 : 2.5)
            .background(Circle().fill(Color.accentColor.opacity(grown ? 0 : 0.25)))
            .frame(width: grown ? 38 : 6, height: grown ? 38 : 6)
            .opacity(grown ? 0 : 1)
            .position(point)
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { grown = true } }
    }
}

/// Mute and Skip, small, at the foot of the window.
struct DemoSkipPill: View {
    @Binding var muted: Bool
    var skip: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button { muted.toggle() } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 16)
            }
            .buttonStyle(.plain).help(muted ? "Turn the voice on" : "Mute the voice").pointer().uiFrame("demo.mute")
            Divider().frame(height: 12)
            Button(action: skip) {
                HStack(spacing: 6) {
                    Text("Skip demo")
                    Text("esc").font(.system(size: 9.5, weight: .semibold, design: .rounded)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.6), lineWidth: 0.8))
                }
            }
            .buttonStyle(.plain).help("End the demo (Help ▸ Welcome Tour plays it again)").pointer().uiFrame("demo.skip")
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

/// An arrow pointer with its tip at the view's top-left, the size of the person's own pointer: EditMax's accent,
/// outlined in white so it reads on any picture.
struct TourPointer: View {
    /// The direction the tip leads at rest, in degrees from +x with y downwards.
    static let restingHeading = -112.0
    var size = CGSize(width: 13, height: 20)
    var body: some View {
        ArrowShape()
            .fill(Color.accentColor)
            .overlay(ArrowShape().stroke(Color.white, style: StrokeStyle(lineWidth: max(1.2, size.height / 14), lineJoin: .round)))
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .shadow(color: Color.accentColor.opacity(0.5), radius: 7)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private struct ArrowShape: Shape {
        func path(in r: CGRect) -> Path {
            let w = r.width / 16, h = r.height / 24
            var p = Path()
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 0, y: 20 * h))
            p.addLine(to: CGPoint(x: 4.6 * w, y: 15.6 * h))
            p.addLine(to: CGPoint(x: 7.8 * w, y: 23 * h))
            p.addLine(to: CGPoint(x: 10.6 * w, y: 21.8 * h))
            p.addLine(to: CGPoint(x: 7.4 * w, y: 14.6 * h))
            p.addLine(to: CGPoint(x: 13.6 * w, y: 14.6 * h))
            p.closeSubpath()
            return p
        }
    }
}
