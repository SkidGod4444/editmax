import SwiftUI
import AppKit

/// What the menus ask of the front project's editor. A menu posts one; the window whose project is active runs it
/// (EditorRootView), the same way Export and Full Screen Preview reach it.
enum EditorCommand: String {
    case split, transition, marker, closeGaps, deleteRange, reframe, slowMotion, normalSpeed, fast
    case zoomIn, zoomOut, importMedia
    case askAgent, dictate, stopAgent
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
    var body: some Commands {
        CommandMenu("Clip") {
            Button("Split at Playhead") { postEditorCommand(.split) }.keyboardShortcut("b", modifiers: .command)
            Button("Add Cross Dissolve") { postEditorCommand(.transition) }.keyboardShortcut("t", modifiers: .command)
            Button("Add Marker") { postEditorCommand(.marker) }.keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Menu("Speed") {
                Button("Slow Motion (0.5×)") { postEditorCommand(.slowMotion) }.keyboardShortcut("1", modifiers: [.command, .control])
                Button("Normal (1×)") { postEditorCommand(.normalSpeed) }.keyboardShortcut("2", modifiers: [.command, .control])
                Button("Fast (2×)") { postEditorCommand(.fast) }.keyboardShortcut("3", modifiers: [.command, .control])
            }
            Button("Auto-Reframe Selected Clips") { postEditorCommand(.reframe) }.keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Close Gaps") { postEditorCommand(.closeGaps) }.keyboardShortcut("g", modifiers: [.command, .option])
            Button("Delete In to Out") { postEditorCommand(.deleteRange) }.keyboardShortcut(.delete, modifiers: [.command, .option])
        }
    }
}

/// Agent ▸ talk to the editor's agent from anywhere in the window.
struct AgentCommands: Commands {
    var body: some Commands {
        CommandMenu("Agent") {
            Button("Ask the Agent…") { postEditorCommand(.askAgent) }.keyboardShortcut("l", modifiers: .command)
            Button("Speak to the Agent") { postEditorCommand(.dictate) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Stop the Agent") { postEditorCommand(.stopAgent) }.keyboardShortcut(".", modifiers: .command)
        }
    }
}

/// View ▸ the inspector's tabs and the timeline's zoom; File ▸ Import Media….
struct PanelCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Inspector") { postEditorCommand(.showInspector) }.keyboardShortcut("1", modifiers: .command)
            Button("Chat") { postEditorCommand(.showChat) }.keyboardShortcut("2", modifiers: .command)
            Button("Agents") { postEditorCommand(.showAgents) }.keyboardShortcut("3", modifiers: .command)
            Button("History") { postEditorCommand(.showHistory) }.keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Zoom In Timeline") { postEditorCommand(.zoomIn) }.keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out Timeline") { postEditorCommand(.zoomOut) }.keyboardShortcut("-", modifiers: .command)
        }
        CommandGroup(before: .saveItem) {
            Button("Import Media…") { postEditorCommand(.importMedia) }.keyboardShortcut("i", modifiers: .command)
        }
    }
}

/// Help ▸ Welcome Tour, Keyboard Shortcuts.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Welcome Tour") { WelcomeTour.shared.replay() }
            Button("Keyboard Shortcuts") { openWindow(id: KeyboardShortcutsView.windowID) }.keyboardShortcut("/", modifiers: .command)
        }
    }
}

// MARK: Keyboard Shortcuts window

/// Every key in one place, the plain editor keys included: they are not in the menus, so this is where they are found.
struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"
    struct Row: Identifiable { let keys: String; let what: String; var id: String { keys + what } }
    struct Section: Identifiable { let title: String; let rows: [Row]; var id: String { title } }

    static let sections: [Section] = [
        Section(title: "Playback", rows: [
            Row(keys: "Space", what: "Play or pause"),
            Row(keys: "J  K  L", what: "Play backward, pause, play forward (press again to go faster)"),
            Row(keys: "←  →", what: "One frame back or forward (⇧ for ten)"),
            Row(keys: "Home  End", what: "Go to the start or the end"),
            Row(keys: "[  ]", what: "Previous or next keyframe of the selected clips"),
        ]),
        Section(title: "Marking", rows: [
            Row(keys: "I  O", what: "Mark in, mark out"),
            Row(keys: "X", what: "Clear in and out"),
            Row(keys: "⌥⌘⌫", what: "Delete in to out, closing the gap"),
            Row(keys: "M  or  ⇧⌘M", what: "Add a marker at the playhead"),
        ]),
        Section(title: "Editing", rows: [
            Row(keys: "S  or  ⌘B", what: "Split the selected clips at the playhead"),
            Row(keys: "Delete", what: "Remove the selection"),
            Row(keys: "⌘T", what: "Cross dissolve into the selected clips"),
            Row(keys: "⌃⌘1  ⌃⌘2  ⌃⌘3", what: "Speed: slow motion, normal, fast"),
            Row(keys: "⌥⌘R", what: "Auto-reframe the selected clips (faces first)"),
            Row(keys: "⌥⌘G", what: "Close gaps"),
            Row(keys: "A  R  Y  U", what: "Select, roll, slip, slide tools"),
            Row(keys: ",  .", what: "Insert or overwrite from the source viewer"),
            Row(keys: "F", what: "Match frame"),
            Row(keys: "⌘Z  ⇧⌘Z", what: "Undo, redo"),
        ]),
        Section(title: "Agent", rows: [
            Row(keys: "⌘L", what: "Ask the agent (opens the chat)"),
            Row(keys: "⇧⌘D", what: "Speak instead of typing; again to stop"),
            Row(keys: "Return  or  ⌘↩", what: "Send (stops listening first)"),
            Row(keys: "⌘.", what: "Stop the agent"),
        ]),
        Section(title: "View", rows: [
            Row(keys: "⌘1  ⌘2  ⌘3  ⌘4", what: "Inspector, Chat, Agents, History"),
            Row(keys: "⌘=  ⌘−", what: "Zoom the timeline in or out"),
            Row(keys: "⇧⌘F", what: "Full screen preview"),
            Row(keys: "⌥⌘F", what: "Focus on the player and the chat"),
            Row(keys: "⌥⌘B", what: "Before / after the grade"),
            Row(keys: "⌥⌘S", what: "Source viewer"),
            Row(keys: "⇧⌘P", what: "Home"),
        ]),
        Section(title: "File", rows: [
            Row(keys: "⌘N", what: "New project"),
            Row(keys: "⌘I", what: "Import media"),
            Row(keys: "⌘E  ⇧⌘E  ⌥⌘E", what: "Export video, batch export, export timeline"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Single keys work while the timeline or player has the focus, not while you type in the chat. Click the timeline first.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Self.sections) { s in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.title).font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                            ForEach(s.rows) { r in
                                GridRow {
                                    Text(r.keys).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                                        .frame(minWidth: 130, alignment: .leading)
                                    Text(r.what).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 620)
    }
}
