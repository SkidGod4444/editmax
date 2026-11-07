import AppKit

/// EditMax's own archive, for files that would otherwise be lost: EditMax's copy of an Assets item, a project deleted
/// from Home, an installed font, a saved template. They are moved here instead of the Mac's Trash, can be put back from
/// Home ▸ Archive (also Window ▸ Archive) until they are erased for good, once they have been here longer than the period
/// set in Settings ▸ General (30 days unless changed). That check runs at launch, about every hour in the background,
/// and whenever the period changes. Timeline items (clips, text, markers) are not files: ⌘Z and History bring them back.
@MainActor
final class AppArchive: ObservableObject {
    static let shared = AppArchive()

    struct Entry: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case asset, project, font, template, export, file
            var label: String { switch self { case .asset: "Assets"; case .project: "Project"; case .font: "Font"; case .template: "Template"; case .export: "Replaced export"; case .file: "File" } }
            var symbol: String { switch self { case .asset: "photo.on.rectangle"; case .project: "film"; case .font: "textformat"; case .template: "doc.on.doc"; case .export: "square.and.arrow.up"; case .file: "doc" } }
        }
        var id = UUID()
        var kind: Kind? = .file
        /// What the user knows it as (the file name, a project or font family), and where it was before it was deleted.
        var name: String
        var original: String
        /// Where it is now, inside the archive.
        var path: String
        var archivedAt: Date
        var bytes: Int64
        /// For an Assets item: the item as it was (source, the projects that used it), so Restore lists it as before.
        var item: LibraryItem? = nil
        /// For a font: its Assets items (a family can be several files), listed again on Restore.
        var items: [LibraryItem]? = nil
        var fileName: String { URL(fileURLWithPath: original).lastPathComponent }
    }

    @Published private(set) var entries: [Entry] = []

    /// The periods Settings offers, in days.
    static let periods = [1, 7, 14, 30, 60, 90]
    static let defaultDays = 30

    /// Inside the projects folder, so moving a file in is a rename on the same disk (no copy of a large video). Home lists
    /// only projects at that folder's top level, so nothing in here shows up there. Tests use a temporary folder.
    static var directoryOverride: URL?
    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        if AppDelegate.isTesting { return FileManager.default.temporaryDirectory.appendingPathComponent("EditMaxTestArchive", isDirectory: true) }
        return ProjectLibrary.directory.appendingPathComponent("Archive", isDirectory: true)
    }
    private static var manifestURL: URL { directory.appendingPathComponent(".archive.json") }

    private var scheduler: NSBackgroundActivityScheduler?
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private init() { load() }

    func load() {
        entries = (try? Data(contentsOf: Self.manifestURL)).flatMap { try? Self.decoder.decode([Entry].self, from: $0) } ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: Self.manifestURL, options: .atomic)
        } catch { DebugLog.event("archive-save-failed", ["error": error.localizedDescription]) }
    }

    var retentionDays: Int { max(1, AppSettings.shared.archiveDays) }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    /// Moves a file or folder into the archive and returns where it went ("Clip.mp4", then "Clip 2.mp4" for a second
    /// file of that name). Throws when it cannot be moved; the caller says why.
    @discardableResult
    func archive(_ url: URL, kind: Entry.Kind = .file, name: String? = nil, item: LibraryItem? = nil, items: [LibraryItem]? = nil, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var dest = Self.directory.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = Self.directory.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        try fm.moveItem(at: url, to: dest)
        entries.append(Entry(kind: kind, name: name ?? url.lastPathComponent, original: url.path, path: dest.path, archivedAt: now, bytes: Self.size(of: dest), item: item, items: items))
        save()
        DebugLog.event("archive-add", ["name": url.lastPathComponent])
        return dest
    }

    /// Erases for good everything that has been here longer than the period; forgets entries whose file is already
    /// gone (emptied by hand in the Finder). Returns how many were erased.
    @discardableResult
    func purge(now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return erase { $0.archivedAt <= cutoff }
    }

    /// How many items a period of `days` would erase at once (Settings asks before a shorter period erases anything).
    func wouldErase(days: Int, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400)
        return entries.filter { $0.archivedAt <= cutoff && FileManager.default.fileExists(atPath: $0.path) }.count
    }

    /// Before an export writes over a file that is already there (the save panel's Replace, or an agent's path): the
    /// old file goes to the Archive instead of being erased, so an earlier render can be restored. Returns its entry.
    /// Under XCTest only when a test points the Archive at its own folder.
    @discardableResult
    func keepBeforeReplacing(_ url: URL) -> UUID? {
        guard FileManager.default.fileExists(atPath: url.path), !AppDelegate.isTesting || Self.directoryOverride != nil else { return nil }
        do { try archive(url, kind: .export); return entries.last?.id }
        catch { DebugLog.event("archive-replaced-failed", ["name": url.lastPathComponent, "error": error.localizedDescription]); return nil }
    }

    /// Erases everything now (Empty Archive).
    @discardableResult
    func emptyNow() -> Int { erase { _ in true } }

    /// Erases one item for good now.
    func erase(_ id: UUID) { _ = erase { $0.id == id } }

    /// Days until an item is erased for good (0 = at the next check).
    func daysLeft(_ e: Entry, now: Date = Date()) -> Int {
        max(0, Int((e.archivedAt.addingTimeInterval(Double(retentionDays) * 86_400).timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    /// Puts an item back where it was ("name 2" beside it when something else took that name since) and back where the
    /// user finds it: an Assets item in Assets, a project on Home, a font in the Font picker. Returns where it went.
    @discardableResult
    func restore(_ id: UUID) throws -> URL {
        guard let e = entries.first(where: { $0.id == id }) else { throw EditError.notFound("archived item \(id.short)") }
        let fm = FileManager.default
        guard fm.fileExists(atPath: e.path) else {
            entries.removeAll { $0.id == id }; save()
            throw EditError.invalid("\(e.name) is no longer in the Archive folder (it was removed in the Finder)")
        }
        let original = URL(fileURLWithPath: e.original)
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        var dest = original
        let base = original.deletingPathExtension().lastPathComponent, ext = original.pathExtension
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = original.deletingLastPathComponent().appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        try fm.moveItem(at: URL(fileURLWithPath: e.path), to: dest)
        entries.removeAll { $0.id == id }
        save()
        switch e.kind ?? .file {
        case .asset:
            if var item = e.item { item.path = dest.path; AssetLibrary.shared.restore(item, from: e.original) }
            else { Task { _ = await AssetLibrary.shared.add(urls: [dest], source: .drawer, copy: false) } }
        case .project: ProjectLibrary.shared.refresh()
        case .font:
            FontLibrary.shared.restored(at: dest)   // registered again, so titles draw with it now
            for var it in e.items ?? [] {
                let was = it.path
                if was.hasPrefix(e.original) { it.path = dest.path + was.dropFirst(e.original.count) }
                AssetLibrary.shared.restore(it, from: was)
            }
        case .template, .export, .file: break
        }
        DebugLog.event("archive-restore", ["name": e.fileName, "kind": (e.kind ?? .file).rawValue])
        return dest
    }

    /// For an MCP call: an item by id prefix, or by name when only one has it.
    func entry(matching key: String) throws -> Entry {
        let k = key.lowercased()
        if let e = entries.first(where: { $0.id.uuidString.lowercased().hasPrefix(k) }) { return e }
        let named = entries.filter { $0.name.lowercased() == k || $0.fileName.lowercased() == k }
        if named.count == 1 { return named[0] }
        throw EditError.notFound(named.isEmpty ? "'\(key)' in the Archive; list_archive lists what is there" : "'\(key)' names \(named.count) archived items; use an id")
    }

    private func erase(where due: (Entry) -> Bool) -> Int {
        let fm = FileManager.default
        var erased = 0
        let before = entries.count
        entries.removeAll { e in
            guard fm.fileExists(atPath: e.path) else { return true }
            guard due(e) else { return false }
            do { try fm.removeItem(atPath: e.path); erased += 1; return true }
            catch { DebugLog.event("archive-erase-failed", ["name": e.name, "error": error.localizedDescription]); return false }
        }
        if entries.count != before { save() }
        if erased > 0 { DebugLog.event("archive-purge", ["erased": erased, "days": retentionDays]) }
        return erased
    }

    /// A check at launch, then about every hour while EditMax runs, at a moment macOS picks (it batches background
    /// work to save power). Never under XCTest.
    func startWatching() {
        guard !AppDelegate.isTesting, scheduler == nil else { return }
        load()
        purge()
        let s = NSBackgroundActivityScheduler(identifier: "io.openhorizon.editmax.archive-purge")
        s.repeats = true
        s.interval = 3600
        s.tolerance = 600
        s.qualityOfService = .utility
        s.schedule { done in
            Task { @MainActor in
                AppArchive.shared.purge()
                done(.finished)
            }
        }
        scheduler = s
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Self.directory])
    }

    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        guard (try? url.resourceValues(forKeys: keys).isDirectory) == true else { return Int64((try? url.resourceValues(forKeys: keys).fileSize) ?? 0) }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    /// "Erased after 30 days", for the notes that say where a deleted file goes.
    var periodText: String { retentionDays == 1 ? "1 day" : "\(retentionDays) days" }
}
