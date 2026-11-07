import Foundation

/// Shot matching: measure two frames and solve for a grade that makes the first look like the second.
///
/// Each frame is sampled (320 px wide) into per-channel percentiles and a mean saturation. Per channel, lift, gamma
/// and gain are solved so the target's 2nd, 50th and 98th percentiles land on the reference's (closed form for lift
/// and gain given the gamma, bisection on the gamma for the median), and a saturation factor matches the mean
/// saturation (applied before the wheels, as in the grade). The result goes on a "Shot match" grade layer, so it sits
/// after the clip's own grade, the matching ran on exactly what that layer receives, and it can be mixed or removed.
enum ShotMatch {
    static let quantiles = [0.02, 0.10, 0.25, 0.50, 0.75, 0.90, 0.98]
    static let layerName = "Shot match"

    struct Stats: Equatable {
        /// Per channel (r, g, b): the value at each of `quantiles`, 0…1.
        var percentiles: [[Double]]
        var meanSaturation: Double
        var medians: [Double] { percentiles.map { $0[3] } }
    }

    /// Pixels as (r, g, b) in 0…1 from RGBA8.
    static func samples(_ px: [UInt8]) -> [(Double, Double, Double)] {
        stride(from: 0, to: px.count - 3, by: 4).map { (i: Int) -> (Double, Double, Double) in
            let r: Double = Double(px[i]) / 255, g: Double = Double(px[i + 1]) / 255, b: Double = Double(px[i + 2]) / 255
            return (r, g, b)
        }
    }

    static func measure(_ s: [(Double, Double, Double)]) -> Stats {
        guard !s.isEmpty else { return Stats(percentiles: [[Double]](repeating: quantiles.map { _ in 0 }, count: 3), meanSaturation: 0) }
        var chans = [s.map(\.0), s.map(\.1), s.map(\.2)]
        for i in 0..<3 { chans[i].sort() }
        let p = chans.map { c in quantiles.map { c[min(c.count - 1, Int(Double(c.count - 1) * $0))] } }
        let sat = s.reduce(0.0) { $0 + (max($1.0, $1.1, $1.2) - min($1.0, $1.1, $1.2)) } / Double(s.count)
        return Stats(percentiles: p, meanSaturation: sat)
    }

    /// How far apart two frames' colour statistics are, in 0–255 levels: the RMS of every channel percentile's
    /// difference, with the mean-saturation difference counted as one more term.
    static func distance(_ a: Stats, _ b: Stats) -> Double {
        var sum = 0.0, n = 0.0
        for c in 0..<3 { for q in 0..<quantiles.count { let d = (a.percentiles[c][q] - b.percentiles[c][q]) * 255; sum += d * d; n += 1 } }
        let ds = (a.meanSaturation - b.meanSaturation) * 255
        sum += ds * ds * 3; n += 3
        return ((sum / n).squareRoot() * 10).rounded() / 10
    }

    struct Solution {
        var wheels: ColorWheels
        var saturation: Double
        /// What the solution predicts the target will measure.
        var predicted: Stats
        var clamped: Bool
    }

    /// The saturation step of the grade (CIColorControls: a lerp from Rec.709 luma).
    static func saturate(_ p: (Double, Double, Double), _ s: Double) -> (Double, Double, Double) {
        let y = ColorBalance.luma(p.0, p.1, p.2)
        return (y + (p.0 - y) * s, y + (p.1 - y) * s, y + (p.2 - y) * s)
    }

    /// Solves the layer for `target` samples to match `reference` statistics.
    static func solve(target: [(Double, Double, Double)], reference ref: Stats) -> Solution {
        var sat = 1.0
        var wheels = ColorWheels()
        var clamped = false
        var predicted = measure(target)
        for _ in 0..<4 {
            let adjusted = sat == 1 ? target : target.map { saturate($0, sat) }
            let tStats = measure(adjusted)
            var lift = [0.0, 0.0, 0.0], gamma = [0.0, 0.0, 0.0], gain = [0.0, 0.0, 0.0]
            for c in 0..<3 {
                let (l, g, k, cl) = channel(lo: tStats.percentiles[c][0], mid: tStats.percentiles[c][3], hi: tStats.percentiles[c][6],
                                            LO: ref.percentiles[c][0], MID: ref.percentiles[c][3], HI: ref.percentiles[c][6])
                lift[c] = l; gamma[c] = g; gain[c] = k; clamped = clamped || cl
            }
            wheels = ColorWheels()
            wheels.lift = split(lift); wheels.gamma = split(gamma); wheels.gain = split(gain)
            let mapped = adjusted.map { p in (wheels.apply(p.0, channel: 0), wheels.apply(p.1, channel: 1), wheels.apply(p.2, channel: 2)) }
            predicted = measure(mapped.map { (min(1, max(0, $0.0)), min(1, max(0, $0.1)), min(1, max(0, $0.2))) })
            guard predicted.meanSaturation > 0.005, ref.meanSaturation > 0.005 else { break }
            let next = min(2, max(0.3, sat * ref.meanSaturation / predicted.meanSaturation))
            if abs(next - sat) < 0.01 { break }
            sat = next
        }
        return Solution(wheels: wheels, saturation: (sat * 1000).rounded() / 1000, predicted: predicted, clamped: clamped)
    }

    /// Per-channel values as a wheel: the master is their mean, the balance the rest.
    static func split(_ v: [Double]) -> ColorWheel {
        let m = (v[0] + v[1] + v[2]) / 3
        let r = { (x: Double) in (x * 1000).rounded() / 1000 }
        return ColorWheel(r: r(v[0] - m), g: r(v[1] - m), b: r(v[2] - m), master: r(m))
    }

    /// Lift, gamma (wheel units) and gain for one channel so that lo → LO, mid → MID, hi → HI under
    /// y = (x + L(1 − x))^(2^(−2G)) · (1 + K). Returns whether a value had to be limited.
    static func channel(lo: Double, mid: Double, hi: Double, LO: Double, MID: Double, HI: Double) -> (Double, Double, Double, Bool) {
        guard hi - lo > 0.02, HI > 0.02 else {
            // A flat channel: shift it with the gain alone.
            let k = hi > 0.02 ? HI / hi - 1 : 0
            return (0, 0, min(1, max(-0.9, k)), false)
        }
        func liftGain(_ G: Double) -> (L: Double, K: Double) {
            let p = pow(2, -2 * G)
            let q = pow(max(0, LO) / HI, 1 / p)
            let den = (1 - lo) - q * (1 - hi)
            var L = abs(den) < 1e-9 ? 0 : (q * hi - lo) / den
            L = min(0.6, max(-0.6, L))
            let u = hi + L * (1 - hi)
            let K = u > 1e-6 ? HI / pow(u, p) - 1 : 0
            return (L, K)
        }
        func midOut(_ G: Double) -> Double {
            let (L, K) = liftGain(G), p = pow(2, -2 * G)
            let u = max(0, mid + L * (1 - mid))
            return pow(u, p) * (1 + K)
        }
        // midOut falls as G falls (a larger exponent darkens the middle): bisect for MID.
        var a = -1.0, b = 1.0
        let fa = midOut(a) - MID, fb = midOut(b) - MID
        var G: Double
        if fa * fb > 0 {
            // No exact solution inside the range: take the closest end.
            G = abs(fa) < abs(fb) ? a : b
        } else {
            for _ in 0..<50 { let m = (a + b) / 2; if (midOut(m) - MID) * fa > 0 { a = m } else { b = m } }
            G = (a + b) / 2
        }
        let (L, K0) = liftGain(G)
        let K = min(1.5, max(-0.9, K0))
        let limited = K != K0 || abs(L) >= 0.6 || abs(G) >= 0.999
        return (L, min(1, max(-1, G)), K, limited)
    }
}
