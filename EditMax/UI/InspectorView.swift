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
            .pickerStyle(.segmented).padding(8).pointer()
            Divider()
            if state.inspectorTab == .chat, let chat = state.chat {
                ChatView(chat: chat)
            } else if state.inspectorTab == .inspector {
                inspector
            } else {
                ScrollView {
                    switch state.inspectorTab {
                    case .agents: agents.padding(12)
                    case .history: history.padding(12)
                    default: EmptyView()
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
            ForEach(Array(document.project.history.reversed().enumerated()), id: \.element.id) { i, h in
                HStack(spacing: 8) {
                    Image(systemName: h.origin == .agent ? "sparkles" : h.origin == .user ? "person" : "gear").foregroundStyle(h.origin == .agent ? .purple : .secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h.label).font(.caption).lineLimit(1)
                        Text(i == 0 ? "Latest · \(h.createdAt.formatted(date: .omitted, time: .shortened))" : h.createdAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Restore") { try? document.restore(snapshotID: h.id, origin: .user) }.font(.caption).controlSize(.small).pointer().help("Go back to the state before this edit")
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(i == 0 ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            }
            if document.project.history.isEmpty { Text("No edits yet.").font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

struct ClipInspector: View {
    @ObservedObject var document: EditMaxDocument
    @EnvironmentObject var state: EditorState
    @EnvironmentObject var player: PlayerController
    @ObservedObject private var thumbnails = ThumbnailStore.shared
    let clip: Clip
    let track: Track
    @State private var nameDraft = ""
    @State private var transitionNote: String?

    var body: some View {
        let x = ToolExecutor(document: document, origin: .user, coalesce: true)   // slider drags make one undo step
        let asset = document.project.asset(clip.assetID)
        Form {
            Section {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(track.kind == .audio ? Color.green.opacity(0.25) : Color.black.opacity(0.35))
                        if let frame = thumbnails.strips[clip.assetID]?.frames.first { Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                        else { Image(systemName: track.kind == .video ? "film" : "waveform").foregroundStyle(.secondary) }
                    }
                    .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: $nameDraft).textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                            .onSubmit { commitName(x) }
                        Text(asset?.name ?? "missing file").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
                HStack(spacing: 8) {
                    Button("Split at playhead", systemImage: "scissors") { try? x.splitClip(clip.id.uuidString, at: player.currentTime) }
                        .disabled(player.currentTime <= clip.start + 0.01 || player.currentTime >= clip.end - 0.01).pointer()
                    Button("Delete", systemImage: "trash", role: .destructive) { state.selectedClipIDs = []; try? x.removeClips([clip.id.uuidString]) }.pointer()
                    Spacer()
                }
                .controlSize(.small)
            }
            Section("Timing") {
                LabeledContent("Track", value: track.name)
                LabeledContent("Start", value: Timecode.string(clip.start))
                LabeledContent("End", value: Timecode.string(clip.end))
                LabeledContent("Duration", value: Timecode.string(clip.duration))
                LabeledContent("Source in", value: Timecode.string(clip.sourceIn))
            }
            Section("Speed") {
                slider("Speed", value: clip.speed, range: 0.25...4, format: String(format: "%.2f×", clip.speed), reset: 1) { try? x.setClipProperties(clip.id.uuidString, speed: $0) }
            }
            if track.kind == .video {
                Section {
                    let tf = clip.transform
                    slider("Scale", value: tf.scale, range: 0.1...4, format: "\(Int(tf.scale * 100))%", reset: 1) { try? x.setClipTransform(clip.id.uuidString, scale: $0, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Position X", value: tf.x, range: -1...1, format: "\(Int(tf.x * 100))%", reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: $0, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Position Y", value: tf.y, range: -1...1, format: "\(Int(tf.y * 100))%", reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: $0, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Rotation", value: tf.rotation, range: -180...180, format: "\(Int(tf.rotation))°", reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: $0, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Crop left", value: tf.cropLeft, range: 0...0.9, format: "\(Int(tf.cropLeft * 100))%", reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: $0, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Crop right", value: tf.cropRight, range: 0...0.9, format: "\(Int(tf.cropRight * 100))%", reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: $0, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Crop top", value: tf.cropTop, range: 0...0.9, format: "\(Int(tf.cropTop * 100))%", reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: $0, cropBottom: nil, reset: false) }
                    slider("Crop bottom", value: tf.cropBottom, range: 0...0.9, format: "\(Int(tf.cropBottom * 100))%", reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: $0, reset: false) }
                    slider("Opacity", value: clip.opacity, range: 0...1, format: "\(Int(clip.opacity * 100))%", reset: 1) { try? x.setClipProperties(clip.id.uuidString, opacity: $0) }
                } header: {
                    HStack { Text("Transform"); Spacer(); if !clip.transform.isIdentity { Button("Reset") { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: true) }.controlSize(.mini).pointer() } }
                }
                Section {
                    let c = clip.color
                    slider("Exposure", value: c.exposure, range: -2...2, format: String(format: "%+.1f", c.exposure), reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: $0, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false) }
                    slider("Contrast", value: c.contrast, range: 0.5...2, format: "\(Int(c.contrast * 100))%", reset: 1) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: $0, saturation: nil, temperature: nil, tint: nil, reset: false) }
                    slider("Saturation", value: c.saturation, range: 0...2, format: "\(Int(c.saturation * 100))%", reset: 1) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: $0, temperature: nil, tint: nil, reset: false) }
                    slider("Temperature", value: c.temperature, range: -100...100, format: "\(Int(c.temperature))", reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: $0, tint: nil, reset: false) }
                    slider("Tint", value: c.tint, range: -100...100, format: "\(Int(c.tint))", reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: $0, reset: false) }
                } header: {
                    HStack { Text("Color"); Spacer(); if !clip.color.isIdentity { Button("Reset") { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: true) }.controlSize(.mini).pointer() } }
                }
            }
            Section("Audio") {
                slider("Volume", value: clip.volume, range: 0...2, format: "\(Int(clip.volume * 100))%", reset: 1) { try? x.setClipProperties(clip.id.uuidString, volume: $0) }
                slider("Fade in", value: clip.fadeIn, range: 0...min(5, clip.duration), format: String(format: "%.1f s", clip.fadeIn), reset: 0) { try? x.setClipFades(clip.id.uuidString, fadeIn: $0, fadeOut: nil) }
                slider("Fade out", value: clip.fadeOut, range: 0...min(5, clip.duration), format: String(format: "%.1f s", clip.fadeOut), reset: 0) { try? x.setClipFades(clip.id.uuidString, fadeIn: nil, fadeOut: $0) }
                if track.kind == .video { Text("Fades take the picture to black and the sound to silence.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Transition in") {
                Picker("Kind", selection: Binding(get: { clip.transitionIn?.kind.rawValue ?? "none" }, set: { v in _ = try? ToolExecutor(document: document, origin: .user).setTransition(clip.id.uuidString, kind: v, duration: nil); transitionNote = nil })) {
                    Text("None").tag("none")
                    ForEach(Transition.Kind.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.pointer()
                if let tr = clip.transitionIn {
                    slider("Duration", value: tr.duration, range: 0.1...min(3, clip.duration), format: String(format: "%.2f s", tr.duration), reset: 0.5) { d in
                        transitionNote = (try? x.setTransition(clip.id.uuidString, kind: nil, duration: d))?.note
                    }
                }
                Text(transitionNote ?? (document.project.clipBefore(clip, on: track) == nil ? "No clip ends where this one starts, so a transition would come from black." : "Plays over the end of \(document.project.clipBefore(clip, on: track)!.name), which needs that much media past its out point."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Clip id", value: clip.id.short).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { nameDraft = clip.name }
        .onChange(of: clip.id) { _, _ in nameDraft = clip.name }
    }

    private func commitName(_ x: ToolExecutor) {
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, n != clip.name { try? x.setClipProperties(clip.id.uuidString, name: n) }
    }

    /// A labeled slider with its value on the right; double-click the value to reset.
    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, format: String, reset: Double, set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: .init(get: { value }, set: set), in: range).controlSize(.small)
                Text(format).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    .onTapGesture(count: 2) { set(reset) }.help("Double-click to reset")
            }
        }
    }
}

struct TextInspector: View {
    @ObservedObject var document: EditMaxDocument
    @EnvironmentObject var state: EditorState
    @EnvironmentObject var player: PlayerController
    let text: TextOverlay
    @State private var draft = ""

    var body: some View {
        Form {
            Section(text.isCaption ? "Caption" : "Title") {
                TextField("Text", text: $draft, axis: .vertical).lineLimit(1...4)
                    .onSubmit { commitText() }
                HStack(spacing: 8) {
                    Button("Apply text") { commitText() }.disabled(draft == text.text).pointer()
                    Button("Show", systemImage: "eye") { player.pause(); player.seek(to: text.start + 0.05) }.help("Move the playhead to this text").pointer()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        state.selectedTextID = nil
                        document.apply("Delete text", origin: .user) { p in p.texts.removeAll { $0.id == text.id } }
                    }.pointer()
                    Spacer()
                }
                .controlSize(.small)
                if text.isCaption { Text("Part of caption group \(text.group!.short). Style changes apply to this line only.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Look") {
                Picker("Style", selection: Binding(get: { text.preset ?? "title" }, set: { v in
                    document.apply("Text style", origin: .user) { p in if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i].preset = v } }
                })) { ForEach(CaptionPresets.all, id: \.name) { Text($0.title).tag($0.name) } }.pointer()
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Slider(value: binding(\.fontSize), in: 12...300).controlSize(.small)
                        Text("\(Int(text.fontSize)) pt").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
                ColorPicker("Color", selection: Binding(get: { Color(hex: text.colorHex) }, set: { c in
                    let hex = c.hexString
                    guard hex != text.colorHex else { return }
                    document.apply("Text color", origin: .user) { p in if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i].colorHex = hex } }
                }), supportsOpacity: false).pointer()
            }
            Section("Position") {
                LabeledContent("Horizontal") {
                    HStack(spacing: 8) {
                        Slider(value: binding(\.x), in: 0...1).controlSize(.small)
                        Text("\(Int(text.x * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Vertical") {
                    HStack(spacing: 8) {
                        Slider(value: binding(\.y), in: 0...1).controlSize(.small)
                        Text("\(Int(text.y * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
                Text("0% is the top-left of the frame, 100% the bottom-right. Drag the bar on the timeline to move it in time, its edges to change the length.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Timing") {
                LabeledContent("Start", value: Timecode.string(text.start))
                LabeledContent("End", value: Timecode.string(text.end))
                LabeledContent("Duration", value: Timecode.string(text.duration))
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = text.text }
        .onChange(of: text.id) { _, _ in draft = text.text }
    }

    private func commitText() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != text.text else { return }
        document.apply("Edit text", origin: .user) { p in if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i].text = t } }
    }

    private func binding<T: Equatable>(_ kp: WritableKeyPath<TextOverlay, T>) -> Binding<T> {
        .init(get: { text[keyPath: kp] }, set: { v in
            guard v != text[keyPath: kp] else { return }
            document.apply("Edit text", origin: .user) { p in if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i][keyPath: kp] = v } }
        })
    }
}

extension ProjectInspector {
    private enum CleanupKind { case silence, fillers }
    private var cleanupHint: String {
        let ignored = document.project.tracks.filter { ($0.isHidden || $0.isMuted) && !$0.clips.isEmpty }.map(\.name)
        let base = "Cuts moments where nothing is audible (over 0.6 s) or spoken fillers (um, uh, hmm…) from every track and closes the gaps. Do this before captions."
        return ignored.isEmpty ? base : base + " Muted or hidden now, so not listened to, but cut along: \(ignored.joined(separator: ", "))."
    }
    private func cleanup(_ kind: CleanupKind) {
        cleanupBusy = true; cleanupStatus = kind == .silence ? "Listening for silence…" : "Transcribing…"
        Task { @MainActor in
            defer { cleanupBusy = false }
            do {
                let x = ToolExecutor(document: document, origin: .user)
                let r = kind == .silence ? try await x.removeSilence(clip: nil, thresholdDb: -38, minDuration: 0.6, padding: 0.15) : try await x.removeWords(clip: nil, words: nil, language: nil)
                let what = kind == .silence ? "\(r.ranges.count) silence\(r.ranges.count == 1 ? "" : "s")" : "\(r.words?.count ?? 0) filler word\((r.words?.count ?? 0) == 1 ? "" : "s")"
                var status = r.ranges.isEmpty ? "Nothing to remove." : "Removed \(what), \(String(format: "%.1f", r.removedSeconds)) s. Timeline is now \(Timecode.string(r.duration))."
                if !r.ignoredTracks.isEmpty { status += " Not listened to (muted or hidden), but cut along: \(r.ignoredTracks.joined(separator: ", "))." }
                cleanupStatus = status
            } catch { cleanupStatus = error.localizedDescription }
        }
    }

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
    @EnvironmentObject var player: PlayerController
    @State private var newText = ""
    @State private var captionPreset = "subtitle"
    @State private var captionBusy = false
    @State private var captionStatus: String?
    @State private var cleanupBusy = false
    @State private var cleanupStatus: String?
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
            Section("Add text") {
                TextField("Title text", text: $newText, prompt: Text("Type a title and press Return")).onSubmit { addTitle() }
                HStack {
                    Button("Add at playhead", systemImage: "plus") { addTitle() }.disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty).pointer()
                    Spacer()
                    Text("Starts at \(Timecode.string(player.currentTime)), 3 s long. Drag the bar to adjust.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !p.markers.isEmpty || state.inPoint != nil || state.outPoint != nil {
                Section("Markers") {
                    if let i = state.inPoint, let o = state.outPoint {
                        HStack {
                            Text("In \(Timecode.string(i)) → Out \(Timecode.string(o))").font(.caption)
                            Spacer()
                            Button("Delete range") { EditorActions(document: document, state: state, player: player).deleteRange() }.controlSize(.small).pointer()
                            Button("Clear") { state.inPoint = nil; state.outPoint = nil }.controlSize(.small).pointer()
                        }
                    }
                    ForEach(p.markers) { m in
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: m.colorHex)).frame(width: 8, height: 8)
                            TextField("Name", text: Binding(get: { m.name }, set: { v in document.apply("Rename marker", origin: .user, coalesce: true) { p in if let i = p.markers.firstIndex(where: { $0.id == m.id }) { p.markers[i].name = v } } })).textFieldStyle(.plain).font(.caption)
                            Text(Timecode.string(m.time)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Button { player.pause(); player.seek(to: m.time) } label: { Image(systemName: "arrow.right.to.line") }.buttonStyle(.borderless).help("Go to marker").pointer()
                            Button { document.apply("Remove marker", origin: .user) { p in p.markers.removeAll { $0.id == m.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove marker").pointer()
                        }
                    }
                }
            }
            Section("Cleanup") {
                HStack {
                    Button(cleanupBusy ? "Working…" : "Remove silence") { cleanup(.silence) }.disabled(cleanupBusy || p.allClips.isEmpty).pointer().uiFrame("inspector.removeSilence")
                    Button("Remove filler words") { cleanup(.fillers) }.disabled(cleanupBusy || p.allClips.isEmpty).pointer().uiFrame("inspector.removeFillers")
                }
                Text(cleanupStatus ?? cleanupHint)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Captions") {
                Picker("Style", selection: $captionPreset) { ForEach(CaptionPresets.all, id: \.name) { Text($0.title).tag($0.name) } }.pointer()
                HStack {
                    Button(captionBusy ? "Transcribing…" : "Add captions") { addCaptions() }.disabled(captionBusy || p.allClips.isEmpty).pointer()
                    if captionCount > 0 {
                        Button("Remove \(captionCount)") { captionStatus = nil; _ = try? ToolExecutor(document: document, origin: .user).removeCaptions(group: nil) }.pointer()
                    }
                }
                Text(captionStatus ?? Transcriber.privacyNote)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Click a clip or a text bar on the timeline to edit it. The Agents tab connects Claude Code, Codex or Cursor; the Chat tab talks to them here.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addTitle() {
        let t = newText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if let added = try? ToolExecutor(document: document, origin: .user).addText(t, start: player.currentTime, duration: 3, fontSize: nil, colorHex: nil, x: nil, y: nil) {
            state.selectedTextID = added.id; state.selectedClipIDs = []
        }
        newText = ""
    }
}
