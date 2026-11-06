import AppKit

/// Every user interaction in the EditMax window, as lines in `editmax.log` beside the edits and the MCP calls, so a
/// session can be read back in order: `ui-click` (with the `uiFrame` id under the pointer, else the view class),
/// `ui-drag`, `ui-key`, `ui-typing` (that typing happened in a text field, never the characters), `ui-menu`.
/// Events the MCP driver posted carry `synthetic: true`.
///
/// Two things a plain event list cannot show are measured as well. A drag records how late each move was delivered
/// (`maxLateMs`: a blocked main thread hands over queued moves with their original timestamps, so this is exactly
/// "the control is behind the mouse"), the longest pause between moves, and whether video was playing. A click that
/// hit no registered element records the nearest one within 24 points (`near`, `distance`): that is how a control
/// that is hard to grab shows up. And a watchdog logs `ui-hang` whenever the main thread stops answering for 150 ms.
@MainActor
enum InteractionLog {
    /// The driver sets this just before it posts events; events dispatched until then are marked synthetic.
    static var syntheticUntil = Date.distantPast
    private static var downAt: (point: CGPoint, id: String?, drag: DragTiming)?
    private static var lastTyping = Date.distantPast

    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown]) { e in
            log(e); return e
        }
        Watchdog.start()
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
            downAt = (p, id, DragTiming(start: e.timestamp))
            var f: [String: Any] = ["x": r(p.x), "y": r(p.y), "clicks": e.clickCount, "synthetic": synthetic]
            if e.type == .rightMouseDown { f["button"] = "right" }
            if let id { f["id"] = id } else {
                if let v = content.hitTest(e.locationInWindow) { f["view"] = NSStringFromClass(type(of: v)) }
                if let n = UIRegistry.shared.nearest(to: p, within: 24) { f["near"] = n.id; f["distance"] = r(n.distance) }
            }
            if let m = mods(e.modifierFlags) { f["mods"] = m }
            if w.title.isEmpty == false { f["window"] = w.title }
            DebugLog.event("ui-click", f)
        case .leftMouseDragged:
            downAt?.drag.moved(at: e.timestamp, now: ProcessInfo.processInfo.systemUptime)
        case .leftMouseUp:
            if let d = downAt, hypot(p.x - d.point.x, p.y - d.point.y) > 4 {
                var f: [String: Any] = ["fromX": r(d.point.x), "fromY": r(d.point.y), "toX": r(p.x), "toY": r(p.y), "synthetic": synthetic,
                                        "ms": Int((e.timestamp - d.drag.start) * 1000), "updates": d.drag.updates,
                                        "maxLateMs": Int(d.drag.maxLate * 1000), "maxGapMs": Int(d.drag.maxGap * 1000),
                                        "playing": UIRegistry.shared.anyPlaying]
                if let id = d.id { f["id"] = id }
                if d.drag.maxLate > 0.1 { f["laggy"] = true }
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

/// How a drag was delivered: how many moves, the longest pause between them, and how late the latest one arrived
/// (event timestamp against the clock at delivery). Pure, so a test can feed it times.
struct DragTiming {
    let start: TimeInterval
    private(set) var updates = 0
    private(set) var maxGap: TimeInterval = 0
    private(set) var maxLate: TimeInterval = 0
    private var last: TimeInterval
    init(start: TimeInterval) { self.start = start; last = start }
    mutating func moved(at stamp: TimeInterval, now: TimeInterval) {
        updates += 1
        maxGap = max(maxGap, stamp - last); last = stamp
        maxLate = max(maxLate, now - stamp)
    }
}

/// A background timer asks the main thread for the time every 250 ms; when the answer is more than 150 ms late the
/// main thread was blocked, and one `ui-hang` line per episode records the worst delay and whether video was playing.
enum Watchdog {
    static let interval: TimeInterval = 0.25, threshold: TimeInterval = 0.15
    private static let queue = DispatchQueue(label: "editmax.watchdog", qos: .utility)
    private static var timer: DispatchSourceTimer?
    private static var episodeMax: TimeInterval = 0
    private static var lastLate = Date.distantPast
    static func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: interval)   // the first seconds after launch are the splash and the first layout
        t.setEventHandler {
            let sent = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { MainActor.assumeIsolated { answered(sent: sent) } }
        }
        t.resume(); timer = t
    }
    @MainActor private static func answered(sent: TimeInterval) {
        let late = ProcessInfo.processInfo.systemUptime - sent
        if late > threshold {
            episodeMax = max(episodeMax, late); lastLate = Date()
        } else if episodeMax > 0, Date().timeIntervalSince(lastLate) > 0.5 {
            DebugLog.event("ui-hang", ["ms": Int(episodeMax * 1000), "playing": UIRegistry.shared.anyPlaying])
            episodeMax = 0
        }
    }
}
