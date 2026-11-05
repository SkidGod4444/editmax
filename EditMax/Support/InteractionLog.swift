import AppKit

/// Every user interaction in the EditMax window, as lines in `editmax.log` beside the edits and the MCP calls, so a
/// session can be read back in order: `ui-click` (with the `uiFrame` id under the pointer, else the view class),
/// `ui-drag`, `ui-key`, `ui-typing` (that typing happened in a text field, never the characters), `ui-menu`.
/// Events the MCP driver posted carry `synthetic: true`.
@MainActor
enum InteractionLog {
    /// The driver sets this just before it posts events; events dispatched until then are marked synthetic.
    static var syntheticUntil = Date.distantPast
    private static var downAt: (point: CGPoint, id: String?)?
    private static var lastTyping = Date.distantPast

    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .keyDown]) { e in
            log(e); return e
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { n in
            guard let item = n.userInfo?["MenuItem"] as? NSMenuItem else { return }
            MainActor.assumeIsolated {
                DebugLog.event("ui-menu", ["title": item.title, "menu": item.menu?.title ?? "", "synthetic": synthetic])
            }
        }
        DebugLog.event("interaction-log", ["installed": true])
    }

    private static var synthetic: Bool { Date() < syntheticUntil }

    private static func log(_ e: NSEvent) {
        guard let w = e.window, let content = w.contentView else { return }
        // Registry frames have a top-left origin; NSEvent locations have the window's bottom-left origin.
        let p = CGPoint(x: e.locationInWindow.x, y: content.bounds.height - e.locationInWindow.y)
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            let id = UIRegistry.shared.element(at: p)
            downAt = (p, id)
            var f: [String: Any] = ["x": r(p.x), "y": r(p.y), "clicks": e.clickCount, "synthetic": synthetic]
            if e.type == .rightMouseDown { f["button"] = "right" }
            if let id { f["id"] = id } else if let v = content.hitTest(e.locationInWindow) { f["view"] = NSStringFromClass(type(of: v)) }
            if let m = mods(e.modifierFlags) { f["mods"] = m }
            if w.title.isEmpty == false { f["window"] = w.title }
            DebugLog.event("ui-click", f)
        case .leftMouseUp:
            if let d = downAt, hypot(p.x - d.point.x, p.y - d.point.y) > 4 {
                var f: [String: Any] = ["fromX": r(d.point.x), "fromY": r(d.point.y), "toX": r(p.x), "toY": r(p.y), "synthetic": synthetic]
                if let id = d.id { f["id"] = id }
                DebugLog.event("ui-drag", f)
            }
            downAt = nil
        case .keyDown:
            let typing = w.firstResponder is NSTextView && !e.modifierFlags.contains(.command)
            if typing {
                // One line per burst of typing, and never what was typed: text fields hold prompts and names.
                if Date().timeIntervalSince(lastTyping) > 2 { DebugLog.event("ui-typing", ["synthetic": synthetic]) }
                lastTyping = Date()
                return
            }
            var f: [String: Any] = ["key": keyName(e), "synthetic": synthetic]
            if let m = mods(e.modifierFlags) { f["mods"] = m }
            if e.isARepeat { f["repeat"] = true }
            DebugLog.event("ui-key", f)
        default: break
        }
    }

    private static let keyNames: [UInt16: String] = [49: "space", 123: "left", 124: "right", 126: "up", 125: "down", 115: "home", 119: "end",
                                                     51: "delete", 117: "forwarddelete", 36: "return", 76: "enter", 53: "escape", 48: "tab",
                                                     122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
    private static func keyName(_ e: NSEvent) -> String {
        if let n = keyNames[e.keyCode] { return n }
        let c = e.charactersIgnoringModifiers ?? ""
        return c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 }) ? c : "keycode-\(e.keyCode)"
    }
    private static func mods(_ f: NSEvent.ModifierFlags) -> String? {
        var m: [String] = []
        if f.contains(.command) { m.append("cmd") }; if f.contains(.shift) { m.append("shift") }
        if f.contains(.option) { m.append("opt") }; if f.contains(.control) { m.append("ctrl") }
        return m.isEmpty ? nil : m.joined(separator: "+")
    }
    private static func r(_ v: CGFloat) -> Double { Double(v).rounded() }
}
