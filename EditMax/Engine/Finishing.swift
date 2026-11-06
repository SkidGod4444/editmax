import Foundation
import CoreImage

/// Per-clip finishing after the grade and the grade layers, in this order: noise reduction → sharpen → glow →
/// vignette → grain. Built-in Core Image filters only. Sizes are pixels of a 1080-line frame, scaled with the canvas,
/// so a look holds at any project size. Everything stays inside the clip's picture (a scaled-down clip's frame edge
/// is its own edge, not the canvas's) and keeps the picture's alpha.
enum Finishing {
    static func apply(_ img: CIImage, _ f: ClipFinish, at t: Double, size: CGSize) -> CIImage {
        let area = img.extent.intersection(CGRect(origin: .zero, size: size))
        guard !area.isNull, area.width >= 2, area.height >= 2 else { return img }
        let k = size.height / 1080
        var out = img.cropped(to: area)
        if f.noiseReduction > 0 {
            // A 3×3 median (edge-keeping), then Core Image's luminance noise reduction, mixed in by the amount.
            let clean = out.clampedToExtent().applyingFilter("CIMedianFilter")
                .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02 + 0.06 * f.noiseReduction, "inputSharpness": 0.4 * (1 - 0.6 * f.noiseReduction)]).cropped(to: area)
            out = f.noiseReduction >= 0.999 ? clean : clean.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: clean, kCIInputImageKey: out, kCIInputTimeKey: f.noiseReduction]).cropped(to: area)
        }
        if f.sharpen > 0 {
            out = out.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 2 * f.sharpen, "inputRadius": max(0.25, f.sharpenRadius * k)]).cropped(to: area)
        }
        if f.glow > 0 { out = glow(out, amount: f.glow, radius: f.glowRadius * k, threshold: f.glowThreshold, area: area) }
        if f.vignette != 0 { out = vignette(out, amount: f.vignette, size: f.vignetteSize, softness: f.vignetteSoftness, area: area) }
        if f.grain > 0 { out = grain(out, amount: f.grain, size: f.grainSize * k, at: t, area: area) }
        return out.cropped(to: area)
    }

    /// What is brighter than the threshold, blurred and screened back over the picture.
    static func glow(_ img: CIImage, amount: Double, radius: Double, threshold th: Double, area: CGRect) -> CIImage {
        let s = 1 / max(0.02, 1 - th)
        let bright = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: -th * s, y: -th * s, z: -th * s, w: 0)])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 4, y: 4, z: 4, w: 1)])
        let blurred = bright.clampedToExtent().applyingGaussianBlur(sigma: max(0.5, radius * 0.6)).cropped(to: area)
        let scaled = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        return scaled.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: area)
    }

    /// An elliptical falloff fitted to the picture: + blends the edges toward black, − toward white.
    static func vignette(_ img: CIImage, amount: Double, size: Double, softness: Double, area: CGRect) -> CIImage {
        let mid = size * 2.0.squareRoot()   // in half-picture units, the corners are at √2
        let r0 = mid * (1 - min(0.95, softness)), r1 = max(r0 + 0.01, mid * (1 + softness))
        let a = min(1, abs(amount))
        let unit = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: 0, y: 0), "inputRadius0": r0 * 100, "inputRadius1": r1 * 100,
                                                                 "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: a, green: a, blue: a)])!.outputImage!
        let mask = unit.transformed(by: CGAffineTransform(scaleX: area.width / 200, y: area.height / 200).concatenating(CGAffineTransform(translationX: area.midX, y: area.midY))).cropped(to: area)
        let tone = amount > 0 ? CIColor(red: 0, green: 0, blue: 0) : CIColor(red: 1, green: 1, blue: 1)
        let target = CIImage(color: tone).cropped(to: area).applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: img])
        return target.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask]).cropped(to: area)
    }

    /// Grain strength by brightness y: 0.25 + 3y(1 − y), 1 at mid-gray and 0.25 at black and white (RGB float triplets).
    static let grainWeight: Data = {
        let n = 256
        var v = [Float](); v.reserveCapacity(n * 3)
        for i in 0..<n { let y = Double(i) / Double(n - 1), w = Float(0.25 + 3 * y * (1 - y)); v += [w, w, w] }
        return v.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    /// Monochrome film grain: zero-mean noise added to the picture (linear light around 0.5), strongest in the mid-tones
    /// and about a quarter as strong in deep shadows and bright highlights, like film. The pattern is fixed per frame
    /// (seeded by the timeline time), so a paused frame and an export of that frame show the same grain.
    static func grain(_ img: CIImage, amount: Double, size: Double, at t: Double, area: CGRect) -> CIImage {
        var seed = UInt64(max(0, (t * 1000).rounded())) &* 0x9E37_79B9_7F4A_7C15
        seed ^= seed >> 29
        let ox = Double(seed % 4096), oy = Double((seed >> 12) % 4096)
        let s = max(1, size)   // never finer than a pixel: sub-pixel noise would average itself away on a small canvas
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(translationX: -ox, y: -oy).concatenating(CGAffineTransform(scaleX: s, y: s)))
            .cropped(to: area).settingAlphaOne(in: area)
        // Two independent channels averaged (a softer, triangular spread), centred on 0.5: linear light adds 2·(s − 0.5).
        let a = min(1, amount) / 4
        let gray = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: a, z: 0, w: 0), "inputGVector": CIVector(x: a, y: a, z: 0, w: 0), "inputBVector": CIVector(x: a, y: a, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0.5 - a, y: 0.5 - a, z: 0.5 - a, w: 1)])
        let grained = gray.applyingFilter("CILinearLightBlendMode", parameters: [kCIInputBackgroundImageKey: img])
        // Weight by brightness: 1 in the mid-tones, 0.25 at black and white.
        let w = ColorBalance.weights
        let weight = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: w.r, y: w.g, z: w.b, w: 0), "inputGVector": CIVector(x: w.r, y: w.g, z: w.b, w: 0), "inputBVector": CIVector(x: w.r, y: w.g, z: w.b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .applyingFilter("CIColorCurves", parameters: ["inputCurvesData": grainWeight, "inputCurvesDomain": CIVector(x: 0, y: 1)])
        let mixed = grained.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: weight])
        return mixed.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: area)
    }
}
