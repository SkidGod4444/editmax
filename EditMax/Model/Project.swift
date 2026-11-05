import Foundation

// MARK: - Core model. Plain Codable values; all times are seconds.

struct ProjectSettings: Codable, Equatable {
    var width: Int = 1920
    var height: Int = 1080
    var fps: Double = 30
    /// Preview from low-resolution proxy files when they exist; the export always uses the originals.
    var useProxies: Bool = false

    init(width: Int = 1920, height: Int = 1080, fps: Double = 30, useProxies: Bool = false) { self.width = width; self.height = height; self.fps = fps; self.useProxies = useProxies }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        fps = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 30
        useProxies = try c.decodeIfPresent(Bool.self, forKey: .useProxies) ?? false
    }
}

enum AssetKind: String, Codable { case video, audio, image, sequence }

struct Asset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var path: String                // absolute path on disk
    var bookmark: Data? = nil       // security-scoped bookmark for sandbox-free reopen
    var kind: AssetKind
    var duration: Double            // seconds; images use 5s default
    var width: Int? = nil
    var height: Int? = nil
    /// For `kind == .sequence`: the `Project.sequences` entry this asset plays (its path is the cached render).
    var sequenceID: UUID? = nil
    var url: URL { URL(fileURLWithPath: path) }
}

enum TrackKind: String, Codable { case video, audio }

/// Where a clip's picture sits in the frame. Position is a fraction of the frame (0.5 = half a frame to the right/down),
/// rotation is clockwise degrees, crops are fractions of the clip's own picture cut from each edge.
struct ClipTransform: Codable, Equatable {
    var scale: Double = 1
    var x: Double = 0
    var y: Double = 0
    var rotation: Double = 0
    var cropLeft: Double = 0
    var cropRight: Double = 0
    var cropTop: Double = 0
    var cropBottom: Double = 0
    var isIdentity: Bool { self == ClipTransform() }
    static let identity = ClipTransform()
}

/// Camera-shake correction for a clip (see `Stabilizer`). Samples are keyed by SOURCE time in the asset, so trims and
/// speed ramps never move them; `dx`/`dy` are the shift to apply to the picture as a fraction of the oriented source
/// width/height (+ = move it right/down); `zoom` is the uniform scale that keeps the shifted borders out of the frame.
struct Stabilization: Codable, Equatable {
    struct Sample: Codable, Equatable { var t: Double; var dx: Double; var dy: Double }
    var strength: Double
    var zoom: Double
    /// Per-frame corrections. On a clip in the document this stays empty: the samples live in `Project.motionPaths[pathKey]`
    /// (a cache that history snapshots skip, so a long clip's thousands of samples are stored once, not once per edit);
    /// the composition builder fills them in (`Project.hydrated`) before the compositor reads them.
    var samples: [Sample] = []
    var pathKey: String = ""

    init(strength: Double, zoom: Double, samples: [Sample], pathKey: String = "") { self.strength = strength; self.zoom = zoom; self.samples = samples; self.pathKey = pathKey }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 0.6
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        samples = try c.decodeIfPresent([Sample].self, forKey: .samples) ?? []
        pathKey = try c.decodeIfPresent(String.self, forKey: .pathKey) ?? ""
    }

    /// The shift at a source time: linear between samples, held at the ends. Samples are sorted by `t`.
    func offset(at sourceTime: Double) -> (dx: Double, dy: Double) {
        guard let first = samples.first, let last = samples.last else { return (0, 0) }
        if sourceTime <= first.t { return (first.dx, first.dy) }
        if sourceTime >= last.t { return (last.dx, last.dy) }
        var lo = 0, hi = samples.count - 1   // samples[lo].t <= sourceTime < samples[hi].t
        while hi - lo > 1 { let mid = (lo + hi) / 2; if samples[mid].t <= sourceTime { lo = mid } else { hi = mid } }
        let a = samples[lo], b = samples[hi], u = (sourceTime - a.t) / max(1e-9, b.t - a.t)
        return (a.dx + (b.dx - a.dx) * u, a.dy + (b.dy - a.dy) * u)
    }
}

/// Primary color correction. Exposure in stops, contrast and saturation as multipliers (1 = untouched),
/// temperature and tint from -100 (cool / green) to 100 (warm / magenta).
struct ClipColor: Codable, Equatable {
    var exposure: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var temperature: Double = 0
    var tint: Double = 0
    /// Tone curve lifts (+) or drops (−) of the shadows, midtones and highlights, -1 to 1.
    var shadows: Double = 0
    var midtones: Double = 0
    var highlights: Double = 0
    /// Saturation that favours muted colors, -1 to 1.
    var vibrance: Double = 0
    /// A technical conversion LUT (`.cube` path) applied before every other control, full strength: log footage
    /// (D-Log, S-Log, V-Log…) is converted to Rec.709 first, so exposure and the tone curve work on a normal image.
    var inputLut: String? = nil
    /// A look: a built-in name (`Looks.builtin`) or the path of a `.cube` file, blended by `lutMix`.
    var lut: String? = nil
    var lutMix: Double = 1
    var isIdentity: Bool { self == ClipColor() }
    static let identity = ClipColor()
    /// A grade on top of the conversion: anything but the input LUT. The before/after view compares exactly this.
    var hasGrade: Bool { var c = self; c.inputLut = nil; return !c.isIdentity }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        midtones = try c.decodeIfPresent(Double.self, forKey: .midtones) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        inputLut = try c.decodeIfPresent(String.self, forKey: .inputLut)
        lut = try c.decodeIfPresent(String.self, forKey: .lut)
        lutMix = try c.decodeIfPresent(Double.self, forKey: .lutMix) ?? 1
    }
}

/// A transition into a clip from the clip that ends where it starts. It takes the first `duration` seconds of the
/// incoming clip; the outgoing clip keeps playing underneath, using media past its out point.
struct Transition: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case crossDissolve, dipToBlack, wipeLeft, wipeRight
        var title: String {
            switch self { case .crossDissolve: return "Cross dissolve"; case .dipToBlack: return "Dip to black"; case .wipeLeft: return "Wipe left"; case .wipeRight: return "Wipe right" }
        }
    }
    var kind: Kind = .crossDissolve
    var duration: Double = 0.5
}

/// One animated value of a clip parameter, at a clip-local time (0 = the clip's start). `ease` says how the value
/// moves to the next keyframe: linear, smooth (ease in and out), or hold (jump at the next keyframe).
struct Keyframe: Codable, Equatable {
    enum Ease: String, Codable, CaseIterable { case linear, smooth, hold }
    var time: Double
    var value: Double
    var ease: Ease = .linear

    init(time: Double, value: Double, ease: Ease = .linear) { self.time = time; self.value = value; self.ease = ease }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        value = try c.decode(Double.self, forKey: .value)
        ease = try c.decodeIfPresent(Ease.self, forKey: .ease) ?? .linear
    }
}

/// Every clip parameter that can carry keyframes.
enum ClipParam: String, Codable, CaseIterable {
    case scale, x, y, rotation, opacity, exposure, contrast, saturation, temperature, tint, shadows, midtones, highlights, vibrance, lutMix, volume, speed
    var title: String {
        switch self {
        case .scale: return "Scale"; case .x: return "Position X"; case .y: return "Position Y"; case .rotation: return "Rotation"; case .opacity: return "Opacity"
        case .exposure: return "Exposure"; case .contrast: return "Contrast"; case .saturation: return "Saturation"; case .temperature: return "Temperature"; case .tint: return "Tint"
        case .shadows: return "Shadows"; case .midtones: return "Midtones"; case .highlights: return "Highlights"; case .vibrance: return "Vibrance"; case .lutMix: return "Look mix"
        case .volume: return "Volume"; case .speed: return "Speed"
        }
    }
    static let transformParams: [ClipParam] = [.scale, .x, .y, .rotation]
    static let colorParams: [ClipParam] = [.exposure, .contrast, .saturation, .temperature, .tint, .shadows, .midtones, .highlights, .vibrance, .lutMix]
}

struct Clip: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var assetID: UUID
    var name: String
    var start: Double          // position on timeline
    var duration: Double       // timeline duration (= source length / speed)
    var sourceIn: Double = 0   // offset into the asset
    var speed: Double = 1
    var volume: Double = 1
    var opacity: Double = 1
    var transform = ClipTransform()
    var color = ClipColor()
    var fadeIn: Double = 0     // seconds; picture from black and sound from silence
    var fadeOut: Double = 0
    var transitionIn: Transition? = nil
    /// Keyframes per parameter (`ClipParam` raw values), sorted by time. A parameter with keyframes ignores its plain field.
    var animations: [String: [Keyframe]] = [:]
    /// EQ, high-pass and gate for the clip's sound.
    var audio = ClipAudio()
    /// Several synchronized angles behind one clip (see `Multicam`); nil for a plain clip.
    var multicam: Multicam? = nil
    /// Sound from another asset than the picture (a multicam piece's audio angle); nil = the clip's own asset.
    var audioAssetID: UUID? = nil
    var audioSourceIn: Double? = nil
    /// Camera-shake correction from `stabilize_clip`; nil = none.
    var stabilization: Stabilization? = nil
    var end: Double { start + duration }
    /// Where the clip's media ends in the asset: with a speed ramp, the integral of speed over the clip.
    var sourceOut: Double { sourceIn + sourceOffset(at: duration) }

    init(id: UUID = UUID(), assetID: UUID, name: String, start: Double, duration: Double, sourceIn: Double = 0, speed: Double = 1, volume: Double = 1, opacity: Double = 1) {
        self.id = id; self.assetID = assetID; self.name = name; self.start = start; self.duration = duration
        self.sourceIn = sourceIn; self.speed = speed; self.volume = volume; self.opacity = opacity
    }

    // Older project files lack the newer keys; every one of them has a default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        assetID = try c.decode(UUID.self, forKey: .assetID)
        name = try c.decode(String.self, forKey: .name)
        start = try c.decode(Double.self, forKey: .start)
        duration = try c.decode(Double.self, forKey: .duration)
        sourceIn = try c.decodeIfPresent(Double.self, forKey: .sourceIn) ?? 0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? ClipTransform()
        color = try c.decodeIfPresent(ClipColor.self, forKey: .color) ?? ClipColor()
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        transitionIn = try c.decodeIfPresent(Transition.self, forKey: .transitionIn)
        animations = try c.decodeIfPresent([String: [Keyframe]].self, forKey: .animations) ?? [:]
        audio = try c.decodeIfPresent(ClipAudio.self, forKey: .audio) ?? ClipAudio()
        multicam = try c.decodeIfPresent(Multicam.self, forKey: .multicam)
        audioAssetID = try c.decodeIfPresent(UUID.self, forKey: .audioAssetID)
        audioSourceIn = try c.decodeIfPresent(Double.self, forKey: .audioSourceIn)
        stabilization = try c.decodeIfPresent(Stabilization.self, forKey: .stabilization)
    }

    /// The two clips a split at `local` seconds produces; the right one gets a new id and no transition or fade-in.
    func split(atLocal local: Double) -> (Clip, Clip) {
        var left = self, right = self
        right.id = UUID()
        let consumed = sourceOffset(at: local)
        right.sourceIn = sourceIn + consumed
        if let s = audioSourceIn { right.audioSourceIn = s + consumed }
        left.duration = local
        right.start = start + local
        right.duration = duration - local
        right.shiftKeyframes(by: -local)
        right.transitionIn = nil
        right.fadeIn = 0; left.fadeOut = 0
        if let mc = multicam {
            var l = mc, r = mc
            l.cuts = mc.cuts.filter { $0.time < local }
            r.cuts = [MulticamCut(time: 0, angle: mc.angle(at: local))] + mc.cuts.filter { $0.time > local }.map { MulticamCut(time: $0.time - local, angle: $0.angle) }
            left.multicam = l; right.multicam = r
        }
        return (left, right)
    }

    /// What the engine plays for this clip: itself, or for a multicam clip one plain piece per cut interval, each on
    /// its angle's asset (source time shifted by the angle's offset) with sound from the audio angle. Piece 0 keeps
    /// the clip's id; the others derive theirs from it so a rebuild yields the same ids.
    func multicamPieces(in project: Project) -> [Clip] {
        guard let mc = multicam, !mc.angles.isEmpty else { return [self] }
        let times = Array(Set(mc.cuts.map(\.time).filter { $0 > 0.01 && $0 < duration - 0.01 })).sorted()
        var rest = self, pieces: [Clip] = []
        for t in times { let (l, r) = rest.split(atLocal: t - (rest.start - start)); pieces.append(l); rest = r }
        pieces.append(rest)
        return pieces.enumerated().map { i, piece in
            var p = piece
            let ai = mc.angle(at: piece.start - start + 0.001)
            let au = min(max(0, mc.audioAngle), mc.angles.count - 1)
            p.assetID = mc.angles[ai]
            p.sourceIn = max(0, piece.sourceIn + mc.offset(ai))
            if let a = project.asset(p.assetID) { p.sourceIn = min(p.sourceIn, max(0, a.duration - 0.01)) }
            p.audioAssetID = mc.angles[au]
            p.audioSourceIn = max(0, piece.sourceIn + mc.offset(au))
            p.multicam = nil
            if ai != 0 { p.stabilization = nil }   // the analysis is of angle 1's picture
            p.name = "\(name) ∠\(ai + 1)"
            if i > 0 { var u = id.uuid; u.0 ^= UInt8(i & 0xff); u.1 ^= UInt8((i >> 8) & 0xff); p.id = UUID(uuid: u) }   // leading bytes: short ids stay distinct
            return p
        }
    }
}

// MARK: - Keyframe evaluation (all times clip-local seconds)

extension Clip {
    func keyframes(_ p: ClipParam) -> [Keyframe] { animations[p.rawValue] ?? [] }
    func isAnimated(_ p: ClipParam) -> Bool { !(animations[p.rawValue]?.isEmpty ?? true) }
    var isAnimated: Bool { animations.values.contains { !$0.isEmpty } }
    /// Every keyframe time of the clip, for the timeline marks and prev/next navigation.
    var keyframeTimes: [Double] { Array(Set(animations.values.flatMap { $0.map(\.time) })).sorted() }

    /// The plain (unanimated) value of a parameter.
    func baseValue(_ p: ClipParam) -> Double {
        switch p {
        case .scale: return transform.scale; case .x: return transform.x; case .y: return transform.y; case .rotation: return transform.rotation
        case .opacity: return opacity
        case .exposure: return color.exposure; case .contrast: return color.contrast; case .saturation: return color.saturation
        case .temperature: return color.temperature; case .tint: return color.tint
        case .shadows: return color.shadows; case .midtones: return color.midtones; case .highlights: return color.highlights; case .vibrance: return color.vibrance; case .lutMix: return color.lutMix
        case .volume: return volume; case .speed: return speed
        }
    }

    /// The value of a parameter at a clip-local time: the plain value, or the keyframes interpolated.
    func value(_ p: ClipParam, at local: Double) -> Double {
        let ks = keyframes(p)
        guard let first = ks.first, let last = ks.last else { return baseValue(p) }
        if local <= first.time { return first.value }
        if local >= last.time { return last.value }
        var i = 0
        while i + 1 < ks.count, ks[i + 1].time <= local { i += 1 }
        let a = ks[i], b = ks[i + 1]
        return Self.interpolate(a, b, at: local)
    }

    static func interpolate(_ a: Keyframe, _ b: Keyframe, at t: Double) -> Double {
        let span = b.time - a.time
        guard span > 1e-9 else { return b.value }
        let u = max(0, min(1, (t - a.time) / span))
        switch a.ease {
        case .hold: return a.value
        case .linear: return a.value + (b.value - a.value) * u
        case .smooth: let s = u * u * (3 - 2 * u); return a.value + (b.value - a.value) * s
        }
    }

    func transform(at local: Double) -> ClipTransform {
        var t = transform
        if isAnimated(.scale) { t.scale = value(.scale, at: local) }
        if isAnimated(.x) { t.x = value(.x, at: local) }
        if isAnimated(.y) { t.y = value(.y, at: local) }
        if isAnimated(.rotation) { t.rotation = value(.rotation, at: local) }
        return t
    }
    func color(at local: Double) -> ClipColor {
        var c = color
        if isAnimated(.exposure) { c.exposure = value(.exposure, at: local) }
        if isAnimated(.contrast) { c.contrast = value(.contrast, at: local) }
        if isAnimated(.saturation) { c.saturation = value(.saturation, at: local) }
        if isAnimated(.temperature) { c.temperature = value(.temperature, at: local) }
        if isAnimated(.tint) { c.tint = value(.tint, at: local) }
        if isAnimated(.shadows) { c.shadows = value(.shadows, at: local) }
        if isAnimated(.midtones) { c.midtones = value(.midtones, at: local) }
        if isAnimated(.highlights) { c.highlights = value(.highlights, at: local) }
        if isAnimated(.vibrance) { c.vibrance = value(.vibrance, at: local) }
        if isAnimated(.lutMix) { c.lutMix = value(.lutMix, at: local) }
        return c
    }
    func opacity(at local: Double) -> Double { value(.opacity, at: local) }
    func volume(at local: Double) -> Double { value(.volume, at: local) }
    func speed(at local: Double) -> Double { max(0, value(.speed, at: local)) }

    /// Media consumed between the clip's start and a clip-local time: ∫ speed dt, exact for every ease.
    func sourceOffset(at local: Double) -> Double {
        let ks = keyframes(.speed)
        guard let first = ks.first, let last = ks.last else { return max(0, local) * speed }
        let end = max(0, local)
        var acc = 0.0
        // Before the first keyframe the speed is constant at its value.
        acc += min(end, max(0, first.time)) * first.value
        if end <= first.time { return acc }
        for (a, b) in zip(ks, ks.dropFirst()) {
            let s0 = max(0, a.time), s1 = min(end, b.time)
            guard s1 > s0 else { if a.time >= end { break } else { continue } }
            let span = b.time - a.time
            let x0 = (s0 - a.time) / span, x1 = (s1 - a.time) / span
            let f: (Double) -> Double
            switch a.ease {
            case .hold: f = { x in a.value * x }
            case .linear: f = { x in a.value * x + (b.value - a.value) * x * x / 2 }
            case .smooth: f = { x in a.value * x + (b.value - a.value) * (x * x * x - x * x * x * x / 2) }
            }
            acc += (f(x1) - f(x0)) * span
        }
        if end > last.time { acc += (end - max(0, last.time)) * last.value }
        return acc
    }

    /// Adds or replaces a keyframe (same time within a frame), keeping the list sorted.
    mutating func setKeyframe(_ p: ClipParam, at local: Double, value v: Double, ease: Keyframe.Ease? = nil) {
        var ks = keyframes(p)
        if let i = ks.firstIndex(where: { abs($0.time - local) < 1.0 / 120 }) { ks[i].value = v; if let ease { ks[i].ease = ease } }
        else { ks.append(Keyframe(time: local, value: v, ease: ease ?? .linear)) }
        ks.sort { $0.time < $1.time }
        animations[p.rawValue] = ks
    }
    @discardableResult
    mutating func removeKeyframe(_ p: ClipParam, at local: Double) -> Bool {
        var ks = keyframes(p)
        guard let i = ks.firstIndex(where: { abs($0.time - local) < 1.0 / 120 }) else { return false }
        ks.remove(at: i)
        animations[p.rawValue] = ks.isEmpty ? nil : ks
        return true
    }
    /// Drops every keyframe of a parameter, freezing it at the value it has at `local` (nil keeps the plain value).
    mutating func clearAnimation(_ p: ClipParam, freezeAt local: Double? = nil) {
        if let local, isAnimated(p) { setBase(p, value(p, at: local)) }
        animations[p.rawValue] = nil
    }
    mutating func setBase(_ p: ClipParam, _ v: Double) {
        switch p {
        case .scale: transform.scale = v; case .x: transform.x = v; case .y: transform.y = v; case .rotation: transform.rotation = v
        case .opacity: opacity = v
        case .exposure: color.exposure = v; case .contrast: color.contrast = v; case .saturation: color.saturation = v
        case .temperature: color.temperature = v; case .tint: color.tint = v
        case .shadows: color.shadows = v; case .midtones: color.midtones = v; case .highlights: color.highlights = v; case .vibrance: color.vibrance = v; case .lutMix: color.lutMix = v
        case .volume: volume = v; case .speed: speed = v
        }
    }
    /// Moves every keyframe in time (a head trim or split changes where local 0 is).
    mutating func shiftKeyframes(by delta: Double) {
        guard delta != 0 else { return }
        for k in animations.keys { animations[k] = animations[k]?.map { var x = $0; x.time += delta; return x } }
    }
}

/// A named point on the timeline.
struct Marker: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var time: Double
    var name: String = ""
    var colorHex: String = "#3B82F6"
}

struct Track: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var kind: TrackKind
    var clips: [Clip] = []
    var isMuted = false
    var isHidden = false
    /// Automatic ducking under another track's clips (audio tracks and video tracks with sound alike).
    var duck: Ducking? = nil

    init(id: UUID = UUID(), name: String, kind: TrackKind, clips: [Clip] = [], isMuted: Bool = false, isHidden: Bool = false, duck: Ducking? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.clips = clips; self.isMuted = isMuted; self.isHidden = isHidden; self.duck = duck
    }
    // Every optional key has a default, so files from any earlier version open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(TrackKind.self, forKey: .kind)
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        duck = try c.decodeIfPresent(Ducking.self, forKey: .duck)
    }
}

struct TextOverlay: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var start: Double
    var duration: Double
    var fontSize: Double = 64
    var colorHex: String = "#FFFFFF"
    var x: Double = 0.5     // normalized center
    var y: Double = 0.85
    var preset: String? = nil   // CaptionPresets name; nil = "title"
    var group: UUID? = nil      // set on captions made in one go, so they can be removed together
    var end: Double { start + duration }
    var isCaption: Bool { group != nil }
}

/// One recognized word of an asset's audio, in asset seconds.
struct TranscriptWord: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// Speech recognized in an asset, cached on the project so captions and searches do not transcribe twice.
struct Transcript: Codable, Equatable {
    var locale: String
    var words: [TranscriptWord]
    var createdAt: Date = Date()
    var text: String { words.map(\.text).joined(separator: " ") }
}

enum EditOrigin: String, Codable { case user, agent, system }

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String
    var origin: EditOrigin
    var createdAt: Date = Date()
    var project: Data        // encoded Project without history
}

struct Project: Codable, Equatable {
    /// File format: 1 = before 2026-11-05 (tint drawn the wrong way round), 2 = current. Missing in old files.
    static let currentFormat = 2
    var formatVersion: Int = Project.currentFormat
    var name: String = "Untitled"
    var settings = ProjectSettings()
    var assets: [Asset] = []
    var tracks: [Track] = [Track(name: "V1", kind: .video), Track(name: "A1", kind: .audio)]
    /// Row of the Text lane in the timeline (0 = top); nil = below the tracks. Display only: text always draws over the picture.
    var textLaneRow: Int? = nil
    var texts: [TextOverlay] = []
    var markers: [Marker] = []
    var transcripts: [String: Transcript]? = nil   // keyed by asset id; a cache, left out of history snapshots
    /// Stabilization samples keyed by `Stabilization.pathKey` (asset, source range, strength): analysis results, a cache like
    /// `transcripts`, left out of history snapshots and kept across undo/redo/restore.
    var motionPaths: [String: [Stabilization.Sample]]? = nil
    /// Nested sequences (timelines folded into one clip); assets of kind `.sequence` point at them.
    var sequences: [Sequence] = []
    var history: [HistoryEntry] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1   // files before the field was added
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        settings = try c.decodeIfPresent(ProjectSettings.self, forKey: .settings) ?? ProjectSettings()
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? [Track(name: "V1", kind: .video), Track(name: "A1", kind: .audio)]
        textLaneRow = try c.decodeIfPresent(Int.self, forKey: .textLaneRow)
        texts = try c.decodeIfPresent([TextOverlay].self, forKey: .texts) ?? []
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        transcripts = try c.decodeIfPresent([String: Transcript].self, forKey: .transcripts)
        motionPaths = try c.decodeIfPresent([String: [Stabilization.Sample]].self, forKey: .motionPaths)
        sequences = try c.decodeIfPresent([Sequence].self, forKey: .sequences) ?? []
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
    }

    var duration: Double {
        let clipEnd = tracks.flatMap(\.clips).map(\.end).max() ?? 0
        let textEnd = texts.map(\.end).max() ?? 0
        return max(clipEnd, textEnd)
    }

    func asset(_ id: UUID) -> Asset? { assets.first { $0.id == id } }
    func sequence(_ id: UUID) -> Sequence? { sequences.first { $0.id == id } }
    /// The nested sequence a clip plays, if its asset is one.
    func sequence(of clip: Clip) -> Sequence? { asset(clip.assetID)?.sequenceID.flatMap(sequence) }
    func track(_ id: UUID) -> Track? { tracks.first { $0.id == id } }
    func clip(_ id: UUID) -> (track: Track, clip: Clip)? {
        for t in tracks { if let c = t.clips.first(where: { $0.id == id }) { return (t, c) } }
        return nil
    }
    var allClips: [Clip] { tracks.flatMap(\.clips) }
    /// Any clip carries a color grade (beyond its conversion LUT), plain or keyframed: the before/after view has something to show.
    var hasColorGrade: Bool {
        allClips.contains { c in c.color.hasGrade || [ClipParam.exposure, .contrast, .saturation, .temperature, .tint].contains(where: c.isAnimated) }
    }

    /// Copy of this project with history (and the transcript cache) stripped, for snapshots and resource reads.
    var withoutHistory: Project { var p = self; p.history = []; p.transcripts = nil; p.motionPaths = nil; return p }
    /// The clip with its stabilization samples filled in from the cache (the compositor reads them from the clip).
    func hydrated(_ clip: Clip) -> Clip {
        guard var st = clip.stabilization, st.samples.isEmpty, let samples = motionPaths?[st.pathKey], !samples.isEmpty else { return clip }
        var c = clip; st.samples = samples; c.stabilization = st; return c
    }
    func transcript(for assetID: UUID) -> Transcript? { transcripts?[assetID.uuidString] }
}

enum EditError: LocalizedError {
    case notFound(String), invalid(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let s): return "Not found: \(s)"
        case .invalid(let s): return "Invalid: \(s)"
        }
    }
}

// MARK: - Timeline operations (pure mutations on Project)

extension Project {
    func trackIndex(_ id: UUID) throws -> Int {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("track \(id)") }
        return i
    }
    func clipIndex(_ id: UUID) throws -> (Int, Int) {
        for (ti, t) in tracks.enumerated() {
            if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        throw EditError.notFound("clip \(id)")
    }

    /// Resolve a user/agent supplied prefix or full UUID against a list of ids.
    static func resolve(_ text: String, in ids: [UUID]) -> UUID? {
        let needle = text.lowercased()
        if let full = UUID(uuidString: text) { return ids.contains(full) ? full : nil }
        let matches = ids.filter { $0.uuidString.lowercased().hasPrefix(needle) }
        return matches.count == 1 ? matches[0] : nil
    }

    func firstTrack(of kind: TrackKind) -> Track? { tracks.first { $0.kind == kind } }

    /// End of the last clip on a track (0 if empty).
    func trackEnd(_ trackID: UUID) -> Double { track(trackID)?.clips.map(\.end).max() ?? 0 }

    /// Timeline rows top to bottom: tracks with the Text lane at `textLaneRow`.
    enum Row: Identifiable, Equatable {
        case track(Track), text
        var id: UUID { if case .track(let t) = self { return t.id }; return Project.textRowID }
    }
    static let textRowID = UUID(uuidString: "00000000-0000-0000-0000-00000000007E")!
    var rows: [Row] {
        var r = tracks.map(Row.track)
        r.insert(.text, at: min(textLaneRow ?? tracks.count, tracks.count))
        return r
    }

    /// Moves a row (a track or the Text lane) to another row. Returns false when nothing changed.
    @discardableResult
    mutating func moveRow(_ id: UUID, toRow index: Int) -> Bool {
        var r = rows
        guard let from = r.firstIndex(where: { $0.id == id }) else { return false }
        let to = max(0, min(r.count - 1, index))
        guard from != to else { return false }
        let row = r.remove(at: from)
        r.insert(row, at: to)
        tracks = r.compactMap { if case .track(let t) = $0 { return t }; return nil }
        textLaneRow = r.firstIndex(of: .text)
        return true
    }

    /// Moves a track to another row. The top row covers the rows below it in the picture. Returns false when nothing changed.
    @discardableResult
    mutating func moveTrack(_ id: UUID, toIndex index: Int) -> Bool {
        guard let from = tracks.firstIndex(where: { $0.id == id }) else { return false }
        let to = max(0, min(tracks.count - 1, index))
        guard from != to else { return false }
        let t = tracks.remove(at: from)
        tracks.insert(t, at: to)
        return true
    }

    /// Removes a track with everything on it. Returns the number of clips that went with it.
    @discardableResult
    mutating func removeTrack(_ id: UUID) -> Int {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return 0 }
        let n = tracks[i].clips.count
        tracks.remove(at: i)
        if let row = textLaneRow, row > tracks.count { textLaneRow = tracks.count }
        return n
    }

    /// Removes a media file from the project with every clip that uses it. Returns the number of clips removed.
    @discardableResult
    mutating func removeAsset(_ id: UUID) -> Int {
        var n = 0
        for ti in tracks.indices { let before = tracks[ti].clips.count; tracks[ti].clips.removeAll { $0.assetID == id }; n += before - tracks[ti].clips.count }
        assets.removeAll { $0.id == id }
        transcripts?[id.uuidString] = nil
        return n
    }

    mutating func addTrack(name: String? = nil, kind: TrackKind) -> Track {
        let n = tracks.filter { $0.kind == kind }.count + 1
        let t = Track(name: name ?? "\(kind == .video ? "V" : "A")\(n)", kind: kind)
        tracks.append(t)
        return t
    }

    /// Insert a clip for `assetID`. `at == nil` appends after the last clip on the track.
    @discardableResult
    mutating func insertClip(assetID: UUID, trackID: UUID? = nil, at: Double? = nil,
                             sourceIn: Double = 0, duration: Double? = nil) throws -> Clip {
        guard let asset = asset(assetID) else { throw EditError.notFound("asset \(assetID)") }
        let kind: TrackKind = asset.kind == .audio ? .audio : .video
        let tid = trackID ?? firstTrack(of: kind)?.id ?? addTrack(kind: kind).id
        let ti = try trackIndex(tid)
        let maxDur = max(0.01, asset.duration - sourceIn)
        let dur = min(duration ?? maxDur, maxDur)
        guard dur > 0 else { throw EditError.invalid("duration must be > 0") }
        let start = at ?? trackEnd(tid)
        let clip = Clip(assetID: assetID, name: asset.name, start: max(0, start), duration: dur, sourceIn: sourceIn)
        tracks[ti].clips.append(clip)
        tracks[ti].clips.sort { $0.start < $1.start }
        return clip
    }

    /// Split a clip at an absolute timeline time. Returns (left, right).
    @discardableResult
    mutating func splitClip(_ id: UUID, at time: Double) throws -> (Clip, Clip) {
        let (ti, ci) = try clipIndex(id)
        var left = tracks[ti].clips[ci]
        guard time > left.start + 0.01, time < left.end - 0.01 else {
            throw EditError.invalid("split time \(time) is outside clip \(left.start)...\(left.end)")
        }
        let right: Clip
        (left, right) = left.split(atLocal: time - left.start)
        tracks[ti].clips[ci] = left
        tracks[ti].clips.insert(right, at: ci + 1)
        return (left, right)
    }

    mutating func moveClip(_ id: UUID, to start: Double, trackID: UUID? = nil) throws {
        let (ti, ci) = try clipIndex(id)
        var clip = tracks[ti].clips.remove(at: ci)
        clip.start = max(0, start)
        let target = try trackID.map(trackIndex) ?? ti
        guard tracks[target].kind == tracks[ti].kind else { throw EditError.invalid("track kind mismatch") }
        tracks[target].clips.append(clip)
        tracks[target].clips.sort { $0.start < $1.start }
    }

    /// Trim by setting new timeline in/out points (absolute seconds). Either may be nil.
    mutating func trimClip(_ id: UUID, newStart: Double?, newEnd: Double?) throws {
        let (ti, ci) = try clipIndex(id)
        var c = tracks[ti].clips[ci]
        let s = newStart ?? c.start
        let e = newEnd ?? c.end
        guard e - s > 0.01 else { throw EditError.invalid("trim would leave an empty clip") }
        let delta = s - c.start
        let consumed = delta >= 0 ? c.sourceOffset(at: delta) : -c.speed(at: 0) * -delta   // extending the head runs the first speed backwards
        guard c.sourceIn + consumed >= 0 else { throw EditError.invalid("cannot trim before source start") }
        c.sourceIn += consumed
        c.start = s
        c.duration = e - s
        c.shiftKeyframes(by: -delta)
        tracks[ti].clips[ci] = c
    }

    mutating func removeClips(_ ids: [UUID]) -> Int {
        var removed = 0
        for ti in tracks.indices {
            let before = tracks[ti].clips.count
            tracks[ti].clips.removeAll { ids.contains($0.id) }
            removed += before - tracks[ti].clips.count
        }
        return removed
    }

    /// Moves several clips by the same amount, stopping at 0 as a group so their spacing is kept.
    mutating func moveClips(_ ids: Set<UUID>, by delta: Double) {
        let starts = allClips.filter { ids.contains($0.id) }.map(\.start)
        guard let minStart = starts.min() else { return }
        let d = max(delta, -minStart)
        for ti in tracks.indices {
            for ci in tracks[ti].clips.indices where ids.contains(tracks[ti].clips[ci].id) { tracks[ti].clips[ci].start += d }
            tracks[ti].clips.sort { $0.start < $1.start }
        }
    }

    /// The clip that ends where `clip` starts on the same track (the one a transition into `clip` plays over).
    func clipBefore(_ clip: Clip, on track: Track) -> Clip? {
        track.clips.first { $0.id != clip.id && abs($0.end - clip.start) < 0.02 }
    }

    mutating func updateClip(_ id: UUID, _ body: (inout Clip) -> Void) throws {
        let (ti, ci) = try clipIndex(id)
        body(&tracks[ti].clips[ci])
    }

    /// Close gaps on a track so clips play back to back.
    mutating func ripple(trackID: UUID) throws {
        let ti = try trackIndex(trackID)
        var cursor = 0.0
        for ci in tracks[ti].clips.indices {
            tracks[ti].clips[ci].start = cursor
            cursor += tracks[ti].clips[ci].duration
        }
    }

    @discardableResult
    mutating func addText(_ text: String, start: Double, duration: Double,
                          fontSize: Double = 64, colorHex: String = "#FFFFFF", x: Double = 0.5, y: Double = 0.85) -> TextOverlay {
        let t = TextOverlay(text: text, start: start, duration: duration, fontSize: fontSize, colorHex: colorHex, x: x, y: y)
        texts.append(t)
        return t
    }

    mutating func removeTexts(_ ids: [UUID]) -> Int {
        let before = texts.count
        texts.removeAll { ids.contains($0.id) }
        return before - texts.count
    }
    /// Remove the captions of one group, or every caption when `group` is nil.
    mutating func removeCaptions(group: UUID?) -> Int {
        let before = texts.count
        texts.removeAll { $0.group != nil && (group == nil || $0.group == group) }
        return before - texts.count
    }
}

// MARK: - Short IDs for humans and agents

extension UUID {
    /// First 8 hex chars; `Project.resolve` accepts these as prefixes.
    var short: String { String(uuidString.lowercased().prefix(8)) }
}


extension Project {
    /// Brings a decoded project up to the current format. Format 1 stored tint with the opposite sign
    /// (its renderer drew + as green), so every tint value and tint keyframe is negated to keep the picture the same.
    mutating func migrateToCurrentFormat() {
        guard formatVersion < Project.currentFormat else { return }
        if formatVersion < 2 {
            func flip(_ clips: inout [Clip]) {
                for i in clips.indices {
                    clips[i].color.tint = -clips[i].color.tint
                    if var ks = clips[i].animations[ClipParam.tint.rawValue] {
                        for k in ks.indices { ks[k].value = -ks[k].value }
                        clips[i].animations[ClipParam.tint.rawValue] = ks
                    }
                }
            }
            for t in tracks.indices { flip(&tracks[t].clips) }
            for q in sequences.indices { sequences[q].project.migrateToCurrentFormat() }
            for h in history.indices {
                if var old = try? EditMaxDocument.decoder.decode(Project.self, from: history[h].project), old.formatVersion < 2 {
                    old.migrateToCurrentFormat()
                    if let d = try? EditMaxDocument.encoder.encode(old) { history[h].project = d }
                }
            }
        }
        formatVersion = Project.currentFormat
    }
}
