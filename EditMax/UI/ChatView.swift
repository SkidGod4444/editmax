import SwiftUI
import AppKit

struct ChatView: View {
    @ObservedObject var chat: ChatSession
    @State private var keyDraft = ""
    @State private var editingKey = false
    /// The composer field's current height: a capsule while it is one line, a rounded rectangle once it wraps.
    @State private var fieldHeight: CGFloat = 0

    /// The example requests in the empty state; a tap puts one in the input.
    private static let suggestions = ["cut the first 2 seconds", "add a title that says Welcome at 0:01", "speed up the second clip"]
    /// The transcript and the composer share one reading column, so the focus-mode (wide) chat does not run edge to edge.
    private static let columnWidth: CGFloat = 760

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if chat.backend == .agent, hasAgentProblem {
                agentProblem.padding(12); Divider()
            } else if chat.backend == .apiKey, chat.apiProblem != nil || editingKey { keyEntry.padding(12); Divider() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chat.items) { item in ItemView(item: item).id(item.id) }
                        if chat.isRunning {
                            HStack(spacing: 8) {
                                PulseDot()
                                Text("\(workerName) is working…").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4).id("working")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: Self.columnWidth)
                    .frame(maxWidth: .infinity)
                }
                .overlay { if chat.items.isEmpty { emptyState } }
                // The input bar floats over the transcript: the list scrolls under it and scroll-to-end stops above it.
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .onChange(of: chat.items.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: chat.items.last?.text.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: chat.isRunning) { _, _ in scrollToEnd(proxy) }
            }
        }
        .animation(.snappy, value: chat.isRunning)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if chat.isRunning { proxy.scrollTo("working", anchor: .bottom) }
        else if let last = chat.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private var workerName: String { chat.backend == .agent ? (chat.selectedAgent?.name ?? "The agent") : (chat.selectedProvider?.name ?? "The model") }

    // MARK: Header: one 28 pt row (backend, agent or provider, refresh, running dot … key, trash) and a status caption under it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $chat.backend) { ForEach(ChatSession.Backend.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(maxWidth: 130).pointer().uiFrame("chat.backend")
                    .onChange(of: chat.backend) { old, new in chat.switchBackend(from: old, to: new) }
                if chat.backend == .agent {
                    Picker("", selection: $chat.agent) {
                        ForEach(chat.agents) { a in
                            HStack(spacing: 6) {
                                Image(systemName: a.installed ? "circle.fill" : "circle").foregroundStyle(a.installed ? .green : .secondary)
                                Text(a.installed ? a.name : "\(a.name) (not installed)")
                            }.tag(a.id)
                        }
                        if chat.agents.isEmpty { Text(chat.agent).tag(chat.agent) }
                    }
                    .labelsHidden().controlSize(.small).frame(maxWidth: 200).pointer().disabled(chat.isRunning).uiFrame("chat.agent")
                    Button { chat.refreshAgents() } label: { Image(systemName: "arrow.clockwise").imageScale(.medium) }
                        .buttonStyle(.borderless).focusable(false).controlSize(.small).help("Look for installed agents again").pointer().disabled(chat.isRunning).uiFrame("chat.refreshAgents")
                } else {
                    Picker("", selection: $chat.provider) {
                        ForEach(chat.providers) { p in
                            HStack(spacing: 6) {
                                Image(systemName: providerReady(p) ? "circle.fill" : "circle").foregroundStyle(providerReady(p) ? .green : .secondary)
                                Text(p.name)
                            }.tag(p.id)
                        }
                        if chat.providers.isEmpty { Text(chat.provider).tag(chat.provider) }
                    }
                    .labelsHidden().controlSize(.small).frame(maxWidth: 170).pointer().disabled(chat.isRunning).uiFrame("chat.provider")
                    Button { chat.refreshProviders() } label: { Image(systemName: "arrow.clockwise").imageScale(.medium) }
                        .buttonStyle(.borderless).focusable(false).controlSize(.small).help("Check keys and Claude Code again").pointer().disabled(chat.isRunning).uiFrame("chat.refreshProviders")
                }
                if chat.isRunning { PulseDot().transition(.opacity) }
                Spacer(minLength: 4)
                if chat.backend == .apiKey {
                    Button { editingKey.toggle() } label: { Image(systemName: "key").imageScale(.medium) }
                        .buttonStyle(.borderless).focusable(false).help("API keys").pointer().uiFrame("chat.keys")
                }
                Button { chat.clear() } label: { Image(systemName: "trash").imageScale(.medium) }
                    .buttonStyle(.borderless).focusable(false).help("Clear conversation").pointer().disabled(chat.items.isEmpty).uiFrame("chat.clear")
            }
            .frame(height: 28)
            if chat.backend == .apiKey {
                HStack(spacing: 8) {
                    TextField(chat.selectedProvider?.defaultModel ?? "model id", text: $chat.model)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(maxWidth: 150).disabled(chat.isRunning)
                        .help("Model id; empty uses the provider's default").uiFrame("chat.model")
                    Text(apiDetailLine).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help(chat.apiStatus)
                    Spacer(minLength: 0)
                }
            } else if !agentDetail.isEmpty {
                Text(agentDetail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help(chat.agentStatus)
            }
        }
    }

    /// A provider can run: Claude Code present when it needs it, and a key (or none needed).
    private func providerReady(_ p: CodemaxRunner.ProviderInfo) -> Bool {
        _ = chat.keysVersion
        return (!p.needsClaude || p.hasClaude) && (!ChatSession.keyRequired(p) || KeychainStore.key(p.keySlot) != nil)
    }

    /// The sidecar's status without its prefix, like `agentDetail`.
    private var apiDetail: String {
        let parts = chat.apiStatus.components(separatedBy: " · ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : ""
    }

    /// Status and, after a turn, its token usage: "Claude Agent 0.93.0 · fable · 1.2k in · 300 out · $0.012".
    private var apiDetailLine: String { [apiDetail, chat.lastUsage].filter { !$0.isEmpty }.joined(separator: " · ") }

    /// "Claude Agent 0.93.0 · fable" without the codemax prefix; the full string is the tooltip.
    private var agentDetail: String {
        if chat.agents.isEmpty, CodemaxRunner.bundledBinary != nil { return "Looking for agents…" }
        let parts = chat.agentStatus.components(separatedBy: " · ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : ""
    }

    /// Shown only when the agent backend cannot run: codemax missing, or the chosen agent is not installed.
    @ViewBuilder private var agentProblem: some View {
        if CodemaxRunner.bundledBinary == nil {
            Label("The agent runtime is missing from this build of EditMax.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        } else if let a = chat.selectedAgent, !a.installed {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(a.name) was not found on this Mac" + (a.problem.map { " (\($0))" } ?? "") + ".", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Install it and press the refresh button, or pick another agent.").font(.caption).foregroundStyle(.secondary)
                if let hint = ChatSession.installHints[a.id] {
                    Text(hint).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }
    private var hasAgentProblem: Bool { CodemaxRunner.bundledBinary == nil || (chat.selectedAgent.map { !$0.installed } ?? false) }

    // MARK: Empty state: a symbol, one line, one short note on how it runs, and three example requests as chips.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary).padding(.bottom, 4)
            Text("Tell \(workerName) what to change").font(.headline)
            Text(chat.backend == .agent
                 ? "Runs with its own login through EditMax's bundled agent runtime, no API key. It can only call EditMax's editing tools."
                 : "Uses your own API key through EditMax's bundled sidecar, pay per token. It can only call EditMax's editing tools.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                ForEach(Array(Self.suggestions.enumerated()), id: \.offset) { i, s in
                    SuggestionChip(text: s, id: "chat.suggestion.\(i)") { chat.input = s }
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 24)
        .padding(.bottom, 56)   // keeps the group centred in the part of the list not under the input bar
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The key box for the chosen provider's slot: what it needs, where the key is now (keychain or environment), save and remove.
    @ViewBuilder private var keyEntry: some View {
        let _ = chat.keysVersion
        if let problem = chat.apiProblem, chat.selectedProvider.map({ !ChatSession.keyRequired($0) || KeychainStore.key($0.keySlot) != nil }) ?? true {
            // Not a missing key: the sidecar or Claude Code is missing, or nothing is loaded yet.
            Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } else if let p = chat.selectedProvider {
            VStack(alignment: .leading, spacing: 6) {
                let source = KeychainStore.source(p.keySlot)
                Text(source == "environment" ? "\(p.keyEnv) is set in EditMax's environment; it is used as is."
                     : source == "keychain" ? "\(p.name) key (\(p.keyEnv)) is saved in your login keychain."
                     : p.needsClaude ? "The Claude Agent SDK runs on an Anthropic API key (\(p.keyEnv)), billed per token. Anthropic's terms do not allow apps built on it to use a Claude Pro or Max login; to use yours, switch to the Agent backend, which runs your own Claude Code. The key is stored in your login keychain and sent only to Anthropic."
                     : "Paste your \(p.name) key (\(p.keyEnv)). It is stored in your login keychain and sent only to the provider.")
                    .font(.caption).foregroundStyle(.secondary)
                if source != "environment" {
                    HStack {
                        SecureField(p.keySlot == "anthropic" ? "sk-ant-…" : p.keySlot == "google" ? "AIza…" : p.keySlot == "xai" ? "xai-…" : "sk-…", text: $keyDraft)
                            .textFieldStyle(.roundedBorder).controlSize(.small).uiFrame("chat.keyField")
                        Button("Save") { chat.saveKey(keyDraft, slot: p.keySlot); keyDraft = ""; editingKey = false }
                            .controlSize(.small).pointer().disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty).uiFrame("chat.saveKey")
                        if source == "keychain" { Button("Remove") { chat.saveKey("", slot: p.keySlot) }.controlSize(.small).pointer().uiFrame("chat.removeKey") }
                    }
                }
                if p.needsClaude, source.isEmpty {
                    Button("Use the Agent backend") { chat.backend = .agent }
                        .controlSize(.small).pointer().uiFrame("chat.useAgentBackend")
                        .help("Runs your own Claude Code with its own login, through EditMax's agent runtime")
                }
                if let url = ChatSession.keyConsoles[p.keySlot].flatMap(URL.init(string:)) {
                    Link("Get a key: \(url.host ?? url.absoluteString)", destination: url).font(.caption2).pointer().uiFrame("chat.keyConsole")
                }
            }
        }
    }

    // MARK: Composer: the floating control layer, so the only glass in this view. A capsule field and a round send / stop button.
    private var composer: some View {
        GlassGroup(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Tell \(workerName) what to change…", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain).font(.body).lineLimit(1...6)
                    .onSubmit { chat.send() }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: 32)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
                    .liquidGlass(in: fieldShape)
                    .uiFrame("chat.input")
                if chat.isRunning {
                    Button { chat.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold)).frame(width: 18, height: 18) }
                        .glassButtonStyle(prominent: true).buttonBorderShape(.circle).tint(.accentColor).focusable(false).help("Stop").pointer().uiFrame("chat.stop")
                } else {
                    Button { chat.send() } label: { Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).frame(width: 18, height: 18) }
                        .glassButtonStyle(prominent: true).buttonBorderShape(.circle).tint(.accentColor).focusable(false).keyboardShortcut(.return, modifiers: .command)
                        .help("Send (⌘↩)")
                        .pointer().disabled(chat.input.trimmingCharacters(in: .whitespaces).isEmpty || (chat.backend == .apiKey ? !chat.apiReady : !chat.agentReady)).uiFrame("chat.send")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: Self.columnWidth)
        .frame(maxWidth: .infinity)
    }

    /// A capsule for a one-line field; once it wraps, a continuous rounded rectangle so the corners stay clear of the text.
    private var fieldShape: AnyShape {
        fieldHeight > 40 ? AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) : AnyShape(Capsule())
    }
}

/// A small accent dot that pulses while a reply streams.
private struct PulseDot: View {
    var body: some View {
        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Color.accentColor)
            .symbolEffect(.pulse, options: .repeating)
            .accessibilityLabel("Working")
    }
}

/// One example request in the empty state: a capsule on the content layer (not glass), 6 % hover, fills the input on a click.
private struct SuggestionChip: View {
    let text: String
    let id: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text).font(.body).lineLimit(2).multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .liquidGlass(tint: hovering ? Color.primary.opacity(0.06) : nil, interactive: true)
        }
        .buttonStyle(.plain).focusable(false)
        .onHover { hovering = $0 }
        .animation(.snappy, value: hovering)
        .pointer().uiFrame(id).uiTap(id, action)
    }
}

private struct ItemView: View {
    let item: ChatSession.Item
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack { Spacer(minLength: 40)
                Text(item.text).font(.body).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous)) }
        case .assistant:
            MarkdownBlocks(text: item.text).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    statusIcon.frame(width: 14)
                    Text(item.text).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(item.status == "failed" ? Color.red : Color.primary).lineLimit(1).layoutPriority(1)
                    Text(summary).font(.system(size: 12)).foregroundStyle(item.status == "failed" ? Color.red.opacity(0.8) : Color.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if hasDetails { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle()).onTapGesture { if hasDetails { expanded.toggle() } }.pointer()
                .uiFrame("chat.tool.\(item.id.short)").uiTap("chat.tool.\(item.id.short)") { if hasDetails { expanded.toggle() } }
                if expanded {
                    if let i = item.input { block("Input", i) }
                    if let d = item.detail { block(item.status == "failed" ? "Error" : "Result", d) }
                }
            }
            .animation(.snappy, value: expanded)
        case .note:
            Label(item.text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        case .error:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").imageScale(.medium).foregroundStyle(.red)
                Text(item.text).font(.body).textSelection(.enabled)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var hasDetails: Bool { item.input != nil || item.detail != nil }

    /// The one-line result after the tool name: the first line of its output, or what it is doing.
    private var summary: String {
        if item.status == "running" { return "running…" }
        guard let d = item.detail else { return "" }
        return d.split(separator: "\n", omittingEmptySubsequences: true).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case "running": ProgressView().controlSize(.mini)
        case "failed": Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
        default: Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.bold()).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6).background(Color(nsColor: .textBackgroundColor)).cornerRadius(4)
        }
        .padding(.leading, 20)
    }

    /// Agents answer in Markdown; inline syntax (bold, code, links) is rendered and line breaks are kept so bullet lines stay lines.
    private static func markdown(_ s: String) -> AttributedString {
        let bulleted = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.drop(while: { $0 == " " })
            return t.hasPrefix("- ") || t.hasPrefix("* ") ? String(line.prefix(line.count - t.count)) + "•" + t.dropFirst() : String(line)
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: bulleted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}


/// Block-level Markdown for chat replies: headings, bullet and numbered lists, fenced code, pipe tables, paragraphs with
/// inline **bold**, `code` and links. Enough for an editing assistant's reports; not a full renderer.
struct MarkdownBlocks: View {
    let text: String
    private enum Block { case heading(Int, String), bullets([String]), numbered([String]), code(String), table([[String]]), paragraph(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let level, let t):
                    Text(Self.inline(t)).font(level == 1 ? .headline : level == 2 ? .subheadline.weight(.semibold) : .body.weight(.semibold)).padding(.top, 2)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                            HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•").foregroundStyle(.secondary); Text(Self.inline(it)).font(.body) }
                        }
                    }
                case .numbered(let items):
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                            HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit(); Text(Self.inline(it)).font(.body) }
                        }
                    }
                case .code(let c):
                    ScrollView(.horizontal, showsIndicators: false) { Text(c).font(.system(size: 11, design: .monospaced)).padding(8) }
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                case .table(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(Self.inline(cell)).font(r == 0 ? .caption.weight(.semibold) : .caption).foregroundStyle(r == 0 ? .secondary : .primary)
                                }
                            }
                            if r == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                        }
                    }
                    .padding(6).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                case .paragraph(let t):
                    Text(Self.inline(t)).font(.body)
                }
            }
        }
        .textSelection(.enabled)
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = [], bullets: [String] = [], numbered: [String] = [], table: [[String]] = []
        var code: [String]? = nil
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let c = code {
                if line.hasPrefix("```") { blocks.append(.code(c.joined(separator: "\n"))); code = nil } else { code!.append(raw) }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|") {
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }) { continue }   // the |---|---| separator
                if !para.isEmpty || !bullets.isEmpty || !numbered.isEmpty { flush() }
                table.append(cells); continue
            }
            if !table.isEmpty { flush() }
            if let m = line.firstMatch(of: /^(#{1,4})\s+(.*)$/) { flush(); blocks.append(.heading(m.1.count, String(m.2))); continue }
            if let m = line.firstMatch(of: /^[-*•]\s+(.*)$/) { if !para.isEmpty || !numbered.isEmpty { flush() }; bullets.append(String(m.1)); continue }
            if let m = line.firstMatch(of: /^\d+[.)]\s+(.*)$/) { if !para.isEmpty || !bullets.isEmpty { flush() }; numbered.append(String(m.1)); continue }
            if !bullets.isEmpty || !numbered.isEmpty { flush() }
            para.append(line)
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
