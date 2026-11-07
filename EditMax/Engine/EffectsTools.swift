import Foundation
import AVFoundation
import CoreImage
import AppKit

/// The effects edits (green-screen key, blend modes, face and region blur, title animations, lower thirds, project
/// colour). Every method validates its inputs and refuses out-of-range values with an error instead of clamping them,
/// and returns what changed.
extension ToolExecutor {
    fileprivate func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// A number argument inside its range, or an error naming the range.
    fileprivate func checked(_ name: String, _ v: Double?, _ range: ClosedRange<Double>) throws -> Double? {
        guard let v else { return nil }
        guard v.isFinite, range.contains(v) else { throw EditError.invalid("\(name) must be between \(fmt(range.lowerBound)) and \(fmt(range.upperBound)) (got \(fmt(v)))") }
        return v
    }
    fileprivate func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }

    /// A clip on a video track playing a video or a still, with its asset.
    fileprivate func pictureClip(_ clip: String, for what: String) throws -> (id: UUID, clip: Clip, track: Track, asset: Asset) {
        let id = try resolveClip(clip)
        guard let found = document.project.clip(id) else { throw EditError.notFound("clip '\(clip)'") }
        guard found.track.kind == .video else { throw EditError.invalid("clip \(id.short) is on an audio track; \(what) works on video-track clips") }
        guard let asset = document.project.asset(found.clip.assetID) else { throw EditError.notFound("the media of clip \(id.short)") }
        guard asset.kind == .video || asset.kind == .image else { throw EditError.invalid("clip \(id.short) has no picture (\(asset.kind.rawValue)); \(what) works on video and still clips") }
        return (id, found.clip, found.track, asset)
    }

    /// The source time a timeline time shows in a clip (clamped into the clip).
    fileprivate func sourceTime(_ c: Clip, timeline t: Double?) -> Double {
        let tl = min(max(t ?? (UIRegistry.shared.playheads[document.id]?() ?? c.start), c.start), c.end - 0.001)
        return c.sourceIn + c.sourceOffset(at: tl - c.start)
    }

    /// The clip's own picture (oriented, before crop, transform and grade) at a source time, as the compositor sees it.
    fileprivate func sourcePicture(_ asset: Asset, at s: Double) async throws -> CIImage {
        if asset.kind == .image {
            guard let still = StillLoader.load(asset.url) else { throw EditError.invalid("could not read \(asset.name)") }
            return still
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let cg = try await gen.image(at: CMTime(seconds: max(0, min(s, asset.duration - 0.02)), preferredTimescale: 600)).image
        // The generator hands back display pixels; draw them as untagged sRGB values, as stills come in.
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw EditError.invalid("could not read a frame of \(asset.name)") }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let srgb = ctx.makeImage() else { throw EditError.invalid("could not read a frame of \(asset.name)") }
        return CIImage(cgImage: srgb, options: [.colorSpace: NSNull()])
    }

    fileprivate static let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    fileprivate func cgImage(_ img: CIImage, maxWidth: Int) -> CGImage? {
        let s = min(1, CGFloat(maxWidth) / max(1, img.extent.width))
        let scaled = s < 1 ? img.transformed(by: CGAffineTransform(scaleX: s, y: s)) : img
        let r = scaled.extent.integral
        return Self.ciContext.createCGImage(scaled, from: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    fileprivate func png(_ cg: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let d = rep.representation(using: .png, properties: [:]) else { throw EditError.invalid("could not encode the image") }
        return d
    }

    // MARK: Green-screen key

    struct ChromaKeyResult: Codable {
        var clip: String, name: String, removed: Bool
        var key: ChromaKey?
        var detected: String?          // the colour auto-detect found, when asked for
        var confidence: Double?        // share of edge pixels with that colour
        var matte: Keyer.MatteStats?   // at the measured frame
        var measuredAt: Double?        // timeline seconds of that frame
        var note: String?
    }

    func setChromaKey(_ clip: String, color: String?, tolerance: Double?, softness: Double?, spill: Double?, shrink: Double?, edgeBlur: Double?, time: Double?, remove: Bool) async throws -> ChromaKeyResult {
        let pc = try pictureClip(clip, for: "a green-screen key")
        if remove {
            guard pc.clip.effects.chromaKey != nil else { throw EditError.invalid("clip \(pc.id.short) has no key") }
            try document.apply("Remove key", origin: origin) { p in try p.updateClip(pc.id) { $0.effects.chromaKey = nil } }
            return ChromaKeyResult(clip: pc.id.short, name: pc.clip.name, removed: true)
        }
        let tol = try checked("tolerance", tolerance, ChromaKey.toleranceRange), soft = try checked("softness", softness, ChromaKey.softnessRange)
        let sp = try checked("spill", spill, ChromaKey.spillRange), sh = try checked("shrink", shrink, ChromaKey.shrinkRange), eb = try checked("edge_blur", edgeBlur, ChromaKey.edgeBlurRange)
        var key = pc.clip.effects.chromaKey ?? ChromaKey()
        let s = sourceTime(pc.clip, timeline: time)
        let frame = try await sourcePicture(pc.asset, at: s)
        var detected: Keyer.Detection?
        let wantsAuto = color?.lowercased() == "auto" || (color == nil && pc.clip.effects.chromaKey == nil)
        if wantsAuto {
            guard let cg = cgImage(frame, maxWidth: 480), let d = Keyer.detect(cg) else { throw EditError.invalid("the frame's edges hold no saturated colour to key; give the screen colour as color \"#RRGGBB\"") }
            guard d.confidence >= 0.3, (Keyer.saturation(d.hex) ?? 0) >= Keyer.minimumSaturation else {
                throw EditError.invalid("no clear screen colour at the frame's edges (the most common hue, \(d.hex), covers \(Int(d.confidence * 100)) % of them); give the colour as color \"#RRGGBB\" or measure another time")
            }
            detected = d; key.colorHex = d.hex; key.autoPicked = true
        } else if let color {
            guard Keyer.rgb(color) != nil else { throw EditError.invalid("color must be \"auto\" or a hex colour like #00B140 (got \(color))") }
            guard let sat = Keyer.saturation(color), sat >= Keyer.minimumSaturation else { throw EditError.invalid("\(color) is too grey to key: a key colour needs a clear hue, such as a green or blue screen") }
            let (r, g, b) = Keyer.rgb(color)!
            key.colorHex = Keyer.hex(r, g, b); key.autoPicked = false
        }
        if let tol { key.tolerance = tol }; if let soft { key.softness = soft }; if let sp { key.spill = sp }; if let sh { key.shrink = sh }; if let eb { key.edgeBlur = eb }
        let final = key
        try document.apply("Key \(pc.clip.name)", origin: origin, coalesce: coalesce) { p in try p.updateClip(pc.id) { $0.effects.chromaKey = final } }
        let stats = cgImage(Keyer.matte(frame, final), maxWidth: 320).map(Keyer.stats)
        var note: String?
        if let st = stats, st.keyedPercent < 5 { note = "almost nothing is keyed at this frame (\(st.keyedPercent) %): check the colour, or raise tolerance" }
        else if let st = stats, st.keptPercent < 5 { note = "almost everything is keyed at this frame (\(st.keyedPercent) % transparent): lower tolerance" }
        if pc.clip.effects.blend == .normal, belowIsEmpty(pc.id) { note = [note, "nothing plays under this clip on a lower video track, so the keyed-out area shows black"].compactMap { $0 }.joined(separator: "; ") }
        let tl = pc.clip.start + max(0, min(pc.clip.duration, (min(max(time ?? (UIRegistry.shared.playheads[document.id]?() ?? pc.clip.start), pc.clip.start), pc.clip.end) - pc.clip.start)))
        return ChromaKeyResult(clip: pc.id.short, name: pc.clip.name, removed: false, key: final, detected: detected?.hex, confidence: detected.map { round3($0.confidence) },
                               matte: stats, measuredAt: round3(tl), note: note)
    }

    struct KeyMatteResult: Codable { var clip: String, name: String, time: Double, width: Int, height: Int, matte: Keyer.MatteStats, key: ChromaKey }

    /// The key's matte at a time as a PNG: white = kept, black = keyed out, grey = partly.
    func keyMatte(_ clip: String, time: Double?, maxWidth: Int) async throws -> (KeyMatteResult, Data) {
        guard (64...4096).contains(maxWidth) else { throw EditError.invalid("max_width must be between 64 and 4096 (got \(maxWidth))") }
        let pc = try pictureClip(clip, for: "key_matte")
        guard let key = pc.clip.effects.chromaKey else { throw EditError.invalid("clip \(pc.id.short) has no key; set one with set_chroma_key first") }
        if let time, time < pc.clip.start - 0.001 || time > pc.clip.end + 0.001 { throw EditError.invalid("time \(fmt(time)) s is outside the clip (\(fmt(round3(pc.clip.start)))–\(fmt(round3(pc.clip.end))) s)") }
        let frame = try await sourcePicture(pc.asset, at: sourceTime(pc.clip, timeline: time))
        guard let cg = cgImage(Keyer.matte(frame, key), maxWidth: maxWidth) else { throw EditError.invalid("could not draw the matte") }
        let tl = min(max(time ?? (UIRegistry.shared.playheads[document.id]?() ?? pc.clip.start), pc.clip.start), pc.clip.end)
        return (KeyMatteResult(clip: pc.id.short, name: pc.clip.name, time: round3(tl), width: cg.width, height: cg.height, matte: Keyer.stats(cg), key: key), try png(cg))
    }

    /// True when no clip on a lower video track overlaps this one in time (the rows below are only black).
    fileprivate func belowIsEmpty(_ id: UUID) -> Bool {
        let p = document.project
        guard let ti = p.tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }), let c = p.clip(id)?.clip else { return true }
        return !p.tracks[(ti + 1)...].contains { t in t.kind == .video && !t.isHidden && t.clips.contains { $0.start < c.end - 0.001 && $0.end > c.start + 0.001 } }
    }

    // MARK: Blend modes

    struct BlendResult: Codable { var clip: String, name: String, mode: String, previous: String, note: String? }

    func setBlendMode(_ clip: String, mode: String) throws -> BlendResult {
        let pc = try pictureClip(clip, for: "a blend mode")
        guard let m = ClipBlendMode.parse(mode) else { throw EditError.invalid("mode must be one of \(ClipBlendMode.allCases.map(\.rawValue).joined(separator: ", ")) (got \(mode))") }
        let previous = pc.clip.effects.blend
        try document.apply("Blend \(m.title)", origin: origin, coalesce: coalesce) { p in try p.updateClip(pc.id) { $0.effects.blend = m } }
        var note: String?
        if m != .normal, belowIsEmpty(pc.id) { note = "nothing plays under this clip on a lower video track, so it blends with black" }
        return BlendResult(clip: pc.id.short, name: pc.clip.name, mode: m.rawValue, previous: previous.rawValue, note: note)
    }

    // MARK: Face and region blur

    struct FaceInfo: Codable { var id: Int, from: Double, to: Double, samples: Int, blurred: Bool }   // timeline seconds the face is seen
    struct RegionInfo: Codable { var id: Int, x: Double, y: Double, width: Double, height: Double, from: Double, to: Double, tracked: Bool, samples: Int }
    struct BlurResult: Codable {
        var clip: String, name: String, removed: Bool
        var style: String?, strength: Double?, expand: Double?, feather: Double?
        var faces: [FaceInfo], excluded: [Int], regions: [RegionInfo]
        var analysed: Bool, framesAnalysed: Int?
        var note: String?
    }

    /// Source seconds → timeline seconds in a clip (linear between its ends; exact for constant speed).
    fileprivate func timeline(_ c: Clip, source s: Double) -> Double {
        let span = max(1e-6, c.sourceOut - c.sourceIn)
        return round3(c.start + (s - c.sourceIn) / span * c.duration)
    }

    fileprivate func blurResult(_ id: UUID, removed: Bool, analysed: Bool, frames: Int?, note: String?) -> BlurResult {
        let p = document.project
        guard let c = p.clip(id)?.clip else { return BlurResult(clip: id.short, name: "", removed: removed, faces: [], excluded: [], regions: [], analysed: analysed, framesAnalysed: frames, note: note) }
        let h = p.hydrated(c)
        guard let fb = h.effects.blur else { return BlurResult(clip: id.short, name: c.name, removed: removed, faces: [], excluded: [], regions: [], analysed: analysed, framesAnalysed: frames, note: note) }
        let faces = fb.tracks.map { FaceInfo(id: $0.id, from: timeline(c, source: $0.start), to: timeline(c, source: $0.end), samples: $0.boxes.count, blurred: !fb.exclude.contains($0.id)) }
        let regions = fb.regions.map { r in RegionInfo(id: r.id, x: round3(r.x), y: round3(r.y), width: round3(r.w), height: round3(r.h), from: timeline(c, source: r.start), to: timeline(c, source: min(r.end, c.sourceOut)), tracked: !r.path.isEmpty, samples: r.path.count) }
        return BlurResult(clip: id.short, name: c.name, removed: removed, style: fb.style.rawValue, strength: fb.strength, expand: fb.expand, feather: fb.feather,
                          faces: faces, excluded: fb.exclude, regions: regions, analysed: analysed, framesAnalysed: frames, note: note)
    }

    fileprivate func parseStyle(_ style: String?) throws -> FaceBlur.Style? {
        guard let style else { return nil }
        let k = style.lowercased()
        if k == "black" || k == "blackbox" || k == "box" { return .solid }
        guard let s = FaceBlur.Style(rawValue: k) else { throw EditError.invalid("style must be blur, pixelate or solid (got \(style))") }
        return s
    }

    func blurFaces(_ clip: String, style: String?, strength: Double?, expand: Double?, feather: Double?, exclude: [Int]?, only: [Int]?, reanalyse: Bool, remove: Bool,
                   progress: (@Sendable (Double) -> Void)? = nil) async throws -> BlurResult {
        let pc = try pictureClip(clip, for: "face blur")
        if remove {
            guard let fb = pc.clip.effects.blur, !fb.pathKey.isEmpty else { throw EditError.invalid("clip \(pc.id.short) has no face blur") }
            try document.apply("Remove face blur", origin: origin) { p in
                try p.updateClip(pc.id) { c in
                    guard var b = c.effects.blur else { return }
                    b.pathKey = ""; b.tracks = []; b.faceCount = 0; b.exclude = []
                    c.effects.blur = b.regions.isEmpty ? nil : b
                }
            }
            return blurResult(pc.id, removed: true, analysed: false, frames: nil, note: fb.regions.isEmpty ? nil : "the clip's \(fb.regions.count) blur region\(fb.regions.count == 1 ? "" : "s") stay; remove them with blur_region remove")
        }
        let st = try parseStyle(style)
        let sg = try checked("strength", strength, FaceBlur.strengthRange), ex = try checked("expand", expand, FaceBlur.expandRange), fe = try checked("feather", feather, FaceBlur.featherRange)
        if exclude != nil, only != nil { throw EditError.invalid("give exclude or only, not both") }
        guard pc.asset.kind == .video else { throw EditError.invalid("clip \(pc.id.short) is a still; face blur follows faces through video (use blur_region for a still)") }
        guard pc.clip.multicam == nil else { throw EditError.invalid("clip \(pc.id.short) is a multicam clip; flatten it first (set_multicam flatten)") }
        let from = max(0, pc.clip.sourceIn - 0.2), to = min(pc.asset.duration, pc.clip.sourceOut + 0.2)
        let key = "faces|\(pc.asset.id.uuidString)|\((from * 1000).rounded())|\((to * 1000).rounded())"
        var tracks = document.project.faceTracks?[key]
        var frames: Int?
        let analysed = tracks == nil || reanalyse || pc.clip.effects.blur?.pathKey != key
        if analysed && (tracks == nil || reanalyse) {
            let url = pc.asset.url
            let worker = Task.detached(priority: .utility) { try await FaceAnalyzer.analyse(url: url, from: from, to: to) { p in progress?(p) } }
            let r = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard document.project.clip(pc.id) != nil else { throw EditError.notFound("clip \(pc.id.short): it was removed while analysing") }
            tracks = r.tracks; frames = r.frames
        }
        let found = tracks ?? []
        let ids = Set(found.map(\.id))
        for n in (exclude ?? []) + (only ?? []) where !ids.contains(n) {
            throw EditError.invalid("there is no face \(n); the analysis found \(found.isEmpty ? "none" : "faces " + found.map { String($0.id) }.joined(separator: ", "))")
        }
        let regions = pc.clip.effects.blur?.regions ?? []
        if found.isEmpty && regions.isEmpty {
            return BlurResult(clip: pc.id.short, name: pc.clip.name, removed: false, faces: [], excluded: [], regions: [], analysed: true, framesAnalysed: frames,
                              note: "no faces found in the clip (Vision's face detector, \(frames ?? 0) frames); nothing was changed. Use blur_region to blur a rectangle")
        }
        let excludeList: [Int]? = only.map { o in found.map(\.id).filter { !o.contains($0) } } ?? exclude
        try document.apply(analysed ? "Blur faces in \(pc.clip.name)" : "Face blur", origin: origin, coalesce: !analysed && coalesce) { p in
            if p.faceTracks == nil { p.faceTracks = [:] }
            p.faceTracks?[key] = found
            try p.updateClip(pc.id) { c in
                var b = c.effects.blur ?? FaceBlur()
                b.pathKey = key; b.tracks = []; b.faceCount = found.count
                if let st { b.style = st }; if let sg { b.strength = sg }; if let ex { b.expand = ex }; if let fe { b.feather = fe }
                if let excludeList { b.exclude = excludeList.sorted() } else if analysed { b.exclude = b.exclude.filter(ids.contains) }
                c.effects.blur = b
            }
        }
        var note: String?
        if found.isEmpty { note = "no faces found; the clip's regions are blurred" }
        else if found.contains(where: { $0.boxes.count < 4 }) { note = "some faces are seen only briefly (a few samples); check them with capture_frame" }
        return blurResult(pc.id, removed: false, analysed: analysed, frames: frames, note: note)
    }

    func blurRegion(_ clip: String, x: Double?, y: Double?, width: Double?, height: Double?, start: Double?, end: Double?, track: Bool, style: String?, strength: Double?, feather: Double?,
                    remove: String?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> BlurResult {
        let pc = try pictureClip(clip, for: "a blur region")
        if let remove {
            guard let fb = pc.clip.effects.blur, !fb.regions.isEmpty else { throw EditError.invalid("clip \(pc.id.short) has no blur regions") }
            let ids: [Int]
            if remove.lowercased() == "all" { ids = fb.regions.map(\.id) }
            else {
                guard let n = Int(remove), fb.regions.contains(where: { $0.id == n }) else { throw EditError.invalid("remove takes a region number (\(fb.regions.map { String($0.id) }.joined(separator: ", "))) or all (got \(remove))") }
                ids = [n]
            }
            try document.apply("Remove blur region", origin: origin) { p in
                try p.updateClip(pc.id) { c in
                    guard var b = c.effects.blur else { return }
                    b.regions.removeAll { ids.contains($0.id) }
                    c.effects.blur = b.isEmpty ? nil : b
                }
            }
            return blurResult(pc.id, removed: true, analysed: false, frames: nil, note: nil)
        }
        guard let x, let y, let width, let height else { throw EditError.invalid("x, y, width and height are required (normalized 0-1 to the clip's own picture, top-left corner, y down)") }
        _ = try checked("x", x, 0...1); _ = try checked("y", y, 0...1)
        _ = try checked("width", width, 0.01...1); _ = try checked("height", height, 0.01...1)
        guard x + width <= 1.0001, y + height <= 1.0001 else { throw EditError.invalid("the rectangle runs off the picture (x + width = \(fmt(x + width)), y + height = \(fmt(y + height)); both must be at most 1)") }
        let st = try parseStyle(style)
        let sg = try checked("strength", strength, FaceBlur.strengthRange), fe = try checked("feather", feather, FaceBlur.featherRange)
        let c = pc.clip
        let t0 = start ?? c.start, t1 = end ?? c.end
        guard t0 >= c.start - 0.001, t1 <= c.end + 0.001, t1 > t0 + 0.01 else { throw EditError.invalid("start and end must lie inside the clip (\(fmt(round3(c.start)))–\(fmt(round3(c.end))) s), start before end") }
        let s0 = c.sourceIn + c.sourceOffset(at: t0 - c.start), s1 = c.sourceIn + c.sourceOffset(at: min(t1, c.end) - c.start)
        if track && pc.asset.kind != .video { throw EditError.invalid("clip \(pc.id.short) is a still; there is nothing to track (leave track off)") }
        let nextID = (c.effects.blur?.regions.map(\.id).max() ?? 0) + 1
        var region = BlurRegion(id: nextID, x: x, y: y, w: width, h: height, start: s0, end: s1)
        var path: [BlurBox] = []
        var note: String?
        if track {
            let url = pc.asset.url, box = BlurBox(t: s0, x: x, y: y, w: width, h: height)
            let worker = Task.detached(priority: .utility) { try await FaceAnalyzer.trackRegion(url: url, box: box, from: s0, to: s1) { p in progress?(p) } }
            let r = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard document.project.clip(pc.id) != nil else { throw EditError.notFound("clip \(pc.id.short): it was removed while tracking") }
            path = r.path
            region.pathKey = "region|\(pc.asset.id.uuidString)|\(UUID().uuidString.prefix(8))"
            if let lost = r.lostAt { note = "tracking lost the region at \(fmt(timeline(c, source: lost))) s; it stays where it was last seen until the region ends" }
        }
        let finalRegion = region, finalPath = path
        try document.apply("Blur region", origin: origin) { p in
            if let k = finalRegion.pathKey {
                if p.faceTracks == nil { p.faceTracks = [:] }
                p.faceTracks?[k] = [FaceTrack(id: finalRegion.id, boxes: finalPath)]
            }
            try p.updateClip(pc.id) { c in
                var b = c.effects.blur ?? FaceBlur()
                b.regions.append(finalRegion)
                if let st { b.style = st }; if let sg { b.strength = sg }; if let fe { b.feather = fe }
                c.effects.blur = b
            }
        }
        return blurResult(pc.id, removed: false, analysed: track, frames: track ? path.count : nil, note: note)
    }

    // MARK: Titles

    struct TextAnimationResult: Codable { var text: String, content: String, animation: TextAnimation?, lowerThird: LowerThird?, note: String? }

    fileprivate func resolveText(_ text: String) throws -> TextOverlay {
        let p = document.project
        if let id = Project.resolve(text, in: p.texts.map(\.id)), let t = p.texts.first(where: { $0.id == id }) { return t }
        throw EditError.notFound("text '\(text)' (use the id inspect_timeline lists)")
    }

    fileprivate func parseKind(_ name: String, _ v: String?) throws -> TextAnimation.Kind? {
        guard let v else { return nil }
        guard let k = TextAnimation.Kind.parse(v) else { throw EditError.invalid("\(name) must be one of \(TextAnimation.Kind.allCases.map(\.rawValue).joined(separator: ", ")) (got \(v))") }
        return k
    }

    func setTextAnimation(_ text: String, inKind: String?, inDuration: Double?, outKind: String?, outDuration: Double?) throws -> TextAnimationResult {
        let t = try resolveText(text)
        let ik = try parseKind("in", inKind), ok = try parseKind("out", outKind)
        let id = try checked("in_duration", inDuration, TextAnimation.durationRange), od = try checked("out_duration", outDuration, TextAnimation.durationRange)
        guard ik != nil || ok != nil || id != nil || od != nil else { throw EditError.invalid("give at least one of in, in_duration, out, out_duration") }
        var a = t.animation ?? TextAnimation()
        if let ik { a.inKind = ik }; if let ok { a.outKind = ok }; if let id { a.inDuration = id }; if let od { a.outDuration = od }
        let used = (a.inKind == .none ? 0 : a.inDuration) + (a.outKind == .none ? 0 : a.outDuration)
        guard used <= t.duration + 0.001 else { throw EditError.invalid("the in and out animations (\(fmt(round3(used))) s together) are longer than the text (\(fmt(round3(t.duration))) s); shorten them or the text") }
        let final: TextAnimation? = a.isNone ? nil : a
        try document.apply("Animate text", origin: origin, coalesce: coalesce) { p in
            guard let i = p.texts.firstIndex(where: { $0.id == t.id }) else { throw EditError.notFound("text \(t.id.short)") }
            p.texts[i].animation = final
        }
        var note: String?
        if t.isCaption, final != nil { note = "this text is a caption; captions usually cut" }
        return TextAnimationResult(text: t.id.short, content: String(t.text.prefix(40)), animation: final, lowerThird: t.lowerThird, note: note)
    }

    func addLowerThird(name: String, role: String?, template: String?, start: Double?, duration: Double?, x: Double?, y: Double?, accent: String?, color: String?, fontSize: Double?,
                       inKind: String?, outKind: String?, text existing: String?) throws -> TextAnimationResult {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EditError.invalid("name is empty") }
        let tpl: LowerThird.Template?
        if let template { guard let tt = LowerThird.Template(rawValue: template.lowercased()) else { throw EditError.invalid("template must be bar, box or line (got \(template))") }; tpl = tt } else { tpl = nil }
        for (k, v) in [("accent", accent), ("color", color)] { if let v, Keyer.rgb(v) == nil { throw EditError.invalid("\(k) must be a hex colour like #FF9F0A (got \(v))") } }
        let fs = try checked("font_size", fontSize, 16...200)
        if let x { _ = try checked("x", x, 0...1) }; if let y { _ = try checked("y", y, 0...1) }
        if let duration { _ = try checked("duration", duration, 0.5...600) }
        if let start, start < 0 { throw EditError.invalid("start must be 0 or later (got \(fmt(start)))") }
        let ik = try parseKind("in", inKind), ok = try parseKind("out", outKind)
        let canvas = document.project.settings.canvas
        var t: TextOverlay
        if let existing {
            t = try resolveText(existing)
            if let start { t.start = start }; if let duration { t.duration = duration }
        } else {
            t = TextOverlay(text: name, start: start ?? (UIRegistry.shared.playheads[document.id]?() ?? 0), duration: duration ?? 4, fontSize: 56, colorHex: "#FFFFFF")
        }
        t.text = name
        var lt = t.lowerThird ?? LowerThird()
        if let tpl { lt.template = tpl }; if let role { lt.role = role }; if let accent { lt.accentHex = accent.uppercased().hasPrefix("#") ? accent.uppercased() : "#" + accent.uppercased() }
        t.lowerThird = lt
        if let fs { t.fontSize = fs }; if let color { t.colorHex = color.hasPrefix("#") ? color : "#" + color }
        var a = t.animation ?? (existing == nil ? TextAnimation(inKind: .wipe, inDuration: 0.6, outKind: .fade, outDuration: 0.4) : TextAnimation())
        if let ik { a.inKind = ik }; if let ok { a.outKind = ok }
        let used = (a.inKind == .none ? 0 : a.inDuration) + (a.outKind == .none ? 0 : a.outDuration)
        guard used <= t.duration + 0.001 else { throw EditError.invalid("the in and out animations (\(fmt(round3(used))) s) are longer than the lower third (\(fmt(round3(t.duration))) s)") }
        t.animation = a.isNone ? nil : a
        // Lower left by default: its left edge at 6 % of the width, its bottom at 88 % of the height.
        let size = TitleRasterizer.lowerThirdLayout(t, canvas: canvas).size
        if let x { t.x = x } else if existing == nil { t.x = round3(0.06 + size.width / canvas.width / 2) }
        if let y { t.y = y } else if existing == nil { t.y = round3(0.88 - size.height / canvas.height / 2) }
        guard size.width <= canvas.width * 1.001, size.height <= canvas.height * 0.6 else { throw EditError.invalid("the lower third (\(Int(size.width))×\(Int(size.height)) px) does not fit the \(Int(canvas.width))×\(Int(canvas.height)) frame; use a smaller font_size or shorter lines") }
        let final = t
        try document.apply(existing == nil ? "Add lower third" : "Edit lower third", origin: origin, coalesce: existing != nil && coalesce) { p in
            if let i = p.texts.firstIndex(where: { $0.id == final.id }) { p.texts[i] = final } else { p.texts.append(final) }
        }
        let box = TextLayout.box(final, canvas: canvas)
        var note: String?
        if box.minX < -0.001 || box.maxX > 1.001 || box.minY < -0.001 || box.maxY > 1.001 { note = "part of the lower third is outside the frame; move it with x / y" }
        let blockers = TextLayout.blockers(of: final, among: document.project.texts, canvas: canvas)
        if !blockers.isEmpty { note = [note, "it overlaps \(blockers.map { "'\($0.text.prefix(20))'" }.joined(separator: ", ")) on screen"].compactMap { $0 }.joined(separator: "; ") }
        return TextAnimationResult(text: final.id.short, content: final.text, animation: final.animation, lowerThird: final.lowerThird, note: note)
    }

    // MARK: Project colour

    struct ProjectColorResult: Codable { var color: String, title: String, previous: String, note: String }

    func setProjectColor(_ color: String) throws -> ProjectColorResult {
        guard let c = ProjectColor.parse(color) else { throw EditError.invalid("color must be sdr, hlg or pq (got \(color))") }
        let previous = document.project.settings.color
        try document.apply("Colour: \(c.title)", origin: origin) { p in p.settings.color = c }
        let note = c.isHDR
            ? "HDR \(c == .pq ? "PQ" : "HLG") in Rec.2020: the hevc10 / ProRes masters carry it (SDR sources sit at 203-nit reference white; HLG and PQ sources keep their highlights); the preview, high / medium / low H.264 exports and capture_frame stay SDR, with HDR sources tone-mapped. Grades, LUTs and the green-screen key work in 0-1, so their output above SDR white is clipped."
            : "SDR Rec.709: every frame passes through unmanaged, as before."
        return ProjectColorResult(color: c.rawValue, title: c.title, previous: previous.rawValue, note: note)
    }

    // MARK: Inspector edits (synchronous: sliders and pickers, no frame reads or analysis)

    /// Changes an existing key's values (or starts one with `color`), validated like set_chroma_key.
    @discardableResult
    func adjustChromaKey(_ clip: String, color: String? = nil, tolerance: Double? = nil, softness: Double? = nil, spill: Double? = nil, shrink: Double? = nil, edgeBlur: Double? = nil) throws -> ChromaKey {
        let pc = try pictureClip(clip, for: "a green-screen key")
        var key = pc.clip.effects.chromaKey ?? ChromaKey()
        if let color {
            guard let (r, g, b) = Keyer.rgb(color) else { throw EditError.invalid("color must be a hex colour like #00B140 (got \(color))") }
            guard let sat = Keyer.saturation(color), sat >= Keyer.minimumSaturation else { throw EditError.invalid("\(color) is too grey to key: a key colour needs a clear hue") }
            key.colorHex = Keyer.hex(r, g, b); key.autoPicked = false
        }
        if let v = try checked("tolerance", tolerance, ChromaKey.toleranceRange) { key.tolerance = v }
        if let v = try checked("softness", softness, ChromaKey.softnessRange) { key.softness = v }
        if let v = try checked("spill", spill, ChromaKey.spillRange) { key.spill = v }
        if let v = try checked("shrink", shrink, ChromaKey.shrinkRange) { key.shrink = v }
        if let v = try checked("edge_blur", edgeBlur, ChromaKey.edgeBlurRange) { key.edgeBlur = v }
        let final = key
        try document.apply("Key \(pc.clip.name)", origin: origin, coalesce: coalesce) { p in try p.updateClip(pc.id) { $0.effects.chromaKey = final } }
        return final
    }

    /// Changes the blur look or which faces stay sharp, on a clip that already has a face blur or regions.
    @discardableResult
    func adjustBlur(_ clip: String, style: String? = nil, strength: Double? = nil, expand: Double? = nil, feather: Double? = nil, exclude: [Int]? = nil) throws -> FaceBlur {
        let pc = try pictureClip(clip, for: "face blur")
        guard var b = pc.clip.effects.blur else { throw EditError.invalid("clip \(pc.id.short) has no face blur or blur regions; run blur_faces first") }
        if let st = try parseStyle(style) { b.style = st }
        if let v = try checked("strength", strength, FaceBlur.strengthRange) { b.strength = v }
        if let v = try checked("expand", expand, FaceBlur.expandRange) { b.expand = v }
        if let v = try checked("feather", feather, FaceBlur.featherRange) { b.feather = v }
        if let exclude {
            for n in exclude where !(1...max(1, b.faceCount)).contains(n) || b.faceCount == 0 { throw EditError.invalid("there is no face \(n)") }
            b.exclude = Array(Set(exclude)).sorted()
        }
        let final = b
        try document.apply("Face blur", origin: origin, coalesce: coalesce) { p in try p.updateClip(pc.id) { $0.effects.blur = final } }
        return final
    }

    /// Turns a lower third back into a plain title (its name stays as the text).
    func removeLowerThird(_ text: String) throws {
        let t = try resolveText(text)
        guard t.lowerThird != nil else { throw EditError.invalid("text \(t.id.short) is not a lower third") }
        try document.apply("Plain title", origin: origin) { p in
            guard let i = p.texts.firstIndex(where: { $0.id == t.id }) else { throw EditError.notFound("text \(t.id.short)") }
            p.texts[i].lowerThird = nil
        }
    }

    // MARK: inspect_timeline

    /// The effects summary per clip and per text, filled into `inspect_timeline` after the main listing.
    func addEffects(to s: inout TimelineSummary) {
        let p = document.project
        for i in s.clips.indices {
            guard let c = p.allClips.first(where: { $0.id.short == s.clips[i].id }), !c.effects.isDefault else { continue }
            var e: [String: String] = [:]
            if let k = c.effects.chromaKey { e["key"] = "\(k.colorHex) tolerance \(fmt(k.tolerance)) softness \(fmt(k.softness)) spill \(fmt(k.spill))\(k.shrink != 0 ? " shrink \(fmt(k.shrink))" : "")\(k.edgeBlur > 0 ? " edge blur \(fmt(k.edgeBlur))" : "")" }
            if c.effects.blend != .normal { e["blend"] = c.effects.blend.rawValue }
            if let b = c.effects.blur {
                if !b.pathKey.isEmpty { e["faceBlur"] = "\(b.style.rawValue), \(b.faceCount) face\(b.faceCount == 1 ? "" : "s")\(b.exclude.isEmpty ? "" : ", sharp: \(b.exclude.map(String.init).joined(separator: ", "))")" }
                if !b.regions.isEmpty { e["blurRegions"] = "\(b.regions.count) (\(b.style.rawValue))" }
            }
            s.clips[i].effects = e
        }
        for i in s.texts.indices {
            guard let t = p.texts.first(where: { $0.id.short == s.texts[i].id }) else { continue }
            s.texts[i].animation = t.animation
            s.texts[i].lowerThird = t.lowerThird
        }
        if p.settings.color.isHDR { s.color = p.settings.color.rawValue }
    }
}
