import Foundation
import AVFoundation
import CoreVideo

// MARK: - Scene cut detection
//
// Reads the picture with AVAssetReader at a small size (the decoder scales to about 96 px wide), and for each frame
// builds a 4×4×4 RGB colour histogram and a 4×4 grid of mean brightness. The difference between neighbouring frames
// (0.8 × half the L1 histogram distance + 0.2 × three times the mean grid change) is near 0 within a shot and high across
// a hard cut. A frame is a cut when its difference is a local peak, clears a floor, and stands well above the
// differences of the second before it (median + k × MAD, so a busy handheld shot needs a bigger jump than a locked-off
// one). Sensitivity 0...1 lowers the floor and k. Dissolves and fades spread the change over many frames and are not
// reported as cuts.

enum SceneDetector {
    struct Cut: Codable, Equatable { var time: Double; var score: Double }
    struct Result { var cuts: [Cut]; var times: [Double]; var diffs: [Double]; var threshold: [Double]; var frames: Int }

    static let defaultSensitivity = 0.5

    /// Floor and spread factor for a sensitivity (0 = only the most obvious cuts, 1 = anything that jumps).
    static func parameters(_ sensitivity: Double) -> (floor: Double, k: Double) {
        let s = min(1, max(0, sensitivity))
        return (0.12 + 0.38 * (1 - s), 2 + 8 * (1 - s))
    }

    /// Cuts between source seconds `from` and `to` of `url`, each at the first frame of the new shot.
    nonisolated static func detect(url: URL, from: Double = 0, to: Double? = nil, sensitivity: Double = defaultSensitivity, minScene: Double = 0.5) async throws -> Result {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditError.invalid("\(url.lastPathComponent) has no picture") }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let end = min(to ?? duration, duration)
        guard end - from > 0.1 else { throw EditError.invalid("the range \(EditFormat.s(from))–\(EditFormat.s(end)) s is too short to look for cuts") }
        let w = 96, h = max(8, Int((96 * abs(size.height) / max(1, abs(size.width))).rounded()))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw EditError.invalid("cannot read the picture of \(url.lastPathComponent)") }
        reader.add(out)
        guard reader.startReading() else { throw EditError.invalid("cannot read \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")") }

        var times: [Double] = [], diffs: [Double] = []
        var prev: Signature?
        while let sample = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let px = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let sig = Signature(px)
            times.append(t)
            diffs.append(prev.map { sig.distance($0) } ?? 0)
            prev = sig
        }
        if reader.status == .failed { throw EditError.invalid("reading \(url.lastPathComponent) failed: \(reader.error?.localizedDescription ?? "unknown error")") }
        return pick(times: times, diffs: diffs, sensitivity: sensitivity, minScene: minScene)
    }

    /// The adaptive threshold over a difference curve (separate from reading, so it is tested on its own).
    static func pick(times: [Double], diffs: [Double], sensitivity: Double, minScene: Double) -> Result {
        let (floor, k) = parameters(sensitivity)
        let fps = times.count > 1 ? Double(times.count - 1) / max(1e-6, times.last! - times.first!) : 30
        let window = max(4, Int(fps.rounded()))
        var cuts: [Cut] = [], threshold: [Double] = Array(repeating: floor, count: diffs.count)
        var lastCut = -Double.infinity
        for i in 1..<max(1, diffs.count) {
            let lo = max(1, i - window)
            let before = Array(diffs[lo..<i])
            let med = median(before), mad = median(before.map { abs($0 - med) })
            let th = max(floor, med + k * max(mad, 0.01))
            threshold[i] = th
            let d = diffs[i]
            let peak = d >= (i > 1 ? diffs[i - 1] : 0) && d >= (i + 1 < diffs.count ? diffs[i + 1] : 0)
            guard d > th, peak, times[i] - lastCut >= minScene, times[i] - times[0] >= minScene * 0.5 else { continue }
            cuts.append(Cut(time: times[i], score: min(1, d)))
            lastCut = times[i]
        }
        return Result(cuts: cuts, times: times, diffs: diffs, threshold: threshold, frames: times.count)
    }

    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// A frame's colour histogram (64 bins, sums to 1) and 4×4 mean brightness grid (0...1).
    struct Signature {
        var hist = [Double](repeating: 0, count: 64)
        var grid = [Double](repeating: 0, count: 16)
        init(_ px: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(px) else { return }
            let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), row = CVPixelBufferGetBytesPerRow(px)
            let p = base.assumingMemoryBound(to: UInt8.self)
            // A decoder that ignores the requested size hands over the full frame: sample about 96 × 54 points.
            let step = max(1, w / 96)
            var n = 0.0, counts = [Double](repeating: 0, count: 16)
            for y in stride(from: 0, to: h, by: step) {
                for x in stride(from: 0, to: w, by: step) {
                    let o = y * row + x * 4
                    let b = Int(p[o]), g = Int(p[o + 1]), r = Int(p[o + 2])
                    // Soft (trilinear) binning: a colour near a bin edge votes for both bins, so a flat wall whose
                    // exposure drifts across an edge changes the histogram a little, not all at once.
                    let fr = Double(r) / 85, fg = Double(g) / 85, fb = Double(b) / 85
                    let r0 = min(2, Int(fr)), g0 = min(2, Int(fg)), b0 = min(2, Int(fb))
                    let wr = fr - Double(r0), wg = fg - Double(g0), wb = fb - Double(b0)
                    for dr in 0...1 { for dg in 0...1 { for db in 0...1 {
                        // Split up: CI's compiler gave up type-checking the one-line product.
                        let tr: Double = dr == 0 ? 1 - wr : wr, tg: Double = dg == 0 ? 1 - wg : wg, tb: Double = db == 0 ? 1 - wb : wb
                        let wt: Double = tr * tg * tb
                        hist[(r0 + dr) * 16 + (g0 + dg) * 4 + (b0 + db)] += wt
                    } } }
                    let cell = min(3, y * 4 / h) * 4 + min(3, x * 4 / w)
                    grid[cell] += Double(r * 3 + g * 6 + b) / 2550
                    counts[cell] += 1
                    n += 1
                }
            }
            if n > 0 { for i in hist.indices { hist[i] /= n } }
            for i in grid.indices where counts[i] > 0 { grid[i] /= counts[i] }
        }
        func distance(_ o: Signature) -> Double {
            var hd = 0.0; for i in hist.indices { hd += abs(hist[i] - o.hist[i]) }
            var gd = 0.0; for i in grid.indices { gd += abs(grid[i] - o.grid[i]) }
            return min(1, 0.8 * hd / 2 + 0.2 * min(1, 3 * gd / 16))
        }
    }
}

extension Clip {
    /// The clip-local time at which `sourceSeconds` of its media plays (inverse of sourceOffset, by bisection), or nil
    /// when that moment is outside the clip.
    func localTime(ofSource sourceSeconds: Double) -> Double? {
        let off = sourceSeconds - sourceIn
        guard off >= -1e-6, off <= sourceOffset(at: duration) + 1e-6 else { return nil }
        var lo = 0.0, hi = duration
        for _ in 0..<48 {
            let mid = (lo + hi) / 2
            if sourceOffset(at: mid) < off { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}
