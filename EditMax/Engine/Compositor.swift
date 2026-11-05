import AVFoundation
import CoreImage
import AppKit

// MARK: - What an instruction carries

/// One picture source: a composition track (video) or a still, with the clip that says how to draw it.
final class LayerSource {
    let trackID: CMPersistentTrackID        // kCMPersistentTrackID_Invalid for stills
    let still: CIImage?
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let clip: Clip
    /// Last time this source has media on its track (past `clip.end` when the next clip transitions over it).
    let effectiveEnd: Double
    /// When `clip.transitionIn` is live: the time it is done, and the clip it plays over (nil = from black).
    let transitionEnd: Double?
    let outgoingID: UUID?

    init(trackID: CMPersistentTrackID, still: CIImage?, naturalSize: CGSize, preferredTransform: CGAffineTransform, clip: Clip, effectiveEnd: Double, transitionEnd: Double?, outgoingID: UUID?) {
        self.trackID = trackID; self.still = still; self.naturalSize = naturalSize; self.preferredTransform = preferredTransform
        self.clip = clip; self.effectiveEnd = effectiveEnd; self.transitionEnd = transitionEnd; self.outgoingID = outgoingID
    }
}

/// What one project video track shows during an instruction: the clip playing and, while a transition runs, the clip going out.
struct TrackLayer {
    let current: LayerSource
    let outgoing: LayerSource?
}

/// A rasterized title: where it goes and when.
struct TextLayer {
    let text: TextOverlay
    let image: CIImage
    let size: CGSize
}

final class EditMaxInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [TrackLayer]      // top row of the timeline first
    let texts: [TextLayer]
    let renderSize: CGSize

    init(timeRange: CMTimeRange, layers: [TrackLayer], texts: [TextLayer], renderSize: CGSize, requiredTrackIDs: [CMPersistentTrackID]) {
        self.timeRange = timeRange; self.layers = layers; self.texts = texts; self.renderSize = renderSize
        self.requiredSourceTrackIDs = requiredTrackIDs.isEmpty ? nil : requiredTrackIDs.map { NSNumber(value: $0) }
    }
}

// MARK: - The compositor

/// Draws every frame of the preview, the export and `capture_frame`: picture transforms and crops, color correction,
/// fades, transitions, stills and titles, all through Core Image on the GPU. One code path, so what plays is what exports.
final class EditMaxCompositor: NSObject, AVVideoCompositing {
    /// No color management: pixel values pass through untouched, so a frame that is not graded exports exactly as it
    /// came in (with management, Core Image lifted shadows by treating decoded video and PNGs as linear).
    static let context = CIContext(options: [.cacheIntermediates: false, .name: "EditMax", .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let queue = DispatchQueue(label: "io.openhorizon.editmax.compositor", qos: .userInteractive)
    private static let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                               kCVPixelBufferMetalCompatibilityKey as String: true]
    var sourcePixelBufferAttributes: [String: Any]? { Self.attrs }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { Self.attrs }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard let inst = request.videoCompositionInstruction as? EditMaxInstruction else {
                request.finish(with: EditError.invalid("unknown composition instruction")); return
            }
            guard let out = request.renderContext.newPixelBuffer() else { request.finish(with: EditError.invalid("no pixel buffer")); return }
            let image = FrameRenderer.frame(inst, at: request.compositionTime.seconds) { id in request.sourceFrame(byTrackID: id) }
            Self.context.render(image, to: out, bounds: CGRect(origin: .zero, size: inst.renderSize), colorSpace: nil)
            request.finish(withComposedVideoFrame: out)
        }
    }
}

/// Pure frame maths on CIImages (origin bottom-left, as Core Image has it). Also used by the still-frame capture.
enum FrameRenderer {
    static func frame(_ inst: EditMaxInstruction, at t: Double, source: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        let size = inst.renderSize
        let canvasRect = CGRect(origin: .zero, size: size)
        var canvas = CIImage(color: .black).cropped(to: canvasRect)
        for layer in inst.layers.reversed() {   // bottom row first; the top row is drawn last and covers
            guard let img = picture(layer, at: t, size: size, source: source) else { continue }
            canvas = img.composited(over: canvas)
        }
        for tl in inst.texts where tl.text.start <= t && t < tl.text.end {
            let origin = CGPoint(x: size.width * tl.text.x - tl.size.width / 2, y: size.height * (1 - tl.text.y) - tl.size.height / 2)
            canvas = tl.image.transformed(by: CGAffineTransform(translationX: origin.x.rounded(), y: origin.y.rounded())).composited(over: canvas)
        }
        return canvas.cropped(to: canvasRect)
    }

    private static func picture(_ layer: TrackLayer, at t: Double, size: CGSize, source: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage? {
        let cur = render(layer.current, at: t, size: size, source: source)
        if let tr = layer.current.clip.transitionIn, let tEnd = layer.current.transitionEnd, t < tEnd {
            let p = max(0, min(1, (t - layer.current.clip.start) / max(0.01, tEnd - layer.current.clip.start)))
            let out = layer.outgoing.flatMap { render($0, at: t, size: size, source: source) }
            return blend(tr.kind, from: out, to: cur, progress: p, size: size)
        }
        return cur
    }

    /// The clip's picture at `t`: oriented, cropped, fitted, transformed, color-corrected, faded.
    private static func render(_ src: LayerSource, at t: Double, size: CGSize, source: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage? {
        var img: CIImage
        if let still = src.still { img = still }
        else {
            guard let buf = source(src.trackID) else { return nil }
            img = oriented(CIImage(cvPixelBuffer: buf, options: [.colorSpace: NSNull()]), natural: src.naturalSize, preferred: src.preferredTransform)
        }
        let clip = src.clip, local = t - clip.start, tf = clip.transform(at: local)
        let w = img.extent.width, h = img.extent.height
        guard w > 0, h > 0 else { return nil }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        if tf.cropLeft + tf.cropRight + tf.cropTop + tf.cropBottom > 0 {
            let r = CGRect(x: w * tf.cropLeft, y: h * tf.cropBottom, width: w * max(0.01, 1 - tf.cropLeft - tf.cropRight), height: h * max(0.01, 1 - tf.cropTop - tf.cropBottom))
            img = img.cropped(to: r)
        }
        // Fit the (uncropped) picture into the frame, then the user's scale, rotation and offset about the frame center.
        let fit = min(size.width / w, size.height / h)
        var T = CGAffineTransform(translationX: -w / 2, y: -h / 2)
        T = T.concatenating(CGAffineTransform(scaleX: fit * tf.scale, y: fit * tf.scale))
        if tf.rotation != 0 { T = T.concatenating(CGAffineTransform(rotationAngle: -tf.rotation * .pi / 180)) }
        T = T.concatenating(CGAffineTransform(translationX: size.width / 2 + tf.x * size.width, y: size.height / 2 - tf.y * size.height))
        img = img.transformed(by: T)
        let color = clip.color(at: local)
        if !color.isIdentity { img = graded(img, color) }
        let alpha = clip.opacity(at: local) * fade(clip, at: t)
        if alpha < 1 { img = withAlpha(img, alpha) }
        return img.cropped(to: CGRect(origin: .zero, size: size))
    }

    static func graded(_ img: CIImage, _ c: ClipColor) -> CIImage {
        var out = img
        if c.exposure != 0 { out = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": c.exposure]) }
        if c.contrast != 1 || c.saturation != 1 {
            out = out.applyingFilter("CIColorControls", parameters: ["inputContrast": c.contrast, "inputSaturation": c.saturation, "inputBrightness": 0])
        }
        if c.temperature != 0 || c.tint != 0 {
            // Core Image moves the picture's neutral from `inputNeutral` to `inputTargetNeutral`: a lower target kelvin warms it.
            out = out.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                                                                           "inputTargetNeutral": CIVector(x: 6500 - c.temperature * 25, y: c.tint)])
        }
        if c.shadows != 0 || c.midtones != 0 || c.highlights != 0 {
            // A five-point tone curve: the three inner points move by up to ±0.15.
            let k = 0.15
            let p = { (x: Double, d: Double) in CIVector(x: x, y: max(0, min(1, x + d * k))) }
            out = out.applyingFilter("CIToneCurve", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": p(0.25, c.shadows), "inputPoint2": p(0.5, c.midtones),
                                                                 "inputPoint3": p(0.75, c.highlights), "inputPoint4": CIVector(x: 1, y: 1)])
        }
        if c.vibrance != 0 { out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": c.vibrance]) }
        if let lut = c.lut, !lut.isEmpty { out = Looks.apply(out, key: lut, mix: c.lutMix) }
        return out
    }

    /// Fade factor inside [start, end]; 1 outside (an outgoing clip under a transition keeps its picture).
    private static func fade(_ clip: Clip, at t: Double) -> Double {
        var f = 1.0
        if clip.fadeIn > 0, t < clip.start + clip.fadeIn { f = min(f, max(0, (t - clip.start) / clip.fadeIn)) }
        if clip.fadeOut > 0, t > clip.end - clip.fadeOut, t <= clip.end { f = min(f, max(0, (clip.end - t) / clip.fadeOut)) }
        return f
    }

    /// Uniform multiply of all four channels (the pixels are premultiplied, so RGB scale with alpha).
    static func withAlpha(_ img: CIImage, _ a: Double) -> CIImage {
        let a = CGFloat(max(0, min(1, a)))
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }

    private static func blend(_ kind: Transition.Kind, from: CIImage?, to: CIImage?, progress p: Double, size: CGSize) -> CIImage? {
        let rect = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: rect)
        let a = from ?? black, b = to ?? black
        switch kind {
        case .crossDissolve:
            return withAlpha(b, p).composited(over: a)
        case .dipToBlack:
            return p < 0.5 ? withAlpha(a, 1 - 2 * p).composited(over: black) : withAlpha(b, 2 * p - 1).composited(over: black)
        case .wipeRight:
            return b.cropped(to: CGRect(x: 0, y: 0, width: size.width * p, height: size.height)).composited(over: a)
        case .wipeLeft:
            return b.cropped(to: CGRect(x: size.width * (1 - p), y: 0, width: size.width * p, height: size.height)).composited(over: a)
        }
    }

    /// Applies a track's preferred transform (phone rotations) the way AVFoundation means it: in a top-left space.
    static func oriented(_ img: CIImage, natural: CGSize, preferred: CGAffineTransform) -> CIImage {
        guard preferred != .identity else { return img }
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let flipN = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: natural.height)
        let flipR = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.height)
        return img.transformed(by: flipN.concatenating(preferred).concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)).concatenating(flipR))
    }
}

/// Loads a still as untagged sRGB pixels for the compositor (a P3 photo is converted first, then its values pass through).
enum StillLoader {
    static func load(_ url: URL) -> CIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let upright: CGImage
        if orientation == 1 { upright = raw }
        else {
            let ci = CIImage(cgImage: raw).oriented(CGImagePropertyOrientation(rawValue: orientation) ?? .up)
            guard let cg = CIContext(options: nil).createCGImage(ci, from: ci.extent) else { return nil }
            upright = cg
        }
        let w = upright.width, h = upright.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(upright, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let srgb = ctx.makeImage() else { return nil }
        return CIImage(cgImage: srgb, options: [.colorSpace: NSNull()])
    }
}

/// A tiny black movie used as the base video track, so a timeline of stills and titles alone still renders and exports.
enum BlankVideo {
    static let size = CGSize(width: 64, height: 36)
    static func url() throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax")
        let url = dir.appendingPathComponent("blank.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EditError.invalid("blank video") }
        writer.startSession(atSourceTime: .zero)
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buf)
        guard let buf else { throw EditError.invalid("blank video buffer") }
        CVPixelBufferLockBaseAddress(buf, []); memset(CVPixelBufferGetBaseAddress(buf), 0, CVPixelBufferGetDataSize(buf)); CVPixelBufferUnlockBaseAddress(buf, [])
        for i in 0..<2 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 1))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if let e = writer.error { throw e }
        return url
    }
}
