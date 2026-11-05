import Foundation
import AppKit

/// EditMax's debug log: one JSON line per event in `~/Library/Application Support/EditMax/logs/editmax.log`
/// (what the app did with codemax, the installer and updater, the MCP server, and every error), the same shape
/// as codemax's own `~/.codemax/debug.log`. Secrets are redacted before anything is written. "Export diagnostics"
/// in the Agents tab zips both logs, the codemax protocol log and the versions involved, so a bug report needs no retelling.
enum DebugLog {
    nonisolated static var directory: URL { CodemaxInstaller.supportDirectory.appendingPathComponent("logs") }
    nonisolated static var eventsFile: URL { directory.appendingPathComponent("editmax.log") }
    /// Every line exchanged with `codemax serve` (redacted). It contains the chat itself, so it is only ever read locally or exported by the user.
    nonisolated static var protocolFile: URL {
        ProcessInfo.processInfo.environment["EDITMAX_CODEMAX_LOG"].map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("codemax-protocol.log")
    }
    nonisolated static var codemaxDebugFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codemax/debug.log") }

    private static let queue = DispatchQueue(label: "io.openhorizon.editmax.log", qos: .utility)
    private static let maxBytes = 5 * 1024 * 1024
    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    /// One event. `fields` hold facts (names, counts, versions, error text), never the conversation.
    nonisolated static func event(_ kind: String, _ fields: [String: Any] = [:]) {
        var line: [String: Any] = [:]
        for (k, v) in fields { line[k] = v is String ? redact(v as! String) : v }
        line["ts"] = iso.string(from: Date()); line["kind"] = kind
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        append(data + Data([0x0A]), to: eventsFile)
    }

    nonisolated static func error(_ kind: String, _ error: Error, _ fields: [String: Any] = [:]) {
        var f = fields; f["error"] = String(describing: error).prefix(600).description
        event(kind, f)
    }

    /// A protocol line to (">") or from ("<") codemax, or a note ("!").
    nonisolated static func protocolLine(_ dir: String, _ line: String) {
        append(Data("\(iso.string(from: Date())) \(dir) \(redact(line))\n".utf8), to: protocolFile)
    }

    nonisolated private static func append(_ data: Data, to url: URL) {
        queue.async {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Bounded: past 5 MB the file becomes <name>.1 (one older file kept).
                if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxBytes {
                    let old = url.appendingPathExtension("1")
                    try? fm.removeItem(at: old)
                    try? fm.moveItem(at: url, to: old)
                }
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
                else { try data.write(to: url) }
            } catch { /* the log must never get in the way */ }
        }
    }

    private static let secretPatterns: [NSRegularExpression] = [
        // JSON fields that carry credentials: the MCP bearer token, API keys, and the whole `keys` object.
        try! NSRegularExpression(pattern: #""(token|apiKey|api_key|key|Authorization|authorization)"\s*:\s*"[^"]*""#),
        try! NSRegularExpression(pattern: #""keys"\s*:\s*\{[^}]*\}"#),
        try! NSRegularExpression(pattern: #"Bearer\s+[A-Za-z0-9._\-]+"#),
        // Key shapes: Anthropic/OpenAI "sk-…", Google "AIza…", xAI "xai-…".
        try! NSRegularExpression(pattern: #"\b(sk-[A-Za-z0-9_\-]{8,}|AIza[A-Za-z0-9_\-]{20,}|xai-[A-Za-z0-9_\-]{8,})"#),
    ]
    nonisolated static func redact(_ s: String) -> String {
        var out = s
        for (i, re) in secretPatterns.enumerated() {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: i == 0 ? "\"$1\":\"<redacted>\"" : i == 1 ? "\"keys\":\"<redacted>\"" : i == 2 ? "Bearer <redacted>" : "<redacted>")
        }
        return out
    }

    /// Zips the logs, the codemax debug log and a versions file to `~/Desktop/EditMax-diagnostics-<date>.zip`.
    @MainActor static func exportDiagnostics(versions: [String: String]) throws -> URL {
        let fm = FileManager.default
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; return f.string(from: Date()) }()
        let staging = fm.temporaryDirectory.appendingPathComponent("EditMax-diagnostics-\(stamp)")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for f in [eventsFile, eventsFile.appendingPathExtension("1"), protocolFile, protocolFile.appendingPathExtension("1"), codemaxDebugFile, codemaxDebugFile.appendingPathExtension("1")] where fm.fileExists(atPath: f.path) {
            // The codemax protocol log already is redacted at write time; the others carry no secrets.
            try? fm.copyItem(at: f, to: staging.appendingPathComponent(f.lastPathComponent == "debug.log" || f.lastPathComponent == "debug.log.1" ? "codemax-" + f.lastPathComponent : f.lastPathComponent))
        }
        var info = versions
        info["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
        info["exported"] = iso.string(from: Date())
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: staging.appendingPathComponent("versions.json"))
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let zip = desktop.appendingPathComponent("EditMax-diagnostics-\(stamp).zip")
        try? fm.removeItem(at: zip)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, zip.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "EditMax", code: 1, userInfo: [NSLocalizedDescriptionKey: "ditto failed with status \(p.terminationStatus)"]) }
        try? fm.removeItem(at: staging)
        event("diagnostics-exported", ["path": zip.path])
        return zip
    }

    @MainActor static func reveal() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([eventsFile.path, protocolFile.path].map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }.isEmpty ? [directory] : [eventsFile])
    }
}
