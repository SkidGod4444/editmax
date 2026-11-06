import SwiftUI
import AppKit
import MCP
import ScreenCaptureKit

/// Where things are on screen, so an agent can drive the real UI through the MCP server (`ui_layout`, `ui_drag`,
/// `ui_click`, `ui_select`, `ui_key`, `ui_scroll`, `ui_screenshot`). Views mark themselves with `.uiFrame("id")`,
/// `.uiTap("id")` and `.uiDrag("id")`; each puts a zero-size AppKit probe behind the view.
///
/// Nothing here is a copy of what a view once said. The registry keeps weak references to the live probes and asks them
/// at the moment of the call: where the view is now, how much of it a user can see, which closure it would run now. A
/// view that is gone, scrolled away or moved can therefore never leave a stale frame or an old closure behind (a stale
/// closure deleted the wrong grade layer after a reorder; stale frames sent clicks to removed or moved controls).
/// Frames are in window points with the origin at the top-left of the window's content.
@MainActor
final class UIRegistry {
    static let shared = UIRegistry()

    private let probes = NSHashTable<UIProbeView>.weakObjects()
    private var serial = 0
    fileprivate func add(_ p: UIProbeView) { serial += 1; p.serial = serial; probes.add(p) }
    /// Probes whose view is on screen in some window, newest first (when two views share an id, the newer one wins).
    fileprivate var live: [UIProbeView] { probes.allObjects.filter { $0.window != nil && !$0.id.isEmpty }.sorted { $0.serial > $1.serial } }

    /// Frames set by hand rather than by a view (tests), in the driver window's points.
    private var fixed: [String: CGRect] = [:]
    func set(_ id: String, _ frame: CGRect) { fixed[id] = frame }
    func remove(_ id: String) { fixed.removeValue(forKey: id) }
    /// Tap handlers registered by code rather than by a view (the notch drawer's `drawer.open`); they stay until removed.
    private var fixedTaps: [String: [Int: () -> Void]] = [:]
    func setTap(_ id: String, count: Int, _ handler: @escaping () -> Void) { fixedTaps[id, default: [:]][count] = handler }
    func removeTap(_ id: String) { fixedTaps.removeValue(forKey: id) }

    var keyHandler: ((NSEvent) -> Bool)?
    /// The player time of each open document, for inspect_timeline.
    var playheads: [UUID: () -> Double?] = [:]
    /// Whether each open document's player is running, for the interaction log's `playing` field.
    var playing: [UUID: () -> Bool] = [:]
    var anyPlaying: Bool { playing.values.contains { $0() } }
    /// Modifier keys the driver pretends are held while it calls a handler directly (⇧ for multi-select, ⌥ for free drags).
    var modifiers: NSEvent.ModifierFlags?
    var currentModifiers: NSEvent.ModifierFlags { modifiers ?? NSEvent.modifierFlags }

    /// One element as a user would see it: `rect` in the driver window's points, `local` in the points of the window it
    /// is drawn in (a popover's own window, say), which is where a click for it must be posted.
    struct Placed { let id: String; let rect: CGRect; let window: NSWindow; let local: CGRect }

    /// The visible elements of `root` and of the windows attached to it (popovers, sheets), and the ids registered there
    /// that a user cannot see now (scrolled out of their scroll view, outside the window, hidden).
    func elements(in root: NSWindow) -> (visible: [Placed], hidden: [String]) {
        let windows = UIDriver.tree(root)
        var best: [String: Placed] = [:], seen = Set<String>()
        for p in live where p.framed {
            guard let w = p.window, windows.contains(where: { $0 === w }) else { continue }
            switch UIDriver.visibility(of: p) {
            case .visible(let local) where best[p.id] == nil:
                best[p.id] = Placed(id: p.id, rect: UIDriver.convert(local, from: w, to: root), window: w, local: local)
            case .clipped: seen.insert(p.id)
            default: break   // not drawn at all (a removed row SwiftUI keeps hidden for reuse): not an element
            }
        }
        for (id, r) in fixed where best[id] == nil { best[id] = Placed(id: id, rect: r, window: root, local: r) }
        return (Array(best.values), seen.subtracting(best.keys).sorted())
    }

    /// The visible elements drawn in `window` itself, in its own points (the interaction log's view of a real click).
    func elements(of window: NSWindow) -> [Placed] {
        var best: [String: Placed] = [:]
        for p in live where p.framed && p.window === window && best[p.id] == nil {
            if let local = UIDriver.visibleRect(of: p) { best[p.id] = Placed(id: p.id, rect: local, window: window, local: local) }
        }
        if window === UIDriver.window { for (id, r) in fixed where best[id] == nil { best[id] = Placed(id: id, rect: r, window: window, local: r) } }
        return Array(best.values)
    }

    /// What a user can see in the driver window, by id.
    var frames: [String: CGRect] {
        guard let w = UIDriver.window else { return fixed }
        return Dictionary(elements(in: w).visible.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
    }
    func frame(_ id: String) -> CGRect? { frames[id] }

    private func rects(in window: NSWindow?) -> [(id: String, rect: CGRect)] {
        window.map { elements(of: $0).map { ($0.id, $0.local) } } ?? frames.map { ($0.key, $0.value) }
    }
    /// The smallest visible element containing `point` (in `window`'s points; the driver window when nil).
    func element(at point: CGPoint, in window: NSWindow? = nil) -> String? {
        rects(in: window).filter { $0.rect.contains(point) }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.id
    }
    /// The visible element closest to a point that hit nothing, when it is within `within` points: the log's record of a
    /// near miss ("hit nothing, 9 pt from preview.compareDivider" is how a hard-to-grab control shows up).
    func nearest(to point: CGPoint, within: CGFloat, in window: NSWindow? = nil) -> (id: String, distance: CGFloat)? {
        var best: (String, CGFloat)?
        for (id, f) in rects(in: window) {
            let dx = max(f.minX - point.x, 0, point.x - f.maxX), dy = max(f.minY - point.y, 0, point.y - f.maxY)
            let d = hypot(dx, dy)
            if d <= within, d < (best?.1 ?? .infinity) { best = (id, d) }
        }
        return best.map { (id: $0.0, distance: $0.1) }
    }

    /// The closure the view registered as `id` would run now for a `count`-click (views that react through a SwiftUI
    /// gesture: bars select on tap, media rows append on double-click).
    func tap(_ id: String, count: Int) -> (() -> Void)? {
        live.first { $0.id == id && $0.taps[count] != nil }?.taps[count] ?? fixedTaps[id]?[count]
    }
    func hasTap(_ id: String) -> Bool { live.contains { $0.id == id && !$0.taps.isEmpty } || fixedTaps[id] != nil }

    /// Views that can apply a horizontal drag themselves (timeline bars: move and the two trim edges). The driver calls
    /// these when EditMax is not the active app, since SwiftUI gestures only run in the active app. By id, else the
    /// smallest visible element containing `point` (in `window`'s points) that has one: a trim handle lies inside its
    /// bar, so the smaller frame is the more specific one.
    func dragHandler(id: String?, at point: CGPoint, in window: NSWindow) -> (String, (CGFloat) -> Void)? {
        let handlers = live.filter { $0.drag != nil }
        if let id, let h = handlers.first(where: { $0.id == id })?.drag { return (id, h) }
        let hits = elements(of: window).compactMap { e -> (String, (CGFloat) -> Void, CGFloat)? in
            guard e.local.contains(point), let h = handlers.first(where: { $0.id == e.id })?.drag else { return nil }
            return (e.id, h, e.local.width * e.local.height)
        }
        return hits.min { $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }

    /// The newest live probe drawn for `id` in `root` or a window attached to it, visible or not (ui_scroll uses it to
    /// bring a scrolled-away element into view).
    fileprivate func probe(_ id: String, in root: NSWindow) -> UIProbeView? {
        let windows = UIDriver.tree(root)
        return live.first { p in p.framed && p.id == id && windows.contains { $0 === p.window } }
    }
}

/// The AppKit view behind a `.uiFrame`, `.uiTap` or `.uiDrag`: it fills the view it marks, so its place in the window is
/// the view's place, and it holds the closures the view gave it on its latest update.
final class UIProbeView: NSView {
    var id = ""
    var framed = false
    var taps: [Int: () -> Void] = [:]
    var drag: ((CGFloat) -> Void)?
    fileprivate(set) var serial = 0
    override var isFlipped: Bool { true }
    /// It marks a place; it never takes a click from the control it sits behind.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct UIProbe: NSViewRepresentable {
    let id: String
    var framed = false
    var tapCount = 0
    var tap: (() -> Void)? = nil
    var drag: ((CGFloat) -> Void)? = nil
    func makeNSView(context: Context) -> UIProbeView { let v = UIProbeView(); apply(v); UIRegistry.shared.add(v); return v }
    /// SwiftUI calls this whenever the view that owns the modifier is drawn again (a closure never compares equal), so
    /// the probe always holds the closure and id of the latest update: after a list reorders, row 1's probe runs row 1's
    /// code. Nothing at the call site has to say when to re-register.
    func updateNSView(_ v: UIProbeView, context: Context) { apply(v) }
    static func dismantleNSView(_ v: UIProbeView, coordinator: ()) { v.id = ""; v.taps = [:]; v.drag = nil }
    private func apply(_ v: UIProbeView) {
        v.id = id; v.framed = framed
        v.taps = tap.map { [tapCount: $0] } ?? [:]
        v.drag = drag
    }
}

extension View {
    /// Registers this view's place under `id` for the MCP UI driver.
    func uiFrame(_ id: String) -> some View { background(UIProbe(id: id, framed: true)) }
    /// Lets the MCP UI driver apply a horizontal drag of `dx` points to this view without a mouse gesture. The closure is
    /// taken fresh on every update; `key` is no longer needed and is ignored.
    func uiDrag(_ id: String, key: String = "", _ handler: @escaping (CGFloat) -> Void) -> some View { background(UIProbe(id: id, drag: handler)) }
    /// Lets the MCP UI driver click this view (a tap gesture) without a mouse event. The closure is taken fresh on every
    /// update, so it is never an older row's; `key` is no longer needed and is ignored.
    func uiTap(_ id: String, count: Int = 1, key: String = "", _ handler: @escaping () -> Void) -> some View { background(UIProbe(id: id, tapCount: count, tap: handler)) }
}

/// Posts mouse events to EditMax's own windows through the app's event queue. They never leave the process, so they
/// cannot land in another app; the real cursor does not move. The driver never activates EditMax: when it is not the
/// active app, clicks and drags go to the control's own `.uiTap`/`.uiDrag` handler where it has one, and plain controls
/// take posted events without activation (`acceptFirstMouse`).
@MainActor
enum UIDriver {
    struct Point: Codable { var x: Double, y: Double }
    /// `window` names the window the element is drawn in when it is not the editor window itself ("popover", "sheet").
    struct Element: Codable { var id: String, x: Double, y: Double, width: Double, height: Double; var window: String? }
    /// `hidden`: ids registered in the window that a user cannot see now (scrolled away, outside the window, hidden).
    struct Layout: Codable { var window: Point, elements: [Element]; var hidden: [String]? }

    /// Tests point the driver at their own off-screen window.
    static var pinned: NSWindow?

    /// The window the driver works on: the key or main window when it is on screen, else the frontmost titled window.
    /// With the app in the background there is no key window, and the first visible window can be the menu bar icon's.
    /// A popover or sheet that is key counts as the window it is attached to: frames are always in that window's points.
    static var window: NSWindow? {
        if let pinned { return pinned }
        func onScreen(_ w: NSWindow?) -> NSWindow? {
            w.flatMap { $0.isVisible && $0.windowNumber > 0 && $0.contentView != nil && !($0 is NotchDrawerPanel) ? topLevel($0) : nil }
        }
        return onScreen(NSApp.keyWindow) ?? onScreen(NSApp.mainWindow)
            ?? NSApp.orderedWindows.first { onScreen($0) != nil && $0.styleMask.contains(.titled) && topLevel($0) === $0 }
            ?? NSApp.windows.first { onScreen($0) != nil && $0.styleMask.contains(.titled) && topLevel($0) === $0 }
    }

    static func requireWindow() throws -> NSWindow {
        guard let w = window, w.contentView != nil else { throw EditError.invalid("no EditMax window is open") }
        return w
    }

    private static func topLevel(_ w: NSWindow) -> NSWindow {
        var x = w
        while let p = x.parent ?? x.sheetParent { x = p }
        return x
    }

    /// `root` and the visible windows attached to it (popovers and other child windows, sheets), back to front.
    static func tree(_ root: NSWindow) -> [NSWindow] {
        var out = [root]
        func add(_ w: NSWindow) {
            for c in (w.childWindows ?? []) + w.sheets where c.isVisible && c.contentView != nil && !out.contains(where: { $0 === c }) {
                out.append(c); add(c)
            }
        }
        add(root)
        return out
    }

    static func kind(_ w: NSWindow) -> String {
        if w.sheetParent != nil { return "sheet" }
        return NSStringFromClass(type(of: w)).contains("Popover") ? "popover" : "child window"
    }

    // MARK: Geometry

    /// How much of a view a user can see: the visible part in its window's content points (top-left origin), clipped by
    /// every scroll view and clipping ancestor and by the window; `clipped` when it is drawn but all of it is scrolled
    /// away or outside the window (scrolling can bring it back); `notShown` when it is not drawn at all.
    enum Visibility { case visible(CGRect), clipped, notShown }
    static func visibility(of v: NSView) -> Visibility {
        guard let w = v.window, let content = w.contentView, !v.isHiddenOrHasHiddenAncestor, v.alphaValue > 0.01 else { return .notShown }
        var r = v.convert(v.bounds, to: nil)
        var a = v.superview
        while let s = a {
            if s.alphaValue <= 0.01 { return .notShown }
            if s is NSClipView || s.clipsToBounds { r = r.intersection(s.convert(s.bounds, to: nil)) }
            a = s.superview
        }
        r = r.intersection(content.convert(content.bounds, to: nil))
        guard !r.isNull, r.width > 0, r.height > 0 else { return .clipped }
        return .visible(fromBase(r, w))
    }
    static func visibleRect(of v: NSView) -> CGRect? {
        if case .visible(let r) = visibility(of: v) { return r }
        return nil
    }

    /// Window content points (top-left origin) to the window's base coordinates (bottom-left origin, what NSEvent uses).
    static func toBase(_ r: CGRect, _ w: NSWindow) -> CGRect {
        guard let c = w.contentView else { return r }
        return c.convert(CGRect(x: r.minX, y: c.isFlipped ? r.minY : c.bounds.height - r.maxY, width: r.width, height: r.height), to: nil)
    }
    static func fromBase(_ r: CGRect, _ w: NSWindow) -> CGRect {
        guard let c = w.contentView else { return r }
        let l = c.convert(r, from: nil)
        return CGRect(x: l.minX, y: c.isFlipped ? l.minY : c.bounds.height - l.maxY, width: l.width, height: l.height)
    }
    /// A rect in `a`'s content points to `b`'s, through the screen (a popover's controls in the editor window's points).
    static func convert(_ r: CGRect, from a: NSWindow, to b: NSWindow) -> CGRect {
        a === b ? r : fromBase(b.convertFromScreen(a.convertToScreen(toBase(r, a))), b)
    }
    static func convert(_ p: CGPoint, from a: NSWindow, to b: NSWindow) -> CGPoint {
        convert(CGRect(origin: p, size: .zero), from: a, to: b).origin
    }
    private static func contains(_ w: NSWindow, _ local: CGPoint) -> Bool {
        guard let c = w.contentView else { return false }
        return CGRect(origin: .zero, size: c.bounds.size).contains(local)
    }

    // MARK: Layout and targets

    static func layout(prefix: String?, in root: NSWindow? = nil) throws -> Layout {
        let w = try root ?? requireWindow()
        w.contentView?.layoutSubtreeIfNeeded()   // a change that just landed has its final place
        let els = UIRegistry.shared.elements(in: w)
        let keep = { (id: String) in prefix.map { id.hasPrefix($0) } ?? true }
        let shown = els.visible.filter { keep($0.id) }.map {
            Element(id: $0.id, x: r($0.rect.minX), y: r($0.rect.minY), width: r($0.rect.width), height: r($0.rect.height), window: $0.window === w ? nil : kind($0.window))
        }.sorted { $0.id < $1.id }
        let hidden = els.hidden.filter(keep)
        let size = w.contentView?.bounds.size ?? .zero
        return Layout(window: Point(x: Double(size.width), y: Double(size.height)), elements: shown, hidden: hidden.isEmpty ? nil : hidden)
    }

    /// Where a click, drag or selection goes: the window that draws it (the editor, or a popover or sheet over it) and the
    /// point in that window's own points; `point` is the same place in the editor window's points, for messages.
    struct Target {
        var id: String?
        var window: NSWindow
        var local: CGPoint
        var point: CGPoint
        /// The element's visible part in `window`'s points (a 1-point square for a bare point).
        var area: CGRect
        /// An element with a tap handler and no place on screen (tab.history, …): only its handler can be called.
        var handlerOnly = false
        @MainActor var place: String { "(\(Int(point.x)), \(Int(point.y)))" + (window === UIDriver.window || handlerOnly ? "" : " in the \(kind(window))") }
    }

    /// Resolves "element id" (the centre of its visible part, plus an optional offset) or {x, y} in the editor window's
    /// points. Fails, saying why, when the place cannot be clicked: an element scrolled out of view or hidden, a point
    /// outside the window.
    static func target(_ v: Value?, dx: Double, dy: Double, in root: NSWindow? = nil) throws -> Target {
        let root = try root ?? requireWindow()
        root.contentView?.layoutSubtreeIfNeeded()
        if let id = v?.stringValue {
            let els = UIRegistry.shared.elements(in: root)
            if let e = els.visible.first(where: { $0.id == id }) {
                let local = CGPoint(x: e.local.midX + dx, y: e.local.midY + dy)
                let point = CGPoint(x: e.rect.midX + dx, y: e.rect.midY + dy)
                guard contains(e.window, local) else {
                    throw EditError.invalid("the offset puts the point (\(Int(point.x)), \(Int(point.y))) outside the \(e.window === root ? "window" : kind(e.window)); '\(id)' is at \(Int(e.rect.minX)), \(Int(e.rect.minY)), \(Int(e.rect.width))×\(Int(e.rect.height))")
                }
                return Target(id: id, window: e.window, local: local, point: point, area: e.local)
            }
            if els.hidden.contains(id) {
                throw EditError.invalid("'\(id)' is not visible now (scrolled out of view, outside the window or hidden), so a click could not land on it. ui_scroll {\"target\": \"\(id)\"} scrolls it into view")
            }
            if UIRegistry.shared.hasTap(id) {
                return Target(id: id, window: root, local: CGPoint(x: -1, y: -1), point: CGPoint(x: -1, y: -1), area: .zero, handlerOnly: true)
            }
            throw EditError.notFound("ui element '\(id)'. ui_layout lists what is on screen")
        }
        if let o = v?.objectValue, let x = o["x"]?.doubleValue ?? o["x"]?.intValue.map(Double.init), let y = o["y"]?.doubleValue ?? o["y"]?.intValue.map(Double.init) {
            let p = CGPoint(x: x + dx, y: y + dy)
            // The front-most window at that place takes it: a popover over the editor, a sheet, else the editor.
            for w in tree(root).reversed() {
                let local = convert(p, from: root, to: w)
                if contains(w, local) { return Target(id: nil, window: w, local: local, point: p, area: CGRect(x: local.x, y: local.y, width: 1, height: 1)) }
            }
            let s = root.contentView?.bounds.size ?? .zero
            throw EditError.invalid("(\(Int(p.x)), \(Int(p.y))) is outside the EditMax window, which is \(Int(s.width))×\(Int(s.height)) points")
        }
        throw EditError.invalid("give an element id (see ui_layout) or {x, y} in window points")
    }

    // MARK: Mouse

    /// A click on a window that is not key is normally swallowed to make it key (`acceptsFirstMouse`), which is what a
    /// posted event hits while the user works in another app. The hosting view that takes the click (the window's, or
    /// the SwiftUI view inside a popover) is taught to accept first mouse, once per class, so posted gestures land
    /// without raising or focusing anything.
    private static var firstMouseTaught: Set<ObjectIdentifier> = []
    private static func acceptFirstMouse(in w: NSWindow, at local: CGPoint) {
        guard let content = w.contentView else { return }
        var views: [NSView] = [content]
        let base = toBase(CGRect(origin: local, size: .zero), w).origin
        var v = content.hitTest(content.superview?.convert(base, from: nil) ?? base)
        while let cur = v, cur !== content {
            if NSStringFromClass(type(of: cur)).contains("HostingView") { views.append(cur); break }
            v = cur.superview
        }
        for view in views {
            let cls: AnyClass = type(of: view)
            guard firstMouseTaught.insert(ObjectIdentifier(cls)).inserted else { continue }
            let block: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
            class_addMethod(cls, #selector(NSView.acceptsFirstMouse(for:)), imp_implementationWithBlock(block), "B@:@")
            DebugLog.event("ui-first-mouse", ["class": NSStringFromClass(cls)])
        }
    }

    /// Whether EditMax is the active app with `t`'s window (or the editor window it hangs from) key: SwiftUI gestures only
    /// run then, so otherwise views' own handlers are used.
    private static func active(_ w: NSWindow) -> Bool { NSApp.isActive && (w.isKeyWindow || topLevel(w).isKeyWindow) }

    /// How a drag was delivered: mouse events through the real gesture, or the view's own drag handler because EditMax
    /// is not the active app.
    enum DragMethod { case events(Int), handler(String) }

    static func drag(from: Target, to: Target, steps: Int, holdMs: Int) async throws -> DragMethod {
        guard !from.handlerOnly, !to.handlerOnly else { throw EditError.invalid("a drag needs an element with a place on screen (see ui_layout) or {x, y}") }
        let w = from.window
        if !active(w), let (id, handler) = UIRegistry.shared.dragHandler(id: from.id, at: from.local, in: w) {
            UIRegistry.shared.modifiers = modifiers; defer { UIRegistry.shared.modifiers = nil }   // ⌥ = no snapping on this path too
            handler(to.point.x - from.point.x)
            try await Task.sleep(for: .milliseconds(120))
            return .handler(id)
        }
        acceptFirstMouse(in: w, at: from.local)
        // The gesture stays in the window that took the mouse-down, as a real drag does.
        let end = to.window === w ? to.local : convert(to.local, from: to.window, to: w)
        return .events(try await dragEvents(from: from.local, to: end, steps: steps, holdMs: holdMs, in: w))
    }

    private static func dragEvents(from: CGPoint, to: CGPoint, steps: Int, holdMs: Int, in w: NSWindow) async throws -> Int {
        var n = 0
        post(.leftMouseDown, at: from, in: w); n += 1
        try await Task.sleep(for: .milliseconds(max(0, holdMs)))
        let steps = max(2, steps)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(.leftMouseDragged, at: p, in: w); n += 1
            try await Task.sleep(for: .milliseconds(16))
        }
        try await Task.sleep(for: .milliseconds(60))
        post(.leftMouseUp, at: to, in: w); n += 1
        try await Task.sleep(for: .milliseconds(120))   // let gesture handlers and document.apply run
        return n
    }

    enum ClickMethod { case events, handler(String) }

    static func click(_ t: Target, count: Int) async throws -> ClickMethod {
        let w = t.window
        let active = active(w)
        if let id = t.id, let h = UIRegistry.shared.tap(id, count: count), !active || t.handlerOnly {
            UIRegistry.shared.modifiers = modifiers; defer { UIRegistry.shared.modifiers = nil }
            h()
            try await Task.sleep(for: .milliseconds(120))
            return .handler(id)
        }
        guard !t.handlerOnly else { throw EditError.invalid("'\(t.id ?? "")' has no handler for a \(count)-click and no place on screen to click") }
        // An open menu runs its own event loop and brings EditMax to the front, which the driver must never do while the
        // user works in another app. An AppKit pop-up button is recognised before the click; a SwiftUI picker or menu
        // button only shows itself by building its menu on mouse-down, so that menu is caught before it opens.
        if !active, let p = popUp(at: t) { throw menuRefusal(t, choices(p).map(\.title)) }
        acceptFirstMouse(in: w, at: t.local)
        InteractionLog.syntheticUntil = Date().addingTimeInterval(1)
        let press = {
            for c in 1...max(1, count) {
                post(.leftMouseDown, at: t.local, in: w, clickCount: c)
                try await Task.sleep(for: .milliseconds(30))
                post(.leftMouseUp, at: t.local, in: w, clickCount: c)
                try await Task.sleep(for: .milliseconds(60))
                if MenuCapture.caught != nil { break }
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        guard !active else { try await press(); return .events }
        if let menu = try await MenuCapture.catching(press) { throw menuRefusal(t, choices(menu, skipFirst: false).map(\.title)) }
        return .events
    }

    private static func menuRefusal(_ t: Target, _ titles: [String]) -> EditError {
        let name = t.id.map { "'\($0)'" } ?? t.place
        let target = t.id.map { "\"\($0)\"" } ?? "{\"x\": \(Int(t.point.x)), \"y\": \(Int(t.point.y))}"
        let what = MenuCapture.opened ? "its menu opened and was closed again at once" : "its menu was not opened"
        return .invalid("\(name) opens a menu, so \(what): an open menu takes over EditMax and brings it to the front. Choose a value with ui_select {\"target\": \(target), \"option\": \"…\"}"
            + (titles.isEmpty ? "" : "; its options are: \(titles.joined(separator: ", "))"))
    }

    // MARK: Pop-up menus and segmented controls

    private static func subviews(of v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(subviews) }

    /// The AppKit pop-up button or segmented control drawn at `area` (window points): one under the area's centre
    /// first, else the one that overlaps the area most, measured against the control's own size. (SwiftUI's own menu
    /// pickers and menu buttons have no AppKit control behind them; `select` reaches their menu another way.)
    static func control(in w: NSWindow, around area: CGRect) -> NSControl? {
        guard let content = w.contentView else { return nil }
        let centre = CGPoint(x: area.midX, y: area.midY)
        var best: (control: NSControl, under: Int, score: CGFloat)?
        for case let c as NSControl in subviews(of: content) where c is NSPopUpButton || c is NSSegmentedControl {
            guard let r = visibleRect(of: c) else { continue }
            let i = r.intersection(area.insetBy(dx: -0.5, dy: -0.5))
            guard !i.isNull, i.width > 0, i.height > 0 else { continue }
            let under = r.contains(centre) ? 1 : 0, score = (i.width * i.height) / max(1, r.width * r.height)
            if best.map({ (under, score) > ($0.under, $0.score) }) ?? true { best = (c, under, score) }
        }
        return best?.control
    }

    /// The AppKit pop-up button a click at `t` would open: the one under the point, or for an element id, one that fills
    /// most of the element (a labelled picker's centre can fall on its label).
    private static func popUp(at t: Target) -> NSPopUpButton? {
        let point = CGRect(x: t.local.x - 0.5, y: t.local.y - 0.5, width: 1, height: 1)
        if let p = control(in: t.window, around: point) as? NSPopUpButton, visibleRect(of: p)?.contains(t.local) == true { return p }
        guard t.id != nil, let p = control(in: t.window, around: t.area) as? NSPopUpButton, let r = visibleRect(of: p) else { return nil }
        let i = r.intersection(t.area)
        return i.width * i.height >= 0.4 * t.area.width * t.area.height ? p : nil
    }

    private struct Choice { let title: String; let item: NSMenuItem }
    /// Every item a user could pick, submenus included ("Parent › Child"); separators, hidden items and a pull-down
    /// menu's title item are left out.
    private static func choices(_ menu: NSMenu, skipFirst: Bool) -> [Choice] {
        func walk(_ m: NSMenu, _ path: String, skipFirst: Bool) -> [Choice] {
            m.items.enumerated().flatMap { i, item -> [Choice] in
                if (skipFirst && i == 0) || item.isSeparatorItem || item.isHidden { return [] }
                let title = item.title.isEmpty ? (item.attributedTitle?.string ?? "") : item.title
                if let sub = item.submenu { return walk(sub, path + title + " › ", skipFirst: false) }
                return title.isEmpty ? [] : [Choice(title: path + title, item: item)]
            }
        }
        return walk(menu, "", skipFirst: skipFirst)
    }
    private static func choices(_ p: NSPopUpButton) -> [Choice] {
        guard let menu = p.menu else { return [] }
        menu.update()   // validation, and a delegate's lazily built items
        return choices(menu, skipFirst: p.pullsDown)
    }

    private static func label(_ s: NSSegmentedControl, _ i: Int) -> String {
        if let l = s.label(forSegment: i), !l.isEmpty { return l }
        if let t = s.toolTip(forSegment: i), !t.isEmpty { return t }
        return s.image(forSegment: i)?.accessibilityDescription ?? "segment \(i + 1)"
    }

    /// The title among `titles` the agent means: the same words (any case), else the only one starting with them, else
    /// the only one containing them.
    static func match(_ option: String, in titles: [String]) -> Int? {
        func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let o = norm(option), t = titles.map(norm)
        if let i = t.firstIndex(of: o) { return i }
        for test in [{ (s: String) in s.hasPrefix(o) }, { (s: String) in s.contains(o) }] {
            let hits = t.indices.filter { test(t[$0]) }
            if hits.count == 1 { return hits[0] }
        }
        return nil
    }

    /// Chooses `option` in the picker, menu button or segmented control at `t`, as a user picking it would, without
    /// opening a menu or bringing EditMax forward. With no option, says what can be chosen.
    static func select(_ t: Target, option: String?) async throws -> String {
        let name = t.id.map { "'\($0)'" } ?? t.place
        guard !t.handlerOnly else { throw EditError.invalid("\(name) has no place on screen; ui_layout lists what can be chosen from") }
        let pick: (title: String, what: String, run: () -> Void)
        let titles: [String]
        var flashed = false
        if let c = control(in: t.window, around: t.area) {
            // AppKit controls are set directly.
            let what = c is NSSegmentedControl ? "segmented control" : (c as? NSPopUpButton)?.pullsDown == true ? "menu button" : "pop-up menu"
            if let p = c as? NSPopUpButton {
                let list = choices(p)
                titles = list.map(\.title)
                guard let option, !option.isEmpty else { return "\(name) is a \(what); its options are: \(titles.joined(separator: ", "))" }
                guard let i = match(option, in: titles) else { throw EditError.invalid("\(name) has no option '\(option)'; its options are: \(titles.joined(separator: ", "))") }
                let item = list[i].item
                guard c.isEnabled, item.isEnabled, let menu = item.menu else { throw EditError.invalid("'\(titles[i])' cannot be chosen in \(name) now (disabled)") }
                pick = (titles[i], what, {
                    let index = menu.index(of: item)
                    if !p.pullsDown, menu === p.menu, let action = p.action {
                        p.selectItem(at: index); p.sendAction(action, to: p.target)   // the selection is the pop-up's
                    } else {
                        menu.performActionForItem(at: index)   // what picking the item runs
                    }
                })
            } else {
                let s = c as! NSSegmentedControl
                titles = (0..<s.segmentCount).map { label(s, $0) }
                guard let option, !option.isEmpty else { return "\(name) is a \(what); its options are: \(titles.joined(separator: ", "))" }
                guard let i = match(option, in: titles) else { throw EditError.invalid("\(name) has no option '\(option)'; its options are: \(titles.joined(separator: ", "))") }
                guard c.isEnabled, s.isEnabled(forSegment: i) else { throw EditError.invalid("'\(titles[i])' cannot be chosen in \(name) now (disabled)") }
                pick = (titles[i], what, { s.selectedSegment = i; s.sendAction(s.action, to: s.target) })
            }
        } else {
            // A SwiftUI picker or menu button builds its menu on mouse-down: press it with the menu caught before it can
            // open, and choose from that menu.
            acceptFirstMouse(in: t.window, at: t.local)
            InteractionLog.syntheticUntil = Date().addingTimeInterval(1)
            let menu = try await MenuCapture.catching {
                post(.leftMouseDown, at: t.local, in: t.window)
                for _ in 0..<10 where MenuCapture.caught == nil { try await Task.sleep(for: .milliseconds(30)) }
                // With no menu the press is let go outside the control, so a plain button under it does not fire.
                post(.leftMouseUp, at: MenuCapture.caught != nil ? t.local : CGPoint(x: -40, y: -40), in: t.window)
                try await Task.sleep(for: .milliseconds(60))
            }
            guard let menu else { throw EditError.invalid("\(name) is not a pop-up menu, menu button or segmented control (no menu comes from it); use ui_click") }
            flashed = MenuCapture.opened
            let list = choices(menu, skipFirst: false)
            titles = list.map(\.title)
            guard let option, !option.isEmpty else { return "\(name) is a menu; its options are: \(titles.joined(separator: ", "))" }
            guard let i = match(option, in: titles) else { throw EditError.invalid("\(name) has no option '\(option)'; its options are: \(titles.joined(separator: ", "))") }
            let item = list[i].item
            guard item.isEnabled, let owner = item.menu else { throw EditError.invalid("'\(titles[i])' cannot be chosen in \(name) now (disabled)") }
            pick = (titles[i], "menu", { owner.performActionForItem(at: owner.index(of: item)) })
        }
        InteractionLog.syntheticUntil = Date().addingTimeInterval(1)
        pick.run()
        try await Task.sleep(for: .milliseconds(120))
        return "Chose '\(pick.title)' in \(name) (a \(pick.what)) " + (flashed ? "; its menu opened for a moment and was closed" : "without opening it")
    }

    // MARK: Scroll

    /// Scrolls the scroll view that holds an element, or the one under a point, without any event, so it works while
    /// another app is active. An element id with no dx/dy scrolls that element into view.
    static func scroll(_ v: Value?, dx: Double?, dy: Double?, in root: NSWindow? = nil) async throws -> String {
        let root = try root ?? requireWindow()
        if let id = v?.stringValue, let p = UIRegistry.shared.probe(id, in: root) {
            if dx == nil, dy == nil {
                p.scrollToVisible(p.bounds)
                try await Task.sleep(for: .milliseconds(250))
                guard let w = p.window, let local = visibleRect(of: p) else { throw EditError.invalid("could not scroll '\(id)' into view: it is hidden or outside the window") }
                let r = convert(local, from: w, to: root)
                return "Scrolled '\(id)' into view; it is at \(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height))"
            }
            guard let sv = p.enclosingScrollView else { throw EditError.invalid("'\(id)' is not in a scrollable area") }
            return try await scroll(sv, dx: dx ?? 0, dy: dy ?? 0)
        }
        let t = try target(v, dx: 0, dy: 0, in: root)
        guard !t.handlerOnly, let content = t.window.contentView else { throw EditError.invalid("nothing scrollable at '\(t.id ?? "")'") }
        let base = toBase(CGRect(origin: t.local, size: .zero), t.window).origin
        var view: NSView? = content.hitTest(content.superview?.convert(base, from: nil) ?? base) ?? content
        while let cur = view, !(cur is NSScrollView) { view = cur.superview }
        guard let sv = view as? NSScrollView else { throw EditError.invalid("nothing scrollable at \(t.place)") }
        return try await scroll(sv, dx: dx ?? 0, dy: dy ?? 0)
    }

    private static func scroll(_ sv: NSScrollView, dx: Double, dy: Double) async throws -> String {
        let clip = sv.contentView, doc = sv.documentView?.frame ?? .zero
        let maxX = max(0, doc.width - clip.bounds.width), maxY = max(0, doc.height - clip.bounds.height)
        // AppKit scroll views here are flipped (SwiftUI's are), so +y is down in both the request and the bounds origin.
        let o = NSPoint(x: min(maxX, max(0, clip.bounds.origin.x + dx)), y: min(maxY, max(0, clip.bounds.origin.y + dy)))
        clip.scroll(to: o); sv.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(250))
        return "Scrolled to (\(Int(o.x)), \(Int(o.y))) of (\(Int(maxX)), \(Int(maxY)))"
    }

    // MARK: Keys

    /// How a key reached the window. A key typed while a text field has the focus goes to the field, as it would for a
    /// user; a key without ⌘, ⌃ or ⌥ never reaches the menu bar (a plain "e" once ran Edit ▸ Emoji & Symbols).
    enum KeyMethod: String { case text = "typed into the focused text field", editor = "the editor's key handler", window = "the window", menu = "the menu bar", events = "events", unused = "nothing in the window uses this key" }

    private static let named: [String: (UInt16, String)] = [
        "space": (49, " "), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "up": (126, "\u{F700}"), "down": (125, "\u{F701}"),
        "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"), "delete": (51, "\u{7F}"), "backspace": (51, "\u{7F}"), "forwarddelete": (117, "\u{F728}"),
        "return": (36, "\r"), "enter": (36, "\r"), "escape": (53, "\u{1B}"), "tab": (48, "\t")]
    /// US-layout key codes, so a posted "e" is the E key (code 0 is A) as far as anything matching key codes cares.
    private static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50]

    /// The window a key goes to: the key window when it is the editor or hangs from it, else a popover or sheet whose
    /// text field has the focus, else an open sheet, else the editor.
    private static func keyWindow(_ root: NSWindow) -> NSWindow {
        let windows = tree(root)
        if let k = NSApp.keyWindow, windows.contains(where: { $0 === k }) { return k }
        if let t = windows.dropFirst().reversed().first(where: { $0.firstResponder is NSTextView }) { return t }
        return root.attachedSheet ?? root
    }

    /// Presses a key (down and up). `key` is a character ("j", "m") or a name: space, left, right, up, down, home, end,
    /// delete, forwarddelete, return, escape, tab.
    static func key(_ key: String, modifiers names: [String], in root: NSWindow? = nil) async throws -> KeyMethod {
        let root = try root ?? requireWindow()
        let w = keyWindow(root)
        let (code, chars): (UInt16, String)
        if let n = named[key.lowercased()] { (code, chars) = n }
        else if key.count == 1 { (code, chars) = (codes[Character(key.lowercased())] ?? 0, key) }
        else { throw EditError.invalid("key must be one character or one of \(named.keys.sorted().joined(separator: ", "))") }
        let f = flags(names)
        let shown = f.contains(.shift) && key.count == 1 ? key.uppercased() : chars
        let chord = !f.isDisjoint(with: [.command, .control, .option])
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                             context: nil, characters: shown, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { throw EditError.invalid("cannot make a key event for '\(key)'") }
        InteractionLog.syntheticUntil = Date().addingTimeInterval(1)
        let settle = { try await Task.sleep(for: .milliseconds(120)) }

        // A text field has the focus: the key is text (⌥ and ⌃ edit text too), as the editor's own key monitor lets it be.
        if let field = w.firstResponder as? NSTextView, !f.contains(.command) {
            // Return and Escape press a sheet's default or cancel button first, as they do for a user.
            if ["return", "enter", "escape"].contains(key.lowercased()), w.performKeyEquivalent(with: down) { try await settle(); return .window }
            field.keyDown(with: down); field.keyUp(with: up)
            try await settle(); return .text
        }
        // ⌘ chords in the active app go the way a real one does (menus included).
        if chord, active(w) {
            for e in [down, up] { NSApp.postEvent(e, atStart: false); try await Task.sleep(for: .milliseconds(30)) }
            try await settle(); return .events
        }
        let typing = w.firstResponder is NSTextView
        if w === root, !typing, let h = UIRegistry.shared.keyHandler, h(down) { try await settle(); return .editor }
        if w.performKeyEquivalent(with: down) { try await settle(); return .window }   // a SwiftUI .keyboardShortcut, a default button
        if chord {
            if NSApp.mainMenu?.performKeyEquivalent(with: down) == true { try await settle(); return .menu }
            return .unused
        }
        // A plain key goes to the focused control (a list's arrows, a button's space), never to the menu bar. With nothing
        // focused it would only beep.
        guard let responder = w.firstResponder, responder !== w else { return .unused }
        w.sendEvent(down); w.sendEvent(up)
        try await settle(); return .window
    }

    // MARK: Screenshot

    /// Why a screenshot is not ScreenCaptureKit pixels; the reason goes into the tool's answer as it is.
    enum CaptureFailure: Error {
        case notGranted, offScreen, notListed, failed(String)
        var reason: String {
            switch self {
            case .notGranted: return "Screen Recording is not granted to EditMax; grant it in System Settings → Privacy & Security → Screen Recording for true pixels (the tool never asks)"
            case .offScreen: return "the window has no on-screen number (minimised or closing)"
            case .notListed: return "ScreenCaptureKit does not list the window"
            case .failed(let s): return "ScreenCaptureKit could not capture the window: \(s)"
            }
        }
    }

    /// The EditMax window's own pixels through ScreenCaptureKit, when the Screen Recording permission is already granted.
    /// The tool never asks for it: a debug build is re-signed on every build, so macOS would forget the grant and nag
    /// again each time. Only EditMax's windows are ever in the picture, never another app's or the desktop.
    ///
    /// Only the window itself is captured, never the display (the user's rule, after a display capture once photographed
    /// another app). Popovers and sheets are in the picture when macOS draws them with the window; the answer says when
    /// some are attached. An open menu or another EditMax window over it is left out: captured one by one they came back
    /// as a shrunken copy of the whole window. Without the permission, or when capture fails, the window's layer tree is
    /// rendered instead and the answer gives the real reason.
    static func screenshot(maxWidth: Int, in root: NSWindow? = nil) async throws -> (png: Data, method: String) {
        await AgentFollow.shared.settle()   // an agent edit that just landed is still animating into place
        let w = try root ?? requireWindow()
        let attached = Array(tree(w).dropFirst())
        var cg: CGImage, method: String
        do {
            (cg, method) = try await pixels(of: w, attached: attached)
        } catch {
            let reason = (error as? CaptureFailure)?.reason ?? CaptureFailure.failed(error.localizedDescription).reason
            DebugLog.event("ui-screenshot-fallback", ["error": reason])
            cg = try renderLayers(of: w)
            method = "layer-render, which misses some controls (\(reason))" + (attached.isEmpty ? "" : "; the \(kind(attached[0])) over it is not in the picture")
        }
        let over = NSApp.windows.filter { o in
            o.isVisible && o.windowNumber > 0 && o.level.rawValue > w.level.rawValue && !(o is NotchDrawerPanel)
                && !attached.contains { $0 === o } && o.frame.intersects(w.frame) && o.frame.width > 2 && o.frame.height > 2
        }
        if !over.isEmpty { method += "; an open menu or panel over the window is not in the picture" }
        var image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if maxWidth > 0, cg.width > maxWidth {
            let s = CGFloat(maxWidth) / CGFloat(cg.width)
            let small = NSImage(size: NSSize(width: CGFloat(cg.width) * s, height: CGFloat(cg.height) * s))
            small.lockFocus(); image.draw(in: NSRect(origin: .zero, size: small.size)); small.unlockFocus()
            image = small
        }
        guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw EditError.invalid("cannot encode PNG") }
        return (out, method)
    }

    private static func pixels(of w: NSWindow, attached: [NSWindow]) async throws -> (CGImage, String) {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.notGranted }
        // A window that is not on screen (closing, or a menu's window) has a negative number; converting it to a
        // CGWindowID trapped and took the app down.
        guard w.windowNumber > 0, let wid = CGWindowID(exactly: w.windowNumber) else { throw CaptureFailure.offScreen }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw CaptureFailure.failed("listing windows: \(error.localizedDescription)") }
        guard let win = content.windows.first(where: { $0.windowID == wid }) else { throw CaptureFailure.notListed }
        let scale = w.backingScaleFactor
        // ui_layout's points start at the content's top-left; the picture starts at the window's (title bar included) or
        // further out for a popover sticking out. The answer says where, so the two can be lined up.
        let inset = CGPoint(x: w.contentView?.frame.minX ?? 0, y: w.frame.height - (w.contentView?.frame.maxY ?? w.frame.height))
        func origin(_ topLeft: CGPoint) -> String {
            let o = CGPoint(x: topLeft.x - win.frame.minX - inset.x, y: topLeft.y - win.frame.minY - inset.y)
            return abs(o.x) > 0.5 || abs(o.y) > 0.5 ? "; the image's top-left is (\(Int(o.x)), \(Int(o.y))) in ui_layout points" : ""
        }

        // Only ever the window itself (the user's rule): never a capture of the display, even filtered to EditMax's
        // windows, since a display capture once photographed another app. macOS draws the window's attached popovers
        // and sheets into this picture when it can; when it cannot, the answer says so instead of reaching for the screen.
        let cfg = SCStreamConfiguration()
        cfg.showsCursor = false
        cfg.captureResolution = .best
        cfg.width = Int(win.frame.width * scale); cfg.height = Int(win.frame.height * scale)
        let img: CGImage
        do { img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg) }
        catch { throw CaptureFailure.failed(error.localizedDescription) }
        var method = "window-pixels" + origin(win.frame.origin)
        if !attached.isEmpty {
            method += "; the \(attached.map(kind).joined(separator: " and ")) over it is in the picture only if macOS drew it with the window (screenshots never capture the display)"
        }
        return (img, method)
    }

    private static func renderLayers(of w: NSWindow) throws -> CGImage {
        guard let v = w.contentView, let layer = v.layer else { throw EditError.invalid("no window content") }
        let scale = w.backingScaleFactor
        let size = v.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw EditError.invalid("cannot create bitmap") }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)   // CGContext is bottom-up; keep the image upright
        layer.render(in: ctx)
        guard let cg = ctx.makeImage() else { throw EditError.invalid("cannot render window") }
        return cg
    }

    // MARK: Events

    private static var eventNumber = 100_000
    /// Modifier keys held during posted mouse events (⇧-click adds to the selection, ⌥-drag skips snapping).
    static var modifiers: NSEvent.ModifierFlags = []
    static func flags(_ names: [String]) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for n in names.map({ $0.lowercased() }) {
            switch n {
            case "shift", "⇧": f.insert(.shift)
            case "command", "cmd", "⌘": f.insert(.command)
            case "option", "alt", "⌥": f.insert(.option)
            case "control", "ctrl", "⌃": f.insert(.control)
            default: break
            }
        }
        return f
    }

    /// Posts a mouse event at `p` (the window's content points) to the window `w`.
    private static func post(_ type: NSEvent.EventType, at p: CGPoint, in w: NSWindow, clickCount: Int = 1) {
        InteractionLog.syntheticUntil = Date().addingTimeInterval(1)
        let loc = toBase(CGRect(origin: p, size: .zero), w).origin
        eventNumber += 1
        guard let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private static func r(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
}

/// Catches a menu that is about to open and keeps it from showing. A SwiftUI picker or menu button has no AppKit control
/// behind it: on mouse-down it builds an NSMenu and pops it up, and an open menu runs its own event loop and brings
/// EditMax to the front. For the length of one driver gesture NSMenu's pop-up methods are replaced by one that only
/// records the menu, then put back, so the driver can choose from the menu (`ui_select`) or refuse the click
/// (`ui_click`) without anything opening. A menu that still starts tracking through a path not covered here is closed at
/// once (`opened` says so).
@MainActor
enum MenuCapture {
    private(set) static var caught: NSMenu?
    private(set) static var opened = false
    private static var busy = false

    /// NSMenu's ways to pop a menu up (SwiftUI pickers use `_popUpMenuRelativeToRect:inView:width:flags:selectedItemIndexProvider:`
    /// on macOS 26). Missing ones are skipped, so a renamed method costs only the safety net, never a crash.
    private static let instanceSelectors = [
        "popUpMenuPositioningItem:atLocation:inView:", "popUpMenuPositioningItem:atLocation:inView:appearance:",
        "_popUpMenuPositioningItem:atLocation:inView:completionBlock:",
        "_popUpMenuRelativeToRect:inView:width:flags:selectedItemIndexProvider:", "_popUpMenuRelativeToRect:inView:preferredEdge:",
        "_popUpMenuRelativeToRect:inView:preferredEdge:flags:options:",
        "_popUpMenuAtLocation:view:selectedItemIndexProvider:minimumWidth:font:flags:options:",
        "_popUpMenuWithContext:forView:", "_popUpMenuWithEvent:forView:"]
    private static let classSelectors = ["popUpContextMenu:withEvent:forView:", "popUpContextMenu:withEvent:forView:withFont:"]

    /// Runs `body` (a press) with menus caught; returns the menu it tried to open, if any.
    static func catching(_ body: () async throws -> Void) async throws -> NSMenu? {
        // The press awaits on the main actor, so a second driver call could start here while the first is suspended;
        // putting the methods back out of order would restore one already freed.
        guard !busy else { throw EditError.invalid("another ui_click or ui_select is still running; try again when it has answered") }
        busy = true
        caught = nil; opened = false
        let record: @convention(block) (AnyObject) -> Bool = { menu in
            MainActor.assumeIsolated { if caught == nil { caught = menu as? NSMenu } }
            return false   // "nothing was chosen"
        }
        let recordArgument: @convention(block) (AnyObject, AnyObject?) -> Void = { _, menu in
            MainActor.assumeIsolated { if caught == nil { caught = menu as? NSMenu } }
        }
        var replaced: [(method: ObjectiveC.Method, original: IMP, mine: IMP)] = []
        func replace(_ cls: AnyClass, _ names: [String], _ block: Any) {
            for n in names {
                guard let m = class_getInstanceMethod(cls, NSSelectorFromString(n)) else { continue }
                let mine = imp_implementationWithBlock(block)
                replaced.append((m, method_setImplementation(m, mine), mine))
            }
        }
        replace(NSMenu.self, instanceSelectors, record)
        if let meta = object_getClass(NSMenu.self) { replace(meta, classSelectors, recordArgument) }
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            guard let menu = n.object as? NSMenu else { return }
            MainActor.assumeIsolated { if caught == nil { caught = menu }; opened = true }
            RunLoop.main.perform(inModes: [.eventTracking, .common]) { menu.cancelTrackingWithoutAnimation() }
        }
        defer {
            for r in replaced.reversed() { method_setImplementation(r.method, r.original); imp_removeBlock(r.mine) }
            NotificationCenter.default.removeObserver(token)
            // A menu left here would end a later multi-click outside a capture after its first click, and keep the menu alive.
            caught = nil
            busy = false
        }
        try await body()
        return caught
    }
}
