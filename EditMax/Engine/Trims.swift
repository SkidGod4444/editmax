import Foundation

// MARK: - Roll, slip and slide
//
// Trims that keep the timeline's length: a roll moves the cut between two touching clips (one gets longer, the other
// shorter by the same amount), a slip changes which part of the source a clip shows without moving it, a slide moves a
// clip between its neighbours, which trim to make room. None of them clamps: a move that would run out of media or
// shrink a clip below one frame is refused, and the message says how far it could go.

/// How far a clip's edges and source can move before it runs out of media (picture and sound, J/L cut included).
struct MediaRoom: Equatable {
    /// Timeline seconds the in point can move earlier / the out point later.
    var head: Double
    var tail: Double
    /// Source seconds a slip can move the source earlier / later.
    var slipEarlier: Double
    var slipLater: Double
    static let unlimited = MediaRoom(head: .infinity, tail: .infinity, slipEarlier: .infinity, slipLater: .infinity)
}

extension Project {
    /// Source seconds of media before / after what a plain piece uses, for its picture and its sound.
    private func slack(_ p: Clip) -> (before: Double, after: Double) {
        var before = Double.infinity, after = Double.infinity
        if let a = asset(p.assetID), a.kind != .image {
            before = min(before, p.sourceIn); after = min(after, a.duration - p.sourceOut)
        }
        if let sa = soundAsset(of: p), sa.kind != .image, p.soundDuration > 0.01 {
            let s = p.hasSplitEdit ? p.soundClip() : { var c = p; c.sourceIn = p.audioSourceIn ?? p.sourceIn; return c }()
            before = min(before, s.sourceIn); after = min(after, sa.duration - s.sourceOut)
        }
        return (max(0, before), max(0, after))
    }

    /// The media room of a clip as it stands. Stills have no frames to run out of: unlimited, except a slip, which a
    /// still cannot do.
    func mediaRoom(_ c: Clip) -> MediaRoom {
        let pieces = c.multicamPieces(in: self)
        guard let first = pieces.first, let last = pieces.last else { return .unlimited }
        let all = pieces.map(slack)
        let head = slack(first).before, tail = slack(last).after
        return MediaRoom(head: head / max(1e-4, c.speed(at: 0)), tail: tail / max(1e-4, c.speed(at: c.duration)),
                         slipEarlier: all.map(\.before).min() ?? 0, slipLater: all.map(\.after).min() ?? 0)
    }

    /// One frame: the shortest a clip may become.
    var minClipLength: Double { 1 / max(1, settings.fps) }

    /// The clip on the same track whose start touches `clip`'s end (within 0.02 s), if any.
    func clipAfter(_ clip: Clip, on track: Track) -> Clip? {
        track.clips.first { $0.id != clip.id && abs($0.start - clip.end) < 0.02 }
    }

    // MARK: Limits

    /// How far an edit point may move earlier and later (seconds), with the reason each limit exists.
    struct MoveLimits: Equatable {
        var earlier: Double, later: Double
        var earlierWhy: String, laterWhy: String
    }

    /// The two clips of the cut at `id`'s end (`atEnd`) or start, or the reason there is no cut to roll.
    func rollPair(_ id: UUID, atEnd: Bool) throws -> (a: Clip, b: Clip) {
        guard let (track, c) = clip(id) else { throw EditError.notFound("clip \(id.short)") }
        if atEnd {
            guard let n = clipAfter(c, on: track) else { throw EditError.invalid("no clip starts where \(c.name) ends (\(EditFormat.s(c.end)) s); a roll needs two touching clips, use trim_clip to trim one edge") }
            return (c, n)
        }
        guard let p = clipBefore(c, on: track) else { throw EditError.invalid("no clip ends where \(c.name) starts (\(EditFormat.s(c.start)) s); a roll needs two touching clips, use trim_clip to trim one edge") }
        return (p, c)
    }

    /// How far the cut between `a` and `b` can roll: later until `a` runs out of media or `b` is one frame long,
    /// earlier until `b` runs out of media or `a` is one frame long.
    func rollLimits(_ id: UUID, atEnd: Bool) throws -> MoveLimits {
        let (a, b) = try rollPair(id, atEnd: atEnd)
        let ra = mediaRoom(a), rb = mediaRoom(b), minLen = minClipLength
        var l = MoveLimits(earlier: min(rb.head, a.duration - minLen), later: min(ra.tail, b.duration - minLen), earlierWhy: "", laterWhy: "")
        l.laterWhy = ra.tail < b.duration - minLen ? "\(a.name) has only \(EditFormat.s(ra.tail)) s of media after its out point" : "\(b.name) would be shorter than one frame"
        l.earlierWhy = rb.head < a.duration - minLen ? "\(b.name) has only \(EditFormat.s(rb.head)) s of media before its in point" : "\(a.name) would be shorter than one frame"
        l.earlier = max(0, l.earlier); l.later = max(0, l.later)
        return l
    }

    /// How far a clip can slip, in source seconds (earlier = show earlier media).
    func slipLimits(_ id: UUID) throws -> MoveLimits {
        guard let c = clip(id)?.clip else { throw EditError.notFound("clip \(id.short)") }
        if asset(c.assetID)?.kind == .image { throw EditError.invalid("\(c.name) is a still image; there is no other part of it to show") }
        let room = mediaRoom(c)
        return MoveLimits(earlier: room.slipEarlier, later: room.slipLater, earlierWhy: "it would run past the start of the media", laterWhy: "it would run past the end of the media")
    }

    /// The touching neighbours of a slide, and how far it can go.
    func slideLimits(_ id: UUID) throws -> (limits: MoveLimits, previous: Clip?, next: Clip?) {
        guard let (track, c) = clip(id) else { throw EditError.notFound("clip \(id.short)") }
        let prev = clipBefore(c, on: track), next = clipAfter(c, on: track)
        guard prev != nil || next != nil else { throw EditError.invalid("no clip touches either edge of \(c.name); a slide trims its neighbours, use move_clip to move it alone") }
        let minLen = minClipLength
        let others = track.clips.filter { $0.id != c.id && $0.id != prev?.id && $0.id != next?.id }
        // Later: the previous clip grows into its media, the next one loses its head. Earlier: the reverse.
        var l = MoveLimits(earlier: c.start, later: .infinity, earlierWhy: "it would start before 0", laterWhy: "")
        if let prev {
            let r = mediaRoom(prev).tail
            if r < l.later { l.later = r; l.laterWhy = "\(prev.name) has only \(EditFormat.s(r)) s of media after its out point" }
            l.earlier = prev.duration - minLen; l.earlierWhy = "\(prev.name) would be shorter than one frame"
        } else if let wall = others.filter({ $0.end <= c.start + 0.02 }).map(\.end).max() {
            l.earlier = c.start - wall; l.earlierWhy = "it would overlap the clip before the gap"
        }
        if let next {
            if next.duration - minLen < l.later { l.later = next.duration - minLen; l.laterWhy = "\(next.name) would be shorter than one frame" }
            let r = mediaRoom(next).head
            if r < l.earlier { l.earlier = r; l.earlierWhy = "\(next.name) has only \(EditFormat.s(r)) s of media before its in point" }
        } else if let wall = others.filter({ $0.start >= c.end - 0.02 }).map(\.start).min() {
            if wall - c.end < l.later { l.later = wall - c.end; l.laterWhy = "it would overlap the clip after the gap" }
        }
        l.earlier = max(0, l.earlier); l.later = max(0, l.later)
        return (l, prev, next)
    }

    // MARK: Roll

    struct RollResult { var outgoing: Clip, incoming: Clip, from: Double, to: Double, notes: [String] }

    /// Moves the cut at `clip`'s `edge` by `delta` timeline seconds: the clip on the other side of the cut changes by
    /// the opposite amount, so nothing else moves.
    @discardableResult
    mutating func rollEdit(_ id: UUID, atEnd: Bool, delta: Double) throws -> RollResult {
        let (a, b) = try rollPair(id, atEnd: atEnd)
        let cut = a.end
        guard abs(delta) > 1e-6 else { return RollResult(outgoing: a, incoming: b, from: cut, to: cut, notes: ["the cut did not move"]) }
        let l = try rollLimits(id, atEnd: atEnd)
        if delta > l.later + 1e-4 { throw EditError.invalid("the cut can move at most \(EditFormat.s(l.later)) s later: \(l.laterWhy)") }
        if -delta > l.earlier + 1e-4 { throw EditError.invalid("the cut can move at most \(EditFormat.s(l.earlier)) s earlier: \(l.earlierWhy)") }
        let to = cut + delta
        try trimClip(a.id, newStart: nil, newEnd: to)
        try trimClip(b.id, newStart: to, newEnd: nil)
        let outgoing = try clipNow(a.id), incoming = try clipNow(b.id)
        try checkMedia(outgoing); try checkMedia(incoming)
        var notes: [String] = []
        if let tr = incoming.transitionIn, tr.duration > 0.01 {
            let left = mediaRoom(outgoing).tail
            if left + 0.01 < tr.duration { notes.append("the \(tr.kind.title.lowercased()) into \(incoming.name) is \(EditFormat.s(tr.duration)) s but \(outgoing.name) now has only \(EditFormat.s(left)) s of media after the cut; it will play \(EditFormat.s(left)) s") }
        }
        return RollResult(outgoing: outgoing, incoming: incoming, from: cut, to: to, notes: notes)
    }

    // MARK: Slip

    /// Shows a different part of the source in the same place: the source in point moves by `delta` source seconds
    /// (sound with it, multicam angles and J/L cuts included). Keyframes and the clip's place stay.
    @discardableResult
    mutating func slipClip(_ id: UUID, delta: Double) throws -> Clip {
        let l = try slipLimits(id)
        let (ti, ci) = try clipIndex(id)
        var c = tracks[ti].clips[ci]
        guard abs(delta) > 1e-6 else { return c }
        if delta > l.later + 1e-4 { throw EditError.invalid("\(c.name) can slip at most \(EditFormat.s(l.later)) s later in its source (\(l.laterWhy))") }
        if -delta > l.earlier + 1e-4 { throw EditError.invalid("\(c.name) can slip at most \(EditFormat.s(l.earlier)) s earlier in its source (\(l.earlierWhy))") }
        c.sourceIn += delta
        if let s = c.audioSourceIn { c.audioSourceIn = s + delta }
        try checkMedia(c)
        tracks[ti].clips[ci] = c
        return c
    }

    // MARK: Slide

    struct SlideResult { var clip: Clip, previous: Clip?, next: Clip?, from: Double, to: Double }

    /// Moves a clip by `delta` timeline seconds between its neighbours, keeping its source: the touching clip before it
    /// gets longer or shorter at its end and the touching clip after it at its start, so the track keeps its length.
    /// An edge without a touching neighbour may move into a gap but not over another clip.
    @discardableResult
    mutating func slideClip(_ id: UUID, delta: Double) throws -> SlideResult {
        let (l, prev, next) = try slideLimits(id)
        let c = try clipNow(id)
        guard abs(delta) > 1e-6 else { return SlideResult(clip: c, previous: prev, next: next, from: c.start, to: c.start) }
        if delta > l.later + 1e-4 { throw EditError.invalid("\(c.name) can slide at most \(EditFormat.s(l.later)) s later: \(l.laterWhy)") }
        if -delta > l.earlier + 1e-4 { throw EditError.invalid("\(c.name) can slide at most \(EditFormat.s(l.earlier)) s earlier: \(l.earlierWhy)") }
        if let prev { try trimClip(prev.id, newStart: nil, newEnd: c.start + delta) }
        if let next { try trimClip(next.id, newStart: c.end + delta, newEnd: nil) }
        let (ti, ci) = try clipIndex(c.id)
        tracks[ti].clips[ci].start = c.start + delta
        tracks[ti].clips.sort { $0.start < $1.start }
        let moved = try clipNow(c.id), p2 = try prev.map { try clipNow($0.id) }, n2 = try next.map { try clipNow($0.id) }
        for x in [p2, n2].compactMap({ $0 }) { try checkMedia(x) }
        return SlideResult(clip: moved, previous: p2, next: n2, from: c.start, to: c.start + delta)
    }

    func clipNow(_ id: UUID) throws -> Clip {
        guard let c = clip(id)?.clip else { throw EditError.notFound("clip \(id.short)") }
        return c
    }

    /// Final guard after an edit: refuses a clip that plays media its file does not have.
    func checkMedia(_ c: Clip) throws {
        for p in c.multicamPieces(in: self) {
            guard let a = asset(p.assetID), a.kind != .image else { continue }
            guard c.multicam == nil else { continue }   // angles may start late or end early; the builder holds their edges
            if p.sourceIn < -0.005 { throw EditError.invalid("\(c.name) would start \(EditFormat.s(-p.sourceIn)) s before the start of \(a.name)") }
            if p.sourceOut > a.duration + 0.005 { throw EditError.invalid("\(c.name) would run \(EditFormat.s(p.sourceOut - a.duration)) s past the end of \(a.name)") }
        }
        try checkSplitEditMedia(c)
    }
}
