import Foundation
import AVFoundation

// MARK: - Split edits (J and L cuts)
//
// A clip's sound can start before its picture (J cut, `audioLead` > 0) or run on after it (L cut, `audioTrail` > 0),
// playing the source's own media beyond the picture's in/out. Negative values make the sound start later / stop
// earlier than the picture (the neighbour's half of a moved audio edit). The picture's span always plays exactly the
// media it played before: only the edges of the sound move.

extension Clip {
    var hasSplitEdit: Bool { abs(audioLead) > 1e-9 || abs(audioTrail) > 1e-9 }
    /// Where the clip's sound starts and ends on the timeline.
    var soundStart: Double { start - audioLead }
    var soundEnd: Double { end + audioTrail }
    var soundDuration: Double { soundEnd - soundStart }

    /// This clip is a piece of `original` whose head was cut at timeline `time` (a split, a ripple cut, an overwrite):
    /// a lead goes with the cut (its media would be the media that was cut away); a sound that started after the cut
    /// still starts there.
    mutating func cutSoundHead(at time: Double, from original: Clip) {
        guard original.hasSplitEdit else { return }
        audioLead = min(0, time - original.soundStart)
    }
    /// The same at the tail: the piece's sound stops at the cut, or earlier if it already did.
    mutating func cutSoundTail(at time: Double, from original: Clip) {
        guard original.hasSplitEdit else { return }
        audioTrail = min(0, original.soundEnd - time)
    }
    /// A ripple delete of a range that starts at `time`, after this clip: an L cut's sound stops where the range begins.
    mutating func trimSound(before time: Double) { if audioTrail > 0, soundEnd > time { audioTrail = max(0, time - end) } }
    /// A ripple delete of a range that ends at `time`, before this clip: a J cut's sound starts where the range ended.
    mutating func trimSound(after time: Double) { if audioLead > 0, soundStart < time { audioLead = max(0, start - time) } }

    /// The clip's sound as a plain clip of its own on the audio asset, spanning `soundStart`…`soundEnd`: keyframes moved
    /// so every moment keeps its value, and an in point chosen so the picture's span plays exactly the media it plays
    /// without the split edit (exact through speed ramps: the lead runs at the first speed, the trail at the last).
    func soundClip() -> Clip {
        var s = self
        s.audioLead = 0; s.audioTrail = 0
        s.multicam = nil; s.transitionIn = nil
        if let a = audioAssetID { s.assetID = a }
        let audioIn = audioSourceIn ?? sourceIn
        s.audioAssetID = nil; s.audioSourceIn = nil
        s.start = soundStart
        s.duration = max(0, soundDuration)
        s.shiftKeyframes(by: audioLead)
        if audioLead >= 0 { s.sourceIn = audioIn - s.sourceOffset(at: audioLead) }   // media before the picture's in point
        else { s.sourceIn = audioIn + sourceOffset(at: -audioLead) }                 // the sound starts later in the media
        return s
    }

    /// Drops the first `local` seconds (a head trim with the clip's own speed).
    mutating func dropHead(_ local: Double) {
        guard local > 0 else { return }
        sourceIn += sourceOffset(at: local)
        start += local; duration -= local
        shiftKeyframes(by: -local)
    }
}

extension Project {
    /// The asset a clip's sound comes from (a multicam piece's audio angle, else its own).
    func soundAsset(of c: Clip) -> Asset? { c.audioAssetID.flatMap(asset) ?? asset(c.assetID) }

    /// Media the clip's split-edit sound lacks before the start and after the end of its file, in source seconds
    /// (0 when it fits). Multicam: the first and last pieces carry the lead and the trail.
    func splitEditShortfall(_ c: Clip) -> (head: Double, tail: Double) {
        guard c.hasSplitEdit else { return (0, 0) }
        var head = 0.0, tail = 0.0
        for piece in c.multicamPieces(in: self) where piece.hasSplitEdit {
            guard let a = soundAsset(of: piece), a.kind != .image, piece.soundDuration > 0.01 else { continue }
            let s = piece.soundClip()
            head = max(head, -s.sourceIn)
            tail = max(tail, s.sourceIn + s.sourceOffset(at: s.duration) - a.duration)
        }
        return (max(0, head), max(0, tail))
    }

    /// Refuses a clip whose J/L cut would run out of media (called by every edit that moves a clip's in or out).
    func checkSplitEditMedia(_ c: Clip) throws {
        guard c.hasSplitEdit else { return }
        let short = splitEditShortfall(c)
        let name = soundAsset(of: c)?.name ?? "the file"
        if short.head > 0.005 {
            throw EditError.invalid("the J cut on \(c.name) would need \(EditFormat.s(short.head)) s more media before its in point than \(name) has; shorten the lead first (set_split_edit)")
        }
        if short.tail > 0.005 {
            throw EditError.invalid("the L cut on \(c.name) would need \(EditFormat.s(short.tail)) s more media after its out point than \(name) has; shorten the trail first (set_split_edit)")
        }
    }

    /// The longest lead and trail a clip's media allows, in timeline seconds (the current split edit ignored).
    func splitEditRoom(_ c: Clip) -> (lead: Double, trail: Double) {
        let pieces = c.multicamPieces(in: self)
        guard let first = pieces.first, let last = pieces.last, let fa = soundAsset(of: first), let la = soundAsset(of: last) else { return (0, 0) }
        var f = first; f.audioLead = 0; f.audioTrail = 0
        var l = last; l.audioLead = 0; l.audioTrail = 0
        let headMedia = f.audioSourceIn ?? f.sourceIn
        let tailMedia = la.duration - ((l.audioSourceIn ?? l.sourceIn) + l.sourceOffset(at: l.duration))
        _ = fa
        return (max(0, headMedia / max(1e-4, f.speed(at: 0))), max(0, tailMedia / max(1e-4, l.speed(at: l.duration))))
    }
}

/// Number formatting for messages and results.
enum EditFormat {
    static func s(_ x: Double) -> String { String(format: "%.2f", x) }
    static func signed(_ x: Double) -> String { String(format: "%+.2f", x) }
    static func r(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}

/// Builds the sound of every split-edit clip. A J/L cut overlaps its neighbour's sound, and the builder's A/B slots
/// hold one clip at a time, so these sounds go on composition tracks of their own: one per run of sounds that never
/// overlap (a lane is reused once its last sound has ended). Clips without a split edit never come here, so a
/// project without J/L cuts builds exactly as before.
enum SplitEditAudio {
    struct Item {
        let clip: Clip
        /// The track the clip is on: its lanes carry that track's strip (fader, pan, bus, master), never another's.
        let trackID: UUID
        let muted: Bool
        let duck: DuckCurve?
        /// Seconds of the incoming transition, when the clip has one: a sound that starts with its picture crossfades
        /// over it, as the plain path does.
        let transitionHead: Double?
        /// The next clip on the track: when it has a transition in and this sound ends with the picture, the sound runs
        /// on under the transition and fades out over it (the plain path's crossfade tail, which skips split edits).
        let next: Clip?
    }

    /// Seconds of a crossfade tail the plain path would give `clip`: the next clip's transition, limited like the
    /// builder limits it (the next clip's length and the media left after the out point).
    static func transitionTail(_ clip: Clip, next: Clip?, asset: Asset) -> Double {
        guard abs(clip.audioTrail) < 1e-9, let next, let tr = next.transitionIn, tr.duration > 0.01, abs(clip.end - next.start) < 0.02 else { return 0 }
        let tailSpeed = max(0.05, clip.speed(at: clip.duration))
        let d = min(min(tr.duration, next.duration), max(0, (asset.duration - clip.sourceOut) / tailSpeed))
        return d > 0.01 ? d : 0
    }

    private final class Lane {
        let owner: UUID          // the project track whose sounds this lane plays
        let track: AVMutableCompositionTrack
        let params: AVMutableAudioMixInputParameters
        var end = -Double.infinity
        var spans: [AudioTapContext.Span] = []
        init(owner: UUID, track: AVMutableCompositionTrack) { self.owner = owner; self.track = track; params = AVMutableAudioMixInputParameters(track: track) }
    }

    /// `kept` collects the source assets: they must outlive the composition (`CompositionBuilder.Output.sources`).
    static func insert(_ items: [Item], into comp: AVMutableComposition, project: Project, proxies: [UUID: URL], total: CMTime,
                       kept: inout [AVAsset]) async throws -> [AVMutableAudioMixInputParameters] {
        guard !items.isEmpty else { return [] }
        let t = { (s: Double) in CMTime(seconds: s, preferredTimescale: CompositionBuilder.timescale) }
        let end = total.seconds
        var lanes: [Lane] = []
        var cache: [URL: AVURLAsset] = [:]
        for item in items.sorted(by: { $0.clip.soundStart < $1.clip.soundStart }) {
            let clip = item.clip
            guard let audioAsset = project.soundAsset(of: clip), audioAsset.kind != .image else { continue }
            var s = clip.soundClip()
            if let picture = project.asset(clip.assetID), picture.kind != .image {
                let tail = transitionTail(clip, next: item.next, asset: picture)
                if tail > 0 { s.duration += tail; s.fadeOut = tail }
            }
            // The render never fails over a J/L cut: sound past either end of the file, before 0 or past the end of the
            // timeline is left out. The edit tools refuse to make such a cut; a later speed change can still cause one.
            let speed0 = max(1e-4, s.speed(at: 0))
            if s.sourceIn < 0 { s.dropHead(-s.sourceIn / speed0); DebugLog.event("split-edit-clamped", ["clip": clip.name, "edge": "head"]) }
            let over = s.sourceIn + s.sourceOffset(at: s.duration) - audioAsset.duration
            if over > 0.0005 { s.duration -= over / max(1e-4, s.speed(at: s.duration)); DebugLog.event("split-edit-clamped", ["clip": clip.name, "edge": "tail"]) }
            if s.start < 0 { s.dropHead(-s.start) }
            if s.end > end { s.duration = end - s.start }
            guard s.duration > 0.01 else { continue }

            let isolated = clip.audio.needsIsolation
                ? try await IsolatedAudio.readySource(for: audioAsset, amount: clip.audio.voiceIsolation, span: IsolatedAudio.span(of: clip, next: item.next, in: project)) : nil
            let av: AVAsset
            if let isolated { av = isolated.asset; kept.append(contentsOf: isolated.keep) }
            else {
                let url = proxies[audioAsset.id] ?? audioAsset.url
                let a = cache[url] ?? AVURLAsset(url: url)
                if cache[url] == nil { kept.append(a) }
                cache[url] = a; av = a
            }
            guard let src = try await av.loadTracks(withMediaType: .audio).first else { continue }
            let lane: Lane
            if let free = lanes.first(where: { $0.owner == item.trackID && $0.end <= s.start + 1e-6 }) { lane = free }
            else {
                guard let tr = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                lane = Lane(owner: item.trackID, track: tr); lanes.append(lane)
            }
            try TimeMap.insert(TimeMap.segments(s, assetDuration: audioAsset.duration), of: src, into: lane.track)
            // One envelope over the whole sound: its fades sit at the sound's own edges (a J cut fades in before the
            // picture starts); keyframes × fades × ducking, as back-to-back ramps like the plain path.
            let head = (abs(clip.audioLead) < 1e-9 ? item.transitionHead : nil) ?? clip.fadeIn
            let env = VolumeEnvelope.points(s, muted: item.muted, headFade: head, duck: item.duck)
            lane.params.setVolume(env.first?.1 ?? Float(s.volume), at: t(s.start))
            for (p0, p1) in zip(env, env.dropFirst()) where p1.0 > p0.0 + 0.0005 {
                lane.params.setVolumeRamp(fromStartVolume: p0.1, toEndVolume: p1.1, timeRange: CMTimeRange(start: t(s.start + p0.0), end: t(s.start + p1.0)))
            }
            lane.end = s.end
            // Every sound gets a span, as on the plain path: the track's strip (fader, pan, bus, master) runs after the
            // clip's own chain and needs the envelope AVFoundation applies after the tap.
            lane.spans.append(AudioTapContext.Span(start: s.start, end: s.end, audio: clip.audio, envelope: env.map { (s.start + $0.0, Double($0.1)) }))
        }
        for lane in lanes {
            guard let track = project.track(lane.owner) else { continue }
            let strip = Mixer.strip(for: track, in: project)
            guard lane.spans.contains(where: { !$0.audio.isIdentity }) || !strip.isIdentity else { continue }
            if let tap = AudioTap.make(spans: lane.spans, strip: strip, meter: nil) { lane.params.audioTapProcessor = tap }
        }
        return lanes.map(\.params)
    }
}
