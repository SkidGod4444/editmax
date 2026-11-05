import Foundation
import AVFoundation
import AppKit

/// The single implementation of every editing operation. The SwiftUI views and the MCP server both call
/// this, so an agent and a human get identical behaviour, identical validation and identical history entries.
@MainActor
struct ToolExecutor {
    let document: EditMaxDocument
    let origin: EditOrigin
    /// Slider-style callers: fold rapid same-kind edits into one undo step.
    var coalesce = false

    private var project: Project { document.project }

    // MARK: Inspect

    struct TimelineSummary: Codable {
        struct ClipInfo: Codable {
            var id: String, name: String, asset: String, track: String
            var start: Double, end: Double, duration: Double, sourceIn: Double, speed: Double, volume: Double, opacity: Double
            var transform: ClipTransform?, color: ClipColor?, fadeIn: Double?, fadeOut: Double?, transition: Transition?   // only when set
        }
        struct MarkerInfo: Codable { var id: String, time: Double, name: String, color: String }
        struct TextInfo: Codable { var id: String, text: String, start: Double, end: Double, preset: String?, caption: String? }
        struct TrackInfo: Codable { var id: String, name: String, kind: String, clipCount: Int, muted: Bool, hidden: Bool }
        var project: String, projectID: String, width: Int, height: Int, fps: Double, duration: Double
        var tracks: [TrackInfo], clips: [ClipInfo], texts: [TextInfo], markers: [MarkerInfo], historyCount: Int
        var playhead: Double?
    }

    func inspectTimeline() -> TimelineSummary {
        let p = project
        var clips: [TimelineSummary.ClipInfo] = []
        for t in p.tracks {
            for c in t.clips {
                clips.append(.init(id: c.id.short, name: c.name, asset: c.assetID.short, track: t.name,
                                   start: r(c.start), end: r(c.end), duration: r(c.duration), sourceIn: r(c.sourceIn),
                                   speed: c.speed, volume: c.volume, opacity: c.opacity,
                                   transform: c.transform.isIdentity ? nil : c.transform, color: c.color.isIdentity ? nil : c.color,
                                   fadeIn: c.fadeIn > 0 ? c.fadeIn : nil, fadeOut: c.fadeOut > 0 ? c.fadeOut : nil, transition: c.transitionIn))
            }
        }
        return TimelineSummary(
            project: document.displayName, projectID: document.id.short,
            width: p.settings.width, height: p.settings.height, fps: p.settings.fps, duration: r(p.duration),
            tracks: p.tracks.map { .init(id: $0.id.short, name: $0.name, kind: $0.kind.rawValue, clipCount: $0.clips.count, muted: $0.isMuted, hidden: $0.isHidden) },
            clips: clips.sorted { ($0.track, $0.start) < ($1.track, $1.start) },
            texts: p.texts.map { .init(id: $0.id.short, text: $0.text, start: r($0.start), end: r($0.end), preset: $0.preset, caption: $0.group?.short) },
            markers: p.markers.map { .init(id: $0.id.short, time: r($0.time), name: $0.name, color: $0.colorHex) },
            historyCount: p.history.count, playhead: UIRegistry.shared.playheads[document.id]?().map(r))
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
        try document.apply("Edit clip properties", origin: origin, coalesce: coalesce) { p in
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
    func addText(_ text: String, start: Double, duration: Double, fontSize: Double?, colorHex: String?, x: Double?, y: Double?, preset: String? = nil) throws -> TextOverlay {
        guard duration > 0 else { throw EditError.invalid("duration must be > 0") }
        let style = try preset.map { try CaptionPresets.resolve($0) } ?? CaptionPresets.title
        var t: TextOverlay!
        document.apply("Add text \"\(text.prefix(20))\"", origin: origin) { p in
            t = p.addText(text, start: max(0, start), duration: duration, fontSize: fontSize ?? style.fontSize, colorHex: colorHex ?? style.color, x: x ?? 0.5, y: y ?? style.y)
            if preset != nil { p.texts[p.texts.count - 1].preset = style.name; t = p.texts[p.texts.count - 1] }
        }
        return t
    }

    // MARK: Transcripts and captions
    struct TranscriptInfo: Codable {
        struct Word: Codable { var text: String, start: Double, end: Double }
        var asset: String, assetName: String, clip: String?, locale: String, wordCount: Int, text: String, words: [Word]
    }

    /// The asset's transcript, made on first use (on-device, blocks for a while on long files) and cached on the project.
    func ensureTranscript(assetID: UUID, language: String?) async throws -> Transcript {
        guard let asset = project.asset(assetID) else { throw EditError.notFound("asset \(assetID)") }
        guard asset.kind != .image else { throw EditError.invalid("'\(asset.name)' is an image; there is nothing to transcribe") }
        let wantsLanguage = language.map { $0.lowercased() != "auto" && !$0.isEmpty } ?? false
        if let t = project.transcript(for: assetID), !wantsLanguage || t.locale.lowercased().hasPrefix(language!.lowercased().replacingOccurrences(of: "-", with: "_").prefix(2)) { return t }
        let t = try await Transcriber.transcribe(url: asset.url, language: language)
        document.apply("Transcribe \(asset.name)", origin: .system) { p in
            var all = p.transcripts ?? [:]; all[assetID.uuidString] = t; p.transcripts = all
        }
        return t
    }

    /// Words of an asset transcript that fall inside a clip, moved to timeline seconds (speed and trims applied).
    func timelineWords(_ t: Transcript, clip: Clip) -> [TranscriptWord] {
        t.words.compactMap { w in
            guard w.start >= clip.sourceIn - 0.05, w.start < clip.sourceOut else { return nil }
            let s = clip.start + max(0, w.start - clip.sourceIn) / clip.speed
            let e = clip.start + min(w.end - clip.sourceIn, clip.duration * clip.speed) / clip.speed
            return TranscriptWord(text: w.text, start: s, end: max(s + 0.05, e))
        }
    }

    /// Clips whose audio can carry captions: on tracks that play, not images, one per (asset, position).
    func captionableClips() -> [Clip] {
        var seen: Set<String> = []
        var out: [Clip] = []
        for t in project.tracks where !t.isHidden && !t.isMuted {   // a muted or hidden track is not heard, so it neither gets captions nor counts for silence
            for c in t.clips {
                guard let a = project.asset(c.assetID), a.kind != .image else { continue }
                let key = "\(c.assetID)-\(c.start)-\(c.sourceIn)"
                if seen.insert(key).inserted { out.append(c) }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    func getTranscript(asset: String?, clip: String?, language: String?) async throws -> TranscriptInfo {
        let clipRef: Clip?
        let assetID: UUID
        if let clip, !clip.isEmpty {
            let id = try resolveClip(clip); clipRef = project.clip(id)!.clip; assetID = clipRef!.assetID
        } else if let asset, !asset.isEmpty {
            clipRef = nil; assetID = try resolveAsset(asset)
        } else {
            let candidates = project.assets.filter { $0.kind != .image }
            guard candidates.count == 1 else { throw EditError.invalid(candidates.isEmpty ? "No audio or video asset to transcribe" : "Say which asset or clip to transcribe") }
            clipRef = nil; assetID = candidates[0].id
        }
        let t = try await ensureTranscript(assetID: assetID, language: language)
        let words = clipRef.map { timelineWords(t, clip: $0) } ?? t.words
        return TranscriptInfo(asset: assetID.short, assetName: project.asset(assetID)?.name ?? "", clip: clipRef?.id.short, locale: t.locale, wordCount: words.count,
                              text: words.map(\.text).joined(separator: " "), words: words.map { .init(text: $0.text, start: r($0.start), end: r($0.end)) })
    }

    struct CaptionResult: Codable { var count: Int, group: String, preset: String, clips: Int, first: Double?, last: Double? }

    /// Caption one clip or every clip with speech. Transcribes what is not yet transcribed, then adds the lines as one edit.
    func addCaptions(clip: String?, preset: String?, maxWords: Int?, language: String?) async throws -> CaptionResult {
        let style = try CaptionPresets.resolve(preset)
        let clips: [Clip]
        if let clip, !clip.isEmpty { let id = try resolveClip(clip); clips = [project.clip(id)!.clip] } else { clips = captionableClips() }
        guard !clips.isEmpty else { throw EditError.invalid("No clip with audio on the timeline") }
        let group = UUID()
        var overlays: [TextOverlay] = []
        for c in clips {
            let t = try await ensureTranscript(assetID: c.assetID, language: language)
            for s in Captioner.segments(timelineWords(t, clip: c), maxChars: style.maxChars, maxWords: maxWords ?? style.maxWords) {
                let text = style.uppercase ? s.text.uppercased() : s.text
                overlays.append(TextOverlay(text: text, start: s.start, duration: s.end - s.start, fontSize: style.fontSize, colorHex: style.color, x: 0.5, y: style.y, preset: style.name, group: group))
            }
        }
        guard !overlays.isEmpty else { throw EditError.invalid("No speech was recognized in \(clips.count == 1 ? "that clip" : "those clips")") }
        document.apply("Add \(overlays.count) captions (\(style.title))", origin: origin) { p in p.texts.append(contentsOf: overlays) }
        return CaptionResult(count: overlays.count, group: group.short, preset: style.name, clips: clips.count, first: overlays.first.map { r($0.start) }, last: overlays.last.map { r($0.end) })
    }

    // MARK: Cleanup: silence, filler words, ripple delete
    struct RangeInfo: Codable { var start: Double, end: Double, duration: Double }
    struct CleanupResult: Codable { var ranges: [RangeInfo], removedSeconds: Double, duration: Double, words: [String]?, ignoredTracks: [String] }

    /// Tracks with clips that cleanup does not listen to (hidden or muted). They are still cut by the ripple.
    func ignoredTracks() -> [String] { project.tracks.filter { ($0.isHidden || $0.isMuted) && !$0.clips.isEmpty }.map(\.name) }

    private func cleanupClips(_ clip: String?) throws -> [Clip] {
        if let clip, !clip.isEmpty { let id = try resolveClip(clip); return [project.clip(id)!.clip] }
        let clips = captionableClips()
        guard !clips.isEmpty else { throw EditError.invalid("No clip with audio on the timeline") }
        return clips
    }

    /// Merges overlapping or touching timeline ranges.
    private func merge(_ ranges: [(Double, Double)]) -> [RangeInfo] {
        var out: [RangeInfo] = []
        for r in ranges.sorted(by: { $0.0 < $1.0 }) where r.1 - r.0 > 0.02 {
            if let last = out.last, r.0 <= last.end + 0.02 { out[out.count - 1].end = max(last.end, r.1); out[out.count - 1].duration = self.r(out[out.count - 1].end - out[out.count - 1].start) }
            else { out.append(RangeInfo(start: self.r(r.0), end: self.r(r.1), duration: self.r(r.1 - r.0))) }
        }
        return out
    }

    /// Quiet stretches of the timeline. With `clip` given, that clip's own pauses. Otherwise a moment counts as silent only
    /// when every audible clip playing there is quiet, so a pause in the speech is kept where music or another voice runs
    /// underneath it. Every cut is still a ripple across all tracks, so picture and sound stay together.
    func detectSilence(clip: String?, thresholdDb: Double, minDuration: Double, padding: Double) async throws -> [RangeInfo] {
        let clips = try cleanupClips(clip)
        var loud: [(Double, Double)] = []          // timeline stretches where some clip has sound
        var quiet: [(Double, Double)] = []         // the chosen clip's pauses (single-clip mode)
        for c in clips {
            guard let asset = project.asset(c.assetID) else { continue }
            let peaks = try await WaveformExtractor.peaks(for: asset.url)
            let pauses = SilenceDetector.ranges(peaks: peaks, from: c.sourceIn, to: c.sourceOut, thresholdDb: thresholdDb, minDuration: 0.05, padding: padding * c.speed)
                .map { (c.start + ($0.start - c.sourceIn) / c.speed, c.start + ($0.end - c.sourceIn) / c.speed) }
            quiet += pauses
            var t = c.start
            for p in pauses { if p.0 > t { loud.append((t, p.0)) }; t = max(t, p.1) }
            if c.end > t { loud.append((t, c.end)) }
        }
        let ranges: [RangeInfo]
        if clip != nil {
            ranges = merge(quiet)
        } else {
            // Everything in [0, duration] not covered by a loud stretch.
            var gaps: [(Double, Double)] = []
            var t = 0.0
            for l in merge(loud) { if l.start > t { gaps.append((t, l.start)) }; t = max(t, l.end) }
            if project.duration > t { gaps.append((t, project.duration)) }
            ranges = merge(gaps)
        }
        return ranges.filter { $0.duration >= minDuration }
    }

    private func rippleDelete(_ ranges: [RangeInfo], label: String) -> CleanupResult {
        let removed = ranges.reduce(0) { $0 + $1.duration }
        if !ranges.isEmpty {
            document.apply(label, origin: origin) { p in
                for r in ranges.sorted(by: { $0.start > $1.start }) { p.rippleDelete(start: r.start, end: r.end) }   // last first keeps earlier times valid
            }
        }
        return CleanupResult(ranges: ranges, removedSeconds: r(removed), duration: r(project.duration), words: nil, ignoredTracks: ignoredTracks())
    }

    func removeSilence(clip: String?, thresholdDb: Double, minDuration: Double, padding: Double) async throws -> CleanupResult {
        let ranges = try await detectSilence(clip: clip, thresholdDb: thresholdDb, minDuration: minDuration, padding: padding)
        return rippleDelete(ranges, label: "Remove \(ranges.count) silence\(ranges.count == 1 ? "" : "s")")
    }

    /// Cuts the moments where filler words ("um", "uh"…) are spoken, using the transcript's word timings.
    func removeWords(clip: String?, words: [String]?, language: String?) async throws -> CleanupResult {
        let wanted = Set((words?.isEmpty == false ? words! : Array(FillerWords.defaults)).map(FillerWords.normalize))
        var found: [(Double, Double)] = []
        var hits: [String] = []
        for c in try cleanupClips(clip) {
            let t = try await ensureTranscript(assetID: c.assetID, language: language)
            for w in timelineWords(t, clip: c) where wanted.contains(FillerWords.normalize(w.text)) {
                found.append((w.start - 0.03, w.end + 0.03)); hits.append(w.text)
            }
        }
        var result = rippleDelete(merge(found), label: "Remove \(hits.count) filler word\(hits.count == 1 ? "" : "s")")
        result.words = hits
        return result
    }

    func rippleDelete(start: Double, end: Double) throws -> CleanupResult {
        guard end > start else { throw EditError.invalid("end must be after start") }
        return rippleDelete([RangeInfo(start: start, end: end, duration: r(end - start))], label: "Ripple delete \(r(start))s–\(r(end))s")
    }

    @discardableResult
    func removeCaptions(group: String?) throws -> Int {
        var gid: UUID? = nil
        if let group, !group.isEmpty {
            let groups = Array(Set(project.texts.compactMap(\.group)))
            guard let g = Project.resolve(group, in: groups) else { throw EditError.notFound("caption group '\(group)'") }
            gid = g
        }
        var n = 0
        document.apply(gid == nil ? "Remove all captions" : "Remove captions", origin: origin) { p in n = p.removeCaptions(group: gid) }
        return n
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
        let raw = try await gen.image(at: t).image   // the compositor draws titles and stills too
        let frame = raw.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? raw   // the pixels are sRGB already; retag, don't convert
        let scale = min(1, CGFloat(maxWidth) / out.renderSize.width)
        let outSize = NSSize(width: (out.renderSize.width * scale).rounded(), height: (out.renderSize.height * scale).rounded())
        let image = NSImage(size: outSize)
        image.lockFocus(); NSGraphicsContext.current?.cgContext.draw(frame, in: CGRect(origin: .zero, size: outSize)); image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw EditError.invalid("could not encode frame") }
        return png
    }

    // MARK: Look: transform, color, fades, transitions

    func setClipTransform(_ clip: String, scale: Double?, x: Double?, y: Double?, rotation: Double?, cropLeft: Double?, cropRight: Double?, cropTop: Double?, cropBottom: Double?, reset: Bool) throws {
        let id = try resolveClip(clip)
        try document.apply("Transform clip", origin: origin, coalesce: coalesce) { p in
            try p.updateClip(id) { c in
                if reset { c.transform = .identity }
                if let scale { c.transform.scale = max(0.05, min(10, scale)) }
                if let x { c.transform.x = max(-2, min(2, x)) }
                if let y { c.transform.y = max(-2, min(2, y)) }
                if let rotation { c.transform.rotation = rotation.truncatingRemainder(dividingBy: 360) }
                if let cropLeft { c.transform.cropLeft = max(0, min(0.95, cropLeft)) }
                if let cropRight { c.transform.cropRight = max(0, min(0.95, cropRight)) }
                if let cropTop { c.transform.cropTop = max(0, min(0.95, cropTop)) }
                if let cropBottom { c.transform.cropBottom = max(0, min(0.95, cropBottom)) }
            }
        }
    }

    func setClipColor(_ clip: String, exposure: Double?, contrast: Double?, saturation: Double?, temperature: Double?, tint: Double?, reset: Bool) throws {
        let id = try resolveClip(clip)
        try document.apply("Color clip", origin: origin, coalesce: coalesce) { p in
            try p.updateClip(id) { c in
                if reset { c.color = .identity }
                if let exposure { c.color.exposure = max(-4, min(4, exposure)) }
                if let contrast { c.color.contrast = max(0.25, min(3, contrast)) }
                if let saturation { c.color.saturation = max(0, min(3, saturation)) }
                if let temperature { c.color.temperature = max(-100, min(100, temperature)) }
                if let tint { c.color.tint = max(-100, min(100, tint)) }
            }
        }
    }

    func setClipFades(_ clip: String, fadeIn: Double?, fadeOut: Double?) throws {
        let id = try resolveClip(clip)
        try document.apply("Fade clip", origin: origin, coalesce: coalesce) { p in
            try p.updateClip(id) { c in
                if let fadeIn { c.fadeIn = max(0, min(c.duration, fadeIn)) }
                if let fadeOut { c.fadeOut = max(0, min(c.duration, fadeOut)) }
            }
        }
    }

    struct TransitionResult: Codable { var clip: String, kind: String?, duration: Double, note: String? }
    /// A transition into `clip` from the clip ending where it starts. `kind` "none" removes it. The duration is limited
    /// by the clip's length and by how much media the outgoing clip has past its out point.
    func setTransition(_ clip: String, kind: String?, duration: Double?) throws -> TransitionResult {
        let id = try resolveClip(clip)
        guard let found = project.clip(id) else { throw EditError.notFound("clip \(clip)") }
        if kind?.lowercased() == "none" {
            try document.apply("Remove transition", origin: origin) { p in try p.updateClip(id) { $0.transitionIn = nil } }
            return TransitionResult(clip: id.short, kind: nil, duration: 0, note: nil)
        }
        let k: Transition.Kind
        if let kind {
            let key = kind.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
            guard let m = Transition.Kind.allCases.first(where: { $0.rawValue.lowercased() == key }) else { throw EditError.invalid("kind must be one of \(Transition.Kind.allCases.map(\.rawValue).joined(separator: ", ")) or none") }
            k = m
        } else { k = found.clip.transitionIn?.kind ?? .crossDissolve }
        var d = max(0.1, duration ?? found.clip.transitionIn?.duration ?? 0.5)
        var note: String? = nil
        let prev = project.clipBefore(found.clip, on: found.track)
        if prev == nil { note = "No clip ends where this one starts, so it transitions from black." }
        if let prev, let pa = project.asset(prev.assetID), pa.kind != .image {
            let tail = max(0, (pa.duration - prev.sourceOut) / prev.speed)
            if tail < d { d = max(0.1, (tail * 100).rounded(.down) / 100); note = "Shortened to \(d) s: the outgoing clip \(prev.name) has only \(String(format: "%.2f", tail)) s of media past its out point." }
            if tail < 0.1 { note = "The outgoing clip \(prev.name) has no media past its out point; the transition will play over black. Trim its end earlier to give it a tail." }
        }
        d = min(d, found.clip.duration)
        try document.apply("Add transition", origin: origin) { p in try p.updateClip(id) { $0.transitionIn = Transition(kind: k, duration: d) } }
        return TransitionResult(clip: id.short, kind: k.rawValue, duration: d, note: note)
    }

    // MARK: Markers

    struct MarkerInfo: Codable { var id: String, time: Double, name: String, color: String }
    func addMarker(at time: Double, name: String?, colorHex: String?) -> MarkerInfo {
        var m = Marker(time: max(0, time), name: name ?? "")
        if let colorHex { m.colorHex = colorHex }
        document.apply("Add marker", origin: origin) { p in p.markers.append(m); p.markers.sort { $0.time < $1.time } }
        return MarkerInfo(id: m.id.short, time: r(m.time), name: m.name, color: m.colorHex)
    }
    func removeMarker(_ text: String) throws {
        let key = text.lowercased()
        guard let m = project.markers.first(where: { $0.id.uuidString.lowercased().hasPrefix(key) || $0.id.short.lowercased() == key }) else { throw EditError.notFound("marker \(text)") }
        document.apply("Remove marker", origin: origin) { p in p.markers.removeAll { $0.id == m.id } }
    }

    // MARK: Settings

    struct TrackResult: Codable { var id: String, name: String, kind: String, row: Int }
    func addTrack(kind: String, name: String?) throws -> TrackResult {
        guard let k = TrackKind(rawValue: kind.lowercased()) else { throw EditError.invalid("kind must be video or audio") }
        var t: Track!
        document.apply("Add \(k.rawValue) track", origin: origin) { p in t = p.addTrack(name: name, kind: k) }
        return TrackResult(id: t.id.short, name: t.name, kind: t.kind.rawValue, row: project.tracks.firstIndex(where: { $0.id == t.id }) ?? 0)
    }

    /// Row 0 is the top of the timeline and covers the rows below it in the picture.
    func moveTrack(_ track: String, toRow row: Int) throws -> TrackResult {
        guard let id = try resolveTrack(track), let t = project.track(id) else { throw EditError.notFound("track '\(track)'") }
        document.apply("Move track \(t.name)", origin: origin) { p in _ = p.moveTrack(id, toIndex: row) }
        return TrackResult(id: id.short, name: t.name, kind: t.kind.rawValue, row: project.tracks.firstIndex(where: { $0.id == id }) ?? 0)
    }

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
