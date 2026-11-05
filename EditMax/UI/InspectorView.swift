import SwiftUI
import AppKit

struct InspectorView: View {
    @ObservedObject var document: EditMaxDocument
    @EnvironmentObject var state: EditorState
    @ObservedObject var mcp = MCPService.shared
    @ObservedObject var installer = CodemaxInstaller.shared
    @ObservedObject private var updater = CodemaxUpdater.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.inspectorTab) {
                ForEach(EditorState.InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(8)
            Divider()
            if state.inspectorTab == .chat, let chat = state.chat {
                ChatView(chat: chat)
            } else {
                ScrollView {
                    switch state.inspectorTab {
                    case .inspector: inspector.padding(12)
                    case .agents: agents.padding(12)
                    case .history: history.padding(12)
                    case .chat: EmptyView()
                    }
                }
            }
        }
    }

    // MARK: Inspector
    @ViewBuilder private var inspector: some View {
        if let id = state.selectedClipIDs.first, let found = document.project.clip(id) {
            ClipInspector(document: document, clip: found.clip, track: found.track)
        } else if let tid = state.selectedTextID, let t = document.project.texts.first(where: { $0.id == tid }) {
            TextInspector(document: document, text: t)
        } else {
            ProjectInspector(document: document)
        }
    }

    // MARK: Agents
    private var agents: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusText).font(.headline)
            }
            Text("Any MCP client can edit this project. The server listens on localhost only and requires the bearer token below. \(mcp.requestCount) requests served.").font(.caption).foregroundStyle(.secondary)
            agentRuntime
            Group {
                snippet("Claude Code", mcp.claudeCodeCommand)
                snippet("Codex CLI", mcp.codexCommand)
                snippet("Cursor / Claude Desktop / any JSON config", mcp.genericJSON)
            }
            if let c = mcp.lastClient { Text("Last connected client: \(c)").font(.caption) }
            Text("Config file: \(MCPService.configDirectory.appendingPathComponent("mcp.json").path)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            logs
        }
    }
    /// Where to look when something goes wrong, and one button that packs it all for a bug report.
    @State private var exportNote: String?
    private var logs: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Logs").font(.caption.bold())
            Text("EditMax writes what it did with codemax, the updater and the MCP server to editmax.log; every line exchanged with codemax (the chat included) goes to codemax-protocol.log, secrets removed. Export packs both with codemax's own debug log and the versions involved.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Export diagnostics…") {
                    do {
                        let zip = try DebugLog.exportDiagnostics(versions: ["editmax": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "", "codemax-bundled": installer.status.bundledVersion ?? "", "codemax-installed": installer.status.installedPath ?? "", "editmax-agent": CodemaxRunner.bundledBinary(.agent)?.path ?? "missing"])
                        exportNote = "Saved to \(zip.lastPathComponent) on the Desktop."
                        NSWorkspace.shared.activateFileViewerSelecting([zip])
                    } catch { exportNote = "Export failed: \(error.localizedDescription)" }
                }.controlSize(.small).pointer()
                Button("Reveal logs") { DebugLog.reveal() }.controlSize(.small).pointer()
            }
            if let n = exportNote { Text(n).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(8).background(Color(nsColor: .textBackgroundColor)).cornerRadius(6)
    }
    /// The bundled codemax: install state and which agents it found.
    private var agentRuntime: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Built-in agent runtime (codemax)").font(.caption.bold())
            Text(installer.status.message).font(.caption).foregroundStyle(.secondary)
            if let p = installer.status.installedPath { Text(p).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled) }
            HStack(spacing: 6) {
                Text("Updates: running \(updater.status.activeVersion ?? "?") (\(updater.status.activeSource))" + (updater.status.latest.map { " · latest release \($0)" } ?? "")).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if updater.status.busy { ProgressView().controlSize(.mini) }
                Button("Check now") { updater.check(reason: "button") }.controlSize(.mini).disabled(updater.status.busy).pointer()
            }
            Text(updater.status.message).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            Text("New codemax releases install on their own (checked every 12 h) after passing a health check; one that crashes twice is rolled back.").font(.caption2).foregroundStyle(.tertiary)
            if let chat = state.chat {
                ForEach(chat.agents) { a in
                    HStack(spacing: 6) {
                        Circle().fill(a.installed ? Color.green : Color.gray).frame(width: 7, height: 7)
                        Text(a.name).font(.caption)
                        if let v = a.version { Text(v).font(.caption2).foregroundStyle(.tertiary) }
                        if !a.installed, let p = a.problem { Text(p).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                        Spacer()
                    }
                }
                if chat.agents.isEmpty { Text("Looking for agents…").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .padding(8).background(Color(nsColor: .textBackgroundColor)).cornerRadius(6)
    }
    private var statusColor: Color { if case .running = mcp.status { return .green }; if case .failed = mcp.status { return .red }; return .gray }
    private var statusText: String {
        switch mcp.status {
        case .running(let p): return "MCP server running on port \(p)"
        case .failed(let e): return "MCP server failed: \(e)"
        case .stopped: return "MCP server stopped"
        }
    }
    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.caption.bold()); Spacer(); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }.pointer().font(.caption) }
            Text(text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(6)
                .frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .textBackgroundColor)).cornerRadius(4)
        }
    }

    // MARK: History
    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Every edit records the state before it. Restore any point; restoring is itself an edit, so nothing is lost.").font(.caption).foregroundStyle(.secondary)
            ForEach(document.project.history.reversed()) { h in
                HStack {
                    Image(systemName: h.origin == .agent ? "sparkles" : h.origin == .user ? "person" : "gear").foregroundStyle(h.origin == .agent ? .purple : .secondary).frame(width: 16)
                    VStack(alignment: .leading) {
                        Text(h.label).font(.caption)
                        Text(h.createdAt.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Restore") { try? document.restore(snapshotID: h.id, origin: .user) }.font(.caption).pointer()
                }
                .padding(.vertical, 2)
            }
            if document.project.history.isEmpty { Text("No edits yet.").font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

struct ClipInspector: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    let track: Track
    var body: some View {
        let x = ToolExecutor(document: document, origin: .user)
        Form {
            TextField("Name", text: .init(get: { clip.name }, set: { try? x.setClipProperties(clip.id.uuidString, name: $0) }))
            LabeledContent("Track", value: track.name)
            LabeledContent("Start", value: Timecode.string(clip.start))
            LabeledContent("End", value: Timecode.string(clip.end))
            LabeledContent("Duration", value: Timecode.string(clip.duration))
            LabeledContent("Source in", value: Timecode.string(clip.sourceIn))
            LabeledContent("ID", value: clip.id.short)
            Slider(value: .init(get: { clip.speed }, set: { try? x.setClipProperties(clip.id.uuidString, speed: $0) }), in: 0.25...4) { Text("Speed \(clip.speed, specifier: "%.2f")×") }
            Slider(value: .init(get: { clip.volume }, set: { try? x.setClipProperties(clip.id.uuidString, volume: $0) }), in: 0...2) { Text("Volume \(Int(clip.volume * 100))%") }
            if track.kind == .video {
                Slider(value: .init(get: { clip.opacity }, set: { try? x.setClipProperties(clip.id.uuidString, opacity: $0) }), in: 0...1) { Text("Opacity \(Int(clip.opacity * 100))%") }
            }
        }
    }
}

struct TextInspector: View {
    @ObservedObject var document: EditMaxDocument
    let text: TextOverlay
    var body: some View {
        Form {
            TextField("Text", text: binding(\.text), axis: .vertical)
            Picker("Style", selection: Binding(get: { text.preset ?? "title" }, set: { v in
                document.apply("Text style", origin: .user) { p in if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i].preset = v } }
            })) { ForEach(CaptionPresets.all, id: \.name) { Text($0.title).tag($0.name) } }.pointer()
            if text.isCaption { Text("Caption (group \(text.group!.short))").font(.caption).foregroundStyle(.secondary) }
            Slider(value: binding(\.fontSize), in: 12...300) { Text("Size \(Int(text.fontSize))") }
            TextField("Color (hex)", text: binding(\.colorHex))
            Slider(value: binding(\.x), in: 0...1) { Text("X") }
            Slider(value: binding(\.y), in: 0...1) { Text("Y") }
            Slider(value: binding(\.start), in: 0...max(1, document.project.duration + 10)) { Text("Start \(Timecode.string(text.start))") }
            Slider(value: binding(\.duration), in: 0.1...60) { Text("Duration \(Timecode.string(text.duration))") }
        }
    }
    private func binding<T>(_ kp: WritableKeyPath<TextOverlay, T>) -> Binding<T> {
        .init(get: { text[keyPath: kp] }, set: { v in
            document.apply("Edit text", origin: .user) { p in if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i][keyPath: kp] = v } }
        })
    }
}

extension ProjectInspector {
    private func addCaptions() {
        captionBusy = true; captionStatus = "Transcribing…"
        Task { @MainActor in
            defer { captionBusy = false }
            do {
                let r = try await ToolExecutor(document: document, origin: .user).addCaptions(clip: nil, preset: captionPreset, maxWords: nil, language: nil)
                captionStatus = "Added \(r.count) captions to \(r.clips) clip\(r.clips == 1 ? "" : "s")."
            } catch { captionStatus = error.localizedDescription }
        }
    }
}

struct ProjectInspector: View {
    @ObservedObject var document: EditMaxDocument
    @EnvironmentObject var state: EditorState
    @State private var newText = ""
    @State private var captionPreset = "subtitle"
    @State private var captionBusy = false
    @State private var captionStatus: String?
    var body: some View {
        let p = document.project
        let captionCount = p.texts.filter(\.isCaption).count
        Form {
            Section("Project") {
                LabeledContent("Resolution", value: "\(p.settings.width)×\(p.settings.height)")
                LabeledContent("Frame rate", value: "\(Int(p.settings.fps)) fps")
                LabeledContent("Duration", value: Timecode.string(p.duration))
                LabeledContent("Clips", value: "\(p.allClips.count)")
                LabeledContent("Project ID", value: document.id.short)
            }
            Section("Add text at playhead") {
                TextField("Title text", text: $newText)
                Button("Add text") {
                    guard !newText.isEmpty else { return }
                    _ = try? ToolExecutor(document: document, origin: .user).addText(newText, start: 0, duration: 3, fontSize: nil, colorHex: nil, x: nil, y: nil)
                    newText = ""
                }.pointer()
            }
            Section("Captions") {
                Picker("Style", selection: $captionPreset) { ForEach(CaptionPresets.all, id: \.name) { Text($0.title).tag($0.name) } }.pointer()
                HStack {
                    Button(captionBusy ? "Transcribing…" : "Add captions") { addCaptions() }.disabled(captionBusy || p.allClips.isEmpty).pointer()
                    if captionCount > 0 {
                        Button("Remove \(captionCount)") { captionStatus = nil; _ = try? ToolExecutor(document: document, origin: .user).removeCaptions(group: nil) }.pointer()
                    }
                }
                Text(captionStatus ?? (Transcriber.isAvailable ? "Speech is recognized on this Mac; nothing is uploaded." : "Captions need macOS 26 or newer."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Select a clip or text block to edit it. Use the Agents tab to connect Claude Code, Codex or Cursor.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
