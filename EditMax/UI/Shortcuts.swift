import SwiftUI
import AppKit

/// Editor keys that work without modifiers (Space, J/K/L, I/O, M, S, arrows, Home/End, Delete) plus the zoom and
/// transition chords. A local event monitor, not menu shortcuts: a plain-letter menu shortcut would steal the letter
/// from any text field, so keys are passed through untouched while a text view has the focus.
struct KeyMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool
    func makeNSView(context: Context) -> KeyMonitorView { let v = KeyMonitorView(); v.handler = handler; return v }
    func updateNSView(_ v: KeyMonitorView, context: Context) { v.handler = handler }
}

final class KeyMonitorView: NSView {
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?
    private var clickMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard monitor == nil, window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = self.window, e.window == w, !(w.firstResponder is NSTextView) else { return e }
            return self.handler?(e) == true ? nil : e
        }
        // A click on the timeline or the player gives the keyboard back to the editor (see `KeyboardAreaView`).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            if let w = self?.window, e.window == w { EditorKeyboard.takeBack(at: e.locationInWindow, in: w) }
            return e
        }
        UIRegistry.shared.keyHandler = { [weak self] e in self?.handler?(e) ?? false }   // the MCP driver's direct path
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }
}

/// Marks a part of the editor (the timeline, the player) where a click gives the keyboard back to the editor. While a
/// text field has the keyboard, every editor key is left to it (`KeyMonitorView`), and in AppKit a click on a plain view
/// does not take the keyboard away: after typing to the agent, Space went on typing spaces into the chat box however
/// often the timeline was clicked, so nothing played or paused. A click in one of these areas ends the typing; the text
/// stays in its field.
final class KeyboardAreaView: NSView {
    static let all = NSHashTable<KeyboardAreaView>.weakObjects()
    /// It marks a place; it never takes a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct KeyboardArea: NSViewRepresentable {
    func makeNSView(context: Context) -> KeyboardAreaView { let v = KeyboardAreaView(); KeyboardAreaView.all.add(v); return v }
    func updateNSView(_ v: KeyboardAreaView, context: Context) {}
}

extension View {
    /// A click anywhere in this view ends typing in a text field, so the editor's keys work again (`KeyboardAreaView`).
    func takesKeyboardOnClick() -> some View { background(KeyboardArea()) }
}

@MainActor
enum EditorKeyboard {
    /// True when a click at `point` (window coordinates) should end typing: a text field has the keyboard, the click lands
    /// in a keyboard area of that window, and not on a text field (typing a track's new name goes on).
    static func shouldTakeBack(at point: NSPoint, in w: NSWindow) -> Bool {
        guard w.firstResponder is NSTextView else { return false }
        var v = w.contentView?.hitTest(point)
        while let view = v {
            if view is NSTextView || view is NSTextField { return false }
            v = view.superview
        }
        return KeyboardAreaView.all.allObjects.contains { a in
            a.window === w && !a.isHiddenOrHasHiddenAncestor && a.convert(a.bounds, to: nil).contains(point)
        }
    }

    static func takeBack(at point: NSPoint, in w: NSWindow) {
        guard shouldTakeBack(at: point, in: w) else { return }
        w.makeFirstResponder(nil)
        DebugLog.event("keyboard-to-editor", [:])
    }
}

/// The editing commands behind the toolbar buttons, the keys and the menus, in one place.
@MainActor
struct EditorActions {
    let document: EditMaxDocument
    let state: EditorState
    let player: PlayerController
    private var x: ToolExecutor { ToolExecutor(document: document, origin: .user) }
    private var fps: Double { document.project.settings.fps }

    /// Moves the playhead to the previous/next keyframe of the selected clips (every animated parameter counts).
    func jumpKeyframe(forward: Bool) {
        let ts = document.project.allClips.filter { state.selectedClipIDs.contains($0.id) }.flatMap { c in c.keyframeTimes.map { c.start + $0 } }.sorted()
        let t = forward ? ts.first { $0 > player.currentTime + 0.001 } : ts.last { $0 < player.currentTime - 0.001 }
        if let t { player.pause(); player.seek(to: t) }
    }

    /// What Play Selection plays: the selected clips (or title) from the first start to the last end, else the In to Out
    /// range; nil when there is neither.
    var selectionRange: ClosedRange<Double>? {
        let clips = document.project.allClips.filter { state.selectedClipIDs.contains($0.id) }
        if let s = clips.map(\.start).min(), let e = clips.map(\.end).max(), e > s { return s...e }
        if let id = state.selectedTextID, let t = document.project.texts.first(where: { $0.id == id }), t.end > t.start { return t.start...t.end }
        if let i = state.inPoint, let o = state.outPoint, o > i { return i...o }
        return nil
    }

    /// Plays the selection once and stops at its end. While anything plays it pauses, as Space does; with nothing selected
    /// and no In to Out range it plays from the playhead.
    func playSelection() {
        if player.isPlaying { player.pause(); return }
        if let r = selectionRange { player.play(from: r.lowerBound, to: r.upperBound) } else { player.play() }
    }

    func splitAtPlayhead() { for id in state.selectedClipIDs { try? x.splitClip(id.uuidString, at: player.currentTime) } }

    func deleteSelection() {
        if !state.selectedClipIDs.isEmpty { try? x.removeClips(state.selectedClipIDs.map(\.uuidString)); state.selectedClipIDs = [] }
        if let t = state.selectedTextID { try? x.removeTexts([t.uuidString]); state.selectedTextID = nil }
    }

    func closeGaps() {
        let ids = Set(document.project.tracks.filter { t in t.clips.contains { state.selectedClipIDs.contains($0.id) } }.map(\.id))
        for t in document.project.tracks where ids.isEmpty || ids.contains(t.id) { try? x.rippleTrack(t.id.uuidString) }
    }

    func addMarker() { _ = x.addMarker(at: player.currentTime, name: nil, colorHex: nil) }

    /// A 0.5 s cross dissolve into each selected clip. A clip that already has a transition keeps it (kind and length):
    /// pressing ⌘T again must never silently swap a push for a dissolve, and an unchanged clip records no history.
    func addTransition() { for id in state.selectedClipIDs { _ = try? x.setTransition(id.uuidString, kind: nil, duration: nil) } }

    func setIn() { state.inPoint = player.currentTime; if let o = state.outPoint, o <= player.currentTime { state.outPoint = nil } }
    func setOut() { state.outPoint = player.currentTime; if let i = state.inPoint, i >= player.currentTime { state.inPoint = nil } }
    func clearInOut() { state.inPoint = nil; state.outPoint = nil }
    var hasRange: Bool { if let i = state.inPoint, let o = state.outPoint { return o - i > 0.01 }; return false }

    /// Ripple-deletes everything between the in and out points on every track.
    func deleteRange() {
        guard let i = state.inPoint, let o = state.outPoint, o > i else { return }
        try? x.rippleDelete(start: i, end: o)
        clearInOut(); player.seek(to: i)
    }

    func zoom(_ factor: Double) { state.pixelsPerSecond = max(10, min(400, state.pixelsPerSecond * factor)) }

    /// Returns true when the key was used. The keys come from Settings ▸ Shortcuts (ShortcutStore); undo and redo are
    /// macOS's and fixed.
    func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == .command || mods == [.command, .shift], e.charactersIgnoringModifiers?.lowercased() == "z" {
            if mods.contains(.shift) { document.redo() } else { document.undo() }
            return true
        }
        guard let a = ShortcutStore.shared.action(matching: e) else { return false }
        return perform(a)
    }

    /// Runs an action. False when only its menu item can (the menu then takes the key).
    func perform(_ a: ShortcutAction) -> Bool {
        let source = SourceActions(document: document, state: state, player: player)
        let post = { (n: Notification.Name) in NotificationCenter.default.post(name: n, object: nil) }
        switch a {
        case .playPause: player.togglePlay()
        case .playSelection: playSelection()
        case .shuttleBack: player.shuttle(backward: true)
        case .pause: player.pause()
        case .shuttleForward: player.shuttle(backward: false)
        case .stepBack: player.step(frames: -1, fps: fps)
        case .stepForward: player.step(frames: 1, fps: fps)
        case .stepBack10: player.step(frames: -10, fps: fps)
        case .stepForward10: player.step(frames: 10, fps: fps)
        case .goToStart: player.pause(); player.seek(to: 0)
        case .goToEnd: player.pause(); player.seek(to: document.project.duration)
        case .prevKeyframe: jumpKeyframe(forward: false)
        case .nextKeyframe: jumpKeyframe(forward: true)
        case .markIn: setIn()
        case .markOut: setOut()
        case .clearInOut: clearInOut()
        case .deleteInOut: run(.deleteRange)
        case .addMarker: addMarker()
        case .split: splitAtPlayhead()
        case .deleteSelection: deleteSelection()
        case .transition: addTransition()
        case .slowMotion: run(.slowMotion)
        case .normalSpeed: run(.normalSpeed)
        case .fast: run(.fast)
        case .reframe: run(.reframe)
        case .closeGaps: run(.closeGaps)
        case .toolSelect: state.editTool = .select
        case .toolRoll: state.editTool = .roll
        case .toolSlip: state.editTool = .slip
        case .toolSlide: state.editTool = .slide
        case .insertFromSource, .overwriteFromSource:
            if let n = source.edit(overwrite: a == .overwriteFromSource) { DebugLog.event("source-edit-refused", ["why": n]); NSSound.beep() }
        case .matchFrame: source.matchFrame()
        case .askAgent: run(.askAgent)
        case .dictate: run(.dictate)
        case .stopAgent: run(.stopAgent)
        case .showInspector: run(.showInspector)
        case .showChat: run(.showChat)
        case .showAgents: run(.showAgents)
        case .showHistory: run(.showHistory)
        case .zoomIn: zoom(1.4)
        case .zoomOut: zoom(1 / 1.4)
        case .fullScreenPreview: post(.editmaxFullScreenPreview)
        case .focusMode: post(.editmaxFocusMode)
        case .compare: post(.editmaxCompare)
        case .sourceViewer: NotificationCenter.default.post(name: .editmaxToggleSource, object: document.id)
        case .home: HomeWindow.shared.show()
        case .importMedia: run(.importMedia)
        case .exportVideo: post(.editmaxExport)
        case .batchExport: post(.editmaxBatchExport)
        case .exportTimeline: post(.editmaxExportTimeline)
        case .keyboardShortcuts: return false
        }
        return true
    }
}
