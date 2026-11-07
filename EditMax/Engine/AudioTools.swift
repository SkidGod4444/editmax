import Foundation
import AVFoundation

/// Audio operations: dynamics, hum and sibilance, clip gain and pan, crossfades, the mixer, loudness. Same rules as the
/// rest of `ToolExecutor`: the UI and the MCP tools call these, and out-of-range values are refused, never clamped.
extension ToolExecutor {
    private var current: Project { document.project }

    private static func fmt(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%g", (x * 1000).rounded() / 1000) }
    private static func check(_ name: String, _ v: Double?, _ range: ClosedRange<Double>, _ unit: String) throws {
        guard let v else { return }
        guard v.isFinite, range.contains(v) else { throw EditError.invalid("\(name) must be \(fmt(range.lowerBound)) to \(fmt(range.upperBound))\(unit); got \(fmt(v))") }
    }
    nonisolated static func finite(_ x: Double) -> Double? { x.isFinite ? (x * 100).rounded() / 100 : nil }

    /// A clip that has sound (not a still), resolved by id or name.
    private func soundClip(_ text: String) throws -> (id: UUID, track: Track, clip: Clip) {
        let id = try resolveClip(text)
        guard let f = current.clip(id) else { throw EditError.notFound("clip '\(text)'") }
        let asset = current.asset(f.clip.audioAssetID ?? f.clip.assetID)
        guard asset?.kind != .image else { throw EditError.invalid("'\(f.clip.name)' is a still image: it has no sound") }
        return (id, f.track, f.clip)
    }

    struct ClipAudioChange: Codable { var clip: String, name: String; var changed: [String]; var audio: ClipAudio; var note: String? }

    private func updateAudio(_ id: UUID, _ label: String, changed: [String], note: String? = nil, _ body: (inout ClipAudio) -> Void) throws -> ClipAudioChange {
        try document.apply(label, origin: origin, coalesce: coalesce) { p in try p.updateClip(id) { body(&$0.audio) } }
        let c = current.clip(id)!.clip
        return ClipAudioChange(clip: id.short, name: c.name, changed: changed, audio: c.audio, note: note)
    }

    /// enabled false removes; otherwise at least one setting or enabled true is needed.
    private static func toggle(_ what: String, enabled: Bool?, given: Bool) throws -> Bool {
        if enabled == false {
            guard !given else { throw EditError.invalid("enabled false removes the \(what); leave the other settings out") }
            return false
        }
        guard given || enabled == true else { throw EditError.invalid("nothing to change: give enabled true or at least one \(what) setting") }
        return true
    }

    // MARK: Dynamics

    func setClipCompressor(_ clip: String, enabled: Bool?, threshold: Double?, ratio: Double?, attack: Double?, release: Double?, knee: Double?, makeup: Double?) throws -> ClipAudioChange {
        let f = try soundClip(clip)
        guard try Self.toggle("compressor", enabled: enabled, given: [threshold, ratio, attack, release, knee, makeup].contains { $0 != nil }) else {
            return try updateAudio(f.id, "Remove compressor", changed: ["compressor removed"]) { $0.compressor = nil }
        }
        typealias C = CompressorSettings
        try Self.check("threshold", threshold, C.thresholdRange, " dBFS"); try Self.check("ratio", ratio, C.ratioRange, ":1")
        try Self.check("attack", attack, C.attackRange, " ms"); try Self.check("release", release, C.releaseRange, " ms")
        try Self.check("knee", knee, C.kneeRange, " dB"); try Self.check("makeup", makeup, C.makeupRange, " dB")
        var s = f.clip.audio.compressor ?? C()
        var changed: [String] = f.clip.audio.compressor == nil ? ["compressor on"] : []
        if let threshold { s.threshold = threshold; changed.append("threshold \(Self.fmt(threshold)) dBFS") }
        if let ratio { s.ratio = ratio; changed.append("ratio \(Self.fmt(ratio)):1") }
        if let attack { s.attack = attack; changed.append("attack \(Self.fmt(attack)) ms") }
        if let release { s.release = release; changed.append("release \(Self.fmt(release)) ms") }
        if let knee { s.knee = knee; changed.append("knee \(Self.fmt(knee)) dB") }
        if let makeup { s.makeup = makeup; changed.append("makeup \(Self.fmt(makeup)) dB") }
        let final = s
        return try updateAudio(f.id, "Compressor", changed: changed) { $0.compressor = final }
    }

    func setClipLimiter(_ clip: String, enabled: Bool?, ceiling: Double?, release: Double?, lookahead: Double?) throws -> ClipAudioChange {
        let f = try soundClip(clip)
        guard try Self.toggle("limiter", enabled: enabled, given: [ceiling, release, lookahead].contains { $0 != nil }) else {
            return try updateAudio(f.id, "Remove limiter", changed: ["limiter removed"]) { $0.limiter = nil }
        }
        typealias L = LimiterSettings
        try Self.check("ceiling", ceiling, L.ceilingRange, " dBTP"); try Self.check("release", release, L.releaseRange, " ms"); try Self.check("lookahead", lookahead, L.lookaheadRange, " ms")
        var s = f.clip.audio.limiter ?? L()
        var changed: [String] = f.clip.audio.limiter == nil ? ["limiter on"] : []
        if let ceiling { s.ceiling = ceiling; changed.append("ceiling \(Self.fmt(ceiling)) dBTP") }
        if let release { s.release = release; changed.append("release \(Self.fmt(release)) ms") }
        if let lookahead { s.lookahead = lookahead; changed.append("look-ahead \(Self.fmt(lookahead)) ms") }
        let final = s
        return try updateAudio(f.id, "Limiter", changed: changed) { $0.limiter = final }
    }

    func setClipDeEsser(_ clip: String, enabled: Bool?, amount: Double?, frequency: Double?) throws -> ClipAudioChange {
        let f = try soundClip(clip)
        guard try Self.toggle("de-esser", enabled: enabled, given: amount != nil || frequency != nil) else {
            return try updateAudio(f.id, "Remove de-esser", changed: ["de-esser removed"]) { $0.deEsser = nil }
        }
        try Self.check("amount", amount, DeEsserSettings.amountRange, ""); try Self.check("frequency", frequency, DeEsserSettings.frequencyRange, " Hz")
        var s = f.clip.audio.deEsser ?? DeEsserSettings()
        var changed: [String] = f.clip.audio.deEsser == nil ? ["de-esser on"] : []
        if let amount { s.amount = amount; changed.append("amount \(Self.fmt(amount))") }
        if let frequency { s.frequency = frequency; changed.append("frequency \(Self.fmt(frequency)) Hz") }
        let final = s
        return try updateAudio(f.id, "De-esser", changed: changed) { $0.deEsser = final }
    }

    /// `frequency` "auto" (the default when hum removal is first switched on) listens to the clip's own sound and picks
    /// 50 or 60 Hz; the detection numbers come back in the note.
    func setClipHumRemoval(_ clip: String, enabled: Bool?, frequency: String?, amount: Double?, harmonics: Int?) async throws -> ClipAudioChange {
        let f = try soundClip(clip)
        guard try Self.toggle("hum removal", enabled: enabled, given: frequency != nil || amount != nil || harmonics != nil) else {
            return try updateAudio(f.id, "Remove hum removal", changed: ["hum removal removed"]) { $0.hum = nil }
        }
        try Self.check("amount", amount, HumSettings.amountRange, "")
        if let harmonics, !HumSettings.harmonicsRange.contains(harmonics) { throw EditError.invalid("harmonics must be 1 to 8; got \(harmonics)") }
        let key = frequency?.lowercased().replacingOccurrences(of: "hz", with: "").trimmingCharacters(in: .whitespaces)
        guard key == nil || ["auto", "50", "60"].contains(key!) else { throw EditError.invalid("frequency must be auto, 50 or 60; got '\(frequency!)'") }
        var s = f.clip.audio.hum ?? HumSettings()
        var changed: [String] = f.clip.audio.hum == nil ? ["hum removal on"] : []
        var note: String? = nil
        if key == "auto" || (key == nil && f.clip.audio.hum == nil) {
            let d = try await detectHum(f.id)
            s.frequency = d.frequency
            changed.append("frequency \(Int(d.frequency)) Hz (detected)")
            note = "Detected from the clip's sound: hum stands \(Self.fmt(d.prominence50)) dB above its surroundings at 50 Hz and its harmonics, \(Self.fmt(d.prominence60)) dB at 60 Hz."
                + (d.clear ? "" : " Neither stands out clearly, so there may be little hum to remove; \(Int(d.frequency)) Hz was the stronger.")
        } else if let key, let v = Double(key) { s.frequency = v; changed.append("frequency \(key) Hz") }
        if let amount { s.amount = amount; changed.append("amount \(Self.fmt(amount))") }
        if let harmonics { s.harmonics = harmonics; changed.append("\(harmonics) harmonics") }
        let final = s
        return try updateAudio(f.id, "Hum removal", changed: changed, note: note) { $0.hum = final }
    }

    /// 50 or 60 Hz, from the clip's unprocessed sound. The detector looks at its first minute, so only that is read.
    func detectHum(_ id: UUID) async throws -> HumDetector.Result {
        var p = try Loudness.isolate(id, in: current)
        p.tracks[0].clips[0].audio = ClipAudio()
        p.tracks[0].clips[0].volume = 1; p.tracks[0].clips[0].animations[ClipParam.volume.rawValue] = nil
        p.tracks[0].clips[0].fadeIn = 0; p.tracks[0].clips[0].fadeOut = 0
        let st = try await Loudness.render(p, seconds: HumDetector.seconds)
        var mono = [Float](repeating: 0, count: st.count / 2)
        for i in 0..<mono.count { mono[i] = (st[2 * i] + st[2 * i + 1]) * 0.5 }
        guard mono.count >= 48_000 else { throw EditError.invalid("the clip is under a second long: too short to tell 50 from 60 Hz hum; give frequency 50 or 60") }
        return HumDetector.detect(mono, sampleRate: 48_000)
    }

    // MARK: Gain and pan

    func setClipMix(_ clip: String, gain: Double?, pan: Double?) async throws -> ClipAudioChange {
        let f = try soundClip(clip)
        guard gain != nil || pan != nil else { throw EditError.invalid("nothing to change: give gain (dB) or pan (-1 to 1)") }
        try Self.check("gain", gain, ClipAudio.gainRange, " dB"); try Self.check("pan", pan, ClipAudio.panRange, "")
        if let pan, pan != 0, let n = await AudioChannels.count(of: f.clip, in: current), n < 2 {
            throw EditError.invalid("'\(f.clip.name)' has mono sound: AVFoundation hands its processing one channel and spreads it to both speakers afterwards, so it cannot be panned")
        }
        var changed: [String] = []
        if let gain { changed.append("gain \(Self.fmt(gain)) dB") }
        if let pan { changed.append("pan \(Self.fmt(pan))") }
        return try updateAudio(f.id, "Clip gain and pan", changed: changed) { a in
            if let gain { a.gain = gain }
            if let pan { a.pan = pan }
        }
    }

    // MARK: Crossfades

    struct CrossfadeResult: Codable { var clip: String, name: String; var from: String?; var duration: Double; var requested: Double?; var curve: String?; var note: String? }

    /// A sound crossfade into `clip` from the clip that ends where it starts on the same audio track.
    func setAudioCrossfade(_ clip: String, duration: Double?, curve: String?, remove: Bool) throws -> CrossfadeResult {
        let f = try soundClip(clip)
        if remove {
            guard duration == nil, curve == nil else { throw EditError.invalid("remove true takes the crossfade off; leave duration and curve out") }
            try document.apply("Remove crossfade", origin: origin) { p in try p.updateClip(f.id) { $0.audioCrossfade = nil } }
            return CrossfadeResult(clip: f.id.short, name: f.clip.name, from: nil, duration: 0, requested: nil, curve: nil, note: f.clip.audioCrossfade == nil ? "There was no crossfade." : nil)
        }
        guard f.track.kind == .audio else { throw EditError.invalid("'\(f.clip.name)' is on video track \(f.track.name): crossfade its sound with set_transition, which fades picture and sound together") }
        try Self.check("duration", duration, AudioCrossfade.durationRange, " s")
        var c: AudioCrossfade.Curve = f.clip.audioCrossfade?.curve ?? .equalPower
        if let curve {
            let k = curve.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            switch k {
            case "equalpower", "power", "constantpower": c = .equalPower
            case "linear", "equalgain", "constantgain": c = .linear
            default: throw EditError.invalid("curve must be equal_power or linear; got '\(curve)'")
            }
        }
        guard let prev = current.clipBefore(f.clip, on: f.track) else { throw EditError.invalid("no clip on \(f.track.name) ends where '\(f.clip.name)' starts (at \(Self.fmt(f.clip.start)) s): a crossfade needs two clips that touch") }
        if f.clip.transitionIn != nil { throw EditError.invalid("'\(f.clip.name)' has a transition, which already crossfades its sound; remove it first (set_transition kind none)") }
        let want = duration ?? f.clip.audioCrossfade?.duration ?? 0.5
        let handle = AudioCrossfades.tailHandle(prev, in: current)
        guard handle >= 0.02 else { throw EditError.invalid("'\(prev.name)' has no sound past its out point to fade out with; trim its end earlier first") }
        var d = min(want, f.clip.duration)
        var note: String? = nil
        if handle < d { d = (handle * 100).rounded(.down) / 100; note = "Shortened to \(Self.fmt(d)) s: '\(prev.name)' has only \(String(format: "%.2f", handle)) s of sound past its out point." }
        else if d < want { note = "Shortened to \(Self.fmt(d)) s: the length of '\(f.clip.name)'." }
        let xf = AudioCrossfade(duration: d, curve: c)
        try document.apply("Crossfade", origin: origin, coalesce: coalesce) { p in try p.updateClip(f.id) { $0.audioCrossfade = xf } }
        return CrossfadeResult(clip: f.id.short, name: f.clip.name, from: prev.name, duration: d, requested: want, curve: c == .equalPower ? "equal_power" : "linear", note: note)
    }

    // MARK: Mixer

    struct TrackMixResult: Codable { var track: String; var changed: [String]; var gain: Double, pan: Double; var solo: Bool, muted: Bool; var bus: String?; var note: String? }

    func setTrackMix(_ track: String, gain: Double?, pan: Double?, solo: Bool?, mute: Bool?, bus: String?) async throws -> TrackMixResult {
        guard let tid = try resolveTrack(track), let t = current.track(tid) else { throw EditError.notFound("track '\(track)'") }
        guard gain != nil || pan != nil || solo != nil || mute != nil || bus != nil else { throw EditError.invalid("nothing to change: give gain, pan, solo, mute or bus") }
        try Self.check("gain", gain, TrackMix.gainRange, " dB"); try Self.check("pan", pan, TrackMix.panRange, "")
        var busID: UUID?? = nil
        if let bus {
            if bus.lowercased() == "none" || bus.lowercased() == "master" { busID = .some(nil) }
            else { busID = .some(try resolveBus(bus).id) }
        }
        var changed: [String] = []
        if let gain { changed.append("gain \(Self.fmt(gain)) dB") }
        if let pan { changed.append("pan \(Self.fmt(pan))") }
        if let solo { changed.append(solo ? "solo on" : "solo off") }
        if let mute { changed.append(mute ? "muted" : "unmuted") }
        if let busID { changed.append("routed to \(busID.flatMap { current.mix.bus($0)?.name } ?? "the master")") }
        var note: String? = nil
        if let pan, pan != 0 {
            var mono: [String] = []
            for c in t.clips { if let n = await AudioChannels.count(of: c, in: current), n < 2 { mono.append(c.name) } }
            if !mono.isEmpty { note = "Mono clips are not panned (AVFoundation spreads a one-channel source to both speakers after the track's processing): \(mono.prefix(5).joined(separator: ", "))\(mono.count > 5 ? " and \(mono.count - 5) more" : "")." }
        }
        try document.apply("Track mix \(t.name)", origin: origin, coalesce: coalesce) { p in
            guard let i = p.tracks.firstIndex(where: { $0.id == tid }) else { return }
            if let gain { p.tracks[i].mix.gain = gain }
            if let pan { p.tracks[i].mix.pan = pan }
            if let solo { p.tracks[i].mix.solo = solo }
            if let mute { p.tracks[i].isMuted = mute }
            if let busID { p.tracks[i].mix.bus = busID }
        }
        let n = current.track(tid)!
        return TrackMixResult(track: n.name, changed: changed, gain: n.mix.gain, pan: n.mix.pan, solo: n.mix.solo, muted: n.isMuted, bus: current.mix.bus(n.mix.bus)?.name, note: note)
    }

    func resolveBus(_ text: String) throws -> Bus {
        let buses = current.mix.buses
        if let id = Project.resolve(text, in: buses.map(\.id)), let b = buses.first(where: { $0.id == id }) { return b }
        if let b = buses.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) { return b }
        throw EditError.notFound("bus '\(text)' (buses: \(buses.isEmpty ? "none yet; set_bus with a new name creates one" : buses.map(\.name).joined(separator: ", ")))")
    }

    private static func compressor(_ d: [String: Double], base: CompressorSettings?) throws -> CompressorSettings {
        let known: Set<String> = ["threshold", "ratio", "attack", "release", "knee", "makeup"]
        if let bad = d.keys.first(where: { !known.contains($0) }) { throw EditError.invalid("compressor has no '\(bad)'; its settings are \(known.sorted().joined(separator: ", "))") }
        typealias C = CompressorSettings
        try check("compressor threshold", d["threshold"], C.thresholdRange, " dBFS"); try check("compressor ratio", d["ratio"], C.ratioRange, ":1")
        try check("compressor attack", d["attack"], C.attackRange, " ms"); try check("compressor release", d["release"], C.releaseRange, " ms")
        try check("compressor knee", d["knee"], C.kneeRange, " dB"); try check("compressor makeup", d["makeup"], C.makeupRange, " dB")
        var s = base ?? C()
        if let v = d["threshold"] { s.threshold = v }; if let v = d["ratio"] { s.ratio = v }; if let v = d["attack"] { s.attack = v }
        if let v = d["release"] { s.release = v }; if let v = d["knee"] { s.knee = v }; if let v = d["makeup"] { s.makeup = v }
        return s
    }
    private static func limiter(_ d: [String: Double], base: LimiterSettings?) throws -> LimiterSettings {
        let known: Set<String> = ["ceiling", "release", "lookahead"]
        if let bad = d.keys.first(where: { !known.contains($0) }) { throw EditError.invalid("limiter has no '\(bad)'; its settings are \(known.sorted().joined(separator: ", "))") }
        typealias L = LimiterSettings
        try check("limiter ceiling", d["ceiling"], L.ceilingRange, " dBTP"); try check("limiter release", d["release"], L.releaseRange, " ms"); try check("limiter lookahead", d["lookahead"], L.lookaheadRange, " ms")
        var s = base ?? L()
        if let v = d["ceiling"] { s.ceiling = v }; if let v = d["release"] { s.release = v }; if let v = d["lookahead"] { s.lookahead = v }
        return s
    }

    struct BusResult: Codable { var bus: String, id: String; var created: Bool; var removed: Bool; var changed: [String]; var gain: Double; var muted: Bool; var compressor: CompressorSettings?; var limiter: LimiterSettings?; var tracks: [String]; var note: String }

    /// Creates the bus when no bus has that name. `remove` deletes it and sends its tracks straight to the master.
    func setBus(_ bus: String, rename: String?, gain: Double?, mute: Bool?, compressor: [String: Double]?, removeCompressor: Bool, limiter: [String: Double]?, removeLimiter: Bool, remove: Bool) throws -> BusResult {
        let existing = try? resolveBus(bus)
        if remove {
            guard let b = existing else { throw EditError.notFound("bus '\(bus)'") }
            guard rename == nil, gain == nil, mute == nil, compressor == nil, limiter == nil, !removeCompressor, !removeLimiter else { throw EditError.invalid("remove true deletes the bus; leave the other settings out") }
            let members = current.tracks.filter { $0.mix.bus == b.id }.map(\.name)
            try document.apply("Remove bus \(b.name)", origin: origin) { p in
                p.mix.buses.removeAll { $0.id == b.id }
                for i in p.tracks.indices where p.tracks[i].mix.bus == b.id { p.tracks[i].mix.bus = nil }
            }
            return BusResult(bus: b.name, id: b.id.short, created: false, removed: true, changed: ["removed; \(members.isEmpty ? "no tracks were routed to it" : members.joined(separator: ", ") + " now go straight to the master")"], gain: b.gain, muted: b.isMuted, compressor: nil, limiter: nil, tracks: [], note: Self.busNote)
        }
        if compressor != nil && removeCompressor { throw EditError.invalid("give compressor or remove_compressor, not both") }
        if limiter != nil && removeLimiter { throw EditError.invalid("give limiter or remove_limiter, not both") }
        try Self.check("gain", gain, TrackMix.gainRange, " dB")
        let name = bus.trimmingCharacters(in: .whitespaces)
        guard existing != nil || !name.isEmpty else { throw EditError.invalid("give the bus a name") }
        if let rename, rename.trimmingCharacters(in: .whitespaces).isEmpty { throw EditError.invalid("rename must not be empty") }
        if let rename, current.mix.buses.contains(where: { $0.name.caseInsensitiveCompare(rename) == .orderedSame && $0.id != existing?.id }) { throw EditError.invalid("a bus is already called '\(rename)'") }
        var b = existing ?? Bus(name: name)
        var changed: [String] = existing == nil ? ["created"] : []
        if let rename { b.name = rename; changed.append("renamed \(rename)") }
        if let gain { b.gain = gain; changed.append("gain \(Self.fmt(gain)) dB") }
        if let mute { b.isMuted = mute; changed.append(mute ? "muted" : "unmuted") }
        if let compressor { b.compressor = try Self.compressor(compressor, base: b.compressor); changed.append("compressor \(compressor.isEmpty ? "on" : compressor.keys.sorted().map { "\($0) \(Self.fmt(compressor[$0]!))" }.joined(separator: ", "))") }
        if removeCompressor { b.compressor = nil; changed.append("compressor removed") }
        if let limiter { b.limiter = try Self.limiter(limiter, base: b.limiter); changed.append("limiter \(limiter.isEmpty ? "on" : limiter.keys.sorted().map { "\($0) \(Self.fmt(limiter[$0]!))" }.joined(separator: ", "))") }
        if removeLimiter { b.limiter = nil; changed.append("limiter removed") }
        guard !changed.isEmpty else { throw EditError.invalid("nothing to change: give gain, mute, compressor, limiter, rename or remove") }
        let final = b
        try document.apply(existing == nil ? "Add bus \(b.name)" : "Bus \(b.name)", origin: origin, coalesce: coalesce && existing != nil) { p in
            if let i = p.mix.buses.firstIndex(where: { $0.id == final.id }) { p.mix.buses[i] = final } else { p.mix.buses.append(final) }
        }
        let members = current.tracks.filter { $0.mix.bus == final.id }.map(\.name)
        return BusResult(bus: final.name, id: final.id.short, created: existing == nil, removed: false, changed: changed, gain: final.gain, muted: final.isMuted,
                         compressor: final.compressor, limiter: final.limiter, tracks: members,
                         note: Self.busNote + (members.isEmpty ? " No track is routed to it yet: set_track_mix with bus \(final.name)." : ""))
    }
    static let busNote = "A bus's gain is exact. Its compressor and limiter run once per member track, on that track alone (AVFoundation mixes the tracks itself and offers no stage after the sum), so they react to each track's own level, not to the bus total."

    struct MasterResult: Codable { var changed: [String]; var gain: Double; var limiter: LimiterSettings?; var note: String }

    func setMaster(gain: Double?, limiter: [String: Double]?, removeLimiter: Bool) throws -> MasterResult {
        guard gain != nil || limiter != nil || removeLimiter else { throw EditError.invalid("nothing to change: give gain, limiter or remove_limiter") }
        if limiter != nil && removeLimiter { throw EditError.invalid("give limiter or remove_limiter, not both") }
        try Self.check("gain", gain, ClipAudio.gainRange, " dB")
        var m = current.mix
        var changed: [String] = []
        if let gain { m.masterGain = gain; changed.append("gain \(Self.fmt(gain)) dB") }
        if let limiter { m.masterLimiter = try Self.limiter(limiter, base: m.masterLimiter); changed.append(m.masterLimiter == current.mix.masterLimiter ? "limiter unchanged" : "limiter ceiling \(Self.fmt(m.masterLimiter!.ceiling)) dBTP") }
        if removeLimiter { m.masterLimiter = nil; changed.append("limiter removed") }
        let final = m
        try document.apply("Master", origin: origin, coalesce: coalesce) { p in p.mix.masterGain = final.masterGain; p.mix.masterLimiter = final.masterLimiter }
        return MasterResult(changed: changed, gain: final.masterGain, limiter: final.masterLimiter, note: Self.masterNote)
    }
    static let masterNote = "The master gain is exact. The master limiter runs once per track (AVFoundation sums the tracks after every processing stage), so two tracks peaking together can pass its ceiling; normalize_loudness measures the real mix and lowers the gain until the summed true peak is under the ceiling."

    struct MixSummary: Codable {
        struct TrackInfo: Codable { var id: String, name: String, kind: String; var gain: Double, pan: Double; var muted: Bool, solo: Bool, silencedBySolo: Bool; var bus: String?; var processedClips: Int }
        struct BusInfo: Codable { var id: String, name: String; var gain: Double; var muted: Bool; var compressor: CompressorSettings?; var limiter: LimiterSettings?; var tracks: [String] }
        var tracks: [TrackInfo]; var buses: [BusInfo]; var masterGain: Double; var masterLimiter: LimiterSettings?; var note: String
    }

    func inspectMix() -> MixSummary {
        let p = current
        let tracks = p.tracks.map { t in
            MixSummary.TrackInfo(id: t.id.short, name: t.name, kind: t.kind.rawValue, gain: t.mix.gain, pan: t.mix.pan, muted: t.isMuted, solo: t.mix.solo,
                                 silencedBySolo: Mixer.isSilencedBySolo(t, in: p), bus: p.mix.bus(t.mix.bus)?.name, processedClips: t.clips.filter { !$0.audio.isIdentity }.count)
        }
        let buses = p.mix.buses.map { b in MixSummary.BusInfo(id: b.id.short, name: b.name, gain: b.gain, muted: b.isMuted, compressor: b.compressor, limiter: b.limiter, tracks: p.tracks.filter { $0.mix.bus == b.id }.map(\.name)) }
        return MixSummary(tracks: tracks, buses: buses, masterGain: p.mix.masterGain, masterLimiter: p.mix.masterLimiter, note: Self.busNote + " " + Self.masterNote)
    }

    // MARK: Loudness

    struct LoudnessReport: Codable {
        struct Target: Codable { var name: String; var lufs: Double; var difference: Double? }
        var scope: String
        var integrated: Double?, truePeak: Double?, samplePeak: Double?, rms: Double?, range: Double, momentaryMax: Double?, shortTermMax: Double?, duration: Double
        var targets: [Target]?
        var note: String?
        init(scope: String, _ r: LoudnessMeter.Result, targets: Bool = true) {
            self.scope = scope
            integrated = ToolExecutor.finite(r.integrated); truePeak = ToolExecutor.finite(r.truePeak); samplePeak = ToolExecutor.finite(r.samplePeak)
            rms = ToolExecutor.finite(r.rms); range = (r.range * 100).rounded() / 100; momentaryMax = ToolExecutor.finite(r.momentaryMax); shortTermMax = ToolExecutor.finite(r.shortTermMax)
            duration = (r.duration * 1000).rounded() / 1000
            if targets { let i = integrated; self.targets = Loudness.targets.map { t in Target(name: t.label, lufs: t.lufs, difference: i.map { ((t.lufs - $0) * 100).rounded() / 100 }) } }
            if !r.integrated.isFinite { note = "Silent: every 400 ms block is under −70 LUFS." }
        }
    }

    /// Integrated loudness (ITU-R BS.1770-4), true peak and the rest, for the whole mix or one clip alone, rendered the
    /// way the export renders it.
    func measureLoudness(clip: String?) async throws -> LoudnessReport {
        if let clip {
            let f = try soundClip(clip)
            return LoudnessReport(scope: "clip '\(f.clip.name)' alone (its own processing; no track fader, bus or master)", try await Loudness.measure(try Loudness.isolate(f.id, in: current)))
        }
        let soloed = current.tracks.filter(\.mix.solo).map(\.name)
        var r = LoudnessReport(scope: soloed.isEmpty ? "mix" : "mix with only the soloed tracks (\(soloed.joined(separator: ", ")))", try await Loudness.measure(current))
        if !soloed.isEmpty { r.note = [r.note, "Solo is on, so this is not the whole mix."].compactMap { $0 }.joined(separator: " ") }
        return r
    }

    struct NormalizeResult: Codable {
        var scope: String; var target: Double; var ceiling: Double
        var before: LoudnessReport; var after: LoudnessReport
        var changed: [String]; var gain: Double; var limiter: LimiterSettings
        var steps: [Loudness.Step]
        var note: String?
    }

    /// Brings the mix (master gain + master limiter) or one clip (clip gain + clip limiter) to `target` LUFS with the
    /// true peak at or under `ceiling` dBTP, then measures again and returns both measurements. One undo step.
    func normalizeLoudness(target: String?, ceiling: Double?, clip: String?) async throws -> NormalizeResult {
        let lufs = try Loudness.parseTarget(target)
        try Self.check("ceiling", ceiling, Loudness.ceilingRange, " dBTP")
        let ceil = ceiling ?? -1
        let start = current
        if let clip {
            let f = try soundClip(clip)
            let base = try Loudness.isolate(f.id, in: start)
            let before = try await Loudness.measure(base)
            let lim = LimiterSettings(ceiling: ceil, release: f.clip.audio.limiter?.release ?? 100, lookahead: f.clip.audio.limiter?.lookahead ?? 1.5)
            let plan = try await Loudness.solve(target: lufs, ceiling: ceil, startGain: f.clip.audio.gain, before: before, gainRange: ClipAudio.gainRange) { g in
                var p = base
                p.tracks[0].clips[0].audio.gain = g; p.tracks[0].clips[0].audio.limiter = lim
                return try await Loudness.measure(p)
            }
            let g = (plan.gain * 100).rounded() / 100
            try document.apply("Normalize \(f.clip.name) to \(Self.fmt(lufs)) LUFS", origin: origin) { p in try p.updateClip(f.id) { $0.audio.gain = g; $0.audio.limiter = lim } }
            return NormalizeResult(scope: "clip '\(f.clip.name)' alone", target: lufs, ceiling: ceil, before: LoudnessReport(scope: "before", before, targets: false), after: LoudnessReport(scope: "after", plan.after, targets: false),
                                   changed: ["clip gain \(Self.fmt(f.clip.audio.gain)) → \(Self.fmt(g)) dB", "clip limiter ceiling \(Self.fmt(ceil)) dBTP"], gain: g, limiter: lim, steps: plan.steps,
                                   note: [plan.note, "Measured on the clip alone; the track fader, bus and master still apply in the mix."].compactMap { $0 }.joined(separator: " "))
        }
        let soloed = start.tracks.filter(\.mix.solo).map(\.name)
        guard soloed.isEmpty else { throw EditError.invalid("solo is on (\(soloed.joined(separator: ", "))): the mix would be measured without the other tracks. Turn solo off first") }
        let before = try await Loudness.measure(start)
        let lim = LimiterSettings(ceiling: ceil, release: start.mix.masterLimiter?.release ?? 100, lookahead: start.mix.masterLimiter?.lookahead ?? 1.5)
        let plan = try await Loudness.solve(target: lufs, ceiling: ceil, startGain: start.mix.masterGain, before: before, gainRange: ClipAudio.gainRange) { g in
            var p = start
            p.mix.masterGain = g; p.mix.masterLimiter = lim
            return try await Loudness.measure(p)
        }
        let g = (plan.gain * 100).rounded() / 100
        try document.apply("Normalize to \(Self.fmt(lufs)) LUFS", origin: origin) { p in p.mix.masterGain = g; p.mix.masterLimiter = lim }
        return NormalizeResult(scope: "mix", target: lufs, ceiling: ceil, before: LoudnessReport(scope: "before", before, targets: false), after: LoudnessReport(scope: "after", plan.after, targets: false),
                               changed: ["master gain \(Self.fmt(start.mix.masterGain)) → \(Self.fmt(g)) dB", "master limiter ceiling \(Self.fmt(ceil)) dBTP"], gain: g, limiter: lim, steps: plan.steps, note: plan.note)
    }
}

/// Channel counts of the files clips play their sound from (a mono file cannot be panned in the tap).
@MainActor
enum AudioChannels {
    private static var cache: [String: Int] = [:]
    static func cached(_ clip: Clip, in project: Project) -> Int? {
        project.asset(clip.audioAssetID ?? clip.assetID).flatMap { cache[$0.path] }
    }
    static func count(of clip: Clip, in project: Project) async -> Int? {
        guard let a = project.asset(clip.audioAssetID ?? clip.assetID), a.kind != .image else { return nil }
        if let n = cache[a.path] { return n }
        guard let t = try? await AVURLAsset(url: a.url).loadTracks(withMediaType: .audio).first,
              let fd = try? await t.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        let n = Int(asbd.pointee.mChannelsPerFrame)
        cache[a.path] = n
        return n
    }
}
