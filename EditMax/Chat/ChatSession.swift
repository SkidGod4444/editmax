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
    @Published var isRunning = false
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

    let document: EditMaxDocument
    private var task: Task<Void, Never>?

    init(document: EditMaxDocument) {
        self.document = document
        backend = UserDefaults.standard.string(forKey: "chatBackend").flatMap(Backend.init(rawValue:)) ?? .agent
        agent = UserDefaults.standard.string(forKey: "chatAgent") ?? "claude"
        provider = UserDefaults.standard.string(forKey: "chatProvider") ?? "claude-agent"
        // Older builds saved a Claude model id for the raw API; it still applies.
        model = UserDefaults.standard.string(forKey: "chatModel") ?? ""
        runner.onEvent = { [weak self] ev in self?.handle(ev) }
        apiRunner.onEvent = { [weak self] ev in self?.handle(ev) }
        refreshAgents()
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
        if !p.keyOptional, KeychainStore.key(p.keySlot) == nil { return "Add your \(p.name) key (\(p.keyEnv)) above." }
        return nil
    }
    var apiReady: Bool { apiProblem == nil && selectedProvider != nil }

    private var agentsTask: Task<Void, Never>?

    /// Asks codemax which agents are installed; picks the first installed one when the saved choice is missing.
    func refreshAgents() {
        agentsTask = Task { [weak self] in
            guard let self else { return }
            do {
                try self.runner.launch()
                self.agents = try await self.runner.agents()
                if self.agentStatus.isEmpty { self.agentStatus = "codemax \(self.runner.version ?? "")" }
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

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        switch backend {
        case .agent:
            guard CodemaxRunner.bundledBinary != nil else { items.append(Item(kind: .error, text: "codemax is missing from this build of EditMax.")); return }
            input = ""
            items.append(Item(kind: .user, text: text))
            runAgent(prompt: text)
        case .apiKey:
            if let problem = apiProblem { items.append(Item(kind: .error, text: problem)); return }
            input = ""
            items.append(Item(kind: .user, text: text))
            runAPI(prompt: text)
        }
    }

    func stop() { (backend == .apiKey ? apiRunner : runner).cancel() }

    /// Forgets the conversation; the next message starts a fresh session.
    func clear() {
        stop()
        if configuredAgent != nil { runner.close(); configuredAgent = nil }
        if configuredAPI != nil { apiRunner.close(); configuredAPI = nil }
        items = []; lastUsage = ""; currentAssistant = nil; toolItems = [:]
    }

    static let agentInstructions = """
    You are working inside EditMax, a macOS video editor, through its `editmax` MCP tools. Edit only with those tools; do not read or write files directly. \
    Call inspect_timeline before editing and after a series of changes; use capture_frame when visual judgement matters; use set_playhead to show the user the moment you changed. \
    Times are seconds on the timeline; ids may be given as the 8-character prefixes you see. Every edit records a snapshot in History. \
    Reply briefly: say what you did in one or two sentences, use a short bullet list when there are several changes, give timecodes as mm:ss. \
    Before removing more than one clip, or restoring an old snapshot, confirm with the user unless they clearly asked for exactly that.
    """

    private var instructions: String {
        Self.agentInstructions + " The user's project id is \(document.id.short); pass project: \"\(document.id.short)\" to every editmax tool."
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
            items.append(Item(kind: .error, text: kind == "quota" ? "Out of quota: \(message)" : kind == "auth" ? (backend == .apiKey ? "Key rejected: \(message)" : "Login needed: \(message)") : message))
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
                self.currentAssistant = nil
                let r = try await self.runner.prompt(prompt)
                if !r.agent.isEmpty, r.agent != self.configuredAgent { self.configuredAgent = r.agent; self.agent = r.agent }
                if let e = r.error { self.items.append(Item(kind: .error, text: e)) }
                else if r.stopReason == "cancelled" { self.items.append(Item(kind: .note, text: "Stopped.")) }
                self.finishOpenTools()
            } catch {
                self.items.append(Item(kind: .error, text: error.localizedDescription))
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
                self.currentAssistant = nil
                let r = try await self.apiRunner.prompt(prompt)
                if let e = r.error { self.items.append(Item(kind: .error, text: e)) }
                else if r.stopReason == "cancelled" { self.items.append(Item(kind: .note, text: "Stopped.")) }
                else if r.stopReason == "max_tokens" { self.items.append(Item(kind: .note, text: "Reply was cut off at the token limit.")) }
                else if r.stopReason == "refusal" { self.items.append(Item(kind: .note, text: "The model declined this request.")) }
                self.finishOpenTools()
            } catch {
                self.items.append(Item(kind: .error, text: error.localizedDescription))
                self.finishOpenTools()
            }
        }
    }

    /// Tool rows whose completion never arrived (cancel, crash, agents that only report the start) stop spinning.
    private func finishOpenTools() {
        for i in items.indices where items[i].kind == .tool && items[i].status == "running" { items[i].status = "completed" }
    }
}
