import SwiftUI

@main
struct EditMaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var mcp = MCPService.shared
    init() { MCPService.shared.start(); CodemaxInstaller.shared.ensureInstalled(); CodemaxUpdater.shared.start() }

    var body: some Scene {
        DocumentGroup(newDocument: { EditMaxDocument() }) { file in
            EditorRootView(document: file.document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1380, height: 860)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Export Video…") { NotificationCenter.default.post(name: .editmaxExport, object: nil) }.keyboardShortcut("e", modifiers: [.command])
            }
            EditCommands()
        }
    }
}

struct EditorRootView: View {
    @ObservedObject var document: EditMaxDocument
    let fileURL: URL?
    @StateObject private var state = EditorState()
    @StateObject private var player = PlayerController()

    var body: some View {
        VSplitView {
            HSplitView {
                AssetsSidebar(document: document).frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                VStack(spacing: 0) {
                    PreviewView(controller: player)
                        .overlay {
                            if document.project.allClips.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "play.rectangle").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                                    Text("Drop a clip on the timeline to see it here").font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                .allowsHitTesting(false)
                            }
                        }
                    if let e = player.buildError { Text(e).font(.caption).foregroundStyle(.red).padding(4) }
                }
                .frame(minWidth: 400)
                InspectorView(document: document).frame(minWidth: 280, idealWidth: 360, maxWidth: 560)
            }
            .frame(minHeight: 320)
            TimelineView(document: document, player: player).frame(minHeight: 200, idealHeight: 280)
        }
        .environmentObject(state)
        .environmentObject(player)
        .focusedSceneObject(document)
        .background(KeyMonitor { e in EditorActions(document: document, state: state, player: player).handle(e) })
        .onAppear { UIRegistry.shared.playheads[document.id] = { [weak player] in player?.currentTime } }
        .frame(minWidth: 1000, minHeight: 640)
        .onAppear { document.fileURL = fileURL; DocumentRegistry.shared.register(document); player.bind(to: document); if state.chat == nil { state.chat = ChatSession(document: document) }
            // Debug affordances (used by automated checks): EDITMAX_INSPECTOR_TAB=chat|agents|history opens that tab;
            // EDITMAX_CHAT_AUTOSEND="..." sends a first chat message on launch.
            if let t = ProcessInfo.processInfo.environment["EDITMAX_INSPECTOR_TAB"], let tab = EditorState.InspectorTab.allCases.first(where: { $0.rawValue.lowercased() == t.lowercased() }) {
                state.inspectorTab = tab
            }
            if let t = ProcessInfo.processInfo.environment["EDITMAX_CHAT_AUTOSEND"], !t.isEmpty, state.chat?.items.isEmpty == true {
                state.inspectorTab = .chat; state.chat?.input = t; state.chat?.send()
            }
        }
        .onChange(of: fileURL) { _, new in document.fileURL = new }
        .onDisappear { DocumentRegistry.shared.unregister(document); player.pause() }
        .background(WindowFocusObserver { DocumentRegistry.shared.activate(document) })
        .onReceive(NotificationCenter.default.publisher(for: .editmaxExport)) { _ in
            guard DocumentRegistry.shared.activeID == document.id, !state.isExporting else { return }
            exportVideo()
        }
        .overlay(alignment: .top) {
            if let s = state.exportStatus {
                Text(s).font(.caption).padding(8).background(.thinMaterial).cornerRadius(6).padding(8)
            }
        }
    }

    private func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = document.displayName + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.isExporting = true
        state.exportStatus = "Exporting…"
        Task {
            do {
                let r = try await ToolExecutor(document: document, origin: .user).exportVideo(to: url.path) { p in
                    Task { @MainActor in state.exportStatus = "Exporting… \(Int(p * 100))%" }
                }
                state.exportStatus = "Exported \(Timecode.string(r.duration)) to \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                state.exportStatus = "Export failed: \(error.localizedDescription)"
            }
            state.isExporting = false
            try? await Task.sleep(for: .seconds(6))
            state.exportStatus = nil
        }
    }
}

/// Undo/Redo for the focused window's document. A text field being edited keeps its own undo (typos), the project
/// gets everything else. The items follow the document, so they update as edits land.
struct EditCommands: Commands {
    @FocusedObject private var document: EditMaxDocument?

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(document?.undoLabel.map { "Undo \($0)" } ?? "Undo") { if !textUndo(redo: false) { document?.undo() } }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(document == nil || !(document!.canUndo || editingText))
            Button(document?.redoLabel.map { "Redo \($0)" } ?? "Redo") { if !textUndo(redo: true) { document?.redo() } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(document == nil || !(document!.canRedo || editingText))
        }
    }

    private var editingText: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

    /// Routes ⌘Z to the text being edited when it has something to undo. Returns false when the project should take it.
    private func textUndo(redo: Bool) -> Bool {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, let um = tv.undoManager else { return false }
        if redo { guard um.canRedo else { return false }; um.redo() } else { guard um.canUndo else { return false }; um.undo() }
        return true
    }
}

/// Marks the document active when its window becomes key, so agents default to what the user is looking at.
struct WindowFocusObserver: NSViewRepresentable {
    let onFocus: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak v] n in
            if let w = n.object as? NSWindow, w == v?.window { onFocus() }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension Notification.Name { static let editmaxExport = Notification.Name("io.openhorizon.editmax.export") }
