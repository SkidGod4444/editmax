import SwiftUI

@main
struct EditMaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var mcp = MCPService.shared
    /// The EditMax icon in the menu bar (Settings ▸ General can hide it).
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    init() {
        guard !AppDelegate.isTesting else { return }
        // Downloaded and added fonts first, before any document window restores and renders (FontLibrary.swift).
        FontLibrary.registerInstalledFonts()
        MCPService.shared.start(); CodemaxInstaller.shared.ensureInstalled(); CodemaxUpdater.shared.start(); AppUpdater.shared.start()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { EditMaxDocument() }) { file in
            EditorRootView(document: file.document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1380, height: 860)
        .commands {
            // ⌘N creates a project file in the library (Movies ▸ EditMax Projects), so every project shows on Home and
            // autosaves; the standard in-memory untitled document would vanish when closed unsaved.
            CommandGroup(replacing: .newItem) {
                Button("New Project") { newLibraryProject(Templates.list().first!) }.keyboardShortcut("n", modifiers: [.command])
                Menu("New Project in Format") {
                    ForEach(Templates.list().filter(\.builtin)) { t in Button("\(t.name) · \(t.width)×\(t.height)") { newLibraryProject(t) } }
                }
            }
            CommandGroup(after: .saveItem) {
                Button("Export Video…") { NotificationCenter.default.post(name: .editmaxExport, object: nil) }.keyboardShortcut("e", modifiers: [.command])
                Button("Export Chapters…") { NotificationCenter.default.post(name: .editmaxExportChapters, object: nil) }
                Button("Batch Export…") { NotificationCenter.default.post(name: .editmaxBatchExport, object: nil) }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export Timeline…") { NotificationCenter.default.post(name: .editmaxExportTimeline, object: nil) }.keyboardShortcut("e", modifiers: [.command, .option])
            }
            ViewCommands()
            EditCommands()
            EditingCommands()   // relink, consolidate, source viewer (RelinkSheet.swift)
            UpdateCommands()
        }
        Settings { SettingsView() }
        MenuBarExtra(isInserted: AppDelegate.isTesting ? .constant(false) : $showMenuBarIcon) {   // no icon while tests run
            MenuBarMenu()
        } label: {
            Image(nsImage: MenuBarIcon.image).renderingMode(.template).accessibilityLabel("EditMax")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
func newLibraryProject(_ template: Templates.Info) {
    do { ProjectLibrary.shared.open(try ProjectLibrary.shared.create(template: template)) }
    catch { DebugLog.error("library-create", error); NSAlert(error: error).runModal() }
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
                    previewArea
                        .overlay(alignment: .bottom) { TransportBar(player: player, fps: document.project.settings.fps) }   // glass pill over the picture
                        .frame(minWidth: 480)
                    focusChat.frame(minWidth: 340, idealWidth: 440, maxWidth: 680)
                }
            } else {
                editorLayout
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { HomeWindow.shared.show() } label: { Label("Home", systemImage: "house") }.help("Projects (⇧⌘P)")
                Button { state.focusMode.toggle(); if state.focusMode, state.chat == nil { state.chat = ChatSession(document: document) } } label: {
                    Label("Focus", systemImage: state.focusMode ? "rectangle.3.group" : "rectangle.split.2x1")
                }
                .help(state.focusMode ? "Back to the full editor (⌥⌘F)" : "Focus: just the player and the chat (⌥⌘F)")
                Button { exportVideo() } label: { Label("Export", systemImage: "square.and.arrow.up") }.help("Export the movie (⌘E)").disabled(noClips || state.isExporting)
            }
        }
        .environmentObject(state)
        .environment(\.reveal, state.reveal)
        .environmentObject(player)
        .focusedSceneObject(document)
        .background(KeyMonitor { e in EditorActions(document: document, state: state, player: player).handle(e) })
        .onAppear {
            UIRegistry.shared.playheads[document.id] = { [weak player] in player?.currentTime }
            UIRegistry.shared.playing[document.id] = { [weak player] in player?.isRunning ?? false }
            AgentFollow.shared.register(document.id) { [weak document, weak state, weak player] t in
                guard let document, let state, let player else { return false }
                return FollowUI.apply(t, document: document, state: state, player: player)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .onAppear { document.fileURL = fileURL; DocumentRegistry.shared.register(document); player.bind(to: document); if state.chat == nil { state.chat = ChatSession(document: document) }
            FontLibrary.shared.ensureFonts(for: document.project)   // a Google font this Mac lacks downloads now; the picture redraws when it lands
            document.noteLibraryUse()   // the Assets library's "Used in" is right from the moment a project opens
            // Debug affordances (used by automated checks): EDITMAX_INSPECTOR_TAB=chat|agents|history opens that tab;
            // EDITMAX_CHAT_AUTOSEND="..." sends a first chat message on launch.
            if let t = ProcessInfo.processInfo.environment["EDITMAX_INSPECTOR_TAB"], let tab = EditorState.InspectorTab.allCases.first(where: { $0.rawValue.lowercased() == t.lowercased() }) {
                state.inspectorTab = tab
            }
            if let t = ProcessInfo.processInfo.environment["EDITMAX_CHAT_AUTOSEND"], !t.isEmpty, state.chat?.items.isEmpty == true {
                state.inspectorTab = .chat; state.chat?.input = t; state.chat?.send()
            }
        }
        .onChange(of: fileURL) { old, new in
            document.fileURL = new
            // Renamed or moved: "Used in" names the project under its new file.
            if let old, old.standardizedFileURL != new?.standardizedFileURL { AssetLibrary.shared.forgetProject(AssetLibrary.projectID(for: old)) }
            document.noteLibraryUse()
        }
        .onDisappear { DocumentRegistry.shared.unregister(document); AgentFollow.shared.unregister(document.id); player.pause() }
        .background(WindowFocusObserver { DocumentRegistry.shared.activate(document) })
        .modifier(EditingSheets(document: document))   // relink on open, consolidate (RelinkSheet.swift)
        .onReceive(NotificationCenter.default.publisher(for: .editmaxCompare)) { _ in
            if DocumentRegistry.shared.active?.id == document.id, document.project.hasColorGrade { player.cycleCompare() }
        }
        .onChange(of: document.project.hasColorGrade) { _, graded in if !graded, player.compareMode != .off { player.compareMode = .off } }
        .onReceive(NotificationCenter.default.publisher(for: .editmaxFocusMode)) { _ in
            if DocumentRegistry.shared.active?.id == document.id { state.focusMode.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editmaxFullScreenPreview)) { _ in
            if DocumentRegistry.shared.active?.id == document.id { toggleFullScreen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editmaxExport)) { _ in
            guard DocumentRegistry.shared.activeID == document.id, !state.isExporting else { return }
            exportVideo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editmaxExportChapters)) { _ in
            guard DocumentRegistry.shared.activeID == document.id else { return }
            DeliveryActions(document: document, state: state).exportChapters()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editmaxBatchExport)) { _ in
            guard DocumentRegistry.shared.activeID == document.id, !state.isExporting else { return }
            DeliveryActions(document: document, state: state).batchExport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editmaxExportTimeline)) { _ in
            guard DocumentRegistry.shared.activeID == document.id, !state.isExporting else { return }
            DeliveryActions(document: document, state: state).exportTimeline()
        }
        .overlay(alignment: .top) {
            if let s = state.exportStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(s).font(.caption.monospacedDigit()).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .liquidGlass()
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
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
            MixerSplit(document: document, player: player) { TimelineView(document: document, player: player) }.frame(minHeight: 200, idealHeight: 280)
        }
    }

    /// Focus: only the player and the chat, for directing the agent while watching the picture (⌥⌘F or the preview button).
    private var focusChat: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Chat").font(.system(size: 13, weight: .semibold))
                    Text(document.displayName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { state.focusMode = false } label: { Label("Back to editor", systemImage: "rectangle.3.group") }
                    .controlSize(.small).focusable(false).pointer().uiFrame("focus.exit").uiTap("focus.exit") { state.focusMode = false }.help("Back to the full editor (⌥⌘F)")
            }
            .frame(height: 44)
            .padding(.horizontal, 14)
            .background(Color.primary.opacity(0.03))
            Divider()
            if let chat = state.chat { ChatView(chat: chat) } else { Spacer() }
        }
    }

    /// The picture with its overlays (empty state, version banner, scopes / full screen / focus buttons), scopes and build errors.
    private var previewArea: some View {
        VStack(spacing: 0) {
            PreviewView(controller: player, canFullScreen: !noClips)
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
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .liquidGlass(tint: .orange.opacity(0.75))
                        .padding(10)
                        .uiFrame("preview.versionBanner")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // The floating control layer over the picture: one glass group, icon-only, tinted when active.
                    GlassGroup(spacing: 6) {
                        HStack(spacing: 6) {
                            overlayButton("waveform.path.ecg", active: player.scopesEnabled,
                                          help: player.scopesEnabled ? "Hide the scopes" : "Show the scopes (waveform and histogram)") { player.scopesEnabled.toggle() }
                                .uiFrame("preview.scopes")
                            overlayButton(player.compareMode == .off ? "rectangle.lefthalf.inset.filled" : player.compareMode == .split ? "rectangle.split.2x1.fill" : "rectangle.fill",
                                          active: player.compareMode != .off,
                                          help: !document.project.hasColorGrade ? "Before / after compares the color grade; no clip is graded yet" : player.compareMode == .off ? "Before / after the color grade: split the picture at a divider you can drag, then the whole picture before, then off" : "Next before / after mode") { player.cycleCompare() }
                                .disabled(!document.project.hasColorGrade)
                                .uiFrame("preview.compare").uiTap("preview.compare") { if document.project.hasColorGrade { player.cycleCompare() } }
                            overlayButton("arrow.up.left.and.arrow.down.right", active: false,
                                          help: noClips ? "Add a clip to the timeline to view it full screen" : "Show the preview full screen (⇧⌘F, or double-click the preview; Esc leaves)") { toggleFullScreen() }
                                .disabled(noClips)
                                .uiFrame("preview.fullscreen").uiTap("preview.fullscreen") { toggleFullScreen() }
                            overlayButton(state.focusMode ? "rectangle.3.group" : "rectangle.split.2x1", active: state.focusMode,
                                          help: state.focusMode ? "Back to the full editor (⌥⌘F)" : "Focus: just the player and the chat (⌥⌘F)") {
                                state.focusMode.toggle(); if state.focusMode, state.chat == nil { state.chat = ChatSession(document: document) }
                            }
                            .uiFrame("preview.focus").uiTap("preview.focus") { state.focusMode.toggle() }
                        }
                    }
                    .padding(10)
                }
            .overlay { if player.compareMode != .off { CompareOverlay(player: player, aspect: Double(document.project.settings.width) / Double(max(1, document.project.settings.height))) } }
            .overlay { SourceViewerHost(document: document) }   // last, so the source viewer covers the program's overlays (SourceViewer.swift)
            if player.scopesEnabled { ScopesView(data: player.scopes) }
            if let e = player.buildError { Text(e).font(.caption).foregroundStyle(.red).padding(4) }
        }
    }

    /// One floating glass button over the picture. `.pointer()` sits inside `.disabled` at the call site.
    private func overlayButton(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 26)
                .foregroundStyle(active ? Color.white : .primary)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain).focusable(false)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous), tint: active ? Color.glassSelection : nil, interactive: true)
        .help(help)
        .pointer()
    }

    /// No clips on any track: nothing to show full screen, so every entry point (button, menu, double-click) stays off.
    private var noClips: Bool { document.project.allClips.isEmpty }

    /// Opens the full-screen preview only when there is something to show; closing it always works.
    private func toggleFullScreen() {
        guard FullScreenPreview.shared.isShowing || !noClips else { return }
        FullScreenPreview.shared.toggle(player, keys: EditorActions(document: document, state: state, player: player).handle)
    }

    private func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = document.displayName + ".mp4"
        let format = ExportFormatBox()
        // The name field and the file type follow the format: ProRes is a QuickTime .mov, the rest MP4.
        format.onChange = { preset in
            panel.allowedContentTypes = [preset.isProRes ? .quickTimeMovie : .mpeg4Movie]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = (name.isEmpty ? document.displayName : name) + "." + preset.fileExtension
        }
        panel.accessoryView = PanelAccessory.popUp(label: "Format:", items: ExportFormatBox.items, selected: format.preset) { format.preset = $0 }
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

/// View menu items. Full Screen Preview does nothing while the project has no clips: the receiver in EditorRootView
/// (`toggleFullScreen`) guards it, the same way the preview button does. The item itself stays enabled because the
/// focused document is not reliably visible to the menu (it goes nil whenever the editor window is not key).
struct ViewCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button("Home") { HomeWindow.shared.show() }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("Full Screen Preview") { NotificationCenter.default.post(name: .editmaxFullScreenPreview, object: nil) }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Focus on Player and Chat") { NotificationCenter.default.post(name: .editmaxFocusMode, object: nil) }.keyboardShortcut("f", modifiers: [.command, .option])
            Button("Before / After") { NotificationCenter.default.post(name: .editmaxCompare, object: nil) }.keyboardShortcut("b", modifiers: [.command, .option])
        }
    }
}

/// EditMax ▸ Check for Updates…, under About.
struct UpdateCommands: Commands {
    @ObservedObject private var updates = AppUpdater.shared
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheck)
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

/// The format choice in the export save panel. `onChange` lets the panel follow it (file type, name extension).
/// The export format chosen in the Save panel (`PanelAccessory`); the panel's name field follows it.
final class ExportFormatBox {
    var preset: ExportService.Preset = .high { didSet { onChange?(preset) } }
    var onChange: ((ExportService.Preset) -> Void)?

    static let items: [PanelAccessory.Item<ExportService.Preset>?] = [
        .init(title: "H.264, 8-bit (plays everywhere)", value: .high),
        .init(title: "HEVC 10-bit, Main 10 (for grading)", value: .hevc10),
        nil,
        .init(title: "ProRes 422 HQ (edit and grade in Resolve, Final Cut)", value: .prores422hq),
        .init(title: "ProRes 422 (smaller)", value: .prores422),
        .init(title: "ProRes 4444 (highest quality)", value: .prores4444),
    ]
}
