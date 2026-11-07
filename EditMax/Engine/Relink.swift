import Foundation
import AVFoundation

// MARK: - Relink and consolidate media
//
// A project points at media by path (plus a bookmark made at import). A file that is no longer at its path is missing:
// its clips render black and silent. Relink finds it again: first the bookmark (it follows a file moved or renamed on
// the same volume), then a folder the user picks, matched by file name and checked by duration and picture size, then
// files of the same type, duration and size under another name. Consolidate copies every file the timeline uses into
// one folder and points the project at the copies. Both only read the user's files and copy them; nothing is moved,
// renamed or deleted.

enum Relink {
    /// A file that is not at its path. Nested sequences (renders in the cache) are never missing.
    nonisolated static func isMissing(_ a: Asset) -> Bool {
        guard a.sequenceID == nil else { return false }
        return isLeaving(a.path) || !FileManager.default.fileExists(atPath: a.path)
    }

    /// Drives being ejected right now (DriveWatcher): their files count as offline at once, so nothing opens them again
    /// while the drive goes.
    private static let leavingLock = NSLock()
    nonisolated(unsafe) private static var leavingDrives = Set<String>()
    nonisolated static func setLeaving(_ volume: String, _ on: Bool) {
        leavingLock.lock(); defer { leavingLock.unlock() }
        if on { leavingDrives.insert(volume) } else { leavingDrives.remove(volume) }
    }
    nonisolated static func isLeaving(_ path: String) -> Bool {
        leavingLock.lock(); defer { leavingLock.unlock() }
        return leavingDrives.contains { path.hasPrefix($0 + "/") }
    }

    static func missing(_ p: Project) -> [Asset] { p.assets.filter(isMissing) }

    /// Where the asset's bookmark points now, when that file exists and is not the old path.
    nonisolated static func bookmarkTarget(_ a: Asset) -> URL? {
        guard let data = a.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.path != a.path, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The longest stretch of the file the project plays (source seconds, picture or sound, J/L cuts included).
    static func usedDuration(of id: UUID, in p: Project) -> Double {
        var end = 0.0
        func scan(_ project: Project) {
            for c in project.allClips {
                for piece in c.multicamPieces(in: project) {
                    if piece.assetID == id { end = max(end, piece.sourceOut) }
                    if piece.hasSplitEdit, project.soundAsset(of: piece)?.id == id { end = max(end, piece.soundClip().sourceOut) }
                    else if piece.audioAssetID == id { end = max(end, (piece.audioSourceIn ?? piece.sourceIn) + piece.sourceOffset(at: piece.duration)) }
                }
            }
        }
        scan(p)
        return end
    }

    struct Probe: Sendable { var url: URL; var kind: AssetKind; var duration: Double; var width: Int?; var height: Int?; var size: Int64 }

    static func probe(_ url: URL) async throws -> Probe {
        let a = try await MediaImporter.probe(url)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return Probe(url: url, kind: a.kind, duration: a.duration, width: a.width, height: a.height, size: size)
    }

    /// Refuses a replacement that is another kind of media or shorter than what the timeline plays from the asset.
    static func check(_ probe: Probe, for asset: Asset, in p: Project) throws {
        guard probe.kind == asset.kind else { throw EditError.invalid("\(probe.url.lastPathComponent) is \(probe.kind.rawValue), but \(asset.name) is \(asset.kind.rawValue)") }
        let used = usedDuration(of: asset.id, in: p)
        if asset.kind != .image, probe.duration + 0.05 < used {
            throw EditError.invalid("\(probe.url.lastPathComponent) is \(EditFormat.s(probe.duration)) s long, but the timeline plays \(asset.name) up to \(EditFormat.s(used)) s")
        }
    }

    /// How well a file fits an asset: duration within a frame and the same picture size. Lower is better; nil = no fit.
    static func mismatch(_ probe: Probe, _ a: Asset, fps: Double) -> Double? {
        guard probe.kind == a.kind else { return nil }
        if a.kind == .image { return (probe.width == a.width && probe.height == a.height) ? 0 : nil }
        let d = abs(probe.duration - a.duration)
        guard d <= max(0.05, 1 / max(1, fps)) else { return nil }
        if let w = a.width, let h = a.height, probe.width != nil, (probe.width != w || probe.height != h) { return nil }
        return d
    }

    /// Media files under a folder (recursive to `depth`, capped), by lowercased file name.
    nonisolated static func index(_ folder: URL, recursive: Bool, cap: Int = 20000) -> [String: [URL]] {
        var out: [String: [URL]] = [:]
        let fm = FileManager.default
        let opts: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: opts) else { return out }
        var n = 0
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            out[url.lastPathComponent.lowercased(), default: []].append(url)
            n += 1
            if n >= cap { break }
        }
        return out
    }

    struct Match { var asset: Asset; var url: URL; var probe: Probe; var reason: String }
    struct Miss { var asset: Asset; var reason: String; var candidates: [String] }

    /// Finds a file for each asset: the bookmark, then (with a folder) the same file name, then the same type,
    /// duration and picture size under another name. Ambiguous names are settled by duration and size, else reported.
    static func find(_ assets: [Asset], folder: URL?, recursive: Bool, in p: Project) async -> (matches: [Match], misses: [Miss]) {
        var matches: [Match] = [], misses: [Miss] = []
        let idx: [String: [URL]] = folder.map { f in index(f, recursive: recursive) } ?? [:]
        var probes: [URL: Probe] = [:]
        func probed(_ u: URL) async -> Probe? {
            if let p = probes[u] { return p }
            guard let p = try? await probe(u) else { return nil }
            probes[u] = p; return p
        }
        var taken = Set<URL>()
        for a in assets {
            if let u = bookmarkTarget(a), let pr = await probed(u), (try? check(pr, for: a, in: p)) != nil {
                matches.append(Match(asset: a, url: u, probe: pr, reason: "found where its bookmark points (moved or renamed on the same disk)")); taken.insert(u); continue
            }
            guard folder != nil else { misses.append(Miss(asset: a, reason: "not at \(a.path); choose a folder to search", candidates: [])); continue }
            let name = URL(fileURLWithPath: a.path).lastPathComponent.lowercased()
            var named: [(URL, Probe, Double)] = []
            for u in idx[name] ?? [] where !taken.contains(u) {
                guard let pr = await probed(u) else { continue }
                if let m = mismatch(pr, a, fps: p.settings.fps) { named.append((u, pr, m)) }
            }
            if named.count == 1 || (named.count > 1 && named.sorted(by: { $0.2 < $1.2 })[0].2 + 0.01 < named.sorted(by: { $0.2 < $1.2 })[1].2) {
                let best = named.sorted { $0.2 < $1.2 }[0]
                if let err = Result(catching: { try check(best.1, for: a, in: p) }).failure {
                    misses.append(Miss(asset: a, reason: err, candidates: [best.0.path])); continue
                }
                matches.append(Match(asset: a, url: best.0, probe: best.1, reason: "same file name, duration and picture size")); taken.insert(best.0); continue
            }
            if named.count > 1 {
                misses.append(Miss(asset: a, reason: "\(named.count) files named \(name) match equally; relink this one with path", candidates: named.map(\.0.path))); continue
            }
            let sameName = idx[name] ?? []
            // Renamed: the same extension, duration and picture size, and only one such file.
            let ext = URL(fileURLWithPath: a.path).pathExtension.lowercased()
            var renamed: [(URL, Probe)] = []
            var looked = 0
            for (_, urls) in idx { for u in urls where u.pathExtension.lowercased() == ext && !taken.contains(u) && looked < 300 {
                looked += 1
                if let pr = await probed(u), let m = mismatch(pr, a, fps: p.settings.fps), m < 0.02 { renamed.append((u, pr)) }
            } }
            if renamed.count == 1, (try? check(renamed[0].1, for: a, in: p)) != nil {
                matches.append(Match(asset: a, url: renamed[0].0, probe: renamed[0].1, reason: "renamed: only file with the same type, duration and picture size")); taken.insert(renamed[0].0); continue
            }
            let why = !sameName.isEmpty ? "\(sameName.count) file\(sameName.count == 1 ? "" : "s") named \(name) found, but none has its duration (\(EditFormat.s(a.duration)) s) and picture size"
                : renamed.count > 1 ? "no file named \(name); \(renamed.count) files have its duration and size, relink this one with path" : "no file named \(name) in the folder"
            misses.append(Miss(asset: a, reason: why, candidates: (sameName + renamed.map(\.0)).prefix(5).map(\.path)))
        }
        return (matches, misses)
    }

    /// Points the asset at a new file (path, bookmark, duration and picture size from the file; the id stays, so
    /// every clip follows). The name follows the file when it was the old file name.
    static func repoint(_ a: inout Asset, to probe: Probe) {
        let oldFile = URL(fileURLWithPath: a.path).lastPathComponent
        if a.name == oldFile { a.name = probe.url.lastPathComponent }
        a.path = probe.url.path
        a.bookmark = try? probe.url.bookmarkData()
        a.duration = probe.duration
        if probe.width != nil { a.width = probe.width; a.height = probe.height }
    }

    // MARK: Consolidate

    /// Every file the timeline uses: clip assets, multicam angles and audio, nested sequences' media, and `.cube`
    /// files referenced by path. Nested sequence renders are left out (they are rebuilt from the cache).
    static func usedFiles(_ p: Project) -> (assets: [Asset], luts: [String]) {
        var ids = Set<UUID>(), luts = Set<String>()
        var assets: [Asset] = []
        func scan(_ project: Project) {
            for c in project.allClips {
                var refs = [c.assetID]
                if let a = c.audioAssetID { refs.append(a) }
                if let mc = c.multicam { refs.append(contentsOf: mc.angles) }
                for id in refs where !ids.contains(id) {
                    guard let a = project.asset(id) else { continue }
                    ids.insert(id)
                    if a.sequenceID == nil { assets.append(a) }
                }
                for l in [c.color.lut, c.color.inputLut].compactMap({ $0 }) where l.hasPrefix("/") { luts.insert(l) }
            }
            for s in project.sequences { scan(s.project) }
        }
        scan(p)
        return (assets, luts.sorted())
    }

    struct Copy: Sendable { var from: URL; var to: URL; var bytes: Int64; var alreadyThere: Bool }

    /// Plans the copies: a unique name in the folder for each file ("name 2.mov" when another file has the name), the
    /// same file already there (same size) reused, files already inside the folder left alone.
    nonisolated static func plan(_ files: [URL], into folder: URL) -> [Copy] {
        let fm = FileManager.default
        var used = Set<String>(), out: [Copy] = []
        let root = folder.standardizedFileURL.path + "/"
        for f in files {
            let size = ((try? fm.attributesOfItem(atPath: f.path))?[.size] as? NSNumber)?.int64Value ?? 0
            if f.standardizedFileURL.path.hasPrefix(root) { out.append(Copy(from: f, to: f, bytes: 0, alreadyThere: true)); continue }
            let base = f.deletingPathExtension().lastPathComponent, ext = f.pathExtension
            var n = 1
            while true {
                let name = n == 1 ? f.lastPathComponent : "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
                let dest = folder.appendingPathComponent(name)
                if used.contains(name.lowercased()) { n += 1; continue }
                if fm.fileExists(atPath: dest.path) {
                    let s = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? -1
                    if s == size { used.insert(name.lowercased()); out.append(Copy(from: f, to: dest, bytes: 0, alreadyThere: true)); break }
                    n += 1; continue
                }
                used.insert(name.lowercased()); out.append(Copy(from: f, to: dest, bytes: size, alreadyThere: false)); break
            }
        }
        return out
    }

    /// Runs the copies off the main thread (copy, never move). Returns the bytes copied.
    nonisolated static func perform(_ copies: [Copy], progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Int64 {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var total: Int64 = 0
            for c in copies where !c.alreadyThere {
                try fm.createDirectory(at: c.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: c.from, to: c.to)
                total += c.bytes
                progress?(total)
            }
            return total
        }.value
    }
}

// MARK: - Offline media (a drive that is not plugged in)

extension Relink {
    /// The drive a file is on ("OSMO", "T7"), for messages; nil for the Mac's own disk.
    nonisolated static func driveName(of path: String) -> String? {
        let c = URL(fileURLWithPath: path).standardizedFileURL.pathComponents   // ["/", "Volumes", "<name>", …]
        return c.count > 3 && c[1] == "Volumes" ? c[2] : nil
    }

    /// Every file a clip plays: its picture, its sound from another file, and a multicam clip's angles.
    nonisolated static func assetIDs(of clip: Clip, in p: Project) -> Set<UUID> {
        var ids: Set<UUID> = [clip.assetID]
        if let a = clip.audioAssetID { ids.insert(a) }
        if clip.multicam != nil { for piece in clip.multicamPieces(in: p) { ids.insert(piece.assetID); if let a = piece.audioAssetID { ids.insert(a) } } }
        return ids
    }

    /// Files the project points at that are not there now (on a drive that is unplugged, or deleted).
    nonisolated static func offline(_ p: Project) -> Set<UUID> { Set(p.assets.filter(isMissing).map(\.id)) }

    /// How many clips play one of these files.
    nonisolated static func clipCount(using ids: Set<UUID>, in p: Project) -> Int {
        ids.isEmpty ? 0 : p.allClips.filter { !assetIDs(of: $0, in: p).isDisjoint(with: ids) }.count
    }

    /// The project without the clips that play these files, for the preview: the rest of the timeline plays and those
    /// clips are a gap (black and silent) until their drive is back. Clip positions are absolute, so nothing moves.
    nonisolated static func removingClips(using ids: Set<UUID>, from p: Project) -> Project {
        var q = p
        for i in q.tracks.indices { q.tracks[i].clips.removeAll { !assetIDs(of: $0, in: p).isDisjoint(with: ids) } }
        return q
    }

    /// The assets on a drive (paths under its folder in /Volumes).
    nonisolated static func assets(onDrive path: String, in p: Project) -> [Asset] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return p.assets.filter { $0.sequenceID == nil && $0.path.hasPrefix(prefix) }
    }

    /// An export needs every file its clips play: one on an unplugged drive is named with the drive, so the user knows
    /// what to plug in. Files that are only missing point to Relink.
    nonisolated static func requireOnline(_ p: Project) throws {
        let off = offline(p)
        let used = p.assets.filter { off.contains($0.id) && clipCount(using: [$0.id], in: p) > 0 }
        guard !used.isEmpty else { return }
        let n = clipCount(using: Set(used.map(\.id)), in: p)
        let drives = Array(Set(used.compactMap { driveName(of: $0.path) })).sorted()
        let clips = "\(n) clip\(n == 1 ? "" : "s")"
        if !drives.isEmpty, drives.count == Set(used.map { driveName(of: $0.path) }).count {
            throw EditError.invalid("\(clips) use\(n == 1 ? "s" : "") files on \(drives.joined(separator: " and ")), which \(drives.count == 1 ? "is" : "are") not connected. Plug \(drives.count == 1 ? "it" : "them") in to export.")
        }
        throw EditError.invalid("\(clips) use\(n == 1 ? "s" : "") files that are missing (\(used.prefix(3).map(\.name).joined(separator: ", "))). Relink them first (File ▸ Relink Media).")
    }
}

private extension Result where Failure == Error {
    var failure: String? { if case .failure(let e) = self { return (e as? LocalizedError)?.errorDescription ?? "\(e)" }; return nil }
}
