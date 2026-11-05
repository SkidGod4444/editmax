import Foundation
import AVFoundation
import MediaToolbox
import Accelerate

/// Per-clip audio processing: a three-band EQ (low shelf, mid peak, high shelf), a high-pass filter and a noise gate.
/// Gains in dB (0 = untouched), frequencies in Hz (0 = off), the gate threshold in dBFS (0 = off).
struct ClipAudio: Codable, Equatable {
    var lowGain: Double = 0
    var midGain: Double = 0
    var highGain: Double = 0
    var highPass: Double = 0
    var gate: Double = 0
    /// Voice isolation amount, 0 = off … 1 = speech only. Pre-rendered per asset by `IsolatedAudio`, never run in the tap.
    var voiceIsolation: Double = 0
    /// Nothing for the tap to process (EQ, high-pass, gate). Isolation does not count: it is rendered ahead of time.
    var isIdentity: Bool { lowGain == 0 && midGain == 0 && highGain == 0 && highPass == 0 && gate == 0 }
    /// Every setting at its default, isolation included.
    var isDefault: Bool { self == ClipAudio() }
    var needsIsolation: Bool { voiceIsolation > 0.001 }
    static let identity = ClipAudio()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lowGain = try c.decodeIfPresent(Double.self, forKey: .lowGain) ?? 0
        midGain = try c.decodeIfPresent(Double.self, forKey: .midGain) ?? 0
        highGain = try c.decodeIfPresent(Double.self, forKey: .highGain) ?? 0
        highPass = try c.decodeIfPresent(Double.self, forKey: .highPass) ?? 0
        gate = try c.decodeIfPresent(Double.self, forKey: .gate) ?? 0
        voiceIsolation = try c.decodeIfPresent(Double.self, forKey: .voiceIsolation) ?? 0
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

/// The state behind one audio tap: which clip's settings apply when, and the filters per channel.
final class AudioTapContext {
    struct Span { let start: Double, end: Double, audio: ClipAudio }
    let spans: [Span]
    var sampleRate = 48000.0
    var channels = 2
    var current: ClipAudio? = nil
    var filters: [[Biquad]] = []    // per channel: [low, mid, high, highPass] (only the active ones are run)
    var gateEnv = 0.0, gateGain = 1.0

    init(spans: [Span]) { self.spans = spans }

    func settings(at t: Double) -> ClipAudio? { spans.first { $0.start - 0.001 <= t && t < $0.end + 0.001 }?.audio }

    func configure(_ a: ClipAudio) {
        current = a
        filters = (0..<channels).map { _ in
            [Biquad.lowShelf(sampleRate, f: 200, gainDB: a.lowGain), Biquad.peak(sampleRate, f: 1000, gainDB: a.midGain),
             Biquad.highShelf(sampleRate, f: 6000, gainDB: a.highGain), a.highPass > 0 ? Biquad.highPass(sampleRate, f: min(a.highPass, sampleRate * 0.45)) : Biquad()]
        }
    }

    /// Runs the active filters and the gate over one buffer of float samples (interleaved or planar).
    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, interleaved: Bool) {
        guard let a = current, !a.isIdentity else { return }
        let runLow = a.lowGain != 0, runMid = a.midGain != 0, runHigh = a.highGain != 0, runHP = a.highPass > 0
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let gateOn = a.gate < 0
        let thr = pow(10, a.gate / 20)
        let attack = exp(-1 / (0.005 * sampleRate)), release = exp(-1 / (0.08 * sampleRate))
        let gainAttack = exp(-1 / (0.003 * sampleRate)), gainRelease = exp(-1 / (0.05 * sampleRate))
        for frame in 0..<frames {
            var peak = 0.0
            for ch in 0..<channels {
                let ptr: UnsafeMutablePointer<Float>
                if interleaved { guard let d = buffers[0].mData else { continue }; ptr = d.assumingMemoryBound(to: Float.self) + frame * channels + ch }
                else { guard ch < buffers.count, let d = buffers[ch].mData else { continue }; ptr = d.assumingMemoryBound(to: Float.self) + frame }
                var x = Double(ptr.pointee)
                if runHP { x = filters[ch][3].process(x) }
                if runLow { x = filters[ch][0].process(x) }
                if runMid { x = filters[ch][1].process(x) }
                if runHigh { x = filters[ch][2].process(x) }
                peak = max(peak, abs(x))
                ptr.pointee = Float(x)
            }
            if gateOn {
                gateEnv = peak > gateEnv ? attack * gateEnv + (1 - attack) * peak : release * gateEnv + (1 - release) * peak
                let target = gateEnv >= thr ? 1.0 : 0.05   // closed gate = −26 dB, not silence, so it never pumps hard
                gateGain = target > gateGain ? gainAttack * gateGain + (1 - gainAttack) * target : gainRelease * gateGain + (1 - gainRelease) * target
                for ch in 0..<channels {
                    let ptr: UnsafeMutablePointer<Float>
                    if interleaved { guard let d = buffers[0].mData else { continue }; ptr = d.assumingMemoryBound(to: Float.self) + frame * channels + ch }
                    else { guard ch < buffers.count, let d = buffers[ch].mData else { continue }; ptr = d.assumingMemoryBound(to: Float.self) + frame }
                    ptr.pointee *= Float(gateGain)
                }
            }
        }
    }
}

enum AudioTap {
    /// A tap for one composition audio track, running the clip settings of whatever clip is playing at each buffer's time.
    static func make(spans: [AudioTapContext.Span]) -> MTAudioProcessingTap? {
        let ctx = AudioTapContext(spans: spans)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(ctx).toOpaque(),
            init: { tap, clientInfo, tapStorageOut in tapStorageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, maxFrames, format in
                let c = Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                c.sampleRate = format.pointee.mSampleRate
                c.channels = Int(format.pointee.mChannelsPerFrame)
                if let cur = c.current { c.configure(cur) }
            },
            unprepare: { _ in },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                var range = CMTimeRange.zero
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &range, numberFramesOut)
                guard status == noErr else { return }
                let c = Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let t = range.start.seconds
                let wanted = c.settings(at: t.isFinite ? t : 0) ?? .identity
                if c.current != wanted { c.configure(wanted) }
                let interleaved = UnsafeMutableAudioBufferListPointer(bufferListInOut).count == 1 && c.channels > 1
                c.process(bufferListInOut, frames: Int(numberFramesOut.pointee), interleaved: interleaved)
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
