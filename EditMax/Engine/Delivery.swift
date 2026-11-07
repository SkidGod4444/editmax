import Foundation
import AVFoundation

// Delivery: chapter lists from markers and batch exports to several templates. Nothing here mutates a project;
// the batch export works on copies whose settings are overridden per template.

/// YouTube-style chapters from the project's markers: one line per marker, "mm:ss Name" (h:mm:ss from one hour),
/// sorted by time. YouTube needs the first chapter at 00:00, so a leading "00:00 Intro" is added when no marker sits there.
enum Chapters {
    struct Entry: Equatable { var time: Double; var name: String }

    /// Whole seconds, "mm:ss" under an hour and "h:mm:ss" from one hour on (what YouTube parses in a description).
    static func timestamp(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static func entries(_ project: Project) -> [Entry] {
        let sorted = project.markers.sorted { $0.time < $1.time }
        var out: [Entry] = []
        // A marker that formats to 00:00 (anything under a second) is the intro; otherwise YouTube's required first chapter is synthesized.
        if !sorted.contains(where: { Int($0.time.rounded(.down)) == 0 }) { out.append(Entry(time: 0, name: "Intro")) }
        for m in sorted {
            let trimmed = m.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = Int(m.time.rounded(.down)) == 0 ? "Intro" : "Chapter \(out.count + 1)"
            out.append(Entry(time: m.time, name: trimmed.isEmpty ? fallback : trimmed))
        }
        return out
    }

    static func youtubeText(_ project: Project) -> String {
        entries(project).map { "\(timestamp($0.time)) \($0.name)" }.joined(separator: "\n") + "\n"
    }

    /// `<video basename>.chapters.txt` beside the video.
    static func sidecarURL(nextTo videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("chapters.txt")
    }

    /// Writes the chapter list next to a video (or to `url` itself when it already ends in .txt) and returns where it went.
    @discardableResult
    static func write(_ project: Project, nextTo videoURL: URL) throws -> URL {
        let url = videoURL.pathExtension.lowercased() == "txt" ? videoURL : sidecarURL(nextTo: videoURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try youtubeText(project).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// One project rendered to several templates in one go: each template's width, height and fps override a copy of the
/// project (nothing else changes; the compositor fits the picture, so other aspect ratios are letter- or pillarboxed).
enum BatchExport {
    struct Item: Codable {
        var path: String
        var template: String
        var width: Int, height: Int, fps: Double
        var bytes: Int
        var duration: Double
        /// Wall-clock seconds the render took.
        var seconds: Double
        /// The chapters sidecar written into the directory (the same file for every item), when asked for and the project has markers.
        var chapters: String?
        /// Video clips auto-reframed for this template (nil when the template keeps the project's aspect or reframing was off).
        var reframed: Int?
    }

    /// "YouTube 16:9 1080p" → "youtube-16-9-1080p".
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = "", dash = false
        for ch in folded {
            if ch.isLetter || ch.isNumber { out.append(ch); dash = false } else if !dash && !out.isEmpty { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "export" : out
    }

    /// A project name made safe for a file name.
    static func stem(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).map { "/:\\".contains($0) ? "-" : $0 }
        let s = String(cleaned)
        return s.isEmpty ? "Untitled" : s
    }

    /// Template infos for the names (case-insensitive, against `Templates.list()`); an empty list means every built-in.
    static func resolve(_ names: [String]) throws -> [Templates.Info] {
        let all = Templates.list()
        let wanted = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if wanted.isEmpty { return all.filter(\.builtin) }
        return try wanted.map { n in
            guard let t = all.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) else {
                throw EditError.notFound("template '\(n)'; templates: \(all.map(\.name).joined(separator: ", "))")
            }
            return t
        }
    }

    /// Renders `project` once per template into `directory` as `<project name>-<template slug>.mp4` (.mov for ProRes), one export session
    /// at a time. `progress` gets "k/n Template name" and that export's fraction. With `chapters`, the markers also go
    /// to `<project name>.chapters.txt` in the directory (once; skipped when there are no markers).
    static func export(_ project: Project, to directory: URL, templates: [String], preset: ExportService.Preset, chapters: Bool, reframe: Bool = true,
                       progress: ((String, Double) -> Void)? = nil) async throws -> [Item] {
        guard project.duration > 0 else { throw EditError.invalid("timeline is empty") }
        let infos = try resolve(templates)
        guard !infos.isEmpty else { throw EditError.invalid("no templates to export to") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = stem(project.name)

        var chaptersPath: String?
        if chapters, !project.markers.isEmpty {
            chaptersPath = try Chapters.write(project, nextTo: directory.appendingPathComponent(base + ".mp4")).path
        }

        var items: [Item] = []
        for (k, t) in infos.enumerated() {
            var copy = project
            copy.settings.width = max(16, t.width)
            copy.settings.height = max(16, t.height)
            copy.settings.fps = max(1, t.fps)
            let url = directory.appendingPathComponent("\(base)-\(slug(t.name)).\(preset.fileExtension)")
            let label = "\(k + 1)/\(infos.count) \(t.name)"
            progress?(label, 0)
            // A template with another aspect would letterbox every clip: follow the subject instead (per clip, on the copy only).
            var reframed: Int? = nil
            let projectAspect = Double(project.settings.width) / Double(max(1, project.settings.height))
            let templateAspect = Double(copy.settings.width) / Double(max(1, copy.settings.height))
            if reframe, abs(projectAspect / templateAspect - 1) > 0.02 {
                let frame = CGSize(width: copy.settings.width, height: copy.settings.height)
                var n = 0
                for track in copy.tracks where track.kind == .video && !track.isHidden {
                    for clip in track.clips {
                        guard let asset = copy.asset(clip.assetID), asset.kind == .video || asset.kind == .sequence else { continue }
                        do {
                            let plan = try await AutoReframe.plan(clip: clip, asset: asset, frame: frame, mode: .auto, sampleInterval: nil, strength: nil)
                            try copy.updateClip(clip.id) { AutoReframe.apply(plan, to: &$0) }
                            n += 1
                        } catch {
                            DebugLog.event("batch-reframe-skipped", ["template": t.name, "clip": clip.id.short, "error": error.localizedDescription])
                        }
                    }
                }
                reframed = n
            }
            let started = Date()
            await AppArchive.shared.keepBeforeReplacing(url)   // a render of that name from an earlier batch goes to the Archive
            let r = try await ExportService.export(copy, to: url, preset: preset) { p in progress?(label, p) }
            let took = (Date().timeIntervalSince(started) * 100).rounded() / 100
            DebugLog.event("batch-export", ["template": t.name, "path": url.lastPathComponent, "bytes": r.bytes, "seconds": took])
            items.append(Item(path: r.path, template: t.name, width: copy.settings.width, height: copy.settings.height, fps: copy.settings.fps,
                              bytes: r.bytes, duration: r.duration, seconds: took, chapters: chaptersPath, reframed: reframed))
        }
        return items
    }
}

extension ExportService.Preset {
    /// "hevc10", "hevc", "high", "med", "prores", "prores422", "ProRes 4444"… → a preset (default high), the same loose
    /// match `export_video` accepts. An exact name wins over a prefix, so "prores422" is 422 and a bare "prores" is 422 HQ.
    static func parse(_ text: String?) -> ExportService.Preset {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let want = key(text ?? "high")
        guard !want.isEmpty else { return .high }
        let aliases: [String: ExportService.Preset] = ["h264": .high, "mp4": .high, "proreshq": .prores422hq, "hq": .prores422hq, "mov": .prores422hq,
                                                       "4444": .prores4444, "prores4": .prores4444, "422": .prores422]
        if let a = aliases[want] { return a }
        return allCases.first { key($0.rawValue) == want } ?? allCases.first { key($0.rawValue).hasPrefix(want) } ?? .high
    }
}

// MARK: - ToolExecutor

extension ToolExecutor {
    struct ChapterResult: Codable { var text: String; var path: String?; var count: Int }

    /// The YouTube chapter list; with `path` it is also written there (a .txt path as given, any other path such as the
    /// exported .mp4 gets `<basename>.chapters.txt` beside it).
    func exportChapters(path: String?) throws -> ChapterResult {
        let p = document.project
        guard !p.markers.isEmpty else { throw EditError.invalid("the project has no markers; add some with add_marker (or M in the timeline) first") }
        let text = Chapters.youtubeText(p)
        var written: String?
        if let path, !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            written = try Chapters.write(p, nextTo: url).path
        }
        return ChapterResult(text: text, path: written, count: Chapters.entries(p).count)
    }

    /// Batch export of the live project (a copy of it; nothing in the document changes) into a directory.
    /// Files are named after the window (the file name, or the project name while unsaved).
    func exportBatch(directory: String, templates: [String], preset: ExportService.Preset, chapters: Bool, reframe: Bool = true,
                     progress: ((String, Double) -> Void)? = nil) async throws -> [BatchExport.Item] {
        let dir = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        var copy = document.project
        copy.name = document.displayName
        return try await BatchExport.export(copy, to: dir, templates: templates, preset: preset, chapters: chapters, reframe: reframe, progress: progress)
    }
}
