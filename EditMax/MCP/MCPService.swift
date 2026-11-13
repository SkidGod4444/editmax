import Foundation
import Combine
import MCP
import Logging

/// Hosts the local MCP endpoint that lets any MCP client (Claude Code, Codex, Cursor, Claude Desktop) drive the editor.
/// Loopback only, bearer token required, token never appears in the URL.
@MainActor
final class MCPService: ObservableObject {
    static let shared = MCPService()

    enum Status: Equatable { case stopped, running(port: UInt16), failed(String) }
    @Published private(set) var status: Status = .stopped
    @Published private(set) var requestCount = 0
    @Published private(set) var lastClient: String?

    let token: String
    var port: UInt16 { UInt16(UserDefaults.standard.integer(forKey: "mcpPort")).nonZero ?? 19790 }

    private var server: Server?
    private var transport: StatelessHTTPServerTransport?
    private var listener: HTTPListener?

    private init() {
        if let t = UserDefaults.standard.string(forKey: "mcpToken"), t.count >= 32 {
            token = t
        } else {
            var bytes = [UInt8](repeating: 0, count: 24)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            token = bytes.map { String(format: "%02x", $0) }.joined()
            UserDefaults.standard.set(token, forKey: "mcpToken")
        }
    }

    var url: String { "http://127.0.0.1:\(port)/mcp" }

    static let instructions = """
    EditMax is a native macOS video editor. You are editing a real timeline the user can see.
    Workflow: call inspect_timeline first, then make edits with the clip/text tools, then inspect again to confirm.
    IDs are 8-character prefixes shown by inspect_timeline and list_assets. Times are seconds on the timeline.
    Every edit you make is recorded as a named snapshot; the user can restore any of them, and so can you with restore_snapshot.
    Media must already exist on this Mac; import it by absolute path with import_media before inserting clips.
    The user may have installed skills (playbooks for a kind of editing job): list_skills names them, read_skill loads one. Read a matching skill before you start.
    """

    func start() {
        guard case .stopped = status else { return }
        let server = Server(
            name: "EditMax", version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            title: "EditMax Video Editor", instructions: Self.instructions,
            capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
        let transport = StatelessHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ]))
        let token = self.token
        let listener = HTTPListener { [weak self] request in
            // Bearer auth before anything touches the transport.
            let auth = request.header("Authorization") ?? ""
            guard auth == "Bearer \(token)" else {
                return .error(statusCode: 401, .invalidRequest("Unauthorized: missing or invalid bearer token"),
                              extraHeaders: ["WWW-Authenticate": "Bearer realm=\"EditMax\""])
            }
            guard request.path == "/mcp" || request.path == "/mcp/" else {
                return .error(statusCode: 404, .invalidRequest("Not found; use /mcp"))
            }
            let response = await transport.handleRequest(request)
            await MainActor.run { self?.requestCount += 1 }
            return response
        }
        Task {
            await EditMaxTools.register(on: server)
            do {
                try await server.start(transport: transport) { [weak self] client, _ in
                    await MainActor.run { self?.lastClient = "\(client.name) \(client.version)" }
                }
                // The stateless transport serves many independent clients, but the SDK's default handler
                // rejects every `initialize` after the first. Replace it with one that always answers.
                let info = Server.Info(name: "EditMax", version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                let caps = await server.capabilities
                await server.withMethodHandler(Initialize.self) { [weak self] params in
                    let client = params.clientInfo
                    await MainActor.run { self?.lastClient = "\(client.name) \(client.version)" }
                    let version = Version.supported.contains(params.protocolVersion) ? params.protocolVersion : Version.latest
                    return Initialize.Result(protocolVersion: version, capabilities: caps, serverInfo: info, instructions: Self.instructions)
                }
                try listener.start(port: port)
                self.server = server; self.transport = transport; self.listener = listener
                status = .running(port: port)
                DebugLog.event("mcp-start", ["port": Int(port)])
                writeClientConfig()
            } catch {
                status = .failed(error.localizedDescription)
                DebugLog.error("mcp-failed", error)
            }
        }
    }

    func stop() {
        listener?.stop(); listener = nil
        let s = server; server = nil; transport = nil
        Task { await s?.stop() }
        status = .stopped
    }

    // MARK: Client configuration helpers

    static var configDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Written on start so scripts and agents can discover the endpoint without reading the window.
    private func writeClientConfig() {
        let cfg: [String: Any] = ["url": url, "headers": ["Authorization": "Bearer \(token)"], "transport": "http"]
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            let file = Self.configDirectory.appendingPathComponent("mcp.json")
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    var claudeCodeCommand: String {
        "claude mcp add --transport http editmax \(url) --header \"Authorization: Bearer \(token)\""
    }
    var codexCommand: String {
        "codex mcp add editmax --url \(url) --bearer-token \(token)"
    }
    var genericJSON: String {
        """
        {
          "mcpServers": {
            "editmax": {
              "type": "http",
              "url": "\(url)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }
}

private extension UInt16 { var nonZero: UInt16? { self == 0 ? nil : self } }
