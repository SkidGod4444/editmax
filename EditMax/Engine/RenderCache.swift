import Foundation
import AVFoundation
import CryptoKit
import Combine

/// Low-resolution copies of video assets for smooth preview (the export always uses the originals), kept in Application
/// Support and keyed by the file's path, size and modification date.
@MainActor
final class ProxyStore: ObservableObject {
    static let shared = ProxyStore()
    enum Status: Equatable { case none, building(Double), ready(URL), failed(String) }
    @Published private(set) var status: [UUID: Status] = [:]
    /// Bumped whenever a proxy becomes ready, so players can rebuild with it.
    @Published private(set) var version = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]

    nonisolated static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax/proxies")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func key(for asset: Asset) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: asset.path)) ?? [:]
        let size = (attrs[.size] as? Int) ?? 0, mod = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(asset.path)|\(size)|\(Int(mod))".utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(24).joined()
    }
    nonisolated static func proxyURL(for asset: Asset) -> URL { directory.appendingPathComponent(key(for: asset) + ".mp4") }

    /// The proxy file if it exists on disk (also refreshes `status`).
    func ready(for asset: Asset) -> URL? {
        if case .ready(let u) = status[asset.id] { return u }
        let u = Self.proxyURL(for: asset)
        if FileManager.default.fileExists(atPath: u.path) { status[asset.id] = .ready(u); return u }
        return nil
    }

    /// Builds proxies for every video asset that lacks one (960×540 H.264, original audio).
    func build(_ assets: [Asset]) {
        for a in assets where a.kind == .video && ready(for: a) == nil && tasks[a.id] == nil {
            status[a.id] = .building(0)
            tasks[a.id] = Task { [weak self] in
                let url = Self.proxyURL(for: a)
                do {
                    let av = AVURLAsset(url: a.url)
                    guard let session = AVAssetExportSession(asset: av, presetName: AVAssetExportPreset960x540) else { throw EditError.invalid("no proxy preset for \(a.name)") }
                    session.outputFileType = .mp4
                    let tmp = url.deletingPathExtension().appendingPathExtension("part.mp4")
                    try? FileManager.default.removeItem(at: tmp)
                    let poll = Task { while !Task.isCancelled { await MainActor.run { self?.status[a.id] = .building(Double(session.progress)) }; try? await Task.sleep(for: .milliseconds(300)) } }
                    try await session.export(to: tmp, as: .mp4)
                    poll.cancel()
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: tmp, to: url)
                    self?.status[a.id] = .ready(url)
                    self?.version += 1
                } catch {
                    self?.status[a.id] = .failed(error.localizedDescription)
                }
                self?.tasks[a.id] = nil
            }
        }
    }

    func remove(_ assets: [Asset]) {
        for a in assets { try? FileManager.default.removeItem(at: Self.proxyURL(for: a)); status[a.id] = .none }
        version += 1
    }
}

/// Project templates: built-in format presets and projects the user saved as templates, as JSON files in Application Support.
enum Templates {
    struct Info: Codable, Identifiable { var id: String { name }; var name: String; var builtin: Bool; var width: Int; var height: Int; var fps: Double; var summary: String }

    static let builtin: [(name: String, w: Int, h: Int, fps: Double)] = [
        ("YouTube 16:9 1080p", 1920, 1080, 30), ("Shorts / Reels 9:16", 1080, 1920, 30), ("Square 1:1", 1080, 1080, 30),
        ("4K 16:9", 3840, 2160, 30), ("Cinema 2.39:1 24 fps", 2048, 858, 24), ("Vertical 4:5 (feed)", 1080, 1350, 30)]

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax/templates")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func list() -> [Info] {
        var out = builtin.map { Info(name: $0.name, builtin: true, width: $0.w, height: $0.h, fps: $0.fps, summary: "\($0.w)×\($0.h) at \(Int($0.fps)) fps, empty timeline") }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "editmax" {
            guard let data = try? Data(contentsOf: f), let p = try? JSONDecoder().decode(Project.self, from: data) else { continue }
            let n = p.allClips.count, t = p.texts.count
            out.append(Info(name: f.deletingPathExtension().lastPathComponent, builtin: false, width: p.settings.width, height: p.settings.height, fps: p.settings.fps,
                            summary: "\(p.settings.width)×\(p.settings.height), \(p.tracks.count) tracks, \(n) clip\(n == 1 ? "" : "s"), \(t) title\(t == 1 ? "" : "s")"))
        }
        return out
    }

    /// The project a template produces (built-ins: fresh project with those settings; saved: the stored project, with history cleared).
    static func project(named name: String) throws -> Project {
        if let b = builtin.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            var p = Project(); p.settings = ProjectSettings(width: b.w, height: b.h, fps: b.fps); p.name = b.name
            return p
        }
        let url = directory.appendingPathComponent(name + ".editmax")
        guard let data = try? Data(contentsOf: url) else { throw EditError.notFound("template '\(name)'; templates: \(list().map(\.name).joined(separator: ", "))") }
        var p = try JSONDecoder().decode(Project.self, from: data)
        p.history = []; p.transcripts = nil
        return p
    }

    static func save(_ project: Project, as name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { throw EditError.invalid("template name is empty") }
        guard !builtin.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else { throw EditError.invalid("'\(clean)' is a built-in template name") }
        let url = directory.appendingPathComponent(clean + ".editmax")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(project.withoutHistory).write(to: url)
        return url
    }

    static func delete(_ name: String) throws {
        let url = directory.appendingPathComponent(name + ".editmax")
        guard FileManager.default.fileExists(atPath: url.path) else { throw EditError.notFound("saved template '\(name)'") }
        try FileManager.default.removeItem(at: url)
    }
}

/// A timeline folded into one clip: the sub-project is rendered once per content hash into Application Support and
/// the clip plays that file, so the parent can speed, grade, fade and transition it like any clip.
struct Sequence: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var project: Project
}

/// Renders nested sequences into the cache, one render per content hash even when several builds ask at once.
actor SequenceRenderer {
    static let shared = SequenceRenderer()
    private var inFlight: [String: Task<URL, Error>] = [:]

    nonisolated static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax/nested")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Content hash of what the render depends on: the sub-project without its history, keys sorted so the hash is stable.
    nonisolated static func key(for seq: Sequence) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(seq.project.withoutHistory)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.prefix(24).joined()
    }
    nonisolated static func url(for seq: Sequence) -> URL { directory.appendingPathComponent(key(for: seq) + ".mp4") }

    /// The rendered file for a sequence, rendering it first when the cache has no file for its current content.
    func ensure(_ seq: Sequence, depth: Int) async throws -> URL {
        guard depth <= 4 else { throw EditError.invalid("sequences nested more than 4 deep (does '\(seq.name)' contain itself?)") }
        let url = Self.url(for: seq)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let k = Self.key(for: seq)
        if let t = inFlight[k] { return try await t.value }
        let task = Task<URL, Error> {
            guard seq.project.duration > 0 else { throw EditError.invalid("sequence '\(seq.name)' is empty") }
            let tmp = url.deletingPathExtension().appendingPathExtension("part.mp4")
            let started = Date()
            _ = try await ExportService.export(seq.project, to: tmp, preset: .high, depth: depth)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            DebugLog.event("sequence-render", ["name": seq.name, "key": k, "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
            return url
        }
        inFlight[k] = task
        defer { inFlight[k] = nil }
        return try await task.value
    }
}
