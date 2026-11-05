import SwiftUI
import AppKit
import MCP
import ScreenCaptureKit

/// Where things are on screen, so an agent can drive the real UI through the MCP server (`ui_layout`, `ui_drag`,
/// `ui_click`, `ui_screenshot`). Views register their frame with `.uiFrame("id")`; frames are in window points with the
/// origin at the top-left of the window's content.
@MainActor
final class UIRegistry {
    static let shared = UIRegistry()
    private(set) var frames: [String: CGRect] = [:]
    /// Views that can apply a horizontal drag themselves (timeline bars: move and the two trim edges), keyed like frames.
    /// The driver calls these when macOS refuses to activate EditMax, since SwiftUI gestures only run in the active app.
    private(set) var dragHandlers: [String: (CGFloat) -> Void] = [:]
    func set(_ id: String, _ frame: CGRect) { frames[id] = frame }
    func remove(_ id: String) { frames.removeValue(forKey: id) }
    func frame(_ id: String) -> CGRect? { frames[id] }
    /// The smallest registered element containing `point` (window points, top-left origin).
    func element(at point: CGPoint) -> String? {
        frames.filter { $0.value.contains(point) }.min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?.key
    }
    /// Views that react to a click through a SwiftUI gesture (bars select on tap, media rows append on double-click),
    /// keyed by id then click count; and the window's key handler. Used like `dragHandlers`.
    private(set) var tapHandlers: [String: [Int: () -> Void]] = [:]
    var keyHandler: ((NSEvent) -> Bool)?
    /// The player time of each open document, for inspect_timeline.
    var playheads: [UUID: () -> Double?] = [:]
    /// Modifier keys the driver pretends are held while it calls a handler directly (⇧ for multi-select, ⌥ for free drags).
    var modifiers: NSEvent.ModifierFlags?
    var currentModifiers: NSEvent.ModifierFlags { modifiers ?? NSEvent.modifierFlags }
    func setTap(_ id: String, count: Int, _ handler: @escaping () -> Void) { tapHandlers[id, default: [:]][count] = handler }
    func removeTap(_ id: String) { tapHandlers.removeValue(forKey: id) }
    func setDrag(_ id: String, _ handler: @escaping (CGFloat) -> Void) { dragHandlers[id] = handler }
    func removeDrag(_ id: String) { dragHandlers.removeValue(forKey: id) }
    /// The handler for the element named `id`, else the smallest registered frame containing `point` (a trim handle
    /// lies inside its bar, so the smaller frame is the more specific one).
    func dragHandler(id: String?, at point: CGPoint) -> (String, (CGFloat) -> Void)? {
        if let id, let h = dragHandlers[id] { return (id, h) }
        let hits = dragHandlers.compactMap { id, h -> (String, (CGFloat) -> Void, CGFloat)? in
            guard let f = frames[id], f.contains(point) else { return nil }
            return (id, h, f.width * f.height)
        }
        return hits.min { $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }
}

private struct UITapModifier: ViewModifier {
    let id: String
    let count: Int
    let key: String
    let handler: () -> Void
    func body(content: Content) -> some View {
        content
            .onAppear { UIRegistry.shared.setTap(id, count: count, handler) }
            .onChange(of: key) { _, _ in UIRegistry.shared.setTap(id, count: count, handler) }
            .onDisappear { UIRegistry.shared.removeTap(id) }
    }
}

private struct UIDragModifier: ViewModifier {
    let id: String
    /// Changes whenever the closure would compute something different (a bar's start, length, zoom), so the registry
    /// never keeps a closure that captured old values.
    let key: String
    let handler: (CGFloat) -> Void
    func body(content: Content) -> some View {
        content
            .onAppear { UIRegistry.shared.setDrag(id, handler) }
            .onChange(of: id) { old, new in UIRegistry.shared.removeDrag(old); UIRegistry.shared.setDrag(new, handler) }
            .onChange(of: key) { _, _ in UIRegistry.shared.setDrag(id, handler) }
            .onDisappear { UIRegistry.shared.removeDrag(id) }
    }
}

private struct UIFrameModifier: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { g in
                let f = g.frame(in: .global)
                Color.clear
                    .onAppear { UIRegistry.shared.set(id, f) }
                    .onChange(of: f) { _, new in UIRegistry.shared.set(id, new) }
                    .onDisappear { UIRegistry.shared.remove(id) }
            }
        )
    }
}

extension View {
    /// Registers this view's frame under `id` for the MCP UI driver.
    func uiFrame(_ id: String) -> some View { modifier(UIFrameModifier(id: id)) }
    /// Lets the MCP UI driver apply a horizontal drag of `dx` points to this view without a mouse gesture.
    func uiDrag(_ id: String, key: String, _ handler: @escaping (CGFloat) -> Void) -> some View { modifier(UIDragModifier(id: id, key: key, handler: handler)) }
    /// Lets the MCP UI driver click this view (a tap gesture) without a mouse event. `key` re-registers the closure when it changes.
    func uiTap(_ id: String, count: Int = 1, key: String = "", _ handler: @escaping () -> Void) -> some View { modifier(UITapModifier(id: id, count: count, key: key, handler: handler)) }
}

/// Posts mouse events to EditMax's own window through the app's event queue. They never leave the process, so they
/// cannot land in another app; the real cursor does not move. When EditMax is not the active app, it is activated for
/// the one gesture (SwiftUI needs that) and the previous app gets the focus straight back; see `withActiveWindow`.
@MainActor
enum UIDriver {
    struct Point: Codable { var x: Double, y: Double }
    struct Element: Codable { var id: String, x: Double, y: Double, width: Double, height: Double }
    struct Layout: Codable { var window: Point, elements: [Element] }

    static var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil } }

    static func layout(prefix: String?) throws -> Layout {
        guard let w = window, let content = w.contentView else { throw EditError.invalid("no window") }
        let els = UIRegistry.shared.frames
            .filter { el in prefix.map { el.key.hasPrefix($0) } ?? true }
            .map { Element(id: $0.key, x: r($0.value.minX), y: r($0.value.minY), width: r($0.value.width), height: r($0.value.height)) }
            .sorted { $0.id < $1.id }
        return Layout(window: Point(x: Double(content.bounds.width), y: Double(content.bounds.height)), elements: els)
    }

    /// Resolves "element id" (its centre, plus an optional offset) or {x, y} into window points (top-left origin).
    static func resolve(_ v: Value?, dx: Double, dy: Double) throws -> CGPoint {
        if let id = v?.stringValue {
            guard let f = UIRegistry.shared.frame(id) else {
                // Handler-only elements (tab.history, …) have no frame; the click goes to their handler, never to a point.
                if UIRegistry.shared.tapHandlers[id] != nil { return CGPoint(x: -1, y: -1) }
                throw EditError.notFound("ui element '\(id)'. ui_layout lists what is on screen")
            }
            return CGPoint(x: f.midX + dx, y: f.midY + dy)
        }
        if let o = v?.objectValue, let x = o["x"]?.doubleValue ?? o["x"]?.intValue.map(Double.init), let y = o["y"]?.doubleValue ?? o["y"]?.intValue.map(Double.init) {
            return CGPoint(x: x + dx, y: y + dy)
        }
        throw EditError.invalid("give an element id (see ui_layout) or {x, y} in window points")
    }

    /// A click on a window that is not key is normally swallowed to make it key (`acceptsFirstMouse`), which is what a
    /// posted event hits while the user works in another app. The hosting view of the window is taught to accept first
    /// mouse, once, so posted gestures land without raising or focusing anything.
    private static var firstMouseTaught: Set<ObjectIdentifier> = []
    private static func acceptFirstMouse(in w: NSWindow) {
        guard let v = w.contentView else { return }
        let cls: AnyClass = type(of: v)
        guard firstMouseTaught.insert(ObjectIdentifier(cls)).inserted else { return }
        let block: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
        let sel = #selector(NSView.acceptsFirstMouse(for:))
        class_addMethod(cls, sel, imp_implementationWithBlock(block), "B@:@")
        DebugLog.event("ui-first-mouse", ["class": NSStringFromClass(cls)])
    }

    /// SwiftUI gestures only run while EditMax is the active app with a key window. For one gesture EditMax is activated,
    /// then the app that was in front gets the focus back and the window its place in the stack. Keystrokes arriving
    /// meanwhile are dropped, not applied, so nothing typed into another app can split or delete a clip.
    /// Runs `body` with whether the EditMax window is the active, key window. The driver never activates the app itself:
    /// bringing the window forward would steal the user's focus (and macOS may then refuse to hand it back), so views
    /// register tap/drag/key handlers instead, and plain controls take posted events without activation.
    private static func withActiveWindow<T>(_ w: NSWindow, _ body: (_ active: Bool) async throws -> T) async throws -> T {
        let active = NSApp.isActive && w.isKeyWindow
        if !active { acceptFirstMouse(in: w) }
        return try await body(active)
    }

    /// Window number of the on-screen window just above `w`, from any app (nil when `w` is already on top).
    private static func windowAbove(_ w: NSWindow) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var previous: Int? = nil
        for info in list where (info["kCGWindowLayer"] as? Int) == 0 {
            let number = info["kCGWindowNumber"] as? Int ?? -1
            if number == w.windowNumber { return previous }
            if let bounds = info["kCGWindowBounds"] as? [String: Any], (bounds["Height"] as? Double ?? 0) > 100 { previous = number }
        }
        return nil
    }

    /// How a drag was delivered: mouse events through the real gesture, or the view's own drag handler because macOS
    /// would not activate EditMax (it refuses while another app is being used).
    enum DragMethod { case events(Int), handler(String) }

    static func drag(from: CGPoint, fromID: String?, to: CGPoint, steps: Int, holdMs: Int) async throws -> DragMethod {
        guard let w = window else { throw EditError.invalid("no window") }
        acceptFirstMouse(in: w)
        return try await withActiveWindow(w) { active in
            if !active, let (id, handler) = UIRegistry.shared.dragHandler(id: fromID, at: from) {
                UIRegistry.shared.modifiers = modifiers; defer { UIRegistry.shared.modifiers = nil }   // ⌥ = no snapping on this path too
                handler(to.x - from.x)
                try await Task.sleep(for: .milliseconds(120))
                return .handler(id)
            }
            return .events(try await dragEvents(from: from, to: to, steps: steps, holdMs: holdMs, in: w))
        }
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

    /// Scrolls the nearest NSScrollView under `p` (registry coordinates) without any event, so it works while another app is active.
    static func scroll(at p: CGPoint, dx: CGFloat, dy: CGFloat) async throws -> (x: CGFloat, y: CGFloat, maxX: CGFloat, maxY: CGFloat) {
        guard let w = window, let content = w.contentView else { throw EditError.invalid("no window") }
        let loc = NSPoint(x: p.x, y: content.bounds.height - p.y)
        var v: NSView? = content.hitTest(loc) ?? content
        while let cur = v, !(cur is NSScrollView) { v = cur.superview }
        guard let sv = v as? NSScrollView else { throw EditError.invalid("nothing scrollable at (\(Int(p.x)), \(Int(p.y)))") }
        let clip = sv.contentView, doc = sv.documentView?.frame ?? .zero
        let maxX = max(0, doc.width - clip.bounds.width), maxY = max(0, doc.height - clip.bounds.height)
        // AppKit scroll views here are flipped (SwiftUI's are), so +y is down in both the request and the bounds origin.
        let o = NSPoint(x: min(maxX, max(0, clip.bounds.origin.x + dx)), y: min(maxY, max(0, clip.bounds.origin.y + dy)))
        clip.scroll(to: o); sv.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(250))
        return (o.x, o.y, maxX, maxY)
    }

    enum ClickMethod { case events, handler(String) }

    static func click(at p: CGPoint, id: String?, count: Int) async throws -> ClickMethod {
        guard let w = window else { throw EditError.invalid("no window") }
        acceptFirstMouse(in: w)
        return try await withActiveWindow(w) { active in
            if let id, let h = UIRegistry.shared.tapHandlers[id]?[count], !active || p.x < 0 {
                UIRegistry.shared.modifiers = modifiers; defer { UIRegistry.shared.modifiers = nil }
                h()
                try await Task.sleep(for: .milliseconds(120))
                return .handler(id)
            }
            guard p.x >= 0 else { throw EditError.invalid("no handler for a \(count)-click on '\(id ?? "")'") }
            InteractionLog.syntheticUntil = Date().addingTimeInterval(1)
            for c in 1...max(1, count) {
                post(.leftMouseDown, at: p, in: w, clickCount: c)
                try await Task.sleep(for: .milliseconds(30))
                post(.leftMouseUp, at: p, in: w, clickCount: c)
                try await Task.sleep(for: .milliseconds(60))
            }
            try await Task.sleep(for: .milliseconds(120))
            return .events
        }
    }

    /// The EditMax window's own pixels through ScreenCaptureKit, filtered to this one window (never the screen around
    /// it), when the Screen Recording permission is already granted. The tool never asks for it: a debug build is
    /// re-signed on every build, so macOS would forget the grant and nag again each time. Without the permission it
    /// renders the window's layer tree instead, which misses some inspector controls.
    static func screenshot(maxWidth: Int) async throws -> (png: Data, method: String) {
        guard let w = window else { throw EditError.invalid("no window") }
        var method = "window-pixels"
        var cg: CGImage
        do {
            guard CGPreflightScreenCaptureAccess() else { throw EditError.invalid("Screen Recording not granted") }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let win = content.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) else { throw EditError.invalid("window not capturable") }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            let scale = w.backingScaleFactor
            cfg.width = Int(win.frame.width * scale); cfg.height = Int(win.frame.height * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            DebugLog.event("ui-screenshot-fallback", ["error": error.localizedDescription])
            method = "layer-render (Screen Recording not granted to EditMax; grant it in System Settings → Privacy & Security for true pixels; the tool never prompts)"
            cg = try renderLayers(of: w)
        }
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

    /// Posts a key press (down and up) to the window. `key` is a character ("j", "m") or a name: space, left, right,
    /// up, down, home, end, delete, forwarddelete, return, escape, tab.
    static func key(_ key: String, modifiers names: [String]) async throws -> String {
        guard let w = window else { throw EditError.invalid("no window") }
        let named: [String: (UInt16, String)] = ["space": (49, " "), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "up": (126, "\u{F700}"), "down": (125, "\u{F701}"),
                                                 "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"), "delete": (51, "\u{7F}"), "backspace": (51, "\u{7F}"), "forwarddelete": (117, "\u{F728}"),
                                                 "return": (36, "\r"), "enter": (36, "\r"), "escape": (53, "\u{1B}"), "tab": (48, "\t")]
        let (code, chars): (UInt16, String)
        if let n = named[key.lowercased()] { (code, chars) = n }
        else if key.count == 1 { (code, chars) = (0, key) }
        else { throw EditError.invalid("key must be one character or one of \(named.keys.sorted().joined(separator: ", "))") }
        let f = flags(names)
        let shown = f.contains(.shift) && key.count == 1 ? key.uppercased() : chars
        return try await withActiveWindow(w) { active in
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                        characters: shown, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            // Not the active app: hand the key to the editor's own handler (the one behind the keys), or to the menu for ⌘ chords.
            if !active, let down {
                if let h = UIRegistry.shared.keyHandler, h(down) { try await Task.sleep(for: .milliseconds(120)); return "handler" }
                if f.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: down) == true { try await Task.sleep(for: .milliseconds(120)); return "menu" }
            }
            InteractionLog.syntheticUntil = Date().addingTimeInterval(1)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                               characters: shown, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
                NSApp.postEvent(e, atStart: false)
                try await Task.sleep(for: .milliseconds(30))
            }
            try await Task.sleep(for: .milliseconds(120))
            return "events"
        }
    }

    private static func post(_ type: NSEvent.EventType, at p: CGPoint, in w: NSWindow, clickCount: Int = 1) {
        guard let content = w.contentView else { return }
        // Registry frames have a top-left origin; NSEvent wants the window's bottom-left origin.
        let loc = NSPoint(x: p.x, y: content.bounds.height - p.y)
        eventNumber += 1
        guard let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private static func r(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
}
