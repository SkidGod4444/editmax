import AppKit
import SwiftUI

/// The welcome tour: a card over a project window that teaches a first edit by doing it, one step at a time, while a
/// guide cursor flies to the real control the step is about and points at it. A step finishes on what the person does
/// in EditMax (a file added, playback started, a cut), never on a button alone, and the tour moves on by itself;
/// Next, Back and the dots still go anywhere already reached. It runs once, on the first project window after the
/// crash-report card; Help ▸ Welcome Tour runs it again. No sound.
///
/// The card and the cursor are child windows of the project window, so they move with it and never float over other
/// apps; the cursor's window lets every click through. Where things are comes from `UIRegistry`, the same frames the
/// MCP UI driver uses. The tour never switches a view itself: the Chat step points at the tab and waits for the click.
enum TourStep: Int, CaseIterable, Identifiable {
    case media, timeline, play, split, chat, export
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .media: "Bring in your footage"
        case .timeline: "Put a clip on the timeline"
        case .play: "Play it"
        case .split: "Make a cut"
        case .chat: "Ask for an edit"
        case .export: "Export when it looks right"
        }
    }

    var body: String {
        switch self {
        case .media: "Drag videos, sound or pictures from the Finder onto the Media list, or press + to pick them."
        case .timeline: "Double-click a file in Media to add it to the end of the timeline, or drag it onto a lane."
        case .play: "Space plays and pauses. J, K and L shuttle backwards and forwards."
        case .split: "Click a clip on the timeline, put the playhead where the cut goes, and press S."
        case .chat: "Open Chat and say what you want, like “cut the pauses and add a title”. Every change it makes can be undone."
        case .export: "⌘E renders the movie. Projects save by themselves, so you can close the window any time."
        }
    }

    /// Keycaps on the card; each lights while that key is held.
    var keys: [String] {
        switch self {
        case .play: ["Space"]
        case .split: ["S"]
        case .export: ["⌘", "E"]
        default: []
        }
    }

    /// What the guide cursor says at the control.
    var bubble: String {
        switch self {
        case .media: "Drop files here"
        case .timeline: "Double-click me"
        case .play: "Or click here"
        case .split: "Or the scissors"
        case .chat: "Open Chat"
        case .export: "Export"
        }
    }

    /// The `UIRegistry` id of the control the cursor points at (nil: the toolbar's Export, found in the title bar).
    func target(_ s: TourSnapshot) -> String? {
        switch self {
        case .media: "media.import"
        case .timeline: s.firstAsset.map { "media.\($0)" } ?? "media.import"
        case .play: "toolbar.play"
        case .split: "toolbar.split"
        case .chat: "tab.chat"
        case .export: nil
        }
    }

    /// Whether the person has done the step, from what the window looks like now and when the step began.
    func isDone(_ s: TourSnapshot, since start: TourSnapshot) -> Bool {
        switch self {
        case .media: s.assets > 0
        case .timeline: s.clips > 0
        case .play: s.playing
        case .split: s.clips > start.clips
        case .chat: s.chatOpen
        case .export: s.exporting
        }
    }
}

/// What the tour reads from a project window, four times a second.
struct TourSnapshot: Equatable {
    var assets = 0
    var clips = 0
    var playing = false
    var chatOpen = false
    var exporting = false
    var firstAsset: String?
}

/// Where the tour is: pure, so the tests can walk it.
struct TourProgress: Equatable {
    private(set) var index = 0
    /// The furthest step shown; the dots go back to any of them.
    private(set) var reached = 0
    private(set) var done: Set<Int> = []
    /// Steps that were already done when they came up (a project with media in it): they wait for Next.
    private(set) var foundDone: Set<Int> = []
    private(set) var start = TourSnapshot()

    init(_ s: TourSnapshot) { start = s; checkFoundDone(s) }

    var step: TourStep { TourStep.allCases[index] }
    var isLast: Bool { index == TourStep.allCases.count - 1 }
    var isDone: Bool { done.contains(index) }
    var wasFoundDone: Bool { foundDone.contains(index) }

    /// True the moment the current step is done, by the person while it is showing: only that moves the tour on.
    mutating func observe(_ s: TourSnapshot) -> Bool {
        guard !isDone, step.isDone(s, since: start) else { return false }
        done.insert(index)
        return true
    }

    /// False past the last step: the tour is over.
    mutating func next(_ s: TourSnapshot) -> Bool {
        guard !isLast else { return false }
        go(index + 1, s, force: true)
        return true
    }

    mutating func back(_ s: TourSnapshot) { if index > 0 { go(index - 1, s) } }

    mutating func go(_ i: Int, _ s: TourSnapshot, force: Bool = false) {
        guard TourStep.allCases.indices.contains(i), force || i <= reached, i != index else { return }
        index = i
        reached = max(reached, i)
        start = s
        checkFoundDone(s)
    }

    private mutating func checkFoundDone(_ s: TourSnapshot) {
        guard !done.contains(index), step.isDone(s, since: s) else { return }
        done.insert(index)
        foundDone.insert(index)
    }
}

/// The guide cursor's flight: a quadratic arc that bows upward, eased at both ends, the pointer turned along the path
/// and a little larger mid-flight.
struct TourFlight: Equatable {
    let from: CGPoint
    let to: CGPoint
    let start: Date
    let duration: Double

    init(from: CGPoint, to: CGPoint, start: Date) {
        self.from = from; self.to = to; self.start = start
        duration = min(max(hypot(to.x - from.x, to.y - from.y) / 900, 0.55), 1.2)
    }

    private var control: CGPoint {
        let d = hypot(to.x - from.x, to.y - from.y)
        return CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - min(d * 0.2, 90))
    }

    /// The pointer's tip, its turn in degrees from the resting pose, its scale, and whether it has landed.
    func sample(at date: Date) -> (point: CGPoint, angle: Double, scale: Double, landed: Bool) {
        let p = min(max(date.timeIntervalSince(start) / duration, 0), 1)
        guard p < 1 else { return (to, 0, 1, true) }
        let t = p * p * (3 - 2 * p)
        let u = 1 - t, c = control
        let point = CGPoint(x: u * u * from.x + 2 * u * t * c.x + t * t * to.x, y: u * u * from.y + 2 * u * t * c.y + t * t * to.y)
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
    /// Raised when the tour changes enough to show it again to everyone.
    static let version = 1
    static let completedKey = "tour.completedVersion"

    var defaults: UserDefaults = .standard
    /// Tests: the card and cursor go off screen.
    var offscreen = false
    /// How long a finished step stays before the next one.
    var advanceAfter: TimeInterval = 1.1

    @Published private(set) var progress: TourProgress?
    @Published private(set) var pressed: Set<String> = []
    /// The guide cursor, in the project window's top-left points.
    @Published private(set) var flight: TourFlight?
    @Published private(set) var targetRect: CGRect?
    @Published private(set) var bubble = ""

    var isRunning: Bool { progress != nil }
    var completed: Bool { defaults.integer(forKey: Self.completedKey) >= Self.version }
    var cardWindow: NSPanel? { card }
    var cursorWindow: NSPanel? { overlay }

    private var snapshots: [UUID: () -> TourSnapshot] = [:]
    private var running: (doc: UUID, window: NSWindow)?
    private var card: TourPanel?
    private var overlay: TourPanel?
    private var poll: Timer?
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    private var pendingAdvance: DispatchWorkItem?
    private var keyDownAt: [String: Date] = [:]

    // MARK: Windows that can be toured

    func register(_ doc: UUID, snapshot: @escaping () -> TourSnapshot) { snapshots[doc] = snapshot }

    func unregister(_ doc: UUID) {
        snapshots.removeValue(forKey: doc)
        if running?.doc == doc { close(finished: false) }
    }

    /// A project window appeared: the first one gets the tour, once, after the crash-report card.
    func startIfNeeded(document doc: UUID) {
        let demo = UserDefaults.standard.bool(forKey: "EditMaxTourDemo")   // Debug check: -EditMaxTourDemo YES
        guard !AppDelegate.isTesting, demo || !completed, !isRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.startWhenClear(doc, demo: demo, tries: 0) }
    }

    private func startWhenClear(_ doc: UUID, demo: Bool, tries: Int) {
        guard demo || !completed, !isRunning, snapshots[doc] != nil, tries < 300 else { return }
        // Never under a card, and never while EditMax is in the background (the demo flag starts it there too).
        if TelemetryPrompt.shared.isShowing || UpdatePrompt.shared.isShowing || NSApp.modalWindow != nil || (!demo && !NSApp.isActive) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startWhenClear(doc, demo: demo, tries: tries + 1) }
            return
        }
        guard let window = UIDriver.window, DocumentRegistry.shared.activeID == doc || demo else { return }
        start(doc, in: window)
    }

    /// Help ▸ Welcome Tour: from the start, on the project in front.
    func replay() {
        guard let doc = DocumentRegistry.shared.activeID, let window = UIDriver.window else { return }
        close(finished: false)
        start(doc, in: window)
    }

    // MARK: Running

    func start(_ doc: UUID, in window: NSWindow) {
        guard let read = snapshots[doc] else { return }
        running = (doc, window)
        progress = TourProgress(read())
        let card = self.card ?? TourPanel(clickThrough: false)
        let overlay = self.overlay ?? TourPanel(clickThrough: true)
        card.contentView = NSHostingView(rootView: TourCardHost(tour: self))
        overlay.contentView = NSHostingView(rootView: TourCursorHost(tour: self))
        self.card = card; self.overlay = overlay
        if !offscreen {
            window.addChildWindow(card, ordered: .above)
            window.addChildWindow(overlay, ordered: .above)   // after the card: the cursor flies over it
        }
        layoutWindows()
        card.orderFront(nil); overlay.orderFront(nil)
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutWindows(); self?.aim(fly: false) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            MainActor.assumeIsolated { self?.noteKey(e) }
            return e   // only watched, never taken
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        DebugLog.event("tour-started", ["version": Self.version])
        aim(fly: true, from: cardEdge())
    }

    func next() {
        guard var p = progress, let s = read() else { return }
        pendingAdvance?.cancel()
        if p.next(s) { progress = p; aim(fly: true) } else { close(finished: true) }
    }

    func back() {
        guard var p = progress, let s = read() else { return }
        pendingAdvance?.cancel()
        p.back(s); progress = p; aim(fly: true)
    }

    func go(_ i: Int) {
        guard var p = progress, let s = read() else { return }
        pendingAdvance?.cancel()
        p.go(i, s); progress = p; aim(fly: true)
    }

    /// Done, the close button, or the window going away. The tour counts as seen either way; Help runs it again.
    func close(finished: Bool) {
        guard running != nil || progress != nil else { return }
        if let step = progress?.step { DebugLog.event("tour-closed", ["finished": finished, "at": "\(step)"]) }
        defaults.set(Self.version, forKey: Self.completedKey)
        pendingAdvance?.cancel(); pendingAdvance = nil
        poll?.invalidate(); poll = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }; keyMonitor = nil
        if let o = resizeObserver { NotificationCenter.default.removeObserver(o) }; resizeObserver = nil
        for w in [card, overlay].compactMap({ $0 }) { w.parent?.removeChildWindow(w); w.orderOut(nil) }
        running = nil; progress = nil; flight = nil; targetRect = nil; pressed = []
    }

    private func read() -> TourSnapshot? { running.flatMap { snapshots[$0.doc]?() } }

    private func tick() {
        guard var p = progress, let s = read() else { return }
        if p.observe(s) {
            progress = p
            let at = p.index
            let work = DispatchWorkItem { [weak self] in if self?.progress?.index == at { self?.next() } }
            pendingAdvance = work
            DispatchQueue.main.asyncAfter(deadline: .now() + advanceAfter, execute: work)
        }
        aim(fly: false)   // a control that moved (a resize, a list that scrolled) keeps the cursor on it
    }

    private func noteKey(_ e: NSEvent) {
        switch e.type {
        case .flagsChanged:
            if e.modifierFlags.contains(.command) { pressed.insert("⌘") } else { pressed.remove("⌘") }
        case .keyDown, .keyUp:
            let k = e.keyCode == 49 ? "Space" : (e.charactersIgnoringModifiers ?? "").uppercased()
            guard e.type == .keyDown else { pressed.remove(k); return }
            pressed.insert(k)
            // A key pressed with ⌘ sends no key-up: let it go out by itself unless it is still repeating.
            keyDownAt[k] = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let at = self.keyDownAt[k], Date().timeIntervalSince(at) >= 0.55 else { return }
                self.pressed.remove(k)
            }
        default: break
        }
    }

    // MARK: Where things go

    /// Points the cursor at the current step's control: a new flight when the step changed, else a quiet follow.
    private func aim(fly: Bool, from: CGPoint? = nil) {
        guard let p = progress, let s = read(), let window = running?.window, let overlay else { return }
        let rect = targetRect(for: p.step, s, in: window, overlay: overlay)
        bubble = p.step.bubble
        guard let rect else { targetRect = nil; return }
        let tip = Self.tip(on: rect)
        if fly || flight == nil {
            let origin = from ?? flight.map { $0.sample(at: Date()).point } ?? cardEdge() ?? tip
            let f = TourFlight(from: origin, to: tip, start: Date())
            flight = f
            targetRect = rect
            // Landed: draw once more so the cursor's timeline stops (it runs only while the cursor moves).
            DispatchQueue.main.asyncAfter(deadline: .now() + f.duration + 0.05) { [weak self] in if self?.flight == f { self?.objectWillChange.send() } }
        } else if rect != targetRect, let f = flight, f.sample(at: Date()).landed {
            flight = TourFlight(from: f.to, to: tip, start: Date().addingTimeInterval(-10))   // already there: no swoop
            targetRect = rect
        }
    }

    /// Where the tip lands: just inside the control's lower right, so the arrow sits beside it and the label stays readable.
    static func tip(on r: CGRect) -> CGPoint {
        CGPoint(x: r.maxX - min(r.width * 0.3, 12), y: r.maxY - min(r.height * 0.3, 6))
    }

    private func targetRect(for step: TourStep, _ s: TourSnapshot, in window: NSWindow, overlay: NSWindow) -> CGRect? {
        if let id = step.target(s) {
            guard let placed = UIRegistry.shared.elements(in: window).visible.first(where: { $0.id == id }) else { return nil }
            return UIDriver.convert(placed.rect, from: window, to: overlay)
        }
        // Export is a title-bar button: no probe there, so find it by its tooltip.
        guard let frameView = window.contentView?.superview, let button = Self.find(in: frameView, where: { ($0.toolTip ?? "").hasPrefix("Export the movie") }) else { return nil }
        let screen = window.convertToScreen(button.convert(button.bounds, to: nil))
        return UIDriver.fromBase(overlay.convertFromScreen(screen), overlay)
    }

    private static func find(in v: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(v) { return v }
        for s in v.subviews { if let hit = find(in: s, where: match) { return hit } }
        return nil
    }

    /// The card's left edge, in the cursor window's points: where the cursor sets off from at the start.
    private func cardEdge() -> CGPoint? {
        guard let card, let overlay else { return nil }
        let r = UIDriver.fromBase(overlay.convertFromScreen(card.frame), overlay)
        return CGPoint(x: r.minX + 40, y: r.midY)
    }

    private func layoutWindows() {
        guard let window = running?.window, let card, let overlay else { return }
        let frame = offscreen ? CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: window.frame.size) : window.frame
        overlay.setFrame(frame, display: true)
        let size = card.contentView?.fittingSize ?? CGSize(width: 440, height: 220)
        let bounds = CGRect(origin: .zero, size: frame.size)
        let local = Self.cardPlace(size: size, in: bounds, avoiding: targetRect)
        let screen = overlay.convertToScreen(UIDriver.toBase(CGRect(origin: local, size: size), overlay))
        card.setFrame(screen, display: true)
    }

    /// The card's top-left in the window's top-left points: over the picture near the top, else the middle, else the
    /// bottom, whichever keeps clear of the control the cursor points at (and room for its label).
    static func cardPlace(size: CGSize, in bounds: CGRect, avoiding target: CGRect?) -> CGPoint {
        let mid = bounds.midX - size.width / 2, shift = size.width * 0.45
        let top = bounds.minY + bounds.height * 0.12
        let candidates = [CGPoint(x: mid, y: top), CGPoint(x: mid + shift, y: top), CGPoint(x: mid - shift, y: top),
                          CGPoint(x: mid, y: bounds.midY - size.height / 2), CGPoint(x: mid, y: bounds.maxY - size.height - 24)]
            .map { CGPoint(x: min(max($0.x, bounds.minX), bounds.maxX - size.width), y: $0.y) }
        guard let target else { return candidates[0] }
        let keepOut = target.insetBy(dx: -150, dy: -40)
        return candidates.first { !CGRect(origin: $0, size: size).intersects(keepOut) } ?? candidates[0]
    }

    /// A step change may move the card out of the new target's way.
    func relayoutCard() { layoutWindows() }
}

/// A borderless, non-activating child window: the card (clickable) or the cursor layer (click-through).
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
    override var canBecomeKey: Bool { false }   // the keyboard stays in the project window, where the steps happen
}

// MARK: - The card

private struct TourCardHost: View {
    @ObservedObject var tour: WelcomeTour
    var body: some View {
        if let p = tour.progress {
            TourCardView(progress: p, pressed: tour.pressed, next: { tour.next() }, back: { tour.back() }, go: { tour.go($0) },
                         close: { tour.close(finished: false) })
                .onChange(of: p.index) { _, _ in DispatchQueue.main.async { tour.relayoutCard() } }
        }
    }
}

struct TourCardView: View {
    let progress: TourProgress
    var pressed: Set<String> = []
    var next: () -> Void = {}
    var back: () -> Void = {}
    var go: (Int) -> Void = { _ in }
    var close: () -> Void = {}

    private var step: TourStep { progress.step }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Welcome tour").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text("\(step.rawValue + 1) of \(TourStep.allCases.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("End the tour (Help ▸ Welcome Tour shows it again)")
                    .pointer().uiFrame("tour.close").uiTap("tour.close", close)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).font(.title3.weight(.semibold))
                Text(step.body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(step.keys, id: \.self) { k in TourKeycap(label: k, lit: pressed.contains(k)) }
                if !step.keys.isEmpty { Spacer().frame(width: 4) }
                status
                Spacer(minLength: 0)
            }
            .frame(minHeight: 26)
            HStack(spacing: 10) {
                dots
                Spacer(minLength: 12)
                if step.rawValue > 0 {
                    Button("Back", action: back).buttonStyle(.link).font(.callout).pointer().uiFrame("tour.back").uiTap("tour.back", back)
                }
                GlassGroup(spacing: 10) {
                    Button(progress.isLast ? "Done" : "Next", action: next)
                        .glassButtonStyle(prominent: progress.isDone || progress.isLast).controlSize(.large)
                        .pointer().uiFrame("tour.next").uiTap("tour.next", next)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.controlActiveState, .key)   // the panel is never key; Next still draws in color
        .padding(24)   // room for the shadow
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: progress)
    }

    @ViewBuilder private var status: some View {
        if progress.isDone {
            Label(progress.wasFoundDone ? "Already done" : "Nice", systemImage: "checkmark.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(.green)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            Text(step.keys.isEmpty ? "Your turn" : "Your turn: press it").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(TourStep.allCases) { s in
                let reached = s.rawValue <= progress.reached
                Circle()
                    .fill(s == step ? Color.accentColor : Color.primary.opacity(reached ? 0.35 : 0.12))
                    .frame(width: s == step ? 8 : 6, height: s == step ? 8 : 6)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
                    .onTapGesture { if reached { go(s.rawValue) } }
                    .help(reached ? "Step \(s.rawValue + 1): \(s.title)" : "Step \(s.rawValue + 1), not reached yet")
                    .pointer().uiFrame("tour.dot.\(s.rawValue + 1)")
                    .uiTap("tour.dot.\(s.rawValue + 1)") { if reached { go(s.rawValue) } }
            }
        }
    }
}

private struct TourKeycap: View {
    let label: String
    let lit: Bool
    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(lit ? Color.white : Color.primary)
            .padding(.horizontal, label.count > 1 ? 10 : 0)
            .frame(minWidth: 26, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(lit ? Color.accentColor : Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(lit ? 0 : 0.18), lineWidth: 1))
            .offset(y: lit ? 1 : 0)
            .animation(.easeOut(duration: 0.08), value: lit)
    }
}

// MARK: - The guide cursor

private struct TourCursorHost: View {
    @ObservedObject var tour: WelcomeTour
    var body: some View {
        if let flight = tour.flight, let target = tour.targetRect {
            SwiftUI.TimelineView(.animation(minimumInterval: nil, paused: flight.sample(at: Date()).landed)) { ctx in
                let s = flight.sample(at: ctx.date)
                TourCursorView(tip: s.point, angle: s.angle, scale: s.scale, target: s.landed ? target : nil, bubble: s.landed ? tour.bubble : nil)
            }
            .id(flight.start)   // a new flight restarts the timeline
        }
    }
}

/// The pointer, the ring around the control, and the label: drawn at given values, so a preview can freeze any moment.
struct TourCursorView: View {
    let tip: CGPoint
    var angle: Double = 0
    var scale: Double = 1
    var target: CGRect?
    var bubble: String?
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let target {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.10)))
                        .shadow(color: Color.accentColor.opacity(pulse ? 0.7 : 0.25), radius: pulse ? 10 : 4)
                        .frame(width: target.width + 10, height: target.height + 10)
                        .position(x: target.midX, y: target.midY)
                        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
                        .transition(.opacity)
                }
                TourPointer()
                    .scaleEffect(scale, anchor: .topLeading)
                    .rotationEffect(.degrees(angle), anchor: .topLeading)
                    .offset(x: tip.x, y: tip.y)
                if let bubble, !bubble.isEmpty {
                    // Beside the tip, on whichever side has room; the zero-width frame lets the text grow away from it.
                    let leftward = tip.x + 200 > geo.size.width
                    Text(bubble)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        .fixedSize()
                        .frame(width: 0, height: 0, alignment: leftward ? .trailing : .leading)
                        .offset(x: tip.x + (leftward ? -6 : 24), y: tip.y + 30)
                        .transition(.scale(scale: 0.5, anchor: leftward ? .trailing : .leading).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: bubble)
    }
}

/// An arrow pointer with its tip at the view's top-left: EditMax's accent, outlined in white so it reads on any picture.
struct TourPointer: View {
    /// The direction the tip leads at rest, in degrees from +x with y downwards.
    static let restingHeading = -112.0
    var body: some View {
        ArrowShape()
            .fill(Color.accentColor)
            .overlay(ArrowShape().stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
            .frame(width: 21, height: 31)   // larger than the Mac's own pointer, so the two are never confused
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
            .shadow(color: Color.accentColor.opacity(0.55), radius: 9)
            .frame(width: 21, height: 31, alignment: .topLeading)
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
