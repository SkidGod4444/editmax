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

    /// A 0.5 s cross dissolve into each selected clip (or a longer one if it already has a transition).
    func addTransition() { for id in state.selectedClipIDs { _ = try? x.setTransition(id.uuidString, kind: "crossDissolve", duration: nil) } }

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

    /// Returns true when the key was used.
    func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = mods.contains(.shift)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods.contains(.command) {
            guard !mods.contains(.option), !mods.contains(.control) else { return false }
            switch chars {
            case "=", "+": zoom(1.4); return true
            case "-": zoom(1 / 1.4); return true
            case "t": addTransition(); return true
            case "z": if shift { document.redo() } else { document.undo() }; return true
            default: return false
            }
        }
        guard !mods.contains(.control), !mods.contains(.option) else { return false }
        switch e.keyCode {
        case 49: player.togglePlay(); return true                                    // space
        case 123: player.step(frames: shift ? -10 : -1, fps: fps); return true       // ←
        case 124: player.step(frames: shift ? 10 : 1, fps: fps); return true         // →
        case 115: player.pause(); player.seek(to: 0); return true                    // home
        case 119: player.pause(); player.seek(to: document.project.duration); return true   // end
        case 51, 117: deleteSelection(); return true                                 // delete, forward delete
        default: break
        }
        switch chars {
        case "j": player.shuttle(backward: true); return true
        case "k": player.pause(); return true
        case "l": player.shuttle(backward: false); return true
        case "i": setIn(); return true
        case "o": setOut(); return true
        case "m": addMarker(); return true
        case "s": splitAtPlayhead(); return true
        case "x": clearInOut(); return true
        default: return false
        }
    }
}
