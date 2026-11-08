import Foundation
import AVFoundation
import MediaToolbox
import Accelerate

/// Per-clip audio processing: a three-band EQ (low shelf, mid peak, high shelf), a high-pass filter and a noise gate,
/// then hum removal, a de-esser, a compressor, a gain, a pan and a limiter (see `DynamicsChain` for the order).
/// Gains in dB (0 = untouched), frequencies in Hz (0 = off), the gate threshold in dBFS (0 = off); nil = processor off.
struct ClipAudio: Codable, Equatable {
    var lowGain: Double = 0
    var midGain: Double = 0
    var highGain: Double = 0
    var highPass: Double = 0
    var gate: Double = 0
    /// Voice isolation amount, 0 = off … 1 = speech only. Pre-rendered per asset by `IsolatedAudio`, never run in the tap.
    var voiceIsolation: Double = 0
    /// Mains hum notches (50/60 Hz and harmonics), run with the EQ.
    var hum: HumSettings? = nil
    var deEsser: DeEsserSettings? = nil
    var compressor: CompressorSettings? = nil
    /// Clip gain in dB after the compressor, before the limiter (what normalize_loudness sets for one clip).
    var gain: Double = 0
    /// Stereo balance −1 … 1 (stereo sources only: a mono file reaches the tap as one channel).
    var pan: Double = 0
    var limiter: LimiterSettings? = nil
    /// Nothing for the tap to process. Isolation does not count: it is rendered ahead of time.
    var isIdentity: Bool { !hasCleanup && !hasDynamics }
    /// EQ, high-pass or gate set (the processors the tap has always run).
    var hasCleanup: Bool { lowGain != 0 || midGain != 0 || highGain != 0 || highPass != 0 || gate != 0 }
    /// Hum removal, de-esser, compressor, gain, pan or limiter set.
    var hasDynamics: Bool { hum != nil || deEsser != nil || compressor != nil || gain != 0 || pan != 0 || limiter != nil }
    /// Every setting at its default, isolation included.
    var isDefault: Bool { self == ClipAudio() }
    var needsIsolation: Bool { voiceIsolation > 0.001 }
    static let identity = ClipAudio()
    static let gainRange = -24.0...24, panRange = -1.0...1
    /// Back to no EQ, high-pass, gate or isolation; the rest (hum, de-esser, dynamics, gain, pan) stays.
    mutating func clearCleanup() { lowGain = 0; midGain = 0; highGain = 0; highPass = 0; gate = 0; voiceIsolation = 0 }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lowGain = try c.decodeIfPresent(Double.self, forKey: .lowGain) ?? 0
        midGain = try c.decodeIfPresent(Double.self, forKey: .midGain) ?? 0
        highGain = try c.decodeIfPresent(Double.self, forKey: .highGain) ?? 0
        highPass = try c.decodeIfPresent(Double.self, forKey: .highPass) ?? 0
        gate = try c.decodeIfPresent(Double.self, forKey: .gate) ?? 0
        voiceIsolation = try c.decodeIfPresent(Double.self, forKey: .voiceIsolation) ?? 0
        hum = try c.decodeIfPresent(HumSettings.self, forKey: .hum)
        deEsser = try c.decodeIfPresent(DeEsserSettings.self, forKey: .deEsser)
        compressor = try c.decodeIfPresent(CompressorSettings.self, forKey: .compressor)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        limiter = try c.decodeIfPresent(LimiterSettings.self, forKey: .limiter)
    }
}

/// One second-order section (RBJ cookbook), direct form I, with its own state.
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    static func lowShelf(_ fs: Double, f: Double, gainDB: Double) -> Biquad { shelf(fs, f: f, gainDB: gainDB, low: true) }
    static func highShelf(_ fs: Double, f: Double, gainDB: Double) -> Biquad { shelf(fs, f: f, gainDB: gainDB, low: false) }
    private static func shelf(_ fs: Double, f: Double, gainDB: Double, low: Bool) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f / fs, cw = cos(w), sw = sin(w)
        let alpha = sw / 2 * sqrt((A + 1 / A) * (1 / 0.9 - 1) + 2), s = 2 * sqrt(A) * alpha
        var q = Biquad()
        let a0: Double
        if low {
            q.b0 = A * ((A + 1) - (A - 1) * cw + s); q.b1 = 2 * A * ((A - 1) - (A + 1) * cw); q.b2 = A * ((A + 1) - (A - 1) * cw - s)
            a0 = (A + 1) + (A - 1) * cw + s; q.a1 = -2 * ((A - 1) + (A + 1) * cw); q.a2 = (A + 1) + (A - 1) * cw - s
        } else {
            q.b0 = A * ((A + 1) + (A - 1) * cw + s); q.b1 = -2 * A * ((A - 1) + (A + 1) * cw); q.b2 = A * ((A + 1) + (A - 1) * cw - s)
            a0 = (A + 1) - (A - 1) * cw + s; q.a1 = 2 * ((A - 1) - (A + 1) * cw); q.a2 = (A + 1) - (A - 1) * cw - s
        }
        q.b0 /= a0; q.b1 /= a0; q.b2 /= a0; q.a1 /= a0; q.a2 /= a0
        return q
    }
    static func peak(_ fs: Double, f: Double, gainDB: Double, Q: Double = 1) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f / fs, cw = cos(w), alpha = sin(w) / (2 * Q)
        var q = Biquad()
        let a0 = 1 + alpha / A
        q.b0 = (1 + alpha * A) / a0; q.b1 = -2 * cw / a0; q.b2 = (1 - alpha * A) / a0
        q.a1 = -2 * cw / a0; q.a2 = (1 - alpha / A) / a0
        return q
    }
    static func highPass(_ fs: Double, f: Double, Q: Double = 0.707) -> Biquad {
        let w = 2 * .pi * f / fs, cw = cos(w), alpha = sin(w) / (2 * Q)
        var q = Biquad()
        let a0 = 1 + alpha
        q.b0 = (1 + cw) / 2 / a0; q.b1 = -(1 + cw) / a0; q.b2 = (1 + cw) / 2 / a0
        q.a1 = -2 * cw / a0; q.a2 = (1 - alpha) / a0
        return q
    }
    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// The state behind one audio tap: which clip's settings apply when, the filters per channel, and the dynamics strip.
/// Everything the audio thread touches is allocated in `prepare` (the tap's prepare callback); `run` never allocates,
/// locks or grows an array.
final class AudioTapContext {
    struct Span {
        let start: Double, end: Double, audio: ClipAudio
        /// The clip's volume envelope as (timeline seconds, volume) breakpoints. AVFoundation applies it after the tap,
        /// so the limiters scale what they detect by it to hold their ceiling for what is heard. Empty = 1.
        var envelope: [(Double, Double)] = []
    }
    let spans: [Span]
    let strip: TrackStrip
    let meter: MeterSlot?
    private let starts: [Double], ends: [Double], audios: [ClipAudio]
    private let envOffset: [Int], envCount: [Int]
    private let envTimes: UnsafeMutablePointer<Double>, envValues: UnsafeMutablePointer<Double>
    private(set) var sampleRate = 48000.0
    private(set) var channels = 2
    private(set) var current: ClipAudio? = nil
    private var currentSpan = -2
    private var filters: UnsafeMutablePointer<Biquad>? = nil    // per channel: [low, mid, high, highPass]
    private var frame: UnsafeMutablePointer<Double>? = nil
    private var hum: HumFilter? = nil
    private var chain: DynamicsChain? = nil
    private var latency = 0.0
    private var nextTime = -1.0
    var gateEnv = 0.0, gateGain = 1.0

    init(spans: [Span], strip: TrackStrip = TrackStrip(), meter: MeterSlot? = nil) {
        self.spans = spans; self.strip = strip; self.meter = meter
        starts = spans.map(\.start); ends = spans.map(\.end); audios = spans.map(\.audio)
        var offs: [Int] = [], counts: [Int] = [], total = 0
        for s in spans { offs.append(total); counts.append(s.envelope.count); total += s.envelope.count }
        envOffset = offs; envCount = counts
        envTimes = .allocate(capacity: max(1, total)); envValues = .allocate(capacity: max(1, total))
        var k = 0
        for s in spans { for (t, v) in s.envelope { envTimes[k] = t; envValues[k] = v; k += 1 } }
    }
    deinit {
        envTimes.deallocate(); envValues.deallocate()
        filters?.deallocate(); frame?.deallocate()
    }

    func settings(at t: Double) -> ClipAudio? { let i = spanIndex(at: t); return i >= 0 ? audios[i] : nil }
    private func spanIndex(at t: Double) -> Int {
        for i in 0..<starts.count where starts[i] - 0.001 <= t && t < ends[i] + 0.001 { return i }
        return -1
    }
    /// The span's volume envelope at `t` (1 outside any span or without breakpoints).
    private func envelope(_ span: Int, at t: Double) -> Double {
        guard span >= 0, envCount[span] > 0 else { return 1 }
        let o = envOffset[span], n = envCount[span]
        if t <= envTimes[o] { return envValues[o] }
        var k = 1
        while k < n {
            if t <= envTimes[o + k] {
                let t0 = envTimes[o + k - 1], t1 = envTimes[o + k]
                return t1 > t0 ? envValues[o + k - 1] + (envValues[o + k] - envValues[o + k - 1]) * (t - t0) / (t1 - t0) : envValues[o + k]
            }
            k += 1
        }
        return envValues[o + n - 1]
    }

    /// Allocates the filters and the dynamics chain for the format the tap will see (the source track's own: a mono
    /// file is one channel, at its own sample rate).
    func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate; self.channels = max(1, channels)
        filters?.deallocate(); frame?.deallocate()
        let f = UnsafeMutablePointer<Biquad>.allocate(capacity: self.channels * 4); f.initialize(repeating: Biquad(), count: self.channels * 4)
        let fr = UnsafeMutablePointer<Double>.allocate(capacity: self.channels); fr.initialize(repeating: 0, count: self.channels)
        filters = f; frame = fr
        hum = HumFilter(channels: self.channels)
        chain = DynamicsChain(channels: self.channels, sampleRate: sampleRate, strip: strip)
        latency = strip.latencyMs(fs: sampleRate) / 1000
        current = nil; currentSpan = -2; nextTime = -1; gateEnv = 0; gateGain = 1
    }

    func configure(_ a: ClipAudio) {
        current = a
        guard let filters else { return }
        for ch in 0..<channels {
            filters[ch * 4 + 0] = Biquad.lowShelf(sampleRate, f: 200, gainDB: a.lowGain)
            filters[ch * 4 + 1] = Biquad.peak(sampleRate, f: 1000, gainDB: a.midGain)
            filters[ch * 4 + 2] = Biquad.highShelf(sampleRate, f: 6000, gainDB: a.highGain)
            filters[ch * 4 + 3] = a.highPass > 0 ? Biquad.highPass(sampleRate, f: min(a.highPass, sampleRate * 0.45)) : Biquad()
        }
        hum?.configure(a.hum, fs: sampleRate)
        chain?.configure(a)
    }

    /// One buffer of float samples (interleaved or planar) starting at timeline second `time`.
    func run(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, interleaved: Bool, time t: Double) {
        guard let filters, let frame, let hum, let chain, frames > 0 else { return }
        // A jump in time (a seek, a loop): no envelope, delay line or filter state carries across it.
        if nextTime >= 0, abs(t - nextTime) > 0.02 {
            if TapStats.enabled { TapStats.shared.jumped(from: nextTime, to: t) }
            chain.reset(); hum.reset(); gateEnv = 0; gateGain = 1
            for i in 0..<(channels * 4) { filters[i].x1 = 0; filters[i].x2 = 0; filters[i].y1 = 0; filters[i].y2 = 0 }
        }
        nextTime = t + Double(frames) / sampleRate
        let idx = spanIndex(at: t)
        let a = idx >= 0 ? audios[idx] : ClipAudio.identity
        if idx != currentSpan || current != a { configure(a); currentSpan = idx }
        let cleanup = a.hasCleanup, humOn = hum.isActive, dyn = !chain.isIdle(for: a)
        guard cleanup || humOn || dyn || meter != nil else { return }
        let runLow = a.lowGain != 0, runMid = a.midGain != 0, runHigh = a.highGain != 0, runHP = a.highPass > 0
        let gateOn = a.gate < 0
        let thr = pow(10, a.gate / 20)
        let attack = exp(-1 / (0.005 * sampleRate)), release = exp(-1 / (0.08 * sampleRate))
        let gainAttack = exp(-1 / (0.003 * sampleRate)), gainRelease = exp(-1 / (0.05 * sampleRate))
        let post0 = envelope(idx, at: t + latency), post1 = envelope(idx, at: nextTime + latency)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let C = channels
        let nb = buffers.count
        var bufferPeak = 0.0
        for n in 0..<frames {
            // Gather one frame.
            for ch in 0..<C {
                if interleaved { frame[ch] = buffers[0].mData.map { Double($0.assumingMemoryBound(to: Float.self)[n * C + ch]) } ?? 0 }
                else { frame[ch] = ch < nb ? (buffers[ch].mData.map { Double($0.assumingMemoryBound(to: Float.self)[n]) } ?? 0) : 0 }
            }
            if cleanup || humOn {
                var peak = 0.0
                for ch in 0..<C {
                    var x = frame[ch]
                    if runHP { x = filters[ch * 4 + 3].process(x) }
                    if humOn { x = hum.process(x, channel: ch) }
                    if runLow { x = filters[ch * 4 + 0].process(x) }
                    if runMid { x = filters[ch * 4 + 1].process(x) }
                    if runHigh { x = filters[ch * 4 + 2].process(x) }
                    peak = max(peak, abs(x))
                    frame[ch] = x
                }
                if gateOn {
                    gateEnv = peak > gateEnv ? attack * gateEnv + (1 - attack) * peak : release * gateEnv + (1 - release) * peak
                    let target = gateEnv >= thr ? 1.0 : 0.05   // closed gate = −26 dB, not silence, so it never pumps hard
                    gateGain = target > gateGain ? gainAttack * gateGain + (1 - gainAttack) * target : gainRelease * gateGain + (1 - gainRelease) * target
                    for ch in 0..<C { frame[ch] *= gateGain }
                }
            }
            let post = post0 + (post1 - post0) * Double(n) / Double(frames)
            if dyn { chain.process(frame, post: post) }
            // Scatter it back.
            for ch in 0..<C {
                let v = frame[ch]
                bufferPeak = max(bufferPeak, abs(v) * post)
                if interleaved { buffers[0].mData?.assumingMemoryBound(to: Float.self)[n * C + ch] = Float(v) }
                else if ch < nb { buffers[ch].mData?.assumingMemoryBound(to: Float.self)[n] = Float(v) }
            }
        }
        if let meter {
            let r = chain.reductions
            meter.post(peak: Float(bufferPeak), reduction: Float(max(r.compressor, r.deEsser, r.busCompressor)))
        }
    }
}

/// What the taps saw while `enabled` (a test turns it on to say why two reads of the same mix differ): prepares, time
/// jumps that reset the dynamics, and source reads that came back short or failed.
final class TapStats: @unchecked Sendable {
    nonisolated(unsafe) static var enabled = false
    static let shared = TapStats()
    private let lock = NSLock()
    private var prepares = 0, callbacks = 0, short = 0, failed = 0, nonFinite = 0, frames = 0
    private var minFrames = Int.max, maxFrames = 0, firstT = Double.nan, lastEnd = Double.nan
    private var jumps: [String] = [], jumpCount = 0

    func reset() {
        lock.lock(); defer { lock.unlock() }
        prepares = 0; callbacks = 0; short = 0; failed = 0; nonFinite = 0; frames = 0
        minFrames = .max; maxFrames = 0; firstT = .nan; lastEnd = .nan; jumps = []; jumpCount = 0
    }
    func prepared() { lock.lock(); prepares += 1; lock.unlock() }
    func read(asked: Int, got: Int, status: OSStatus, time t: Double, sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        callbacks += 1
        guard status == noErr else { failed += 1; return }
        if got < asked { short += 1 }
        if !t.isFinite { nonFinite += 1 } else { if firstT.isNaN { firstT = t }; lastEnd = t + Double(got) / sampleRate }
        frames += got; minFrames = min(minFrames, got); maxFrames = max(maxFrames, got)
    }
    func jumped(from expected: Double, to t: Double) {
        lock.lock(); defer { lock.unlock() }
        jumpCount += 1
        if jumps.count < 6 { jumps.append(String(format: "%.4f→%.4f", expected, t)) }
    }
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return "taps: \(prepares) prepares, \(callbacks) reads (\(failed) failed, \(short) short, \(nonFinite) without a time), "
            + "\(frames) frames in \(minFrames == .max ? 0 : minFrames)–\(maxFrames) a read, "
            + String(format: "%.4f–%.4f s, ", firstT, lastEnd) + "\(jumpCount) time jumps \(jumps)"
    }
}

enum AudioTap {
    /// A tap for one composition audio track, running the clip settings of whatever clip is playing at each buffer's
    /// time, then the track's strip (fader, bus, master).
    static func make(spans: [AudioTapContext.Span], strip: TrackStrip = TrackStrip(), meter: MeterSlot? = nil) -> MTAudioProcessingTap? {
        let ctx = AudioTapContext(spans: spans, strip: strip, meter: meter)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(ctx).toOpaque(),
            init: { tap, clientInfo, tapStorageOut in tapStorageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, maxFrames, format in
                let c = Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                c.prepare(sampleRate: format.pointee.mSampleRate, channels: Int(format.pointee.mChannelsPerFrame))
                if TapStats.enabled { TapStats.shared.prepared() }
            },
            unprepare: { _ in },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                var range = CMTimeRange.zero
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &range, numberFramesOut)
                let c = Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let t = range.start.seconds
                if TapStats.enabled { TapStats.shared.read(asked: Int(numberFrames), got: Int(numberFramesOut.pointee), status: status, time: t, sampleRate: c.sampleRate) }
                guard status == noErr else { return }
                let interleaved = UnsafeMutableAudioBufferListPointer(bufferListInOut).count == 1 && c.channels > 1
                c.run(bufferListInOut, frames: Int(numberFramesOut.pointee), interleaved: interleaved, time: t.isFinite ? t : 0)
            })
        var tap: MTAudioProcessingTap?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard err == noErr, let tap else { Unmanaged.passUnretained(ctx).release(); return nil }
        return tap
    }
}

/// Automatic ducking: a track drops to `level` while clips play on `sourceTrackID`, with attack and release ramps.
struct Ducking: Codable, Equatable {
    var sourceTrackID: UUID
    var level: Double = 0.25
    var attack: Double = 0.15
    var release: Double = 0.4
}

/// The duck factor over the timeline as (time, factor) breakpoints, piecewise linear.
struct DuckCurve {
    let points: [(Double, Double)]
    init(intervals: [(Double, Double)], duck: Ducking) {
        var pts: [(Double, Double)] = []
        for (a, b) in intervals.sorted(by: { $0.0 < $1.0 }) {
            pts.append((a - max(0.01, duck.attack), 1)); pts.append((a, duck.level)); pts.append((b, duck.level)); pts.append((b + max(0.01, duck.release), 1))
        }
        points = pts
    }
    func factor(at t: Double) -> Double {
        var f = 1.0
        // Intervals can overlap: take the lowest factor of every ramp that covers t.
        var i = 0
        while i + 3 < points.count {
            let seg = Array(points[i..<i + 4])
            if t > seg[0].0 && t < seg[3].0 {
                for (p, q) in zip(seg, seg.dropFirst()) where t >= p.0 && t <= q.0 {
                    let u = q.0 > p.0 ? (t - p.0) / (q.0 - p.0) : 1
                    f = min(f, p.1 + (q.1 - p.1) * u)
                }
            }
            i += 4
        }
        return f
    }
    var times: [Double] { points.map(\.0) }
}
