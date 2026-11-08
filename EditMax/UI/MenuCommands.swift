import SwiftUI
import AppKit

/// What the menus ask of the front project's editor. A menu posts one; the window whose project is active runs it
/// (EditorRootView), the same way Export and Full Screen Preview reach it.
enum EditorCommand: String {
    case split, transition, marker, closeGaps, deleteRange, reframe, slowMotion, normalSpeed, fast
    case zoomIn, zoomOut, importMedia
    case askAgent, dictate, stopAgent, talkStart, talkStop
    case showInspector, showChat, showAgents, showHistory
}

extension Notification.Name {
    static let editmaxCommand = Notification.Name("io.openhorizon.editmax.command")
}

@MainActor func postEditorCommand(_ c: EditorCommand) { NotificationCenter.default.post(name: .editmaxCommand, object: c.rawValue) }

/// Runs the menus' commands in the window whose project is active.
struct EditorCommandReceiver: ViewModifier {
    let document: EditMaxDocument
    let state: EditorState
    let player: PlayerController
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .editmaxCommand)) { n in
            guard DocumentRegistry.shared.active?.id == document.id,
                  let c = (n.object as? String).flatMap(EditorCommand.init(rawValue:)) else { return }
            EditorActions(document: document, state: state, player: player).run(c)
        }
    }
}

extension EditorActions {
    /// Runs a menu command in this editor.
    func run(_ c: EditorCommand) {
        switch c {
        case .split: splitAtPlayhead()
        case .transition: addTransition()
        case .marker: addMarker()
        case .closeGaps: closeGaps()
        case .deleteRange: deleteRange()
        case .reframe: reframeSelection()
        case .slowMotion: setSpeed(0.5)
        case .normalSpeed: setSpeed(1)
        case .fast: setSpeed(2)
        case .zoomIn: zoom(1.4)
        case .zoomOut: zoom(1 / 1.4)
        case .importMedia:
            if state.focusMode { state.focusMode = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { state.importRequest += 1 }   // once the media list is on screen
        case .askAgent, .dictate:
            if state.chat == nil { state.chat = ChatSession(document: document) }
            if !state.focusMode { state.inspectorTab = .chat }
            if c == .dictate { state.chat?.toggleDictation() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { state.chat?.focusRequest += 1 }   // once the field is on screen
        case .stopAgent: if state.chat?.isRunning == true { state.chat?.stop() }
        case .talkStart:   // push to talk: the chat comes up and listens while the key is held
            if state.chat == nil { state.chat = ChatSession(document: document) }
            if !state.focusMode { state.inspectorTab = .chat }
            state.chat?.startDictation()
        case .talkStop: state.chat?.stopDictation()
        case .showInspector: state.focusMode = false; state.inspectorTab = .inspector
        case .showChat: state.focusMode = false; state.inspectorTab = .chat
        case .showAgents: state.focusMode = false; state.inspectorTab = .agents
        case .showHistory: state.focusMode = false; state.inspectorTab = .history
        }
    }

    /// Auto-reframe on each selected video clip, faces first (the inspector's Auto-reframe, for several clips at once).
    func reframeSelection() {
        let ids = state.selectedClipIDs.map(\.uuidString)
        guard !ids.isEmpty else { NSSound.beep(); return }
        let x = ToolExecutor(document: document, origin: .user)
        Task {
            var failed = 0
            for id in ids { do { _ = try await x.autoReframe(id) } catch { failed += 1 } }
            if failed == ids.count { NSSound.beep() }
        }
    }

    /// Plays the selected clips at `speed` (0.5 slow motion, 2 twice as fast).
    func setSpeed(_ speed: Double) {
        guard !state.selectedClipIDs.isEmpty else { NSSound.beep(); return }
        let x = ToolExecutor(document: document, origin: .user)
        for id in state.selectedClipIDs { try? x.setClipProperties(id.uuidString, speed: speed) }
    }
}

// MARK: Menus
// Only chords here: a menu item bound to a plain letter would take that letter from the chat field. The plain keys
// (Space, J K L, I O, S, M…) work in the editor itself and are listed in Help ▸ Keyboard Shortcuts.

/// Clip ▸ the edits a reel needs most, each with a chord.
struct ClipCommands: Commands {
    @ObservedObject private var keys = ShortcutStore.shared
    var body: some Commands {
        CommandMenu("Clip") {
            Button("Split at Playhead") { postEditorCommand(.split) }.keyboardShortcut(keys.menuShortcut(.split))
            Button("Add Cross Dissolve") { postEditorCommand(.transition) }.keyboardShortcut(keys.menuShortcut(.transition))
            Button("Add Marker") { postEditorCommand(.marker) }.keyboardShortcut(keys.menuShortcut(.addMarker))
            Divider()
            Menu("Speed") {
                Button("Slow Motion (0.5×)") { postEditorCommand(.slowMotion) }.keyboardShortcut(keys.menuShortcut(.slowMotion))
                Button("Normal (1×)") { postEditorCommand(.normalSpeed) }.keyboardShortcut(keys.menuShortcut(.normalSpeed))
                Button("Fast (2×)") { postEditorCommand(.fast) }.keyboardShortcut(keys.menuShortcut(.fast))
            }
            Button("Auto-Reframe Selected Clips") { postEditorCommand(.reframe) }.keyboardShortcut(keys.menuShortcut(.reframe))
            Divider()
            Button("Close Gaps") { postEditorCommand(.closeGaps) }.keyboardShortcut(keys.menuShortcut(.closeGaps))
            Button("Delete In to Out") { postEditorCommand(.deleteRange) }.keyboardShortcut(keys.menuShortcut(.deleteInOut))
        }
    }
}

/// Agent ▸ talk to the editor's agent from anywhere in the window.
struct AgentCommands: Commands {
    @ObservedObject private var keys = ShortcutStore.shared
    var body: some Commands {
        CommandMenu("Agent") {
            Button("Ask the Agent…") { postEditorCommand(.askAgent) }.keyboardShortcut(keys.menuShortcut(.askAgent))
            Button("Speak to the Agent") { postEditorCommand(.dictate) }.keyboardShortcut(keys.menuShortcut(.dictate))
            Button("Stop the Agent") { postEditorCommand(.stopAgent) }.keyboardShortcut(keys.menuShortcut(.stopAgent))
            Divider()
            PushToTalkMenuLine()
        }
    }
}

/// View ▸ the inspector's tabs and the timeline's zoom; File ▸ Import Media….
struct PanelCommands: Commands {
    @ObservedObject private var keys = ShortcutStore.shared
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Inspector") { postEditorCommand(.showInspector) }.keyboardShortcut(keys.menuShortcut(.showInspector))
            Button("Chat") { postEditorCommand(.showChat) }.keyboardShortcut(keys.menuShortcut(.showChat))
            Button("Agents") { postEditorCommand(.showAgents) }.keyboardShortcut(keys.menuShortcut(.showAgents))
            Button("History") { postEditorCommand(.showHistory) }.keyboardShortcut(keys.menuShortcut(.showHistory))
            Divider()
            Button("Zoom In Timeline") { postEditorCommand(.zoomIn) }.keyboardShortcut(keys.menuShortcut(.zoomIn))
            Button("Zoom Out Timeline") { postEditorCommand(.zoomOut) }.keyboardShortcut(keys.menuShortcut(.zoomOut))
        }
        CommandGroup(before: .saveItem) {
            Button("Import Media…") { postEditorCommand(.importMedia) }.keyboardShortcut(keys.menuShortcut(.importMedia))
        }
    }
}

/// Help ▸ Welcome Tour, Keyboard Shortcuts.
struct HelpCommands: Commands {
    @ObservedObject private var keys = ShortcutStore.shared
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Welcome Tour") { WelcomeTour.shared.replay() }
            Button("Keyboard Shortcuts") { openWindow(id: KeyboardShortcutsView.windowID) }.keyboardShortcut(keys.menuShortcut(.keyboardShortcuts))
        }
    }
}

/// Agent ▸ the push-to-talk key, as a line: a held key cannot be a menu shortcut, so the menu says where it is.
private struct PushToTalkMenuLine: View {
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        let key = PushToTalk.Key(rawValue: settings.pushToTalk) ?? .rightOption
        if let s = key.symbol { Text("Push to Talk: hold \(s)") } else { Text("Push to Talk: off (Settings ▸ Shortcuts)") }
    }
}

// MARK: Keyboard Shortcuts window

/// Every key in one place, the plain editor keys included: they are not in the menus, so this is where they are found.
/// The keys are the ones in use (Settings ▸ Shortcuts changes them).
struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"
    @ObservedObject private var store = ShortcutStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    /// Keys that are not in the store: macOS's fixed ones and the chat's.
    private func extras(_ g: ShortcutAction.Group) -> [(String, String)] {
        switch g {
        case .editing: return [("⌘Z  ⇧⌘Z", "Undo, redo")]
        case .agent:
            let ptt = (PushToTalk.Key(rawValue: settings.pushToTalk) ?? .rightOption).symbol.map { "Hold \($0)" } ?? "Off"
            return [(ptt, "Push to talk: listens while held, stops when you let go"), ("Return  or  ⌘↩", "Send (stops listening first)")]
        case .file: return [("⌘N", "New project")]
        default: return []
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Text("Single keys work while the timeline or player has the keyboard, not while you type in the chat. Click the timeline first.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Change Keys…") { SettingsView.show(.shortcuts, using: openSettings) }.uiFrame("shortcuts.change")
                }
                ForEach(ShortcutAction.Group.allCases, id: \.self) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(g.rawValue).font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                            ForEach(ShortcutAction.allCases.filter { $0.group == g }) { a in
                                GridRow { keys(store.combos(a).isEmpty ? "None" : store.display(a)); Text(a.title).foregroundStyle(.secondary) }
                            }
                            ForEach(extras(g), id: \.0) { k, what in GridRow { keys(k); Text(what).foregroundStyle(.secondary) } }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 600, height: 660)
    }

    private func keys(_ s: String) -> some View {
        Text(s).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit().frame(minWidth: 150, alignment: .leading)
    }
}
