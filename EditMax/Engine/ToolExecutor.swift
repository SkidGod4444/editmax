import Foundation
import AVFoundation
import AppKit

/// The single implementation of every editing operation. The SwiftUI views and the MCP server both call
/// this, so an agent and a human get identical behaviour, identical validation and identical history entries.
@MainActor
struct ToolExecutor {
    let document: EditMaxDocument
    let origin: EditOrigin

    private var project: Project { document.project }

    // MARK: Inspect

    struct TimelineSummary: Codable {
        struct ClipInfo: Codable {
            var id: String, name: String, asset: String, track: String
            var start: Double, end: Double, duration: Double, sourceIn: Double, speed: Double, volume: Double, opacity: Double
        }
        struct TextInfo: Codable { var id: String, text: String, start: Double, end: Double }
        struct TrackInfo: Codable { var id: String, name: String, kind: String, clipCount: Int, muted: Bool, hidden: Bool }
        var project: String, projectID: String, width: Int, height: Int, fps: Double, duration: Double
        var tracks: [TrackInfo], clips: [ClipInfo], texts: [TextInfo], historyCount: Int
    }

    func inspectTimeline() -> TimelineSummary {
        let p = project
        var clips: [TimelineSummary.ClipInfo] = []
        for t in p.tracks {
            for c in t.clips {
                clips.append(.init(id: c.id.short, name: c.name, asset: c.assetID.short, track: t.name,
                                   start: r(c.start), end: r(c.end), duration: r(c.duration), sourceIn: r(c.sourceIn),
                                   speed: c.speed, volume: c.volume, opacity: c.opacity))
            }
        }
        return TimelineSummary(
            project: document.displayName, projectID: document.id.short,
            width: p.settings.width, height: p.settings.height, fps: p.settings.fps, duration: r(p.duration),
            tracks: p.tracks.map { .init(id: $0.id.short, name: $0.name, kind: $0.kind.rawValue, clipCount: $0.clips.count, muted: $0.isMuted, hidden: $0.isHidden) },
            clips: clips.sorted { ($0.track, $0.start) < ($1.track, $1.start) },
            texts: p.texts.map { .init(id: $0.id.short, text: $0.text, start: r($0.start), end: r($0.end)) },
            historyCount: p.history.count)
    }

    struct AssetInfo: Codable { var id: String, name: String, kind: String, duration: Double, width: Int?, height: Int?, path: String }
    func listAssets() -> [AssetInfo] {
        project.assets.map { .init(id: $0.id.short, name: $0.name, kind: $0.kind.rawValue, duration: r($0.duration), width: $0.width, height: $0.height, path: $0.path) }
    }

    // MARK: Assets

    @discardableResult
    func importMedia(paths: [String]) async throws -> [AssetInfo] {
        var imported: [Asset] = []
        var failures: [String] = []
        for p in paths {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { failures.append("\(p): file not found"); continue }
            if let existing = project.assets.first(where: { $0.path == url.path }) { imported.append(existing); continue }
            do { imported.append(try await MediaImporter.probe(url)) } catch { failures.append("\(p): \(error.localizedDescription)") }
        }
        let new = imported.filter { a in !project.assets.contains { $0.id == a.id } }
        if !new.isEmpty {
            document.apply("Import \(new.count) file\(new.count == 1 ? "" : "s")", origin: origin) { $0.assets.append(contentsOf: new) }
        }
        if !failures.isEmpty, imported.isEmpty { throw EditError.invalid(failures.joined(separator: "; ")) }
        return imported.map { a in .init(id: a.id.short, name: a.name, kind: a.kind.rawValue, duration: r(a.duration), width: a.width, height: a.height, path: a.path) }
    }

    // MARK: Clip edits

    func resolveAsset(_ text: String) throws -> UUID {
        if let id = Project.resolve(text, in: project.assets.map(\.id)) { return id }
        if let a = project.assets.first(where: { $0.name.lowercased() == text.lowercased() }) { return a.id }
        throw EditError.notFound("asset '\(text)'")
    }
    func resolveClip(_ text: String) throws -> UUID {
        guard let id = Project.resolve(text, in: project.allClips.map(\.id)) else { throw EditError.notFound("clip '\(text)'") }
        return id
    }
    func resolveTrack(_ text: String?) throws -> UUID? {
        guard let text, !text.isEmpty else { return nil }
        if let id = Project.resolve(text, in: project.tracks.map(\.id)) { return id }
        if let t = project.tracks.first(where: { $0.name.lowercased() == text.lowercased() }) { return t.id }
        throw EditError.notFound("track '\(text)'")
    }

    @discardableResult
    func insertClip(asset: String, track: String? = nil, at: Double? = nil, sourceIn: Double = 0, duration: Double? = nil) throws -> Clip {
        let aid = try resolveAsset(asset)
        let tid = try resolveTrack(track)
        var result: Clip!
        try document.apply("Insert \(project.asset(aid)?.name ?? "clip")", origin: origin) { p in
            result = try p.insertClip(assetID: aid, trackID: tid, at: at, sourceIn: sourceIn, duration: duration)
        }
        return result
    }

    @discardableResult
    func splitClip(_ clip: String, at time: Double) throws -> (Clip, Clip) {
        let id = try resolveClip(clip)
        var result: (Clip, Clip)!
        try document.apply("Split clip at \(r(time))s", origin: origin) { p in result = try p.splitClip(id, at: time) }
        return result
    }

    func moveClip(_ clip: String, to start: Double, track: String? = nil) throws {
        let id = try resolveClip(clip)
        let tid = try resolveTrack(track)
        try document.apply("Move clip to \(r(start))s", origin: origin) { p in try p.moveClip(id, to: start, trackID: tid) }
    }

    func trimClip(_ clip: String, start: Double?, end: Double?) throws {
        let id = try resolveClip(clip)
        try document.apply("Trim clip", origin: origin) { p in try p.trimClip(id, newStart: start, newEnd: end) }
    }

    @discardableResult
    func removeClips(_ clips: [String]) throws -> Int {
        let ids = try clips.map(resolveClip)
        var n = 0
        document.apply("Remove \(ids.count) clip\(ids.count == 1 ? "" : "s")", origin: origin) { p in n = p.removeClips(ids) }
        return n
    }

    func setClipProperties(_ clip: String, speed: Double? = nil, volume: Double? = nil, opacity: Double? = nil, name: String? = nil) throws {
        let id = try resolveClip(clip)
        if let speed, speed <= 0 { throw EditError.invalid("speed must be > 0") }
        try document.apply("Edit clip properties", origin: origin) { p in
            try p.updateClip(id) { c in
                if let speed { let src = c.duration * c.speed; c.speed = speed; c.duration = src / speed }
                if let volume { c.volume = max(0, min(2, volume)) }
                if let opacity { c.opacity = max(0, min(1, opacity)) }
                if let name { c.name = name }
            }
        }
    }

    func rippleTrack(_ track: String) throws {
        guard let tid = try resolveTrack(track) else { throw EditError.invalid("track required") }
        try document.apply("Close gaps on track", origin: origin) { p in try p.ripple(trackID: tid) }
    }

    // MARK: Text

    @discardableResult
    func addText(_ text: String, start: Double, duration: Double, fontSize: Double?, colorHex: String?, x: Double?, y: Double?) throws -> TextOverlay {
        guard duration > 0 else { throw EditError.invalid("duration must be > 0") }
        var t: TextOverlay!
        document.apply("Add text \"\(text.prefix(20))\"", origin: origin) { p in
            t = p.addText(text, start: max(0, start), duration: duration, fontSize: fontSize ?? 64, colorHex: colorHex ?? "#FFFFFF", x: x ?? 0.5, y: y ?? 0.85)
        }
        return t
    }

    @discardableResult
    func removeTexts(_ texts: [String]) throws -> Int {
        let ids = try texts.map { t -> UUID in
            guard let id = Project.resolve(t, in: project.texts.map(\.id)) else { throw EditError.notFound("text '\(t)'") }
            return id
        }
        var n = 0
        document.apply("Remove text", origin: origin) { p in n = p.removeTexts(ids) }
        return n
    }

    // MARK: History

    struct SnapshotInfo: Codable { var id: String, label: String, origin: String, createdAt: Date }
    func listHistory(limit: Int = 50) -> [SnapshotInfo] {
        project.history.suffix(limit).reversed().map { .init(id: $0.id.short, label: $0.label, origin: $0.origin.rawValue, createdAt: $0.createdAt) }
    }
    func restore(_ snapshot: String) throws {
        guard let id = Project.resolve(snapshot, in: project.history.map(\.id)) else { throw EditError.notFound("snapshot '\(snapshot)'") }
        try document.restore(snapshotID: id, origin: origin)
    }

    // MARK: Export

    func exportVideo(to path: String, preset: ExportService.Preset = .high, progress: ((Double) -> Void)? = nil) async throws -> ExportService.Result {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if url.pathExtension.lowercased() != "mp4" { url.appendPathExtension("mp4") }
        return try await ExportService.export(project, to: url, preset: preset, progress: progress)
    }

    // MARK: Playhead and frames

    func setPlayhead(_ seconds: Double, play: Bool) {
        document.seekRequest = (max(0, seconds), play)
    }

    /// Render one frame of the timeline (video tracks only; text/image overlays are composited on top) as PNG data.
    func captureFrame(at seconds: Double, maxWidth: Int = 960) async throws -> Data {
        let out = try await CompositionBuilder.build(project)
        let gen = AVAssetImageGenerator(asset: out.composition)
        gen.videoComposition = out.videoComposition
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let t = CMTime(seconds: min(max(0, seconds), max(0, out.duration.seconds - 0.05)), preferredTimescale: CompositionBuilder.timescale)
        var base: CGImage? = try? await gen.image(at: t).image
        if base == nil {  // no video at that time: black frame
            let ctx = CGContext(data: nil, width: Int(out.renderSize.width), height: Int(out.renderSize.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: out.renderSize))
            base = ctx.makeImage()
        }
        guard let base else { throw EditError.invalid("could not render frame") }
        let img = OverlayLayerBuilder.composite(base: base, project: project, size: out.renderSize, at: seconds, maxWidth: maxWidth)
        return img
    }

    // MARK: Settings

    func setProjectSettings(width: Int?, height: Int?, fps: Double?, name: String?) throws {
        document.apply("Project settings", origin: origin) { p in
            if let width { p.settings.width = max(16, width) }
            if let height { p.settings.height = max(16, height) }
            if let fps { p.settings.fps = max(1, fps) }
            if let name { p.name = name }
        }
    }

    private func r(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
