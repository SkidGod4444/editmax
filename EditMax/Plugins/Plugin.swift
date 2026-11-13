import Foundation

/// A plugin: a folder that gives EditMax's agent more to work with.
/// - Skills: editing playbooks (`skills/<name>/SKILL.md`, or one `SKILL.md` at the root). The agent sees each one's
///   name and description, and reads the text with `read_skill` when a request matches.
/// - MCP servers: more tools (`mcpServers` in the manifest, or `.mcp.json`), handed to the in-app chat next to
///   EditMax's own server.
///
/// The layout is the one Claude Code plugins use (`.claude-plugin/plugin.json`, `skills/`, `.mcp.json`,
/// `${CLAUDE_PLUGIN_ROOT}`), so one of those installs as it is; `plugin.json` at the root is EditMax's own manifest
/// and wins when both are there. docs/internals-plugins.md has the format.
struct Plugin: Identifiable, Equatable {
    struct Skill: Identifiable, Equatable {
        var id: String { name }
        /// What `read_skill` takes: unique across the installed plugins (PluginStore renames a second one).
        var name: String
        let description: String
        /// The folder holding SKILL.md; `read_skill` reads nothing outside it.
        let directory: URL
        let plugin: String
    }

    enum Transport: Equatable {
        case stdio(command: String, args: [String], env: [String: String], cwd: String?)
        case http(url: String, headers: [String: String], sse: Bool)
    }

    struct Server: Identifiable, Equatable {
        var id: String { name }
        /// As the agent sees it (`mcp__<name>__tool`): lower-case letters, digits and hyphens, never "editmax".
        var name: String
        let transport: Transport

        /// One line a person can judge before turning the plugin on: the command this Mac runs, or the address it calls.
        var summary: String {
            switch transport {
            case .stdio(let command, let args, _, _): return ([command] + args).joined(separator: " ")
            case .http(let url, _, _): return url
            }
        }
        var runsLocally: Bool { if case .stdio = transport { return true }; return false }
    }

    /// A value the person supplies (an API key, a folder), written `${KEY}` in a server's command, arguments,
    /// environment, address or headers.
    struct Setting: Identifiable, Equatable {
        var id: String { key }
        let key: String
        var label: String
        var help: String?
        var secret: Bool
        /// `${KEY:-fallback}`: used when nothing is entered.
        var fallback: String?
        var required: Bool { fallback == nil }
    }

    /// The folder's name under the plugins directory, and the plugin's name in every list.
    let id: String
    var name: String
    var version: String
    var summary: String
    var author: String
    var homepage: String?
    let directory: URL
    var skills: [Skill]
    var servers: [Server]
    var settings: [Setting]

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    // MARK: Names

    /// Lower-case letters, digits and hyphens: "Shorts Factory!" → "shorts-factory". Empty when nothing is left.
    static func slug(_ s: String, max: Int = 48) -> String {
        var out = ""
        for u in s.lowercased().unicodeScalars {
            if ("a"..."z").contains(u) || ("0"..."9").contains(u) { out.unicodeScalars.append(u) }
            else if !out.isEmpty, !out.hasSuffix("-") { out += "-" }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > max { out = String(out.prefix(max)); while out.hasSuffix("-") { out.removeLast() } }
        return out
    }

    /// Names a plugin's server may not take: EditMax's own server, whose tools the chat always allows.
    static let reservedServerNames: Set<String> = ["editmax"]

    // MARK: Reading a folder

    /// Reads the plugin in `directory`. Throws when the folder holds neither a skill nor a server.
    static func load(directory: URL, id: String? = nil) throws -> Plugin {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { throw Failure(message: "\(directory.lastPathComponent) is not a folder.") }
        let manifestFile = ["plugin.json", ".claude-plugin/plugin.json"].map { directory.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        var manifest: [String: Any] = [:]
        if let manifestFile {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile))) as? [String: Any] else {
                throw Failure(message: "\(manifestFile.lastPathComponent) in \(directory.lastPathComponent) is not a JSON object.")
            }
            manifest = obj
        }
        let declared = (manifest["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pid = id ?? slug(declared.isEmpty ? directory.lastPathComponent : declared)
        guard !pid.isEmpty else { throw Failure(message: "The plugin needs a name with letters or digits in it.") }
        let author: String = {
            if let a = manifest["author"] as? String { return a }
            return (manifest["author"] as? [String: Any])?["name"] as? String ?? ""
        }()

        let skills = readSkills(in: directory, plugin: pid)
        let servers = try readServers(manifest: manifest, directory: directory)
        guard !skills.isEmpty || !servers.isEmpty else {
            throw Failure(message: "\(directory.lastPathComponent) has no skills (skills/<name>/SKILL.md) and no MCP servers (.mcp.json), so there is nothing to install.")
        }
        // `title` is the name people read ("Shorts Factory"); `name` is the id Claude Code plugins also carry.
        let title = ((manifest["title"] as? String) ?? (manifest["displayName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Plugin(id: pid, name: !title.isEmpty ? title : declared.isEmpty ? directory.lastPathComponent : declared,
                      version: (manifest["version"] as? String) ?? "", summary: (manifest["description"] as? String) ?? "",
                      author: author, homepage: (manifest["homepage"] as? String) ?? (manifest["repository"] as? String),
                      directory: directory, skills: skills, servers: servers, settings: readSettings(manifest: manifest, servers: servers))
    }

    /// `skills/<name>/SKILL.md`, and a `SKILL.md` at the root (a skill folder shared as it is).
    private static func readSkills(in directory: URL, plugin: String) -> [Skill] {
        let fm = FileManager.default
        var out: [Skill] = []
        var seen = Set<String>()
        func add(_ dir: URL, fallback: String) {
            let file = dir.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            let head = frontmatter(text).fields
            var name = slug(head["name"] ?? fallback, max: 64)
            if name.isEmpty { name = slug(fallback, max: 64) }
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            let d = (head["description"] ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            out.append(Skill(name: name, description: String(d.prefix(400)), directory: dir, plugin: plugin))
        }
        let root = directory.appendingPathComponent("skills")
        for n in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() where !n.hasPrefix(".") {
            add(root.appendingPathComponent(n), fallback: n)
        }
        add(directory, fallback: plugin)
        return out
    }

    /// The `---` block at the top of a SKILL.md as `key: value` pairs (a value on the following indented lines, as
    /// YAML's `>` and `|` write it, is joined), and the text after the block.
    static func frontmatter(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([:], text) }
        var fields: [String: String] = [:]
        var key: String?
        for line in lines[1..<end] {
            if let k = key, line.first == " " || line.first == "\t" {
                let more = line.trimmingCharacters(in: .whitespaces)
                if !more.isEmpty { fields[k] = [fields[k] ?? "", more].filter { !$0.isEmpty }.joined(separator: " ") }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { key = nil; continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-", ">+", "|+"].contains(v) { v = "" }
            if v.count >= 2, let f = v.first, let l = v.last, f == l, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
            guard !k.isEmpty, !k.contains(" ") else { key = nil; continue }
            fields[k] = v; key = k
        }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (fields, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The manifest's `mcpServers` (an object, or the name of a JSON file beside it), else `.mcp.json`.
    private static func readServers(manifest: [String: Any], directory: URL) throws -> [Server] {
        func file(_ name: String) -> [String: Any]? {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name)))) as? [String: Any] else { return nil }
            return (obj["mcpServers"] as? [String: Any]) ?? obj
        }
        var entries: [String: Any] = [:]
        if let inline = manifest["mcpServers"] as? [String: Any] { entries = inline }
        else if let path = manifest["mcpServers"] as? String, !path.contains(".."), let f = file(path) { entries = f }
        else if let f = file(".mcp.json") { entries = f }

        var out: [Server] = []
        for key in entries.keys.sorted() {
            guard let e = entries[key] as? [String: Any], (e["disabled"] as? Bool) != true, (e["enabled"] as? Bool) != false else { continue }
            let name = slug(key, max: 40)
            guard !name.isEmpty else { continue }
            if reservedServerNames.contains(name) { throw Failure(message: "A plugin's MCP server cannot be named \"\(name)\": that is EditMax's own server.") }
            guard !out.contains(where: { $0.name == name }) else { continue }
            let strings = { (v: Any?) -> [String: String] in
                var m: [String: String] = [:]
                for (k, x) in (v as? [String: Any]) ?? [:] { if let s = x as? String { m[k] = s } else if let n = x as? NSNumber { m[k] = n.stringValue } }
                return m
            }
            if let url = e["url"] as? String, !url.isEmpty {
                out.append(Server(name: name, transport: .http(url: url, headers: strings(e["headers"]), sse: (e["type"] as? String)?.lowercased() == "sse")))
            } else if let command = e["command"] as? String, !command.isEmpty {
                let args = ((e["args"] as? [Any]) ?? []).map { ($0 as? String) ?? "\($0)" }
                out.append(Server(name: name, transport: .stdio(command: command, args: args, env: strings(e["env"]), cwd: e["cwd"] as? String)))
            }
        }
        return out
    }

    // MARK: Settings (the ${KEY} values)

    /// Placeholders that mean the plugin's own folder, filled in by EditMax.
    static let rootKeys: Set<String> = ["CLAUDE_PLUGIN_ROOT", "EDITMAX_PLUGIN_ROOT"]
    private static let placeholder = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_.]*)(?::-([^}]*))?\}"#)

    /// `${KEY}` and `${KEY:-fallback}` in a string, in order. Claude Code's `${user_config.KEY}` is the same KEY.
    static func placeholders(in s: String) -> [(key: String, fallback: String?)] {
        let ns = s as NSString
        return placeholder.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (settingKey(ns.substring(with: m.range(at: 1))), m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2)))
        }
    }
    private static func settingKey(_ raw: String) -> String { raw.hasPrefix("user_config.") ? String(raw.dropFirst("user_config.".count)) : raw }

    /// Fills the placeholders in `s`. A key with no value and no fallback is left out and reported in `missing`.
    static func fill(_ s: String, values: (String) -> String?, missing: inout [String]) -> String {
        let ns = s as NSString
        var out = "", at = 0
        for m in placeholder.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            at = m.range.location + m.range.length
            let key = settingKey(ns.substring(with: m.range(at: 1)))
            let fallback = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
            if let v = values(key), !v.isEmpty { out += v }
            else if let fallback { out += fallback }
            else if !missing.contains(key) { missing.append(key) }
        }
        return out + ns.substring(from: at)
    }

    private static func strings(of t: Transport) -> [String] {
        switch t {
        case .stdio(let command, let args, let env, let cwd): return [command] + args + env.keys.sorted().map { env[$0]! } + [cwd].compactMap { $0 }
        case .http(let url, let headers, _): return [url] + headers.keys.sorted().map { headers[$0]! }
        }
    }

    /// What the manifest declares (`settings`, or Claude Code's `userConfig`), then every placeholder the servers use
    /// that it did not mention.
    private static func readSettings(manifest: [String: Any], servers: [Server]) -> [Setting] {
        var out: [Setting] = []
        func secretName(_ k: String) -> Bool { k.range(of: "key|token|secret|password|credential", options: [.regularExpression, .caseInsensitive]) != nil }
        for e in (manifest["settings"] as? [[String: Any]]) ?? [] {
            guard let key = e["key"] as? String, !key.isEmpty, !out.contains(where: { $0.key == key }) else { continue }
            out.append(Setting(key: key, label: (e["label"] as? String) ?? key, help: e["help"] as? String,
                               secret: (e["secret"] as? Bool) ?? secretName(key), fallback: (e["required"] as? Bool) == false ? "" : nil))
        }
        for (key, v) in ((manifest["userConfig"] as? [String: Any]) ?? [:]).sorted(by: { $0.key < $1.key }) where !out.contains(where: { $0.key == key }) {
            let e = v as? [String: Any] ?? [:]
            out.append(Setting(key: key, label: (e["title"] as? String) ?? key, help: e["description"] as? String,
                               secret: (e["sensitive"] as? Bool) ?? secretName(key), fallback: (e["required"] as? Bool) == false ? "" : nil))
        }
        for server in servers {
            for s in strings(of: server.transport) {
                for p in placeholders(in: s) where !rootKeys.contains(p.key) {
                    if let i = out.firstIndex(where: { $0.key == p.key }) {
                        if out[i].fallback == nil, let f = p.fallback { out[i].fallback = f }
                    } else {
                        out.append(Setting(key: p.key, label: p.key, help: nil, secret: secretName(p.key), fallback: p.fallback))
                    }
                }
            }
        }
        return out
    }
}
