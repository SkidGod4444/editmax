import Foundation
import AVFoundation
import Synchronization

// MARK: - Model (every field decodes with a default; the defaults leave the sound exactly as before)

/// A track's fader: gain in dB, stereo balance (−1 left … 1 right), solo, and the bus it plays through (nil = straight
/// to the master). Mute stays `Track.isMuted`.
struct TrackMix: Codable, Equatable {
    var gain: Double = 0
    var pan: Double = 0
    var solo = false
    var bus: UUID? = nil
    var isDefault: Bool { self == TrackMix() }
    static let gainRange = -60.0...12, panRange = -1.0...1

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        bus = try c.decodeIfPresent(UUID.self, forKey: .bus)
    }
}

/// A group of tracks with one gain, compressor and limiter (dialogue, music, effects…). See `Mixer` for how it runs.
struct Bus: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var gain: Double = 0
    var compressor: CompressorSettings? = nil
    var limiter: LimiterSettings? = nil
    var isMuted = false

    init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Bus"
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 0
        compressor = try c.decodeIfPresent(CompressorSettings.self, forKey: .compressor)
        limiter = try c.decodeIfPresent(LimiterSettings.self, forKey: .limiter)
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }
}

/// The master: a gain in dB (what normalize_loudness sets) and a true-peak limiter, plus the project's buses.
struct ProjectMix: Codable, Equatable {
    var masterGain: Double = 0
    var masterLimiter: LimiterSettings? = nil
    var buses: [Bus] = []
    var isDefault: Bool { self == ProjectMix() }
    func bus(_ id: UUID?) -> Bus? { id.flatMap { i in buses.first { $0.id == i } } }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        masterGain = try c.decodeIfPresent(Double.self, forKey: .masterGain) ?? 0
        masterLimiter = try c.decodeIfPresent(LimiterSettings.self, forKey: .masterLimiter)
        buses = try c.decodeIfPresent([Bus].self, forKey: .buses) ?? []
    }
}

/// A sound-only crossfade into a clip from the clip that ends where it starts (audio tracks). The outgoing clip plays
/// on past the cut for `duration` seconds while it fades out and this one fades in.
struct AudioCrossfade: Codable, Equatable {
    enum Curve: String, Codable, CaseIterable {
        /// sin/cos: the summed power stays constant, so unrelated sounds keep their loudness through the fade.
        case equalPower
        /// straight lines: the summed amplitude stays constant, right for the two sides of the same recording.
        case linear
    }
    var duration: Double = 0.5
    var curve: Curve = .equalPower
    static let durationRange = 0.02...10.0

    init(duration: Double = 0.5, curve: Curve = .equalPower) { self.duration = duration; self.curve = curve }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0.5
        curve = try c.decodeIfPresent(Curve.self, forKey: .curve) ?? .equalPower
    }
    /// Gain of the incoming clip at u = 0…1 through the fade; the outgoing clip gets `gainIn(1 − u)`.
    static func gainIn(_ u: Double, _ curve: Curve) -> Double {
        let x = max(0, min(1, u))
        return curve == .linear ? x : sin(x * .pi / 2)
    }
}

// MARK: - Mixer: solo, buses and the per-track strip

/// AVFoundation mixes the composition's audio tracks itself (`AVAudioMix` has per-track volume and one processing tap
/// per track, and no stage after the sum). So everything here runs per track, inside that track's tap:
/// - a track's gain and pan are exact;
/// - a bus's gain is exact (gain is linear: applying it to each member equals applying it to their sum);
/// - a bus's compressor and limiter run once per member track, on that track alone (each member is compressed by its
///   own level, not by the sum of the bus; a limited bus can peak above its ceiling when two members peak together);
/// - the master gain is exact; the master limiter likewise runs once per track. normalize_loudness renders the real
///   mix afterwards and turns the master gain down until the summed true peak is at or under the ceiling, so its
///   result holds; a hand-set master limiter is a per-track safety net only.
enum Mixer {
    /// Solo and bus mute as plain track mutes: when any track is soloed, every other track is muted; tracks routed to a
    /// muted bus are muted. Returns the project unchanged when neither is in use.
    static func soloApplied(_ project: Project) -> Project {
        let soloing = project.tracks.contains { $0.mix.solo && !$0.isHidden }
        let mutedBuses = Set(project.mix.buses.filter(\.isMuted).map(\.id))
        guard soloing || !mutedBuses.isEmpty else { return project }
        var p = project
        for i in p.tracks.indices {
            let t = p.tracks[i]
            if soloing && !t.mix.solo { p.tracks[i].isMuted = true }
            if let b = t.mix.bus, mutedBuses.contains(b) { p.tracks[i].isMuted = true }
        }
        return p
    }

    /// True when a track's sound is cut by solo or a muted bus (for the UI: the fader greys out).
    static func isSilencedBySolo(_ track: Track, in project: Project) -> Bool {
        let soloing = project.tracks.contains { $0.mix.solo && !$0.isHidden }
        if soloing && !track.mix.solo { return true }
        return project.mix.bus(track.mix.bus)?.isMuted == true
    }

    /// The processing a track adds after its clips' own: its fader, its bus, the master.
    static func strip(for track: Track, in project: Project) -> TrackStrip {
        var s = TrackStrip()
        s.gain = DSP.dbToGain(track.mix.gain)
        s.pan = track.mix.pan
        if let bus = project.mix.bus(track.mix.bus) {
            s.busGain = DSP.dbToGain(bus.gain); s.busCompressor = bus.compressor; s.busLimiter = bus.limiter
        }
        s.masterGain = DSP.dbToGain(project.mix.masterGain)
        s.masterLimiter = project.mix.masterLimiter
        s.clipLimiterLookahead = track.clips.compactMap(\.audio.limiter?.lookahead).max()
        return s
    }

    /// What an FCPXML edit list leaves behind of the audio processing, one line per setting in use (none are written).
    static func notTransferred(_ p: Project) -> [String] {
        func n(_ k: Int, _ one: String, _ many: String? = nil) -> String { "\(k) \(k == 1 ? one : (many ?? one + "s"))" }
        func names(_ ts: [Track]) -> String { ts.map(\.name).joined(separator: ", ") }
        let clips = p.allClips
        var no: [String] = []
        func clipLine(_ what: String, _ has: (ClipAudio) -> Bool, _ consequence: String) {
            let k = clips.filter { has($0.audio) }.count
            if k > 0 { no.append("\(what) on \(n(k, "clip")): \(consequence)") }
        }
        clipLine("Compressor", { $0.compressor != nil }, "the clips come in uncompressed, without their makeup gain")
        clipLine("Limiter", { $0.limiter != nil }, "peaks are not held under the ceiling")
        clipLine("De-esser", { $0.deEsser != nil }, "s sounds come in untouched")
        clipLine("Hum removal", { $0.hum != nil }, "the hum stays in; Final Cut's own Hum Removal can be turned on by hand")
        clipLine("Clip gain or pan", { $0.gain != 0 || $0.pan != 0 }, "the clips come in at their volume setting only, centered")
        let xfades = clips.filter { $0.audioCrossfade != nil }.count
        if xfades > 0 { no.append("\(n(xfades, "audio crossfade")): the clips come in as plain cuts") }
        let mixed = p.tracks.filter { $0.mix.gain != 0 || $0.mix.pan != 0 }
        if !mixed.isEmpty { no.append("Track gain or pan on \(names(mixed)): those clips come in at their own volume, centered") }
        let soloed = p.tracks.filter(\.mix.solo)
        if !soloed.isEmpty { no.append("Solo on \(names(soloed)): every track comes in audible") }
        if !p.mix.buses.isEmpty {
            no.append("\(n(p.mix.buses.count, "bus", "buses")) (\(p.mix.buses.map(\.name).joined(separator: ", "))): no bus gain, mute, compressor or limiter; the tracks come in as ordinary tracks")
        }
        if p.mix.masterGain != 0 || p.mix.masterLimiter != nil { no.append("Master gain and limiter: loudness normalization is lost; normalize again in the other editor") }
        return no
    }
}

// MARK: - Crossfades in the composition

enum AudioCrossfades {
    struct Fade { let duration: Double; let curve: AudioCrossfade.Curve }
    struct Plan {
        var incoming: [UUID: Fade] = [:]
        var outgoing: [UUID: Fade] = [:]

        /// The clip's volume envelope with its side of a crossfade: the incoming clip's head follows the curve (its own
        /// fade-in gives way), the outgoing clip keeps full volume to its out point (its fade-out gives way to the tail).
        func envelope(_ clip: Clip, muted: Bool, headFade: Double, duck: DuckCurve?) -> [(Double, Float)] {
            var c = clip
            if outgoing[clip.id] != nil { c.fadeOut = 0 }
            guard let f = incoming[clip.id] else { return VolumeEnvelope.points(c, muted: muted, headFade: headFade, duck: duck) }
            let base = VolumeEnvelope.points(c, muted: muted, headFade: 0, duck: duck)
            let d = min(f.duration, clip.duration)
            var times = Set(base.map(\.0))
            for k in 0...16 { times.insert(d * Double(k) / 16) }
            return times.sorted().map { t in
                let v = Double(AudioCrossfades.value(base, at: t))
                return (t, Float(t < d ? v * AudioCrossfade.gainIn(t / d, f.curve) : v))
            }
        }

        /// The outgoing clip's tail past its out point, as (clip-local seconds, volume) breakpoints from `duration`
        /// to `duration + fade` (empty when the clip has no crossfade after it).
        func tail(_ clip: Clip, muted: Bool, duck: DuckCurve?) -> [(Double, Float)] {
            guard let f = outgoing[clip.id] else { return [] }
            let v = muted ? 0 : clip.volume(at: clip.duration)
            return (0...16).map { k in
                let u = Double(k) / 16, lt = clip.duration + f.duration * u
                return (lt, Float(max(0, v * (duck?.factor(at: clip.start + lt) ?? 1) * AudioCrossfade.gainIn(1 - u, f.curve))))
            }
        }

        /// Puts the outgoing clip's media past its out point on its own composition track and ramps it out.
        func extendTail(of clip: Clip, audioAsset: Asset, source: AVAssetTrack, into track: AVMutableCompositionTrack,
                        params: AVMutableAudioMixInputParameters, muted: Bool, duck: DuckCurve?) throws {
            guard let f = outgoing[clip.id] else { return }
            let ts = CompositionBuilder.timescale
            let t = { (s: Double) in CMTime(seconds: s, preferredTimescale: ts) }
            let speed = max(0.05, clip.speed(at: clip.duration))
            let from = (clip.audioSourceIn ?? clip.sourceIn) + clip.sourceOffset(at: clip.duration)
            let range = CMTimeRange(start: t(from), duration: t(f.duration * speed))
            guard range.end.seconds <= audioAsset.duration + 0.01 else { return }
            try track.insertTimeRange(range, of: source, at: t(clip.end))
            if speed != 1 { track.scaleTimeRange(CMTimeRange(start: t(clip.end), duration: range.duration), toDuration: t(f.duration)) }
            let pts = tail(clip, muted: muted, duck: duck)
            for (a, b) in zip(pts, pts.dropFirst()) {
                params.setVolumeRamp(fromStartVolume: a.1, toEndVolume: b.1, timeRange: CMTimeRange(start: t(clip.start + a.0), end: t(clip.start + b.0)))
            }
        }
    }

    /// Seconds of timeline a clip's sound can run on past its out point (media left in the file, at its end speed).
    static func tailHandle(_ clip: Clip, in project: Project) -> Double {
        guard let a = project.asset(clip.audioAssetID ?? clip.assetID), a.kind != .image else { return 0 }
        let used = (clip.audioSourceIn ?? clip.sourceIn) + clip.sourceOffset(at: clip.duration)
        return max(0, (a.duration - used) / max(0.05, clip.speed(at: clip.duration)))
    }

    /// Which cuts on a track crossfade and for how long. Audio tracks only; a transition on the same cut wins (it already
    /// crossfades the sound). The length is limited by the incoming clip and by the outgoing clip's media.
    static func plan(_ clips: [Clip], track: Track, project: Project) -> Plan {
        var plan = Plan()
        guard track.kind == .audio, clips.count > 1 else { return plan }
        for i in 1..<clips.count {
            let c = clips[i], prev = clips[i - 1]
            guard let xf = c.audioCrossfade, c.transitionIn == nil, abs(prev.end - c.start) < 0.02 else { continue }
            let d = min(xf.duration, c.duration, tailHandle(prev, in: project))
            guard d > 0.01 else { continue }
            plan.incoming[c.id] = Fade(duration: d, curve: xf.curve)
            plan.outgoing[prev.id] = Fade(duration: d, curve: xf.curve)
        }
        return plan
    }

    /// Linear interpolation in (time, value) breakpoints.
    static func value(_ pts: [(Double, Float)], at t: Double) -> Float {
        guard let first = pts.first else { return 1 }
        if t <= first.0 { return first.1 }
        for (a, b) in zip(pts, pts.dropFirst()) where t <= b.0 {
            return b.0 > a.0 ? a.1 + (b.1 - a.1) * Float((t - a.0) / (b.0 - a.0)) : b.1
        }
        return pts.last!.1
    }
}

// MARK: - Taps for one track

enum AudioMixPlan {
    /// The outgoing clip's sound under a transition (the builder extends it by `d` past its out point), as the builder
    /// computes it. The tap runs the clip's dynamics, gain and pan over it too, so a compressed or normalized clip does
    /// not jump in level as it fades out. (Its EQ, high-pass and gate never reached that tail and still do not.)
    private static func transitionTail(_ clips: [Clip], _ i: Int, project: Project) -> Double? {
        guard i + 1 < clips.count, let tr = clips[i + 1].transitionIn, tr.duration > 0.01 else { return nil }
        let prev = clips[i], next = clips[i + 1]
        guard abs(prev.end - next.start) < 0.02, let a = project.asset(prev.assetID), a.kind != .image else { return nil }
        let speed = max(0.05, prev.speed(at: prev.duration))
        let d = min(tr.duration, next.duration, max(0, (a.duration - prev.sourceOut) / speed))
        return d > 0.01 ? d : nil
    }

    /// Attaches a tap to each of a track's two slots when its clips, its fader, its bus or the master ask for
    /// processing, or when the mixer's meters are on (preview only). Plain projects still never touch a tap.
    static func attachTaps(_ params: [AVMutableAudioMixInputParameters?], clips: [Clip], track: Track, project: Project,
                           envelopes: [UUID: [(Double, Float)]], crossfades: AudioCrossfades.Plan, forPreview: Bool) {
        let strip = Mixer.strip(for: track, in: project)
        let meter = forPreview && MeterBank.shared.isEnabled ? MeterBank.shared.slot(for: track.id) : nil
        for slot in 0..<2 {
            var spans: [AudioTapContext.Span] = []
            for (i, clip) in clips.enumerated() where i % 2 == slot {
                let env = (envelopes[clip.id] ?? []).map { (clip.start + $0.0, Double($0.1)) }
                let xTail = crossfades.tail(clip, muted: track.isMuted, duck: nil)
                if let last = xTail.last {
                    // A crossfade's tail: the clip's whole chain keeps running to the end of the fade.
                    let tailEnv = xTail.map { (clip.start + $0.0, Double($0.1)) }
                    spans.append(.init(start: clip.start, end: clip.start + last.0, audio: clip.audio, envelope: env + tailEnv.dropFirst()))
                    continue
                }
                spans.append(.init(start: clip.start, end: clip.end, audio: clip.audio, envelope: env))
                if let d = transitionTail(clips, i, project: project), clip.audio.hasDynamics {
                    var a = clip.audio; a.clearCleanup()
                    let v = track.isMuted ? 0 : clip.volume(at: clip.duration)
                    spans.append(.init(start: clip.end, end: clip.end + d, audio: a, envelope: [(clip.end, v), (clip.end + d, 0)]))
                }
            }
            let busy = spans.contains { !$0.audio.isIdentity }
            guard busy || !strip.isIdentity || meter != nil else { continue }
            if let tap = AudioTap.make(spans: spans, strip: strip, meter: meter) {
                params[slot]?.audioTapProcessor = tap
            }
        }
    }
}

// MARK: - Meters

/// The level a track's tap last saw (after the whole strip, times the clip's volume), for the mixer's meters.
/// Written by the audio thread with plain atomic stores, read by the UI, never locked.
final class MeterSlot: Sendable {
    private let peakBits = Atomic<UInt32>(0)
    private let reductionBits = Atomic<UInt32>(0)
    /// Raises the stored peak (never lowers it); the UI's `take()` resets it.
    func post(peak: Float, reduction: Float) {
        if peak > Float(bitPattern: peakBits.load(ordering: .relaxed)) { peakBits.store(peak.bitPattern, ordering: .relaxed) }
        if reduction > Float(bitPattern: reductionBits.load(ordering: .relaxed)) { reductionBits.store(reduction.bitPattern, ordering: .relaxed) }
    }
    /// The highest peak (linear) and gain reduction (dB) since the last call.
    func take() -> (peak: Float, reduction: Float) {
        (Float(bitPattern: peakBits.exchange(0, ordering: .relaxed)), Float(bitPattern: reductionBits.exchange(0, ordering: .relaxed)))
    }
}

/// One meter slot per track id, created when a preview composition is built (never on the audio thread).
final class MeterBank: @unchecked Sendable {
    static let shared = MeterBank()
    private let lock = NSLock()
    private var slots: [UUID: MeterSlot] = [:]
    private var enabled = false
    var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }
    func slot(for track: UUID) -> MeterSlot {
        lock.lock(); defer { lock.unlock() }
        if let s = slots[track] { return s }
        let s = MeterSlot(); slots[track] = s; return s
    }
    func existing(_ track: UUID) -> MeterSlot? { lock.lock(); defer { lock.unlock() }; return slots[track] }
}
