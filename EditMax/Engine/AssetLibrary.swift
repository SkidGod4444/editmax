import Foundation
import AppKit
import UniformTypeIdentifiers
import CryptoKit

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
    /// For a copy (drawer, Downloads, a drop on Assets): the file it was copied from, so the same file is not copied twice.
    var original: String? = nil

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

@MainActor
final class AssetLibrary: ObservableObject {
    static let shared = AssetLibrary()

    /// Newest first.
    @Published private(set) var all: [LibraryItem] = []

    /// The index. Under XCTest it lives in a temporary folder, so a test run never writes to the user's library.
    static var indexURL = AppDelegate.isTesting
        ? testingDirectory.appendingPathComponent("library.json")
        : MCPService.configDirectory.appendingPathComponent("library.json")
    /// Where copies go instead of `storeDirectory`'s default (tests); a temporary folder under XCTest.
    static var storeOverride: URL? = AppDelegate.isTesting ? testingDirectory.appendingPathComponent("Assets", isDirectory: true) : nil
    /// Where copied files (drawer drops, downloads, drops on Assets) go: next to the projects.
    static var storeDirectory: URL { storeOverride ?? ProjectLibrary.directory.appendingPathComponent("Assets", isDirectory: true) }
    private static var testingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("EditMaxTests-library-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    /// A project's key in `usedIn`, derived from its file path (Home keys projects by path too), so a project gets the
    /// same key every time it opens; a document's own `id` is new on every open.
    static func projectID(for url: URL) -> UUID {
        let d = Array(SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

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
        for u in urls { deleted.remove(u.standardizedFileURL.path) }   // added again on purpose: no longer deleted
        for src in urls {
            guard let kind = Self.kind(of: src) else { failures.append("\(src.lastPathComponent): not a video, audio, image or font file"); continue }
            let from = src.standardizedFileURL
            // Already in the library, at this path or as a copy of it: returned as it is, never copied a second time.
            if let existing = all.first(where: { ($0.path == from.path || $0.original == from.path) && $0.exists }) { out.append(existing); continue }
            guard FileManager.default.fileExists(atPath: from.path) else { failures.append("\(src.lastPathComponent): file not found"); continue }
            // A font that arrives to be kept (the drawer, Downloads, a drop on Assets) is installed, not only stored: the
            // font library copies it into its fonts folder, registers it and adds that copy here, so it is in the Font
            // picker straight away (FontLibrary.addFontFiles).
            if kind == .font, copy {
                let r = await FontLibrary.shared.addFontFiles([from])
                failures += r.failures
                for path in r.files {
                    guard let i = all.firstIndex(where: { $0.path == path }) else { continue }
                    if all[i].original == nil { all[i].original = from.path; all[i].source = source }
                    out.append(all[i])
                }
                continue
            }
            var url = from
            if copy {
                do { url = try Self.copyIntoStore(url) } catch { failures.append("\(src.lastPathComponent): \(error.localizedDescription)"); continue }
            }
            if let existing = all.first(where: { $0.path == url.path }) { out.append(existing); continue }
            var item = LibraryItem(name: url.lastPathComponent, path: url.path, kind: kind, source: source)
            if url != from { item.original = from.path }
            if kind != .font {
                do {
                    let a = try await MediaImporter.probe(url)
                    item.kind = a.kind == .audio ? .audio : a.kind == .image ? .image : .video   // a sound-only .mp4 is audio
                    item.duration = a.kind == .image ? nil : a.duration
                    item.width = a.width; item.height = a.height; item.bookmark = a.bookmark
                } catch {
                    if url != from { try? FileManager.default.removeItem(at: url) }   // our copy of a file that cannot be read
                    failures.append("\(src.lastPathComponent): \(error.localizedDescription)"); continue
                }
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
    /// `explicit` for an import the user just made: a file deleted from Assets earlier comes back. An open or a save
    /// (`syncUse`) never brings back a deleted file.
    func noteUsed(_ assets: [Asset], projectID: UUID, projectName: String, explicit: Bool = false) {
        var changed = false
        let now = Date()
        if explicit { for a in assets where deleted.remove(a.path) != nil { changed = true } }
        for a in assets where a.kind != .sequence && !deleted.contains(a.path) {
            let kind: LibraryItem.Kind = a.kind == .video ? .video : a.kind == .audio ? .audio : .image
            if let i = all.firstIndex(where: { $0.path == a.path }) {
                if all[i].usedIn[projectID.uuidString] != projectName { all[i].usedIn[projectID.uuidString] = projectName; changed = true }
                if all[i].lastUsed.map({ now.timeIntervalSince($0) > 60 }) ?? true { all[i].lastUsed = now; changed = true }
            } else if Self.isThere(a.path) {   // a project never lists a file that is gone
                all.insert(LibraryItem(name: a.name, path: a.path, bookmark: a.bookmark, kind: kind,
                                       duration: a.kind == .image ? nil : a.duration, width: a.width, height: a.height,
                                       source: .project, usedIn: [projectID.uuidString: projectName], lastUsed: now), at: 0)
                changed = true
            }
        }
        if changed { save() }
    }

    /// Adds project assets the library does not have yet (referenced in place) without recording a project: an import
    /// into a project that has no file yet.
    func register(_ assets: [Asset]) {
        var changed = false
        for a in assets where deleted.remove(a.path) != nil { changed = true }   // only called for an import
        for a in assets where a.kind != .sequence && !all.contains(where: { $0.path == a.path }) && Self.isThere(a.path) {
            let kind: LibraryItem.Kind = a.kind == .video ? .video : a.kind == .audio ? .audio : .image
            all.insert(LibraryItem(name: a.name, path: a.path, bookmark: a.bookmark, kind: kind, duration: a.kind == .image ? nil : a.duration,
                                   width: a.width, height: a.height, source: .project), at: 0)
            changed = true
        }
        if changed { save() }
    }

    /// What a project uses now, after an open or a save: records every asset (`noteUsed`) and takes the project off the
    /// items it no longer uses (an asset removed, relinked or consolidated elsewhere). Fonts are left alone; they are
    /// not project assets.
    func syncUse(_ assets: [Asset], projectID: UUID, projectName: String) {
        noteUsed(assets, projectID: projectID, projectName: projectName)
        let key = projectID.uuidString
        let paths = Set(assets.map(\.path))
        var changed = false
        for i in all.indices where all[i].kind != .font && all[i].usedIn[key] != nil && !paths.contains(all[i].path) {
            all[i].usedIn.removeValue(forKey: key); changed = true
        }
        if changed { save() }
    }

    /// A project that is gone (moved to the Trash, renamed): no item says it is used there any more.
    func forgetProject(_ projectID: UUID) {
        let key = projectID.uuidString
        var changed = false
        for i in all.indices where all[i].usedIn[key] != nil { all[i].usedIn.removeValue(forKey: key); changed = true }
        if changed { save() }
    }

    /// Items, newest first, optionally of one kind and matching `search` (name, any case).
    func items(kind: LibraryItem.Kind? = nil, search: String? = nil) -> [LibraryItem] {
        let q = search?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return all.filter { (kind == nil || $0.kind == kind) && (q.isEmpty || $0.name.lowercased().contains(q)) }
    }

    /// Deletes items from Assets for good (the user's choice: "delete it anyway, projects lose that media"). EditMax's
    /// own copy goes to EditMax's Archive even when a project still uses it (that project shows the file as missing); a
    /// file referenced where the user keeps it stays there. Either way no project puts the item back by opening or
    /// saving; adding or importing the file again does.
    func remove(_ ids: Set<UUID>) {
        for item in all where ids.contains(item.id) {
            if isCopy(item), FileManager.default.fileExists(atPath: item.path) {
                do { try AppArchive.shared.archive(item.url, kind: .asset, item: item) }
                catch { DebugLog.event("library-archive-failed", ["name": item.name, "error": error.localizedDescription]) }
            }
            deleted.insert(item.path)
        }
        all.removeAll { ids.contains($0.id) }
        save()
    }

    /// An item put back from the Archive, at the path it went back to: listed again (with its source and the projects
    /// that used it) and no longer counted as deleted.
    func restore(_ item: LibraryItem, from original: String) {
        deleted.remove(original); deleted.remove(item.path)
        if !all.contains(where: { $0.path == item.path }) { all.insert(item, at: 0) }
        save()
    }

    /// Takes items whose file is gone (deleted in the Finder, or deleted before) off the list. A file on a drive that is
    /// not connected stays, shown as missing, since it comes back when the drive does. Run at launch and whenever an
    /// Assets list appears. Returns how many went.
    @discardableResult
    func pruneMissing() -> Int {
        let gone = all.filter { !$0.exists && !Self.onDisconnectedDrive($0.path) }
        guard !gone.isEmpty else { return 0 }
        let ids = Set(gone.map(\.id))
        all.removeAll { ids.contains($0.id) }
        save()
        DebugLog.event("library-prune-missing", ["count": gone.count])
        return gone.count
    }

    /// On disk, or on a drive that is not connected now (it comes back with the drive).
    nonisolated static func isThere(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) || onDisconnectedDrive(path) }

    /// A path on an external drive (/Volumes/<name>/…) that is not mounted now.
    nonisolated static func onDisconnectedDrive(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents   // ["/", "Volumes", "<name>", …]
        guard parts.count > 3, parts[1] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
    }

    /// Paths deleted from Assets: an open or a save of a project that still uses one does not bring it back.
    private(set) var deleted: Set<String> = []
    private static var deletedURL: URL { indexURL.deletingPathExtension().appendingPathExtension("deleted.json") }

    /// True for a file EditMax copied into its Assets folder (as opposed to one referenced where the user keeps it).
    func isCopy(_ item: LibraryItem) -> Bool { item.path.hasPrefix(Self.storeDirectory.standardizedFileURL.path + "/") }

    /// `add`, plus what it did in words for a confirmation ("Added 2 files to Assets").
    func addFiles(_ urls: [URL], source: LibraryItem.Source, copy: Bool) async -> LibraryAddResult {
        let before = Set(all.map(\.id))
        let r = await add(urls: urls, source: source, copy: copy)
        return LibraryAddResult(added: r.items.filter { !before.contains($0.id) }, existing: r.items.filter { before.contains($0.id) }, failures: r.failures)
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
        deleted = (try? Data(contentsOf: Self.deletedURL)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
        guard let data = try? Data(contentsOf: Self.indexURL),
              let items = try? JSONDecoder.iso.decode([LibraryItem].self, from: data) else { all = []; return }
        all = items
        pruneMissing()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso.encode(all).write(to: Self.indexURL, options: .atomic)
            try JSONEncoder().encode(deleted).write(to: Self.deletedURL, options: .atomic)
        } catch { DebugLog.event("library-save-failed", ["error": error.localizedDescription]) }
    }
}

/// What one add did: new items, items that were already there, and the files that were skipped (with why).
struct LibraryAddResult {
    var added: [LibraryItem]
    var existing: [LibraryItem]
    var failures: [String]

    /// One short line for the drawer and the Assets section.
    var message: String {
        if added.isEmpty && existing.isEmpty {
            return failures.count == 1 ? "Could not add \(failures[0])" : failures.isEmpty ? "Nothing to add" : "Could not add \(failures.count) files"
        }
        var s = added.isEmpty ? (existing.count == 1 ? "Already in Assets" : "All \(existing.count) are already in Assets")
                              : "Added \(added.count) file\(added.count == 1 ? "" : "s") to Assets"
        if !failures.isEmpty { s += ". \(failures.count) could not be added" }
        return s
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
}
