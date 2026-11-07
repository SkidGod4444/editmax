import Foundation
import AVFoundation

// MARK: - ITU-R BS.1770-4 / EBU R128 meter

/// Integrated loudness (LUFS), loudness range (LU), true peak (dBTP), sample peak and RMS (dBFS), measured offline.
/// - K-weighting: the BS.1770 pre-filter (high shelf, +4 dB above ~1.7 kHz) and RLB high-pass (~38 Hz), designed for the
///   actual sample rate (at 48 kHz the coefficients are the standard's own).
/// - 400 ms blocks every 100 ms; absolute gate −70 LUFS, relative gate −10 LU under the absolute-gated level.
/// - Loudness range (EBU Tech 3342): 3 s windows every 100 ms, gates −70 LUFS and −20 LU, 10th to 95th percentile.
/// - True peak: 4× oversampled (`TruePeak`), the highest |value| over all channels.
/// Channel weights: 1 for every channel (mono, stereo; surround's LFE and the +1.5 dB rear weights are not used).
final class LoudnessMeter {
    struct Result: Codable, Equatable {
        var integrated: Double        // LUFS; -inf (reported as -70 or lower) when everything is gated out
        var range: Double             // LU
        var truePeak: Double          // dBTP
        var samplePeak: Double        // dBFS
        var rms: Double               // dBFS, all channels together
        var momentaryMax: Double      // LUFS, loudest 400 ms
        var shortTermMax: Double      // LUFS, loudest 3 s
        var duration: Double          // seconds measured
    }

    let channels: Int, sampleRate: Double
    private var k1: [Biquad], k2: [Biquad]
    private let tp: TruePeakDetector
    private let hop: Int
    private var hopEnergy = 0.0, hopFill = 0
    private var hops: [Double] = []        // weighted mean-square energy per 100 ms hop (sum over channels)
    private var peak = 0.0, truePeak = 0.0, sumSquares = 0.0, count = 0
    private let frame: UnsafeMutablePointer<Double>

    init(channels: Int, sampleRate: Double) {
        self.channels = max(1, channels); self.sampleRate = sampleRate
        let (a, b) = Self.kWeighting(sampleRate)
        k1 = Array(repeating: a, count: self.channels); k2 = Array(repeating: b, count: self.channels)
        tp = TruePeakDetector(channels: self.channels)
        hop = max(1, Int((sampleRate / 10).rounded()))
        frame = .allocate(capacity: self.channels)
    }
    deinit { frame.deallocate() }

    /// The two K-weighting sections for a sample rate (libebur128's analytic design; exact at 48 kHz).
    static func kWeighting(_ fs: Double) -> (Biquad, Biquad) {
        var f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
        var K = tan(.pi * f0 / fs)
        let Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1 + K / Q + K * K
        var s = Biquad()
        s.b0 = (Vh + Vb * K / Q + K * K) / a0; s.b1 = 2 * (K * K - Vh) / a0; s.b2 = (Vh - Vb * K / Q + K * K) / a0
        s.a1 = 2 * (K * K - 1) / a0; s.a2 = (1 - K / Q + K * K) / a0
        f0 = 38.13547087602444; Q = 0.5003270373238773
        K = tan(.pi * f0 / fs)
        a0 = 1 + K / Q + K * K
        var h = Biquad()
        h.b0 = 1; h.b1 = -2; h.b2 = 1
        h.a1 = 2 * (K * K - 1) / a0; h.a2 = (1 - K / Q + K * K) / a0
        return (s, h)
    }

    /// Feeds interleaved float frames.
    func feed(interleaved p: UnsafePointer<Float>, frames: Int) {
        for n in 0..<frames {
            for ch in 0..<channels { frame[ch] = Double(p[n * channels + ch]) }
            push()
        }
    }
    /// Feeds planar channels (one array per channel, equal lengths).
    func feed(planar chans: [[Float]]) {
        let n = chans.first?.count ?? 0
        for i in 0..<n {
            for ch in 0..<channels { frame[ch] = Double(chans[min(ch, chans.count - 1)][i]) }
            push()
        }
    }

    @inline(__always) private func push() {
        var e = 0.0
        for ch in 0..<channels {
            let x = frame[ch]
            peak = max(peak, abs(x)); sumSquares += x * x
            let y = k2[ch].process(k1[ch].process(x))
            e += y * y
        }
        truePeak = max(truePeak, tp.push(UnsafePointer(frame)))
        count += 1
        hopEnergy += e; hopFill += 1
        if hopFill == hop { hops.append(hopEnergy / Double(hop)); hopEnergy = 0; hopFill = 0 }
    }

    static func lufs(_ power: Double) -> Double { power > 0 ? -0.691 + 10 * log10(power) : -.infinity }

    var result: Result {
        // Momentary blocks: 4 hops (400 ms); short-term windows: 30 hops (3 s).
        func windows(_ w: Int) -> [Double] {
            guard hops.count >= w else { return [] }
            var out: [Double] = [], acc = hops[0..<w].reduce(0, +)
            out.append(acc / Double(w))
            for i in w..<hops.count { acc += hops[i] - hops[i - w]; out.append(max(0, acc) / Double(w)) }
            return out
        }
        let blocks = windows(4)
        let abs = blocks.filter { Self.lufs($0) > -70 }
        var integrated = -Double.infinity
        if !abs.isEmpty {
            let rel = Self.lufs(abs.reduce(0, +) / Double(abs.count)) - 10
            let gated = abs.filter { Self.lufs($0) > rel }
            if !gated.isEmpty { integrated = Self.lufs(gated.reduce(0, +) / Double(gated.count)) }
        }
        let st = windows(30)
        var range = 0.0
        let stAbs = st.filter { Self.lufs($0) > -70 }
        if !stAbs.isEmpty {
            let rel = Self.lufs(stAbs.reduce(0, +) / Double(stAbs.count)) - 20
            let l = stAbs.map(Self.lufs).filter { $0 > rel }.sorted()
            if l.count > 1 {
                let pct = { (p: Double) in l[min(l.count - 1, max(0, Int((p * Double(l.count - 1)).rounded())))] }
                range = pct(0.95) - pct(0.10)
            }
        }
        let db = { (x: Double) in x > 0 ? 20 * log10(x) : -Double.infinity }
        return Result(integrated: integrated, range: range, truePeak: db(truePeak), samplePeak: db(peak),
                      rms: count > 0 ? 10 * log10(max(1e-20, sumSquares / Double(count * channels))) : -.infinity,
                      momentaryMax: blocks.map(Self.lufs).max() ?? -.infinity, shortTermMax: st.map(Self.lufs).max() ?? -.infinity,
                      duration: Double(count) / sampleRate)
    }
}

// MARK: - Measuring a project

enum Loudness {
    /// Streaming targets: integrated loudness and the usual true-peak ceiling.
    static let targets: [(names: [String], lufs: Double, label: String)] = [
        (["youtube", "spotify", "tidal", "streaming", "web"], -14, "YouTube / Spotify (−14 LUFS)"),
        (["apple", "apple_music", "applemusic", "podcast", "podcasts", "apple_podcasts"], -16, "Apple Music / podcasts (−16 LUFS)"),
        (["ebu", "r128", "ebu_r128", "broadcast", "tv"], -23, "EBU R128 broadcast (−23 LUFS)"),
    ]
    static let targetRange = -40.0...(-5.0), ceilingRange = -9.0...0

    /// "youtube", "apple", "podcast", "ebu", "-14", "-14 LUFS"… → LUFS. Refuses anything else.
    static func parseTarget(_ text: String?) throws -> Double {
        guard let raw = text?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return -14 }
        let key = raw.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        if let t = targets.first(where: { $0.names.contains(key) || $0.names.contains(raw) }) { return t.lufs }
        let num = raw.replacingOccurrences(of: "lufs", with: "").replacingOccurrences(of: "lu", with: "").trimmingCharacters(in: .whitespaces)
        if let v = Double(num) {
            guard targetRange.contains(v) else { throw EditError.invalid("target \(v) LUFS is outside \(Int(targetRange.lowerBound)) to \(Int(targetRange.upperBound)) LUFS") }
            return v
        }
        throw EditError.invalid("target must be youtube (−14), apple or podcast (−16), ebu (−23) or a number of LUFS such as -14; got '\(text ?? "")'")
    }

    /// The clip alone: its own track and processing, none of the track fader, bus or master, starting at 0, no
    /// transition or crossfade.
    static func isolate(_ clipID: UUID, in project: Project) throws -> Project {
        guard let found = project.clip(clipID) else { throw EditError.notFound("clip \(clipID.short)") }
        var p = project
        var c = found.clip
        c.start = 0; c.transitionIn = nil; c.audioCrossfade = nil
        var t = found.track
        t.clips = [c]; t.isMuted = false; t.isHidden = false; t.duck = nil; t.mix = TrackMix()
        if t.kind == .video { t.kind = .audio }   // sound only: nothing to composite
        p.tracks = [t]; p.texts = []; p.mix = ProjectMix()
        return p
    }

    /// Renders the project's sound the way the export does (48 kHz stereo float, every tap and volume ramp) and meters it
    /// as it is read. Nothing is kept: an 18-hour mix held whole would be about 25 GB.
    static func measure(_ project: Project) async throws -> LoudnessMeter.Result {
        try await IsolatedAudio.shared.ensureAll(project)
        do { return try await meter(project) }
        catch let e as ShortRead {
            // Never measure part of the sound as the whole. Read once more; stopping short twice is an error.
            DebugLog.event("loudness-short-read", ["got": e.got, "wanted": e.wanted])
            return try await meter(project)
        }
    }
    private static func meter(_ project: Project) async throws -> LoudnessMeter.Result {
        let m = LoudnessMeter(channels: 2, sampleRate: 48_000)
        try await stream(project) { m.feed(interleaved: $0.baseAddress!, frames: $0.count / 2) }
        return m.result
    }

    /// The project's mixed sound as interleaved stereo float at 48 kHz: whole, or its first `seconds`. This holds all of
    /// it in memory, so it is for short spans and tests; a whole long project goes through `stream`.
    static func render(_ project: Project, seconds: Double? = nil) async throws -> [Float] {
        var samples: [Float] = []
        try await stream(project, seconds: seconds) { samples.append(contentsOf: $0) }
        return samples
    }

    /// The reader finished before the end of the sound it was asked for.
    struct ShortRead: LocalizedError {
        let got: Double, wanted: Double
        var errorDescription: String? { String(format: "reading the mixed sound stopped at %.1f s of %.1f s", got, wanted) }
    }

    /// Reads the project's mixed sound (interleaved stereo float, 48 kHz) a buffer at a time, whole or its first
    /// `seconds`, and hands each buffer to `body`. Throws `ShortRead` if the sound ends early.
    static func stream(_ project: Project, seconds: Double? = nil, _ body: (UnsafeBufferPointer<Float>) throws -> Void) async throws {
        let out = try await CompositionBuilder.build(project)
        let tracks = try await out.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw EditError.invalid("nothing to measure: no clip with sound on an unmuted track") }
        var range = CMTimeRange(start: .zero, duration: out.duration)
        if let seconds, seconds < out.duration.seconds { range.duration = CMTime(seconds: seconds, preferredTimescale: 48_000) }
        // The sound runs to the end of its last track (empty edits read as silence); a reader that stops before that
        // has stopped short.
        var soundEnd = 0.0
        for t in tracks { soundEnd = max(soundEnd, try await t.load(.timeRange).end.seconds) }
        let wanted = min(range.end.seconds, soundEnd)
        let reader = try AVAssetReader(asset: out.composition)
        reader.timeRange = range
        let a = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                                                                 AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        a.audioMix = out.audioMix
        a.alwaysCopiesSampleData = false
        guard reader.canAdd(a) else { throw EditError.invalid("cannot read the mixed sound") }
        reader.add(a)
        // The composition does not keep its source assets alive; `out.sources` does, for as long as `out` lives.
        try withExtendedLifetime(out) {
            guard reader.startReading() else { throw reader.error ?? EditError.invalid("cannot read the mixed sound") }
            var frames = 0
            func next() throws -> Bool {
                // One pool per buffer: an 18-hour read is hundreds of thousands of them.
                try autoreleasepool {
                    guard let sb = a.copyNextSampleBuffer() else { return false }
                    guard var bb = CMSampleBufferGetDataBuffer(sb) else { return true }
                    var total = 0, here = 0
                    if CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: &here, totalLengthOut: &total, dataPointerOut: nil) == noErr, here < total {
                        var flat: CMBlockBuffer?   // in pieces: read it as one run
                        guard CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: bb, blockAllocator: nil, customBlockSource: nil,
                                                            offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &flat) == noErr, let flat else { return true }
                        bb = flat
                    }
                    var len = 0; var ptr: UnsafeMutablePointer<CChar>?
                    guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr,
                          len >= 8 else { return true }
                    try ptr.withMemoryRebound(to: Float.self, capacity: len / 4) { try body(UnsafeBufferPointer(start: $0, count: len / 8 * 2)) }
                    frames += len / 8
                    return true
                }
            }
            while try next() {}
            if reader.status == .failed { throw reader.error ?? EditError.invalid("reading the mixed sound failed") }
            let got = Double(frames) / 48_000
            if got < wanted - 0.1 { throw ShortRead(got: got, wanted: wanted) }
        }
    }

    // MARK: Normalizing

    struct Step: Codable { var gain: Double, integrated: Double, truePeak: Double }
    struct Plan { var gain: Double; var after: LoudnessMeter.Result; var steps: [Step]; var note: String? }

    /// Finds the gain (dB, added to `startGain`) that brings `apply(gain)`'s integrated loudness to `target` with the
    /// true peak at or under `ceiling`. The limiter that `apply` sets catches single-track peaks; when several tracks
    /// peak together the summed peak can still pass it, so the gain then comes down until the mix itself is under the
    /// ceiling (the target is then not reached, and the note says so).
    static func solve(target: Double, ceiling: Double, startGain: Double, before: LoudnessMeter.Result, gainRange: ClosedRange<Double>,
                      measure: (Double) async throws -> LoudnessMeter.Result) async throws -> Plan {
        guard before.integrated.isFinite, before.integrated > -70 else { throw EditError.invalid("the sound is silent (below −70 LUFS everywhere): nothing to normalize") }
        var gain = startGain + (target - before.integrated)
        var steps: [Step] = []
        var capped = false, peakBound = false
        var best: (gain: Double, r: LoudnessMeter.Result)? = nil
        for _ in 0..<6 {
            if gain > gainRange.upperBound { gain = gainRange.upperBound; capped = true }
            if gain < gainRange.lowerBound { gain = gainRange.lowerBound; capped = true }
            let r = try await measure(gain)
            steps.append(Step(gain: (gain * 100).rounded() / 100, integrated: (r.integrated * 100).rounded() / 100, truePeak: (r.truePeak * 100).rounded() / 100))
            let peakOK = r.truePeak <= ceiling + 0.05
            if peakOK, best == nil || abs(r.integrated - target) < abs(best!.r.integrated - target) { best = (gain, r) }
            if !peakOK {
                peakBound = true
                gain -= (r.truePeak - ceiling) + 0.1
                continue
            }
            if abs(r.integrated - target) <= 0.1 { break }
            if peakBound && r.integrated < target { break }       // louder would push the summed peak over again
            if capped && r.integrated < target { break }
            gain += target - r.integrated
        }
        guard let best else { throw EditError.invalid("could not bring the true peak under \(ceiling) dBTP") }
        var note: String? = nil
        if best.r.integrated < target - 0.3 {
            note = peakBound
                ? String(format: "Reached %.1f LUFS, not %.1f: louder, the summed peaks of the tracks pass %.1f dBTP (the limiter runs per track).", best.r.integrated, target, ceiling)
                : String(format: "Reached %.1f LUFS, not %.1f: the gain is at its %.0f dB limit or the limiter is holding the level down.", best.r.integrated, target, gainRange.upperBound)
        } else if best.r.integrated > target + 0.3 {
            note = String(format: "Reached %.1f LUFS, not %.1f.", best.r.integrated, target)
        }
        return Plan(gain: best.gain, after: best.r, steps: steps, note: note)
    }
}

// MARK: - Hum detection

enum HumDetector {
    struct Result: Codable { var frequency: Double; var prominence50: Double; var prominence60: Double; var clear: Bool }

    /// Which mains frequency hums in the sound: Goertzel power at 50, 100, 150, 200 Hz against 60, 120, 180, 240 Hz,
    /// each compared with the spectrum 3–6 Hz to either side, averaged over 1 s windows (up to 60 s of sound).
    /// The most sound `detect` looks at.
    static let seconds = 60.0

    static func detect(_ mono: [Float], sampleRate fs: Double) -> Result {
        let n = Int(fs)   // 1 Hz resolution
        let windows = min(Int(seconds), mono.count / max(1, n))
        func power(_ f: Double, _ start: Int) -> Double {
            let w = 2 * cos(2 * .pi * f / fs)
            var s1 = 0.0, s2 = 0.0
            for i in 0..<n {
                let hann = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
                let s = Double(mono[start + i]) * hann + w * s1 - s2
                s2 = s1; s1 = s
            }
            return s1 * s1 + s2 * s2 - w * s1 * s2
        }
        func prominence(_ base: Double) -> Double {
            guard windows > 0 else { return 0 }
            var total = 0.0
            for h in 1...4 {
                let f = base * Double(h)
                var on = 0.0, off = 0.0
                for k in 0..<windows {
                    let st = k * n
                    on += power(f, st)
                    off += (power(f - 4, st) + power(f + 4, st) + power(f - 6, st) + power(f + 6, st)) / 4
                }
                total += 10 * log10(max(on, 1e-20) / max(off, 1e-20))
            }
            return total / 4
        }
        let p50 = prominence(50), p60 = prominence(60)
        let f = p60 > p50 ? 60.0 : 50.0
        return Result(frequency: f, prominence50: (p50 * 10).rounded() / 10, prominence60: (p60 * 10).rounded() / 10, clear: max(p50, p60) > 6 && abs(p50 - p60) > 3)
    }
}
