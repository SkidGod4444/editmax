import Foundation
import AVFoundation
import CoreImage
import Vision

// MARK: - Drawing

/// Blurs, pixelates or blacks out the boxes of a clip's `FaceBlur` on the oriented source picture (its own pixels,
/// origin at 0), so the result follows the picture through crop, stabilization and transform. Faces get an ellipse
/// grown by `expand`, regions their rectangle; `feather` softens the edge (the ramp straddles the shape's outline, so
/// the shape itself stays fully covered). Each box is blurred from the picture around it only (cropped), so a frame
/// costs a few small blurs, not a full-frame one.
enum FaceBlurRenderer {
    static func apply(_ img: CIImage, _ fb: FaceBlur, at t: Double) -> CIImage {
        let faces = fb.tracks.filter { !fb.exclude.contains($0.id) }.compactMap { $0.box(at: t) }
        let regions = fb.regions.compactMap { $0.box(at: t) }
        guard !faces.isEmpty || !regions.isEmpty else { return img }
        let ext = img.extent, W = ext.width, H = ext.height
        guard W > 1, H > 1 else { return img }
        var mask = CIImage(color: .black).cropped(to: ext)
        var fill = CIImage.empty()
        let feather = max(0, min(1, fb.feather))
        for (box, isFace) in faces.map({ ($0, true) }) + regions.map({ ($0, false) }) {
            var w = box.w * W, h = box.h * H
            var cx = (box.x + box.w / 2) * W, cy = (1 - box.y - box.h / 2) * H   // Core Image is y-up
            if isFace {
                // Vision's face box runs from the brows to the chin: grow it, a little more upwards (forehead, hair).
                let e = max(0, min(1, fb.expand))
                w *= 1 + e; h *= 1 + e * 1.3
                cy += box.h * H * e * 0.12
            }
            guard w >= 1, h >= 1 else { continue }
            let size = max(w, h)
            let ramp = feather * 0.5   // fraction of the half-size the soft edge spans, inside and outside the outline
            let outer = CGRect(x: cx - w / 2 * (1 + ramp), y: cy - h / 2 * (1 + ramp), width: w * (1 + ramp), height: h * (1 + ramp)).insetBy(dx: -2, dy: -2)
            let piece: CIImage
            if isFace {
                // An ellipse: a radial gradient (white core, black rim) drawn as a circle of the box's half-width in
                // pixels, then squeezed to the box's height (a unit gradient scaled up is sampled too coarsely: it came out square).
                let r = w / 2
                let grad = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: 0, y: 0), "inputRadius0": max(0.5, (1 - ramp) * r), "inputRadius1": (1 + ramp) * r + 0.5,
                                                                           "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!
                piece = grad.transformed(by: CGAffineTransform(scaleX: 1, y: h / w).concatenating(CGAffineTransform(translationX: cx, y: cy))).cropped(to: outer)
            } else {
                let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
                let solid = CIImage(color: .white).cropped(to: rect)
                let sigma = feather * 0.12 * min(w, h)
                piece = sigma < 0.5 ? solid : solid.composited(over: CIImage(color: .black).cropped(to: outer.insetBy(dx: -sigma * 3, dy: -sigma * 3)))
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma]).cropped(to: outer.insetBy(dx: -sigma * 2, dy: -sigma * 2))
            }
            mask = piece.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            let area = piece.extent.intersection(ext)
            guard !area.isNull, !area.isEmpty else { continue }
            let s = max(0, min(1, fb.strength))
            let cover: CIImage
            switch fb.style {
            case .blur:
                cover = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2, (0.04 + 0.22 * s) * size)])
            case .pixelate:
                cover = img.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(4, (0.04 + 0.16 * s) * size), kCIInputCenterKey: CIVector(x: cx, y: cy)])
            case .solid:
                cover = CIImage(color: .black)
            }
            fill = cover.cropped(to: area).composited(over: fill)
        }
        return fill.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask]).cropped(to: ext)
    }
}

extension Project {
    /// The clip with its face tracks and tracked-region paths filled in from `faceTracks` (the compositor reads them
    /// from the clip). Untouched when the clip has no blur or the cache holds nothing for it.
    func hydratedBlur(_ clip: Clip) -> Clip {
        guard var fb = clip.effects.blur, let cache = faceTracks else { return clip }
        var changed = false
        if fb.tracks.isEmpty, !fb.pathKey.isEmpty, let t = cache[fb.pathKey], !t.isEmpty { fb.tracks = t; changed = true }
        for i in fb.regions.indices where fb.regions[i].path.isEmpty {
            if let k = fb.regions[i].pathKey, let p = cache[k]?.first?.boxes, !p.isEmpty { fb.regions[i].path = p; changed = true }
        }
        guard changed else { return clip }
        var c = clip; c.effects.blur = fb; return c
    }
}

// MARK: - Analysis

/// Finds faces through a clip's source range with Vision and follows each one: `VNDetectFaceRectanglesRequest` on
/// frames read at ~640 px wide (oriented by a video composition, like the stabilizer) about 10 times a second, each
/// detection joined to the face whose last box overlaps it most (IoU, or a near centre when a face moved fast), new
/// faces numbered in order of appearance. A face missing for up to a second is bridged when drawing; one seen in a
/// single frame only is dropped as a false hit; boxes get a 3-sample moving average against jitter.
enum FaceAnalyzer {
    static let analysisWidth = 640.0
    static let sampleInterval = 0.1

    struct Result { var tracks: [FaceTrack]; var frames: Int; var seconds: Double }

    /// Every frame of `url` from `start` to `end` (asset seconds), oriented and scaled to `width`, at most `every` apart.
    static func frames(url: URL, from start: Double, to end: Double, width: Double, every: Double, _ body: (CVPixelBuffer, Double) throws -> Bool) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditError.invalid("no video track in \(url.lastPathComponent)") }
        let natural = try await track.load(.naturalSize), preferred = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let ow = abs(rect.width), oh = abs(rect.height)
        guard ow > 0, oh > 0 else { throw EditError.invalid("\(url.lastPathComponent) has no picture size") }
        let size = CGSize(width: width, height: max(2, (width * oh / ow / 2).rounded() * 2))
        var fd = try await track.load(.minFrameDuration)
        let nominal = Double(try await track.load(.nominalFrameRate))
        if !fd.isValid || fd.seconds < 1.0 / 121 || fd.seconds > 1 { fd = CMTime(value: 1, timescale: Int32(max(1, nominal > 1 ? nominal : 30).rounded())) }
        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = fd
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(CompositionBuilder.fitTransform(naturalSize: natural, preferred: preferred, into: size), at: .zero)
        instruction.layerInstructions = [layer]
        vc.instructions = [instruction]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = vc
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EditError.invalid("cannot read \(url.lastPathComponent) for analysis") }
        reader.add(output)
        let t0 = max(0, min(start, end)), t1 = min(duration.seconds, max(start, end))
        guard t1 - t0 > 0.02 else { throw EditError.invalid("nothing to analyse: the clip's source range is empty") }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: t0, preferredTimescale: 600), end: CMTime(seconds: t1, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? EditError.invalid("could not read \(url.lastPathComponent)") }
        var last = -Double.infinity, n = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let buf = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard t - last >= every - 0.004 else { continue }
            last = t; n += 1
            if try !body(buf, t) { reader.cancelReading(); break }
        }
        if reader.status == .failed { throw reader.error ?? EditError.invalid("reading \(url.lastPathComponent) failed") }
        return n
    }

    static func analyse(url: URL, from start: Double, to end: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        var detections: [(t: Double, boxes: [BlurBox])] = []
        let span = max(0.01, end - start)
        var lastProgress = -1.0
        let n = try await frames(url: url, from: start, to: end, width: analysisWidth, every: sampleInterval) { buf, t in
            let req = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cvPixelBuffer: buf, options: [:]).perform([req])
            let found = (req.results ?? []).map { o in BlurBox(t: t, x: o.boundingBox.minX, y: 1 - o.boundingBox.maxY, w: o.boundingBox.width, h: o.boundingBox.height) }
            detections.append((t, found))
            let p = (t - start) / span
            if p - lastProgress >= 0.02 { lastProgress = p; progress(max(0, min(1, p))) }
            return true
        }
        progress(1)
        return Result(tracks: associate(detections), frames: n, seconds: end - start)
    }

    static func iou(_ a: BlurBox, _ b: BlurBox) -> Double {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y), x1 = min(a.x + a.w, b.x + b.w), y1 = min(a.y + a.h, b.y + b.h)
        let inter = max(0, x1 - x0) * max(0, y1 - y0)
        let union = a.w * a.h + b.w * b.h - inter
        return union > 0 ? inter / union : 0
    }

    /// Joins per-frame detections into tracks (see the type's notes). Public for tests with injected boxes.
    static func associate(_ detections: [(t: Double, boxes: [BlurBox])], keepSingles: Bool = false) -> [FaceTrack] {
        var tracks: [[BlurBox]] = []
        for (t, boxes) in detections.sorted(by: { $0.t < $1.t }) {
            var free = Set(tracks.indices.filter { t - tracks[$0].last!.t <= 1.5 })
            var pairs: [(score: Double, track: Int, det: Int)] = []
            for (di, d) in boxes.enumerated() {
                for ti in free {
                    let last = tracks[ti].last!
                    let o = iou(last, d)
                    let dist = hypot((last.x + last.w / 2) - (d.x + d.w / 2), (last.y + last.h / 2) - (d.y + d.h / 2))
                    let near = dist < 0.6 * max(last.w, last.h, d.w, d.h)
                    let similar = min(last.w, d.w) / max(last.w, d.w, 1e-6) > 0.5
                    if o > 0.15 { pairs.append((o, ti, di)) } else if near && similar { pairs.append((0.1 - dist * 0.01, ti, di)) }
                }
            }
            var used = Set<Int>()
            for p in pairs.sorted(by: { $0.score > $1.score }) where free.contains(p.track) && !used.contains(p.det) {
                tracks[p.track].append(boxes[p.det]); free.remove(p.track); used.insert(p.det)
            }
            for (di, d) in boxes.enumerated() where !used.contains(di) { tracks.append([d]) }
        }
        let frames = Set(detections.map(\.t)).count
        let kept = tracks.filter { $0.count >= 2 || keepSingles || frames < 3 }
        return kept.sorted { $0[0].t < $1[0].t }.enumerated().map { i, boxes in FaceTrack(id: i + 1, boxes: smoothed(boxes)) }
    }

    /// 3-sample centred moving average of position and size.
    static func smoothed(_ b: [BlurBox]) -> [BlurBox] {
        guard b.count >= 3 else { return b }
        return b.indices.map { i in
            let lo = max(0, i - 1), hi = min(b.count - 1, i + 1)
            let s = b[lo...hi], n = Double(s.count)
            let r = { (x: Double) in (x * 10000).rounded() / 10000 }
            return BlurBox(t: r(b[i].t), x: r(s.map(\.x).reduce(0, +) / n), y: r(s.map(\.y).reduce(0, +) / n), w: r(s.map(\.w).reduce(0, +) / n), h: r(s.map(\.h).reduce(0, +) / n))
        }
    }

    /// Follows a rectangle drawn at source time `start` until `end` with `VNTrackObjectRequest`, frame by frame. Stops
    /// when the tracker loses it (confidence under 0.3 for 5 frames in a row); the region then stays where it was last seen.
    static func trackRegion(url: URL, box: BlurBox, from start: Double, to end: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> (path: [BlurBox], lostAt: Double?) {
        var path: [BlurBox] = []
        let seq = VNSequenceRequestHandler()
        var observation = VNDetectedObjectObservation(boundingBox: CGRect(x: box.x, y: 1 - box.y - box.h, width: box.w, height: box.h))
        var weak = 0
        var lostAt: Double?
        let span = max(0.01, end - start)
        var lastProgress = -1.0
        _ = try await frames(url: url, from: start, to: end, width: analysisWidth, every: 0) { buf, t in
            if path.isEmpty { path.append(BlurBox(t: t, x: box.x, y: box.y, w: box.w, h: box.h)); return true }
            let req = VNTrackObjectRequest(detectedObjectObservation: observation)
            req.trackingLevel = .accurate
            try? seq.perform([req], on: buf)
            guard let o = req.results?.first as? VNDetectedObjectObservation else { lostAt = t; return false }
            weak = o.confidence < 0.3 ? weak + 1 : 0
            if weak >= 5 { lostAt = t; return false }
            observation = o
            let bb = o.boundingBox
            path.append(BlurBox(t: (t * 10000).rounded() / 10000, x: bb.minX, y: 1 - bb.maxY, w: bb.width, h: bb.height))
            let p = (t - start) / span
            if p - lastProgress >= 0.02 { lastProgress = p; progress(max(0, min(1, p))) }
            return true
        }
        progress(1)
        return (path, lostAt)
    }
}
