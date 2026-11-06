import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation

// MARK: - Inspector styling primitives
// One visual system for every page of the right-hand panel: titled cards of rows with 1 px hairlines between them,
// 12 pt inner padding, uppercase tracked section headers, 13 pt body and 11 pt secondary text. Everything in here is
// content, so controls stay bordered or plain; Liquid Glass belongs to the floating layer over the video and timeline.

enum InspectorStyle {
    static let cardRadius: CGFloat = 12
    static let rowInset: CGFloat = 12
    static let labelWidth: CGFloat = 84
    static let gap: CGFloat = 16
    static var cardFill: Color { Color.primary.opacity(0.045) }   // a touch lighter than the panel in dark, a touch darker in light
    static var hairline: Color { Color.primary.opacity(0.08) }
}

/// Section header: caption, semibold, tracked, uppercase, secondary.
struct InspectorHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.caption.weight(.semibold)).tracking(0.8).textCase(.uppercase).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// A titled card. Every child of `content` is one row (`if` and `ForEach` children included), separated by hairlines.
/// `trailing` sits at the right of the header (a Reset button, a count); `footer` is the explanatory line under the card.
struct InspectorCard<Content: View, Trailing: View>: View {
    let title: String?
    let footer: String?
    let trailing: Trailing
    let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack(alignment: .center, spacing: 8) {
                    InspectorHeader(title: title)
                    Spacer(minLength: 8)
                    trailing
                }
                .frame(minHeight: 20)
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    // Rows keep their own identity (not their index), so a conditional row appearing above a stateful
                    // one does not hand that row's state to its neighbour.
                    ForEach(subviews) { row in
                        row
                            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                            .padding(.horizontal, InspectorStyle.rowInset).padding(.vertical, 5)
                        if row.id != subviews.last?.id { InspectorSeparator() }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: InspectorStyle.cardRadius, style: .continuous).fill(InspectorStyle.cardFill))
            .overlay(RoundedRectangle(cornerRadius: InspectorStyle.cardRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            if let footer { InspectorFootnote(footer).padding(.horizontal, 4) }
        }
    }
}

extension InspectorCard where Trailing == EmptyView {
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, trailing: { EmptyView() }, content: content)
    }
}

/// The 1 px hairline between two rows of a card.
struct InspectorSeparator: View {
    var body: some View { Rectangle().fill(InspectorStyle.hairline).frame(height: 1).padding(.leading, InspectorStyle.rowInset) }
}

/// Label left, read-only value right, digits monospaced.
struct InspectorValueRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 13))
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

/// Label left, a control right.
struct InspectorRow<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 13))
            Spacer(minLength: 8)
            content
        }
    }
}

/// 11 pt secondary explanatory text; wraps.
struct InspectorFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The fill, selection ring and hover of a history row. Hover state lives in the modifier so moving the mouse redraws
/// one row, not the list (whose newest row decodes the project to describe its change).
struct HistoryRowStyle: ViewModifier {
    let selected: Bool
    let current: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(selected ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.06) : current ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(selected ? 1 : 0), lineWidth: 1.5))
            .onHover { hovering = $0 }
    }
}

/// A status dot: green = ready, orange = attention, red = failure.
struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

/// The centred empty state of a page: 40 pt symbol, headline, one-line hint.
struct InspectorEmptyState: View {
    let symbol: String
    let title: String
    let hint: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32)
    }
}

/// Plain-English text for an error shown in the inspector or the mixer. The engine's errors are written for the agents
/// that call the same tools ("Invalid: nothing to measure: …", tool and parameter names); a person reading the inspector
/// gets a sentence instead. Every catch in the inspector and the mixer turns its error into text here.
enum InspectorMessage {
    /// What the failed action was about, when that changes the right words.
    enum Scope { case general, clip }

    static func text(_ error: Error, scope: Scope = .general) -> String {
        let raw: String
        if let e = error as? EditError {
            switch e {
            case .invalid(let s): raw = s
            case .notFound(let s): raw = "Could not find " + s
            }
        } else if error is CancellationError {
            raw = "Stopped"
        } else {
            raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return sentence(raw, scope: scope)
    }

    /// Engine phrases that read like code or name a framework, and what they mean for the person.
    private static func phrases(_ scope: Scope) -> [(String, String)] {
        [("nothing to measure: no clip with sound on an unmuted track",
          scope == .clip ? "This clip has no sound to measure" : "There is no sound to measure: no clip with sound plays on an unmuted track"),
         ("cannot read the mixed sound", "Could not read the sound to measure it"),
         ("reading the mixed sound failed", "Could not read the sound to measure it"),
         ("the sound is silent (below −70 LUFS everywhere): nothing to normalize", "The sound is silent, so there is nothing to normalize"),
         ("AVFoundation hands its processing one channel and spreads it to both speakers afterwards, so it cannot be panned", "it plays in both speakers and cannot be panned"),
         ("; give frequency 50 or 60", ". Choose 50 Hz or 60 Hz instead")]
    }

    /// Tidies an engine message into a sentence: no "Invalid:" prefix, no hint naming a tool, a capital and a full stop.
    static func sentence(_ raw: String, scope: Scope = .general) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A wrapped error repeats the engine's prefixes ("Transcription failed: Invalid: …").
        t = t.replacingOccurrences(of: "Invalid: ", with: "").replacingOccurrences(of: "Not found: ", with: "could not find ")
        for (code, words) in phrases(scope) { t = t.replacingOccurrences(of: code, with: words) }
        // Hints for agents name a tool or parameter in brackets: "remove it first (set_transition kind none)".
        t = t.replacingOccurrences(of: #"\s*\([^()]*(?<![\w.'"])[a-z]+_[a-z_]+(?![\w.'"])[^()]*\)"#, with: "", options: .regularExpression)
        guard let first = t.first else { return "Something went wrong." }
        t = first.uppercased() + t.dropFirst()
        if let last = t.last, !".!?…".contains(last) { t += "." }
        return t
    }
}

/// The inspector's slider. `neutral` is the resting value of a setting that runs both ways from it (pan, a gain in dB,
/// a J or L cut's lead): on macOS 26 the track fills from there instead of from the left end and a tick marks it, and a
/// drag that comes within 1 % of the range of it lands exactly on it, so "unchanged" is easy to see and to hit.
struct InspectorSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var neutral: Double? = nil
    let set: (Double) -> Void

    var body: some View {
        let binding = Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: { v in set(Self.snapped(v, to: neutral, in: range)) })
        if #available(macOS 26.0, *), let neutral, range.lowerBound < neutral, neutral < range.upperBound {
            Slider(value: binding, in: range, neutralValue: neutral, label: { EmptyView() }, ticks: { SliderTick(neutral) })
        } else {
            Slider(value: binding, in: range)
        }
    }

    /// `v`, or the neutral value when `v` is within 1 % of the range of it.
    static func snapped(_ v: Double, to neutral: Double?, in range: ClosedRange<Double>) -> Double {
        guard let neutral, abs(v - neutral) < (range.upperBound - range.lowerBound) * 0.01 else { return v }
        return neutral
    }

    /// Zero, for a slider whose range runs both ways from zero and whose reset is zero (a gain, an offset, a pan); nil
    /// for one that fills from its left end (a level, an amount, a length).
    static func neutral(range: ClosedRange<Double>, reset: Double) -> Double? {
        range.lowerBound < 0 && range.upperBound > 0 && reset == 0 ? 0 : nil
    }
}

extension InspectorStyle {
    /// The smallest click target in the panel: icon buttons get at least this much room around their glyph.
    static let hitTarget: CGFloat = 22
}

extension View {
    /// An icon button's label made at least `InspectorStyle.hitTarget` square and clickable all over, so a 10 pt glyph is
    /// not a 10 pt target.
    func inspectorHitTarget() -> some View {
        frame(minWidth: InspectorStyle.hitTarget, minHeight: InspectorStyle.hitTarget).contentShape(Rectangle())
    }
    /// Dims a control that cannot be used. A mini switch that is off draws the same enabled or disabled, so without this
    /// a disabled one reads as available.
    func inspectorDisabledLook(_ disabled: Bool) -> some View { opacity(disabled ? 0.4 : 1) }
    /// The fixed label column of a slider row.
    func inspectorLabel() -> some View {
        font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.8).frame(width: InspectorStyle.labelWidth, alignment: .leading)
    }
    /// The value readout of a slider row.
    func inspectorValue() -> some View {
        font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
    }
    /// A secondary 11 pt line inside a row.
    func inspectorSecondary() -> some View { font(.system(size: 11)).foregroundStyle(.secondary) }
}

struct InspectorView: View {
    @ObservedObject var document: EditMaxDocument
    @EnvironmentObject var state: EditorState
    @EnvironmentObject var player: PlayerController
    @ObservedObject var mcp = MCPService.shared
    @ObservedObject var installer = CodemaxInstaller.shared
    @ObservedObject private var updater = CodemaxUpdater.shared

    var body: some View {
        VStack(spacing: 0) {
            // The tab strip is control layer: one glass group, the selected tab tinted.
            GlassGroup(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(EditorState.InspectorTab.allCases, id: \.self) { tab in
                        let on = state.inspectorTab == tab
                        Button { state.inspectorTab = tab } label: {
                            Text(tab.rawValue).font(.system(size: 12, weight: on ? .semibold : .medium))
                                .padding(.horizontal, 12).frame(height: 26).frame(maxWidth: .infinity)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).focusable(false)
                        .liquidGlass(tint: on ? Color.glassSelection : nil, interactive: true)
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .pointer()
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).uiFrame("inspector.tabs")
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
        VStack(alignment: .leading, spacing: InspectorStyle.gap) {
            InspectorCard("MCP server", footer: "Listens on localhost only. Clients send the bearer token that is part of each snippet below.", trailing: {
                Text("\(mcp.requestCount) request\(mcp.requestCount == 1 ? "" : "s")").inspectorSecondary().monospacedDigit()
            }) {
                HStack(spacing: 8) {
                    StatusDot(color: statusColor)
                    Text(statusText).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    if let p = mcpPort { Text("port \(String(p))").inspectorSecondary().monospacedDigit() }
                }
                if case .failed(let e) = mcp.status { InspectorFootnote(e).lineLimit(2) }
                if let c = mcp.lastClient { InspectorValueRow("Last client", c) }
            }
            agentRuntime
            installedAgents
            snippet("Claude Code", mcp.claudeCodeCommand, id: "claudeCode")
            snippet("Codex CLI", mcp.codexCommand, id: "codex")
            snippet("Cursor, Claude Desktop, any JSON config", mcp.genericJSON, id: "json")
            logs
        }
    }
    /// Where to look when something goes wrong, and one button that packs it all for a bug report.
    @State private var exportNote: String?
    private var logs: some View {
        let config = MCPService.configDirectory.appendingPathComponent("mcp.json").path
        return InspectorCard("Diagnostics", footer: "The logs record the agent runtime, the updater and the MCP server, and every line exchanged with the agent runtime, secrets removed. Export packs them with the runtime's own debug log.") {
            HStack(spacing: 8) {
                Button("Export diagnostics…") {
                    do {
                        let zip = try DebugLog.exportDiagnostics(versions: ["editmax": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "", "codemax-bundled": installer.status.bundledVersion ?? "", "codemax-installed": installer.status.installedPath ?? "", "editmax-agent": CodemaxRunner.bundledBinary(.agent)?.path ?? "missing"])
                        exportNote = "Saved to \(zip.lastPathComponent) on the Desktop."
                        NSWorkspace.shared.activateFileViewerSelecting([zip])
                    } catch { exportNote = "Export failed: " + InspectorMessage.text(error) }
                }.controlSize(.small).pointer().uiFrame("agents.exportDiagnostics")
                Button("Reveal logs") { DebugLog.reveal() }.controlSize(.small).pointer().uiFrame("agents.revealLogs")
                Spacer(minLength: 0)
            }
            if let n = exportNote { InspectorFootnote(n) }
            pathRow("Config file", config)
        }
    }
    /// The bundled codemax: install state and updates.
    private var agentRuntime: some View {
        let s = installer.status, u = updater.status
        return InspectorCard("Agent runtime", footer: "The agent runtime ships inside EditMax. New releases install on their own (checked every 12 h) after a health check; one that crashes twice is rolled back.") {
            InspectorValueRow("Bundled runtime", s.bundledVersion ?? "—")
            InspectorValueRow("Running", (u.activeVersion ?? "?") + " · " + u.activeSource)
            InspectorValueRow("Latest release", u.latest ?? "not checked")
            HStack(spacing: 8) {
                Text(u.message).inspectorSecondary().lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                if u.busy { ProgressView().controlSize(.mini) }
                Button("Check now") { updater.check(reason: "button") }.controlSize(.small).pointer().disabled(updater.status.busy).uiFrame("agents.checkUpdate")
            }
            InspectorFootnote(s.message).lineLimit(2)
            if let p = s.installedPath { pathRow("Location", p) }
        }
    }
    /// Which agents codemax found on this Mac.
    private var installedAgents: some View {
        InspectorCard("Installed agents") {
            if let chat = state.chat {
                ForEach(chat.agents) { a in
                    HStack(spacing: 8) {
                        StatusDot(color: a.installed ? .green : .orange)
                        Text(a.name).font(.system(size: 13))
                        if let v = a.version { Text(v).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary) }
                        Spacer(minLength: 8)
                        Text(a.installed ? "Ready" : (a.problem ?? "Not installed")).inspectorSecondary().lineLimit(1).truncationMode(.tail)
                    }
                }
                if chat.agents.isEmpty { InspectorFootnote("Looking for agents…") }
            } else {
                InspectorFootnote("The agent runtime starts with the Chat tab.")
            }
        }
    }
    /// A label with a file path on the right: one line, middle-truncated, selectable, full path on hover.
    private func pathRow(_ label: String, _ path: String) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 13))
            Spacer(minLength: 8)
            Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
        }
    }
    private var mcpPort: UInt16? { if case .running(let p) = mcp.status { return p }; return nil }
    private var statusColor: Color { if case .running = mcp.status { return .green }; if case .failed = mcp.status { return .red }; return .orange }
    private var statusText: String {
        switch mcp.status {
        case .running: return "Running"
        case .failed: return "Failed to start"
        case .stopped: return "Stopped"
        }
    }
    private func snippet(_ title: String, _ text: String, id: String) -> some View {
        InspectorCard(title, trailing: {
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }.controlSize(.small).pointer().uiFrame("agents.copy.\(id)")
        }) {
            Text(text).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
        }
    }

    // MARK: History (versions)
    /// One row per edit, newest first, each showing the project *as it was after that edit*. Click a row to see that version in
    /// the preview; Restore makes it current again (itself an edit, so nothing is lost). The bottom row is the original.
    private var history: some View {
        let h = document.project.history
        let viewing = state.viewingVersion
        return VStack(alignment: .leading, spacing: InspectorStyle.gap) {
            InspectorFootnote("Every edit is a version. Click one to see it in the preview, Restore to go back to it. Restoring is itself an edit, so nothing is lost.").padding(.horizontal, 4)
            if let v = viewing, !v.isCurrent {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").imageScale(.medium).foregroundStyle(.orange)
                    Text("Viewing \(v.label) · \(v.date.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).monospacedDigit().lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Back to current") { stopViewing() }.controlSize(.small).pointer().uiFrame("history.back").uiTap("history.back") { stopViewing() }
                    Button("Restore") { restore(v) }.controlSize(.small).buttonStyle(.borderedProminent).pointer().uiFrame("history.restoreViewing").uiTap("history.restoreViewing") { restore(v) }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(h.indices.reversed()), id: \.self) { k in
                    let e = h[k]
                    let isCurrent = k == h.count - 1
                    let selected = viewing.map { $0.id == (isCurrent ? "current" : h[k + 1].id.short) } ?? isCurrent
                    HStack(spacing: 10) {
                        historyNode(isCurrent ? Color.accentColor : e.origin == .agent ? Color.purple : Color.secondary.opacity(0.5))
                        Image(systemName: e.origin == .agent ? "sparkles" : e.origin == .user ? "person" : "gear").font(.system(size: 11)).foregroundStyle(e.origin == .agent ? .purple : .secondary).frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.label).font(.system(size: 13, weight: isCurrent ? .semibold : .regular)).lineLimit(1)
                            Text((isCurrent ? "Current · " : "") + e.createdAt.formatted(date: .omitted, time: .shortened) + changes(k)).inspectorSecondary().monospacedDigit().lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if !isCurrent {
                            Button("Restore") { if let v = try? document.version(afterEditAt: k) { restore(v) } }.controlSize(.small).pointer().help("Make this version current again")
                                .uiFrame("history.restore.\(k)").uiTap("history.restore.\(k)", key: e.id.uuidString) { if let v = try? document.version(afterEditAt: k) { restore(v) } }
                        }
                    }
                    .modifier(HistoryRowStyle(selected: selected, current: isCurrent))
                    .contentShape(Rectangle()).onTapGesture { if isCurrent { stopViewing() } else { view(try? document.version(afterEditAt: k)) } }
                    .pointer().uiFrame("history.\(k)").help(isCurrent ? "The project as it is now" : "Show the project as it was after this edit")
                    .uiTap("history.\(k)", key: "\(e.id.uuidString)-\(isCurrent)") { if isCurrent { stopViewing() } else { view(try? document.version(afterEditAt: k)) } }
                }
                if !h.isEmpty {
                    let selected = viewing?.id == "original"
                    HStack(spacing: 10) {
                        historyNode(Color.secondary.opacity(0.5))
                        Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) { Text("Original").font(.system(size: 13)); Text("Before the first edit").inspectorSecondary() }
                        Spacer(minLength: 8)
                        Button("Restore") { if let v = try? document.version(afterEditAt: nil) { restore(v) } }.controlSize(.small).pointer().uiFrame("history.restore.original")
                            .uiTap("history.restore.original") { if let v = try? document.version(afterEditAt: nil) { restore(v) } }
                    }
                    .modifier(HistoryRowStyle(selected: selected, current: false))
                    .contentShape(Rectangle()).onTapGesture { view(try? document.version(afterEditAt: nil)) }.pointer().uiFrame("history.original")
                    .uiTap("history.original") { view(try? document.version(afterEditAt: nil)) }
                }
            }
            // The timeline rail behind the nodes: one hairline from the newest edit down to the original.
            .background(alignment: .topLeading) {
                if !h.isEmpty { Rectangle().fill(InspectorStyle.hairline).frame(width: 1).padding(.leading, 15.5).padding(.vertical, 16) }
            }
            if h.isEmpty { InspectorEmptyState(symbol: "clock.arrow.circlepath", title: "No edits yet", hint: "Every change shows up here as a version you can go back to.") }
        }
        .onChange(of: document.revision) { _, _ in if state.viewingVersion != nil { state.viewingVersion = nil } }   // any edit returns to the live project
        .onDisappear { if state.viewingVersion != nil { stopViewing() } }
    }
    /// The dot of a history row on the timeline rail.
    private func historyNode(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7).frame(width: 16, height: 16)
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

/// Whether the file a clip plays its sound from has a sound track. The project only records a file's kind, and a video
/// file may have no sound (a screen recording, a drone shot), so the file is read once and the answer cached by path.
@MainActor
enum ClipSound {
    enum Presence: Equatable {
        /// Not read yet, or the file is missing or unreadable: the sound cards stay, so nothing set on them is hidden.
        case unknown
        case none, some
    }
    private static var cache: [String: Presence] = [:]

    /// The answer without reading the file: known kinds, or an earlier read.
    static func cached(_ clip: Clip, in project: Project) -> Presence {
        guard let a = IsolatedAudio.audioAsset(of: clip, in: project) else { return .unknown }
        switch a.kind {
        case .image: return .none
        case .audio: return .some
        case .video, .sequence: return cache[a.path] ?? .unknown
        }
    }

    /// Reads the file when the kind does not tell.
    static func probe(_ clip: Clip, in project: Project) async -> Presence {
        let known = cached(clip, in: project)
        guard known == .unknown, let a = IsolatedAudio.audioAsset(of: clip, in: project), FileManager.default.fileExists(atPath: a.path) else { return known }
        guard let tracks = try? await AVURLAsset(url: a.url).loadTracks(withMediaType: .audio) else { return .unknown }
        let p: Presence = tracks.isEmpty ? .none : .some
        cache[a.path] = p
        return p
    }
}

/// Which of the clip inspector's cards apply to a clip, from its track and what its file holds. A picture without sound
/// gets no sound cards (volume, EQ, dynamics, gain and pan, loudness, transcript, J/L cut), only its fades; sound alone
/// on an audio track gets no picture transition (its crossfade card is the sound's own).
struct ClipCards: Equatable {
    var picture = false      // transform, color, wheels, curves, look, grade layers, finishing, green screen, blend, face blur
    var sound = false        // audio (volume and fades), EQ and cleanup, compressor … gain and pan, transcript
    var fadesOnly = false    // fades without volume, for a picture with no sound
    var transition = false   // the picture transition in
    var splitEdit = false    // the J/L cut

    init(track: TrackKind, asset: AssetKind?, sound presence: ClipSound.Presence) {
        let hasSound = asset != .image && presence != .none
        picture = track == .video
        sound = hasSound
        fadesOnly = !hasSound && track == .video
        transition = track == .video
        splitEdit = track == .video && asset == .video && hasSound
    }
}

struct ClipInspector: View {
    @ObservedObject var document: EditMaxDocument
    @EnvironmentObject var state: EditorState
    @EnvironmentObject var player: PlayerController
    @ObservedObject private var thumbnails = ThumbnailStore.shared
    @ObservedObject private var isolated = IsolatedAudio.shared
    let clip: Clip
    let track: Track
    @State private var nameDraft = ""
    @State private var transitionNote: String?
    @State private var reframing = false
    @State private var reframeNote: String?
    /// The read of the sound file, with the path it was for (the inspector is reused when another clip is selected).
    @State private var probed: (path: String, presence: ClipSound.Presence)?

    private var soundPath: String { IsolatedAudio.audioAsset(of: clip, in: document.project)?.path ?? "" }
    private var sound: ClipSound.Presence {
        if let probed, probed.path == soundPath { return probed.presence }
        return ClipSound.cached(clip, in: document.project)
    }

    /// Slider drags make one undo step.
    private var x: ToolExecutor { ToolExecutor(document: document, origin: .user, coalesce: true) }
    private var asset: Asset? { document.project.asset(clip.assetID) }

    var body: some View {
        let cards = ClipCards(track: track.kind, asset: asset?.kind, sound: sound)
        RevealScroller { ScrollView {
            VStack(alignment: .leading, spacing: InspectorStyle.gap) {
                headerCard.revealAnchor(.header)
                timingCard.revealAnchor(.timing)
                if let seq = document.project.sequence(of: clip) { sequenceCard(seq) }
                if let mc = clip.multicam { multicamCard(mc).revealAnchor(.multicam) }
                speedCard.revealAnchor(.speed)
                if cards.sound, let asset, asset.kind == .video || asset.kind == .audio { TranscriptSection(document: document, clip: clip) }
                if cards.picture {
                    transformCard.revealAnchor(.transform)
                    colorCard.revealAnchor(.color)
                    ColorWheelsCard(document: document, clip: clip).revealAnchor(.wheels)   // UI/ColorWheelsSection.swift
                    CurvesCard(document: document, clip: clip).revealAnchor(.curves)        // UI/CurvesSection.swift
                    lookCard.revealAnchor(.look)
                    ColorStackSections(document: document, clip: clip)   // shot match, grade layers, finishing (UI/ColorStackSections.swift)
                    ClipEffectsSection(document: document, clip: clip)   // green screen, blend, face blur (EffectsInspector.swift)
                }
                if cards.sound {
                    audioCard.revealAnchor(.audio)
                    eqCard.revealAnchor(.eq)
                    ClipAudioSections(document: document, clip: clip, track: track)
                } else if cards.fadesOnly {
                    fadesCard.revealAnchor(.audio)
                }
                if cards.transition { transitionCard.revealAnchor(.transition) }
                EditingInspectorCards(document: document, clip: clip, track: track, splitEdit: cards.splitEdit)   // split edit, smooth slow motion (EditingInspector.swift)
                Text("Clip \(clip.id.short)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).textSelection(.enabled)
                    .frame(maxWidth: .infinity).padding(.top, 4)
            }
            .padding(12)
        } }
        .onAppear { nameDraft = clip.name }
        .onChange(of: clip.id) { _, _ in nameDraft = clip.name }
        // Reads the sound file once per path; a relink or another selected clip reads again.
        .task(id: soundPath) {
            let path = soundPath
            let p = await ClipSound.probe(clip, in: document.project)
            if path == soundPath { probed = (path, p) }
        }
    }

    /// Thumbnail, name and the actions that apply to the clip as a whole.
    private var headerCard: some View {
        InspectorCard {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(track.kind == .audio ? Color.green.opacity(0.25) : Color.black.opacity(0.35))
                    if let frame = thumbnails.strips[clip.assetID]?.frames.first { Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                    else { Image(systemName: track.kind == .video ? "film" : "waveform").imageScale(.medium).foregroundStyle(.secondary) }
                }
                .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $nameDraft).textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                        .onSubmit { commitName(x) }
                    Text(asset?.name ?? "missing file").inspectorSecondary().lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.vertical, 4)
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
                    .pointer().disabled(player.currentTime <= clip.start + 0.01 || player.currentTime >= clip.end - 0.01).uiFrame("inspector.clip.split")
                Button("Delete", systemImage: "trash", role: .destructive) { state.selectedClipIDs = []; try? x.removeClips([clip.id.uuidString]) }.pointer().uiFrame("inspector.clip.delete")
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var timingCard: some View {
        InspectorCard("Timing") {
            InspectorValueRow("Track", track.name)
            InspectorValueRow("Start", Timecode.string(clip.start))
            InspectorValueRow("End", Timecode.string(clip.end))
            InspectorValueRow("Duration", Timecode.string(clip.duration))
            InspectorValueRow("Source in", Timecode.string(clip.sourceIn))
        }
    }

    private func sequenceCard(_ seq: Sequence) -> some View {
        let n = seq.project.allClips.count
        return InspectorCard("Nested sequence", footer: "Speed, color, fades, transitions and keyframes on this clip apply to the whole group.") {
            InspectorValueRow("Sequence", seq.name)
            InspectorValueRow("Contents", "\(n) clip\(n == 1 ? "" : "s") on \(seq.project.tracks.map(\.name).joined(separator: ", ")), \(Timecode.string(seq.project.duration))")
            let unnest = { _ = try? ToolExecutor(document: document, origin: .user).unnestClip(clip.id.uuidString); state.selectedClipIDs = [] }
            Button("Unnest onto the timeline", systemImage: "square.stack.3d.up") { unnest() }.controlSize(.small).pointer()
                .uiTap("inspector.sequence.unnest") { unnest() }.uiFrame("inspector.sequence.unnest")
        }
    }

    private func multicamCard(_ mc: Multicam) -> some View {
        let plain = ToolExecutor(document: document, origin: .user)
        let active = mc.angle(at: localTime)
        return InspectorCard("Multicam", footer: "Click an angle to cut to it at the playhead. The cut line shows on the clip.") {
            HStack(spacing: 6) {
                ForEach(Array(mc.angles.enumerated()), id: \.offset) { i, aid in
                    Button("\(i + 1)") { _ = try? plain.cutAngle(clip.id.uuidString, at: player.currentTime, angle: i + 1) }
                        .buttonStyle(.bordered).tint(active == i ? Color.accentColor : nil)
                        .help(document.project.asset(aid)?.name ?? "missing").pointer()
                        .uiTap("inspector.angle.\(i + 1)") { _ = try? plain.cutAngle(clip.id.uuidString, at: player.currentTime, angle: i + 1) }
                        .uiFrame("inspector.angle.\(i + 1)")
                }
                Spacer(minLength: 8)
                Text("angle \(active + 1) at playhead").inspectorSecondary().monospacedDigit()
            }
            InspectorRow("Sound from") {
                Picker("Sound from", selection: Binding(get: { mc.audioAngle }, set: { v in _ = try? plain.setMulticam(clip.id.uuidString, audioAngle: v + 1, offsets: nil, flatten: false) })) {
                    ForEach(0..<mc.angles.count, id: \.self) { i in Text("Angle \(i + 1) · \(document.project.asset(mc.angles[i])?.name ?? "")").tag(i) }
                }.labelsHidden().pointer().uiFrame("inspector.multicam.audio")
            }
            ForEach(mc.cuts.map { ("cut-\($0.time)", $0) }, id: \.0) { _, cut in
                HStack {
                    Text("\(Timecode.string(clip.start + cut.time))  →  angle \(cut.angle + 1)").font(.system(size: 13)).monospacedDigit()
                    Spacer()
                    Button { player.pause(); player.seek(to: clip.start + cut.time) } label: { Image(systemName: "arrow.right.to.line").inspectorHitTarget() }.buttonStyle(.borderless).focusable(false).help("Go to cut").pointer().uiFrame("inspector.multicam.cut.\(cut.time).go")
                    Button { _ = try? plain.cutAngle(clip.id.uuidString, at: clip.start + cut.time, angle: 0, remove: true) } label: { Image(systemName: "trash").inspectorHitTarget() }.buttonStyle(.borderless).focusable(false).help("Remove cut").pointer().uiFrame("inspector.multicam.cut.\(cut.time).remove")
                }
            }
            if mc.angles.count > 1 {
                InspectorFootnote("Offsets: " + mc.angles.indices.dropFirst().map { "angle \($0 + 1) \(String(format: "%+.2f", mc.offset($0))) s" }.joined(separator: ", "))
            }
            HStack(spacing: 8) {
                Button("Sync by audio", systemImage: "waveform.badge.magnifyingglass") { Task { @MainActor in _ = try? await plain.syncAngles(clip.id.uuidString) } }.pointer()
                    .uiTap("inspector.multicam.sync") { Task { @MainActor in _ = try? await plain.syncAngles(clip.id.uuidString) } }.uiFrame("inspector.multicam.sync")
                Button("Flatten to clips", systemImage: "rectangle.split.3x1") { _ = try? plain.setMulticam(clip.id.uuidString, audioAngle: nil, offsets: nil, flatten: true) }.pointer()
                    .uiTap("inspector.multicam.flatten") { _ = try? plain.setMulticam(clip.id.uuidString, audioAngle: nil, offsets: nil, flatten: true) }.uiFrame("inspector.multicam.flatten")
                Spacer(minLength: 0)
            }.controlSize(.small)
        }
    }

    private var speedCard: some View {
        InspectorCard("Speed", footer: clip.isAnimated(.speed)
                      ? "Speed ramp: \(clip.keyframes(.speed).count) keyframes, uses \(Timecode.string(clip.sourceOut - clip.sourceIn)) of media. 0× holds a frame."
                      : "Click the diamond to start a speed ramp from the playhead.") {
            slider("Speed", param: .speed, value: clip.speed, range: 0...4, format: { String(format: "%.2f×", $0) }, reset: 1) { try? x.setClipProperties(clip.id.uuidString, speed: $0) }
        }
    }

    private var transformCard: some View {
        let tf = clip.transform
        return InspectorCard("Transform", trailing: {
            if !clip.transform.isIdentity { Button("Reset") { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: true) }.controlSize(.small).pointer().uiFrame("inspector.transform.reset") }
        }) {
            slider("Scale", param: .scale, value: tf.scale, range: 0.1...4, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipTransform(clip.id.uuidString, scale: $0, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
            slider("Position X", param: .x, value: tf.x, range: -1...1, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: $0, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
            slider("Position Y", param: .y, value: tf.y, range: -1...1, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: $0, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
            slider("Rotation", param: .rotation, value: tf.rotation, range: -180...180, format: { "\(Int($0))°" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: $0, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
            slider("Crop left", keyColumn: true, value: tf.cropLeft, range: 0...0.9, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: $0, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
            slider("Crop right", keyColumn: true, value: tf.cropRight, range: 0...0.9, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: $0, cropTop: nil, cropBottom: nil, reset: false) }
            slider("Crop top", keyColumn: true, value: tf.cropTop, range: 0...0.9, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: $0, cropBottom: nil, reset: false) }
            slider("Crop bottom", keyColumn: true, value: tf.cropBottom, range: 0...0.9, format: { "\(Int($0 * 100))%" }, reset: 0) { try? x.setClipTransform(clip.id.uuidString, scale: nil, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: $0, reset: false) }
            slider("Opacity", param: .opacity, value: clip.opacity, range: 0...1, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipProperties(clip.id.uuidString, opacity: $0) }
            if asset?.kind == .video {
                // Auto-reframe: cover the frame and keyframe the position so the subject stays in view (Vision person / saliency).
                let reframe = { Task { @MainActor in
                    guard !reframing else { return }
                    reframing = true; reframeNote = "Analyzing…"
                    defer { reframing = false }
                    do {
                        let r = try await ToolExecutor(document: document, origin: .user).autoReframe(clip.id.uuidString)
                        reframeNote = "\(r.mode): \(r.keyframesX + r.keyframesY) keyframes, scale \(Int((r.scale * 100).rounded()))%" + (r.note.map { " — \($0)" } ?? "")
                    } catch { reframeNote = InspectorMessage.text(error) }
                } }
                HStack(spacing: 8) {
                    Button("Auto-reframe", systemImage: "person.crop.rectangle.badge.plus") { _ = reframe() }
                        .controlSize(.small).pointer().disabled(reframing).uiTap("inspector.autoReframe") { _ = reframe() }.uiFrame("inspector.autoReframe")
                    if reframing { ProgressView().controlSize(.mini) }
                    if let reframeNote { Text(reframeNote).inspectorSecondary().lineLimit(2) }
                    Spacer(minLength: 0)
                }
            }
            if asset?.kind == .video { StabilizeRow(document: document, clip: clip) }
        }
    }

    private var colorCard: some View {
        let c = clip.color
        return InspectorCard("Color", trailing: {
            if !clip.color.isIdentity { Button("Reset") { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: true) }.controlSize(.small).pointer().uiFrame("inspector.color.reset") }
        }) {
            slider("Exposure", param: .exposure, value: c.exposure, range: -2...2, format: { String(format: "%+.1f", $0) }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: $0, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false) }
            slider("Contrast", param: .contrast, value: c.contrast, range: 0.5...2, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: $0, saturation: nil, temperature: nil, tint: nil, reset: false) }
            slider("Saturation", param: .saturation, value: c.saturation, range: 0...2, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: $0, temperature: nil, tint: nil, reset: false) }
            slider("Temperature", param: .temperature, value: c.temperature, range: -100...100, format: { "\(Int($0))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: $0, tint: nil, reset: false) }
            slider("Tint", param: .tint, value: c.tint, range: -100...100, format: { "\(Int($0))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: $0, reset: false) }
            slider("Shadows", param: .shadows, value: c.shadows, range: -1...1, format: { "\(Int($0 * 100))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, shadows: $0) }
            slider("Midtones", param: .midtones, value: c.midtones, range: -1...1, format: { "\(Int($0 * 100))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, midtones: $0) }
            slider("Highlights", param: .highlights, value: c.highlights, range: -1...1, format: { "\(Int($0 * 100))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, highlights: $0) }
            slider("Vibrance", param: .vibrance, value: c.vibrance, range: -1...1, format: { "\(Int($0 * 100))" }, reset: 0) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, vibrance: $0) }
        }
    }

    private var lookCard: some View {
        let c = clip.color
        let plain = ToolExecutor(document: document, origin: .user)
        return InspectorCard("Look", footer: "The input LUT runs first, at full strength: it turns log footage (DJI D-Log, S-Log, V-Log) into a normal Rec.709 image, so the color controls behave as expected. A look is a 3D LUT applied after them. Built-in looks are generated; .cube files from any grading app load as they are.") {
            InspectorRow("Input LUT") {
                Picker("Input LUT", selection: Binding(get: { c.inputLut ?? "none" }, set: { v in
                    if v == "file" { pickCube(plain, input: true) } else { try? plain.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, inputLut: v) }
                })) {
                    Text("None (footage is already Rec.709)").tag("none")
                    if let path = c.inputLut { Text(URL(fileURLWithPath: path).lastPathComponent).tag(path) }
                    Divider()
                    Text("Load conversion .cube (D-Log → Rec.709…)…").tag("file")
                }.labelsHidden().pointer().uiFrame("inspector.inputLut")
            }
            InspectorRow("Look") {
                Picker("Look", selection: Binding(get: { c.lut ?? "none" }, set: { v in
                    if v == "file" { pickCube(plain) } else { try? plain.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, lut: v) }
                })) {
                    Text("None").tag("none")
                    ForEach(Looks.builtin, id: \.self) { Text($0).tag($0) }
                    if let path = c.lut, !Looks.isBuiltin(path) { Text(URL(fileURLWithPath: path).lastPathComponent).tag(path) }
                    Divider()
                    Text("Load .cube file…").tag("file")
                }.labelsHidden().pointer().uiFrame("inspector.look")
            }
            if c.lut != nil {
                slider("Mix", param: .lutMix, value: c.lutMix, range: 0...1, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipColor(clip.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false, lutMix: $0) }
            }
        }
    }

    private var audioCard: some View {
        InspectorCard("Audio", footer: track.kind == .video ? "Fades take the picture to black and the sound to silence." : nil) {
            slider("Volume", param: .volume, value: clip.volume, range: 0...2, format: { "\(Int($0 * 100))%" }, reset: 1) { try? x.setClipProperties(clip.id.uuidString, volume: $0) }
            slider("Fade in", keyColumn: true, value: clip.fadeIn, range: 0...min(5, clip.duration), format: { String(format: "%.1f s", $0) }, reset: 0) { try? x.setClipFades(clip.id.uuidString, fadeIn: $0, fadeOut: nil) }
            slider("Fade out", keyColumn: true, value: clip.fadeOut, range: 0...min(5, clip.duration), format: { String(format: "%.1f s", $0) }, reset: 0) { try? x.setClipFades(clip.id.uuidString, fadeIn: nil, fadeOut: $0) }
        }
    }

    /// A picture with no sound: its fades still take it to black, and the line under them says why the sound cards are gone.
    private var fadesCard: some View {
        let why = asset?.kind == .image ? "A still image has no sound." : "\(asset?.name ?? "This file") has no sound, so there are no sound settings."
        return InspectorCard("Fades", footer: "Fades take the picture to black. " + why) {
            slider("Fade in", value: clip.fadeIn, range: 0...min(5, clip.duration), format: { String(format: "%.1f s", $0) }, reset: 0) { try? x.setClipFades(clip.id.uuidString, fadeIn: $0, fadeOut: nil) }
            slider("Fade out", value: clip.fadeOut, range: 0...min(5, clip.duration), format: { String(format: "%.1f s", $0) }, reset: 0) { try? x.setClipFades(clip.id.uuidString, fadeIn: nil, fadeOut: $0) }
        }
    }

    private var eqCard: some View {
        let au = clip.audio
        return InspectorCard("EQ & cleanup", footer: isolated.caption(for: IsolatedAudio.audioAsset(of: clip, in: document.project), amount: au.voiceIsolation), trailing: {
            if clip.audio.hasCleanup || clip.audio.needsIsolation { Button("Reset") { try? x.setClipAudio(clip.id.uuidString, low: nil, mid: nil, high: nil, highPass: nil, gate: nil, reset: true) }.controlSize(.small).pointer().uiFrame("inspector.audio.reset") }
        }) {
            slider("Low", value: au.lowGain, range: -18...18, format: { String(format: "%+.0f dB", $0) }, reset: 0) { try? x.setClipAudio(clip.id.uuidString, low: $0, mid: nil, high: nil, highPass: nil, gate: nil, reset: false) }
            slider("Mid", value: au.midGain, range: -18...18, format: { String(format: "%+.0f dB", $0) }, reset: 0) { try? x.setClipAudio(clip.id.uuidString, low: nil, mid: $0, high: nil, highPass: nil, gate: nil, reset: false) }
            slider("High", value: au.highGain, range: -18...18, format: { String(format: "%+.0f dB", $0) }, reset: 0) { try? x.setClipAudio(clip.id.uuidString, low: nil, mid: nil, high: $0, highPass: nil, gate: nil, reset: false) }
            slider("High-pass", value: au.highPass, range: 0...400, format: { $0 <= 0 ? "off" : "\(Int($0)) Hz" }, reset: 0) { try? x.setClipAudio(clip.id.uuidString, low: nil, mid: nil, high: nil, highPass: $0 < 20 ? 0 : $0, gate: nil, reset: false) }
            slider("Noise gate", value: Self.gateSlider(au.gate), range: Self.gateOff...(-1), format: Self.gateText, reset: Self.gateOff) { try? x.setClipAudio(clip.id.uuidString, low: nil, mid: nil, high: nil, highPass: nil, gate: Self.gateValue(fromSlider: $0), reset: false) }
            InspectorFootnote("EQ shelves at 200 Hz and 6 kHz, a 1 kHz peak. A high-pass around 80–120 Hz removes rumble; the gate drops 26 dB below its threshold.")
            slider("Voice isolation", value: au.voiceIsolation, range: 0...1, format: { $0 < 0.005 ? "off" : "\(Int(($0 * 100).rounded()))%" }, reset: 0) { try? x.setClipAudio(clip.id.uuidString, low: nil, mid: nil, high: nil, highPass: nil, gate: nil, voiceIsolation: $0, reset: false) }
        }
    }

    private var transitionCard: some View {
        InspectorCard("Transition in", footer: transitionNote ?? (document.project.clipBefore(clip, on: track) == nil ? "No clip ends where this one starts, so a transition would come from black." : "Plays over the end of \(document.project.clipBefore(clip, on: track)!.name), which needs that much media past its out point.")) {
            InspectorRow("Kind") {
                Picker("Kind", selection: Binding(get: { clip.transitionIn?.kind.rawValue ?? "none" }, set: { v in _ = try? ToolExecutor(document: document, origin: .user).setTransition(clip.id.uuidString, kind: v, duration: nil); transitionNote = nil })) {
                    Text("None").tag("none")
                    ForEach(Transition.Kind.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().pointer().uiFrame("inspector.transition.kind")
            }
            if let tr = clip.transitionIn {
                slider("Duration", value: tr.duration, range: 0.1...min(3, clip.duration), format: { String(format: "%.2f s", $0) }, reset: 0.5) { d in
                    transitionNote = (try? x.setTransition(clip.id.uuidString, kind: nil, duration: d))?.note
                }
            }
        }
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
        catch {
            let alert = NSAlert(); alert.messageText = "Could not load the LUT"; alert.informativeText = InspectorMessage.text(error); alert.runModal()
        }
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
    /// `keyColumn` keeps the diamond's room on a row without one, so its slider lines up with the keyframed rows of the
    /// same card (the crops under Position and Rotation, the fades under Volume).
    private func slider(_ title: String, param: ClipParam? = nil, keyColumn: Bool = false, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String, reset: Double, set: @escaping (Double) -> Void) -> some View {
        let x = ToolExecutor(document: document, origin: .user, coalesce: true)
        let animated = param.map(clip.isAnimated) ?? false
        let shown = (param != nil && animated) ? clip.value(param!, at: localTime) : value
        let apply: (Double) -> Void = { v in
            if let param, animated { _ = try? x.setKeyframe(clip.id.uuidString, param: param.rawValue, time: player.currentTime, value: v, ease: nil) } else { set(v) }
        }
        // Stable driver id: the parameter name, or the title in lowerCamel ("Crop left" → cropLeft) for plain values.
        let key = param?.rawValue ?? title.split(separator: " ").enumerated().map { $0.offset == 0 ? $0.element.lowercased() : $0.element.capitalized }.joined()
        return HStack(spacing: 8) {
            Text(title).inspectorLabel()
            if let param {
                let onKey = hasKeyframe(param)
                Button {
                    let plain = ToolExecutor(document: document, origin: .user)
                    if onKey { _ = try? plain.removeKeyframe(clip.id.uuidString, param: param.rawValue, time: player.currentTime, all: false) }
                    else { _ = try? plain.setKeyframe(clip.id.uuidString, param: param.rawValue, time: player.currentTime, value: shown, ease: nil) }
                } label: {
                    Image(systemName: onKey ? "diamond.fill" : "diamond").font(.system(size: 10)).foregroundStyle(animated ? Color.accentColor : Color.secondary)
                        .frame(width: Self.keyColumnWidth, height: Self.keyColumnWidth).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).focusable(false).pointer().uiFrame("inspector.key.\(param.rawValue)")
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
            } else if keyColumn {
                Color.clear.frame(width: Self.keyColumnWidth, height: 1)
            }
            InspectorSlider(value: shown, range: range, neutral: InspectorSlider.neutral(range: range, reset: reset), set: apply)
                .controlSize(.small).pointer().uiFrame("inspector.\(key).slider")
            Text(format(shown)).inspectorValue()
                .onTapGesture(count: 2) { apply(reset) }.help("Double-click to reset").pointer()
                .uiFrame("inspector.\(key).reset").uiTap("inspector.\(key).reset", count: 2) { apply(reset) }
        }
    }

    /// The keyframe diamond's square: a click target, and the room a row without one keeps when it lines up with one.
    static let keyColumnWidth: CGFloat = 20

    /// The noise gate's slider runs from Off at the left end, like the high-pass and voice isolation beside it, to a
    /// −1 dB threshold at the right (more gating). The project stores 0 for off and a −90…−1 dB threshold otherwise.
    static let gateOff = -91.0
    static func gateSlider(_ gate: Double) -> Double { gate >= 0 ? gateOff : max(gateOff + 1, min(-1, gate)) }
    static func gateValue(fromSlider v: Double) -> Double { v < gateOff + 0.5 ? 0 : min(-1, v.rounded()) }
    static func gateText(_ v: Double) -> String { v < gateOff + 0.5 ? "off" : "\(Int(v.rounded())) dB" }

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
    @ObservedObject private var fonts = FontLibrary.shared   // a font arriving or going redraws the Font rows

    var body: some View {
        RevealScroller { ScrollView {
            VStack(alignment: .leading, spacing: InspectorStyle.gap) {
                InspectorCard(text.isCaption ? "Caption" : "Title", footer: text.isCaption ? "Part of caption group \(text.group!.short). Style changes apply to this line only." : nil) {
                    TextField("Text", text: $draft, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
                        .onSubmit { commitText() }
                    // Font, its weights, and a warning when the chosen font is not on this Mac (FontBrowser.swift).
                    TextFontRow(document: document, text: text)
                    let faces = text.fontIsMissing ? [] : text.fontFamily.map { TextFont.faces(family: $0) } ?? []
                    if faces.count > 1 { TextFaceRow(document: document, text: text, faces: faces) }
                    let status = fonts.status(of: text)
                    if status != .ok { TextFontStatusRow(status: status) }
                    HStack(spacing: 8) {
                        Button("Apply text") { commitText() }.pointer().disabled(draft == text.text).uiFrame("inspector.text.apply")
                        Button("Show", systemImage: "eye") { player.pause(); player.seek(to: Self.showTime(for: text, fps: document.project.settings.fps)) }
                            .help("Move the playhead to where this text is fully on screen").pointer().uiFrame("inspector.text.show")
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            state.selectedTextID = nil
                            document.apply("Delete text", origin: .user) { p in p.texts.removeAll { $0.id == text.id } }
                        }.pointer().uiFrame("inspector.text.delete")
                        Spacer()
                    }
                    .controlSize(.small)
                }.revealAnchor(.title)
                InspectorCard("Look") {
                    InspectorRow("Style") {
                        Picker("Style", selection: Binding(get: { text.preset ?? "title" }, set: { v in
                            document.apply("Text style", origin: .user) { p in if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i].preset = v } }
                        })) { ForEach(CaptionPresets.all, id: \.name) { Text($0.title).tag($0.name) } }.labelsHidden().pointer().uiFrame("inspector.text.style")
                    }
                    HStack(spacing: 8) {
                        Text("Size").inspectorLabel()
                        Slider(value: binding(\.fontSize, "Text size"), in: 12...300).controlSize(.small).pointer().uiFrame("inspector.text.size")
                        Text("\(Int(text.fontSize)) pt").inspectorValue()
                    }
                    InspectorRow("Color") {
                        ColorPicker("Color", selection: Binding(get: { Color(hex: text.colorHex) }, set: { c in
                            let hex = c.hexString
                            guard hex != text.colorHex else { return }
                            document.apply("Text color", origin: .user, coalesce: true) { p in if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i].colorHex = hex } }   // a drag in the wheel is one undo step
                        }), supportsOpacity: false).labelsHidden().pointer().uiFrame("inspector.text.color")
                    }
                }
                TextEffectsSection(document: document, text: text)   // animation, lower third (EffectsInspector.swift)
                InspectorCard("Position", footer: "0% is the top-left of the frame, 100% the bottom-right. Drag the bar on the timeline to move it in time, its edges to change the length.") {
                    HStack(spacing: 8) {
                        Text("Horizontal").inspectorLabel()
                        Slider(value: binding(\.x, "Text horizontal"), in: 0...1).controlSize(.small).pointer().uiFrame("inspector.text.x")
                        Text("\(Int(text.x * 100))%").inspectorValue()
                    }
                    HStack(spacing: 8) {
                        Text("Vertical").inspectorLabel()
                        Slider(value: binding(\.y, "Text vertical"), in: 0...1).controlSize(.small).pointer().uiFrame("inspector.text.y")
                        Text("\(Int(text.y * 100))%").inspectorValue()
                    }
                    // Two texts on screen together must not cover each other: name the other one and offer the fix.
                    let blockers = TextLayout.blockers(of: text, among: document.project.texts, canvas: document.project.settings.canvas)
                    if let other = blockers.first {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Covers \u{201C}\(other.text.prefix(24))\u{201D} \(Timecode.string(max(text.start, other.start)))–\(Timecode.string(min(text.end, other.end)))")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            Spacer()
                            Button("Move clear") {
                                if let y = TextLayout.clearY(for: text, among: document.project.texts, canvas: document.project.settings.canvas) {
                                    document.apply("Move text clear", origin: .user) { p in if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i].y = y } }
                                }
                            }.controlSize(.small).pointer().uiFrame("inspector.text.moveClear")
                                .disabled(TextLayout.clearY(for: text, among: document.project.texts, canvas: document.project.settings.canvas) == nil)
                        }
                    }
                }
                InspectorCard("Timing") {
                    InspectorValueRow("Start", Timecode.string(text.start))
                    InspectorValueRow("End", Timecode.string(text.end))
                    InspectorValueRow("Duration", Timecode.string(text.duration))
                }
            }
            .padding(12)
        } }
        .onAppear { draft = text.text }
        .onChange(of: text.id) { _, _ in draft = text.text }
    }

    /// Where Show parks the playhead: the first frame after the in animation has finished (a typewriter title has every
    /// letter, a pop has settled), before the out animation starts. The picture shown at a time is the frame that starts
    /// at or before it, so one frame of margin (at least 0.05 s) keeps that frame past the animation. When the in and
    /// out animations overlap (a short title), the moment where both are furthest along; always inside the title.
    static func showTime(for text: TextOverlay, fps: Double) -> Double {
        let a = text.animation ?? TextAnimation()
        let inLen = a.inKind == .none ? 0 : max(0.01, a.inDuration)     // the lengths TitleAnimator.phases uses
        let outLen = a.outKind == .none ? 0 : max(0.01, a.outDuration)
        let margin = max(0.05, 1 / max(1, fps))
        let first = text.start + inLen, last = text.end - outLen    // fully on screen between these
        let t: Double
        if first + margin <= last { t = first + margin }
        else if first <= last { t = (first + last) / 2 }
        else { t = (text.start * outLen + text.end * inLen) / (inLen + outLen) }   // in and out progress equal
        return min(max(t, text.start), max(text.start, text.end - 0.001))
    }

    private func commitText() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != text.text else { return }
        document.apply("Edit text", origin: .user) { p in if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i].text = t } }
    }

    /// A slider binding: the drag coalesces into one undo step under `label` (one label per field, so drags stay apart).
    private func binding<T: Equatable>(_ kp: WritableKeyPath<TextOverlay, T>, _ label: String) -> Binding<T> {
        .init(get: { text[keyPath: kp] }, set: { v in
            guard v != text[keyPath: kp] else { return }
            document.apply(label, origin: .user, coalesce: true) { p in if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i][keyPath: kp] = v } }
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
            } catch { cleanupStatus = InspectorMessage.text(error) }
        }
    }

    private func addCaptions() {
        captionBusy = true; captionStatus = "Transcribing…"
        Task { @MainActor in
            defer { captionBusy = false }
            do {
                let r = try await ToolExecutor(document: document, origin: .user).addCaptions(clip: nil, preset: captionPreset, maxWords: nil, language: nil)
                captionStatus = "Added \(r.count) captions to \(r.clips) clip\(r.clips == 1 ? "" : "s")."
            } catch { captionStatus = InspectorMessage.text(error) }
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

    private var p: Project { document.project }
    private var x: ToolExecutor { ToolExecutor(document: document, origin: .user) }

    var body: some View {
        RevealScroller { ScrollView {
            VStack(alignment: .leading, spacing: InspectorStyle.gap) {
                projectCard.revealAnchor(.project)
                proxiesCard
                templatesCard
                addTextCard
                if !p.markers.isEmpty || state.inPoint != nil || state.outPoint != nil { markersCard.revealAnchor(.markers) }
                if p.tracks.count > 1 { duckingCard.revealAnchor(.ducking) }
                cleanupCard
                captionsCard
                InspectorFootnote("Click a clip or a text bar on the timeline to edit it. The Agents tab connects Claude Code, Codex or Cursor; the Chat tab talks to them here.").padding(.horizontal, 4)
            }
            .padding(12)
        } }
    }

    private var projectCard: some View {
        InspectorCard("Project") {
            InspectorValueRow("Resolution", "\(p.settings.width)×\(p.settings.height)")
            InspectorValueRow("Frame rate", "\(Int(p.settings.fps)) fps")
            InspectorValueRow("Duration", Timecode.string(p.duration))
            ProjectColorRow(document: document)   // SDR / HDR (EffectsInspector.swift)
            InspectorValueRow("Clips", "\(p.allClips.count)")
            InspectorValueRow("Project ID", document.id.short)
        }
    }

    private var proxiesCard: some View {
        let videos = p.assets.filter { $0.kind == .video }
        let ready = videos.filter { proxies.ready(for: $0) != nil }.count
        let building = videos.filter { if case .building = proxies.status[$0.id] { return true }; return false }
        return InspectorCard("Proxies", footer: "960×540 copies for smooth playback. The export always uses the original files.") {
            InspectorRow("Preview from proxies") {
                Toggle("Preview from proxies", isOn: Binding(get: { p.settings.useProxies }, set: { v in try? x.setProjectSettings(width: nil, height: nil, fps: nil, name: nil, useProxies: v) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).pointer().uiFrame("inspector.proxies")
            }
            HStack(spacing: 8) {
                Button("Make proxies", systemImage: "arrow.down.right.and.arrow.up.left") { _ = x.makeProxies(enable: true) }.controlSize(.small).pointer().disabled(videos.isEmpty || ready == videos.count).uiFrame("inspector.makeProxies")
                Spacer(minLength: 8)
                Text(videos.isEmpty ? "No video files yet." : building.isEmpty ? "\(ready) of \(videos.count) ready" : "Building \(building.count)…").inspectorSecondary().monospacedDigit()
            }
        }
    }

    private var templatesCard: some View {
        let all = Templates.list()
        return InspectorCard("Templates", footer: templateStatus ?? "Built-in templates set the format on an empty timeline; a saved template restores its tracks, clips and titles.") {
            HStack(spacing: 8) {
                Picker("Template", selection: $templateChoice) {
                    Text("Choose…").tag("")
                    ForEach(all) { t in Text(t.builtin ? "\(t.name)  (\(t.width)×\(t.height))" : t.name).tag(t.name) }
                }.labelsHidden().pointer().uiFrame("inspector.template")
                Spacer(minLength: 0)
                Button("Apply") {
                    do { let t = try x.applyTemplate(templateChoice); templateStatus = "Applied \(t.name). Undo with ⌘Z." } catch { templateStatus = InspectorMessage.text(error) }
                }.controlSize(.small).pointer().disabled(templateChoice.isEmpty).uiFrame("inspector.template.apply")
            }
            HStack(spacing: 8) {
                TextField("Save this project as a template", text: $templateName).textFieldStyle(.roundedBorder).controlSize(.small)
                Button("Save") {
                    do { _ = try x.saveTemplate(templateName); templateStatus = "Saved template '\(templateName)'."; templateName = "" } catch { templateStatus = InspectorMessage.text(error) }
                }.controlSize(.small).pointer().disabled(templateName.trimmingCharacters(in: .whitespaces).isEmpty).uiFrame("inspector.template.save")
            }
        }
    }

    private var addTextCard: some View {
        InspectorCard("Add text", footer: "Starts at \(Timecode.string(player.currentTime)), 3 s long. Drag the bar to adjust.") {
            TextField("Title text", text: $newText, prompt: Text("Type a title and press Return")).textFieldStyle(.roundedBorder).onSubmit { addTitle() }
            HStack(spacing: 8) {
                Button("Add at playhead", systemImage: "plus") { addTitle() }.controlSize(.small).pointer().disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty).uiFrame("inspector.addTitle")
                Spacer(minLength: 0)
            }
        }
    }

    private var markersCard: some View {
        InspectorCard("Markers") {
            if let i = state.inPoint, let o = state.outPoint {
                HStack(spacing: 8) {
                    Text("In \(Timecode.string(i)) → Out \(Timecode.string(o))").font(.system(size: 13)).monospacedDigit()
                    Spacer(minLength: 8)
                    Button("Delete range") { EditorActions(document: document, state: state, player: player).deleteRange() }.controlSize(.small).pointer().uiFrame("inspector.markers.deleteRange")
                    Button("Clear") { state.inPoint = nil; state.outPoint = nil }.controlSize(.small).pointer().uiFrame("inspector.markers.clear")
                }
            }
            ForEach(p.markers) { m in
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: m.colorHex)).frame(width: 8, height: 8)
                    MarkerNameField(marker: m, document: document)
                    Text(Timecode.string(m.time)).inspectorSecondary().monospacedDigit()
                    Button { player.pause(); player.seek(to: m.time) } label: { Image(systemName: "arrow.right.to.line").inspectorHitTarget() }.buttonStyle(.borderless).focusable(false).help("Go to marker").pointer().uiFrame("inspector.marker.\(m.id.short).go")
                    Button { document.apply("Remove marker", origin: .user) { p in p.markers.removeAll { $0.id == m.id } } } label: { Image(systemName: "trash").inspectorHitTarget() }.buttonStyle(.borderless).focusable(false).help("Remove marker").pointer().uiFrame("inspector.marker.\(m.id.short).remove")
                }
            }
            Button("Copy YouTube chapters", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Chapters.youtubeText(p), forType: .string) }
                .controlSize(.small).help("The markers as \"mm:ss Name\" lines for a YouTube description (File > Export Chapters… saves them as a file)").pointer().disabled(p.markers.isEmpty).uiFrame("markers.copyChapters")
        }
    }

    private var duckingCard: some View {
        let plain = ToolExecutor(document: document, origin: .user)
        return InspectorCard("Ducking", footer: "A ducked track drops to the level while clips play on the other track.") {
            ForEach(p.tracks) { t in
                HStack(spacing: 8) {
                    Text(t.name).font(.system(size: 13)).lineLimit(1).frame(width: 48, alignment: .leading)
                    Picker("under", selection: Binding(get: { t.duck?.sourceTrackID.uuidString ?? "none" }, set: { v in _ = try? plain.setDucking(t.id.uuidString, under: v == "none" ? "none" : v, level: nil, attack: nil, release: nil) })) {
                        Text("Not ducked").tag("none")
                        ForEach(p.tracks.filter { $0.id != t.id }) { o in Text("Under \(o.name)").tag(o.id.uuidString) }
                    }.labelsHidden().pointer().uiFrame("inspector.duck.\(t.name)")
                    Spacer(minLength: 0)
                    if let d = t.duck {
                        Slider(value: Binding(get: { d.level }, set: { v in _ = try? ToolExecutor(document: document, origin: .user, coalesce: true).setDucking(t.id.uuidString, under: nil, level: v, attack: nil, release: nil) }), in: 0...1).controlSize(.small).frame(width: 70).pointer().uiFrame("inspector.duck.\(t.name).level")
                        Text("\(Int(d.level * 100))%").inspectorSecondary().monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var cleanupCard: some View {
        InspectorCard("Cleanup", footer: cleanupStatus ?? cleanupHint) {
            HStack(spacing: 8) {
                Button(cleanupBusy ? "Working…" : "Remove silence") { cleanup(.silence) }.controlSize(.small).pointer().disabled(cleanupBusy || p.allClips.isEmpty).uiFrame("inspector.removeSilence")
                Button("Remove filler words") { cleanup(.fillers) }.controlSize(.small).pointer().disabled(cleanupBusy || p.allClips.isEmpty).uiFrame("inspector.removeFillers")
                Spacer(minLength: 0)
            }
        }
    }

    private var captionsCard: some View {
        let captionCount = p.texts.filter(\.isCaption).count
        return InspectorCard("Captions", footer: captionStatus ?? Transcriber.privacyNote) {
            InspectorRow("Style") {
                Picker("Style", selection: $captionPreset) { ForEach(CaptionPresets.all, id: \.name) { Text($0.title).tag($0.name) } }.labelsHidden().pointer().uiFrame("inspector.captions.style")
            }
            HStack(spacing: 8) {
                Button(captionBusy ? "Transcribing…" : "Add captions") { addCaptions() }.controlSize(.small).pointer().disabled(captionBusy || p.allClips.isEmpty).uiFrame("inspector.addCaptions")
                if captionCount > 0 {
                    Button("Remove \(captionCount)") { captionStatus = nil; _ = try? ToolExecutor(document: document, origin: .user).removeCaptions(group: nil) }.controlSize(.small).pointer().uiFrame("inspector.removeCaptions")
                }
                Spacer(minLength: 0)
            }
        }
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

/// The Stabilize row of a video clip's transform section: runs the shake analysis for the clip (see `Stabilizer`),
/// shows its progress, then what it found; "Remove" clears it. One analysis at a time; switching clips cancels it.
private struct StabilizeRow: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    @State private var progress: Double?          // nil = idle
    @State private var task: Task<Void, Never>?
    @State private var note: String?

    var body: some View {
        let busy = progress != nil
        HStack(spacing: 8) {
            Button(clip.stabilization == nil ? "Stabilize" : "Re-analyze", systemImage: "camera.metering.center.weighted") { start() }
                .controlSize(.small).focusable(false).pointer().disabled(busy)
                .uiTap("inspector.stabilize") { start() }.uiFrame("inspector.stabilize")
                .help("Smooth camera shake: analyze the clip's motion and counter-shift the picture, zooming in a little to hide the borders")
            if clip.stabilization != nil {
                Button("Remove") { remove() }.controlSize(.small).focusable(false).pointer().disabled(busy)
                    .uiTap("inspector.stabilize.remove") { remove() }.uiFrame("inspector.stabilize.remove")
            }
            if busy { ProgressView().controlSize(.mini) }
            Spacer(minLength: 8)
            Text(status).inspectorSecondary().monospacedDigit().lineLimit(1).truncationMode(.tail)
        }
        .onChange(of: clip.id) { _, _ in cancel() }   // not onDisappear: a lazy container may tear the row down on scroll
    }

    private var status: String {
        if let progress { return "Analyzing… \(Int((progress * 100).rounded())) %" }
        if let note { return note }
        if let s = document.project.hydrated(clip).stabilization { return "\(s.samples.count) samples · zoom \(Int((s.zoom * 100).rounded())) % · \(Stabilizer.cropPercent(s.zoom)) % crop · \(ProjectDiff.fmt(s.strength)) s" }
        return "Not stabilized"
    }

    private func start() {
        guard progress == nil else { return }
        progress = 0; note = nil
        let id = clip.id.uuidString, strength = clip.stabilization?.strength
        task = Task { @MainActor in
            do {
                let r = try await ToolExecutor(document: document, origin: .user).stabilizeClip(id, strength: strength) { p in
                    Task { @MainActor in if progress != nil { progress = p } }
                }
                note = r.note.map { "Done; \($0)" }
            } catch is CancellationError {
            } catch { note = InspectorMessage.text(error) }
            progress = nil
        }
    }
    private func remove() {
        guard progress == nil else { return }
        note = nil
        Task { @MainActor in _ = try? await ToolExecutor(document: document, origin: .user).stabilizeClip(clip.id.uuidString, strength: nil, remove: true) }
    }
    private func cancel() { task?.cancel(); task = nil; progress = nil }
}

/// A marker's name, renamed when the user presses Return or leaves the field (as Finder renames a file), not on every
/// keystroke. Live renaming wrote the field's old text back after ⌘Z (a focused field does not show the undone name),
/// which recorded a new rename and threw away redo; clicking into the field also recorded an empty rename.
private struct MarkerNameField: View {
    let marker: Marker
    let document: EditMaxDocument
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain).font(.system(size: 13))
            .focused($focused)
            .onAppear { draft = marker.name }
            // Undo, redo or the agent renamed it: the field follows the project, so leaving it changes nothing.
            .onChange(of: marker.name) { _, name in draft = name }
            .onSubmit(commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
            .uiFrame("inspector.marker.\(marker.id.short).name")
    }

    private func commit() {
        let id = marker.id, name = draft
        guard name != marker.name else { return }
        document.apply("Rename marker", origin: .user) { p in if let i = p.markers.firstIndex(where: { $0.id == id }) { p.markers[i].name = name } }
    }
}
