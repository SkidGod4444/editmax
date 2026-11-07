import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import CryptoKit

/// The user's projects: every `.emx` (or older `.editmax`) file in the library folder (`~/Movies/EditMax Projects`, where the Home window
/// creates new ones) plus the recent documents opened from elsewhere. A draft is a library project still named
/// "Untitled…": created from Home and never renamed.
@MainActor
final class ProjectLibrary: ObservableObject {
    static let shared = ProjectLibrary()

    struct Entry: Identifiable, Equatable {
        var url: URL
        var name: String
        var modified: Date
        var width: Int, height: Int, fps: Double
        var clips: Int
        var duration: Double
        var inLibrary: Bool
        var id: String { url.path }
        var isDraft: Bool { inLibrary && name.hasPrefix("Untitled") }
        var stem: String { url.deletingPathExtension().lastPathComponent }
    }

    /// Project files: `.emx` (current) and `.editmax` (before 2026-11-06).
    static let extensions: Set<String> = ["emx", "editmax"]
    static func isProject(_ u: URL) -> Bool { extensions.contains(u.pathExtension.lowercased()) }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var thumbnails: [String: CGImage] = [:]   // keyed by Entry.id
    private var thumbnailsInFlight: Set<String> = []

    static var directory: URL {
        // Settings ▸ General can point the library elsewhere; the default is Movies ▸ EditMax Projects.
        let chosen = UserDefaults.standard.string(forKey: AppSettings.Key.library) ?? ""
        let dir = chosen.isEmpty ? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax Projects")
                                 : URL(fileURLWithPath: chosen)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var thumbnailDirectory: URL {
        let dir = CodemaxInstaller.supportDirectory.appendingPathComponent("home-thumbs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Rescans the library folder and the recent documents. Cheap enough to call whenever Home appears.
    func refresh() {
        let fm = FileManager.default
        let library = Self.directory
        var urls = ((try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { Self.isProject($0) }
        for r in NSDocumentController.shared.recentDocumentURLs where Self.isProject(r) && fm.fileExists(atPath: r.path) && !urls.contains(where: { $0.standardizedFileURL == r.standardizedFileURL }) {
            urls.append(r)
        }
        var out: [Entry] = []
        for u in urls {
            guard let data = try? Data(contentsOf: u), let p = try? EditMaxDocument.decoder.decode(Project.self, from: data) else { continue }
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            out.append(Entry(url: u, name: u.deletingPathExtension().lastPathComponent, modified: mod, width: p.settings.width, height: p.settings.height, fps: p.settings.fps,
                             clips: p.allClips.count, duration: p.duration, inLibrary: u.deletingLastPathComponent().standardizedFileURL == library.standardizedFileURL))
            requestThumbnail(for: u, project: p, modified: mod)
        }
        entries = out.sorted { $0.modified > $1.modified }
        DebugLog.event("library-refresh", ["projects": out.count])
    }

    /// Creates `Untitled N.emx` (or `name`) in the library with the template's frame, and returns its URL.
    func create(name: String? = nil, template: Templates.Info) throws -> URL {
        let fm = FileManager.default
        var stem = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stem.isEmpty {
            var n = 1
            while Self.extensions.contains(where: { fm.fileExists(atPath: Self.directory.appendingPathComponent("Untitled \(n).\($0)").path) }) { n += 1 }
            stem = "Untitled \(n)"
        }
        let url = Self.directory.appendingPathComponent(stem + ".emx")
        guard !Self.extensions.contains(where: { fm.fileExists(atPath: Self.directory.appendingPathComponent(stem + "." + $0).path) }) else { throw EditError.invalid("a project named '\(stem)' already exists") }
        var p = try Templates.project(named: template.name)
        p.name = stem
        try EditMaxDocument.encoder.encode(p).write(to: url, options: .atomic)
        DebugLog.event("library-create", ["name": stem, "template": template.name])
        return url
    }

    func open(_ url: URL) {
        DebugLog.event("library-open", ["name": url.deletingPathExtension().lastPathComponent])
        let dc = NSDocumentController.shared
        dc.openDocument(withContentsOf: url, display: true) { _, _, error in
            guard let error else { HomeWindow.shared.hide(); return }   // also when the project was already open
            // "cannot open files of this type": LaunchServices did not map the extension to our type (a stale
            // registration of an older build). Open it by the type's identifier instead of by the extension.
            do {
                let doc = try dc.makeDocument(withContentsOf: url, ofType: UTType.editmaxProject.identifier)
                dc.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
                DebugLog.event("library-open-by-type", ["name": url.lastPathComponent, "reason": error.localizedDescription])
            } catch {
                DebugLog.error("library-open", error, ["name": url.lastPathComponent]); NSAlert(error: error).runModal()
            }
        }
    }

    /// To EditMax's Archive, erased for good after the period in Settings ▸ General.
    func trash(_ entry: Entry) throws {
        try AppArchive.shared.archive(entry.url, kind: .project, name: entry.name)
        AssetLibrary.shared.forgetProject(AssetLibrary.projectID(for: entry.url))   // Assets no longer says "Used in" it
        DebugLog.event("library-trash", ["name": entry.name])
        refresh()
    }

    // MARK: Thumbnails

    /// The first picture on the timeline (earliest clip on a visible video track), at its source in-point, cached as a
    /// JPEG keyed by the project's path and modification date.
    private func requestThumbnail(for url: URL, project p: Project, modified: Date) {
        let id = url.path
        guard !thumbnailsInFlight.contains(id) else { return }
        let key = Insecure.SHA1.hash(data: Data("\(url.path)|\(modified.timeIntervalSince1970)".utf8)).map { String(format: "%02x", $0) }.joined()
        let cached = Self.thumbnailDirectory.appendingPathComponent(key + ".jpg")
        if thumbnails[id] != nil, FileManager.default.fileExists(atPath: cached.path) { return }
        let clips = p.tracks.filter { $0.kind == .video && !$0.isHidden }.flatMap(\.clips).sorted { $0.start < $1.start }
        guard let clip = clips.first(where: { c in p.asset(c.assetID).map { $0.kind == .video || $0.kind == .image } ?? false }), let asset = p.asset(clip.assetID) else { return }
        thumbnailsInFlight.insert(id)
        let src = asset.url, kind = asset.kind, at = clip.sourceIn
        Task.detached(priority: .utility) {
            var image: CGImage?
            if let data = try? Data(contentsOf: cached), let img = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                image = img
            } else {
                image = await Self.poster(url: src, kind: kind, at: at)
                if let image, let rep = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]) { try? rep.write(to: cached) }
            }
            await MainActor.run {
                self.thumbnailsInFlight.remove(id)
                if let image { self.thumbnails[id] = image }
            }
        }
    }

    /// One frame of a video (or the image itself), at most 640 points: Home's project cards and the Assets grid.
    static func poster(url: URL, kind: AssetKind, at seconds: Double) async -> CGImage? {
        if kind == .image { return NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        let asset = AVURLAsset(url: url)
        // No readable video track makes the generator abort the process (an uncatchable ObjC exception), so check first.
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty, (try? await asset.load(.isReadable)) == true else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        return try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}
