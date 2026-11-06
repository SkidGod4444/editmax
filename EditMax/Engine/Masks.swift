import Foundation
import CoreImage
import Vision

/// Mattes for grade layers: opaque gray images the size of the canvas, white where the layer applies. The parts of a
/// mask multiply (shape × colour qualifier × subject) and `invert` flips the result. Shapes are placed on the canvas
/// (fractions of the frame, y down); the qualifier keys the picture entering its layer; the subject matte comes from
/// the clip's own picture before any grade (with its input LUT), so grading cannot change what Vision sees.
enum Masks {
    static func matte(_ mask: GradeMask?, input: CIImage, pre: CIImage, clip: Clip, inputLut: String?, at t: Double, size: CGSize) -> CIImage? {
        guard let mask else { return nil }
        let frame = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: frame), white = CIImage(color: .white).cropped(to: frame)
        var m: CIImage?
        func and(_ x: CIImage) { m = m.map { x.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? x }
        if let s = mask.shape { and(shape(s, size: size)) }
        if let q = mask.qualifier { and(qualifier(q, input, size: size)) }
        if let s = mask.subject { and(SubjectMatte.matte(s, pre: pre, clip: clip, inputLut: inputLut, at: t, size: size) ?? black) }
        if mask.invert { m = (m ?? white).applyingFilter("CIColorInvert") }
        return m?.composited(over: black).cropped(to: frame)
    }

    /// A soft rectangle or ellipse. Feather is the width of the soft edge as a fraction of the frame height.
    static func shape(_ s: MaskShape, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let w = max(1, s.width * size.width), h = max(1, s.height * size.height)
        let soft = max(0, s.feather) * size.height
        var local: CIImage
        switch s.kind {
        case .ellipse:
            // A circle of radius 100 with the soft edge across it, stretched to the ellipse.
            let half = min(w, h) / 2, f = soft / max(1, half) * 100
            local = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: 0, y: 0), "inputRadius0": max(0, 100 - f / 2), "inputRadius1": 100 + f / 2 + 0.01,
                                                                    "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!
                .transformed(by: CGAffineTransform(scaleX: w / 200, y: h / 200))
        case .rectangle:
            let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            let pad = soft * 2 + 4
            local = CIImage(color: .white).cropped(to: r).composited(over: CIImage(color: .black).cropped(to: r.insetBy(dx: -pad, dy: -pad)))
            if soft > 0.5 { local = local.clampedToExtent().applyingGaussianBlur(sigma: soft / 2.5).cropped(to: r.insetBy(dx: -pad, dy: -pad)) }
        }
        let place = CGAffineTransform(rotationAngle: -s.rotation * .pi / 180)
            .concatenating(CGAffineTransform(translationX: s.centerX * size.width, y: (1 - s.centerY) * size.height))
        var out = local.transformed(by: place).composited(over: CIImage(color: .black)).cropped(to: frame)
        if s.invert { out = out.applyingFilter("CIColorInvert") }
        return out
    }

    nonisolated(unsafe) private static var cubes = BoundedCache<ColorQualifier, Data>(limit: 8)
    private static let lock = NSLock()
    static let qualifierCubeSize = 32

    /// The qualifier as a colour cube: each colour to its membership (gray), opaque.
    static func qualifierCube(_ q: ColorQualifier) -> Data {
        lock.lock(); if let d = cubes[q] { lock.unlock(); return d }; lock.unlock()
        let n = qualifierCubeSize
        var v = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let m = Float(q.membership(r: Double(ri) / Double(n - 1), g: Double(gi) / Double(n - 1), b: Double(bi) / Double(n - 1)))
            let o = ((bi * n + gi) * n + ri) * 4
            v[o] = m; v[o + 1] = m; v[o + 2] = m; v[o + 3] = 1
        } } }
        let d = v.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); cubes[q] = d; lock.unlock()
        return d
    }

    /// The colour selection of a picture, blurred by `blur` (px of a 1080-line frame); outside the picture is unselected.
    static func qualifier(_ q: ColorQualifier, _ img: CIImage, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let picture = img.cropped(to: frame)
        var m = picture.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": qualifierCubeSize, "inputCubeData": qualifierCube(q)])
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: picture])
            .composited(over: CIImage(color: .black)).cropped(to: frame)
        let sigma = q.blur * size.height / 1080
        if sigma > 0.3 { m = m.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: frame) }
        return m
    }
}

/// The AI subject matte. Vision runs on the clip's own picture (canvas space, before the grade, input LUT applied)
/// scaled to `analysisHeight`, once per source frame: results are memoized by asset, source time, transform, canvas
/// and kind, so scrubbing back, the before/after view and the export of an analysed frame reuse it. Preview and export
/// use the same matte (it is upscaled and feathered to the canvas), so what you see is what renders.
enum SubjectMatte {
    static let analysisHeight: CGFloat = 512
    nonisolated(unsafe) private static let cache: NSCache<NSString, CIImage> = { let c = NSCache<NSString, CIImage>(); c.countLimit = 120; return c }()
    /// Milliseconds of the last Vision run (for the report and the tool's note).
    nonisolated(unsafe) static var lastMilliseconds: Double = 0

    static func key(_ s: SubjectMask, clip: Clip, inputLut: String?, at t: Double, size: CGSize) -> String {
        let src = clip.sourceIn + clip.sourceOffset(at: t - clip.start)
        return "\(clip.assetID)|\(Int((src * 1000).rounded()))|\(clip.transform)|\(s.kind.rawValue)|\(Int(size.width))x\(Int(size.height))|\(inputLut ?? "")|\(clip.stabilization?.pathKey ?? "")"
    }

    static func matte(_ s: SubjectMask, pre: CIImage, clip: Clip, inputLut: String?, at t: Double, size: CGSize) -> CIImage? {
        let k = key(s, clip: clip, inputLut: inputLut, at: t, size: size) as NSString
        let raw: CIImage
        if let hit = cache.object(forKey: k) { raw = hit } else {
            guard let m = analyse(s.kind, pre: pre, inputLut: inputLut, size: size) else { return nil }
            cache.setObject(m, forKey: k)
            raw = m
        }
        let frame = CGRect(origin: .zero, size: size)
        let sigma = s.feather * size.height / 1080
        return sigma > 0.3 ? raw.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: frame) : raw
    }

    /// Runs Vision on the frame; the matte comes back canvas-sized, gray, opaque. nil when Vision fails.
    static func analyse(_ kind: SubjectMask.Kind, pre: CIImage, inputLut: String?, size: CGSize) -> CIImage? {
        let frame = CGRect(origin: .zero, size: size)
        var img = pre
        if let lut = inputLut, !lut.isEmpty { img = Looks.apply(img, key: lut, mix: 1) }
        let s = min(1, analysisHeight / max(1, size.height))
        let small = img.composited(over: CIImage(color: .black)).cropped(to: frame).transformed(by: CGAffineTransform(scaleX: s, y: s))
        let r = CGRect(x: 0, y: 0, width: (size.width * s).rounded(), height: (size.height * s).rounded())
        guard let cg = EditMaxCompositor.context.createCGImage(small, from: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        let start = Date()
        defer { lastMilliseconds = Date().timeIntervalSince(start) * 1000 }
        let handler = VNImageRequestHandler(cgImage: cg)
        var buffer: CVPixelBuffer?
        switch kind {
        case .person:
            let req = VNGeneratePersonSegmentationRequest()
            req.qualityLevel = .balanced
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            guard (try? handler.perform([req])) != nil else { return nil }
            buffer = req.results?.first?.pixelBuffer
        case .foreground:
            let req = VNGenerateForegroundInstanceMaskRequest()
            guard (try? handler.perform([req])) != nil else { return nil }
            guard let obs = req.results?.first else { return CIImage(color: .black).cropped(to: frame) }   // nothing found
            buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        }
        guard let buffer else { return CIImage(color: .black).cropped(to: frame) }
        let m = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        // One channel (person: 8-bit, foreground: float) to an opaque gray picture, rendered now at Vision's own size
        // (the cache holds small images and never Vision's buffer), then stretched to the canvas.
        let gray = m.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        guard let out = EditMaxCompositor.context.createCGImage(gray, from: m.extent, format: .RGBA8, colorSpace: nil) else { return nil }
        let matte = CIImage(cgImage: out, options: [.colorSpace: NSNull()])
        return matte.transformed(by: CGAffineTransform(scaleX: size.width / matte.extent.width, y: size.height / matte.extent.height)).cropped(to: frame)
    }
}
