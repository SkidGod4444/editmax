import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// Auto-reframe: makes a clip follow its subject when the project frame has a different aspect than the source
/// (16:9 footage in a 9:16 Shorts or 1:1 project). The picture is scaled to cover the frame and its position is
/// keyframed so the subject stays in view.
///
/// Analysis samples the clip's source range at a small size (≈ 416 px) every `sampleInterval` seconds of timeline
/// and asks Vision for a subject box per sample: faces first (`VNDetectFaceRectanglesRequest`: a group that fits the
/// frame is kept together, else the main face, with its eyes above the centre where the frame can pan vertically),
/// then the largest person (`VNDetectHumanRectanglesRequest`), else the largest attention-based salient object, else
/// the frame centre. The subject centre is smoothed (centred moving
/// average), dead-banded (a keyframe only when it moves more than 2 % of the frame) and speed-limited, then mapped
/// to the compositor's transform (see `FrameRenderer.render`): scale = cover factor / fit, x and y offsets as
/// fractions of the frame, clamped so the picture's edge never leaves the frame.
enum AutoReframe {
    enum Mode: String { case auto, person, saliency }

    struct Result: Codable {
        var clip: String
        var name: String
        /// How the subject was found for the whole clip: person, saliency or centre.
        var mode: String
        var samples: Int
        var keyframesX: Int
        var keyframesY: Int
        var scale: Double
        var source: String      // oriented source size
        var frame: String       // project frame size
        var coverage: String    // subject note (hit rate)
        var note: String?
    }

    /// One analysed sample: clip-local time and the subject centre in source-normalized coordinates (0…1, y down).
    struct Sample { var local: Double; var person: CGPoint?; var salient: CGPoint?; var faces: [CGRect] = [] }

    struct Analysis { var samples: [Sample]; var orientedSize: CGSize }

    // Tuning
    static let analysisWidth: CGFloat = 416
    static let deadBand = 0.02                 // fraction of the frame the smoothed centre must move before a keyframe
    static let smoothingWindow = 1.0           // seconds of centred moving average
    static let maxPanSpeed = 0.6               // frame widths (or heights) per second
    static let minKeyframeGap = 0.4            // seconds between keyframes
    static let maxKeyframes = 240
    /// A face smaller than this (fraction of the picture height) is a crowd in the distance, not the subject.
    static let minFaceHeight = 0.06
    /// Faces under this share of the main face's area are in the background and may be cut.
    static let groupFaceArea = 0.2

    // MARK: Analysis

    /// Reads the clip's media and finds the subject in each sample. Runs off the main actor (Vision and decoding are slow).
    nonisolated static func analyze(url: URL, clip: Clip, mode: Mode, sampleInterval: Double) async throws -> Analysis {
        let started = Date()
        let asset = AVURLAsset(url: url)
        // The generator's reader raises an uncatchable ObjC exception when the file has no readable video track, so check first.
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first, (try? await asset.load(.isReadable)) == true else {
            throw EditError.invalid("'\(url.lastPathComponent)' has no readable video track")
        }
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        // The oriented size, the way the compositor's `oriented` lays the picture out (a portrait phone file is tall).
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let oriented = CGSize(width: abs(rect.width), height: abs(rect.height))
        guard oriented.width > 0, oriented.height > 0 else { throw EditError.invalid("'\(url.lastPathComponent)' has no picture size") }

        let interval = max(0.1, min(5, sampleInterval))
        var locals: [Double] = []
        var t = 0.0
        while t < clip.duration { locals.append(t); t += interval }
        if let last = locals.last, clip.duration - last > interval * 0.5 { locals.append(clip.duration) }
        if locals.isEmpty { locals = [0] }
        // Source time of each sample: exact for speed ramps (the clip's own media integral), constant speed otherwise.
        let mediaDuration = (try? await asset.load(.duration).seconds) ?? .infinity
        let times = locals.map { local -> CMTime in
            let s = min(mediaDuration - 0.05, max(0, clip.sourceIn + clip.sourceOffset(at: min(local, clip.duration))))
            return CMTime(seconds: s, preferredTimescale: 600)
        }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: analysisWidth, height: analysisWidth)
        gen.requestedTimeToleranceBefore = CMTime(seconds: interval / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: interval / 2, preferredTimescale: 600)

        var found: [Int: (CGPoint?, CGPoint?, [CGRect])] = [:]
        var index = 0
        for await result in gen.images(for: times) {
            // One result per requested time, in order (a freeze-frame ramp repeats times, so arrival order is the truth).
            let i = index; index += 1
            guard i < locals.count else { break }
            guard let img = try? result.image else { continue }   // a failed frame leaves a hole; filled from its neighbours
            found[i] = detect(img, mode: mode)
        }
        var samples: [Sample] = []
        for (i, local) in locals.enumerated() {
            let r = found[i]
            samples.append(Sample(local: local, person: r?.0, salient: r?.1, faces: r?.2 ?? []))
        }
        DebugLog.event("auto-reframe-analysis", ["file": url.lastPathComponent, "samples": samples.count, "decoded": found.count,
                                                 "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
        return Analysis(samples: samples, orientedSize: oriented)
    }

    /// The person centre, the salient-object centre and the face boxes in one frame (source-normalized, y down); nil or
    /// empty where nothing was found.
    nonisolated private static func detect(_ img: CGImage, mode: Mode) -> (CGPoint?, CGPoint?, [CGRect]) {
        var requests: [VNRequest] = []
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = true   // head and torso: what the viewer wants kept in frame
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        if mode != .saliency { requests.append(people); requests.append(faces) }
        if mode != .person { requests.append(saliency) }
        let handler = VNImageRequestHandler(cgImage: img, orientation: .up, options: [:])
        try? handler.perform(requests)
        var person: CGPoint? = nil, salient: CGPoint? = nil
        if mode != .saliency, let obs = people.results, let best = obs.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            person = centre(best.boundingBox)
        }
        if mode != .person, let obs = saliency.results?.first, let objects = obs.salientObjects, !objects.isEmpty {
            // Area-weighted centre of the salient objects, so a second small object pulls a little, not all the way.
            var sx = 0.0, sy = 0.0, sw = 0.0
            for o in objects {
                let b = o.boundingBox, a = Double(max(1e-4, b.width * b.height)), c = centre(b)
                sx += c.x * a; sy += c.y * a; sw += a
            }
            if sw > 0 { salient = CGPoint(x: sx / sw, y: sy / sw) }
        }
        let faceBoxes = mode == .saliency ? [] : (faces.results ?? []).map { o -> CGRect in
            let b = o.boundingBox
            return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)   // y down, like the centres
        }
        return (person, salient, faceBoxes)
    }

    /// Where to aim for one sample's faces (source-normalized, y down), or nil when none is big enough to be the subject.
    /// `window` is the part of the source the frame shows. Faces that fit in it together are kept together (a selfie of
    /// two); otherwise the main face, preferring the one aimed at before so the pan does not hop between people. The aim
    /// sits a little below the face, so where the frame can pan vertically the eyes land above the centre (headroom).
    static func faceAim(_ faces: [CGRect], window: CGSize, previous: CGPoint? = nil) -> CGPoint? {
        guard let largest = faces.max(by: { $0.width * $0.height < $1.width * $1.height }), Double(largest.height) >= minFaceHeight else { return nil }
        let area = { (r: CGRect) in Double(r.width * r.height) }
        let kept = faces.filter { area($0) >= groupFaceArea * area(largest) }
        // Everyone's whole face with a little room: shoulders may be cut to keep a second person, a face may not.
        let group = kept.map { $0.insetBy(dx: -$0.width * 0.15, dy: 0) }.reduce(CGRect.null) { $0.union($1) }
        var target: CGRect
        if Double(group.width) <= Double(window.width) * 0.95 {
            target = group
        } else {
            var main = largest
            if let p = previous, let near = kept.min(by: { hypot($0.midX - p.x, $0.midY - p.y) < hypot($1.midX - p.x, $1.midY - p.y) }),
               area(near) >= 0.6 * area(largest) { main = near }
            target = main
        }
        return CGPoint(x: target.midX, y: min(1, target.midY + window.height * 0.12))
    }

    /// Vision boxes are normalized with the origin at the bottom-left; the subject centre is kept y-down (0 = top).
    nonisolated private static func centre(_ b: CGRect) -> CGPoint { CGPoint(x: b.midX, y: 1 - b.midY) }

    // MARK: Path

    /// Chooses one mode for the whole clip (a mix would jump between what each one calls the subject) and returns the
    /// subject centre per sample with holes filled from the neighbours. Hit rate = fraction of samples with a detection.
    static func path(_ analysis: Analysis, mode: Mode, window: CGSize = CGSize(width: 1, height: 1)) -> (points: [CGPoint], mode: String, hitRate: Double) {
        let n = analysis.samples.count
        guard n > 0 else { return ([], "centre", 0) }
        var faceAims: [CGPoint?] = []
        var previous: CGPoint? = nil
        for s in analysis.samples {
            let a = mode == .saliency ? nil : faceAim(s.faces, window: window, previous: previous)
            faceAims.append(a); if let a { previous = a }
        }
        let faceHits = faceAims.filter { $0 != nil }.count
        let personHits = analysis.samples.filter { $0.person != nil }.count
        let salientHits = analysis.samples.filter { $0.salient != nil }.count
        var raw: [CGPoint?]
        var used: String
        var hits: Int
        if mode != .saliency, Double(faceHits) / Double(n) >= 0.3 {
            raw = faceAims; used = "face"; hits = faceHits
        } else if mode != .saliency, Double(personHits) / Double(n) >= 0.3 {
            raw = analysis.samples.map(\.person); used = "person"; hits = personHits
        } else if mode != .person, salientHits > 0 {
            raw = analysis.samples.map(\.salient); used = "saliency"; hits = salientHits
        } else if mode == .person, personHits > 0 {
            raw = analysis.samples.map(\.person); used = "person"; hits = personHits
        } else {
            return (Array(repeating: CGPoint(x: 0.5, y: 0.5), count: n), "centre", 0)
        }
        // Fill holes: interpolate between the nearest known samples, hold at the ends.
        var pts = [CGPoint](repeating: CGPoint(x: 0.5, y: 0.5), count: n)
        let known = raw.indices.filter { raw[$0] != nil }
        if let first = known.first, let last = known.last {
            for i in 0..<n {
                if let p = raw[i] { pts[i] = p; continue }
                if i < first { pts[i] = raw[first]!; continue }
                if i > last { pts[i] = raw[last]!; continue }
                let a = known.last(where: { $0 < i })!, b = known.first(where: { $0 > i })!
                let u = Double(i - a) / Double(b - a)
                let pa = raw[a]!, pb = raw[b]!
                pts[i] = CGPoint(x: pa.x + (pb.x - pa.x) * u, y: pa.y + (pb.y - pa.y) * u)
            }
        }
        return (pts, used, Double(hits) / Double(n))
    }

    /// Centred moving average over `window` seconds (lag-free, unlike exponential smoothing).
    static func smooth(_ values: [Double], interval: Double, window: Double = smoothingWindow) -> [Double] {
        let n = values.count
        guard n > 2 else { return values }
        let half = max(1, Int((window / max(0.01, interval) / 2).rounded()))
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - half), hi = min(n - 1, i + half)
            var s = 0.0
            for j in lo...hi { s += values[j] }
            out[i] = s / Double(hi - lo + 1)
        }
        return out
    }

    /// Dead-band + minimum spacing + pan speed clamp: the keyframes to write for one axis (clip-local time, value).
    /// Always emits the first sample; the last sample may move regardless of the spacing so the clip ends on the subject.
    static func keyframes(times: [Double], values: [Double], deadBand: Double = deadBand, minGap: Double = minKeyframeGap, maxSpeed: Double = maxPanSpeed) -> [(time: Double, value: Double)] {
        let n = min(times.count, values.count)
        guard n > 0 else { return [] }
        var out: [(time: Double, value: Double)] = [(times[0], values[0])]
        if n == 1 { return out }
        var prevIndex = 0
        for i in 1..<n {
            let prev = out[out.count - 1]
            let isLast = i == n - 1
            guard abs(values[i] - prev.value) > deadBand, isLast || times[i] - prev.time >= minGap else { continue }
            // Anchor: hold the old value through the samples that stayed near it, so the pan starts when the subject
            // moves rather than drifting from the previous keyframe across a long hold (a slow drift still spreads).
            if let j = ((prevIndex + 1)..<i).last(where: { abs(values[$0] - prev.value) <= deadBand * 0.5 }), times[j] - prev.time > 0.01 {
                out.append((times[j], prev.value))
            }
            let anchor = out[out.count - 1]
            out.append((times[i], clampSpeed(from: anchor, to: (times[i], values[i]), maxSpeed: maxSpeed)))
            prevIndex = i
        }
        // Keep the count modest whatever the footage does.
        if out.count > maxKeyframes {
            let step = Double(out.count - 1) / Double(maxKeyframes - 1)
            out = (0..<maxKeyframes).map { out[Int((Double($0) * step).rounded())] }
        }
        return out
    }

    private static func clampSpeed(from a: (time: Double, value: Double), to b: (Double, Double), maxSpeed: Double) -> Double {
        let dt = max(0.001, b.0 - a.time), limit = maxSpeed * dt
        let d = b.1 - a.value
        return abs(d) <= limit ? b.1 : a.value + (d < 0 ? -limit : limit)
    }

    // MARK: Mapping to the compositor's transform

    /// The cover scale and the offset bounds for a source of `source` (oriented) pixels in a `frame` of pixels, after the clip's crops.
    /// Mirrors `FrameRenderer.render`: fit = min(W/w, H/h); the drawn size is w·fit·scale × h·fit·scale about the frame centre;
    /// x/y are fractions of the frame (+x right, +y down).
    struct Geometry {
        var scale: Double           // the clip's transform.scale that covers the frame
        var s: Double               // fit × scale: source pixels → frame pixels
        var xRange: ClosedRange<Double>
        var yRange: ClosedRange<Double>
        var source: CGSize, frame: CGSize
        var crop: ClipTransform
    }

    static func geometry(source: CGSize, frame: CGSize, crop tf: ClipTransform) -> Geometry {
        let w = Double(source.width), h = Double(source.height), W = Double(frame.width), H = Double(frame.height)
        let visW = max(0.01, 1 - tf.cropLeft - tf.cropRight), visH = max(0.01, 1 - tf.cropTop - tf.cropBottom)
        let fit = min(W / w, H / h)
        // Cover: the visible (cropped) picture must span the frame on both axes.
        let s = max(W / (w * visW), H / (h * visH))
        let scale = max(0.05, min(10, s / fit))
        let sEff = fit * scale
        // Picture edges stay outside the frame: left edge ≤ 0 and right edge ≥ W (see the math in the file header).
        let xMin = (W / 2 - (0.5 - tf.cropRight) * w * sEff) / W
        let xMax = ((0.5 - tf.cropLeft) * w * sEff - W / 2) / W
        let yMin = (H / 2 - (0.5 - tf.cropBottom) * h * sEff) / H
        let yMax = ((0.5 - tf.cropTop) * h * sEff - H / 2) / H
        let xr = -2.0...2.0, yr = -2.0...2.0   // the x/y limits of ToolExecutor.paramRanges (main-actor, so not read here)
        let clampX = max(xr.lowerBound, min(xr.upperBound, min(xMin, xMax)))...max(xr.lowerBound, min(xr.upperBound, max(xMin, xMax)))
        let clampY = max(yr.lowerBound, min(yr.upperBound, min(yMin, yMax)))...max(yr.lowerBound, min(yr.upperBound, max(yMin, yMax)))
        return Geometry(scale: scale, s: sEff, xRange: clampX, yRange: clampY, source: source, frame: frame, crop: tf)
    }

    /// The x/y offsets (fractions of the frame) that put a subject at source-normalized (u, v) in the frame centre, scaled by
    /// `strength` and clamped to the picture's edges. Derived from the compositor: frame X of a source point = (u·w − w/2)·s + W/2 + x·W.
    static func offset(for p: CGPoint, geometry g: Geometry, strength: Double) -> (x: Double, y: Double) {
        let w = Double(g.source.width), h = Double(g.source.height), W = Double(g.frame.width), H = Double(g.frame.height)
        let x = -(Double(p.x) - 0.5) * w * g.s / W * strength
        let y = (0.5 - Double(p.y)) * h * g.s / H * strength
        return (max(g.xRange.lowerBound, min(g.xRange.upperBound, x)), max(g.yRange.lowerBound, min(g.yRange.upperBound, y)))
    }
}

// MARK: - The operation

extension ToolExecutor {
    /// Analyses the clip's subject and writes one undoable edit: cover scale plus x/y keyframes that keep it in view.
    /// `mode`: auto (default), person, saliency. `sampleInterval`: seconds of timeline between samples (default 0.33).
    /// `strength`: 0…1, how much of the subject's displacement from the centre the pan follows (default 1 = keep it centred).
    func autoReframe(_ clip: String, mode: String? = nil, sampleInterval: Double? = nil, strength: Double? = nil) async throws -> AutoReframe.Result {
        let id = try resolveClip(clip)
        guard let found = document.project.clip(id) else { throw EditError.notFound("clip \(clip)") }
        guard found.track.kind == .video else { throw EditError.invalid("clip \(found.clip.name) is on an audio track; auto-reframe needs a video clip") }
        guard let asset = document.project.asset(found.clip.assetID) else { throw EditError.notFound("the clip's asset") }
        let m = try AutoReframe.Mode.parse(mode)
        let settings = document.project.settings
        let frame = CGSize(width: settings.width, height: settings.height)
        let original = found.clip
        let plan = try await AutoReframe.plan(clip: original, asset: asset, frame: frame, mode: m, sampleInterval: sampleInterval, strength: strength)
        try document.apply("Auto-reframe \(original.name)", origin: origin) { p in try p.updateClip(id) { AutoReframe.apply(plan, to: &$0) } }
        DebugLog.event("auto-reframe", ["clip": id.short, "mode": plan.mode, "samples": plan.samples, "kx": plan.keyframesX, "ky": plan.keyframesY, "scale": (plan.scale * 100).rounded() / 100])
        let r3 = { (x: Double) in (x * 1000).rounded() / 1000 }
        return AutoReframe.Result(clip: id.short, name: original.name, mode: plan.mode, samples: plan.samples,
                                  keyframesX: plan.keyframesX, keyframesY: plan.keyframesY, scale: r3(plan.scale),
                                  source: plan.source, frame: "\(settings.width)×\(settings.height)",
                                  coverage: plan.coverage, note: plan.notes.isEmpty ? nil : plan.notes.joined(separator: "; "))
    }
}

extension AutoReframe.Mode {
    static func parse(_ text: String?) throws -> AutoReframe.Mode {
        switch (text ?? "auto").lowercased() {
        case "auto", "": return .auto
        case "person", "people", "face": return .person
        case "saliency", "salient", "object": return .saliency
        default: throw EditError.invalid("mode must be auto, person or saliency")
        }
    }
}

extension AutoReframe {
    /// What a reframe would write to a clip: the cover scale and the x/y keyframes, plus what the analysis found.
    /// Pure, so the batch export can apply it to a project copy without touching the document.
    struct Plan {
        var scale: Double
        var xs: [(time: Double, value: Double)]
        var ys: [(time: Double, value: Double)]
        var mode: String
        var samples: Int
        var source: String
        var coverage: String
        var notes: [String]
        var keyframesX: Int { xs.count > 1 ? xs.count : 0 }
        var keyframesY: Int { ys.count > 1 ? ys.count : 0 }
    }

    static func plan(clip original: Clip, asset: Asset, frame: CGSize, mode m: Mode, sampleInterval: Double?, strength: Double?) async throws -> Plan {
        guard asset.kind == .video || asset.kind == .sequence else { throw EditError.invalid("clip \(original.name) is a \(asset.kind.rawValue); auto-reframe needs video") }
        guard FileManager.default.fileExists(atPath: asset.path) else { throw EditError.notFound("media file \(asset.path)") }
        let interval = max(0.1, min(5, sampleInterval ?? 0.33))
        let k = max(0, min(1, strength ?? 1))

        let analysis = try await analyze(url: asset.url, clip: original, mode: m, sampleInterval: interval)
        let g = geometry(source: analysis.orientedSize, frame: frame, crop: original.transform)
        let sourceAspect = Double(analysis.orientedSize.width) / Double(analysis.orientedSize.height)
        let frameAspect = Double(frame.width) / Double(frame.height)
        let sameAspect = abs(sourceAspect / frameAspect - 1) < 0.02
        let needX = g.xRange.upperBound - g.xRange.lowerBound > 0.005
        let needY = g.yRange.upperBound - g.yRange.lowerBound > 0.005

        // The part of the source the frame shows at the cover scale (source-normalized), for keeping faces together.
        let window = CGSize(width: min(1, Double(frame.width) / (Double(analysis.orientedSize.width) * g.s)),
                            height: min(1, Double(frame.height) / (Double(analysis.orientedSize.height) * g.s)))
        let (points, usedMode, hitRate) = path(analysis, mode: m, window: window)
        let times = analysis.samples.map(\.local)
        var xs: [(time: Double, value: Double)] = [], ys: [(time: Double, value: Double)] = []
        if usedMode != "centre", !sameAspect {   // a matching aspect renders fitted at scale 1, where no pan is possible
            let offsets = points.map { offset(for: $0, geometry: g, strength: k) }
            if needX { xs = keyframes(times: times, values: smooth(offsets.map(\.x), interval: interval)) }
            if needY { ys = keyframes(times: times, values: smooth(offsets.map(\.y), interval: interval)) }
        }
        // A path that never moves is a plain offset, not an animation.
        if xs.count == 1 || (xs.count > 1 && xs.allSatisfy({ abs($0.value - xs[0].value) < 0.001 })) { xs = [xs[0]] }
        if ys.count == 1 || (ys.count > 1 && ys.allSatisfy({ abs($0.value - ys[0].value) < 0.001 })) { ys = [ys[0]] }

        var notes: [String] = []
        if sameAspect { notes.append("no reframe needed: the source aspect matches the frame; scale 1") }
        else if !needX && !needY { notes.append("the cover scale fills the frame with no room to pan") }
        if original.transform.rotation != 0 { notes.append("the clip is rotated; the edge clamp assumes no rotation") }
        if original.transform.cropLeft + original.transform.cropRight + original.transform.cropTop + original.transform.cropBottom > 0 { notes.append("crops honoured in the scale and the clamp") }
        if usedMode == "centre" { notes.append("no face, person or salient object found; the picture is centred") }
        if k < 1 { notes.append("strength \(k): the pan follows \(Int(k * 100))% of the subject's displacement") }
        let coverage = usedMode == "centre" ? "no subject found in \(analysis.samples.count) samples"
            : "\(usedMode) found in \(Int((hitRate * 100).rounded()))% of \(analysis.samples.count) samples\(hitRate < 1 ? "; gaps filled from the neighbours" : "")"
        return Plan(scale: sameAspect ? 1 : g.scale, xs: xs, ys: ys, mode: usedMode, samples: analysis.samples.count,
                    source: "\(Int(analysis.orientedSize.width))×\(Int(analysis.orientedSize.height))", coverage: coverage, notes: notes)
    }

    /// Writes a plan onto a clip: replaces any x/y (and scale) animation with the cover scale and the pan keyframes.
    static func apply(_ plan: Plan, to c: inout Clip) {
        c.clearAnimation(.x); c.clearAnimation(.y)
        if c.isAnimated(.scale) { c.clearAnimation(.scale) }
        c.transform.scale = plan.scale
        c.transform.x = plan.xs.count == 1 ? plan.xs[0].value : 0
        c.transform.y = plan.ys.count == 1 ? plan.ys[0].value : 0
        if plan.xs.count > 1 { for kf in plan.xs { c.setKeyframe(.x, at: kf.time, value: kf.value, ease: .smooth) } }
        if plan.ys.count > 1 { for kf in plan.ys { c.setKeyframe(.y, at: kf.time, value: kf.value, ease: .smooth) } }
    }
}
