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
    func set(_ id: String, _ frame: CGRect) { frames[id] = frame }
    func remove(_ id: String) { frames.removeValue(forKey: id) }
    func frame(_ id: String) -> CGRect? { frames[id] }
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
    private static func withActiveWindow<T>(_ w: NSWindow, _ body: () async throws -> T) async throws -> T {
        if NSApp.isActive && w.isKeyWindow { return try await body() }
        let previous = NSWorkspace.shared.frontmostApplication
        let above = windowAbove(w)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { _ in nil }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let previous, previous != .current {
                if #available(macOS 14, *) { previous.activate(from: .current, options: []) } else { previous.activate(options: []) }
            }
            if let above { w.order(.below, relativeTo: above) }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        return try await body()
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

    static func drag(from: CGPoint, to: CGPoint, steps: Int, holdMs: Int) async throws -> Int {
        guard let w = window else { throw EditError.invalid("no window") }
        acceptFirstMouse(in: w)
        return try await withActiveWindow(w) { try await dragEvents(from: from, to: to, steps: steps, holdMs: holdMs, in: w) }
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

    static func click(at p: CGPoint, count: Int) async throws {
        guard let w = window else { throw EditError.invalid("no window") }
        acceptFirstMouse(in: w)
        try await withActiveWindow(w) {
            for c in 1...max(1, count) {
                post(.leftMouseDown, at: p, in: w, clickCount: c)
                try await Task.sleep(for: .milliseconds(30))
                post(.leftMouseUp, at: p, in: w, clickCount: c)
                try await Task.sleep(for: .milliseconds(60))
            }
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    /// The EditMax window's own pixels through ScreenCaptureKit, filtered to this one window (never the screen around
    /// it). macOS asks for the Screen Recording permission once.
    /// Without that permission it falls back to rendering the window's layer tree, which misses some inspector controls.
    static func screenshot(maxWidth: Int) async throws -> (png: Data, method: String) {
        guard let w = window else { throw EditError.invalid("no window") }
        var method = "window-pixels"
        var cg: CGImage
        do {
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
            method = "layer-render (grant Screen Recording to EditMax in System Settings → Privacy & Security for true pixels)"
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
        layer.render(in: ctx)
        guard let cg = ctx.makeImage() else { throw EditError.invalid("cannot render window") }
        return cg
    }

    private static var eventNumber = 100_000
    private static func post(_ type: NSEvent.EventType, at p: CGPoint, in w: NSWindow, clickCount: Int = 1) {
        guard let content = w.contentView else { return }
        // Registry frames have a top-left origin; NSEvent wants the window's bottom-left origin.
        let loc = NSPoint(x: p.x, y: content.bounds.height - p.y)
        eventNumber += 1
        guard let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private static func r(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
}
