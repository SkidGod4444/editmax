import Foundation
import CoreImage
import AppKit

/// The green-screen keyer. One 3D LUT (`CIColorCube`, 64³) maps every source colour to its kept colour and alpha:
///
/// - Colours go to BT.709 luma + chroma (Cb, Cr). The key colour's chroma gives a direction `u` and a length `sat`.
/// - A pixel's "screenness" is `m = s · (along − across) / sat`: `along` is its chroma along `u`, `across` the part at
///   right angles to it (so yellows and cyans next to a green are not taken), and `s` lifts pixels darker than the key
///   by up to 2× (shadows on the screen are screen too; a brighter screen already has more chroma than the key).
/// - Alpha = 1 − smoothstep(lo, hi, m): tolerance lowers `hi` (more is keyed), softness widens the ramp below it.
/// - Spill: the chroma along `u` (less a little of `across`) is taken out of what stays, keeping luma, so edges and
///   skin lose the screen's cast without going dark.
///
/// Matte cleanup, when asked for, works on the alpha as a grey image: morphology minimum (shrink) or maximum (grow),
/// then a Gaussian blur, applied back with `CIBlendWithMask` over the opaque, despilled colour.
///
/// The cube's domain is 0…1, so HDR values above 1 are clipped in a keyed clip.
enum Keyer {
    static let dimension = 64

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cubes: [String: Data] = [:]
    nonisolated(unsafe) private static var order: [String] = []

    /// The key colour as 0…1 RGB.
    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }
    static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        let c = { (x: Double) in Int((max(0, min(1, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// BT.709 luma and chroma (Cb, Cr in −0.5…0.5).
    static func ycc(_ r: Double, _ g: Double, _ b: Double) -> (y: Double, cb: Double, cr: Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (y, (b - y) / 1.8556, (r - y) / 1.5748)
    }

    /// How saturated a colour is (chroma length); a key colour needs some, or nothing separates it from greys.
    static func saturation(_ hex: String) -> Double? { rgb(hex).map { let c = ycc($0.0, $0.1, $0.2); return hypot(c.cb, c.cr) } }
    static let minimumSaturation = 0.05

    /// The screenness `m` of a colour for a key (see the type's notes); exposed for tests and the matte stats.
    static func screenness(_ r: Double, _ g: Double, _ b: Double, key: (y: Double, ux: Double, uy: Double, sat: Double)) -> (m: Double, along: Double, across: Double) {
        let c = ycc(r, g, b)
        let along = c.cb * key.ux + c.cr * key.uy
        let across = abs(-c.cb * key.uy + c.cr * key.ux)
        let s = min(2, max(1, key.y / max(c.y, 1e-4)))
        return (s * (along - across) / key.sat, along, across)
    }

    /// The thresholds on `m`: fully keyed above `hi`, fully kept below `lo`.
    static func thresholds(_ k: ChromaKey) -> (lo: Double, hi: Double) {
        let hi = 1 - 0.8 * max(0, min(1, k.tolerance))
        return (max(0, hi - (0.02 + 0.6 * max(0, min(1, k.softness)))), hi)
    }

    /// The cube for a key: (kept colour, alpha) per entry, unpremultiplied (Core Image premultiplies the result).
    /// `opaque` gives the despilled colour with alpha 1, for the matte-cleanup path. Cached (a few keys at a time).
    static func cube(_ k: ChromaKey, opaque: Bool) -> Data? {
        guard let (kr, kg, kb) = rgb(k.colorHex) else { return nil }
        let id = "\(k.colorHex)|\(k.tolerance)|\(k.softness)|\(k.spill)|\(opaque)"
        lock.lock(); defer { lock.unlock() }
        if let d = cubes[id] { return d }
        let kc = ycc(kr, kg, kb)
        let sat = hypot(kc.cb, kc.cr)
        guard sat >= minimumSaturation else { return nil }
        let key = (y: kc.y, ux: kc.cb / sat, uy: kc.cr / sat, sat: sat)
        let (lo, hi) = thresholds(k)
        let spill = max(0, min(1, k.spill))
        let n = dimension
        var f = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        let step = 1 / Double(n - 1)
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let r = Double(ri) * step, g = Double(gi) * step, b = Double(bi) * step
            let c = ycc(r, g, b)
            let along = c.cb * key.ux + c.cr * key.uy
            let across = abs(-c.cb * key.uy + c.cr * key.ux)
            var alpha = 1.0
            if !opaque {
                let s = min(2, max(1, key.y / max(c.y, 1e-4)))
                let m = s * (along - across) / key.sat
                alpha = 1 - smooth(lo, hi, m)
            }
            var (or, og, ob) = (r, g, b)
            let d = spill * max(0, along - 0.35 * across)
            if d > 0 {
                let cb = c.cb - d * key.ux, cr = c.cr - d * key.uy
                or = c.y + 1.5748 * cr; ob = c.y + 1.8556 * cb
                og = (c.y - 0.2126 * or - 0.0722 * ob) / 0.7152
            }
            f[i] = Float(max(0, min(1, or))); f[i + 1] = Float(max(0, min(1, og))); f[i + 2] = Float(max(0, min(1, ob))); f[i + 3] = Float(alpha)
            i += 4
        } } }
        let data = f.withUnsafeBufferPointer { Data(buffer: $0) }
        cubes[id] = data; order.append(id)
        if order.count > 8 { cubes[order.removeFirst()] = nil }
        return data
    }

    static func smooth(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
        guard hi > lo else { return x >= hi ? 1 : 0 }
        let u = max(0, min(1, (x - lo) / (hi - lo)))
        return u * u * (3 - 2 * u)
    }

    /// The keyed picture (premultiplied alpha): screen transparent, the rest despilled.
    static func apply(_ img: CIImage, _ k: ChromaKey) -> CIImage {
        guard let data = cube(k, opaque: false) else { return img }
        let keyed = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": data])
        guard k.shrink != 0 || k.edgeBlur > 0, let opaque = cube(k, opaque: true) else { return keyed }
        let m = cleaned(alphaMatte(keyed), k, extent: img.extent)
        let colour = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": opaque])
        return colour.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m]).cropped(to: img.extent)
    }

    /// The matte as an opaque grey picture: white = kept, black = keyed out (after shrink/grow and edge blur).
    static func matte(_ img: CIImage, _ k: ChromaKey) -> CIImage {
        guard let data = cube(k, opaque: false) else { return CIImage(color: .white).cropped(to: img.extent) }
        let keyed = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": data])
        return cleaned(alphaMatte(keyed), k, extent: img.extent)
    }

    /// Alpha → grey (CIColorMatrix unpremultiplies first, which leaves alpha itself alone).
    private static func alphaMatte(_ img: CIImage) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                                                         "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                         "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).cropped(to: img.extent)   // the bias makes it endless
    }

    /// Shrink (+) / grow (−) and blur, in pixels of a 1080-line picture scaled to this one.
    private static func cleaned(_ matte: CIImage, _ k: ChromaKey, extent: CGRect) -> CIImage {
        let scale = max(0.25, extent.height / 1080)
        var m = matte
        if k.shrink != 0 {
            let r = abs(k.shrink) * scale
            m = m.clampedToExtent().applyingFilter(k.shrink > 0 ? "CIMorphologyMinimum" : "CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r]).cropped(to: extent)
        }
        if k.edgeBlur > 0 {
            m = m.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: k.edgeBlur * scale]).cropped(to: extent)
        }
        return m
    }

    // MARK: Auto-detect

    struct Detection { var hex: String; var confidence: Double }

    /// The screen colour from a frame's edges: the most common saturated hue in the outer tenth of each side, averaged.
    /// Nil when the edges hold no saturated colour at all. `confidence` is the share of edge pixels with that hue.
    static func detect(_ image: CGImage) -> Detection? {
        let w = 160, h = max(2, Int((Double(w) * Double(image.height) / Double(max(1, image.width))).rounded()))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bx = max(1, w / 10), by = max(1, h / 10)
        let bins = 36
        var count = [Int](repeating: 0, count: bins), sums = [[Double]](repeating: [0, 0, 0], count: bins)
        var total = 0
        for yy in 0..<h { for xx in 0..<w where xx < bx || xx >= w - bx || yy < by || yy >= h - by {
            let i = (yy * w + xx) * 4
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            total += 1
            let c = ycc(r, g, b)
            guard hypot(c.cb, c.cr) > 0.06 else { continue }
            let bin = Int(((atan2(c.cr, c.cb) + .pi) / (2 * .pi) * Double(bins)).rounded(.down)) % bins
            count[bin] += 1; sums[bin][0] += r; sums[bin][1] += g; sums[bin][2] += b
        } }
        guard total > 0 else { return nil }
        var best = -1, bestCount = 0
        for b in 0..<bins {
            let c = count[(b + bins - 1) % bins] + count[b] + count[(b + 1) % bins]
            if c > bestCount { bestCount = c; best = b }
        }
        guard best >= 0, bestCount > 0 else { return nil }
        var s = [0.0, 0.0, 0.0]
        for b in [(best + bins - 1) % bins, best, (best + 1) % bins] { for k in 0..<3 { s[k] += sums[b][k] } }
        let n = Double(bestCount)
        return Detection(hex: hex(s[0] / n, s[1] / n, s[2] / n), confidence: Double(bestCount) / Double(total))
    }

    // MARK: Matte numbers

    struct MatteStats: Codable { var keyedPercent: Double, edgePercent: Double, keptPercent: Double }

    /// How much of a matte is keyed out (under 2 %), edge (between) and kept (over 98 %), from a 160-px sample.
    static func stats(_ matte: CGImage) -> MatteStats {
        let w = 160, h = max(2, Int((Double(w) * Double(matte.height) / Double(max(1, matte.width))).rounded()))
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return MatteStats(keyedPercent: 0, edgePercent: 0, keptPercent: 100)
        }
        ctx.draw(matte, in: CGRect(x: 0, y: 0, width: w, height: h))
        var keyed = 0, kept = 0
        for v in px { if v <= 5 { keyed += 1 } else if v >= 250 { kept += 1 } }
        let n = Double(px.count)
        let pct = { (k: Int) in (Double(k) / n * 1000).rounded() / 10 }
        return MatteStats(keyedPercent: pct(keyed), edgePercent: pct(px.count - keyed - kept), keptPercent: pct(kept))
    }
}
