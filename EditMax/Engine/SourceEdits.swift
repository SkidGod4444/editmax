import Foundation

// MARK: - Three- and four-point edits, match frame
//
// An edit is four points: source in/out (seconds of the asset) and timeline in/out. Any three fix the fourth (the
// lengths match). With all four the source is fit to fill the timeline range by changing the clip's speed. Insert
// makes room (a ripple on every track, as `insertClip` does, so nothing drifts out of sync); overwrite replaces the
// range on its own track only, trimming or splitting whatever was there.

struct EditPoints: Equatable {
    var sourceIn: Double, sourceOut: Double, timelineIn: Double, timelineOut: Double
    var sourceDuration: Double { sourceOut - sourceIn }
    var timelineDuration: Double { timelineOut - timelineIn }
    var speed: Double { sourceDuration / max(1e-9, timelineDuration) }
    var fitToFill: Bool { abs(speed - 1) > 1e-6 }

    /// Resolves three or four points. Refuses fewer than three, a range past the media, or a speed outside 0.1–10×.
    static func resolve(sourceIn sIn: Double?, sourceOut sOut: Double?, timelineIn tIn: Double?, timelineOut tOut: Double?,
                        asset: Asset, frame: Double) throws -> EditPoints {
        let given = [sIn, sOut, tIn, tOut].compactMap { $0 }.count
        guard given >= 3 else { throw EditError.invalid("give three of source_in, source_out, timeline_in, timeline_out (four fits the source to the timeline range by changing speed); \(given) given") }
        let still = asset.kind == .image
        var p: EditPoints
        switch (sIn, sOut, tIn, tOut) {
        case let (a?, b?, c?, d?):
            if still { throw EditError.invalid("\(asset.name) is a still: it has no speed to fit; give timeline_in and timeline_out with source_in") }
            p = EditPoints(sourceIn: a, sourceOut: b, timelineIn: c, timelineOut: d)
        case let (a?, b?, c?, nil): p = EditPoints(sourceIn: a, sourceOut: b, timelineIn: c, timelineOut: c + (b - a))
        case let (a?, b?, nil, d?): p = EditPoints(sourceIn: a, sourceOut: b, timelineIn: d - (b - a), timelineOut: d)
        case let (a?, nil, c?, d?): p = EditPoints(sourceIn: a, sourceOut: a + (d - c), timelineIn: c, timelineOut: d)
        case let (nil, b?, c?, d?): p = EditPoints(sourceIn: b - (d - c), sourceOut: b, timelineIn: c, timelineOut: d)
        default: throw EditError.invalid("give three of the four points")
        }
        guard p.sourceDuration >= frame - 1e-9 else { throw EditError.invalid("source out \(EditFormat.s(p.sourceOut)) s must be at least a frame after source in \(EditFormat.s(p.sourceIn)) s") }
        guard p.timelineDuration >= frame - 1e-9 else { throw EditError.invalid("timeline out \(EditFormat.s(p.timelineOut)) s must be at least a frame after timeline in \(EditFormat.s(p.timelineIn)) s") }
        guard p.sourceIn >= -1e-6 else { throw EditError.invalid("the source would start at \(EditFormat.s(p.sourceIn)) s, before the start of \(asset.name)") }
        guard p.timelineIn >= -1e-6 else { throw EditError.invalid("the edit would start at \(EditFormat.s(p.timelineIn)) s, before the start of the timeline") }
        if !still, p.sourceOut > asset.duration + 1e-3 {
            throw EditError.invalid("source out \(EditFormat.s(p.sourceOut)) s is past the end of \(asset.name) (\(EditFormat.s(asset.duration)) s)")
        }
        if p.fitToFill, !(0.1...10).contains(p.speed) {
            throw EditError.invalid("fitting \(EditFormat.s(p.sourceDuration)) s of source into \(EditFormat.s(p.timelineDuration)) s needs speed \(String(format: "%.3g", p.speed))×, outside 0.1–10×")
        }
        p.sourceIn = max(0, p.sourceIn); p.timelineIn = max(0, p.timelineIn)
        return p
    }
}

extension Project {
    /// The clip a three/four-point edit places (speed set for fit to fill).
    func editClip(_ a: Asset, _ pts: EditPoints) -> Clip {
        var c = Clip(assetID: a.id, name: a.name, start: pts.timelineIn, duration: pts.timelineDuration, sourceIn: a.kind == .image ? 0 : pts.sourceIn)
        if a.kind != .image, pts.fitToFill { c.speed = pts.speed }
        return c
    }

    /// Insert: make room on every track at timeline in (a straddling clip is split), then place the clip.
    mutating func insertEdit(_ a: Asset, trackID: UUID, _ pts: EditPoints) throws -> Clip {
        let ti = try trackIndex(trackID)
        makeRoom(on: ti, at: pts.timelineIn, length: pts.timelineDuration)
        let c = editClip(a, pts)
        tracks[ti].clips.append(c); tracks[ti].clips.sort { $0.start < $1.start }
        return c
    }

    /// Overwrite: clear [timeline in, timeline out] on this track only, then place the clip. Returns what was
    /// replaced (names of clips removed, trimmed or split).
    mutating func overwriteEdit(_ a: Asset, trackID: UUID, _ pts: EditPoints) throws -> (clip: Clip, replaced: [String]) {
        let ti = try trackIndex(trackID)
        let replaced = liftRange(on: ti, from: pts.timelineIn, to: pts.timelineOut)
        let c = editClip(a, pts)
        tracks[ti].clips.append(c); tracks[ti].clips.sort { $0.start < $1.start }
        return (c, replaced)
    }

    /// Removes [a, b] from one track without moving anything: clips inside go, clips across an edge are cut there
    /// (Clip.split, so keyframes, fades and J/L cuts stay with their own pieces).
    @discardableResult
    mutating func liftRange(on ti: Int, from a: Double, to b: Double) -> [String] {
        var out: [Clip] = [], touched: [String] = []
        for c in tracks[ti].clips {
            guard c.end > a + 1e-6, c.start < b - 1e-6 else { out.append(c); continue }
            touched.append(c.name)
            if c.start < a - 1e-6 { out.append(c.split(atLocal: a - c.start).0) }
            if c.end > b + 1e-6 { out.append(c.split(atLocal: b - c.start).1) }
        }
        tracks[ti].clips = out.sorted { $0.start < $1.start }
        return touched
    }

    /// The picture on top at a timeline time: the clip on the top-most visible video track that covers it (tracks are
    /// stored top row first, as the builder layers them).
    func topClip(at t: Double) -> Clip? {
        for track in tracks where track.kind == .video && !track.isHidden {
            if let c = track.clips.first(where: { $0.start <= t + 1e-6 && $0.end > t + 1e-6 }) { return c }
        }
        return nil
    }
}
