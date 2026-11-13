import Foundation
import CryptoKit

/// The hub: a list of plugins anyone can install from Settings ▸ Plugins. It is a static `index.json` (EditMax's own
/// is `hub/index.json` in the app's repository, written by `scripts/build-hub.py`) that names each plugin's files
/// with their SHA-256, next to the files themselves. Installing downloads those files into a temporary folder,
/// checks every hash, and hands the folder to `PluginStore.stage`, so a hub plugin goes through the same review
/// sheet as one added from disk. People add a plugin of their own with a pull request to `hub/`.
@MainActor
final class PluginHub: ObservableObject {
    static let shared = PluginHub()

    nonisolated static let defaultAddress = "https://raw.githubusercontent.com/SkidGod4444/editmax/main/hub/index.json"
    /// Where a plugin is added to the hub: the hub's folder in the repository, whose README has the steps and the review rules.
    nonisolated static let contributeURL = URL(string: "https://github.com/SkidGod4444/editmax/tree/main/hub")!
    /// Not in Settings: a developer's override (`defaults write io.openhorizon.editmax pluginHubURL <https address>`),
    /// for trying a hub before it is merged.
    nonisolated static let addressKey = "pluginHubURL"
    /// The hub's address: EditMax's, unless the override is set.
    nonisolated static var address: String {
        let custom = (UserDefaults.standard.string(forKey: addressKey) ?? "").trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? defaultAddress : custom
    }

    struct File: Codable, Equatable { var path: String; var sha256: String; var size: Int }
    struct Listing: Codable, Identifiable, Equatable {
        var id: String, name: String, description: String, version: String
        var author: String?
        var tags: [String]?
        /// Skill names and MCP server names, for the row; what is installed is read from the files themselves.
        var skills: [String]?
        var servers: [String]?
        var homepage: String?
        /// The plugin's folder, relative to the index.
        var path: String
        var files: [File]
    }
    struct Index: Codable, Equatable { var name: String?; var plugins: [Listing] }

    typealias Failure = Plugin.Failure

    @Published private(set) var index: Index?
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    /// The address `index` was read from.
    private(set) var loadedFrom: String?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": "EditMax"]
        return URLSession(configuration: c)
    }()

    /// A hub is read over https (or from a file, for a hub on this Mac).
    nonisolated static func url(_ address: String) throws -> URL {
        guard let u = URL(string: address), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "file" else {
            throw Failure(message: "The hub's address must start with https:// (\(address)).")
        }
        return u
    }

    private func data(from url: URL, limit: Int) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure(message: "The hub answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url.lastPathComponent).")
        }
        guard data.count <= limit else { throw Failure(message: "\(url.lastPathComponent) is larger than the hub allows.") }
        return data
    }

    func refresh(address: String = PluginHub.address) async {
        loading = true; defer { loading = false }
        do {
            let d = try await data(from: try Self.url(address), limit: 4 * 1024 * 1024)
            var idx = try JSONDecoder().decode(Index.self, from: d)
            idx.plugins = idx.plugins.filter { !Plugin.slug($0.id).isEmpty && $0.id == Plugin.slug($0.id) }
            index = idx; loadedFrom = address; problem = nil
            DebugLog.event("hub-loaded", ["plugins": idx.plugins.count])
        } catch {
            problem = (error as? Failure)?.message ?? "The hub could not be read: \(error.localizedDescription)"
            DebugLog.error("hub-failed", error)
        }
    }

    /// A path inside a plugin as the hub may name it: plain components, no "..", nothing absolute.
    nonisolated static func safe(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), parts.count <= 12 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p != "." && p != ".." && p.count <= 100 && p.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._- ".unicodeScalars.contains($0) }
        }
    }

    nonisolated static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Downloads a listing's files into a new temporary folder named after the plugin and returns it. Every file is
    /// checked against the index's hash; one mismatch and nothing is kept.
    func download(_ listing: Listing, from address: String? = nil) async throws -> URL {
        let indexURL = try Self.url(address ?? loadedFrom ?? Self.address)
        guard Self.safe(listing.path), !listing.files.isEmpty, listing.files.count <= 500 else { throw Failure(message: "The hub's entry for \(listing.name) is not valid.") }
        guard listing.files.reduce(0, { $0 + max(0, $1.size) }) <= 50 * 1024 * 1024 else { throw Failure(message: "\(listing.name) is over 50 MB, more than the hub allows.") }
        let base = indexURL.deletingLastPathComponent().appendingPathComponent(listing.path, isDirectory: true)
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("EditMax-hub-\(UUID().uuidString)", isDirectory: true).appendingPathComponent(listing.id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for f in listing.files {
                guard Self.safe(f.path) else { throw Failure(message: "The hub names a file outside the plugin (\(f.path)).") }
                let d = try await data(from: base.appendingPathComponent(f.path), limit: 10 * 1024 * 1024)
                guard Self.sha256(d) == f.sha256.lowercased() else { throw Failure(message: "\(f.path) of \(listing.name) does not match the hub's checksum, so nothing was installed.") }
                let to = folder.appendingPathComponent(f.path)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try d.write(to: to)
            }
            return folder
        } catch {
            try? fm.removeItem(at: folder.deletingLastPathComponent())
            throw error
        }
    }

    /// "1.10.0" is newer than "1.9": compared number by number.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }, y = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
