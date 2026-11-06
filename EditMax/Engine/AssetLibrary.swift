import Foundation
import AppKit
import UniformTypeIdentifiers

// The Assets library: everything the user has brought into EditMax, across projects. Every file imported into any
// project, everything dropped on the notch drawer or added from Downloads, and every font the user added. Shown in the
// Home window's Assets section and the editor's media panel (Library); the index lives in App Support, so it survives
// projects being deleted.
//
// Files imported into a project stay where they are (the library references them, as the project does). Files that
// arrive through the drawer or from Downloads are COPIED into `<library>/Assets/`, because Downloads gets cleaned.

/// One file in the Assets library.
struct LibraryItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case video, audio, image, font }
    /// How it arrived.
    enum Source: String, Codable { case project, drawer, download, upload }

    var id: UUID = UUID()
    var name: String
    /// Absolute path on disk.
    var path: String
    var bookmark: Data? = nil
    var kind: Kind
    var duration: Double? = nil
    var width: Int? = nil
    var height: Int? = nil
    var added: Date = Date()
    var source: Source
    /// Projects that use it: project id → project name (the name as of the last use).
    var usedIn: [String: String] = [:]
    var lastUsed: Date? = nil

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

@MainActor
final class AssetLibrary: ObservableObject {
    static let shared = AssetLibrary()

    /// Newest first.
    @Published private(set) var all: [LibraryItem] = []

    /// The index. Tests point it somewhere else.
    static var indexURL = MCPService.configDirectory.appendingPathComponent("library.json")
    /// Where copied files (drawer drops, downloads) go: next to the projects.
    static var storeDirectory: URL { ProjectLibrary.directory.appendingPathComponent("Assets", isDirectory: true) }

    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2"]

    private init() { load() }

    /// The kind of file at `url`, or nil when EditMax cannot use it.
    static func kind(of url: URL) -> LibraryItem.Kind? {
        let ext = url.pathExtension.lowercased()
        if fontExtensions.contains(ext) { return .font }
        guard let t = UTType(filenameExtension: ext) else { return nil }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .movie) || t.conforms(to: .audiovisualContent) { return .video }
        return nil
    }

    /// Adds files to the library and returns their items (an item already in the library is returned, not added again).
    /// `copy` copies each file into `storeDirectory` first (drawer drops and downloads); otherwise the original is
    /// referenced. Files EditMax cannot use are skipped; `failures` names them and why.
    @discardableResult
    func add(urls: [URL], source: LibraryItem.Source, copy: Bool) async -> (items: [LibraryItem], failures: [String]) {
        var out: [LibraryItem] = [], failures: [String] = []
        for src in urls {
            guard let kind = Self.kind(of: src) else { failures.append("\(src.lastPathComponent): not a video, audio, image or font file"); continue }
            var url = src.standardizedFileURL
            if copy {
                do { url = try Self.copyIntoStore(url) } catch { failures.append("\(src.lastPathComponent): \(error.localizedDescription)"); continue }
            }
            if let existing = all.first(where: { $0.path == url.path }) { out.append(existing); continue }
            var item = LibraryItem(name: url.lastPathComponent, path: url.path, kind: kind, source: source)
            if kind != .font {
                do {
                    let a = try await MediaImporter.probe(url)
                    item.duration = a.kind == .image ? nil : a.duration
                    item.width = a.width; item.height = a.height; item.bookmark = a.bookmark
                } catch { failures.append("\(src.lastPathComponent): \(error.localizedDescription)"); continue }
            } else {
                item.bookmark = try? url.bookmarkData()
            }
            all.insert(item, at: 0)
            out.append(item)
        }
        if !out.isEmpty { save() }
        return (out, failures)
    }

    /// Records that a project uses these assets (adds any the library does not have yet, referenced in place).
    func noteUsed(_ assets: [Asset], projectID: UUID, projectName: String) {
        var changed = false
        let now = Date()
        for a in assets where a.kind != .sequence {
            let kind: LibraryItem.Kind = a.kind == .video ? .video : a.kind == .audio ? .audio : .image
            if let i = all.firstIndex(where: { $0.path == a.path }) {
                if all[i].usedIn[projectID.uuidString] != projectName { all[i].usedIn[projectID.uuidString] = projectName; changed = true }
                if all[i].lastUsed.map({ now.timeIntervalSince($0) > 60 }) ?? true { all[i].lastUsed = now; changed = true }
            } else {
                all.insert(LibraryItem(name: a.name, path: a.path, bookmark: a.bookmark, kind: kind,
                                       duration: a.kind == .image ? nil : a.duration, width: a.width, height: a.height,
                                       source: .project, usedIn: [projectID.uuidString: projectName], lastUsed: now), at: 0)
                changed = true
            }
        }
        if changed { save() }
    }

    /// Items, newest first, optionally of one kind and matching `search` (name, any case).
    func items(kind: LibraryItem.Kind? = nil, search: String? = nil) -> [LibraryItem] {
        let q = search?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return all.filter { (kind == nil || $0.kind == kind) && (q.isEmpty || $0.name.lowercased().contains(q)) }
    }

    /// Removes items from the library. A copy in `storeDirectory` goes to the Trash; a referenced file is left alone.
    func remove(_ ids: Set<UUID>) {
        let store = Self.storeDirectory.standardizedFileURL.path
        for item in all where ids.contains(item.id) && item.path.hasPrefix(store + "/") {
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
        all.removeAll { ids.contains($0.id) }
        save()
    }

    // MARK: Storage

    private static func copyIntoStore(_ url: URL) throws -> URL {
        let dir = storeDirectory
        if url.path.hasPrefix(dir.standardizedFileURL.path + "/") { return url }   // already ours
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let items = try? JSONDecoder.iso.decode([LibraryItem].self, from: data) else { all = []; return }
        all = items
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso.encode(all).write(to: Self.indexURL, options: .atomic)
        } catch { DebugLog.event("library-save-failed", ["error": error.localizedDescription]) }
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
}
