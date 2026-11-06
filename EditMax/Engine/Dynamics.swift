import Foundation
import AVFoundation

// MARK: - Settings (stored on clips, buses and the master; every field decodes with a default)

/// A feed-forward compressor: gain reduction above `threshold` (dBFS) by `ratio`, with a soft knee (dB wide),
/// attack and release in milliseconds and makeup gain in dB. Detection is stereo-linked (the louder channel).
struct CompressorSettings: Codable, Equatable {
    var threshold: Double = -18
    var ratio: Double = 3
    var attack: Double = 10
    var release: Double = 150
    var knee: Double = 6
    var makeup: Double = 0

    static let thresholdRange = -60.0...0, ratioRange = 1.0...20, attackRange = 0.1...200, releaseRange = 10.0...2000, kneeRange = 0.0...24, makeupRange = -12.0...24

    init(threshold: Double = -18, ratio: Double = 3, attack: Double = 10, release: Double = 150, knee: Double = 6, makeup: Double = 0) {
        self.threshold = threshold; self.ratio = ratio; self.attack = attack; self.release = release; self.knee = knee; self.makeup = makeup
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? -18
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 3
        attack = try c.decodeIfPresent(Double.self, forKey: .attack) ?? 10
        release = try c.decodeIfPresent(Double.self, forKey: .release) ?? 150
        knee = try c.decodeIfPresent(Double.self, forKey: .knee) ?? 6
        makeup = try c.decodeIfPresent(Double.self, forKey: .makeup) ?? 0
    }
}

/// A true-peak look-ahead limiter: nothing passes above `ceiling` (dBTP, measured on a 4× oversampled signal),
/// gain comes back over `release` ms, and `lookahead` ms of delay lets the gain ramp down before a peak arrives.
struct LimiterSettings: Codable, Equatable {
    var ceiling: Double = -1
    var release: Double = 100
    var lookahead: Double = 1.5

    static let ceilingRange = -24.0...0, releaseRange = 1.0...1000, lookaheadRange = 0.0...5

    init(ceiling: Double = -1, release: Double = 100, lookahead: Double = 1.5) { self.ceiling = ceiling; self.release = release; self.lookahead = lookahead }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ceiling = try c.decodeIfPresent(Double.self, forKey: .ceiling) ?? -1
        release = try c.decodeIfPresent(Double.self, forKey: .release) ?? 100
        lookahead = try c.decodeIfPresent(Double.self, forKey: .lookahead) ?? 1.5
    }
}

/// Split-band de-esser: above `frequency` (Hz) the band is turned down while it dominates the voice (an "s", "sh").
/// `amount` 0…1 sets how hard (up to 18 dB of reduction).
struct DeEsserSettings: Codable, Equatable {
    var amount: Double = 0.5
    var frequency: Double = 6000
    static let amountRange = 0.0...1, frequencyRange = 3000.0...12000
    init(amount: Double = 0.5, frequency: Double = 6000) { self.amount = amount; self.frequency = frequency }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0.5
        frequency = try c.decodeIfPresent(Double.self, forKey: .frequency) ?? 6000
    }
}

/// Mains hum removal: narrow notches at `frequency` (50 or 60 Hz, picked from the spectrum by the tool) and its
/// first `harmonics` multiples; `amount` 1 = full notch, 0.5 = −6 dB at each centre.
struct HumSettings: Codable, Equatable {
    var amount: Double = 1
    var frequency: Double = 60
    var harmonics: Int = 4
    static let amountRange = 0.0...1, harmonicsRange = 1...8
    init(amount: Double = 1, frequency: Double = 60, harmonics: Int = 4) { self.amount = amount; self.frequency = frequency; self.harmonics = harmonics }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 1
        frequency = try c.decodeIfPresent(Double.self, forKey: .frequency) ?? 60
        harmonics = try c.decodeIfPresent(Int.self, forKey: .harmonics) ?? 4
    }
}

// MARK: - Small helpers

enum DSP {
    @inline(__always) static func dbToGain(_ db: Double) -> Double { pow(10, db / 20) }
    @inline(__always) static func gainToDb(_ g: Double) -> Double { 20 * log10(max(g, 1e-12)) }
    /// One-pole coefficient for a time constant in milliseconds.
    @inline(__always) static func coefficient(ms: Double, fs: Double) -> Double { ms <= 0 ? 0 : exp(-1 / (ms / 1000 * fs)) }

    /// Stereo balance: 0 = untouched, −1 = left only, +1 = right only. The far side fades on a sine/cosine law,
    /// the near side stays at unity, so a centred clip plays exactly as before.
    @inline(__always) static func balance(_ pan: Double) -> (left: Double, right: Double) {
        let p = max(-1, min(1, pan)), a = (p + 1) * .pi / 4
        return (min(1, 2.0.squareRoot() * cos(a)), min(1, 2.0.squareRoot() * sin(a)))
    }
}

extension Biquad {
    /// Band-pass with a constant 0 dB peak (RBJ); x − amount·bp(x) is a notch of depth (1 − amount) at `f`.
    static func bandPass(_ fs: Double, f: Double, Q: Double) -> Biquad {
        let w = 2 * .pi * f / fs, alpha = sin(w) / (2 * Q), a0 = 1 + alpha
        var q = Biquad()
        q.b0 = alpha / a0; q.b1 = 0; q.b2 = -alpha / a0; q.a1 = -2 * cos(w) / a0; q.a2 = (1 - alpha) / a0
        return q
    }
    static func lowPass(_ fs: Double, f: Double, Q: Double = 0.7071067811865476) -> Biquad {
        let w = 2 * .pi * f / fs, cw = cos(w), alpha = sin(w) / (2 * Q), a0 = 1 + alpha
        var q = Biquad()
        q.b0 = (1 - cw) / 2 / a0; q.b1 = (1 - cw) / a0; q.b2 = (1 - cw) / 2 / a0; q.a1 = -2 * cw / a0; q.a2 = (1 - alpha) / a0
        return q
    }
    /// Same coefficients, state cleared.
    var cleared: Biquad { var q = self; q.x1 = 0; q.x2 = 0; q.y1 = 0; q.y2 = 0; return q }
    /// New coefficients, the running state kept (no click when a setting changes).
    mutating func setCoefficients(_ o: Biquad) { b0 = o.b0; b1 = o.b1; b2 = o.b2; a1 = o.a1; a2 = o.a2 }
}

// MARK: - True peak (ITU-R BS.1770-4 Annex 2: 4× oversampling)

/// A 4-phase windowed-sinc interpolator. Phase 0 is the sample itself (delayed by `delay`); phases 1–3 estimate the
/// signal between that sample and the next. Used by the meter and by the limiter's detector.
enum TruePeak {
    static let taps = 16, phases = 4, delay = 8
    /// coefficients[phase * taps + t] multiplies x[n − t].
    /// Kaiser-windowed sinc (β 4): flat within 0.1 dB to 20 kHz at 48 kHz, so peaks made of high harmonics, noise or
    /// a limiter's own gain changes are not missed. (A Blackman window of the same length was 1.1 dB down at 20 kHz
    /// and read limited voice up to 1 dB low against a 16× reference.)
    static let coefficients: [Double] = {
        var h = [Double](repeating: 0, count: phases * taps)
        let halfWidth = Double(taps) / 2 + 0.5
        let beta = 4.0
        func i0(_ x: Double) -> Double {
            var s = 1.0, term = 1.0, k = 1.0
            while term > 1e-14 * s { term *= (x / (2 * k)) * (x / (2 * k)); s += term; k += 1 }
            return s
        }
        for k in 0..<phases {
            let f = Double(k) / Double(phases)
            var sum = 0.0
            for t in 0..<taps {
                let x = Double(delay) - f - Double(t)
                let sinc = abs(x) < 1e-12 ? 1 : sin(.pi * x) / (.pi * x)
                let r = x / halfWidth
                let w = abs(r) >= 1 ? 0 : i0(beta * (1 - r * r).squareRoot()) / i0(beta)
                h[k * taps + t] = sinc * w
                sum += sinc * w
            }
            for t in 0..<taps { h[k * taps + t] /= sum }
        }
        return h
    }()
}

/// Per-channel history for the true-peak estimate. Preallocated; `push` returns the largest |value| among the four phases.
final class TruePeakDetector {
    private let channels: Int
    private let history: UnsafeMutablePointer<Double>   // channels × taps, ring per channel
    private var pos = 0
    private let h: UnsafeMutablePointer<Double>

    init(channels: Int) {
        self.channels = max(1, channels)
        history = .allocate(capacity: self.channels * TruePeak.taps); history.initialize(repeating: 0, count: self.channels * TruePeak.taps)
        h = .allocate(capacity: TruePeak.coefficients.count)
        for (i, v) in TruePeak.coefficients.enumerated() { h[i] = v }
    }
    deinit { history.deallocate(); h.deallocate() }

    func reset() { history.update(repeating: 0, count: channels * TruePeak.taps); pos = 0 }

    /// Feeds one frame; returns the true-peak estimate around the sample `delay` frames back (max over channels).
    @inline(__always) func push(_ frame: UnsafePointer<Double>) -> Double {
        let T = TruePeak.taps
        pos = (pos + 1) % T
        var peak = 0.0
        for ch in 0..<channels {
            let base = history + ch * T
            base[pos] = frame[ch]
            for k in 0..<TruePeak.phases {
                var acc = 0.0
                let hk = h + k * T
                var idx = pos
                for t in 0..<T { acc += hk[t] * base[idx]; idx = idx == 0 ? T - 1 : idx - 1 }
                peak = max(peak, abs(acc))
            }
        }
        return peak
    }
}

// MARK: - Compressor

struct CompressorDSP {
    private var threshold = 0.0, ratio = 1.0, knee = 0.0, makeup = 0.0, aA = 0.0, aR = 0.0
    private var y1 = 0.0, yl = 0.0
    /// The gain reduction of the last sample, in dB (≥ 0).
    private(set) var reduction = 0.0

    mutating func configure(_ s: CompressorSettings, fs: Double) {
        threshold = s.threshold; ratio = max(1, s.ratio); knee = max(0, s.knee); makeup = s.makeup
        aA = DSP.coefficient(ms: s.attack, fs: fs); aR = DSP.coefficient(ms: s.release, fs: fs)
    }
    mutating func reset() { y1 = 0; yl = 0; reduction = 0 }

    /// Static curve: output level in dB for an input level in dB (soft knee, Giannoulis et al. 2012).
    static func curve(_ x: Double, threshold: Double, ratio: Double, knee: Double) -> Double {
        let over = x - threshold
        if 2 * over < -knee { return x }
        if knee > 0, 2 * abs(over) <= knee { return x + (1 / ratio - 1) * (over + knee / 2) * (over + knee / 2) / (2 * knee) }
        return threshold + over / ratio
    }

    /// The linear gain for a detector level (linear peak of this frame), smoothed in the dB domain
    /// (smooth decoupled peak detector: release on the raw reduction, attack on top of it).
    @inline(__always) mutating func gain(level: Double) -> Double {
        let xg = 20 * log10(max(level, 1e-9))
        let xl = xg - Self.curve(xg, threshold: threshold, ratio: ratio, knee: knee)
        y1 = max(xl, aR * y1 + (1 - aR) * xl)
        yl = aA * yl + (1 - aA) * y1
        reduction = yl
        return pow(10, (makeup - yl) / 20)
    }
}

// MARK: - Limiter

/// True-peak look-ahead limiter on an interleaved frame (all channels share one gain).
/// Structure: a requirement g = ceiling / truePeak per frame → minimum over a window of L+1 frames → release smoothing
/// (gain may only rise slowly) → moving average over L frames. With the audio delayed by L + `TruePeak.delay`
/// frames, the averaged gain is at or below the requirement of every sample (and the inter-sample peaks after it) it multiplies.
final class LimiterDSP {
    let channels: Int
    let maxLookahead: Int
    private(set) var lookahead = 0      // L, frames
    private var ceiling = 1.0, release = 0.0
    private let detector: TruePeakDetector
    // Audio delay line: (maxLookahead + delay) frames per channel.
    private let delayCap: Int
    private let delayLine: UnsafeMutablePointer<Double>
    private var delayPos = 0
    // Sliding minimum (monotonic deque of (index, value)).
    private let dqIndex: UnsafeMutablePointer<Int>, dqValue: UnsafeMutablePointer<Double>
    private let dqCap: Int
    private var dqHead = 0, dqCount = 0
    // Moving average of the smoothed gain.
    private let box: UnsafeMutablePointer<Double>
    private var boxPos = 0, boxSum = 0.0, sinceResum = 0
    private var smoothed = 1.0
    private var n = 0
    /// Lowest gain applied since the last `takeMinGain()`, for meters and tests.
    private(set) var minGain = 1.0

    init(channels: Int, sampleRate: Double, maxLookaheadMs: Double = LimiterSettings.lookaheadRange.upperBound) {
        self.channels = max(1, channels)
        maxLookahead = max(1, Int((maxLookaheadMs / 1000 * sampleRate).rounded(.up)) + 1)
        detector = TruePeakDetector(channels: self.channels)
        delayCap = maxLookahead + TruePeak.delay + 1
        delayLine = .allocate(capacity: delayCap * self.channels); delayLine.initialize(repeating: 0, count: delayCap * self.channels)
        dqCap = maxLookahead + 3
        dqIndex = .allocate(capacity: dqCap); dqIndex.initialize(repeating: 0, count: dqCap)
        dqValue = .allocate(capacity: dqCap); dqValue.initialize(repeating: 1, count: dqCap)
        box = .allocate(capacity: maxLookahead); box.initialize(repeating: 1, count: maxLookahead)
    }
    deinit { delayLine.deallocate(); dqIndex.deallocate(); dqValue.deallocate(); box.deallocate() }

    /// Frames of delay this limiter adds.
    var latency: Int { lookahead + TruePeak.delay }

    /// `lookaheadFrames` fixes the delay (the same for every clip on a track); the settings give ceiling and release.
    func configure(ceilingDB: Double, releaseMs: Double, lookaheadFrames: Int, fs: Double) {
        ceiling = DSP.dbToGain(ceilingDB)
        release = DSP.coefficient(ms: releaseMs, fs: fs)
        let L = max(1, min(maxLookahead, lookaheadFrames))
        if L != lookahead { lookahead = L; reset() }
    }
    /// A stage that only delays (a clip without a limiter on a track whose other clips have one).
    func configureBypass(lookaheadFrames: Int, fs: Double) { configure(ceilingDB: 200, releaseMs: 1, lookaheadFrames: lookaheadFrames, fs: fs) }

    func reset() {
        detector.reset()
        delayLine.update(repeating: 0, count: delayCap * channels); delayPos = 0
        dqHead = 0; dqCount = 0
        box.update(repeating: 1, count: maxLookahead); boxPos = 0; boxSum = Double(lookahead); sinceResum = 0
        smoothed = 1; n = 0
    }
    func takeMinGain() -> Double { let m = minGain; minGain = 1; return m }

    /// Processes one frame in place: the frame comes out `latency` frames later, limited.
    /// `post` is the gain applied after this stage (the clip's volume envelope), so the ceiling holds for what is heard.
    @inline(__always) func process(_ frame: UnsafeMutablePointer<Double>, post: Double = 1) {
        let L = lookahead
        // 1. Requirement from the true peak around the sample `TruePeak.delay` back.
        let peak = detector.push(UnsafePointer(frame)) * max(0, post)
        let req = peak > ceiling ? ceiling / peak : 1.0
        // 2. Sliding minimum over [n − L, n].
        while dqCount > 0 {
            let back = (dqHead + dqCount - 1) % dqCap
            if dqValue[back] >= req { dqCount -= 1 } else { break }
        }
        let slot = (dqHead + dqCount) % dqCap
        dqIndex[slot] = n; dqValue[slot] = req; dqCount += 1
        while dqCount > 0, dqIndex[dqHead] < n - L { dqHead = (dqHead + 1) % dqCap; dqCount -= 1 }
        let hold = dqValue[dqHead]
        // 3. Release: falls at once, rises slowly.
        smoothed = hold < smoothed ? hold : release * smoothed + (1 - release) * hold
        // 4. Moving average over L frames.
        boxSum += smoothed - box[boxPos]; box[boxPos] = smoothed; boxPos = (boxPos + 1) % L
        sinceResum += 1
        if sinceResum >= 8192 { sinceResum = 0; boxSum = 0; for i in 0..<L { boxSum += box[i] } }
        let g = min(1, boxSum / Double(L))
        if g < minGain { minGain = g }
        // 5. Delay the audio by latency frames and apply the gain.
        let D = latency
        let writeBase = delayLine + delayPos * channels
        let readPos = (delayPos - D + delayCap * 2) % delayCap
        let readBase = delayLine + readPos * channels
        for ch in 0..<channels { writeBase[ch] = frame[ch] }
        for ch in 0..<channels { frame[ch] = readBase[ch] * g }
        delayPos = (delayPos + 1) % delayCap
        n += 1
    }
}

// MARK: - De-esser

struct DeEsserDSP {
    private var maxReduction = 0.0, slope = 0.0
    private var aFast = 0.0, rFast = 0.0, aGain = 0.0, rGain = 0.0
    private var envS = 0.0, envW = 0.0, gr = 0.0
    private(set) var reduction = 0.0
    static let threshold = -15.0   // dB of the band relative to the whole voice

    mutating func configure(_ s: DeEsserSettings, fs: Double) {
        let a = max(0, min(1, s.amount))
        maxReduction = 18 * a
        let ratio = 1 + 5 * a
        slope = 1 - 1 / ratio
        aFast = DSP.coefficient(ms: 0.5, fs: fs); rFast = DSP.coefficient(ms: 40, fs: fs)
        aGain = DSP.coefficient(ms: 1, fs: fs); rGain = DSP.coefficient(ms: 60, fs: fs)
    }
    mutating func reset() { envS = 0; envW = 0; gr = 0; reduction = 0 }

    /// `band`: linked peak of the high band, `whole`: linked peak of the full signal. Returns the gain for the high band.
    @inline(__always) mutating func bandGain(band: Double, whole: Double) -> Double {
        envS = band > envS ? aFast * envS + (1 - aFast) * band : rFast * envS + (1 - rFast) * band
        envW = whole > envW ? aFast * envW + (1 - aFast) * whole : rFast * envW + (1 - rFast) * whole
        var target = 0.0
        if envW > 0.001 {   // −60 dBFS: below that there is nothing to de-ess
            let rel = 20 * log10(max(envS, 1e-9) / envW)
            let excess = rel - Self.threshold
            if excess > 0 { target = min(maxReduction, excess * slope) }
        }
        gr = target > gr ? aGain * gr + (1 - aGain) * target : rGain * gr + (1 - rGain) * target
        reduction = gr
        return pow(10, -gr / 20)
    }
}

// MARK: - The per-track strip run inside each audio tap

/// What a track adds after its clips' own processing: track gain and pan, the bus it is routed to (gain, compressor,
/// limiter, all run on this track alone), and the master gain and limiter (also per track: AVFoundation offers no
/// stage after the tracks are summed). `clipLimiterLookahead` is set when any clip on the track has a limiter, so
/// every clip on it runs through a limiter stage of the same delay and the track never shifts in time between clips.
struct TrackStrip: Equatable {
    var gain = 1.0
    var pan = 0.0
    var busGain = 1.0
    var busCompressor: CompressorSettings? = nil
    var busLimiter: LimiterSettings? = nil
    var masterGain = 1.0
    var masterLimiter: LimiterSettings? = nil
    var clipLimiterLookahead: Double? = nil    // ms

    var isIdentity: Bool { self == TrackStrip() }
    /// Total delay the strip and the clip limiters add, in ms (look-ahead plus the true-peak filter's 8 frames).
    func latencyMs(fs: Double) -> Double {
        let extra = Double(TruePeak.delay) / fs * 1000
        return [clipLimiterLookahead, busLimiter?.lookahead, masterLimiter?.lookahead].compactMap { $0 }.reduce(0) { $0 + max($1, 1000 / fs) + extra }
    }
}

/// Real-time chain for one tap: de-esser → compressor → clip gain → clip pan → clip limiter → track gain/pan →
/// bus gain/compressor/limiter → master gain/limiter. Everything is allocated in `init` (called from the tap's
/// prepare callback); `configure` only writes coefficients, `process` never allocates or locks.
final class DynamicsChain {
    let channels: Int
    let fs: Double
    let strip: TrackStrip
    private var deEsserLow: UnsafeMutablePointer<Biquad>, deEsserHigh: UnsafeMutablePointer<Biquad>   // 2 sections per channel
    private var deEsser = DeEsserDSP()
    private var deEsserOn = false
    private var comp = CompressorDSP(), compOn = false
    private var gain = 1.0, panL = 1.0, panR = 1.0, panOn = false
    private let clipLimiter: LimiterDSP?, busLimiter: LimiterDSP?, masterLimiter: LimiterDSP?
    private var clipLimiterActive = false
    private var busComp = CompressorDSP()
    private let trackPan: (left: Double, right: Double)
    private let low: UnsafeMutablePointer<Double>, high: UnsafeMutablePointer<Double>

    init(channels: Int, sampleRate: Double, strip: TrackStrip) {
        self.channels = max(1, channels); fs = sampleRate; self.strip = strip
        deEsserLow = .allocate(capacity: self.channels * 2); deEsserLow.initialize(repeating: Biquad(), count: self.channels * 2)
        deEsserHigh = .allocate(capacity: self.channels * 2); deEsserHigh.initialize(repeating: Biquad(), count: self.channels * 2)
        low = .allocate(capacity: self.channels); low.initialize(repeating: 0, count: self.channels)
        high = .allocate(capacity: self.channels); high.initialize(repeating: 0, count: self.channels)
        let frames = { (ms: Double) in max(1, Int((ms / 1000 * sampleRate).rounded())) }
        let C = max(1, channels)
        clipLimiter = strip.clipLimiterLookahead.map { _ in LimiterDSP(channels: C, sampleRate: sampleRate) }
        busLimiter = strip.busLimiter.map { l in let d = LimiterDSP(channels: C, sampleRate: sampleRate); d.configure(ceilingDB: l.ceiling, releaseMs: l.release, lookaheadFrames: frames(l.lookahead), fs: sampleRate); return d }
        masterLimiter = strip.masterLimiter.map { l in let d = LimiterDSP(channels: C, sampleRate: sampleRate); d.configure(ceilingDB: l.ceiling, releaseMs: l.release, lookaheadFrames: frames(l.lookahead), fs: sampleRate); return d }
        if let la = strip.clipLimiterLookahead { clipLimiter?.configureBypass(lookaheadFrames: frames(la), fs: sampleRate) }
        if let bc = strip.busCompressor { busComp.configure(bc, fs: sampleRate) }
        trackPan = DSP.balance(strip.pan)
    }
    deinit { deEsserLow.deallocate(); deEsserHigh.deallocate(); low.deallocate(); high.deallocate() }

    /// True when the chain does nothing for these clip settings (so the tap can skip the per-frame work).
    func isIdle(for a: ClipAudio) -> Bool {
        strip.isIdentity && a.deEsser == nil && a.compressor == nil && a.gain == 0 && a.pan == 0 && a.limiter == nil
    }

    /// New clip settings (a span switch). Writes coefficients only; filter and envelope state carries on when the
    /// same processor stays on, and starts clean when it is switched on.
    func configure(_ a: ClipAudio) {
        if let d = a.deEsser {
            let f = min(d.frequency, fs * 0.45)
            let lp = Biquad.lowPass(fs, f: f), hp = Biquad.highPass(fs, f: f)
            for i in 0..<(channels * 2) {
                if deEsserOn { deEsserLow[i].setCoefficients(lp); deEsserHigh[i].setCoefficients(hp) } else { deEsserLow[i] = lp.cleared; deEsserHigh[i] = hp.cleared }
            }
            if !deEsserOn { deEsser.reset() }
            deEsser.configure(d, fs: fs); deEsserOn = true
        } else { deEsserOn = false }
        if let c = a.compressor { if !compOn { comp.reset() }; comp.configure(c, fs: fs); compOn = true } else { compOn = false }
        gain = DSP.dbToGain(a.gain)
        let p = DSP.balance(a.pan); panL = p.left; panR = p.right; panOn = a.pan != 0 && channels >= 2
        if let lim = clipLimiter, let la = strip.clipLimiterLookahead {
            let frames = max(1, Int((la / 1000 * fs).rounded()))
            if let l = a.limiter { lim.configure(ceilingDB: l.ceiling, releaseMs: l.release, lookaheadFrames: frames, fs: fs); clipLimiterActive = true }
            else { lim.configureBypass(lookaheadFrames: frames, fs: fs); clipLimiterActive = false }
        }
    }

    /// Clears every envelope and delay line (a seek or a jump in time).
    func reset() {
        for i in 0..<(channels * 2) { deEsserLow[i] = deEsserLow[i].cleared; deEsserHigh[i] = deEsserHigh[i].cleared }
        deEsser.reset(); comp.reset(); busComp.reset()
        clipLimiter?.reset(); busLimiter?.reset(); masterLimiter?.reset()
    }

    /// Gain reduction now, in dB, for meters: (compressor, de-esser).
    var reductions: (compressor: Double, deEsser: Double, busCompressor: Double) { (compOn ? comp.reduction : 0, deEsserOn ? deEsser.reduction : 0, strip.busCompressor != nil ? busComp.reduction : 0) }
    func takeLimiterGains() -> (clip: Double, bus: Double, master: Double) { (clipLimiter?.takeMinGain() ?? 1, busLimiter?.takeMinGain() ?? 1, masterLimiter?.takeMinGain() ?? 1) }

    /// One frame in place. `post` is the clip's volume envelope at this moment (applied by AVFoundation after the tap).
    @inline(__always) func process(_ x: UnsafeMutablePointer<Double>, post: Double) {
        let C = channels
        if deEsserOn {
            var band = 0.0, whole = 0.0
            for ch in 0..<C {
                let v = x[ch]
                let l = deEsserLow[ch * 2 + 1].process(deEsserLow[ch * 2].process(v))
                let h = deEsserHigh[ch * 2 + 1].process(deEsserHigh[ch * 2].process(v))
                low[ch] = l; high[ch] = h
                band = max(band, abs(h)); whole = max(whole, abs(v))
            }
            let g = deEsser.bandGain(band: band, whole: whole)
            for ch in 0..<C { x[ch] = low[ch] + high[ch] * g }
        }
        if compOn {
            var level = 0.0
            for ch in 0..<C { level = max(level, abs(x[ch])) }
            let g = comp.gain(level: level)
            for ch in 0..<C { x[ch] *= g }
        }
        if gain != 1 { for ch in 0..<C { x[ch] *= gain } }
        if panOn { x[0] *= panL; x[1] *= panR }
        // Every later stage applies its own gain before the next detector, so each limiter sees what will be heard.
        let tGain = strip.gain, bGain = strip.busGain, mGain = strip.masterGain
        if let lim = clipLimiter { lim.process(x, post: post * (clipLimiterActive ? 1 : 0)) }
        if tGain != 1 { for ch in 0..<C { x[ch] *= tGain } }
        if strip.pan != 0, C >= 2 { x[0] *= trackPan.left; x[1] *= trackPan.right }
        if bGain != 1 { for ch in 0..<C { x[ch] *= bGain } }
        if strip.busCompressor != nil {
            var level = 0.0
            for ch in 0..<C { level = max(level, abs(x[ch])) }
            let g = busComp.gain(level: level * post)
            for ch in 0..<C { x[ch] *= g }
        }
        if let lim = busLimiter { lim.process(x, post: post) }
        if mGain != 1 { for ch in 0..<C { x[ch] *= mGain } }
        if let lim = masterLimiter { lim.process(x, post: post) }
    }
}

// MARK: - Hum notches (run with the EQ, before the gate)

/// Up to eight partial notches per channel, preallocated.
final class HumFilter {
    static let maxHarmonics = 8
    private let channels: Int
    private let sections: UnsafeMutablePointer<Biquad>
    private var count = 0
    private var amount = 0.0
    private(set) var settings: HumSettings?

    init(channels: Int) {
        self.channels = max(1, channels)
        sections = .allocate(capacity: self.channels * Self.maxHarmonics); sections.initialize(repeating: Biquad(), count: self.channels * Self.maxHarmonics)
    }
    deinit { sections.deallocate() }

    func configure(_ s: HumSettings?, fs: Double) {
        guard let s, s.amount > 0 else { settings = nil; count = 0; return }
        let same = settings?.frequency == s.frequency && settings?.harmonics == s.harmonics
        settings = s; amount = max(0, min(1, s.amount))
        var k = 0
        for h in 1...max(1, min(Self.maxHarmonics, s.harmonics)) {
            let f = s.frequency * Double(h)
            guard f < fs * 0.45 else { break }
            let bp = Biquad.bandPass(fs, f: f, Q: 30)   // ±1 Hz at 60 Hz, wider (in Hz) at each harmonic
            for ch in 0..<channels { let i = ch * Self.maxHarmonics + k; if same { sections[i].setCoefficients(bp) } else { sections[i] = bp } }
            k += 1
        }
        count = k
    }
    func reset() { for i in 0..<(channels * Self.maxHarmonics) { sections[i] = sections[i].cleared } }

    @inline(__always) func process(_ x: Double, channel: Int) -> Double {
        var y = x
        let base = sections + channel * Self.maxHarmonics
        for k in 0..<count { y -= amount * base[k].process(y) }
        return y
    }
    var isActive: Bool { count > 0 }
}

// MARK: - Offline helpers (tests, previews, tools)

enum OfflineDSP {
    /// Runs the tap's processing over planar float buffers (one array per channel), as the tap would, in 1024-frame
    /// buffers. `envelope` is the volume AVFoundation would apply after the tap (not applied here: only the limiters
    /// and meters read it).
    static func run(_ channels: [[Float]], sampleRate: Double, audio: ClipAudio, strip: TrackStrip = TrackStrip(), envelope: [(Double, Double)] = []) -> [[Float]] {
        var strip = strip
        if strip.clipLimiterLookahead == nil, let l = audio.limiter { strip.clipLimiterLookahead = l.lookahead }
        let ctx = AudioTapContext(spans: [.init(start: 0, end: .infinity, audio: audio, envelope: envelope)], strip: strip)
        ctx.prepare(sampleRate: sampleRate, channels: channels.count)
        var out = channels
        let n = channels.first?.count ?? 0
        let block = 1024
        var start = 0
        while start < n {
            let len = min(block, n - start)
            let abl = AudioBufferList.allocate(maximumBuffers: channels.count)
            var ptrs: [UnsafeMutablePointer<Float>] = []
            for ch in 0..<channels.count {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: len)
                for i in 0..<len { p[i] = out[ch][start + i] }
                abl[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(len * 4), mData: p)
                ptrs.append(p)
            }
            ctx.run(abl.unsafeMutablePointer, frames: len, interleaved: false, time: Double(start) / sampleRate)
            for ch in 0..<channels.count { for i in 0..<len { out[ch][start + i] = ptrs[ch][i] }; ptrs[ch].deallocate() }
            free(abl.unsafeMutablePointer)
            start += len
        }
        return out
    }
}
