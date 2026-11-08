import Foundation

/// Drives one of the two bundled chat backends over the same line protocol: one JSON request per line on stdin, one JSON
/// event or answer per line on stdout.
/// - `.codemax`: `codemax serve` runs the chosen agent (Claude Code, Codex, OpenCode, Cursor, Grok…) over its interactive
///   protocol with the user's own login.
/// - `.agent`: `editmax-agent`, EditMax's own sidecar (agent/), runs the user's API key through the Claude Agent SDK or
///   the Vercel AI SDK (Claude, OpenAI, Google, xAI).
/// Both answer every permission request by policy: EditMax's MCP tools are allowed, everything else is refused.
@MainActor
final class CodemaxRunner {
    enum Kind {
        case codemax, agent
        var binaryName: String { self == .codemax ? "codemax" : "editmax-agent" }
        var displayName: String { self == .codemax ? "codemax" : "the API sidecar" }
        var arguments: [String] { self == .codemax ? ["serve"] : [] }
        /// Prefix in the protocol log, so both processes' lines can be told apart.
        var tag: String { self == .codemax ? "" : "api" }
    }
    let kind: Kind
    init(kind: Kind = .codemax) { self.kind = kind }

    struct AgentInfo: Identifiable, Equatable {
        let id: String; let name: String; let installed: Bool; let version: String?; let problem: String?
        /// The `api` agent only: its providers and what each needs.
        var providers: [ProviderInfo] = []
    }
    struct ModelInfo: Identifiable, Equatable { let id: String; let name: String }
    /// One way to spend an API key: the Claude Agent SDK, or a provider through the Vercel AI SDK (codemax's `providers`).
    struct ProviderInfo: Identifiable, Equatable {
        let id: String; let name: String
        /// Key slot: anthropic, openai, google or xai.
        let keySlot: String; let keyEnv: String; let keyOptional: Bool
        let defaultModel: String?; let models: [ModelInfo]
        let needsClaude: Bool; let hasClaude: Bool
    }
    struct StartInfo { let agent: String; let name: String; let version: String?; let model: String?; let session: String?; let provider: String?; let models: [ModelInfo] }
    struct TurnResult { let stopReason: String; let error: String?; let agent: String }
    enum Event {
        case text(String)
        case toolCall(id: String, title: String, input: String)
        case toolUpdate(id: String, title: String?, status: String?, output: String?)
        case permissionAuto(title: String, decision: String)
        case handoff(from: String, to: String, reason: String)
        case error(kind: String, message: String)
        case notice(String)
        /// Token counts for the work just done (the API sidecar reports them per step).
        case usage(input: Int?, output: Int?, cost: Double?)
    }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// The copy inside EditMax.app; EditMax always runs this one, whatever `codemax` is on PATH.
    nonisolated static var bundledBinary: URL? { bundledBinary(.codemax) }
    nonisolated static func bundledBinary(_ kind: Kind) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/\(kind.binaryName)"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
    /// Where the agents' own CLIs usually live; the app's own environment has none of these.
    nonisolated static var spawnPATH: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:\(home)/.bun/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
    }
    /// codemax's working folder for EditMax sessions (its journal and sessions live under this cwd). Not a repository.
    static var workDirectory: URL { MCPService.configDirectory.appendingPathComponent("agent") }

    var onEvent: ((Event) -> Void)?
    /// Every line exchanged with codemax goes to the protocol log (DebugLog.protocolFile, redacted); EDITMAX_CODEMAX_LOG=<file> moves it.
    nonisolated private static func log(_ dir: String, _ line: String, tag: String = "") { DebugLog.protocolLine(tag + dir, line) }
    private func log(_ dir: String, _ line: String) { Self.log(dir, line, tag: kind.tag) }
    private(set) var version: String?
    private(set) var isRunning = false
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var stdin: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var stderrTail = ""
    /// The binary of the running (or last) process, for the updater's rollback bookkeeping.
    private var binary: URL?

    deinit {
        try? stdin?.close()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if p?.isRunning == true { p?.terminate() } }
    }

    func launch() throws {
        if isRunning { return }
        guard let bin = kind == .codemax ? CodemaxUpdater.activeBinary() : Self.bundledBinary(kind) else {
            throw Failure(message: "\(kind.binaryName) is missing from this build of EditMax (Contents/Resources/bin/\(kind.binaryName)). Run scripts/vendor-\(kind == .codemax ? "codemax" : "agent").sh and rebuild.")
        }
        let p = Process()
        p.executableURL = bin
        p.arguments = kind.arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.spawnPATH
        p.environment = env
        try? FileManager.default.createDirectory(at: Self.workDirectory, withIntermediateDirectories: true)
        p.currentDirectoryURL = Self.workDirectory
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        let tag = kind.tag, name = kind.binaryName
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Self.log("!", "exited \(status)", tag: tag)
            DebugLog.event("\(name)-exit", ["status": Int(status)])
            Task { @MainActor in self?.didExit(proc, status: status) }
        }
        try p.run()
        process = p; stdin = inPipe.fileHandleForWriting; isRunning = true; stderrTail = ""; binary = bin; version = nil
        DebugLog.event("\(kind.binaryName)-launch", ["binary": bin.path, "pid": Int(p.processIdentifier)])
        // FileHandle.bytes.lines holds a pipe's data back until it closes, so lines are split by hand as they arrive.
        Self.readLines(outPipe.fileHandleForReading) { [weak self] line in self?.handle(line: line) }
        Self.readLines(errPipe.fileHandleForReading) { [weak self] line in
            guard let self else { return }
            self.stderrTail = String((self.stderrTail + line + "\n").suffix(2000))
        }
    }

    /// Calls `onLine` on the main actor for every complete line, in order, until the handle reaches end of file.
    nonisolated private static func readLines(_ handle: FileHandle, onLine: @escaping @MainActor (String) -> Void) {
        var buffer = Data()
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {   // end of file
                h.readabilityHandler = nil
                if !buffer.isEmpty, let rest = String(data: buffer, encoding: .utf8) { DispatchQueue.main.async { onLine(rest) } }
                return
            }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                DispatchQueue.main.async { onLine(line) }
            }
        }
    }

    private func didExit(_ proc: Process, status: Int32) {
        // Only the process this runner is on: an older one closed and replaced by a relaunch is not news.
        guard let current = process, current === proc else { return }
        isRunning = false; process = nil; stdin = nil
        let msg = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = Failure(message: msg.isEmpty ? "\(kind.binaryName) exited with status \(status)" : String(msg.suffix(600)))
        if status != 0 {
            DebugLog.event("\(kind.binaryName)-crash", ["status": Int(status), "stderr": String(msg.suffix(600)), "pending": pending.count])
            // A copy that dies before saying ready cannot work at all; one that dies later gets a second chance.
            if kind == .codemax, let binary { CodemaxUpdater.shared.noteFailure(binary: binary, status: status, startedOK: version != nil, detail: msg) }
        }
        for (_, c) in pending { c.resume(throwing: err) }
        pending.removeAll()
        if status != 0 { onEvent?(.error(kind: "crashed", message: err.message)) }
    }

    private func handle(line: String) {
        log("<", line)
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = obj["id"] as? Int, let c = pending.removeValue(forKey: id) {
            if let e = obj["error"] as? String { c.resume(throwing: Failure(message: e)) } else { c.resume(returning: obj) }
            return
        }
        guard let event = obj["event"] as? String else { return }
        switch event {
        case "ready": version = obj["version"] as? String
        case "text_delta": if let t = obj["text"] as? String { onEvent?(.text(t)) }
        case "tool_call":
            onEvent?(.toolCall(id: obj["id"] as? String ?? "", title: obj["title"] as? String ?? "tool", input: Self.json(obj["input"])))
        case "tool_update":
            onEvent?(.toolUpdate(id: obj["id"] as? String ?? "", title: obj["title"] as? String, status: obj["status"] as? String,
                                 output: (obj["output"] as? String) ?? (obj["detail"] as? String)))
        case "permission_auto":
            onEvent?(.permissionAuto(title: obj["title"] as? String ?? "", decision: obj["decision"] as? String ?? ""))
        case "handoff":
            onEvent?(.handoff(from: obj["from"] as? String ?? "", to: obj["to"] as? String ?? "", reason: obj["reason"] as? String ?? ""))
        case "error":
            onEvent?(.error(kind: obj["kind"] as? String ?? "other", message: obj["message"] as? String ?? "error"))
        case "notice":
            if (obj["level"] as? String) == "error", let t = obj["title"] as? String { onEvent?(.notice(t)) }
        case "usage":
            onEvent?(.usage(input: obj["inputTokens"] as? Int, output: obj["outputTokens"] as? Int, cost: obj["costUsd"] as? Double))
        default: break
        }
    }

    private static func json(_ v: Any?) -> String {
        guard let v, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return "" }
        let s = String(decoding: d, as: UTF8.self)
        return s == "{}" ? "" : s
    }

    private func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard isRunning, let stdin else { throw Failure(message: "\(kind.binaryName) is not running") }
        let id = nextID; nextID += 1
        var msg: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { msg["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: msg) + Data([0x0A])
        log(">", String(decoding: data, as: UTF8.self))
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            do { try stdin.write(contentsOf: data) } catch { pending[id] = nil; c.resume(throwing: error) }
        }
    }

    private func notify(_ method: String) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: ["method": method]) else { return }
        try? stdin.write(contentsOf: data + Data([0x0A]))
    }

    private static func models(_ v: Any?) -> [ModelInfo] {
        (v as? [[String: Any]] ?? []).compactMap { m in (m["id"] as? String).map { ModelInfo(id: $0, name: m["name"] as? String ?? $0) } }
    }
    private static func startInfo(_ r: [String: Any]) -> StartInfo {
        StartInfo(agent: r["agent"] as? String ?? "", name: r["name"] as? String ?? "", version: r["version"] as? String,
                  model: r["model"] as? String, session: r["session"] as? String, provider: r["provider"] as? String, models: models(r["models"]))
    }
    private static func providers(_ v: Any?) -> [ProviderInfo] {
        (v as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            let env = p["keyEnv"] as? String ?? ""
            let slot = KeychainStore.envNames.first { $0.value == env }?.key ?? "anthropic"
            return ProviderInfo(id: id, name: p["name"] as? String ?? id, keySlot: slot, keyEnv: env, keyOptional: p["keyOptional"] as? Bool ?? false,
                                defaultModel: p["defaultModel"] as? String, models: models(p["models"]),
                                needsClaude: p["needsClaude"] as? Bool ?? false, hasClaude: p["hasClaude"] as? Bool ?? true)
        }
    }

    /// `api`: for the `api` agent, `{provider, model, keys}` (codemax's `configure.api`).
    func configure(agent: String, mcpURL: String, token: String, instructions: String, api: [String: Any]? = nil) async throws -> StartInfo {
        let server: [String: Any] = ["name": "editmax", "source": "editmax",
                                     "transport": ["type": "http", "url": mcpURL, "headers": ["Authorization": "Bearer \(token)"]]]
        var params: [String: Any] = ["agent": agent, "cwd": Self.workDirectory.path, "instructions": instructions, "mcp": [server]]
        if let api { params["api"] = api }
        else { params["web"] = true }   // the agent may search and read the web (current trends), still nothing on this Mac (codemax serve)
        let r = try await request("configure", params)
        return Self.startInfo(r["result"] as? [String: Any] ?? [:])
    }

    func agents() async throws -> [AgentInfo] {
        let r = try await request("agents")
        return (r["result"] as? [[String: Any]] ?? []).map {
            AgentInfo(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", installed: $0["installed"] as? Bool ?? false,
                      version: $0["version"] as? String, problem: $0["problem"] as? String, providers: Self.providers($0["providers"]))
        }
    }

    func prompt(_ text: String) async throws -> TurnResult {
        let res = (try await request("prompt", ["text": text]))["result"] as? [String: Any] ?? [:]
        return TurnResult(stopReason: res["stopReason"] as? String ?? "end_turn", error: res["error"] as? String, agent: res["agent"] as? String ?? "")
    }

    func switchAgent(_ id: String, api: [String: Any]? = nil) async throws -> StartInfo {
        var params: [String: Any] = ["agent": id]
        if let api { params["api"] = api }
        return Self.startInfo((try await request("switch", params))["result"] as? [String: Any] ?? [:])
    }

    /// The API sidecar's providers and what each needs; `keys` are the slots the app has (so `hasKey` is right).
    func providers(keys: [String: String]) async throws -> [ProviderInfo] {
        Self.providers((try await request("providers", ["keys": keys]))["result"])
    }

    func cancel() { notify("cancel") }

    /// Ends the session; codemax stops the agent (and whatever it started) on the way out.
    func close() {
        notify("close")
        let p = process
        process = nil; stdin = nil; isRunning = false
        for (_, c) in pending { c.resume(throwing: Failure(message: "closed")) }
        pending.removeAll()
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if p?.isRunning == true { p?.terminate() } }
    }
}
