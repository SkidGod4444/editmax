import Foundation
import AVFoundation
import CoreImage
import Vision

/// Camera-shake analysis for one clip. Reads the clip's source range at ~480 px wide (oriented and scaled by a video
/// composition, so the numbers are in the oriented picture's axes), registers every frame against the one before it
/// with Vision's translational registration, integrates the steps into the camera path, smooths the path over
/// `strength` seconds and keeps the difference as the per-frame correction. The compositor applies that correction
/// as a shift of the picture plus a uniform zoom that hides the borders.
///
/// Sign chain (checked against Vision on synthetic frames): the alignment transform of a request whose floating
/// (targeted) image is the current frame and whose reference is the previous one is the translation that moves the
/// current frame onto the previous, in Core Image y-up pixels (content that moved +20/+10 gives tx −20, ty −10).
/// Summing those steps gives the translation that locks every frame onto the first (the inverse camera path);
/// smoothing it and subtracting the smooth part leaves the shake alone: correction = path − smoothed. Stored as
/// fractions with dy flipped (+ = down), which the compositor flips back when it translates in y-up space.
enum Stabilizer {
    static let analysisWidth = 480.0
    static let maxZoom = 1.25
    /// The largest shift (fraction of the picture) that `maxZoom` can hide on each side: 1 − 1/zoom = 2·m.
    static var maxShift: Double { (1 - 1 / maxZoom) / 2 }

    struct Analysis {
        var stabilization: Stabilization
        var maxShift: Double          // fraction of the picture, over both axes, before clamping
        var secondsAnalysed: Double
        var frames: Int
    }

    /// The crop a zoom implies, in percent of each dimension.
    static func cropPercent(_ zoom: Double) -> Double { ((1 - 1 / max(1, zoom)) * 1000).rounded() / 10 }

    /// Analyses `url` from `start` to `end` seconds (asset time). Runs on the calling task; call it off the main actor.
    /// `progress` is 0…1 and is called at most every couple of percent. Cancelling the task stops the reader.
    static func analyse(url: URL, from start: Double, to end: Double, strength: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> Analysis {
        let began = Date()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditError.invalid("no video track in \(url.lastPathComponent)") }
        let natural = try await track.load(.naturalSize), preferred = try await track.load(.preferredTransform)
        let nominal = Double(try await track.load(.nominalFrameRate))
        var frameDuration = try await track.load(.minFrameDuration)
        let duration = try await asset.load(.duration).seconds
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let ow = abs(rect.width), oh = abs(rect.height)
        guard ow > 0, oh > 0 else { throw EditError.invalid("\(url.lastPathComponent) has no picture size") }
        let size = CGSize(width: analysisWidth, height: max(2, (analysisWidth * oh / ow / 2).rounded() * 2))
        let fps = nominal > 1 ? nominal : 30
        // Variable-rate phone clips report a tiny minimum; the nominal rate is the sensible sampling then.
        if !frameDuration.isValid || frameDuration.seconds < 1.0 / 121 || frameDuration.seconds > 1 { frameDuration = CMTime(value: 1, timescale: Int32(fps.rounded())) }
        if fps > 60 { frameDuration = CMTimeMultiply(frameDuration, multiplier: 2) }   // every 2nd frame is plenty above 60 fps

        // A video composition scales and orients the frames for us (the built-in compositor applies the layer
        // transform the way AVFoundation means it, so phone rotations come out upright).
        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = frameDuration
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
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
        let t0 = max(0, min(start, end)), t1 = min(duration, max(start, end))
        guard t1 - t0 > 0.05 else { throw EditError.invalid("nothing to analyse: the clip's source range is empty") }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: t0, preferredTimescale: 600), end: CMTime(seconds: t1, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? EditError.invalid("could not read \(url.lastPathComponent)") }

        // Per frame: its time and the translation that moves it onto the frame before (Core Image y-up analysis pixels).
        var times: [Double] = [], steps: [(x: Double, y: Double)] = []
        var previous: CVPixelBuffer?
        var lastProgress = -1.0
        let cutLimit = analysisWidth * 0.2   // a jump this big is a cut or a failed match, not shake
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let buf = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            var step = (x: 0.0, y: 0.0)
            if let previous {
                let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: buf, options: [:])
                try? VNImageRequestHandler(cvPixelBuffer: previous, options: [:]).perform([request])
                if let a = (request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform,
                   abs(a.tx) < cutLimit, abs(a.ty) < cutLimit { step = (a.tx, a.ty) }
            }
            times.append(t); steps.append(step)
            previous = buf
            let p = (t - t0) / max(0.01, t1 - t0)
            if p - lastProgress >= 0.02 { lastProgress = p; progress(max(0, min(1, p))) }
        }
        if reader.status == .failed { throw reader.error ?? EditError.invalid("reading \(url.lastPathComponent) failed") }
        guard times.count >= 2 else { throw EditError.invalid("too few frames to analyse (\(times.count))") }

        // The inverse camera path: the translation that locks frame k onto frame 0.
        var path: [(x: Double, y: Double)] = []
        var acc = (x: 0.0, y: 0.0)
        for s in steps { acc = (acc.x + s.x, acc.y + s.y); path.append(acc) }
        // Centred Gaussian over `strength` seconds (σ = strength / 2, cut at ±strength), weights renormalised at the ends.
        let sigma = max(0.05, strength / 2), reach = max(0.1, strength)
        var samples: [Stabilization.Sample] = []
        samples.reserveCapacity(times.count)
        var worst = 0.0
        var j0 = 0
        for i in 0..<times.count {
            let ti = times[i]
            while j0 < i, times[j0] < ti - reach { j0 += 1 }
            var sx = 0.0, sy = 0.0, sw = 0.0
            var j = j0
            while j < times.count, times[j] <= ti + reach {
                let d = (times[j] - ti) / sigma, w = exp(-0.5 * d * d)
                sx += path[j].x * w; sy += path[j].y * w; sw += w
                j += 1
            }
            let smooth = sw > 0 ? (x: sx / sw, y: sy / sw) : path[i]
            let cx = path[i].x - smooth.x, cy = path[i].y - smooth.y   // correction in y-up analysis pixels
            var dx = cx / size.width, dy = -cy / size.height            // + = right / down
            worst = max(worst, abs(dx), abs(dy))
            dx = max(-maxShift, min(maxShift, dx)); dy = max(-maxShift, min(maxShift, dy))
            samples.append(.init(t: (ti * 10000).rounded() / 10000, dx: (dx * 10000).rounded() / 10000, dy: (dy * 10000).rounded() / 10000))
        }
        let m = min(maxShift, worst)
        let zoom = m <= 0 ? 1 : min(maxZoom, ((1 / (1 - 2 * m)) * 1000).rounded(.up) / 1000)
        progress(1)
        DebugLog.event("stabilize", ["file": url.lastPathComponent, "frames": times.count, "from": (t0 * 100).rounded() / 100, "to": (t1 * 100).rounded() / 100,
                                     "maxShift": (worst * 10000).rounded() / 100, "zoom": zoom, "strength": strength,
                                     "seconds": (Date().timeIntervalSince(began) * 100).rounded() / 100])
        return Analysis(stabilization: Stabilization(strength: strength, zoom: zoom, samples: samples), maxShift: worst, secondsAnalysed: t1 - t0, frames: times.count)
    }
}

extension ToolExecutor {
    struct StabilizeResult: Codable {
        var clip: String, name: String, removed: Bool
        var samples: Int, strength: Double, zoom: Double, cropPercent: Double, maxShiftPercent: Double, secondsAnalysed: Double
        var note: String?
    }

    /// Analyses the clip's source range (plus `strength` seconds of margin on each side) off the main thread and stores
    /// the result on the clip in one edit; `remove` clears it. `progress` (0…1) is called from a background thread.
    func stabilizeClip(_ clip: String, strength: Double?, remove: Bool = false, progress: (@Sendable (Double) -> Void)? = nil) async throws -> StabilizeResult {
        let id = try resolveClip(clip)
        guard let c = document.project.clip(id)?.clip else { throw EditError.notFound("clip '\(clip)'") }
        if remove {
            guard c.stabilization != nil else { throw EditError.invalid("clip \(c.id.short) is not stabilized") }
            try document.apply("Remove stabilization", origin: origin) { p in try p.updateClip(id) { $0.stabilization = nil } }
            return StabilizeResult(clip: c.id.short, name: c.name, removed: true, samples: 0, strength: 0, zoom: 1, cropPercent: 0, maxShiftPercent: 0, secondsAnalysed: 0, note: nil)
        }
        guard c.multicam == nil else { throw EditError.invalid("clip \(c.id.short) is a multicam clip; flatten it first (set_multicam flatten)") }
        guard let asset = document.project.asset(c.assetID) else { throw EditError.notFound("the media of clip \(c.id.short)") }
        guard asset.kind == .video else { throw EditError.invalid("clip \(c.id.short) is \(asset.kind == .image ? "a still" : "not a video file"); only video clips can be stabilized") }
        let s = max(0.1, min(3, strength ?? 0.6))
        let from = max(0, c.sourceIn - s), to = min(asset.duration, c.sourceOut + s)
        let url = asset.url
        let worker = Task.detached(priority: .utility) {
            try await Stabilizer.analyse(url: url, from: from, to: to, strength: s) { p in progress?(p) }
        }
        // A detached task does not inherit cancellation: forward it, so the inspector can stop a running analysis.
        let analysis = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard document.project.clip(id) != nil else { throw EditError.notFound("clip \(c.id.short): it was removed while analysing") }
        // The samples (one per frame) go into the project's motion-path cache, which history snapshots skip; the clip
        // only carries the key, strength and zoom, so a long clip does not grow every later undo step.
        var st = analysis.stabilization
        let samples = st.samples
        st.samples = []
        st.pathKey = "\(asset.id.uuidString)|\((from * 1000).rounded())|\((to * 1000).rounded())|\(s)"
        try document.apply("Stabilize \(c.name)", origin: origin) { p in
            if p.motionPaths == nil { p.motionPaths = [:] }
            p.motionPaths?[st.pathKey] = samples
            try p.updateClip(id) { $0.stabilization = st }
        }
        st.samples = samples
        let shift = (analysis.maxShift * 10000).rounded() / 100
        var note: String?
        if analysis.maxShift > Stabilizer.maxShift { note = "the shake reaches \(shift) % of the picture; shifts are capped at \(Stabilizer.maxShift * 100) % (the most a \(Stabilizer.maxZoom)× zoom hides), so the worst moments keep some movement; a smaller strength corrects less and crops less" }
        else if analysis.maxShift < 0.002 { note = "the picture is already steady (shifts under 0.2 %); the correction is negligible" }
        return StabilizeResult(clip: c.id.short, name: c.name, removed: false, samples: st.samples.count, strength: s, zoom: st.zoom,
                               cropPercent: Stabilizer.cropPercent(st.zoom), maxShiftPercent: shift, secondsAnalysed: (analysis.secondsAnalysed * 100).rounded() / 100, note: note)
    }
}
