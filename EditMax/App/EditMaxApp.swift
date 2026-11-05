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
            CommandGroup(after: .toolbar) {
                Button("Full Screen Preview") { NotificationCenter.default.post(name: .editmaxFullScreenPreview, object: nil) }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Focus on Player and Chat") { NotificationCenter.default.post(name: .editmaxFocusMode, object: nil) }.keyboardShortcut("f", modifiers: [.command, .option])
                Button("Before / After") { NotificationCenter.default.post(name: .editmaxCompare, object: nil) }.keyboardShortcut("b", modifiers: [.command, .option])
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
        Group {
            if state.focusMode {
                HSplitView {
                    VStack(spacing: 0) {
                        previewArea
                        TransportBar(player: player, fps: document.project.settings.fps)
                    }
                    .frame(minWidth: 480)
                    focusChat.frame(minWidth: 340, idealWidth: 440, maxWidth: 680)
                }
            } else {
                editorLayout
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .editmaxCompare)) { _ in
            if DocumentRegistry.shared.active?.id == document.id, document.project.hasColorGrade { player.cycleCompare() }
        }
        .onChange(of: document.project.hasColorGrade) { _, graded in if !graded, player.compareMode != .off { player.compareMode = .off } }
        .onReceive(NotificationCenter.default.publisher(for: .editmaxFocusMode)) { _ in
            if DocumentRegistry.shared.active?.id == document.id { state.focusMode.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editmaxFullScreenPreview)) { _ in
            if DocumentRegistry.shared.active?.id == document.id { FullScreenPreview.shared.toggle(player, keys: EditorActions(document: document, state: state, player: player).handle) }
        }
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

    /// The normal editor: media, preview, inspector above the timeline.
    private var editorLayout: some View {
        VSplitView {
            HSplitView {
                AssetsSidebar(document: document).frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                previewArea.frame(minWidth: 400)
                InspectorView(document: document).frame(minWidth: 280, idealWidth: 360, maxWidth: 560)
            }
            .frame(minHeight: 320)
            TimelineView(document: document, player: player).frame(minHeight: 200, idealHeight: 280)
        }
    }

    /// Focus: only the player and the chat, for directing the agent while watching the picture (⌥⌘F or the preview button).
    private var focusChat: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("Chat").font(.headline)
                Spacer()
                Button { state.focusMode = false } label: { Label("Back to editor", systemImage: "rectangle.3.group") }
                    .controlSize(.small).pointer().uiFrame("focus.exit").uiTap("focus.exit") { state.focusMode = false }.help("Back to the full editor (⌥⌘F)")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let chat = state.chat { ChatView(chat: chat) } else { Spacer() }
        }
    }

    /// The picture with its overlays (empty state, version banner, scopes / full screen / focus buttons), scopes and build errors.
    private var previewArea: some View {
        VStack(spacing: 0) {
            PreviewView(controller: player)
                .overlay {
                    if document.project.allClips.isEmpty {
                        VStack(spacing: 8) {
                            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 72, height: 72).opacity(0.55)
                            Text("Drop a clip on the timeline to see it here").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .top) {
                    if let v = state.viewingVersion, !v.isCurrent {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Viewing version: \(v.label) · \(v.date.formatted(date: .omitted, time: .shortened))").lineLimit(1)
                            Button("Back to current") { state.viewingVersion = nil; player.view(nil) }.controlSize(.small).pointer().uiFrame("preview.versionBack")
                                .uiTap("preview.versionBack") { state.viewingVersion = nil; player.view(nil) }
                            Button("Restore") { state.viewingVersion = nil; player.view(nil); try? document.restore(version: v, origin: .user) }.controlSize(.small).buttonStyle(.borderedProminent).pointer().uiFrame("preview.versionRestore")
                                .uiTap("preview.versionRestore", key: v.id) { state.viewingVersion = nil; player.view(nil); try? document.restore(version: v, origin: .user) }
                        }
                        .font(.system(size: 12)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.orange.opacity(0.85), in: Capsule()).padding(8)
                        .uiFrame("preview.versionBanner")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 6) {
                        Button { player.scopesEnabled.toggle() } label: {
                            Label("Scopes", systemImage: "waveform.path.ecg").labelStyle(.iconOnly).font(.system(size: 12))
                                .padding(6).background(.black.opacity(player.scopesEnabled ? 0.6 : 0.35), in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(player.scopesEnabled ? Color.accentColor : .white)
                        }
                        .buttonStyle(.plain).help(player.scopesEnabled ? "Hide the scopes" : "Show the scopes (waveform and histogram)").pointer().uiFrame("preview.scopes")
                        Button { player.cycleCompare() } label: {
                            Label("Before / after", systemImage: player.compareMode == .off ? "rectangle.lefthalf.inset.filled" : player.compareMode == .split ? "rectangle.split.2x1.fill" : "rectangle.fill")
                                .labelStyle(.iconOnly).font(.system(size: 12))
                                .padding(6).background(.black.opacity(player.compareMode != .off ? 0.6 : 0.35), in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(player.compareMode != .off ? Color.accentColor : .white)
                        }
                        .buttonStyle(.plain).disabled(!document.project.hasColorGrade)
                        .help(!document.project.hasColorGrade ? "Before / after compares the color grade; no clip is graded yet" : player.compareMode == .off ? "Before / after the color grade: split the picture at a divider you can drag (⌥⌘B)" : player.compareMode == .split ? "Show the whole picture before the grade (⌥⌘B)" : "Back to the graded picture (⌥⌘B)")
                        .pointer().uiFrame("preview.compare").uiTap("preview.compare") { if document.project.hasColorGrade { player.cycleCompare() } }
                        Button { FullScreenPreview.shared.toggle(player, keys: EditorActions(document: document, state: state, player: player).handle) } label: {
                            Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right").labelStyle(.iconOnly).font(.system(size: 12))
                                .padding(6).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.white)
                        }
                        .buttonStyle(.plain).help("Show the preview full screen (⇧⌘F, or double-click the preview; Esc leaves)").pointer().uiFrame("preview.fullscreen")
                        Button { state.focusMode.toggle(); if state.focusMode, state.chat == nil { state.chat = ChatSession(document: document) } } label: {
                            Label("Focus", systemImage: state.focusMode ? "rectangle.3.group" : "rectangle.split.2x1").labelStyle(.iconOnly).font(.system(size: 12))
                                .padding(6).background(.black.opacity(state.focusMode ? 0.6 : 0.35), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(state.focusMode ? Color.accentColor : .white)
                        }
                        .buttonStyle(.plain).help(state.focusMode ? "Back to the full editor (⌥⌘F)" : "Focus: just the player and the chat (⌥⌘F)").pointer().uiFrame("preview.focus")
                        .uiTap("preview.focus") { state.focusMode.toggle() }
                    }
                    .padding(8)
                }
            .overlay { if player.compareMode != .off { CompareOverlay(player: player, aspect: Double(document.project.settings.width) / Double(max(1, document.project.settings.height))) } }
            if player.scopesEnabled { ScopesView(data: player.scopes) }
            if let e = player.buildError { Text(e).font(.caption).foregroundStyle(.red).padding(4) }
        }
    }

    private func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = document.displayName + ".mp4"
        let format = ExportFormatBox()
        let host = NSHostingView(rootView: ExportFormatPicker(box: format))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 48)
        panel.accessoryView = host
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.isExporting = true
        state.exportStatus = "Exporting…"
        Task {
            do {
                let r = try await ToolExecutor(document: document, origin: .user).exportVideo(to: url.path, preset: format.preset) { p in
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

extension Notification.Name {
    static let editmaxExport = Notification.Name("io.openhorizon.editmax.export")
    static let editmaxFullScreenPreview = Notification.Name("io.openhorizon.editmax.fullScreenPreview")
    static let editmaxFocusMode = Notification.Name("io.openhorizon.editmax.focusMode")
    static let editmaxCompare = Notification.Name("io.openhorizon.editmax.compare")
}

/// The format choice in the export save panel.
final class ExportFormatBox: ObservableObject { @Published var preset: ExportService.Preset = .high }
struct ExportFormatPicker: View {
    @ObservedObject var box: ExportFormatBox
    var body: some View {
        Picker("Format", selection: $box.preset) {
            Text("H.264, 8-bit (plays everywhere)").tag(ExportService.Preset.high)
            Text("HEVC 10-bit, Main 10 (for grading)").tag(ExportService.Preset.hevc10)
        }
        .pickerStyle(.menu).pointer().uiFrame("export.format")
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
