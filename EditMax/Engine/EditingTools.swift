import Foundation
import AVFoundation

// MARK: - Editing tools
//
// Roll, slip and slide trims, J/L cuts, relink and consolidate, scene detection, three- and four-point edits and match
// frame, smooth slow motion. Same contract as the rest of `ToolExecutor`: one undoable `apply` per call, inputs
// validated and refused (never clamped), results that say what changed.

extension ToolExecutor {
    private var proj: Project { document.project }
    private func r(_ x: Double) -> Double { EditFormat.r(x) }

    struct ClipRef: Codable {
        var id: String, name: String, start: Double, end: Double, sourceIn: Double, sourceOut: Double
        var soundStart: Double?, soundEnd: Double?   // only when the sound is split from the picture
    }
    func ref(_ c: Clip) -> ClipRef {
        ClipRef(id: c.id.short, name: c.name, start: r(c.start), end: r(c.end), sourceIn: r(c.sourceIn), sourceOut: r(c.sourceOut),
                soundStart: c.hasSplitEdit ? r(c.soundStart) : nil, soundEnd: c.hasSplitEdit ? r(c.soundEnd) : nil)
    }

    /// Exactly one of a relative and an absolute amount, turned into a delta.
    private func amount(delta: Double?, absolute: Double?, current: Double, names: (String, String)) throws -> Double {
        switch (delta, absolute) {
        case (let d?, nil): guard d.isFinite else { throw EditError.invalid("\(names.0) must be a number") }; return d
        case (nil, let a?): guard a.isFinite else { throw EditError.invalid("\(names.1) must be a number") }; return a - current
        case (nil, nil): throw EditError.invalid("give \(names.0) or \(names.1)")
        default: throw EditError.invalid("give \(names.0) or \(names.1), not both")
        }
    }

    // MARK: Roll / slip / slide

    struct RollEditResult: Codable { var edit = "roll"; var cutFrom: Double, cutTo: Double, moved: Double, outgoing: ClipRef, incoming: ClipRef, notes: [String]? }

    /// Moves the cut between `clip` and its touching neighbour (`edge` end: the clip after it; start: the clip before).
    func rollEdit(_ clip: String, edge: String?, delta: Double?, to: Double?) throws -> RollEditResult {
        let id = try resolveClip(clip)
        let atEnd: Bool
        switch (edge ?? "end").lowercased() {
        case "end", "out", "right": atEnd = true
        case "start", "in", "left": atEnd = false
        default: throw EditError.invalid("edge must be start or end, not '\(edge ?? "")'")
        }
        guard let c = proj.clip(id)?.clip else { throw EditError.notFound("clip '\(clip)'") }
        let d = try amount(delta: delta, absolute: to, current: atEnd ? c.end : c.start, names: ("delta", "to"))
        var res: Project.RollResult!
        try document.apply("Roll edit", origin: origin, coalesce: coalesce) { p in res = try p.rollEdit(id, atEnd: atEnd, delta: d) }
        return RollEditResult(cutFrom: r(res.from), cutTo: r(res.to), moved: r(res.to - res.from), outgoing: ref(res.outgoing), incoming: ref(res.incoming), notes: res.notes.isEmpty ? nil : res.notes)
    }

    struct SlipResult: Codable { var edit = "slip"; var clip: ClipRef, sourceInFrom: Double, sourceInTo: Double, moved: Double }

    /// Moves which part of the source the clip shows; the clip keeps its place and length.
    func slipClip(_ clip: String, delta: Double?, sourceIn: Double?) throws -> SlipResult {
        let id = try resolveClip(clip)
        guard let c = proj.clip(id)?.clip else { throw EditError.notFound("clip '\(clip)'") }
        let d = try amount(delta: delta, absolute: sourceIn, current: c.sourceIn, names: ("delta", "source_in"))
        var out: Clip!
        try document.apply("Slip clip", origin: origin, coalesce: coalesce) { p in out = try p.slipClip(id, delta: d) }
        return SlipResult(clip: ref(out), sourceInFrom: r(c.sourceIn), sourceInTo: r(out.sourceIn), moved: r(out.sourceIn - c.sourceIn))
    }

    struct SlideResult: Codable { var edit = "slide"; var clip: ClipRef, from: Double, to: Double, moved: Double, previous: ClipRef?, next: ClipRef? }

    /// Moves the clip between its neighbours, which trim to compensate.
    func slideClip(_ clip: String, delta: Double?, to: Double?) throws -> SlideResult {
        let id = try resolveClip(clip)
        guard let c = proj.clip(id)?.clip else { throw EditError.notFound("clip '\(clip)'") }
        let d = try amount(delta: delta, absolute: to, current: c.start, names: ("delta", "to"))
        var res: Project.SlideResult!
        try document.apply("Slide clip", origin: origin, coalesce: coalesce) { p in res = try p.slideClip(id, delta: d) }
        return SlideResult(clip: ref(res.clip), from: r(res.from), to: r(res.to), moved: r(res.to - res.from), previous: res.previous.map(ref), next: res.next.map(ref))
    }

    // MARK: J and L cuts

    struct SplitEditResult: Codable {
        var clip: ClipRef, lead: Double, trail: Double
        var kind: String              // "J cut", "L cut", "J and L cut", "none"
        var neighbours: [ClipRef]?    // neighbours whose sound was trimmed or extended to meet this one
        var overlaps: [String]?       // other sounds on the track that now play at the same time
        var maxLead: Double, maxTrail: Double
    }

    static func splitEditKind(_ c: Clip) -> String {
        switch (c.audioLead > 1e-9, c.audioTrail > 1e-9) {
        case (true, true): return "J and L cut"
        case (true, false): return "J cut"
        case (false, true): return "L cut"
        default: return c.hasSplitEdit ? "sound inside the picture" : "none"
        }
    }

    /// Sets how far the clip's sound starts before (`lead`) and runs after (`trail`) its picture. `neighbour`
    /// overlap (default) plays both sounds where they meet; trim moves the touching neighbour's sound edge too, so
    /// the sounds meet at the new audio cut instead of overlapping (a negative value then extends the neighbour's sound).
    func setSplitEdit(_ clip: String, lead: Double?, trail: Double?, neighbour: String?) throws -> SplitEditResult {
        let id = try resolveClip(clip)
        guard let (track, c) = proj.clip(id) else { throw EditError.notFound("clip '\(clip)'") }
        guard lead != nil || trail != nil else { throw EditError.invalid("give lead and/or trail (seconds; 0 puts the sound back with the picture)") }
        for v in [lead, trail].compactMap({ $0 }) where !v.isFinite { throw EditError.invalid("lead and trail must be numbers") }
        let trimNeighbour: Bool
        switch (neighbour ?? "overlap").lowercased() {
        case "overlap": trimNeighbour = false
        case "trim": trimNeighbour = true
        default: throw EditError.invalid("neighbour must be overlap or trim, not '\(neighbour ?? "")'")
        }
        guard track.kind == .video else { throw EditError.invalid("\(c.name) is on an audio track, so it has no picture to split from; move or trim it instead") }
        guard let asset = proj.asset(c.assetID), asset.kind == .video else { throw EditError.invalid("\(c.name) is a still image; a J/L cut needs a video clip with sound") }
        let newLead = lead ?? c.audioLead, newTrail = trail ?? c.audioTrail
        var plain = c; plain.audioLead = 0; plain.audioTrail = 0
        let room = proj.mediaRoom(plain), minLen = proj.minClipLength
        if newLead > room.head + 1e-4 { throw EditError.invalid("lead \(EditFormat.s(newLead)) s needs media before \(c.name)'s in point; it has \(EditFormat.s(room.head)) s") }
        if newTrail > room.tail + 1e-4 { throw EditError.invalid("trail \(EditFormat.s(newTrail)) s needs media after \(c.name)'s out point; it has \(EditFormat.s(room.tail)) s") }
        if newLead > c.start + 1e-4 { throw EditError.invalid("lead \(EditFormat.s(newLead)) s would start the sound before 0 (\(c.name) starts at \(EditFormat.s(c.start)) s)") }
        if c.duration + newLead + newTrail < minLen { throw EditError.invalid("lead \(EditFormat.s(newLead)) s and trail \(EditFormat.s(newTrail)) s leave the sound shorter than one frame") }

        var changed: [UUID] = []
        try document.apply("Set split edit", origin: origin, coalesce: coalesce) { p in
            try p.updateClip(id) { $0.audioLead = newLead; $0.audioTrail = newTrail }
            guard trimNeighbour else { return }
            if lead != nil, let prev = p.clipBefore(c, on: track), p.track(track.id)?.clips.contains(where: { $0.id == prev.id }) == true {
                var t = prev; t.audioTrail = -newLead
                if t.soundDuration < minLen { throw EditError.invalid("a lead of \(EditFormat.s(newLead)) s would leave \(prev.name)'s sound shorter than one frame") }
                if -newLead > 1e-9 {
                    var pp = prev; pp.audioLead = 0; pp.audioTrail = 0
                    let r = p.mediaRoom(pp).tail
                    if -newLead > r + 1e-4 { throw EditError.invalid("\(prev.name) has only \(EditFormat.s(r)) s of media after its out point to fill a sound gap of \(EditFormat.s(-newLead)) s") }
                }
                try p.updateClip(prev.id) { $0.audioTrail = -newLead }; changed.append(prev.id)
            }
            if trail != nil, let next = p.clipAfter(c, on: track) {
                var t = next; t.audioLead = -newTrail
                if t.soundDuration < minLen { throw EditError.invalid("a trail of \(EditFormat.s(newTrail)) s would leave \(next.name)'s sound shorter than one frame") }
                if -newTrail > 1e-9 {
                    var nn = next; nn.audioLead = 0; nn.audioTrail = 0
                    let r = p.mediaRoom(nn).head
                    if -newTrail > r + 1e-4 { throw EditError.invalid("\(next.name) has only \(EditFormat.s(r)) s of media before its in point to fill a sound gap of \(EditFormat.s(-newTrail)) s") }
                }
                try p.updateClip(next.id) { $0.audioLead = -newTrail }; changed.append(next.id)
            }
        }
        let p = proj
        guard let now = p.clip(id) else { throw EditError.notFound("clip '\(clip)'") }
        let overlaps = now.track.clips.filter { $0.id != id && p.asset($0.assetID)?.kind == .video }.compactMap { o -> String? in
            let a = max(o.soundStart, now.clip.soundStart), b = min(o.soundEnd, now.clip.soundEnd)
            return b - a > 0.01 ? "\(o.name)'s sound plays with this one from \(EditFormat.s(a)) to \(EditFormat.s(b)) s" : nil
        }
        return SplitEditResult(clip: ref(now.clip), lead: r(now.clip.audioLead), trail: r(now.clip.audioTrail), kind: Self.splitEditKind(now.clip),
                               neighbours: changed.isEmpty ? nil : changed.compactMap { p.clip($0)?.clip }.map(ref),
                               overlaps: overlaps.isEmpty ? nil : overlaps, maxLead: r(min(room.head, c.start)), maxTrail: r(room.tail))
    }

    // MARK: Summary fields

    /// The editing fields `inspect_timeline` shows for a clip, only when set.
    static func annotateEditing(_ info: inout TimelineSummary.ClipInfo, _ c: Clip) {
        if abs(c.audioLead) > 1e-9 { info.audioLead = EditFormat.r(c.audioLead) }
        if abs(c.audioTrail) > 1e-9 { info.audioTrail = EditFormat.r(c.audioTrail) }
        if c.smoothSlowMotion != .off { info.smoothSlowMotion = c.smoothSlowMotion.rawValue }
    }

    // MARK: Relink / consolidate

    struct RelinkResult: Codable {
        struct Done: Codable { var asset: String, name: String, from: String, to: String, reason: String }
        struct Left: Codable { var asset: String, name: String, path: String, reason: String; var candidates: [String]? }
        var relinked: [Done], stillMissing: [Left], dryRun: Bool
        var message: String
    }

    private func expand(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }

    /// Points missing (or chosen) assets at files on disk again. `path`: this file for `asset`. `folder`: search it
    /// for every missing asset (or just `asset`). Neither: follow the bookmarks only. Files are only read.
    func relinkMedia(asset: String?, path: String?, folder: String?, recursive: Bool, dryRun: Bool) async throws -> RelinkResult {
        let p = proj
        var targets: [Asset]
        if let asset {
            guard let a = p.asset(try resolveAsset(asset)) else { throw EditError.notFound("asset '\(asset)'") }
            if a.sequenceID != nil { throw EditError.invalid("\(a.name) is a nested sequence; its file is a render EditMax makes itself") }
            if !Relink.isMissing(a), path == nil, folder == nil { throw EditError.invalid("\(a.name) is not missing (it is at \(a.path)); give path or folder to point it at another file") }
            targets = [a]
        } else {
            targets = Relink.missing(p)
        }
        var matches: [Relink.Match] = [], misses: [Relink.Miss] = []
        if let path {
            guard targets.count == 1 else { throw EditError.invalid(targets.isEmpty ? "nothing is missing; give asset to relink one to \(path)" : "\(targets.count) files are missing; give asset to say which one \(path) replaces") }
            let url = expand(path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { throw EditError.notFound("file \(url.path)") }
            let pr = try await Relink.probe(url)
            try Relink.check(pr, for: targets[0], in: p)
            matches = [Relink.Match(asset: targets[0], url: url, probe: pr, reason: "the file you chose")]
        } else {
            var dir: URL? = nil
            if let folder {
                let u = expand(folder)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { throw EditError.notFound("folder \(u.path)") }
                dir = u
            }
            (matches, misses) = await Relink.find(targets, folder: dir, recursive: recursive, in: p)
        }
        if !dryRun, !matches.isEmpty {
            document.apply("Relink \(matches.count) file\(matches.count == 1 ? "" : "s")", origin: origin) { q in
                for m in matches { if let i = q.assets.firstIndex(where: { $0.id == m.asset.id }) { Relink.repoint(&q.assets[i], to: m.probe) } }
            }
            for m in matches { if let a = document.project.asset(m.asset.id) { WaveformStore.shared.refresh(a); ThumbnailStore.shared.refresh(a) } }
        }
        let done = matches.map { RelinkResult.Done(asset: $0.asset.id.short, name: $0.asset.name, from: $0.asset.path, to: $0.url.path, reason: $0.reason) }
        let left = misses.map { RelinkResult.Left(asset: $0.asset.id.short, name: $0.asset.name, path: $0.asset.path, reason: $0.reason, candidates: $0.candidates.isEmpty ? nil : $0.candidates) }
        let msg = targets.isEmpty ? "Nothing is missing." : "\(dryRun ? "Would relink" : "Relinked") \(done.count) of \(targets.count) file\(targets.count == 1 ? "" : "s")" + (left.isEmpty ? "." : "; \(left.count) still missing.")
        return RelinkResult(relinked: done, stillMissing: left, dryRun: dryRun, message: msg)
    }

    struct ConsolidateResult: Codable {
        struct File: Codable { var from: String, to: String, bytes: Int64, copied: Bool }
        var folder: String, copied: Int, reused: Int, bytesCopied: Int64, size: String
        var missing: [String]?
        var files: [File]
        var dryRun: Bool
    }

    /// Copies every file the timeline uses into `folder` (default: "<project> Media" next to the project file) and
    /// points the project at the copies. The originals are only read; a file already in the folder is reused.
    func consolidateMedia(folder: String?, dryRun: Bool) async throws -> ConsolidateResult {
        let p = proj
        let dir: URL
        if let folder { dir = expand(folder) }
        else if let f = document.fileURL { dir = f.deletingLastPathComponent().appendingPathComponent("\(f.deletingPathExtension().lastPathComponent) Media") }
        else { throw EditError.invalid("the project has not been saved yet, so there is no folder next to it; give folder") }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue { throw EditError.invalid("\(dir.path) is a file, not a folder") }
        let used = Relink.usedFiles(p)
        let missing = used.assets.filter(Relink.isMissing).map(\.path) + used.luts.filter { !FileManager.default.fileExists(atPath: $0) }
        let files = Array(Set(used.assets.filter { !Relink.isMissing($0) }.map(\.url.standardizedFileURL) + used.luts.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0).standardizedFileURL }))
            .sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw EditError.invalid(missing.isEmpty ? "the timeline uses no media files" : "every file the timeline uses is missing; relink first") }
        let plan = Relink.plan(files, into: dir)
        var bytes: Int64 = 0
        if !dryRun {
            bytes = try await Relink.perform(plan)
            let map = Dictionary(uniqueKeysWithValues: plan.map { ($0.from.path, $0.to) })
            func repoint(_ q: inout Project) {
                for i in q.assets.indices where q.assets[i].sequenceID == nil {
                    guard let to = map[q.assets[i].url.standardizedFileURL.path], to.path != q.assets[i].path else { continue }
                    q.assets[i].path = to.path; q.assets[i].bookmark = try? to.bookmarkData()
                }
                for ti in q.tracks.indices {
                    for ci in q.tracks[ti].clips.indices {
                        if let l = q.tracks[ti].clips[ci].color.lut, let to = map[URL(fileURLWithPath: l).standardizedFileURL.path] { q.tracks[ti].clips[ci].color.lut = to.path }
                        if let l = q.tracks[ti].clips[ci].color.inputLut, let to = map[URL(fileURLWithPath: l).standardizedFileURL.path] { q.tracks[ti].clips[ci].color.inputLut = to.path }
                    }
                }
                for si in q.sequences.indices { repoint(&q.sequences[si].project) }
            }
            document.apply("Consolidate \(plan.count) file\(plan.count == 1 ? "" : "s")", origin: origin) { q in repoint(&q) }
        } else {
            bytes = plan.filter { !$0.alreadyThere }.map(\.bytes).reduce(0, +)
        }
        let copied = plan.filter { !$0.alreadyThere }.count
        return ConsolidateResult(folder: dir.path, copied: copied, reused: plan.count - copied, bytesCopied: bytes,
                                 size: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                                 missing: missing.isEmpty ? nil : missing,
                                 files: plan.map { .init(from: $0.from.path, to: $0.to.path, bytes: $0.bytes, copied: !$0.alreadyThere) }, dryRun: dryRun)
    }

    /// Points each asset at the chosen file, in one undoable edit (the relink sheet's Relink button). Every file is
    /// checked first (kind, length); one bad choice refuses them all.
    func relinkFiles(_ choices: [UUID: URL]) async throws -> RelinkResult {
        let p = proj
        var matches: [Relink.Match] = []
        for (id, url) in choices.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let a = p.asset(id) else { throw EditError.notFound("asset \(id.short)") }
            let pr = try await Relink.probe(url)
            try Relink.check(pr, for: a, in: p)
            matches.append(Relink.Match(asset: a, url: url, probe: pr, reason: "chosen in the relink sheet"))
        }
        guard !matches.isEmpty else { throw EditError.invalid("no files chosen") }
        document.apply("Relink \(matches.count) file\(matches.count == 1 ? "" : "s")", origin: origin) { q in
            for m in matches { if let i = q.assets.firstIndex(where: { $0.id == m.asset.id }) { Relink.repoint(&q.assets[i], to: m.probe) } }
        }
        for m in matches { if let a = document.project.asset(m.asset.id) { WaveformStore.shared.refresh(a); ThumbnailStore.shared.refresh(a) } }
        let left = Relink.missing(document.project)
        return RelinkResult(relinked: matches.map { .init(asset: $0.asset.id.short, name: $0.asset.name, from: $0.asset.path, to: $0.url.path, reason: $0.reason) },
                            stillMissing: left.map { .init(asset: $0.id.short, name: $0.name, path: $0.path, reason: "not chosen") }, dryRun: false,
                            message: "Relinked \(matches.count) file\(matches.count == 1 ? "" : "s")" + (left.isEmpty ? "." : "; \(left.count) still missing."))
    }

    // MARK: Scene cuts

    struct SceneResult: Codable {
        struct CutInfo: Codable { var source: Double; var timeline: Double?; var score: Double }
        var target: String, sourceRange: [Double], frames: Int, sensitivity: Double, minScene: Double
        var cuts: [CutInfo]
        var action: String
        var clips: [ClipRef]?
        var markers: [String]?
        var note: String? = nil
    }

    /// The clip's source range [in, out] in its asset's seconds.
    static func sourceRange(_ c: Clip) -> (Double, Double) { (c.sourceIn, c.sourceIn + c.sourceOffset(at: c.duration)) }

    /// Finds hard cuts in a clip's media (or a whole asset) and optionally splits the clip at them or marks them.
    func detectScenes(clip: String?, asset: String?, sensitivity: Double?, minScene: Double?, action: String?) async throws -> SceneResult {
        let s = sensitivity ?? SceneDetector.defaultSensitivity, m = minScene ?? 0.5, act = (action ?? "none").lowercased()
        guard (0...1).contains(s) else { throw EditError.invalid("sensitivity \(s) is outside 0...1 (0.5 is the default; higher finds more cuts)") }
        guard m >= 0.1, m <= 600 else { throw EditError.invalid("min_scene \(m) s must be between 0.1 and 600") }
        guard ["none", "split", "markers"].contains(act) else { throw EditError.invalid("action '\(act)' must be none, split or markers") }
        guard (clip == nil) != (asset == nil) else { throw EditError.invalid("give clip or asset (one of them)") }
        let p = proj
        if let asset {
            guard act == "none" else { throw EditError.invalid("action \(act) needs clip: an asset has no place on the timeline") }
            guard let a = p.asset(try resolveAsset(asset)) else { throw EditError.notFound("asset '\(asset)'") }
            let url = try sceneURL(a)
            let found = try await SceneDetector.detect(url: url, sensitivity: s, minScene: m)
            return SceneResult(target: a.name, sourceRange: [0, r(a.duration)], frames: found.frames, sensitivity: s, minScene: m,
                               cuts: found.cuts.map { .init(source: r($0.time), timeline: nil, score: r($0.score)) }, action: act,
                               note: found.cuts.isEmpty ? Self.noCutsNote : nil)
        }
        guard let c = p.clip(try resolveClip(clip!))?.clip else { throw EditError.notFound("clip '\(clip!)'") }
        guard c.multicam == nil else { throw EditError.invalid("\(c.name) is a multicam clip; detect scenes on an angle's asset") }
        guard let a = p.asset(c.assetID) else { throw EditError.notFound("the clip's asset") }
        let url = try sceneURL(a)
        let (from, to) = Self.sourceRange(c)
        let found = try await SceneDetector.detect(url: url, from: from, to: to, sensitivity: s, minScene: m)
        var out = try applySceneCuts(c.id, sourceTimes: found.cuts.map(\.time), action: act)
        out.frames = found.frames; out.sensitivity = s; out.minScene = m
        let scores = Dictionary(found.cuts.map { (r($0.time), r($0.score)) }, uniquingKeysWith: max)
        out.cuts = out.cuts.map { .init(source: $0.source, timeline: $0.timeline, score: scores[$0.source] ?? 0) }
        return out
    }

    private static let noCutsNote = "no hard cuts found; dissolves and fades are not detected as cuts. Raise sensitivity (up to 1) to find smaller jumps."

    private func sceneURL(_ a: Asset) throws -> URL {
        guard a.kind == .video || a.kind == .sequence else { throw EditError.invalid("\(a.name) is \(a.kind.rawValue): scene cuts need a video") }
        guard !Relink.isMissing(a), FileManager.default.fileExists(atPath: a.path) else { throw EditError.invalid("\(a.name) is missing (not at \(a.path)); relink it first") }
        return a.url
    }

    /// Splits the clip at (or marks) the timeline moments where these source seconds play, in one undoable edit.
    /// Cuts within a frame of the clip's ends are skipped (they would leave a clip shorter than a frame).
    func applySceneCuts(_ clipID: UUID, sourceTimes: [Double], action: String) throws -> SceneResult {
        let p = proj
        guard let c = p.clip(clipID)?.clip else { throw EditError.notFound("clip \(clipID.short)") }
        let (from, to) = Self.sourceRange(c)
        let minLen = p.minClipLength
        let placed: [(Double, Double)] = sourceTimes.compactMap { t in
            guard let local = c.localTime(ofSource: t), local > minLen, local < c.duration - minLen else { return nil }
            return (t, c.start + local)
        }
        var result = SceneResult(target: c.name, sourceRange: [r(from), r(to)], frames: 0, sensitivity: 0, minScene: 0,
                                 cuts: placed.map { .init(source: r($0.0), timeline: r($0.1), score: 0) }, action: action,
                                 note: sourceTimes.isEmpty ? Self.noCutsNote : placed.count < sourceTimes.count ? "\(sourceTimes.count - placed.count) cut(s) within a frame of the clip's ends were skipped" : nil)
        guard !placed.isEmpty else { return result }
        switch action {
        case "split":
            var pieces: [UUID] = [c.id]
            try document.apply("Split at \(placed.count) scene cut\(placed.count == 1 ? "" : "s")", origin: origin) { q in
                for (_, t) in placed.reversed() { let (_, right) = try q.splitClip(c.id, at: t); pieces.insert(right.id, at: 1) }
            }
            result.clips = pieces.compactMap { document.project.clip($0)?.clip }.map(ref)
        case "markers":
            let ms = placed.enumerated().map { Marker(time: $0.element.1, name: "Scene \($0.offset + 2)", colorHex: "#F59E0B") }
            document.apply("Mark \(placed.count) scene cut\(placed.count == 1 ? "" : "s")", origin: origin) { q in q.markers += ms; q.markers.sort { $0.time < $1.time } }
            result.markers = ms.map(\.id.short)
        default: break
        }
        return result
    }

    // MARK: Three/four-point edits, match frame

    struct PointEditResult: Codable {
        var edit: String
        var clip: ClipRef
        var track: String
        var sourceIn: Double, sourceOut: Double, timelineIn: Double, timelineOut: Double
        var speed: Double
        var fitToFill: Bool
        var replaced: [String]?
        var rippled: Double?
    }

    /// Insert (`overwrite` false) or overwrite an asset range at a timeline range: any three of the four points, four =
    /// fit to fill (speed). Timeline in defaults to the playhead when the app shows one.
    func pointEdit(overwrite: Bool, asset: String, sourceIn: Double?, sourceOut: Double?, timelineIn: Double?, timelineOut: Double?, track: String?) throws -> PointEditResult {
        let p = proj
        guard let a = p.asset(try resolveAsset(asset)) else { throw EditError.notFound("asset '\(asset)'") }
        if Relink.isMissing(a) { throw EditError.invalid("\(a.name) is missing (not at \(a.path)); relink it first") }
        let kind: TrackKind = a.kind == .audio ? .audio : .video
        let tid: UUID
        if let t = try resolveTrack(track) {
            guard let tr = p.tracks.first(where: { $0.id == t }) else { throw EditError.notFound("track '\(track!)'") }
            if a.kind == .audio, tr.kind == .video { throw EditError.invalid("\(a.name) has no picture; put it on an audio track") }
            if a.kind != .audio, tr.kind == .audio { throw EditError.invalid("\(tr.name) is an audio track; \(a.name) has a picture, put it on a video track") }
            tid = t
        } else if let t = p.tracks.first(where: { $0.kind == kind }) { tid = t.id }
        else { tid = UUID() }   // made below
        var tin = timelineIn
        if tin == nil, timelineOut == nil || [sourceIn, sourceOut].compactMap({ $0 }).count < 2 { tin = UIRegistry.shared.playheads[document.id]?() }
        let pts = try EditPoints.resolve(sourceIn: sourceIn, sourceOut: sourceOut, timelineIn: tin, timelineOut: timelineOut, asset: a, frame: p.minClipLength)
        var placed: Clip!, replaced: [String] = [], trackName = ""
        try document.apply("\(overwrite ? "Overwrite" : "Insert") \(a.name)\(pts.fitToFill ? " (fit to fill)" : "")", origin: origin) { q in
            let t = q.tracks.contains(where: { $0.id == tid }) ? tid : q.addTrack(kind: kind).id
            if overwrite { (placed, replaced) = try q.overwriteEdit(a, trackID: t, pts) } else { placed = try q.insertEdit(a, trackID: t, pts) }
            trackName = q.tracks.first { $0.id == t }?.name ?? ""
        }
        return PointEditResult(edit: overwrite ? "overwrite" : "insert", clip: ref(placed), track: trackName,
                               sourceIn: r(pts.sourceIn), sourceOut: r(pts.sourceOut), timelineIn: r(pts.timelineIn), timelineOut: r(pts.timelineOut),
                               speed: r(pts.speed), fitToFill: pts.fitToFill, replaced: replaced.isEmpty ? nil : replaced, rippled: overwrite ? nil : r(pts.timelineDuration))
    }

    struct MatchFrameResult: Codable {
        var clip: ClipRef, asset: String, assetName: String, path: String
        var time: Double, sourceTime: Double
        var sourceIn: Double, sourceOut: Double
    }

    /// The source frame under a timeline time: the asset and the second of it that plays there, plus the clip's source
    /// range (the source viewer opens on that frame with those marks).
    func matchFrame(clip: String?, time: Double?) throws -> MatchFrameResult {
        let p = proj
        guard let t = time ?? UIRegistry.shared.playheads[document.id]?() else { throw EditError.invalid("give time (no playhead to read)") }
        let c: Clip
        if let clip {
            guard let found = p.clip(try resolveClip(clip))?.clip else { throw EditError.notFound("clip '\(clip)'") }
            guard found.start <= t + 1e-6, found.end >= t - 1e-6 else { throw EditError.invalid("\(found.name) is at \(EditFormat.s(found.start))–\(EditFormat.s(found.end)) s, not under \(EditFormat.s(t)) s") }
            c = found
        } else {
            guard let found = p.topClip(at: t) else { throw EditError.invalid("no picture at \(EditFormat.s(t)) s") }
            c = found
        }
        let piece = c.multicamPieces(in: p).first { $0.start <= t + 1e-6 && $0.end > t - 1e-6 } ?? c
        guard let a = p.asset(piece.assetID) else { throw EditError.notFound("the clip's asset") }
        let local = min(max(0, t - piece.start), piece.duration)
        let (sIn, sOut) = Self.sourceRange(piece)
        return MatchFrameResult(clip: ref(c), asset: a.id.short, assetName: a.name, path: a.path, time: r(t), sourceTime: r(piece.sourceIn + piece.sourceOffset(at: local)),
                                sourceIn: r(sIn), sourceOut: r(sOut))
    }

    // MARK: Smooth slow motion

    struct SlowMotionResult: Codable {
        var clip: ClipRef, mode: String, speed: Double
        var method: String? = nil, outputFps: Double? = nil
        var status: String
        var file: String? = nil
        var note: String? = nil
    }

    /// Sets how a slow clip makes its in-between frames, and renders (or schedules) the interpolated file.
    func setSmoothSlowMotion(_ clip: String, mode text: String, wait: Bool) async throws -> SlowMotionResult {
        let key = text.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        guard let mode = SlowMotionMode(rawValue: key) else { throw EditError.invalid("mode '\(text)' must be off, blend or optical_flow") }
        let p = proj
        let id = try resolveClip(clip)
        guard let found = p.clip(id) else { throw EditError.notFound("clip '\(clip)'") }
        let c = found.clip
        guard let a = p.asset(c.assetID) else { throw EditError.notFound("the clip's asset") }
        if mode != .off {
            guard found.track.kind == .video, a.kind == .video else { throw EditError.invalid("\(c.name) is \(a.kind == .image ? "a still image: it has no motion to interpolate" : "sound only: smooth slow motion is for pictures")") }
            guard a.sequenceID == nil else { throw EditError.invalid("\(c.name) plays a nested sequence; set smooth slow motion on the clips inside it") }
            guard c.multicam == nil else { throw EditError.invalid("\(c.name) is a multicam clip; smooth slow motion is not available for multicam") }
            guard !Relink.isMissing(a) else { throw EditError.invalid("\(a.name) is missing (not at \(a.path)); relink it first") }
            let s = InterpolatedVideo.slowest(c)
            guard s < 0.999 else { throw EditError.invalid("\(c.name) plays at \(String(format: "%.2g", s))×; smooth slow motion only changes clips slower than 1× (set its speed below 1 first)") }
        }
        document.apply("Smooth slow motion: \(mode == .off ? "off" : mode == .blend ? "blend" : "optical flow")", origin: origin) { q in
            if let (ti, ci) = try? q.clipIndex(id) { q.tracks[ti].clips[ci].smoothSlowMotion = mode }
        }
        let now = document.project.clip(id)!.clip
        var out = SlowMotionResult(clip: ref(now), mode: mode.rawValue, speed: r(InterpolatedVideo.slowest(now)), status: "off")
        guard mode != .off, let j = InterpolatedVideo.job(now, a, fps: document.project.settings.fps) else { return out }
        out.method = j.method.rawValue; out.outputFps = j.fps
        if mode == .opticalFlow, j.method != .opticalFlow { out.note = "optical flow is not available on this Mac (VideoToolbox frame-rate conversion needs macOS 15.4 and a supported Mac); rendering with blend" }
        if FileManager.default.fileExists(atPath: j.url.path) { out.status = "ready"; out.file = j.url.path }
        else if wait { _ = try await InterpolatedVideo.shared.ensure(j); out.status = "ready"; out.file = j.url.path }
        else { InterpolatedVideo.shared.schedule(now, a, fps: document.project.settings.fps, delay: .zero); out.status = "rendering" }
        return out
    }
}
