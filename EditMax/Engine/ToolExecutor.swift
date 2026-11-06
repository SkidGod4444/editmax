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
            var keyframes: [String: [KeyframeInfo]]?   // per parameter, times on the timeline
            var audio: ClipAudio?                      // EQ / high-pass / gate, only when set
            var multicam: MulticamInfo?                // angles, cuts and the audio angle, only for multicam clips
            var sequence: String?                      // name of the nested sequence this clip plays, if any
            var stabilized: Bool?                      // true when stabilize_clip has run on the clip
            var gradeLayers: [ToolExecutor.LayerInfo]? = nil, finish: ClipFinish? = nil   // color layers and finishing, only when set (ColorTools.swift)
            var effects: [String: String]? = nil       // key, blend mode, face / region blur, only when set (EffectsTools.swift)
            var audioLead: Double?, audioTrail: Double?, smoothSlowMotion: String?   // J/L cut and smooth slow motion, only when set (EditingTools.swift)
        }
        struct KeyframeInfo: Codable { var time: Double, value: Double, ease: String }
        struct MarkerInfo: Codable { var id: String, time: Double, name: String, color: String }
        struct TextInfo: Codable { var id: String, text: String, start: Double, end: Double, preset: String?, caption: String?; var animation: TextAnimation? = nil, lowerThird: LowerThird? = nil; var font: String? = nil, face: String? = nil }   // font: the chosen family (absent = the preset's font); face: its PostScript name
        struct TrackInfo: Codable { var id: String, name: String, kind: String, clipCount: Int, muted: Bool, hidden: Bool; var duckUnder: String?; var duckLevel: Double? }
        var project: String, projectID: String, width: Int, height: Int, fps: Double, duration: Double
        var tracks: [TrackInfo], clips: [ClipInfo], texts: [TextInfo], markers: [MarkerInfo], historyCount: Int
        var playhead: Double?
        var useProxies: Bool
        /// Pairs of texts that cover each other at some moment ("'A' and 'B' overlap 1.4–4.4 s"); absent when none do.
        var textOverlaps: [String]?
        var color: String? = nil   // hlg or pq for an HDR project
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
                                   fadeIn: c.fadeIn > 0 ? c.fadeIn : nil, fadeOut: c.fadeOut > 0 ? c.fadeOut : nil, transition: c.transitionIn,
                                   keyframes: c.isAnimated ? c.animations.mapValues { $0.map { .init(time: r(c.start + $0.time), value: r($0.value), ease: $0.ease.rawValue) } } : nil,
                                   audio: c.audio.isDefault ? nil : c.audio,
                                   multicam: c.multicam.map { multicamInfo(c, $0) },
                                   sequence: p.sequence(of: c)?.name,
                                   stabilized: c.stabilization == nil ? nil : true))
                if !c.grades.isEmpty || c.finish != nil { clips[clips.count - 1].gradeLayers = c.grades.isEmpty ? nil : layersResult(c.id, "").layers; clips[clips.count - 1].finish = c.finish }
                Self.annotateEditing(&clips[clips.count - 1], c)
            }
        }
        var summary = TimelineSummary(
            project: document.displayName, projectID: document.id.short,
            width: p.settings.width, height: p.settings.height, fps: p.settings.fps, duration: r(p.duration),
            tracks: p.tracks.map { t in .init(id: t.id.short, name: t.name, kind: t.kind.rawValue, clipCount: t.clips.count, muted: t.isMuted, hidden: t.isHidden,
                                              duckUnder: t.duck.flatMap { p.track($0.sourceTrackID)?.name }, duckLevel: t.duck?.level) },
            clips: clips.sorted { ($0.track, $0.start) < ($1.track, $1.start) },
            texts: p.texts.map { .init(id: $0.id.short, text: $0.text, start: r($0.start), end: r($0.end), preset: $0.preset, caption: $0.group?.short, font: $0.fontFamily, face: $0.fontName) },
            markers: p.markers.map { .init(id: $0.id.short, time: r($0.time), name: $0.name, color: $0.colorHex) },
            historyCount: p.history.count, playhead: UIRegistry.shared.playheads[document.id]?().map(r), useProxies: p.settings.useProxies,
            textOverlaps: Self.textOverlaps(p))
        addEffects(to: &summary)   // EffectsTools.swift
        return summary
    }

    struct AssetInfo: Codable { var id: String, name: String, kind: String, duration: Double, width: Int?, height: Int?, path: String; var missing: Bool? = nil }   // missing: the file is not at its path (relink_media)
    static func textOverlaps(_ p: Project) -> [String]? {
        let c = TextLayout.collisions(in: p.texts, canvas: p.settings.canvas)
        return c.isEmpty ? nil : c.map { "'\($0.a.text.prefix(24))' and '\($0.b.text.prefix(24))' overlap \(String(format: "%.1f", $0.start))–\(String(format: "%.1f", $0.end)) s" }
    }

    func listAssets() -> [AssetInfo] {
        project.assets.map { var i = AssetInfo(id: $0.id.short, name: $0.name, kind: $0.kind.rawValue, duration: r($0.duration), width: $0.width, height: $0.height, path: $0.path); i.missing = Relink.isMissing($0) ? true : nil; return i }
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
        // Everything imported into any project is in the Assets library too (referenced where it is, as the project does).
        if !imported.isEmpty { document.noteLibraryUse(imported) }
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
        if let id = Project.resolve(text, in: project.allClips.map(\.id)) { return id }
        let byName = project.allClips.filter { $0.name.caseInsensitiveCompare(text) == .orderedSame }
        if byName.count == 1 { return byName[0].id }
        if byName.count > 1 { throw EditError.invalid("\(byName.count) clips are named '\(text)'; use an id: \(byName.map(\.id.short).joined(separator: ", "))") }
        throw EditError.notFound("clip '\(text)'")
    }
    func resolveTrack(_ text: String?) throws -> UUID? {
        guard let text, !text.isEmpty else { return nil }
        // The name first: "A1" is also valid hex, and would otherwise pick a track whose id happens to start with a1.
        if let t = project.tracks.first(where: { $0.name.lowercased() == text.lowercased() }) { return t.id }
        if let id = Project.resolve(text, in: project.tracks.map(\.id)) { return id }
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
        // Speed in hundredths: a slider drag would otherwise store 3.2109839×, which no one can read or type back.
        let speed = speed.map { max(0.01, ($0 * 100).rounded() / 100) }
        let volume = volume.map { max(0, min(2, $0)) }, opacity = opacity.map { max(0, min(1, $0)) }
        let named = [speed.map { "Speed \(ProjectDiff.fmt($0))×" }, volume.map { "Volume \(Self.percent($0))" }, opacity.map { "Opacity \(Self.percent($0))" },
                     name.map { _ in "Rename clip" }].compactMap { $0 }
        try document.apply(named.count == 1 ? named[0] : "Edit clip properties", origin: origin, coalesce: coalesce, key: "Edit clip properties") { p in
            try p.updateClip(id) { c in
                if let speed { let src = c.duration * c.speed; c.speed = speed; c.duration = src / speed }
                if let volume { c.volume = volume }
                if let opacity { c.opacity = opacity }
                if let name { c.name = name }
            }
            if speed != nil, let c = p.clip(id)?.clip { try p.checkSplitEditMedia(c) }   // a J/L cut runs at the new speed too
        }
    }

    func rippleTrack(_ track: String) throws {
        guard let tid = try resolveTrack(track) else { throw EditError.invalid("track required") }
        try document.apply("Close gaps on track", origin: origin) { p in try p.ripple(trackID: tid) }
    }

    // MARK: Text

    @discardableResult
    func addText(_ text: String, start: Double, duration: Double, fontSize: Double?, colorHex: String?, x: Double?, y: Double?, preset: String? = nil, font: FontChoice? = nil) throws -> TextOverlay {
        guard duration > 0 else { throw EditError.invalid("duration must be > 0") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EditError.invalid("text is empty") }
        let style = try preset.map { try CaptionPresets.resolve($0) } ?? CaptionPresets.title
        let chosen = try font.map { try face(for: $0, preset: style.name) }   // FontTools.swift
        var t: TextOverlay!
        document.apply("Add text \"\(text.prefix(20))\"", origin: origin) { p in
            t = p.addText(text, start: max(0, start), duration: duration, fontSize: fontSize ?? style.fontSize, colorHex: colorHex ?? style.color, x: x ?? 0.5, y: y ?? style.y)
            if preset != nil { p.texts[p.texts.count - 1].preset = style.name; t = p.texts[p.texts.count - 1] }
            if let chosen { p.texts[p.texts.count - 1].fontName = chosen.name; p.texts[p.texts.count - 1].fontFamily = chosen.family; t = p.texts[p.texts.count - 1] }
            // Never on top of another text: a title added where a caption or another title already sits moves to the
            // nearest free band (the UI and the tool result both say so).
            if let clear = TextLayout.clearY(for: t, among: p.texts, canvas: p.settings.canvas) { p.texts[p.texts.count - 1].y = clear; t = p.texts[p.texts.count - 1] }
        }
        if let family = chosen?.family { FontLibrary.shared.noteUsed(family) }
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

    func rippleDelete(_ ranges: [RangeInfo], label: String) -> CleanupResult {
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

    struct SnapshotInfo: Codable { var id: String, label: String, origin: String, createdAt: Date, changes: String }
    /// Newest first. Each entry is the state *before* the edit it is named after; `changes` says what that edit did.
    func listHistory(limit: Int = 50) -> [SnapshotInfo] {
        let h = project.history
        return h.indices.suffix(limit).reversed().map { k in
            let changes: String = {
                guard let before = try? EditMaxDocument.decoder.decode(Project.self, from: h[k].project),
                      let after = k == h.count - 1 ? project : (try? EditMaxDocument.decoder.decode(Project.self, from: h[k + 1].project)) else { return "" }
                return ProjectDiff.summary(from: before, to: after)
            }()
            return .init(id: h[k].id.short, label: h[k].label, origin: h[k].origin.rawValue, createdAt: h[k].createdAt, changes: changes)
        }
    }
    func restore(_ snapshot: String) throws {
        guard let id = Project.resolve(snapshot, in: project.history.map(\.id)) else { throw EditError.notFound("snapshot '\(snapshot)'") }
        try document.restore(snapshotID: id, origin: origin)
    }

    // MARK: Export

    /// With `chapters`, the markers also go to `<basename>.chapters.txt` beside the MP4 (skipped when there are none; a sidecar failure never fails the export).
    func exportVideo(to path: String, preset: ExportService.Preset = .high, chapters: Bool = false, progress: ((Double) -> Void)? = nil) async throws -> ExportService.Result {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        // The container follows the preset: a "cut.mp4" asked for as ProRes is written as cut.mov, and the reverse.
        if url.pathExtension.lowercased() != preset.fileExtension {
            if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) { url.deletePathExtension() }
            url.appendPathExtension(preset.fileExtension)
        }
        var r = try await ExportService.export(project, to: url, preset: preset, progress: progress)
        if chapters, !project.markers.isEmpty { r.chapters = try? Chapters.write(project, nextTo: url).path }
        return r
    }

    // MARK: Playhead and frames

    func setPlayhead(_ seconds: Double, play: Bool) {
        document.seekRequest = (max(0, seconds), play)
    }

    /// Render one frame of the timeline (video tracks only; text/image overlays are composited on top) as PNG data.
    /// The composed frame at a time as an sRGB-tagged CGImage, and the render size.
    func renderFrame(at seconds: Double) async throws -> (CGImage, CGSize) {
        guard !project.allClips.isEmpty || !project.texts.isEmpty else { throw EditError.invalid("nothing to render at \(seconds) s: the timeline is empty") }
        let out = try await CompositionBuilder.build(project)
        defer { withExtendedLifetime(out) {} }   // its source assets must outlive the render (`Output.sources`)
        guard let vts = try? await out.composition.loadTracks(withMediaType: .video), !vts.isEmpty else { throw EditError.invalid("nothing to render at \(seconds) s: the composition has no video track") }
        let gen = AVAssetImageGenerator(asset: out.composition)
        gen.videoComposition = out.videoComposition
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let t = CMTime(seconds: min(max(0, seconds), max(0, out.duration.seconds - 0.05)), preferredTimescale: CompositionBuilder.timescale)
        let raw = try await gen.image(at: t).image   // the compositor draws titles and stills too
        return (raw.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? raw, out.renderSize)   // the pixels are sRGB already; retag, don't convert
    }

    func captureFrame(at seconds: Double, maxWidth: Int = 960) async throws -> Data {
        let (frame, renderSize) = try await renderFrame(at: seconds)
        let out = (renderSize: renderSize, ())
        let scale = min(1, CGFloat(maxWidth) / out.renderSize.width)
        let w = Int((out.renderSize.width * scale).rounded()), h = Int((out.renderSize.height * scale).rounded())
        // Draw into a bitmap of exactly w×h pixels (an NSImage lockFocus would use the screen's 2× backing scale).
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { throw EditError.invalid("could not make a bitmap") }
        ctx.cgContext.interpolationQuality = .high
        ctx.cgContext.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let png = rep.representation(using: .png, properties: [:]) else { throw EditError.invalid("could not encode frame") }
        return png
    }

    // MARK: Look: transform, color, fades, transitions

    func setClipTransform(_ clip: String, scale: Double?, x: Double?, y: Double?, rotation: Double?, cropLeft: Double?, cropRight: Double?, cropTop: Double?, cropBottom: Double?, reset: Bool) throws {
        let id = try resolveClip(clip)
        let p100 = { (v: Double) in Self.percent(v) }
        let named = [scale.map { "Scale \(p100(max(0.05, min(10, $0))))" }, x.map { "Position X \(p100($0))" }, y.map { "Position Y \(p100($0))" },
                     rotation.map { "Rotation \(Int($0.rounded()))°" }, cropLeft.map { "Crop left \(p100($0))" }, cropRight.map { "Crop right \(p100($0))" },
                     cropTop.map { "Crop top \(p100($0))" }, cropBottom.map { "Crop bottom \(p100($0))" }].compactMap { $0 }
        let label = reset ? "Reset transform" : named.count == 1 ? named[0] : "Transform clip"
        // Reset is a button: its own undo step, never folded into the drag before it.
        try document.apply(label, origin: origin, coalesce: coalesce && !reset, key: "Transform clip") { p in
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

    func setClipColor(_ clip: String, exposure: Double?, contrast: Double?, saturation: Double?, temperature: Double?, tint: Double?, reset: Bool,
                      shadows: Double? = nil, midtones: Double? = nil, highlights: Double? = nil, vibrance: Double? = nil, lut: String? = nil, lutMix: Double? = nil,
                      inputLut: String? = nil) throws {
        if let inputLut, !inputLut.isEmpty, inputLut.lowercased() != "none" {
            guard FileManager.default.fileExists(atPath: inputLut) else { throw EditError.notFound("input LUT '\(inputLut)': the path of a .cube conversion LUT (for example DJI's D-Log to Rec.709)") }
            guard Looks.cube(for: inputLut) != nil else { throw EditError.invalid("could not read the LUT at \(inputLut) (needs LUT_3D_SIZE and N³ rgb lines)") }
        }
        let id = try resolveClip(clip)
        if let lut, !lut.isEmpty, lut.lowercased() != "none" {
            guard Looks.isBuiltin(lut) || FileManager.default.fileExists(atPath: lut) else { throw EditError.notFound("look '\(lut)': use one of \(Looks.builtin.joined(separator: ", ")) or the path of a .cube file") }
            guard Looks.cube(for: lut) != nil else { throw EditError.invalid("could not read the LUT at \(lut) (needs LUT_3D_SIZE and N³ rgb lines)") }
        }
        let named = [exposure.map { "Exposure \(String(format: "%+.1f", $0))" }, contrast.map { "Contrast \(Self.percent($0))" }, saturation.map { "Saturation \(Self.percent($0))" },
                     temperature.map { "Temperature \(Int($0.rounded()))" }, tint.map { "Tint \(Int($0.rounded()))" }, shadows.map { "Shadows \(Int(($0 * 100).rounded()))" },
                     midtones.map { "Midtones \(Int(($0 * 100).rounded()))" }, highlights.map { "Highlights \(Int(($0 * 100).rounded()))" },
                     vibrance.map { "Vibrance \(Int(($0 * 100).rounded()))" }, lutMix.map { "Look mix \(Self.percent($0))" }].compactMap { $0 }
        let label = reset ? "Reset color" : (named.count == 1 && lut == nil && inputLut == nil) ? named[0] : "Color clip"
        // Reset is a button: its own undo step, never folded into the drag before it.
        try document.apply(label, origin: origin, coalesce: coalesce && !reset, key: "Color clip") { p in
            try p.updateClip(id) { c in
                if reset { c.color = .identity }
                if let exposure { c.color.exposure = max(-4, min(4, exposure)) }
                if let contrast { c.color.contrast = max(0.25, min(3, contrast)) }
                if let saturation { c.color.saturation = max(0, min(3, saturation)) }
                if let temperature { c.color.temperature = max(-100, min(100, temperature)) }
                if let tint { c.color.tint = max(-100, min(100, tint)) }
                if let shadows { c.color.shadows = max(-1, min(1, shadows)) }
                if let midtones { c.color.midtones = max(-1, min(1, midtones)) }
                if let highlights { c.color.highlights = max(-1, min(1, highlights)) }
                if let vibrance { c.color.vibrance = max(-1, min(1, vibrance)) }
                if let lut { c.color.lut = (lut.isEmpty || lut.lowercased() == "none") ? nil : (Looks.builtin.first { $0.caseInsensitiveCompare(lut) == .orderedSame } ?? lut) }
                if let lutMix { c.color.lutMix = max(0, min(1, lutMix)) }
                if let inputLut { c.color.inputLut = inputLut.isEmpty || inputLut.lowercased() == "none" ? nil : inputLut }
            }
        }
    }

    // MARK: Audio

    /// `voiceIsolation` 0…1 is rendered per asset by `IsolatedAudio` (kicked off here so the preview catches up); the AU
    /// missing on this Mac is an error before anything changes.
    func setClipAudio(_ clip: String, low: Double?, mid: Double?, high: Double?, highPass: Double?, gate: Double?, voiceIsolation: Double? = nil, reset: Bool) throws {
        let id = try resolveClip(clip)
        let isolation = voiceIsolation.map { max(0, min(1, $0)) }
        if let isolation, isolation > 0.001 {
            guard IsolatedAudio.isAvailable else { throw EditError.invalid(IsolatedAudio.unavailableMessage) }
            if let c = project.clip(id)?.clip, let a = IsolatedAudio.audioAsset(of: c, in: project), a.sequenceID != nil { throw EditError.invalid(IsolatedAudio.sequenceMessage) }
        }
        try document.apply(reset ? "Reset clip audio" : "Clip audio", origin: origin, coalesce: coalesce && !reset, key: "Clip audio") { p in   // Reset is a button: its own step
            try p.updateClip(id) { c in
                if reset { c.audio.clearCleanup() }   // EQ, high-pass, gate, isolation; the dynamics have their own controls
                if let low { c.audio.lowGain = max(-18, min(18, low)) }
                if let mid { c.audio.midGain = max(-18, min(18, mid)) }
                if let high { c.audio.highGain = max(-18, min(18, high)) }
                if let highPass { c.audio.highPass = highPass <= 0 ? 0 : max(20, min(2000, highPass)) }
                if let gate { c.audio.gate = gate >= 0 ? 0 : max(-90, gate) }
                if let isolation { c.audio.voiceIsolation = isolation < 0.005 ? 0 : isolation }
            }
        }
        if let found = project.clip(id)?.clip, found.audio.needsIsolation, let asset = IsolatedAudio.audioAsset(of: found, in: project) {
            IsolatedAudio.shared.schedule(asset, amount: found.audio.voiceIsolation)
        }
    }

    struct DuckResult: Codable { var track: String, under: String?, level: Double?, attack: Double?, release: Double? }
    /// Ducks `track` under `under` (a track name or id); `under` "none" removes the ducking.
    func setDucking(_ track: String, under: String?, level: Double?, attack: Double?, release: Double?) throws -> DuckResult {
        guard let tid = try resolveTrack(track), let t = project.track(tid) else { throw EditError.notFound("track '\(track)'") }
        if under?.lowercased() == "none" {
            document.apply("Stop ducking \(t.name)", origin: origin) { p in if let i = p.tracks.firstIndex(where: { $0.id == tid }) { p.tracks[i].duck = nil } }
            return DuckResult(track: t.name, under: nil, level: nil, attack: nil, release: nil)
        }
        var d = t.duck
        if let under {
            guard let sid = try resolveTrack(under), sid != tid, let s = project.track(sid) else { throw EditError.invalid("under must name another track") }
            d = Ducking(sourceTrackID: s.id, level: d?.level ?? 0.25, attack: d?.attack ?? 0.15, release: d?.release ?? 0.4)
        }
        guard var duck = d else { throw EditError.invalid("say which track to duck under") }
        if let level { duck.level = max(0, min(1, level)) }
        if let attack { duck.attack = max(0.01, min(3, attack)) }
        if let release { duck.release = max(0.01, min(5, release)) }
        let final = duck
        document.apply("Duck \(t.name)", origin: origin, coalesce: coalesce) { p in if let i = p.tracks.firstIndex(where: { $0.id == tid }) { p.tracks[i].duck = final } }
        return DuckResult(track: t.name, under: project.track(final.sourceTrackID)?.name, level: final.level, attack: final.attack, release: final.release)
    }

    // MARK: Frame analysis

    struct FrameStats: Codable {
        var time: Double, width: Int, height: Int
        var meanRGB: [Double], lumaMean: Double, lumaMedian: Double
        var blackClipped: Double, whiteClipped: Double   // fraction of pixels at or below 2/255, at or above 253/255
        var lumaHistogram: [Int]                           // 16 bins, dark to bright
        var note: String
        var parade: ColorScopes.ParadeStats? = nil         // per-channel levels and the vectorscope summary (ColorScopes.swift)
        var vectorscope: ColorScopes.VectorStats? = nil
    }

    /// Numbers about the composed frame at a time (what the scopes show), so an agent can grade without looking at pixels.
    func frameStats(at seconds: Double) async throws -> FrameStats {
        let (frame, _) = try await renderFrame(at: seconds)
        let w = 320, h = max(1, Int(Double(w) * Double(frame.height) / Double(max(1, frame.width))))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditError.invalid("could not sample the frame") }
        ctx.interpolationQuality = .medium
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = [0.0, 0.0, 0.0], hist = [Int](repeating: 0, count: 16), lumas: [Double] = []
        var black = 0, white = 0
        lumas.reserveCapacity(w * h)
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            sum[0] += r; sum[1] += g; sum[2] += b
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lumas.append(l)
            hist[min(15, Int(l / 16))] += 1
            if l <= 2 { black += 1 }
            if l >= 253 { white += 1 }
        }
        let n = Double(w * h)
        lumas.sort()
        let mean = lumas.reduce(0, +) / n
        var note = "Means are 0–255 after the clip's color and looks."
        if Double(black) / n > 0.3 { note += " Over 30% of the frame is crushed black." }
        if Double(white) / n > 0.1 { note += " Over 10% of the frame is clipped white." }
        var stats = FrameStats(time: r(seconds), width: frame.width, height: frame.height, meanRGB: sum.map { r($0 / n) }, lumaMean: r(mean), lumaMedian: r(lumas[lumas.count / 2]),
                               blackClipped: r(Double(black) / n), whiteClipped: r(Double(white) / n), lumaHistogram: hist, note: note)
        (stats.parade, stats.vectorscope) = ColorScopes.stats(rgba: px)
        return stats
    }

    func setClipFades(_ clip: String, fadeIn: Double?, fadeOut: Double?) throws {
        let id = try resolveClip(clip)
        let label = switch (fadeIn, fadeOut) {
        case (let i?, nil): "Fade in \(ProjectDiff.fmt((max(0, i) * 10).rounded() / 10)) s"
        case (nil, let o?): "Fade out \(ProjectDiff.fmt((max(0, o) * 10).rounded() / 10)) s"
        default: "Fade clip"
        }
        try document.apply(label, origin: origin, coalesce: coalesce, key: "Fade clip") { p in
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

    // MARK: Keyframes

    struct KeyframeResult: Codable { var clip: String, param: String, time: Double, local: Double, value: Double, ease: String, count: Int }
    static func param(_ text: String) throws -> ClipParam {
        let key = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "position", with: "")
        guard let p = ClipParam.allCases.first(where: { $0.rawValue == key }) else { throw EditError.invalid("param must be one of \(ClipParam.allCases.map(\.rawValue).joined(separator: ", "))") }
        return p
    }
    static func ease(_ text: String?) throws -> Keyframe.Ease? {
        guard let text else { return nil }
        guard let e = Keyframe.Ease(rawValue: text.lowercased()) else { throw EditError.invalid("ease must be linear, smooth or hold") }
        return e
    }
    static let paramRanges: [ClipParam: ClosedRange<Double>] = [.scale: 0.05...10, .x: -2...2, .y: -2...2, .rotation: -3600...3600, .opacity: 0...1, .exposure: -4...4, .contrast: 0.25...3,
                                                               .saturation: 0...3, .temperature: -100...100, .tint: -100...100, .volume: 0...2, .speed: 0...8]

    /// Sets a keyframe at a timeline time (nil = the playhead). The first keyframe on a parameter starts its animation from the plain value.
    func setKeyframe(_ clip: String, param: String, time: Double?, value: Double, ease: String?) throws -> KeyframeResult {
        let id = try resolveClip(clip)
        let p = try Self.param(param), e = try Self.ease(ease)
        guard let found = project.clip(id) else { throw EditError.notFound("clip \(clip)") }
        let tl = time ?? UIRegistry.shared.playheads[document.id]?() ?? found.clip.start
        let local = max(0, min(found.clip.duration, tl - found.clip.start))
        let range = Self.paramRanges[p] ?? -1e9...1e9
        let v = max(range.lowerBound, min(range.upperBound, value))
        try document.apply("Keyframe \(p.title)", origin: origin, coalesce: coalesce) { pr in try pr.updateClip(id) { $0.setKeyframe(p, at: local, value: v, ease: e) } }
        let c = project.clip(id)!.clip
        return KeyframeResult(clip: id.short, param: p.rawValue, time: r(c.start + local), local: r(local), value: r(v), ease: (e ?? .linear).rawValue, count: c.keyframes(p).count)
    }

    /// Removes the keyframe at a timeline time, or every keyframe of the parameter (`all`), which freezes it at the playhead's value.
    func removeKeyframe(_ clip: String, param: String, time: Double?, all: Bool) throws -> Int {
        let id = try resolveClip(clip)
        let p = try Self.param(param)
        guard let found = project.clip(id) else { throw EditError.notFound("clip \(clip)") }
        if all {
            let n = found.clip.keyframes(p).count
            let ph = UIRegistry.shared.playheads[document.id]?() ?? found.clip.start
            try document.apply("Clear \(p.title) keyframes", origin: origin) { pr in try pr.updateClip(id) { $0.clearAnimation(p, freezeAt: max(0, min($0.duration, ph - $0.start))) } }
            return n
        }
        let tl = time ?? UIRegistry.shared.playheads[document.id]?() ?? found.clip.start
        let local = tl - found.clip.start
        var removed = false
        try document.apply("Remove \(p.title) keyframe", origin: origin) { pr in try pr.updateClip(id) { removed = $0.removeKeyframe(p, at: local) } }
        guard removed else { throw EditError.notFound("no \(p.rawValue) keyframe at \(r(tl)) s") }
        return 1
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

    /// Renames a track. Names are how people and agents point at tracks ("put it on Dialogue"), so they must be unique,
    /// not empty, and not "Text" (the titles row).
    func renameTrack(_ track: String, to newName: String) throws -> TrackResult {
        guard let id = try resolveTrack(track), let t = project.track(id) else { throw EditError.notFound("track '\(track)'") }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EditError.invalid("a track needs a name") }
        guard name.count <= 32 else { throw EditError.invalid("a track name can be at most 32 characters") }
        guard name.lowercased() != "text" else { throw EditError.invalid("\"Text\" is the titles row's name; pick another") }
        if project.tracks.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) {
            throw EditError.invalid("there is already a track called \(name)")
        }
        document.apply("Rename track \(t.name) to \(name)", origin: origin) { p in
            if let i = p.tracks.firstIndex(where: { $0.id == id }) { p.tracks[i].name = name }
        }
        return TrackResult(id: id.short, name: name, kind: t.kind.rawValue, row: project.tracks.firstIndex(where: { $0.id == id }) ?? 0)
    }

    func setProjectSettings(width: Int?, height: Int?, fps: Double?, name: String?, useProxies: Bool? = nil) throws {
        // Say what changed in History ("Resolution 1080×1920"), not just "Project settings".
        var parts: [String] = []
        if width != nil || height != nil { parts.append("Resolution \(width ?? project.settings.width)×\(height ?? project.settings.height)") }
        if let fps { parts.append("Frame rate \(ProjectFormat.fpsText(fps))") }
        if name != nil { parts.append("Rename project") }
        if useProxies != nil { parts.append(useProxies == true ? "Preview from proxies" : "Preview from originals") }
        document.apply(parts.isEmpty ? "Project settings" : parts.joined(separator: ", "), origin: origin) { p in
            if let width { p.settings.width = max(16, width) }
            if let height { p.settings.height = max(16, height) }
            if let fps { p.settings.fps = max(1, fps) }
            if let name { p.name = name }
            if let useProxies { p.settings.useProxies = useProxies }
        }
        if useProxies == true { Task { @MainActor in ProxyStore.shared.build(project.assets) } }
    }

    // MARK: Multicam

    struct MulticamInfo: Codable {
        struct Angle: Codable { var index: Int, asset: String, name: String, offset: Double }
        struct Cut: Codable { var time: Double, angle: Int }
        var clip: String, angles: [Angle], cuts: [Cut], audioAngle: Int
        var note: String?
    }
    func multicamInfo(_ c: Clip, _ mc: Multicam) -> MulticamInfo {
        MulticamInfo(clip: c.id.short,
                     angles: mc.angles.enumerated().map { .init(index: $0.offset + 1, asset: $0.element.short, name: project.asset($0.element)?.name ?? "missing", offset: r(mc.offset($0.offset))) },
                     cuts: mc.cuts.map { .init(time: r(c.start + $0.time), angle: $0.angle + 1) }, audioAngle: mc.audioAngle + 1)
    }
    private func multicamClip(_ text: String) throws -> (Clip, Multicam) {
        let id = try resolveClip(text)
        guard let c = project.clip(id)?.clip else { throw EditError.notFound("clip '\(text)'") }
        guard let mc = c.multicam else { throw EditError.invalid("clip \(c.id.short) is not a multicam clip; make one with make_multicam") }
        return (c, mc)
    }

    /// Folds several clips into one multicam clip: the earliest one stays and becomes angle 1, the others are removed and
    /// become its angles. `sync` is "audio" (line the angles up by their sound), "start" (they were placed in sync on
    /// the timeline) or "none" (offsets 0; set them with set_multicam).
    func makeMulticam(_ clips: [String], sync: String) async throws -> MulticamInfo {
        let ids = try clips.map(resolveClip)
        var found = ids.compactMap { project.clip($0)?.clip }
        guard found.count >= 2 else { throw EditError.invalid("a multicam clip needs at least two clips") }
        guard Set(found.map(\.id)).count == found.count else { throw EditError.invalid("the same clip is listed twice") }
        for c in found {
            guard let a = project.asset(c.assetID), a.kind != .image else { throw EditError.invalid("clip \(c.id.short) is a still; angles must be video or audio") }
            guard c.multicam == nil else { throw EditError.invalid("clip \(c.id.short) is already a multicam clip") }
        }
        // Earliest clip is the base; on a tie the order given wins (the inspector lists the shown clip first).
        found = found.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        let base = found[0], others = Array(found.dropFirst())
        let baseAsset = project.asset(base.assetID)!
        var offsets: [Double] = [0]
        var notes: [String] = []
        switch sync.lowercased() {
        case "audio":
            for o in others {
                let a = project.asset(o.assetID)!
                let r = try await AngleSync.offset(of: a.url, relativeTo: baseAsset.url)
                if r.confidence < 0.3 {
                    // Nothing to lock onto (silence, a steady tone): trust the timeline placement instead.
                    offsets.append((o.sourceIn - o.start) - (base.sourceIn - base.start))
                    notes.append("\(a.name): audio match too weak (confidence \(String(format: "%.2f", r.confidence))), kept the timeline placement (\(String(format: "%+.2f", offsets.last!)) s)")
                } else {
                    offsets.append(r.offset)
                    notes.append("\(a.name): \(String(format: "%+.2f", r.offset)) s (confidence \(String(format: "%.2f", r.confidence)))")
                }
            }
        case "start":
            for o in others { offsets.append((o.sourceIn - o.start) - (base.sourceIn - base.start)) }
        case "none", "": for _ in others { offsets.append(0) }
        default: throw EditError.invalid("sync must be audio, start or none")
        }
        let mc = Multicam(angles: [base.assetID] + others.map(\.assetID), offsets: offsets)
        try document.apply("Make multicam (\(found.count) angles)", origin: origin) { p in
            _ = p.removeClips(others.map(\.id))
            try p.updateClip(base.id) { $0.multicam = mc }
        }
        var info = multicamInfo(project.clip(base.id)!.clip, mc)
        info.note = notes.isEmpty ? nil : notes.joined(separator: "; ")
        return info
    }

    /// Switches the picture to `angle` (1-based) from a timeline time on, or removes the cut there.
    func cutAngle(_ clip: String, at time: Double, angle: Int, remove: Bool = false) throws -> MulticamInfo {
        let (c, mc) = try multicamClip(clip)
        let local = time - c.start
        guard local >= -0.001, local < c.duration else { throw EditError.invalid("time \(r(time)) is outside the clip (\(r(c.start))...\(r(c.end)))") }
        var next = mc
        if remove {
            guard next.removeCut(at: max(0, local)) else { throw EditError.notFound("cut at \(r(time))") }
        } else {
            guard angle >= 1, angle <= mc.angles.count else { throw EditError.invalid("angle must be 1...\(mc.angles.count)") }
            let ai = angle - 1
            let source = c.sourceIn + mc.offset(ai) + c.sourceOffset(at: max(0, local))
            if let a = project.asset(mc.angles[ai]), source < -0.001 || source > a.duration - 0.01 {
                throw EditError.invalid("angle \(angle) (\(a.name)) has no media at that time: source \(r(source)) s of \(r(a.duration)) s; adjust its offset with set_multicam")
            }
            next.setCut(at: max(0, local), angle: ai)
        }
        try document.apply(remove ? "Remove angle cut" : "Cut to angle \(angle)", origin: origin) { p in try p.updateClip(c.id) { $0.multicam = next } }
        return multicamInfo(project.clip(c.id)!.clip, next)
    }

    /// Audio angle (1-based), explicit offsets (seconds per angle, angle 1 is 0), or flatten the clip into plain clips.
    func setMulticam(_ clip: String, audioAngle: Int?, offsets: [Double]?, flatten: Bool) throws -> MulticamInfo {
        let (c, mc) = try multicamClip(clip)
        if flatten {
            let pieces = c.multicamPieces(in: project)
            try document.apply("Flatten multicam", origin: origin) { p in
                let (ti, ci) = try p.clipIndex(c.id)
                p.tracks[ti].clips.replaceSubrange(ci...ci, with: pieces)
                p.tracks[ti].clips.sort { $0.start < $1.start }
            }
            var info = multicamInfo(c, mc); info.note = "flattened into \(pieces.count) clip\(pieces.count == 1 ? "" : "s"): \(pieces.map(\.id.short).joined(separator: ", "))"
            return info
        }
        var next = mc
        if let audioAngle { guard audioAngle >= 1, audioAngle <= mc.angles.count else { throw EditError.invalid("audio_angle must be 1...\(mc.angles.count)") }; next.audioAngle = audioAngle - 1 }
        if let offsets {
            guard offsets.count == mc.angles.count else { throw EditError.invalid("offsets needs one value per angle (\(mc.angles.count))") }
            next.offsets = offsets
        }
        try document.apply("Multicam settings", origin: origin) { p in try p.updateClip(c.id) { $0.multicam = next } }
        return multicamInfo(project.clip(c.id)!.clip, next)
    }

    /// Recomputes every angle's offset from the audio.
    func syncAngles(_ clip: String) async throws -> MulticamInfo {
        let (c, mc) = try multicamClip(clip)
        guard let base = project.asset(mc.angles[0]) else { throw EditError.notFound("angle 1 asset") }
        var offsets: [Double] = [0], notes: [String] = []
        for aid in mc.angles.dropFirst() {
            guard let a = project.asset(aid) else { offsets.append(0); continue }
            let r = try await AngleSync.offset(of: a.url, relativeTo: base.url)
            offsets.append(r.offset); notes.append("\(a.name): \(String(format: "%+.2f", r.offset)) s (confidence \(String(format: "%.2f", r.confidence)))")
        }
        var info = try setMulticam(clip, audioAngle: nil, offsets: offsets, flatten: false)
        info.note = notes.joined(separator: "; ")
        _ = c
        return info
    }

    // MARK: Nested sequences

    struct SequenceInfo: Codable {
        struct ClipRow: Codable { var id: String, name: String, track: String, start: Double, end: Double }
        var id: String, name: String, duration: Double, tracks: [String], clips: [ClipRow], rendered: Bool
        var clip: String?
        var note: String?
    }
    func sequenceInfo(_ seq: Sequence) -> SequenceInfo {
        SequenceInfo(id: seq.id.short, name: seq.name, duration: r(seq.project.duration), tracks: seq.project.tracks.map(\.name),
                     clips: seq.project.tracks.flatMap { t in t.clips.map { .init(id: $0.id.short, name: $0.name, track: t.name, start: r($0.start), end: r($0.end)) } },
                     rendered: FileManager.default.fileExists(atPath: SequenceRenderer.url(for: seq).path))
    }
    func resolveSequence(_ text: String) throws -> Sequence {
        if let id = Project.resolve(text, in: project.sequences.map(\.id)), let s = project.sequence(id) { return s }
        if let s = project.sequences.first(where: { $0.name.lowercased() == text.lowercased() }) { return s }
        if let cid = Project.resolve(text, in: project.allClips.map(\.id)), let c = project.clip(cid)?.clip, let s = project.sequence(of: c) { return s }
        throw EditError.notFound("sequence '\(text)'; sequences: \(project.sequences.map(\.name).joined(separator: ", "))")
    }

    /// Folds clips into one nested sequence: they leave the timeline (their tracks keep their names inside the
    /// sequence, times start at 0) and one clip playing the sequence takes their place from the earliest start, on the
    /// track of the earliest clip. Nothing else moves: no other clip, text or marker, on any track. When a clip that is
    /// not nested sits inside the span on that track, the nest goes on a new track right under it instead.
    /// The render happens before this returns, so the preview plays at once.
    func nestClips(_ clips: [String], name: String?) async throws -> SequenceInfo {
        let ids = try clips.map(resolveClip)
        let picked = ids.compactMap { project.clip($0) }
        guard !picked.isEmpty else { throw EditError.invalid("no clips to nest") }
        let minStart = picked.map(\.clip.start).min()!, maxEnd = picked.map(\.clip.end).max()!
        var sub = Project()
        sub.settings = project.settings
        sub.name = name ?? "Sequence \(project.sequences.count + 1)"
        sub.tracks = []
        for t in project.tracks {
            let mine = t.clips.filter { c in ids.contains(c.id) }
            guard !mine.isEmpty else { continue }
            var nt = Track(name: t.name, kind: t.kind)
            nt.clips = mine.map { var c = $0; c.start -= minStart; return c }
            sub.tracks.append(nt)
        }
        let usedAssets = Set(picked.map(\.clip.assetID)).union(picked.flatMap { $0.clip.multicam?.angles ?? [] })
        sub.assets = project.assets.filter { usedAssets.contains($0.id) }
        sub.sequences = project.sequences.filter { s in sub.assets.contains { $0.sequenceID == s.id } }
        let seq = Sequence(name: sub.name, project: sub)
        let url = try await SequenceRenderer.shared.ensure(seq, depth: 1)
        // A sequence with no picture is an audio asset, so its clip lands on an audio track.
        let hasPicture = sub.tracks.contains { $0.kind == .video && !$0.clips.isEmpty }
        let asset = Asset(name: seq.name, path: url.path, kind: hasPicture ? .sequence : .audio, duration: sub.duration, width: hasPicture ? sub.settings.width : nil, height: hasPicture ? sub.settings.height : nil, sequenceID: seq.id)
        let kind: TrackKind = hasPicture ? .video : .audio
        let hostTrack = picked.sorted { $0.clip.start < $1.clip.start }.first { $0.track.kind == kind }?.track.id
        let newClip = Clip(assetID: asset.id, name: asset.name, start: minStart, duration: maxEnd - minStart)
        document.apply("Nest \(picked.count) clip\(picked.count == 1 ? "" : "s") into \(seq.name)", origin: origin) { p in
            _ = p.removeClips(ids)
            p.sequences.append(seq)
            p.assets.append(asset)
            // Not an insert: an insert at a time ripples every track, and the nest only takes the place of its clips.
            p.placeWithoutRipple(newClip, preferring: hostTrack, kind: kind)
        }
        var info = sequenceInfo(seq); info.clip = newClip.id.short
        return info
    }

    /// Puts a nested sequence's clips back on the timeline in place of the clip that plays it (the whole sequence,
    /// from the clip's start; tracks are matched by name and created when missing). The clips keep their own ids when
    /// those are free, so nest then unnest gives back exactly the clips that went in. The sequence is dropped when
    /// nothing else plays it.
    func unnestClip(_ clip: String) throws -> Int {
        let id = try resolveClip(clip)
        guard let (track, c) = project.clip(id), let asset = project.asset(c.assetID), let seq = project.sequence(of: c) else { throw EditError.invalid("clip '\(clip)' does not play a nested sequence") }
        var count = 0
        try document.apply("Unnest \(seq.name)", origin: origin) { p in
            _ = p.removeClips([id])
            for st in seq.project.tracks {
                let tid: UUID
                if let existing = p.tracks.first(where: { $0.name == st.name && $0.kind == st.kind }) { tid = existing.id }
                else { tid = p.addTrack(name: st.name, kind: st.kind).id }
                let ti = try p.trackIndex(tid)
                for sc in st.clips {
                    var nc = sc
                    if p.clip(sc.id) != nil { nc.id = UUID() }   // a second unnest of the same sequence: a copy needs ids of its own
                    nc.start += c.start; p.tracks[ti].clips.append(nc); count += 1
                }
                p.tracks[ti].clips.sort { $0.start < $1.start }
            }
            for a in seq.project.assets where p.asset(a.id) == nil { p.assets.append(a) }
            for s in seq.project.sequences where p.sequence(s.id) == nil { p.sequences.append(s) }
            if !p.allClips.contains(where: { $0.assetID == asset.id }) { p.assets.removeAll { $0.id == asset.id }; p.sequences.removeAll { $0.id == seq.id } }
        }
        _ = track
        return count
    }

    func listSequences() -> [SequenceInfo] { project.sequences.map(sequenceInfo) }

    // MARK: Proxies and templates

    struct ProxyInfo: Codable { var asset: String, name: String, status: String, progress: Double? }
    /// Starts building proxies for every video asset without one; `status` lists where each one stands.
    @MainActor func makeProxies(enable: Bool) -> [ProxyInfo] {
        if enable, !project.settings.useProxies { try? setProjectSettings(width: nil, height: nil, fps: nil, name: nil, useProxies: true) }
        ProxyStore.shared.build(project.assets)
        return proxyStatus()
    }
    @MainActor func proxyStatus() -> [ProxyInfo] {
        project.assets.filter { $0.kind == .video }.map { a in
            _ = ProxyStore.shared.ready(for: a)
            switch ProxyStore.shared.status[a.id] ?? .none {
            case .none: return ProxyInfo(asset: a.id.short, name: a.name, status: "none", progress: nil)
            case .building(let p): return ProxyInfo(asset: a.id.short, name: a.name, status: "building", progress: r(p))
            case .ready: return ProxyInfo(asset: a.id.short, name: a.name, status: "ready", progress: 1)
            case .failed(let e): return ProxyInfo(asset: a.id.short, name: a.name, status: "failed: \(e)", progress: nil)
            }
        }
    }

    func listTemplates() -> [Templates.Info] { Templates.list() }
    /// Replaces the whole project with a template (undoable). Built-ins change the format and empty the timeline.
    func applyTemplate(_ name: String) throws -> Templates.Info {
        let p = try Templates.project(named: name)
        let info = Templates.list().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let hasContent = !project.allClips.isEmpty || !project.texts.isEmpty
        if info?.builtin == true, hasContent {
            // A built-in template is only a frame size and rate: on a timeline with a cut, keep the cut and change the frame
            // (then auto_reframe follows the subject). Only an empty project becomes the fresh template project.
            document.apply("Set frame \(p.settings.width)×\(p.settings.height)", origin: origin) { cur in
                cur.settings.width = p.settings.width; cur.settings.height = p.settings.height; cur.settings.fps = p.settings.fps
            }
        } else {
            document.apply("Apply template \(name)", origin: origin) { cur in
                var next = p; next.history = cur.history; cur = next
            }
        }
        return Templates.list().first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? Templates.Info(name: name, builtin: false, width: p.settings.width, height: p.settings.height, fps: p.settings.fps, summary: "")
    }
    func saveTemplate(_ name: String) throws -> String { try Templates.save(project, as: name).path }

    private func r(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
    /// "80%" for 0.8, as the inspector shows it.
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}
