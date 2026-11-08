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
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard monitor == nil, window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = self.window, e.window == w, !(w.firstResponder is NSTextView) else { return e }
            return self.handler?(e) == true ? nil : e
        }
        UIRegistry.shared.keyHandler = { [weak self] e in self?.handler?(e) ?? false }   // the MCP driver's direct path
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
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
