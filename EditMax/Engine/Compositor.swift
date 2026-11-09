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
    var output: ColorManagement.Output = .passthrough   // HDR projects (ColorManagement.swift)

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
    var raster: TitleRaster? = nil   // animated titles and lower thirds (TitleAnimation.swift)

    /// The same title centred on `p` (normalized, y down): its picture does not depend on where it sits.
    func moved(to p: CGPoint) -> TextLayer {
        var t = text; t.x = p.x; t.y = p.y
        return TextLayer(text: t, image: image, size: size, raster: raster)
    }
}

/// Where titles being dragged on the viewer are drawn (normalized centres, y down), before the move is an edit. The
/// player draws a paused frame again at once, while a rebuild after an edit takes a few hundred milliseconds, so this is
/// what lets a title follow the pointer. A position stays until a build that has it is on screen (`settle`), so letting
/// go never flashes the title back to where it was. Preview only: exports and the agent's frame tools never read it.
final class LiveTextPositions: @unchecked Sendable {
    static let shared = LiveTextPositions()
    private let lock = NSLock()
    private var _moves: [UUID: CGPoint] = [:]
    var moves: [UUID: CGPoint] { lock.withLock { _moves } }
    func set(_ moves: [UUID: CGPoint]) { lock.withLock { _moves = moves } }
    func clear() { lock.withLock { _moves = [:] } }
    /// Drops the positions a freshly built `texts` already has (or whose text is gone).
    func settle(_ texts: [TextOverlay]) {
        lock.withLock {
            _moves = _moves.filter { id, p in
                guard let t = texts.first(where: { $0.id == id }) else { return false }
                return abs(t.x - p.x) > 1e-6 || abs(t.y - p.y) > 1e-6
            }
        }
    }
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
    var output: ColorManagement.Output = .passthrough   // HDR projects (ColorManagement.swift)

    init(timeRange: CMTimeRange, layers: [TrackLayer], texts: [TextLayer], renderSize: CGSize, requiredTrackIDs: [CMPersistentTrackID]) {
        self.timeRange = timeRange; self.layers = layers; self.texts = texts; self.renderSize = renderSize
        self.requiredSourceTrackIDs = requiredTrackIDs.isEmpty ? nil : requiredTrackIDs.map { NSNumber(value: $0) }
    }
}

// MARK: - The compositor

/// Draws every frame of the preview, the export and `capture_frame`: picture transforms and crops, color correction,
/// fades, transitions, stills and titles, all through Core Image on the GPU. One code path, so what plays is what exports.
class EditMaxCompositor: NSObject, AVVideoCompositing {
    /// No color management: pixel values pass through untouched, so a frame that is not graded exports as it came in,
    /// within decoder rounding (VideoToolbox's YUV → half-float conversion differs from its YUV → BGRA one by up to 2
    /// levels on saturated colors; with management, Core Image lifted shadows by treating decoded video and PNGs as linear).
    static let context = CIContext(options: [.cacheIntermediates: false, .name: "EditMax", .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let queue = DispatchQueue(label: "io.openhorizon.editmax.compositor", qos: .userInteractive)
    /// Source pixel formats seen so far (logged once each, so the decode path can be checked from the log).
    /// Every source pixel format seen, logged once. Several compositors render at once (preview, export, capture_frame),
    /// so the set sits behind a lock: unguarded, the static Set corrupted under that race and aborted the app.
    nonisolated(unsafe) private static var loggedFormats = Set<OSType>()
    private static let formatLock = NSLock()
    private static func noteFormat(_ t: OSType) {
        formatLock.lock(); defer { formatLock.unlock() }
        guard loggedFormats.insert(t).inserted else { return }
        let s = String(bytes: [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)], encoding: .ascii) ?? "?"
        DebugLog.event("source-pixel-format", ["fourcc": s, "code": "\(t)"])
    }
    private static let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                               kCVPixelBufferMetalCompatibilityKey as String: true]
    /// Sources are decoded to 16-bit half floats, so 10-bit footage (D-Log and other log profiles) keeps its precision
    /// through the input LUT and the grade instead of being cut to 8 bits first. Output stays BGRA: the export encoder,
    /// the player and the scopes read 8-bit frames.
    private static let sourceAttrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                                                     kCVPixelBufferMetalCompatibilityKey as String: true]
    var sourcePixelBufferAttributes: [String: Any]? { Self.sourceAttrs }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { Self.attrs }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard let inst = request.videoCompositionInstruction as? EditMaxInstruction else {
                request.finish(with: EditError.invalid("unknown composition instruction")); return
            }
            guard let out = request.renderContext.newPixelBuffer() else { request.finish(with: EditError.invalid("no pixel buffer")); return }
            let image = self.image(inst, at: request.compositionTime.seconds) { id in
                let f = request.sourceFrame(byTrackID: id)
                if let f { Self.noteFormat(CVPixelBufferGetPixelFormatType(f)) }
                return f
            }
            if !ColorManagement.render(image, to: out, inst) { Self.context.render(image, to: out, bounds: CGRect(origin: .zero, size: inst.renderSize), colorSpace: nil) }
            request.finish(withComposedVideoFrame: out)
        }
    }

    /// The composed frame; the preview compositor overrides it for the before/after view.
    func image(_ inst: EditMaxInstruction, at t: Double, source: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        FrameRenderer.frame(inst, at: t, source: source)
    }
}

/// Before/after view of the preview: off, a split wipe (before on the left of the divider, after on the right) or the
/// whole picture before. "Before" means the clip's corrections and look bypassed; the input (conversion) LUT stays, as do
/// cuts, transforms, transitions and titles, so log footage compares against its converted baseline, not raw log. Preview only: exports and the agent's frame tools always see the graded picture.
enum CompareMode: String, CaseIterable { case off, split, before }

final class CompareState: @unchecked Sendable {
    static let shared = CompareState()
    private let lock = NSLock()
    private var _mode: CompareMode = .off
    private var _split: Double = 0.5
    var mode: CompareMode { get { lock.withLock { _mode } } set { lock.withLock { _mode = newValue } } }
    var split: Double { get { lock.withLock { _split } } set { lock.withLock { _split = max(0, min(1, newValue)) } } }
}

/// The player's compositor: the same drawing, plus the before/after view.
class EditMaxPreviewCompositor: EditMaxCompositor {
    override func image(_ inst: EditMaxInstruction, at t: Double, source: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        let mode = CompareState.shared.mode
        let moved = LiveTextPositions.shared.moves
        guard mode != .off else { return FrameRenderer.frame(inst, at: t, moved: moved, source: source) }
        let before = FrameRenderer.frame(inst, at: t, bypassColor: true, moved: moved, source: source)
        if mode == .before { return before }
        let after = FrameRenderer.frame(inst, at: t, moved: moved, source: source)
        let size = inst.renderSize, x = (size.width * CompareState.shared.split).rounded()
        let left = before.cropped(to: CGRect(x: 0, y: 0, width: x, height: size.height))
        let right = after.cropped(to: CGRect(x: x, y: 0, width: size.width - x, height: size.height))
        let line = CIImage(color: .white).cropped(to: CGRect(x: x - 1, y: 0, width: 2, height: size.height))
        return line.composited(over: left.composited(over: right))
    }
}

/// The compositor for the 10-bit HEVC export: the same drawing, but it hands the encoder 16-bit half-float frames so
/// the grade is not cut to 8 bits on the way out. A subclass, because the preview's compositor keeps running meanwhile.
class EditMaxCompositor10: EditMaxCompositor {
    private static let attrs10: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                                                 kCVPixelBufferMetalCompatibilityKey as String: true]
    override var requiredPixelBufferAttributesForRenderContext: [String: Any] { Self.attrs10 }
}

/// Pure frame maths on CIImages (origin bottom-left, as Core Image has it). Also used by the still-frame capture.
enum FrameRenderer {
    static func frame(_ inst: EditMaxInstruction, at t: Double, bypassColor: Bool = false, moved: [UUID: CGPoint] = [:],
                      source: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        let size = inst.renderSize
        let canvasRect = CGRect(origin: .zero, size: size)
        var canvas = CIImage(color: .black).cropped(to: canvasRect)
        for layer in inst.layers.reversed() {   // bottom row first; the top row is drawn last and covers
            guard let img = picture(layer, at: t, size: size, bypassColor: bypassColor, source: source) else { continue }
            canvas = Effects.composite(img, over: canvas, mode: layer.current.clip.effects.blend)   // blend modes (EffectsRender.swift)
        }
        for var tl in inst.texts where tl.text.start <= t && t < tl.text.end {
            if let p = moved[tl.text.id] { tl = tl.moved(to: p) }   // dragged on the viewer (LiveTextPositions)
            if let drawn = TitleAnimator.draw(tl, at: t, size: size, over: canvas) { canvas = drawn; continue }   // animated titles (TitleAnimation.swift)
            let origin = CGPoint(x: size.width * tl.text.x - tl.size.width / 2, y: size.height * (1 - tl.text.y) - tl.size.height / 2)
            canvas = tl.image.transformed(by: CGAffineTransform(translationX: origin.x.rounded(), y: origin.y.rounded())).composited(over: canvas)
        }
        return canvas.cropped(to: canvasRect)
    }

    private static func picture(_ layer: TrackLayer, at t: Double, size: CGSize, bypassColor: Bool = false, source: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage? {
        let cur = render(layer.current, at: t, size: size, bypassColor: bypassColor, source: source)
        if let tr = layer.current.clip.transitionIn, let tEnd = layer.current.transitionEnd, t < tEnd {
            let p = max(0, min(1, (t - layer.current.clip.start) / max(0.01, tEnd - layer.current.clip.start)))
            let out = layer.outgoing.flatMap { render($0, at: t, size: size, bypassColor: bypassColor, source: source) }
            return blend(tr.kind, from: out, to: cur, progress: p, size: size)
        }
        return cur
    }

    /// The clip's picture at `t`: oriented, cropped, fitted, transformed, color-corrected, faded.
    private static func render(_ src: LayerSource, at t: Double, size: CGSize, bypassColor: Bool = false, source: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage? {
        var img: CIImage
        if let still = src.still { img = still }
        else {
            guard let buf = source(src.trackID) else { return nil }
            img = oriented(src.output.isPassthrough ? CIImage(cvPixelBuffer: buf, options: [.colorSpace: NSNull()]) : ColorManagement.source(buf, src.output), natural: src.naturalSize, preferred: src.preferredTransform)
        }
        let clip = src.clip, local = t - clip.start, tf = clip.transform(at: local)
        let w = img.extent.width, h = img.extent.height
        guard w > 0, h > 0 else { return nil }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        img = Effects.source(img, clip: clip, sourceTime: clip.sourceIn + clip.sourceOffset(at: local))   // face blur, green-screen key (EffectsRender.swift)
        if tf.cropLeft + tf.cropRight + tf.cropTop + tf.cropBottom > 0 {
            let r = CGRect(x: w * tf.cropLeft, y: h * tf.cropBottom, width: w * max(0.01, 1 - tf.cropLeft - tf.cropRight), height: h * max(0.01, 1 - tf.cropTop - tf.cropBottom))
            img = img.cropped(to: r)
        }
        // Stabilization: counter-shift the picture in oriented source pixels (dy is + down; Core Image is y-up), then
        // zoom with the fit so the shifted borders stay outside the frame.
        var zoom = 1.0
        if src.still == nil, let st = clip.stabilization {
            let o = st.offset(at: clip.sourceIn + clip.sourceOffset(at: local))
            img = img.transformed(by: CGAffineTransform(translationX: o.dx * w, y: -o.dy * h))
            zoom = st.zoom
        }
        // Fit the (uncropped) picture into the frame, then the user's scale, rotation and offset about the frame center.
        let fit = min(size.width / w, size.height / h)
        var T = CGAffineTransform(translationX: -w / 2, y: -h / 2)
        T = T.concatenating(CGAffineTransform(scaleX: fit * tf.scale * zoom, y: fit * tf.scale * zoom))
        if tf.rotation != 0 { T = T.concatenating(CGAffineTransform(rotationAngle: -tf.rotation * .pi / 180)) }
        T = T.concatenating(CGAffineTransform(translationX: size.width / 2 + tf.x * size.width, y: size.height / 2 - tf.y * size.height))
        img = img.transformed(by: T)
        let color = clip.color(at: local)
        if bypassColor {
            // "Before" keeps the technical conversion (log → video) and drops only the grade on top of it.
            if let lut = color.inputLut, !lut.isEmpty { img = Looks.apply(img, key: lut, mix: 1) }
        } else { img = ColorPipeline.apply(img, clip: clip, color: color, at: t, size: size) }   // grade, grade layers, finishing (GradeStack.swift)
        let alpha = clip.opacity(at: local) * fade(clip, at: t)
        if alpha < 1 { img = clip.effects.blend == .normal ? withAlpha(img, alpha) : Effects.opacity(img, alpha) }
        return img.cropped(to: CGRect(origin: .zero, size: size))
    }

    static func graded(_ img: CIImage, _ c: ClipColor) -> CIImage {
        var out = img
        if let lut = c.inputLut, !lut.isEmpty { out = Looks.apply(out, key: lut, mix: 1) }   // log → video first, always full
        if c.exposure != 0 { out = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": c.exposure]) }
        if c.contrast != 1 || c.saturation != 1 {
            out = out.applyingFilter("CIColorControls", parameters: ["inputContrast": c.contrast, "inputSaturation": c.saturation, "inputBrightness": 0])
        }
        if c.temperature != 0 || c.tint != 0 {
            // Core Image moves the picture's neutral from `inputNeutral` to `inputTargetNeutral`: a lower target kelvin warms it.
            out = out.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                                                                           "inputTargetNeutral": CIVector(x: 6500 - c.temperature * 25, y: -c.tint)])   // + = magenta, as in every grading panel; CI's tint axis runs the other way
        }
        if c.shadows != 0 || c.midtones != 0 || c.highlights != 0 {
            // A five-point tone curve: the three inner points move by up to ±0.15.
            let k = 0.15
            let p = { (x: Double, d: Double) in CIVector(x: x, y: max(0, min(1, x + d * k))) }
            out = out.applyingFilter("CIToneCurve", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": p(0.25, c.shadows), "inputPoint2": p(0.5, c.midtones),
                                                                 "inputPoint3": p(0.75, c.highlights), "inputPoint4": CIVector(x: 1, y: 1)])
        }
        if c.vibrance != 0 { out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": c.vibrance]) }
        out = ColorCorrection.apply(out, wheels: c.wheels, curves: c.curves)   // color wheels, then custom curves (ColorWheels.swift)
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
        default:
            return Transitions.blend(kind, from: a, to: b, progress: p, size: size)   // the newer kinds (Transitions.swift)
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
    private static let lock = NSLock()
    /// Written once to a temporary name and moved into place, so a render that starts while another is still writing it
    /// (in this process or another EditMax) never reads a half-written file.
    static func url() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax")
        let url = dir.appendingPathComponent("blank.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("blank-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(to: tmp)
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.moveItem(at: tmp, to: url) }
            catch where FileManager.default.fileExists(atPath: url.path) {}   // another EditMax got there first: same movie
        }
        return url
    }

    private static func write(to url: URL) throws {
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
    }
}
