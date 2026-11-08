import Foundation
import Combine

/// In-app editing assistant scoped to one document. Two backends over the same line protocol (CodemaxRunner):
/// - Agent: the coding agents the user already has (Claude Code, Codex, OpenCode, Cursor, Grok…) driven by the bundled
///   codemax over this app's MCP server, with their own logins. No API key.
/// - API key: the user's own key through EditMax's bundled sidecar: the Claude Agent SDK (Claude Code's harness), or
///   Claude / OpenAI / Google / xAI through the Vercel AI SDK. Switching provider is one picker.
@MainActor
final class ChatSession: ObservableObject {
    struct Item: Identifiable {
        enum Kind { case user, assistant, tool, note, error }
        let id = UUID()
        var kind: Kind
        var text: String
        /// Tool output (or the error text when `status` is "failed").
        var detail: String? = nil
        /// Tool rows only: "running", "completed" or "failed".
        var status: String? = nil
        /// Tool rows only: the call's input, shown when the row is expanded.
        var input: String? = nil
    }

    enum Backend: String, CaseIterable { case agent = "Agent", apiKey = "API key" }

    /// Install hints shown when the chosen agent is missing. Claude Code's ACP adapter is fetched by bunx, so bun is needed too.
    static let installHints: [String: String] = [
        "claude": "curl -fsSL https://claude.ai/install.sh | bash   # plus bun: curl -fsSL https://bun.sh/install | bash",
        "codex": "bun install -g @openai/codex",
        "opencode": "curl -fsSL https://opencode.ai/install | bash",
        "cursor": "curl https://cursor.com/install -fsS | bash",
    ]

    /// Where to get a key for each provider slot.
    static let keyConsoles: [String: String] = [
        "anthropic": "https://console.anthropic.com/settings/keys",
        "openai": "https://platform.openai.com/api-keys",
        "google": "https://aistudio.google.com/apikey",
        "xai": "https://console.x.ai",
    ]

    @Published var items: [Item] = []
    @Published var input = ""
    /// Speaking instead of typing (the composer's microphone, ⇧⌘D): what is heard is written into `input` as it comes.
    let dictation = Dictation()
    /// Agent ▸ Ask the Agent… (⌘L): the composer takes the keyboard focus when this changes.
    @Published var focusRequest = 0
    @Published var isRunning = false {
        didSet {   // an agent reply in progress holds back the update popup's restart
            guard isRunning != oldValue else { return }
            if isRunning { BusyWork.begin(BusyWork.agentReply) } else { BusyWork.end(BusyWork.agentReply) }
        }
    }
    @Published var backend: Backend {
        didSet {
            UserDefaults.standard.set(backend.rawValue, forKey: "chatBackend")
            // The sidecar (a 60 MB process) runs only once the API backend is in use.
            if backend == .apiKey, providers.isEmpty { refreshProviders() }
        }
    }
    /// codemax agent id: claude, codex, opencode, cursor, grok, antigravity, copilot.
    @Published var agent: String { didSet { UserDefaults.standard.set(agent, forKey: "chatAgent") } }
    @Published private(set) var agents: [CodemaxRunner.AgentInfo] = []
    /// "codemax 0.1.21 · Claude Agent 0.93.0 · fable"
    @Published private(set) var agentStatus = ""

    /// API-key backend: provider id (claude-agent, anthropic, openai, google, xai) and model (empty = the provider's default).
    @Published var provider: String { didSet { UserDefaults.standard.set(provider, forKey: "chatProvider") } }
    @Published var model: String { didSet { UserDefaults.standard.set(model, forKey: "chatModel") } }
    @Published private(set) var providers: [CodemaxRunner.ProviderInfo] = []
    @Published private(set) var apiStatus = ""
    @Published private(set) var lastUsage = ""
    /// Bumped when a key is saved or removed, so views and `providers` refresh.
    @Published private(set) var keysVersion = 0

    private let runner = CodemaxRunner(kind: .codemax)
    private let apiRunner = CodemaxRunner(kind: .agent)
    private var configuredAgent: String?
    /// The provider and model the sidecar currently runs; a change restarts it with the next message.
    private var configuredAPI: (provider: String, model: String)?
    private var currentAssistant: UUID?
    private var toolItems: [String: UUID] = [:]
    private var turnUsage = (input: 0, output: 0, cost: 0.0)
    /// The agent wrote text this turn. A turn that then ends with a tool call left open (Claude Code's
    /// `incomplete_tool_call`, as when a server tool such as the advisor never answers) gave its reply: a note, not a failure.
    var turnReplied = false

    let document: EditMaxDocument
    private var task: Task<Void, Never>?

    /// Every live session, so Settings can show the agents and providers the runtime reported.
    private static let live = NSHashTable<ChatSession>.weakObjects()
    static var anyAgents: [CodemaxRunner.AgentInfo]? { live.allObjects.map(\.agents).first { !$0.isEmpty } }
    static var anyProviders: [CodemaxRunner.ProviderInfo]? { live.allObjects.map(\.providers).first { !$0.isEmpty } }
    private var observers: [NSObjectProtocol] = []

    init(document: EditMaxDocument) {
        self.document = document
        backend = UserDefaults.standard.string(forKey: "chatBackend").flatMap(Backend.init(rawValue:)) ?? .agent
        agent = UserDefaults.standard.string(forKey: "chatAgent") ?? "claude"
        provider = UserDefaults.standard.string(forKey: "chatProvider") ?? "claude-agent"
        // Older builds saved a Claude model id for the raw API; it still applies.
        model = UserDefaults.standard.string(forKey: "chatModel") ?? ""
        runner.onEvent = { [weak self] ev in self?.handle(ev) }
        apiRunner.onEvent = { [weak self] ev in self?.handle(ev) }
        dictation.onText = { [weak self] t in self?.input = t }
        refreshAgents()
        if backend == .apiKey { refreshProviders() }
        Self.live.add(self)
        // Settings edits the same defaults; pick them up here, and hand the sidecar new keys.
        observers.append(NotificationCenter.default.addObserver(forName: .editmaxChatDefaultsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadDefaults() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .editmaxKeysChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.keysChanged() }
        })
    }

    /// Settings changed a chat default: follow it unless a turn is running on the old choice.
    private func reloadDefaults() {
        guard !isRunning else { return }
        let d = UserDefaults.standard
        if let b = d.string(forKey: "chatBackend").flatMap(Backend.init(rawValue:)), b != backend { let old = backend; backend = b; switchBackend(from: old, to: b) }
        if let a = d.string(forKey: "chatAgent"), a != agent { agent = a }
        if let p = d.string(forKey: "chatProvider"), p != provider { provider = p }
        let m = d.string(forKey: "chatModel") ?? ""
        if m != model { model = m }
    }
    private func keysChanged() {
        keysVersion += 1
        configuredAPI = nil
        if backend == .apiKey { refreshProviders() }
    }

    var selectedAgent: CodemaxRunner.AgentInfo? { agents.first { $0.id == agent } }
    var agentReady: Bool { selectedAgent?.installed ?? false }

    var selectedProvider: CodemaxRunner.ProviderInfo? { providers.first { $0.id == provider } }
    /// Why the API backend cannot send right now, or nil when it can.
    var apiProblem: String? {
        guard CodemaxRunner.bundledBinary(.agent) != nil else { return "The API sidecar is missing from this build of EditMax." }
        guard let p = selectedProvider else { return providers.isEmpty ? nil : "Pick a provider." }
        if p.needsClaude, !p.hasClaude { return "\(p.name) runs through Claude Code, which was not found on this Mac. Install it: curl -fsSL https://claude.ai/install.sh | bash" }
        if Self.keyRequired(p), KeychainStore.key(p.keySlot) == nil {
            return p.needsClaude ? "The Claude Agent SDK needs an Anthropic API key (\(p.keyEnv)). To use your Claude subscription instead, switch to the Agent backend."
                                 : "Add your \(p.name) key (\(p.keyEnv)) above."
        }
        return nil
    }
    var apiReady: Bool { apiProblem == nil && selectedProvider != nil }

    /// Whether a provider needs a key before it can send. The Claude Agent SDK always does, whatever the sidecar
    /// reports: Anthropic's terms do not allow apps built on it to run on a Claude subscription login. (The Agent
    /// backend runs the person's own Claude Code with its own login, which is allowed.)
    nonisolated static func keyRequired(_ p: CodemaxRunner.ProviderInfo) -> Bool { !p.keyOptional || p.needsClaude }

    private var agentsTask: Task<Void, Never>?

    /// Asks codemax which agents are installed; picks the first installed one when the saved choice is missing.
    func refreshAgents() {
        agentsTask = Task { [weak self] in
            guard let self else { return }
            do {
                try self.runner.launch()
                self.agents = try await self.runner.agents()
                if self.agentStatus.isEmpty { self.agentStatus = "Agent runtime \(self.runner.version ?? "")" }
                if !self.agentReady, let first = self.agents.first(where: { $0.installed }) { self.agent = first.id }
            } catch {
                self.items.append(Item(kind: .error, text: error.localizedDescription))
            }
        }
    }

    /// Asks the sidecar what each provider needs and what this Mac has (Claude Code, keys from the keychain or environment).
    func refreshProviders() {
        guard CodemaxRunner.bundledBinary(.agent) != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try self.apiRunner.launch()
                self.providers = try await self.apiRunner.providers(keys: KeychainStore.allKeys)
                if self.apiStatus.isEmpty { self.apiStatus = "sidecar \(self.apiRunner.version ?? "")" }
            } catch {
                DebugLog.error("providers-failed", error)
            }
        }
    }

    /// Saves (or, with an empty key, removes) the key for a provider slot and refreshes the providers' status.
    func saveKey(_ key: String, slot: String) {
        KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), slot: slot)
        keysVersion += 1
        configuredAPI = nil   // the sidecar is given the keys again on the next message
        refreshProviders()
    }

    /// Send, or while listening: stop, let the last words settle, then send what is in the field.
    func sendOrFinishDictation() {
        guard dictation.isActive else { send(); return }
        Task { input = await dictation.finish(); send() }
    }

    /// The microphone button and ⇧⌘D: start listening after what is typed, or stop.
    func toggleDictation() { dictation.toggle(current: input) }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        DebugLog.event("chat-send", ["backend": backend == .agent ? "agent" : "api-key", "characters": text.count])   // never the prompt
        switch backend {
        case .agent:
            guard CodemaxRunner.bundledBinary != nil else { items.append(Item(kind: .error, text: "The agent runtime is missing from this build of EditMax.")); return }
            input = ""
            items.append(Item(kind: .user, text: text))
            Telemetry.shared.capture(.agentTurn, ["backend": "agent"])
            runAgent(prompt: withHandoff(text))
        case .apiKey:
            if let problem = apiProblem { items.append(Item(kind: .error, text: problem)); return }
            input = ""
            items.append(Item(kind: .user, text: text))
            Telemetry.shared.capture(.agentTurn, ["backend": "api-key"])
            runAPI(prompt: withHandoff(text))
        }
    }

    /// The first message after a backend switch carries a digest of the earlier conversation (user requests and the
    /// assistant's replies, not tool output), so "continue the grade" still means something to the new session.
    private var handoffPending = false
    private func withHandoff(_ text: String) -> String {
        guard handoffPending else { return text }
        handoffPending = false
        let earlier = items.dropLast().filter { $0.kind == .user || $0.kind == .assistant }.suffix(30)
            .map { ($0.kind == .user ? "User: " : "Assistant: ") + $0.text.prefix(600) }.joined(separator: "\n")
        guard !earlier.isEmpty else { return text }
        return "Earlier in this chat (a previous session, whose edits are already in the timeline and History):\n\(earlier)\n\nNew request: \(text)"
    }

    func stop() { DebugLog.event("chat-stop"); (backend == .apiKey ? apiRunner : runner).cancel() }

    /// Forgets the conversation; the next message starts a fresh session.
    func clear() {
        stop()
        if configuredAgent != nil { runner.close(); configuredAgent = nil }
        if configuredAPI != nil { apiRunner.close(); configuredAPI = nil }
        items = []; lastUsage = ""; currentAssistant = nil; toolItems = [:]
    }

    /// Agent ↔ API key: the transcript stays on screen (it is the user's record of what was done); only the running
    /// session ends. The next message starts a fresh session on the new backend, which has not read the earlier turns.
    func switchBackend(from old: Backend, to new: Backend) {
        guard old != new else { return }
        stop()
        if configuredAgent != nil { runner.close(); configuredAgent = nil }
        if configuredAPI != nil { apiRunner.close(); configuredAPI = nil }
        currentAssistant = nil; toolItems = [:]
        if !items.isEmpty {
            handoffPending = true
            items.append(Item(kind: .note, text: "Switched to \(new.rawValue). The next message starts a new session there; it gets a digest of the messages above so you can carry on, and every edit so far is in the timeline and History."))
        }
    }

    static let agentInstructions = """
    You are EditMax's editor: the best video editor in the world, with the complete craft of picture editing, color grading, sound and delivery, \
    and nobody beats you at it. You prove it the way great editors do: by looking, measuring and shipping, never by saying so. \
    You work inside EditMax, a macOS video editor, through its `editmax` MCP tools. Edit only with those tools; do not read or write files directly. \
    The user sees the real timeline change as you work.

    Method. inspect_timeline before editing and after a run of changes. Plan the cut before touching it. After each visual change, judge it: \
    frame_stats for numbers (luma, clipping, color balance), capture_frame when you must see the picture. Show the user the moment you changed with set_playhead. \
    Times are seconds on the timeline; ids are the 8-character prefixes you see. Every edit records a snapshot in History (restore_snapshot goes back). \
    Before removing more than one clip, or restoring an old snapshot, confirm with the user unless they clearly asked for exactly that.

    Cutting. Cut on action and on the beat of the sound. Straight cuts by default; a cross dissolve only for a passage of time or a mood change; \
    fades at the head and tail. Hold a title long enough to read it twice. Trim the air out of speech with detect_silence / remove_silence / remove_words \
    before adding captions. Edit speech by its words: search_transcript finds a phrase with its times, cut_transcript removes a sentence, a take or a \
    word range and ripples every track (the way to "remove the second take" or "cut the part where I say X"). Keep clips from drifting out of sync \
    when you ripple. Match the project's frame rate and aspect to the delivery: apply_template (YouTube 16:9, Shorts / Reels 9:16, Square 1:1, 4K) \
    keeps the clips and only changes the frame; after a change of aspect run auto_reframe on each video clip so the subject stays in view \
    instead of letterboxing. Shaky footage: stabilize_clip (smooths the camera path, zooms a little to hide the borders; larger strength = steadier, more zoom).

    Color. Log footage first gets its conversion: set input_lut to the camera maker's log-to-Rec.709 cube (DJI D-Log and D-Log M are different \
    profiles with different cubes; never stack two conversions). Then, in order: exposure, white balance (temperature: + warm, − cool; tint: + magenta, − green), contrast, \
    shadows / midtones / highlights, saturation and vibrance, and last a creative look at a partial look_mix. Skin stays skin-colored; \
    whites stay below clipping (check frame_stats: clipped white and black well under 1 %); snow and sky keep texture. Match shots cut together \
    before styling them. Say which settings you chose and why.

    Sound. Speech is the priority: set_clip_audio voice_isolation (0.5-1) strips room noise and background from dialogue on this Mac (it renders once per \
    asset; the preview catches up when it is done), then high_pass 80-120 Hz against rumble, a gate (about -45 dBFS) for room tone between words, a gentle EQ. \
    Music ducks under voice (set_ducking, about -12 dB, short attack, longer release). Short fades on every audio edge against clicks. \
    Keep loudness consistent across the timeline; use volume keyframes for ramps.

    Captions. add_captions transcribes on this Mac and adds timed lines (presets subtitle, boxed, bold, outline, minimal, title); get_transcript gives \
    the words with times; remove_captions clears them. Long files take a while to transcribe the first time.

    Delivery. export_video: H.264 (high) for sharing, hevc10 (10-bit HEVC Main 10, Rec.709) or a ProRes .mov (prores422hq, prores422, prores4444) \
    when the result goes to a colorist or another editor with everything baked in; \
    chapters true writes the markers as a YouTube chapter list beside it (export_chapters returns the text to paste into a description). \
    export_batch renders every delivery format in one go (one MP4 per template, video clips auto-reframed for the other aspects). \
    export_timeline writes the edit itself (FCPXML for Resolve and Final Cut, or an EDL of the bottom video track) pointing at the original media; \
    grades, looks, styles, EQ, isolation, ducking and stabilization stay behind, so relay its transferred and notTransferred lists as they are \
    and suggest a ProRes master beside it when the grade matters.

    Limits. EditMax has no masks, motion tracking, keying, HDR output or multi-layer compositing beyond stills, titles, \
    transforms and transitions. When asked for one of those, say so plainly and offer the nearest thing the tools do; never claim it was done.

    Reply briefly: what you did in one or two sentences, a short bullet list when there are several changes, timecodes as mm:ss, \
    Markdown tables for measurements. No boasting; the work speaks.
    """

    private var instructions: String {
        Self.agentInstructions + " The user's project id is \(document.id.short); pass project: \"\(document.id.short)\" to every editmax tool."
    }

    /// One card per failure, in plain words. A failed turn reports its error twice (an error event, then the turn's
    /// result), which showed the friendly card and the raw `incomplete_tool_call` text under it.
    func appendError(_ raw: String) {
        if turnReplied, Self.leftAToolOpen(raw) {
            let note = "The reply above is complete. A last step the agent started did not finish and was left out."
            if items.last?.text != note { items.append(Item(kind: .note, text: note)) }
            return
        }
        let text = Self.plainError(raw)
        if let last = items.last, last.kind == .error, last.text == text { return }
        items.append(Item(kind: .error, text: text))
    }

    /// Claude Code's "ended the turn without returning results for tool calls".
    static func leftAToolOpen(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("incomplete_tool_call") || m.contains("without returning results for tool calls")
    }

    /// Agent-harness errors in words for the person editing. The raw text stays in the debug log for us.
    static func plainError(_ message: String) -> String {
        let m = message.lowercased()
        if m.contains("incomplete_tool_call") || m.contains("without returning results for tool calls") {
            return "The agent stopped before finishing its last step. Your edits so far are kept; send \"continue\" to pick up where it left off."
        }
        if m.contains("rate limit") || m.contains("429") || m.contains("overloaded") {
            return "The model is busy right now (rate limited). Wait a moment and send the message again."
        }
        if m.contains("context") && (m.contains("too long") || m.contains("exceed")) {
            return "This conversation got too long for the agent. Clear the chat (trash icon) and continue with a fresh request."
        }
        if m.contains("timed out") || m.contains("timeout") { return "The agent took too long to answer and was stopped. Try the request again, or split it in two." }
        if m.contains("connection") || m.contains("network") || m.contains("enotfound") { return "No connection to the model service. Check the network and try again." }
        return message
    }

    private static func status(_ version: String?, _ info: CodemaxRunner.StartInfo, prefix: String) -> String {
        ["\(prefix) \(version ?? "")", [info.name, info.version].compactMap { $0 }.joined(separator: " "), info.model ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func shortTool(_ title: String) -> String {
        for prefix in ["mcp__editmax__", "editmax/", "editmax:", "editmax."] where title.hasPrefix(prefix) { return String(title.dropFirst(prefix.count)) }
        return title
    }

    private func handle(_ ev: CodemaxRunner.Event) {
        switch ev {
        case .text(let t):
            turnReplied = true
            if let id = currentAssistant, let i = items.firstIndex(where: { $0.id == id }) { items[i].text += t }
            else { let it = Item(kind: .assistant, text: t); currentAssistant = it.id; items.append(it) }
        case .toolCall(let id, let title, let input):
            currentAssistant = nil
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let it = Item(kind: .tool, text: Self.shortTool(title), status: "running", input: trimmed.isEmpty || trimmed == "{}" ? nil : trimmed)
            toolItems[id] = it.id; items.append(it)
        case .toolUpdate(let id, let title, let status, let output):
            guard let iid = toolItems[id], let i = items.firstIndex(where: { $0.id == iid }) else { return }
            if let title, items[i].text == "tool" { items[i].text = Self.shortTool(title) }
            if let status { items[i].status = status == "failed" ? "failed" : status == "completed" ? "completed" : "running" }
            if let output, !output.isEmpty {
                items[i].detail = output.count > 600 ? String(output.prefix(600)) + "…" : output
            } else if status == "failed", items[i].detail == nil { items[i].detail = "The call failed." }
        case .permissionAuto(let title, let decision):
            if decision == "reject" { items.append(Item(kind: .note, text: "Refused: \(title). Only EditMax's tools are allowed.")) }
        case .handoff(let from, let to, let reason):
            let name = { (id: String) in self.agents.first { $0.id == id }?.name ?? id }
            items.append(Item(kind: .note, text: "\(reason.isEmpty ? name(from) + " stopped" : reason); continuing with \(name(to))."))
            configuredAgent = to; agent = to; currentAssistant = nil
        case .error(let kind, let message):
            currentAssistant = nil
            let replied = turnReplied && Self.leftAToolOpen(message)
            // A protocol breakdown or crash in the agent side of an updated codemax counts against the update; a
            // finished reply with a tool call left open is the model's doing, not the runtime's.
            if backend == .agent, !replied, kind == "protocol" || kind == "crashed" { CodemaxUpdater.shared.noteAgentFailure("turn-\(kind)", detail: message) }
            Telemetry.shared.agentFailed(kind: replied ? "tool_left_open" : kind, backend: backend == .agent ? "agent" : "api-key",
                                         detail: Telemetry.errorKind(in: message))
            appendError(kind == "quota" ? "Out of quota: \(message)" : kind == "auth" ? (backend == .apiKey ? "Key rejected: \(message)" : "Login needed: \(message)") : message)
        case .notice(let text):
            items.append(Item(kind: .note, text: text))
        case .usage(let input, let output, let cost):
            turnUsage.input += input ?? 0; turnUsage.output += output ?? 0; turnUsage.cost += cost ?? 0
            lastUsage = Self.usageText(turnUsage)
        }
    }

    private static func usageText(_ u: (input: Int, output: Int, cost: Double)) -> String {
        func k(_ n: Int) -> String { n >= 10_000 ? "\(n / 1000)k" : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
        var s = "\(k(u.input)) in · \(k(u.output)) out"
        if u.cost > 0 { s += String(format: " · $%.3f", u.cost) }
        return s
    }

    private func runAgent(prompt: String) {
        isRunning = true
        let mcp = MCPService.shared
        let instructions = self.instructions
        let wanted = agent
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            do {
                // The agent listing may still be on its way right after launch; a codemax that died (and may have been rolled back) is asked again.
                if self.agents.isEmpty { await self.agentsTask?.value }
                if self.agents.isEmpty { self.refreshAgents(); await self.agentsTask?.value }
                guard let info = self.selectedAgent, info.installed else {
                    let name = self.selectedAgent?.name ?? wanted
                    self.items.append(Item(kind: .error, text: "\(name) is not installed on this Mac. Install it and press the refresh button, or pick another agent."))
                    return
                }
                // Starting the agent: an updated codemax that cannot do it counts against that update (two strikes roll
                // it back), and the start is tried again, with the restored copy after a rollback.
                var attempt = 0
                while true {
                    attempt += 1
                    do {
                        // A codemax that died (or was closed) starts over with a fresh session.
                        if !self.runner.isRunning { self.configuredAgent = nil }
                        try self.runner.launch()
                        if self.configuredAgent == nil {
                            let info = try await self.runner.configure(agent: wanted, mcpURL: mcp.url, token: mcp.token, instructions: instructions)
                            self.configuredAgent = info.agent; self.agentStatus = Self.status(self.runner.version, info, prefix: "codemax")
                        } else if self.configuredAgent != wanted {
                            let info = try await self.runner.switchAgent(wanted)
                            self.configuredAgent = info.agent; self.agentStatus = Self.status(self.runner.version, info, prefix: "codemax")
                            self.items.append(Item(kind: .note, text: "Switched to \(info.name)."))
                        }
                        break
                    } catch {
                        let msg = error.localizedDescription
                        guard attempt < 3, Self.looksLikeCodemaxFault(msg) else { throw error }
                        let rolled = CodemaxUpdater.shared.noteAgentFailure("configure", detail: msg)
                        self.runner.close(); self.configuredAgent = nil
                        if rolled { self.items.append(Item(kind: .note, text: "The updated agent runtime could not start \(info.name) (\(msg)); rolled back to the previous copy and trying again.")) }
                    }
                }
                self.currentAssistant = nil; self.turnReplied = false
                let r = try await self.runner.prompt(prompt)
                if !r.agent.isEmpty, r.agent != self.configuredAgent { self.configuredAgent = r.agent; self.agent = r.agent }
                if let e = r.error { self.appendError(e) }
                else if r.stopReason == "cancelled" { self.items.append(Item(kind: .note, text: "Stopped.")) }
                self.finishOpenTools()
            } catch {
                self.appendError(error.localizedDescription)
                self.finishOpenTools()
            }
        }
    }

    // MARK: API-key backend (the bundled sidecar: Claude Agent SDK or Vercel AI SDK over this app's MCP server)

    /// `configure.api` / `switch.api` for the sidecar: the provider, the model (or its default) and every key the app has.
    private var apiSettings: [String: Any] {
        var api: [String: Any] = ["provider": provider, "keys": KeychainStore.allKeys]
        let m = model.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty { api["model"] = m }
        return api
    }

    private func runAPI(prompt: String) {
        isRunning = true
        let mcp = MCPService.shared
        let instructions = self.instructions
        let wanted = (provider: provider, model: model.trimmingCharacters(in: .whitespaces))
        let api = apiSettings
        turnUsage = (0, 0, 0)
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }
            do {
                if !self.apiRunner.isRunning { self.configuredAPI = nil }
                try self.apiRunner.launch()
                if self.configuredAPI == nil {
                    let info = try await self.apiRunner.configure(agent: "api", mcpURL: mcp.url, token: mcp.token, instructions: instructions, api: api)
                    self.configuredAPI = wanted; self.apiStatus = Self.status(self.apiRunner.version, info, prefix: "sidecar")
                } else if self.configuredAPI! != wanted {
                    let info = try await self.apiRunner.switchAgent("api", api: api)
                    self.configuredAPI = wanted; self.apiStatus = Self.status(self.apiRunner.version, info, prefix: "sidecar")
                    self.items.append(Item(kind: .note, text: "Switched to \(info.name)\(info.model.map { " · \($0)" } ?? "")."))
                }
                self.currentAssistant = nil; self.turnReplied = false
                let r = try await self.apiRunner.prompt(prompt)
                if let e = r.error { self.appendError(e) }
                else if r.stopReason == "cancelled" { self.items.append(Item(kind: .note, text: "Stopped.")) }
                else if r.stopReason == "max_tokens" { self.items.append(Item(kind: .note, text: "Reply was cut off at the token limit.")) }
                else if r.stopReason == "refusal" { self.items.append(Item(kind: .note, text: "The model declined this request.")) }
                self.finishOpenTools()
            } catch {
                self.appendError(error.localizedDescription)
                self.finishOpenTools()
            }
        }
    }

    /// Not the user's quota, login or a missing agent: those are not codemax's fault and never count against an update.
    static func looksLikeCodemaxFault(_ message: String) -> Bool {
        let m = message.lowercased()
        return !(m.contains("quota") || m.contains("usage limit") || m.contains("rate limit") || m.contains("not installed") || m.contains("log in") || m.contains("login") || m.contains("sign in") || m.contains("unauthori") || m.contains("not found on this mac"))
    }

    /// Tool rows whose completion never arrived (cancel, crash, agents that only report the start) stop spinning.
    private func finishOpenTools() {
        for i in items.indices where items[i].kind == .tool && items[i].status == "running" { items[i].status = "completed" }
    }
}
