import Foundation
import CoreGraphics
import CoreVideo

/// The RGB parade and the vectorscope: images for the scopes panel and numbers for agents (`frame_stats`,
/// `capture_scopes`). Both read 8-bit frames, like the waveform and histogram beside them.
enum ColorScopes {
    static let paradeColumns = 96, paradeRows = 96, paradeGap = 4
    static let vectorSize = 128
    /// Cb/Cr ±0.5 spans the vectorscope's radius (a fully saturated primary sits near the rim).
    static let vectorScale = Double(vectorSize) / 2 * 0.92 / 0.5

    /// Where a colour lands on the vectorscope image (x right = +Cb, y down = −Cr), in pixels.
    static func vectorPoint(r: Double, g: Double, b: Double) -> (x: Double, y: Double) {
        let s = ColorBalance.scope(r: r, g: g, b: b)
        return (Double(vectorSize) / 2 + s.cb * vectorScale, Double(vectorSize) / 2 - s.cr * vectorScale)
    }

    /// Parade and vectorscope images from a frame, sampled on a grid. `bgra` says the byte order (else RGBA).
    static func images(_ p: UnsafePointer<UInt8>, width w: Int, height h: Int, stride: Int, bgra: Bool, step: Int) -> (parade: CGImage?, vectorscope: CGImage?) {
        let pc = paradeColumns, pr = paradeRows
        var parade = [Int](repeating: 0, count: 3 * pc * pr)
        let vs = vectorSize
        var vCount = [Int](repeating: 0, count: vs * vs)
        var vSum = [Double](repeating: 0, count: vs * vs * 3)
        let ri = bgra ? 2 : 0, bi = bgra ? 0 : 2
        var y = 0
        while y < h {
            let row = p + y * stride
            var x = 0
            while x < w {
                let r = Int(row[x * 4 + ri]), g = Int(row[x * 4 + 1]), b = Int(row[x * 4 + bi])
                let col = x * pc / w
                parade[(pr - 1 - r * pr / 256) * pc + col] += 1
                parade[(pr + pr - 1 - g * pr / 256) * pc + col] += 1
                parade[(2 * pr + pr - 1 - b * pr / 256) * pc + col] += 1
                let (vx, vy) = vectorPoint(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255)
                let ix = Int(vx), iy = Int(vy)
                if ix >= 0, ix < vs, iy >= 0, iy < vs {
                    let k = iy * vs + ix
                    vCount[k] += 1; vSum[k * 3] += Double(r); vSum[k * 3 + 1] += Double(g); vSum[k * 3 + 2] += Double(b)
                }
                x += step
            }
            y += step
        }
        // Parade: three traces side by side, each in its channel's colour, log-scaled so thin lines show.
        let W = 3 * pc + 2 * paradeGap
        var rgba = [UInt8](repeating: 0, count: W * pr * 4)
        let peak = max(1, parade.max() ?? 1)
        for ch in 0..<3 { for yy in 0..<pr { for xx in 0..<pc {
            let n = parade[(ch * pr + yy) * pc + xx]
            guard n > 0 else { continue }
            let v = UInt8(min(255, 50 + 205 * log(1 + Double(n)) / log(1 + Double(peak))))
            let o = (yy * W + ch * (pc + paradeGap) + xx) * 4
            let tint: (UInt8, UInt8, UInt8) = ch == 0 ? (v, v / 5, v / 5) : ch == 1 ? (v / 5, v, v / 4) : (v / 4, v / 3, v)
            rgba[o] = tint.0; rgba[o + 1] = tint.1; rgba[o + 2] = tint.2; rgba[o + 3] = 255
        } } }
        // Vectorscope: each spot in the average colour of the pixels that land there, brightness by how many.
        var vrgba = [UInt8](repeating: 0, count: vs * vs * 4)
        let vpeak = max(1, vCount.max() ?? 1)
        for k in 0..<(vs * vs) where vCount[k] > 0 {
            let n = Double(vCount[k]), lvl = 0.35 + 0.65 * log(1 + n) / log(1 + Double(vpeak))
            var c = (vSum[k * 3] / n, vSum[k * 3 + 1] / n, vSum[k * 3 + 2] / n)
            let m = max(c.0, c.1, c.2, 1)
            c = (c.0 / m * 255 * lvl, c.1 / m * 255 * lvl, c.2 / m * 255 * lvl)
            // Near-gray spots would vanish on the dark scope: lift them toward white.
            let gray = 255 * lvl * 0.85
            let mix = max(0, 1 - (max(c.0, c.1, c.2) - min(c.0, c.1, c.2)) / 60)
            vrgba[k * 4] = UInt8(min(255, c.0 + (gray - c.0) * mix)); vrgba[k * 4 + 1] = UInt8(min(255, c.1 + (gray - c.1) * mix)); vrgba[k * 4 + 2] = UInt8(min(255, c.2 + (gray - c.2) * mix)); vrgba[k * 4 + 3] = 255
        }
        return (image(rgba, W, pr), image(vrgba, vs, vs))
    }

    private static func image(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Numbers for agents

    struct ChannelStats: Codable, Equatable {
        /// 1st percentile, median, 99th percentile and mean, 0–255.
        var low: Double, median: Double, high: Double, mean: Double
    }
    struct ParadeStats: Codable, Equatable {
        var red: ChannelStats, green: ChannelStats, blue: ChannelStats
        var note: String
    }
    struct VectorStats: Codable, Equatable {
        /// Mean saturation (max − min of R, G, B, 0–1) over the frame.
        var meanSaturation: Double
        /// The frame's average colour direction: a cast toward this hue (HSV degrees, 0 = red) of this strength
        /// (0 = neutral; 0.02 is faint, 0.08 obvious).
        var castHue: Double, castName: String, castStrength: Double
        /// The hue holding most of the colour (saturation-weighted), and the share of colour in 12 sectors centred on 0, 30 … 330°.
        var dominantHue: Double, dominantName: String
        var hueShare: [Double]
        var note: String
    }

    /// Parade and vectorscope numbers from RGBA8 pixels (as `frameStats` reads them).
    static func stats(rgba px: [UInt8]) -> (ParadeStats, VectorStats) {
        let n = px.count / 4
        guard n > 0 else {
            let z = ChannelStats(low: 0, median: 0, high: 0, mean: 0)
            return (ParadeStats(red: z, green: z, blue: z, note: "empty frame"), VectorStats(meanSaturation: 0, castHue: 0, castName: "none", castStrength: 0, dominantHue: 0, dominantName: "none", hueShare: [Double](repeating: 0, count: 12), note: "empty frame"))
        }
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var sums = [0.0, 0.0, 0.0]
        var satSum = 0.0, cb = 0.0, cr = 0.0
        var share = [Double](repeating: 0, count: 12)
        for i in 0..<n {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            hist[0][r] += 1; hist[1][g] += 1; hist[2][b] += 1
            sums[0] += Double(r); sums[1] += Double(g); sums[2] += Double(b)
            let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
            let mx = max(rf, gf, bf), mn = min(rf, gf, bf), chroma = mx - mn
            satSum += chroma
            let s = ColorBalance.scope(r: rf, g: gf, b: bf)
            cb += s.cb; cr += s.cr
            if chroma > 0.02 {
                let h = ColorQualifier.hue(r: rf, g: gf, b: bf, chroma: chroma, max: mx)
                share[min(11, Int((h + 15).truncatingRemainder(dividingBy: 360) / 30))] += chroma
            }
        }
        func pct(_ h: [Int], _ q: Double) -> Double {
            let target = Int(Double(n - 1) * q)
            var acc = 0
            for (v, c) in h.enumerated() { acc += c; if acc > target { return Double(v) } }
            return 255
        }
        func ch(_ i: Int) -> ChannelStats { ChannelStats(low: pct(hist[i], 0.01), median: pct(hist[i], 0.5), high: pct(hist[i], 0.99), mean: (sums[i] / Double(n) * 10).rounded() / 10) }
        let red = ch(0), green = ch(1), blue = ch(2)
        var pnote = "Per channel 0–255: low = 1st percentile (black level), high = 99th (white level)."
        let lows = [red.low, green.low, blue.low], highs = [red.high, green.high, blue.high], meds = [red.median, green.median, blue.median]
        if (lows.max()! - lows.min()!) > 12 { pnote += " Black levels differ by \(Int(lows.max()! - lows.min()!)): the shadows carry a tint." }
        if (highs.max()! - highs.min()!) > 12 { pnote += " White levels differ by \(Int(highs.max()! - highs.min()!)): the highlights carry a tint." }
        if (meds.max()! - meds.min()!) > 15 { pnote += " Medians differ by \(Int(meds.max()! - meds.min()!)) (normal for a colourful frame; a cast if the scene is neutral)." }
        // The mean colour vector: its direction is the cast. Convert the (Cb, Cr) direction back to an HSV hue.
        cb /= Double(n); cr /= Double(n)
        let strength = (cb * cb + cr * cr).squareRoot()
        let castHue = hue(cb: cb, cr: cr)
        let total = share.reduce(0, +)
        let shares = share.map { total > 0 ? (($0 / total) * 1000).rounded() / 1000 : 0 }
        let domIdx = shares.enumerated().max { $0.element < $1.element }?.offset ?? 0
        let meanSat = satSum / Double(n)
        var vnote = "Hue in HSV degrees (0 red, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta); hueShare is the saturation-weighted share of 12 sectors 30° wide, centred on 0 (red), 30, 60 … 330."
        if strength > 0.03 { vnote += " The frame leans \(ColorBalance.name(ofHue: castHue)) overall." }
        if meanSat < 0.04 { vnote += " Nearly gray." }
        return (ParadeStats(red: red, green: green, blue: blue, note: pnote),
                VectorStats(meanSaturation: (meanSat * 1000).rounded() / 1000, castHue: castHue.rounded(), castName: strength < 0.005 ? "neutral" : ColorBalance.name(ofHue: castHue),
                            castStrength: (strength * 1000).rounded() / 1000, dominantHue: Double(domIdx * 30), dominantName: total > 0 ? ColorBalance.name(ofHue: Double(domIdx * 30)) : "none",
                            hueShare: shares, note: vnote))
    }

    /// The HSV hue of a vectorscope direction (Cb, Cr), by finding the pure hue at that angle.
    static func hue(cb: Double, cr: Double) -> Double {
        guard cb != 0 || cr != 0 else { return 0 }
        let a = atan2(cr, cb)
        var best = 0.0, bestD = Double.infinity
        for h in stride(from: 0.0, to: 360, by: 1) {
            let (r, g, b) = ColorBalance.pure(h), s = ColorBalance.scope(r: r, g: g, b: b)
            var d = abs(atan2(s.cr, s.cb) - a); if d > .pi { d = 2 * .pi - d }
            if d < bestD { bestD = d; best = h }
        }
        return best
    }

    /// A BGRA pixel buffer holding a CGImage (for the scope sampler, which reads the player's BGRA frames).
    static func pixelBuffer(_ img: CGImage) -> CVPixelBuffer? {
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(nil, img.width, img.height, kCVPixelFormatType_32BGRA, nil, &buf)
        guard let buf else { return nil }
        CVPixelBufferLockBaseAddress(buf, []); defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return buf
    }
}
