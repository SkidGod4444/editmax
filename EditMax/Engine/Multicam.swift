import Foundation

/// One camera angle switch inside a multicam clip: from `time` (clip-local seconds) the picture comes from `angle`.
struct MulticamCut: Codable, Equatable { var time: Double; var angle: Int }

/// A clip that carries several synchronized sources. `angles[0]` is the clip's own asset; `offsets[i]` is added to the
/// base source time to reach the same moment in angle i; `cuts` pick the picture angle over the clip; the sound always
/// comes from `audioAngle`. The builder expands the clip into one plain piece per cut interval.
struct Multicam: Codable, Equatable {
    var angles: [UUID]
    var offsets: [Double]
    var cuts: [MulticamCut] = []
    var audioAngle: Int = 0

    init(angles: [UUID], offsets: [Double], cuts: [MulticamCut] = [], audioAngle: Int = 0) { self.angles = angles; self.offsets = offsets; self.cuts = cuts; self.audioAngle = audioAngle }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        angles = try c.decodeIfPresent([UUID].self, forKey: .angles) ?? []
        offsets = try c.decodeIfPresent([Double].self, forKey: .offsets) ?? []
        cuts = try c.decodeIfPresent([MulticamCut].self, forKey: .cuts) ?? []
        audioAngle = try c.decodeIfPresent(Int.self, forKey: .audioAngle) ?? 0
    }

    func offset(_ i: Int) -> Double { i < offsets.count ? offsets[i] : 0 }
    /// The picture angle in effect at a clip-local time (angle 0 before the first cut).
    func angle(at local: Double) -> Int {
        let a = cuts.filter { $0.time <= local + 1e-6 }.max { $0.time < $1.time }?.angle ?? 0
        return min(max(0, a), max(0, angles.count - 1))
    }
    mutating func setCut(at local: Double, angle: Int) {
        cuts.removeAll { abs($0.time - local) < 1.0 / 120 }
        cuts.append(MulticamCut(time: local, angle: angle))
        cuts.sort { $0.time < $1.time }
    }
    mutating func removeCut(at local: Double) -> Bool {
        let n = cuts.count
        cuts.removeAll { abs($0.time - local) < 1.0 / 120 }
        return cuts.count < n
    }
}

/// Lines up two recordings of the same moment by their audio: the lag that best correlates their loudness envelopes.
enum AngleSync {
    /// Seconds to add to a time in `base` to reach the same moment in `other`, and the normalized correlation at that lag
    /// (1 = identical envelopes; below ~0.3 the recordings probably do not share sound).
    static func offset(of other: URL, relativeTo base: URL, window: Double = 90, maxLag: Double = 30) async throws -> (offset: Double, confidence: Double) {
        if other == base { return (0, 1) }
        let rate = Double(WaveformStore.peaksPerSecond)
        let a = try await WaveformExtractor.peaks(for: base), b = try await WaveformExtractor.peaks(for: other)
        let n = min(a.count, Int(window * rate)), m = min(b.count, Int((window + maxLag) * rate))
        guard n > Int(rate), m > Int(rate) else { throw EditError.invalid("not enough audio to sync (need at least a second in both angles)") }
        func centered(_ p: ArraySlice<Float>) -> [Double] { let mean = p.reduce(0.0) { $0 + Double($1) } / Double(p.count); return p.map { Double($0) - mean } }
        let x = centered(a[0..<n]), y = centered(b[0..<m])
        let lagRange = Int(maxLag * rate)
        var best = (lag: 0, score: -2.0)
        for lag in -lagRange...lagRange {
            let lo = max(0, -lag), hi = min(n, m - lag)
            guard hi - lo > Int(rate) else { continue }
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for i in lo..<hi { let xi = x[i], yi = y[i + lag]; sxy += xi * yi; sxx += xi * xi; syy += yi * yi }
            let score = sxy / max(1e-9, (sxx * syy).squareRoot())
            if score > best.score { best = (lag, score) }
        }
        return (Double(best.lag) / rate, max(0, best.score))
    }
}
