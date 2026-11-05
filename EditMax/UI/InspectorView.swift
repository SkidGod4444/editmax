import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct InspectorView: View {
    @ObservedObject var document: EditMaxDocument
    @EnvironmentObject var state: EditorState
    @EnvironmentObject var player: PlayerController
    @ObservedObject var mcp = MCPService.shared
    @ObservedObject var installer = CodemaxInstaller.shared
    @ObservedObject private var updater = CodemaxUpdater.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.inspectorTab) {
                ForEach(EditorState.InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(8).pointer().uiFrame("inspector.tabs")
            // The driver switches tabs through these (ids tab.inspector, tab.chat, tab.agents, tab.history), never by posting a click on the control.
            .uiTap("tab.inspector") { state.inspectorTab = .inspector }.uiTap("tab.chat") { state.inspectorTab = .chat }
            .uiTap("tab.agents") { state.inspectorTab = .agents }.uiTap("tab.history") { state.inspectorTab = .history }
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

    // MARK: History (versions)
    /// One row per edit, newest first, each showing the project *as it was after that edit*. Click a row to see that version in
    /// the preview; Restore makes it current again (itself an edit, so nothing is lost). The bottom row is the original.
    private var history: some View {
        let h = document.project.history
        let viewing = state.viewingVersion
        return VStack(alignment: .leading, spacing: 6) {
            Text("Every edit is a version. Click one to see it in the preview, Restore to go back to it. Restoring is itself an edit, so nothing is lost.").font(.caption).foregroundStyle(.secondary)
            if let v = viewing, !v.isCurrent {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                    Text("Viewing: \(v.label) · \(v.date.formatted(date: .omitted, time: .shortened))").font(.caption).lineLimit(1)
                    Spacer()
                    Button("Back to current") { stopViewing() }.font(.caption).controlSize(.small).pointer().uiFrame("history.back").uiTap("history.back") { stopViewing() }
                    Button("Restore") { restore(v) }.font(.caption).controlSize(.small).buttonStyle(.borderedProminent).pointer().uiFrame("history.restoreViewing").uiTap("history.restoreViewing") { restore(v) }
                }
                .padding(6).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(Array(h.indices.reversed()), id: \.self) { k in
                let e = h[k]
                let isCurrent = k == h.count - 1
                let selected = viewing.map { $0.id == (isCurrent ? "current" : h[k + 1].id.short) } ?? isCurrent
                HStack(spacing: 8) {
                    Image(systemName: e.origin == .agent ? "sparkles" : e.origin == .user ? "person" : "gear").foregroundStyle(e.origin == .agent ? .purple : .secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.label).font(.caption).lineLimit(1)
                        Text((isCurrent ? "Current · " : "") + e.createdAt.formatted(date: .omitted, time: .shortened) + changes(k)).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    Spacer()
                    if !isCurrent {
                        Button("Restore") { if let v = try? document.version(afterEditAt: k) { restore(v) } }.font(.caption).controlSize(.small).pointer().help("Make this version current again")
                            .uiFrame("history.restore.\(k)").uiTap("history.restore.\(k)", key: e.id.uuidString) { if let v = try? document.version(afterEditAt: k) { restore(v) } }
                    }
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(selected ? Color.accentColor.opacity(0.18) : isCurrent ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle()).onTapGesture { if isCurrent { stopViewing() } else { view(try? document.version(afterEditAt: k)) } }
                .pointer().uiFrame("history.\(k)").help(isCurrent ? "The project as it is now" : "Show the project as it was after this edit")
                .uiTap("history.\(k)", key: "\(e.id.uuidString)-\(isCurrent)") { if isCurrent { stopViewing() } else { view(try? document.version(afterEditAt: k)) } }
            }
            if !h.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) { Text("Original").font(.caption); Text("Before the first edit").font(.caption2).foregroundStyle(.tertiary) }
                    Spacer()
                    Button("Restore") { if let v = try? document.version(afterEditAt: nil) { restore(v) } }.font(.caption).controlSize(.small).pointer().uiFrame("history.restore.original")
                        .uiTap("history.restore.original") { if let v = try? document.version(afterEditAt: nil) { restore(v) } }
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(viewing?.id == "original" ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle()).onTapGesture { view(try? document.version(afterEditAt: nil)) }.pointer().uiFrame("history.original")
                .uiTap("history.original") { view(try? document.version(afterEditAt: nil)) }
            }
            if h.isEmpty { Text("No edits yet.").font(.caption).foregroundStyle(.tertiary) }
        }
        .onChange(of: document.revision) { _, _ in if state.viewingVersion != nil { state.viewingVersion = nil } }   // any edit returns to the live project
        .onDisappear { if state.viewingVersion != nil { stopViewing() } }
    }

    private func view(_ v: ProjectVersion?) {
        guard let v else { return }
        if v.isCurrent { stopViewing(); return }
        state.viewingVersion = v
        player.view(v.project)
    }
    private func stopViewing() { state.viewingVersion = nil; player.view(nil) }
    private func restore(_ v: ProjectVersion) { stopViewing(); try? document.restore(version: v, origin: .user) }

    /// " · what changed" for edit k, from the snapshot before it to the state after it. Decoded once per entry.
    private func changes(_ k: Int) -> String {
        let h = document.project.history
        let key = h[k].id
        if let c = VersionDiffCache.shared.text[key] { return c }
        guard let before = try? EditMaxDocument.decoder.decode(Project.self, from: h[k].project),
              let after = k == h.count - 1 ? document.project : (try? EditMaxDocument.decoder.decode(Project.self, from: h[k + 1].project)) else { return "" }
        let d = ProjectDiff.summary(from: before, to: after)
        let text = d.isEmpty ? "" : " · " + d
        if k < h.count - 1 { VersionDiffCache.shared.text[key] = text }   // the newest edit's "after" is live and may still coalesce
        return text
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
                if state.selectedClipIDs.count >= 1 {
                    // Read the selection when the button fires: the driver keeps the handler it registered first.
                    let nest = { Task { @MainActor in
                        let nestIDs = [clip.id.uuidString] + state.selectedClipIDs.subtracting([clip.id]).map(\.uuidString)
                        if let info = try? await ToolExecutor(document: document, origin: .user).nestClips(nestIDs, name: nil), let c = info.clip, let id = Project.resolve(c, in: document.project.allClips.map(\.id)) { state.selectedClipIDs = [id] } } }
                    Button("Nest \(state.selectedClipIDs.count) selected into a sequence", systemImage: "square.stack.3d.down.right") { _ = nest() }
                        .controlSize(.small).pointer().uiTap("inspector.sequence.nest") { _ = nest() }.uiFrame("inspector.sequence.nest")
                }
                if state.selectedClipIDs.count >= 2, clip.multicam == nil {
                    let make = { Task { @MainActor in
                        let ids = [clip.id.uuidString] + state.selectedClipIDs.subtracting([clip.id]).map(\.uuidString)
                        if let info = try? await ToolExecutor(document: document, origin: .user).makeMulticam(ids, sync: "audio"), let id = Project.resolve(info.clip, in: document.project.allClips.map(\.id)) { state.selectedClipIDs = [id] } } }
                    Button("Make multicam from \(state.selectedClipIDs.count) selected", systemImage: "camera.on.rectangle") { _ = make() }.controlSize(.small).pointer()
                    .uiTap("inspector.multicam.make") { _ = make() }
                    .uiFrame("inspector.multicam.make")
                }
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
            if let seq = document.project.sequence(of: clip) {
                Section("Nested sequence") {
                    let n = seq.project.allClips.count
                    LabeledContent("Sequence", value: seq.name)
                    LabeledContent("Contents", value: "\(n) clip\(n == 1 ? "" : "s") on \(seq.project.tracks.map(\.name).joined(separator: ", ")), \(Timecode.string(seq.project.duration))")
                    let unnest = { _ = try? ToolExecutor(document: document, origin: .user).unnestClip(clip.id.uuidString); state.selectedClipIDs = [] }
                    Button("Unnest onto the timeline", systemImage: "square.stack.3d.up") { unnest() }.controlSize(.small).pointer()
                        .uiTap("inspector.sequence.unnest") { unnest() }.uiFrame("inspector.sequence.unnest")
                    Text("Speed, color, fades, transitions and keyframes on this clip apply to the whole group.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let mc = clip.multicam {
                Section("Multicam") {
                    let plain = ToolExecutor(document: document, origin: .user)
                    let active = mc.angle(at: localTime)
                    HStack(spacing: 6) {
                        ForEach(Array(mc.angles.enumerated()), id: \.offset) { i, aid in
                            Button("\(i + 1)") { _ = try? plain.cutAngle(clip.id.uuidString, at: player.currentTime, angle: i + 1) }
                                .buttonStyle(.bordered).tint(active == i ? Color.accentColor : nil)
                                .help(document.project.asset(aid)?.name ?? "missing").pointer()
                                .uiTap("inspector.angle.\(i + 1)") { _ = try? plain.cutAngle(clip.id.uuidString, at: player.currentTime, angle: i + 1) }
                                .uiFrame("inspector.angle.\(i + 1)")
                        }
                        Spacer()
                        Text("angle \(active + 1) at playhead").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Click an angle to cut to it at the playhead. The cut line shows on the clip.").font(.caption).foregroundStyle(.secondary)
                    Picker("Sound from", selection: Binding(get: { mc.audioAngle }, set: { v in _ = try? plain.setMulticam(clip.id.uuidString, audioAngle: v + 1, offsets: nil, flatten: false) })) {
                        ForEach(0..<mc.angles.count, id: \.self) { i in Text("Angle \(i + 1) · \(document.project.asset(mc.angles[i])?.name ?? "")").tag(i) }
                    }.pointer().uiFrame("inspector.multicam.audio")
                    ForEach(mc.cuts.map { ("cut-\($0.time)", $0) }, id: \.0) { _, cut in
                        HStack {
                            Text("\(Timecode.string(clip.start + cut.time))  →  angle \(cut.angle + 1)").font(.caption).monospacedDigit()
                            Spacer()
                            Button { player.pause(); player.seek(to: clip.start + cut.time) } label: { Image(systemName: "arrow.right.to.line") }.buttonStyle(.borderless).help("Go to cut").pointer()
                            Button { _ = try? plain.cutAngle(clip.id.uuidString, at: clip.start + cut.time, angle: 0, remove: true) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove cut").pointer()
                        }
                    }
                    if mc.angles.count > 1 {
                        Text("Offsets: " + mc.angles.indices.dropFirst().map { "angle \($0 + 1) \(String(format: "%+.2f", mc.offset($0))) s" }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Sync by audio", systemImage: "waveform.badge.magnifyingglass") { Task { @MainActor in _ = try? await plain.syncAngles(clip.id.uuidString) } }.pointer()
                            .uiTap("inspector.multicam.sync") { Task { @MainActor in _ = try? await plain.syncAngles(clip.id.uuidString) } }.uiFrame("inspector.multicam.sync")
                        Button("Flatten to clips", systemImage: "rectangle.split.3x1") { _ = try? plain.setMulticam(clip.id.uuidString, audioAngle: nil, offsets: nil, flatten: true) }.pointer()
                            .uiTap("inspector.multicam.flatten") { _ = try? plain.setMulticam(clip.id.uuidString, audioAngle: nil, offsets: nil, flatten: true) }.uiFrame("inspector.multicam.flatten")
                    }.controlSize(.small)
                }
            }
            Section("Speed") {
                slider("Speed", param: .speed, value: clip.speed, range: 0...4, format: { String(format: "%.2f×", $0) }, reset: 1) { try? x.setClipProperties(clip.id.uuidString, speed: $0) }
                if clip.isAnimated(.speed) {
                    Text("Speed ramp: \(clip.keyframes(.speed).count) keyframes, uses \(Timecode.string(clip.sourceOut - clip.sourceIn)) of media. 0× holds a frame.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Click the diamond to start a speed ramp from the playhead.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if track.kind == .video {
                Section {
                    let tf = clip.transform
                    slider("Scale", param: .scale, value: tf.scale, range: 0.1...4, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipTransform(clip.id.uuidString, scale: $0, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Position X", param: .x, value: tf.x, range: -1...1, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: $0, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Position Y", param: .y, value: tf.y, range: -1...1, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: $0, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Rotation", param: .rotation, value: tf.rotation, range: -180...180, format: { "\(Int($0))°" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: $0, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Crop left", value: tf.cropLeft, range: 0...0.9, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: $0, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Crop right", value: tf.cropRight, range: 0...0.9, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: $0, cropTop: nil, cropBottom: nil, reset: false) }
                    slider("Crop top", value: tf.cropTop, range: 0...0.9, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: $0, cropBottom: nil, reset: false) }
                    slider("Crop bottom", value: tf.cropBottom, range: 0...0.9, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: $0, reset: false) }
                    slider("Opacity", param: .opacity, value: clip.opacity, range: 0...1, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipProperties(clip.id.uuidString, opacity: $0) }
                } header: {
                    HStack { Text("Transform"); Spacer(); if !clip.transform.isIdentity { Button("Reset") { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: true) }.controlSize(.mini).pointer() } }
                }
                Section {
                    let c = clip.color
                    slider("Exposure", param: .exposure, value: c.exposure, range: -2...2, format: { String(format: "%+.1f", $0) }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: $0, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false) }
                    slider("Contrast", param: .contrast, value: c.contrast, range: 0.5...2, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: $0, saturation: nil, temperature: nil, tint: nil, reset: false) }
                    slider("Saturation", param: .saturation, value: c.saturation, range: 0...2, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: $0, temperature: nil, tint: nil, reset: false) }
                    slider("Temperature", param: .temperature, value: c.temperature, range: -100...100, format: { "\(Int($0))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: $0, tint: nil, reset: false) }
                    slider("Tint", param: .tint, value: c.tint, range: -100...100, format: { "\(Int($0))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: $0, reset: false) }
                    slider("Shadows", param: .shadows, value: c.shadows, range: -1...1, format: { "\(Int($0 * 100))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, shadows: $0) }
                    slider("Midtones", param: .midtones, value: c.midtones, range: -1...1, format: { "\(Int($0 * 100))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, midtones: $0) }
                    slider("Highlights", param: .highlights, value: c.highlights, range: -1...1, format: { "\(Int($0 * 100))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, highlights: $0) }
                    slider("Vibrance", param: .vibrance, value: c.vibrance, range: -1...1, format: { "\(Int($0 * 100))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, vibrance: $0) }
                } header: {
                    HStack { Text("Color"); Spacer(); if !clip.color.isIdentity { Button("Reset") { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: true) }.controlSize(.mini).pointer() } }
                }
            }
            if track.kind == .video {
                Section("Look") {
                    let c = clip.color
                    let plain = ToolExecutor(document: document, origin: .user)
                    Picker("Input LUT", selection: Binding(get: { c.inputLut ?? "none" }, set: { v in
                        if v == "file" { pickCube(plain, input: true) } else { try? plain.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, inputLut: v) }
                    })) {
                        Text("None (footage is already Rec.709)").tag("none")
                        if let path = c.inputLut { Text(URL(fileURLWithPath: path).lastPathComponent).tag(path) }
                        Divider()
                        Text("Load conversion .cube (D-Log → Rec.709…)…").tag("file")
                    }.pointer().uiFrame("inspector.inputLut")
                    Picker("Look", selection: Binding(get: { c.lut ?? "none" }, set: { v in
                        if v == "file" { pickCube(plain) } else { try? plain.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, lut: v) }
                    })) {
                        Text("None").tag("none")
                        ForEach(Looks.builtin, id: \.self) { Text($0).tag($0) }
                        if let path = c.lut, !Looks.isBuiltin(path) { Text(URL(fileURLWithPath: path).lastPathComponent).tag(path) }
                        Divider()
                        Text("Load .cube file…").tag("file")
                    }.pointer().uiFrame("inspector.look")
                    if c.lut != nil {
                        slider("Mix", param: .lutMix, value: c.lutMix, range: 0...1, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, lutMix: $0) }
                    }
                    Text("The input LUT runs first, at full strength: it turns log footage (DJI D-Log, S-Log, V-Log) into a normal Rec.709 image, so the controls above behave as expected. A look is a 3D LUT applied after the color controls. Built-in looks are generated; .cube files from any grading app load as they are.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Audio") {
                slider("Volume", param: .volume, value: clip.volume, range: 0...2, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipProperties(clip.id.uuidString, volume: $0) }
                slider("Fade in", value: clip.fadeIn, range: 0...min(5, clip.duration), format: { String(format: "%.1f s", $0) }, reset: 0) { try? x.setClipFades(clip.id.uuidString, fadeIn: $0, fadeOut: nil) }
                slider("Fade out", value: clip.fadeOut, range: 0...min(5, clip.duration), format: { String(format: "%.1f s", $0) }, reset: 0) { try? x.setClipFades(clip.id.uuidString, fadeIn: nil, fadeOut: $0) }
                if track.kind == .video { Text("Fades take the picture to black and the sound to silence.").font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                let au = clip.audio
                slider("Low", value: au.lowGain, range: -18...18, format: { String(format: "%+.0f dB", $0) }, reset: 0) { try? x.setClipAudio(clip.id.uuidString, low: $0, mid: nil, high: nil, highPass: nil, gate: nil, reset: false) }
                slider("Mid", value: au.midGain, range: -18...18, format: { String(format: "%+.0f dB", $0) }, reset: 0) { try? x.setClipAudio(clip.id.uuidString, low: nil, mid: $0, high: nil, highPass: nil, gate: nil, reset: false) }
                slider("High", value: au.highGain, range: -18...18, format: { String(format: "%+.0f dB", $0) }, reset: 0) { try? x.setClipAudio(clip.id.uuidString, low: nil, mid: nil, high: $0, highPass: nil, gate: nil, reset: false) }
                slider("High-pass", value: au.highPass, range: 0...400, format: { $0 <= 0 ? "off" : "\(Int($0)) Hz" }, reset: 0) { try? x.setClipAudio(clip.id.uuidString, low: nil, mid: nil, high: nil, highPass: $0 < 20 ? 0 : $0, gate: nil, reset: false) }
                slider("Noise gate", value: au.gate, range: -80...0, format: { $0 >= 0 ? "off" : "\(Int($0)) dB" }, reset: 0) { try? x.setClipAudio(clip.id.uuidString, low: nil, mid: nil, high: nil, highPass: nil, gate: $0 > -1 ? 0 : $0, reset: false) }
                Text("EQ shelves at 200 Hz and 6 kHz, a 1 kHz peak. A high-pass around 80–120 Hz removes rumble; the gate drops 26 dB below its threshold.").font(.caption).foregroundStyle(.secondary)
            } header: {
                HStack { Text("EQ & cleanup"); Spacer(); if !clip.audio.isIdentity { Button("Reset") { try? x.setClipAudio(clip.id.uuidString, low: nil, mid: nil, high: nil, highPass: nil, gate: nil, reset: true) }.controlSize(.mini).pointer() } }
            }
            Section("Transition in") {
                Picker("Kind", selection: Binding(get: { clip.transitionIn?.kind.rawValue ?? "none" }, set: { v in _ = try? ToolExecutor(document: document, origin: .user).setTransition(clip.id.uuidString, kind: v, duration: nil); transitionNote = nil })) {
                    Text("None").tag("none")
                    ForEach(Transition.Kind.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.pointer()
                if let tr = clip.transitionIn {
                    slider("Duration", value: tr.duration, range: 0.1...min(3, clip.duration), format: { String(format: "%.2f s", $0) }, reset: 0.5) { d in
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

    private func pickCube(_ x: ToolExecutor, input: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = input ? "Choose the camera's conversion .cube (log → Rec.709)" : "Choose a .cube 3D LUT"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if input { try x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, inputLut: url.path) }
            else { try x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, lut: url.path) }
        }
        catch { NSAlert(error: error).runModal() }
    }

    private func commitName(_ x: ToolExecutor) {
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, n != clip.name { try? x.setClipProperties(clip.id.uuidString, name: n) }
    }

    /// The playhead inside this clip, in clip-local seconds.
    private var localTime: Double { max(0, min(clip.duration, player.currentTime - clip.start)) }
    private func hasKeyframe(_ p: ClipParam) -> Bool { clip.keyframes(p).contains { abs($0.time - localTime) < 1.0 / 120 } }

    /// A labeled slider with its value on the right; double-click the value to reset. With `param`, a keyframe diamond:
    /// once a parameter is animated, dragging the slider writes a keyframe at the playhead instead of the plain value.
    private func slider(_ title: String, param: ClipParam? = nil, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String, reset: Double, set: @escaping (Double) -> Void) -> some View {
        let x = ToolExecutor(document: document, origin: .user, coalesce: true)
        let animated = param.map(clip.isAnimated) ?? false
        let shown = (param != nil && animated) ? clip.value(param!, at: localTime) : value
        let apply: (Double) -> Void = { v in
            if let param, animated { _ = try? x.setKeyframe(clip.id.uuidString, param: param.rawValue, time: player.currentTime, value: v, ease: nil) } else { set(v) }
        }
        return LabeledContent(title) {
            HStack(spacing: 8) {
                if let param {
                    let onKey = hasKeyframe(param)
                    Button {
                        let plain = ToolExecutor(document: document, origin: .user)
                        if onKey { _ = try? plain.removeKeyframe(clip.id.uuidString, param: param.rawValue, time: player.currentTime, all: false) }
                        else { _ = try? plain.setKeyframe(clip.id.uuidString, param: param.rawValue, time: player.currentTime, value: shown, ease: nil) }
                    } label: {
                        Image(systemName: onKey ? "diamond.fill" : "diamond").font(.system(size: 10)).foregroundStyle(animated ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless).pointer().uiFrame("inspector.key.\(param.rawValue)")
                    .help(onKey ? "Remove the keyframe at the playhead" : (animated ? "Add a keyframe at the playhead" : "Animate: add the first keyframe at the playhead"))
                    .contextMenu {
                        if animated {
                            let plain = ToolExecutor(document: document, origin: .user)
                            if onKey, let k = clip.keyframes(param).first(where: { abs($0.time - localTime) < 1.0 / 120 }) {
                                Picker("Ease to next", selection: Binding(get: { k.ease.rawValue }, set: { e in _ = try? plain.setKeyframe(clip.id.uuidString, param: param.rawValue, time: player.currentTime, value: k.value, ease: e) })) {
                                    Text("Linear").tag("linear"); Text("Smooth").tag("smooth"); Text("Hold").tag("hold")
                                }
                            }
                            Button("Previous keyframe") { jumpKeyframe(param, forward: false) }
                            Button("Next keyframe") { jumpKeyframe(param, forward: true) }
                            Divider()
                            Button("Remove all \(clip.keyframes(param).count) keyframes") { _ = try? plain.removeKeyframe(clip.id.uuidString, param: param.rawValue, time: nil, all: true) }
                        }
                    }
                }
                Slider(value: .init(get: { shown }, set: apply), in: range).controlSize(.small)
                Text(format(shown)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    .onTapGesture(count: 2) { apply(reset) }.help("Double-click to reset")
            }
        }
    }

    private func jumpKeyframe(_ p: ClipParam, forward: Bool) {
        let ts = clip.keyframes(p).map { clip.start + $0.time }
        let t = forward ? ts.first { $0 > player.currentTime + 0.001 } : ts.last { $0 < player.currentTime - 0.001 }
        if let t { player.pause(); player.seek(to: t) }
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
    @State private var templateName = ""
    @State private var templateChoice = ""
    @State private var templateStatus: String?
    @ObservedObject private var proxies = ProxyStore.shared
    var body: some View {
        let p = document.project
        let captionCount = p.texts.filter(\.isCaption).count
        let x = ToolExecutor(document: document, origin: .user)
        Form {
            Section("Project") {
                LabeledContent("Resolution", value: "\(p.settings.width)×\(p.settings.height)")
                LabeledContent("Frame rate", value: "\(Int(p.settings.fps)) fps")
                LabeledContent("Duration", value: Timecode.string(p.duration))
                LabeledContent("Clips", value: "\(p.allClips.count)")
                LabeledContent("Project ID", value: document.id.short)
            }
            Section("Proxies") {
                let videos = p.assets.filter { $0.kind == .video }
                let ready = videos.filter { proxies.ready(for: $0) != nil }.count
                let building = videos.filter { if case .building = proxies.status[$0.id] { return true }; return false }
                Toggle("Preview from proxies", isOn: Binding(get: { p.settings.useProxies }, set: { v in try? x.setProjectSettings(width: nil, height: nil, fps: nil, name: nil, useProxies: v) })).pointer().uiFrame("inspector.proxies")
                HStack {
                    Button("Make proxies", systemImage: "arrow.down.right.and.arrow.up.left") { _ = x.makeProxies(enable: true) }.disabled(videos.isEmpty || ready == videos.count).pointer()
                    Spacer()
                    Text(videos.isEmpty ? "No video files yet." : building.isEmpty ? "\(ready) of \(videos.count) ready" : "Building \(building.count)…").font(.caption).foregroundStyle(.secondary)
                }
                Text("960×540 copies for smooth playback. The export always uses the original files.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Templates") {
                let all = Templates.list()
                HStack {
                    Picker("Template", selection: $templateChoice) {
                        Text("Choose…").tag("")
                        ForEach(all) { t in Text(t.builtin ? "\(t.name)  (\(t.width)×\(t.height))" : t.name).tag(t.name) }
                    }.labelsHidden().pointer().uiFrame("inspector.template")
                    Button("Apply") {
                        do { let t = try x.applyTemplate(templateChoice); templateStatus = "Applied \(t.name). Undo with ⌘Z." } catch { templateStatus = error.localizedDescription }
                    }.disabled(templateChoice.isEmpty).pointer().uiFrame("inspector.template.apply")
                }
                HStack {
                    TextField("Save this project as a template", text: $templateName).textFieldStyle(.roundedBorder).controlSize(.small)
                    Button("Save") {
                        do { _ = try x.saveTemplate(templateName); templateStatus = "Saved template '\(templateName)'."; templateName = "" } catch { templateStatus = error.localizedDescription }
                    }.disabled(templateName.trimmingCharacters(in: .whitespaces).isEmpty).pointer()
                }
                Text(templateStatus ?? "Built-in templates set the format on an empty timeline; a saved template restores its tracks, clips and titles.").font(.caption).foregroundStyle(.secondary)
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
            if p.tracks.count > 1 {
                Section("Ducking") {
                    let plain = ToolExecutor(document: document, origin: .user)
                    ForEach(p.tracks) { t in
                        HStack {
                            Text(t.name).frame(width: 36, alignment: .leading)
                            Picker("under", selection: Binding(get: { t.duck?.sourceTrackID.uuidString ?? "none" }, set: { v in _ = try? plain.setDucking(t.id.uuidString, under: v == "none" ? "none" : v, level: nil, attack: nil, release: nil) })) {
                                Text("Not ducked").tag("none")
                                ForEach(p.tracks.filter { $0.id != t.id }) { o in Text("Under \(o.name)").tag(o.id.uuidString) }
                            }.labelsHidden().pointer().uiFrame("inspector.duck.\(t.name)")
                            if let d = t.duck {
                                Slider(value: Binding(get: { d.level }, set: { v in _ = try? ToolExecutor(document: document, origin: .user, coalesce: true).setDucking(t.id.uuidString, under: nil, level: v, attack: nil, release: nil) }), in: 0...1).controlSize(.small).frame(width: 70)
                                Text("\(Int(d.level * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                    Text("A ducked track drops to the level while clips play on the other track.").font(.caption).foregroundStyle(.secondary)
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
