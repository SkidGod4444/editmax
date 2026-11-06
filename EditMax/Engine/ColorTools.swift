import Foundation
import AVFoundation
import AppKit
import CoreImage
import SwiftUI

/// The color tools: wheels, curves, scopes, shot match, finishing, grade layers and masks. One implementation for the
/// inspector, the MCP tools and the chat, like the rest of `ToolExecutor`. Every tool refuses out-of-range input with
/// an error instead of clamping it.
extension ToolExecutor {
    /// Where a color edit lands: the clip's primary grade, or one of its grade layers.
    enum GradeTarget: Equatable { case primary, layer(UUID) }

    private func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    func checkRange(_ name: String, _ v: Double?, _ lo: Double, _ hi: Double) throws {
        guard let v else { return }
        guard v.isFinite, v >= lo, v <= hi else { throw EditError.invalid("\(name) must be between \(ProjectDiff.fmt(lo)) and \(ProjectDiff.fmt(hi)) (got \(ProjectDiff.fmt(v)))") }
    }

    /// A video clip, for the color tools.
    func colorClip(_ text: String) throws -> Clip {
        let id = try resolveClip(text)
        guard let (track, clip) = document.project.clip(id) else { throw EditError.notFound("clip '\(text)'") }
        guard track.kind == .video else { throw EditError.invalid("clip \(clip.id.short) is on an audio track; color applies to video clips") }
        return clip
    }

    /// A grade layer of a clip by name (any case) or id prefix.
    func resolveLayer(_ text: String, in clip: Clip) throws -> UUID {
        if let id = Project.resolve(text, in: clip.grades.map(\.id)) { return id }
        let byName = clip.grades.filter { $0.name.caseInsensitiveCompare(text) == .orderedSame }
        if byName.count == 1 { return byName[0].id }
        let list = clip.grades.isEmpty ? "it has none (add one with add_grade_layer)" : "its layers are " + clip.grades.map { "'\($0.name)' (\($0.id.short))" }.joined(separator: ", ")
        if byName.count > 1 { throw EditError.invalid("\(byName.count) layers of clip \(clip.id.short) are named '\(text)'; use an id: \(byName.map(\.id.short).joined(separator: ", "))") }
        throw EditError.notFound("grade layer '\(text)' on clip \(clip.id.short): \(list)")
    }

    func target(_ layer: String?, in clip: Clip) throws -> GradeTarget {
        guard let layer, !layer.isEmpty else { return .primary }
        return .layer(try resolveLayer(layer, in: clip))
    }

    /// The ClipColor a target holds.
    func color(of clip: Clip, _ t: GradeTarget) -> ClipColor {
        switch t {
        case .primary: return clip.color
        case .layer(let id): return clip.grades.first { $0.id == id }?.color ?? ClipColor()
        }
    }

    /// Changes the ClipColor of a target in one recorded edit (slider callers coalesce).
    func editColor(_ clipID: UUID, _ t: GradeTarget, label: String, _ body: @escaping (inout ClipColor) -> Void) throws {
        try document.apply(label, origin: origin, coalesce: coalesce) { p in
            try p.updateClip(clipID) { c in
                switch t {
                case .primary: body(&c.color)
                case .layer(let id): if let i = c.grades.firstIndex(where: { $0.id == id }) { body(&c.grades[i].color) }
                }
            }
        }
    }

    // MARK: Wheels

    struct WheelsResult: Codable {
        var clip: String, layer: String?, wheel: String
        var value: ColorWheel
        /// master + balance per channel (r, g, b), what the formula uses.
        var effective: [Double]
        var wheels: ColorWheels?
        var note: String
    }

    /// Stores the whole wheel set (nil when untouched, so an ungraded clip stays identical to before).
    func setWheels(_ clipID: UUID, target t: GradeTarget, _ wheels: ColorWheels) throws {
        try editColor(clipID, t, label: "Color wheels") { $0.wheels = wheels.isIdentity ? nil : wheels }
    }

    func setColorWheels(_ clip: String, layer: String?, wheel: String, r: Double?, g: Double?, b: Double?, master: Double?, toward: String?, amount: Double?, reset: Bool) throws -> WheelsResult {
        let c = try colorClip(clip)
        let t = try target(layer, in: c)
        let all = wheel.lowercased() == "all"
        guard all || ColorWheels.Name(rawValue: wheel.lowercased()) != nil else { throw EditError.invalid("wheel must be lift, gamma, gain or offset (or all with reset true), not '\(wheel)'") }
        if all {
            guard reset, r == nil, g == nil, b == nil, master == nil, toward == nil, amount == nil else { throw EditError.invalid("wheel 'all' only clears every wheel: pass reset true and no values") }
            try setWheels(c.id, target: t, ColorWheels())
            return WheelsResult(clip: c.id.short, layer: layer, wheel: "all", value: ColorWheel(), effective: [0, 0, 0], wheels: nil, note: "Cleared lift, gamma, gain and offset")
        }
        let name = ColorWheels.Name(rawValue: wheel.lowercased())!
        for (k, v) in [("r", r), ("g", g), ("b", b), ("master", master), ("amount", amount)] { try checkRange(k, v, -1, 1) }
        if toward != nil || amount != nil {
            guard let toward, let amount else { throw EditError.invalid("toward and amount go together: a hue (degrees or a word such as blue, teal, warm) and how far, -1 to 1") }
            guard r == nil, g == nil, b == nil else { throw EditError.invalid("give either r/g/b or toward + amount, not both") }
            guard ColorBalance.hue(toward) != nil else { throw EditError.invalid("toward '\(toward)' is not a hue: give degrees (0 red, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta) or one of \(ColorBalance.named.map(\.0).joined(separator: ", "))") }
        }
        guard reset || r != nil || g != nil || b != nil || master != nil || toward != nil else { throw EditError.invalid("nothing to change: pass r, g, b, master, toward + amount, or reset") }
        var wheels = color(of: c, t).wheels ?? ColorWheels()
        var w = reset ? ColorWheel() : wheels[name]
        if let toward, let amount, let h = ColorBalance.hue(toward) { let bal = ColorBalance.toward(hue: h, amount: amount); w.r = r3(bal.r); w.g = r3(bal.g); w.b = r3(bal.b) }
        if let r { w.r = r }; if let g { w.g = g }; if let b { w.b = b }
        if let master { w.master = master }
        wheels[name] = w
        try setWheels(c.id, target: t, wheels)
        let eff = w.channels.map(r3)
        let what: String
        switch name {
        case .lift: what = "black moves to \(eff.map { ProjectDiff.fmt($0) }.joined(separator: "/")) (r/g/b), white stays"
        case .gamma: what = "mid-gray 0.5 becomes \((0..<3).map { ProjectDiff.fmt(r3(pow(0.5, pow(2, -2 * eff[$0])))) }.joined(separator: "/")) (r/g/b)"
        case .gain: what = "white becomes \(eff.map { ProjectDiff.fmt(r3(max(0, 1 + $0))) }.joined(separator: "/")) (r/g/b), black stays"
        case .offset: what = "every level moves by \(eff.map { ProjectDiff.fmt($0) }.joined(separator: "/")) (r/g/b)"
        }
        let saved = document.project.clip(c.id).map { color(of: $0.clip, t).wheels } ?? nil
        return WheelsResult(clip: c.id.short, layer: layer, wheel: name.rawValue, value: w, effective: eff, wheels: saved, note: "\(name.title): \(what)")
    }

    // MARK: Curves

    struct CurveResult: Codable {
        var clip: String, layer: String?, curve: String
        var points: [[Double]]
        /// The curve's output at x = 0, 0.25, 0.5, 0.75, 1 (hue_sat: the saturation gain at red, yellow, green, cyan, blue, magenta).
        var samples: [Double]
        var curves: ColorCurves?
    }

    func setCurves(_ clipID: UUID, target t: GradeTarget, _ curves: ColorCurves) throws {
        try editColor(clipID, t, label: "Curves") { $0.curves = curves.isIdentity ? nil : curves }
    }

    /// Checks one curve's points and returns them sorted.
    static func validCurve(_ name: ColorCurves.Name, _ points: [[Double]]) throws -> [CurvePoint] {
        guard points.count <= 32 else { throw EditError.invalid("a curve takes at most 32 points (got \(points.count))") }
        let yMax = name == .hueSat ? 2.0 : 1.0
        var out: [CurvePoint] = []
        for (i, p) in points.enumerated() {
            guard p.count == 2 else { throw EditError.invalid("point \(i + 1) must be [x, y], got \(p.count) numbers") }
            guard p[0].isFinite, p[0] >= 0, p[0] <= 1 else { throw EditError.invalid("point \(i + 1): x must be between 0 and 1 (got \(ProjectDiff.fmt(p[0])))") }
            guard p[1].isFinite, p[1] >= 0, p[1] <= yMax else { throw EditError.invalid("point \(i + 1): y must be between 0 and \(ProjectDiff.fmt(yMax)) for \(name.argName) (got \(ProjectDiff.fmt(p[1])))") }
            out.append(CurvePoint(p[0], p[1]))
        }
        out.sort { $0.x < $1.x }
        for (a, b) in zip(out, out.dropFirst()) where b.x - a.x < 0.01 {
            throw EditError.invalid("points at x \(ProjectDiff.fmt(a.x)) and \(ProjectDiff.fmt(b.x)) are closer than 0.01; keep x values apart")
        }
        if name == .hueSat, let f = out.first, let l = out.last, f.x + 1 - l.x < 0.01, out.count > 1 { throw EditError.invalid("hue_sat wraps around: x \(ProjectDiff.fmt(l.x)) and \(ProjectDiff.fmt(f.x)) are the same hue") }
        return out
    }

    func setColorCurve(_ clip: String, layer: String?, curve: String, points: [[Double]]) throws -> CurveResult {
        let c = try colorClip(clip)
        let t = try target(layer, in: c)
        let key = curve.lowercased().replacingOccurrences(of: "-", with: "_")
        guard let name = ColorCurves.Name.allCases.first(where: { $0.argName == key || $0.rawValue.lowercased() == key }) else {
            throw EditError.invalid("curve must be master, red, green, blue or hue_sat, not '\(curve)'")
        }
        let pts = try Self.validCurve(name, points)
        var curves = color(of: c, t).curves ?? ColorCurves()
        curves[name] = pts
        try setCurves(c.id, target: t, curves)
        let spline = CurveSpline(pts, periodic: name == .hueSat)
        let xs: [Double] = name == .hueSat ? (0..<6).map { Double($0) / 6 } : [0, 0.25, 0.5, 0.75, 1]
        let samples: [Double] = pts.isEmpty ? (name == .hueSat ? xs.map { _ in 1.0 } : xs) : xs.map { r3(spline.value($0)) }
        let saved = document.project.clip(c.id).map { color(of: $0.clip, t).curves } ?? nil
        return CurveResult(clip: c.id.short, layer: layer, curve: name.argName, points: pts.map { [$0.x, $0.y] }, samples: samples, curves: saved)
    }
}

// MARK: - Scopes

extension ToolExecutor {
    struct ScopesSummary: Codable {
        var time: Double, width: Int, height: Int
        var parade: ColorScopes.ParadeStats, vectorscope: ColorScopes.VectorStats
        var lumaMean: Double
        var image: String
    }

    /// RGBA8 pixels of a frame scaled to `width` (what `frameStats` measures).
    static func samplePixels(_ frame: CGImage, width w: Int = 320) -> (px: [UInt8], w: Int, h: Int)? {
        let h = max(1, Int(Double(w) * Double(frame.height) / Double(max(1, frame.width))))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (px, w, h)
    }

    /// The scopes panel for a frame, as a PNG `width` pixels wide (waveform, parade, vectorscope, histogram).
    static func scopesPNG(_ frame: CGImage, width: Int) throws -> (Data, ScopeData) {
        guard let buf = ColorScopes.pixelBuffer(frame), let data = ScopeSampler.sample(buf) else { throw EditError.invalid("could not sample the frame for the scopes") }
        let w = CGFloat(width), h = max(140, (w / 4.2).rounded())
        let renderer = ImageRenderer(content: ScopesView(data: data, height: h).frame(width: w, height: h).environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw EditError.invalid("could not draw the scopes") }
        return (png, data)
    }

    /// The scopes of the composed frame at a time, as an image and numbers.
    func captureScopes(at seconds: Double, maxWidth: Int) async throws -> (png: Data, summary: ScopesSummary) {
        guard maxWidth >= 400, maxWidth <= 2400 else { throw EditError.invalid("max_width must be between 400 and 2400 (got \(maxWidth))") }
        let (frame, _) = try await renderFrame(at: seconds)
        let (png, data) = try Self.scopesPNG(frame, width: maxWidth)
        guard let s = Self.samplePixels(frame) else { throw EditError.invalid("could not sample the frame") }
        let (parade, vector) = ColorScopes.stats(rgba: s.px)
        return (png, ScopesSummary(time: (seconds * 1000).rounded() / 1000, width: frame.width, height: frame.height, parade: parade, vectorscope: vector,
                                   lumaMean: (data.lumaMean * 10).rounded() / 10,
                                   image: "Left to right: luma waveform (0 at the bottom to 255 at the top, across the frame), RGB parade (the same per channel), vectorscope (centre = gray; the boxes are 75% R, Mg, B, Cy, G, Yl; the faint orange line is skin tone), RGB histogram"))
    }
}

// MARK: - Solo renders (shot match, mattes)

extension ToolExecutor {
    /// A project holding only `clip` at time 0, with no fades, transition, opacity, titles or other tracks, so a render
    /// shows exactly the clip's colour. `pictureOnly` also drops the position and size and gives the canvas the picture's
    /// (cropped) shape, so no letterbox bars enter the measurement. `modify` changes the copy (its id is fresh).
    static func soloProject(_ p: Project, clip: Clip, pictureOnly: Bool = false, _ modify: (inout Clip) -> Void = { _ in }) -> (Project, Clip) {
        var q = p
        q.texts = []; q.markers = []; q.history = []
        q.settings.useProxies = false
        var c = clip
        c.id = UUID(); c.start = 0; c.fadeIn = 0; c.fadeOut = 0; c.transitionIn = nil; c.opacity = 1
        c.animations.removeValue(forKey: ClipParam.opacity.rawValue)
        if pictureOnly, let a = p.assets.first(where: { $0.id == clip.assetID }), let aw = a.width, let ah = a.height, aw > 0, ah > 0 {
            let t = clip.transform
            var keep = ClipTransform()
            keep.cropLeft = t.cropLeft; keep.cropRight = t.cropRight; keep.cropTop = t.cropTop; keep.cropBottom = t.cropBottom
            c.transform = keep
            for k in [ClipParam.scale, .x, .y, .rotation] { c.animations.removeValue(forKey: k.rawValue) }
            let w = Double(aw) * max(0.01, 1 - t.cropLeft - t.cropRight), h = Double(ah) * max(0.01, 1 - t.cropTop - t.cropBottom)
            let s = min(1, 960 / max(w, h))
            q.settings.width = max(16, Int((w * s / 2).rounded()) * 2); q.settings.height = max(16, Int((h * s / 2).rounded()) * 2)
        }
        modify(&c)
        var track = Track(name: "V1", kind: .video)
        track.clips = [c]
        q.tracks = [track]
        return (q, c)
    }

    /// The composed frame of a project at a time (as `renderFrame`, for a project that is not the document's).
    static func frame(of project: Project, at seconds: Double) async throws -> CGImage {
        // AVFoundation sometimes fails a composition render once (-11800 / -12780) and succeeds right after.
        do { return try await frameOnce(of: project, at: seconds) } catch let e as NSError where e.domain == AVFoundationErrorDomain {
            return try await frameOnce(of: project, at: seconds)
        }
    }

    private static func frameOnce(of project: Project, at seconds: Double) async throws -> CGImage {
        let out = try await CompositionBuilder.build(project)
        let gen = AVAssetImageGenerator(asset: out.composition)
        gen.videoComposition = out.videoComposition
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let t = CMTime(seconds: min(max(0, seconds), max(0, out.duration.seconds - 0.05)), preferredTimescale: CompositionBuilder.timescale)
        let raw = try await gen.image(at: t).image
        return raw.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? raw
    }

    /// A clip's frame on its own, `local` seconds into the clip.
    func soloFrame(_ clip: Clip, local: Double, pictureOnly: Bool = false, _ modify: (inout Clip) -> Void = { _ in }) async throws -> CGImage {
        let (p, _) = Self.soloProject(document.project, clip: clip, pictureOnly: pictureOnly, modify)
        return try await Self.frame(of: p, at: local)
    }

    /// A timeline time inside a clip (default: its middle), as seconds into the clip.
    func localTime(_ seconds: Double?, in clip: Clip, _ name: String) throws -> Double {
        guard let seconds else { return clip.duration / 2 }
        guard seconds.isFinite, seconds >= clip.start - 1e-6, seconds <= clip.end + 1e-6 else {
            throw EditError.invalid("\(name) \(ProjectDiff.fmt(seconds)) s is outside clip \(clip.id.short) (\(ProjectDiff.fmt(clip.start)) to \(ProjectDiff.fmt(clip.end)) s)")
        }
        return min(max(0, seconds - clip.start), max(0, clip.duration - 0.05))
    }
}

// MARK: - Grade layers

extension ToolExecutor {
    static let maxGradeLayers = 12

    struct LayerInfo: Codable {
        var id: String, index: Int, name: String, enabled: Bool, mix: Double
        /// What the layer changes, in words.
        var grade: String
        var mask: String
    }
    struct LayersResult: Codable {
        var clip: String, changed: String
        var layers: [LayerInfo]
        var note: String
    }

    static func gradeSummary(_ c: ClipColor) -> String {
        var parts: [String] = []
        let f = ProjectDiff.fmt
        if c.exposure != 0 { parts.append("exposure \(f(c.exposure))") }
        if c.contrast != 1 { parts.append("contrast \(f(c.contrast))") }
        if c.saturation != 1 { parts.append("saturation \(f(c.saturation))") }
        if c.temperature != 0 { parts.append("temperature \(f(c.temperature))") }
        if c.tint != 0 { parts.append("tint \(f(c.tint))") }
        if c.shadows != 0 || c.midtones != 0 || c.highlights != 0 { parts.append("tone \(f(c.shadows))/\(f(c.midtones))/\(f(c.highlights))") }
        if c.vibrance != 0 { parts.append("vibrance \(f(c.vibrance))") }
        if let w = c.wheels, !w.isIdentity { parts.append("wheels \(w)") }
        if let cv = c.curves, !cv.isIdentity { parts.append("curves \(cv)") }
        if let l = c.lut { parts.append("look \(l) \(f(c.lutMix))") }
        return parts.isEmpty ? "nothing yet" : parts.joined(separator: ", ")
    }

    static func maskSummary(_ m: GradeMask?) -> String {
        guard let m, !m.isEmpty else { return m?.invert == true ? "none, inverted (the layer applies nowhere)" : "none (whole frame)" }
        var parts: [String] = []
        let f = ProjectDiff.fmt
        if let s = m.shape { parts.append("\(s.kind.rawValue) at (\(f(s.centerX)), \(f(s.centerY))) size \(f(s.width))x\(f(s.height))\(s.rotation != 0 ? " rotated \(f(s.rotation))°" : "") feather \(f(s.feather))\(s.invert ? " inverted" : "")") }
        if let q = m.qualifier { parts.append("qualifier hue \(f(q.hueCenter))±\(f(q.hueWidth / 2))°, sat \(f(q.satLow))-\(f(q.satHigh)), luma \(f(q.lumaLow))-\(f(q.lumaHigh))") }
        if let s = m.subject { parts.append("\(s.kind.rawValue) (AI subject mask)") }
        return parts.joined(separator: " and ") + (m.invert ? ", whole mask inverted" : "")
    }

    func layersResult(_ clipID: UUID, _ changed: String, note: String = "") -> LayersResult {
        let c = document.project.clip(clipID)?.clip
        let layers = (c?.grades ?? []).enumerated().map { i, l in
            LayerInfo(id: l.id.short, index: i, name: l.name, enabled: l.enabled, mix: r3(l.mix), grade: Self.gradeSummary(l.color), mask: Self.maskSummary(l.mask))
        }
        let order = "Layers apply first to last after the clip's own grade, each on the result of the one before, inside its mask, blended by its mix; finishing (grain, glow, vignette...) comes after all of them."
        return LayersResult(clip: clipID.short, changed: changed, layers: layers, note: note.isEmpty ? order : note + " " + order)
    }

    private func checkName(_ name: String?) throws -> String? {
        guard let name else { return nil }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 40 else { throw EditError.invalid("a layer name must be 1 to 40 characters") }
        return n
    }

    func addGradeLayer(_ clip: String, name: String?, index: Int?, mix: Double?, enabled: Bool?) throws -> LayersResult {
        let c = try colorClip(clip)
        guard c.grades.count < Self.maxGradeLayers else { throw EditError.invalid("clip \(c.id.short) already has \(Self.maxGradeLayers) grade layers, the most allowed") }
        let n = try checkName(name) ?? "Layer \(c.grades.count + 1)"
        if let index, index < 0 || index > c.grades.count { throw EditError.invalid("index must be 0 to \(c.grades.count) (got \(index))") }
        try checkRange("mix", mix, 0, 1)
        var layer = GradeLayer(name: n)
        if let mix { layer.mix = mix }
        if let enabled { layer.enabled = enabled }
        let at = index ?? c.grades.count
        try document.apply("Add grade layer", origin: origin, coalesce: false) { p in try p.updateClip(c.id) { $0.grades.insert(layer, at: at) } }
        return layersResult(c.id, "added '\(n)' (\(layer.id.short)) at index \(at)", note: "It changes nothing until you grade it: set_color_wheels or set_color_curve with layer \(layer.id.short), or update_grade_layer for exposure, saturation and the rest; set_layer_mask limits where it applies.")
    }

    struct LayerColorChange {
        var exposure: Double? = nil, contrast: Double? = nil, saturation: Double? = nil, temperature: Double? = nil, tint: Double? = nil
        var shadows: Double? = nil, midtones: Double? = nil, highlights: Double? = nil, vibrance: Double? = nil, lookMix: Double? = nil
        var look: String? = nil
        var reset = false
        var isEmpty: Bool { [exposure, contrast, saturation, temperature, tint, shadows, midtones, highlights, vibrance, lookMix].allSatisfy { $0 == nil } && look == nil && !reset }
    }

    func updateGradeLayer(_ clip: String, layer: String, name: String?, enabled: Bool?, mix: Double?, color ch: LayerColorChange) throws -> LayersResult {
        let c = try colorClip(clip)
        let id = try resolveLayer(layer, in: c)
        let n = try checkName(name)
        try checkRange("mix", mix, 0, 1)
        try checkRange("exposure", ch.exposure, -4, 4); try checkRange("contrast", ch.contrast, 0.25, 3); try checkRange("saturation", ch.saturation, 0, 3)
        try checkRange("temperature", ch.temperature, -100, 100); try checkRange("tint", ch.tint, -100, 100)
        try checkRange("shadows", ch.shadows, -1, 1); try checkRange("midtones", ch.midtones, -1, 1); try checkRange("highlights", ch.highlights, -1, 1)
        try checkRange("vibrance", ch.vibrance, -1, 1); try checkRange("look_mix", ch.lookMix, 0, 1)
        var look: String?? = nil
        if let l = ch.look {
            if l.isEmpty || l.lowercased() == "none" { look = .some(nil) }
            else {
                guard Looks.isBuiltin(l) || FileManager.default.fileExists(atPath: l) else { throw EditError.notFound("look '\(l)': use one of \(Looks.builtin.joined(separator: ", ")) or the path of a .cube file") }
                guard Looks.cube(for: l) != nil else { throw EditError.invalid("could not read the LUT at \(l)") }
                look = .some(Looks.builtin.first { $0.caseInsensitiveCompare(l) == .orderedSame } ?? l)
            }
        }
        guard n != nil || enabled != nil || mix != nil || !ch.isEmpty else { throw EditError.invalid("nothing to change: pass name, enabled, mix or a colour value") }
        try document.apply("Grade layer", origin: origin, coalesce: coalesce) { p in
            try p.updateClip(c.id) { cl in
                guard let i = cl.grades.firstIndex(where: { $0.id == id }) else { return }
                if let n { cl.grades[i].name = n }
                if let enabled { cl.grades[i].enabled = enabled }
                if let mix { cl.grades[i].mix = mix }
                var k = cl.grades[i].color
                if ch.reset { k = ClipColor() }
                if let v = ch.exposure { k.exposure = v }
                if let v = ch.contrast { k.contrast = v }
                if let v = ch.saturation { k.saturation = v }
                if let v = ch.temperature { k.temperature = v }
                if let v = ch.tint { k.tint = v }
                if let v = ch.shadows { k.shadows = v }
                if let v = ch.midtones { k.midtones = v }
                if let v = ch.highlights { k.highlights = v }
                if let v = ch.vibrance { k.vibrance = v }
                if let v = ch.lookMix { k.lutMix = v }
                if let look { k.lut = look }
                cl.grades[i].color = k
            }
        }
        return layersResult(c.id, "updated layer \(id.short)")
    }

    func removeGradeLayer(_ clip: String, layer: String) throws -> LayersResult {
        let c = try colorClip(clip)
        let id = try resolveLayer(layer, in: c)
        let name = c.grades.first { $0.id == id }?.name ?? ""
        try document.apply("Remove grade layer", origin: origin, coalesce: false) { p in try p.updateClip(c.id) { $0.grades.removeAll { $0.id == id } } }
        return layersResult(c.id, "removed '\(name)' (\(id.short))")
    }

    func moveGradeLayer(_ clip: String, layer: String, to index: Int) throws -> LayersResult {
        let c = try colorClip(clip)
        let id = try resolveLayer(layer, in: c)
        guard index >= 0, index < c.grades.count else { throw EditError.invalid("index must be 0 to \(c.grades.count - 1) (got \(index))") }
        guard let from = c.grades.firstIndex(where: { $0.id == id }), from != index else { throw EditError.invalid("layer \(id.short) is already at index \(index)") }
        try document.apply("Move grade layer", origin: origin, coalesce: false) { p in
            try p.updateClip(c.id) { cl in let l = cl.grades.remove(at: from); cl.grades.insert(l, at: index) }
        }
        return layersResult(c.id, "moved layer \(id.short) from index \(from) to \(index)")
    }
}

// MARK: - Shot match

extension ToolExecutor {
    struct MatchResult: Codable {
        var clip: String, reference: String
        var clipTime: Double, referenceTime: Double
        var layer: String
        /// Colour distance to the reference (RMS of per-channel percentile differences, 0–255 levels) before and after.
        var distanceBefore: Double, distanceAfter: Double
        var saturation: Double
        var wheels: ColorWheels
        /// Per-channel medians (0–255) of the clip before, after, and of the reference.
        var mediansBefore: [Double], mediansAfter: [Double], mediansReference: [Double]
        var note: String
    }

    static func matchStats(_ frame: CGImage) throws -> (ShotMatch.Stats, [(Double, Double, Double)]) {
        guard let s = samplePixels(frame) else { throw EditError.invalid("could not sample a frame") }
        let px = ShotMatch.samples(s.px)
        return (ShotMatch.measure(px), px)
    }

    /// Grades `clip` so its frame matches the reference clip's frame, on a "Shot match" grade layer (one undo step).
    func matchColor(_ clip: String, reference: String, clipSeconds: Double?, referenceSeconds: Double?, mix: Double?) async throws -> MatchResult {
        let tgt = try colorClip(clip), ref = try colorClip(reference)
        guard tgt.id != ref.id else { throw EditError.invalid("the reference must be another clip") }
        try checkRange("mix", mix, 0, 1)
        let tl = try localTime(clipSeconds, in: tgt, "clip_seconds"), rl = try localTime(referenceSeconds, in: ref, "reference_seconds")
        let existing = tgt.grades.firstIndex { $0.name == ShotMatch.layerName }
        // What the layer receives: the grade and the layers before it, without finishing.
        let upTo = existing ?? tgt.grades.count
        let (input, inputPx) = try Self.matchStats(try await soloFrame(tgt, local: tl, pictureOnly: true) { c in c.grades = Array(c.grades.prefix(upTo)); c.finish = nil })
        let (before, _) = try Self.matchStats(try await soloFrame(tgt, local: tl, pictureOnly: true))
        let (refStats, _) = try Self.matchStats(try await soloFrame(ref, local: rl, pictureOnly: true))
        guard refStats.percentiles.joined().contains(where: { $0 > 0.02 }) else { throw EditError.invalid("the reference frame is black; pick another reference_seconds") }
        guard input.percentiles.joined().contains(where: { $0 > 0.02 }) else { throw EditError.invalid("the clip's frame is black; pick another clip_seconds") }
        let sol = ShotMatch.solve(target: inputPx, reference: refStats)
        var color = ClipColor()
        color.saturation = sol.saturation
        color.wheels = sol.wheels.isIdentity ? nil : sol.wheels
        let layerID = existing.map { tgt.grades[$0].id } ?? UUID()
        let hadMask = existing.flatMap { tgt.grades[$0].mask } != nil
        guard existing != nil || tgt.grades.count < Self.maxGradeLayers else { throw EditError.invalid("clip \(tgt.id.short) already has \(Self.maxGradeLayers) grade layers; remove one first") }
        try document.apply("Shot match", origin: origin, coalesce: false) { p in
            try p.updateClip(tgt.id) { c in
                if let i = c.grades.firstIndex(where: { $0.id == layerID }) {
                    c.grades[i].color = color; c.grades[i].enabled = true
                    if let mix { c.grades[i].mix = mix }
                } else {
                    var l = GradeLayer(id: layerID, name: ShotMatch.layerName)
                    l.color = color
                    if let mix { l.mix = mix }
                    c.grades.append(l)
                }
            }
        }
        guard let updated = document.project.clip(tgt.id)?.clip else { throw EditError.notFound("clip \(tgt.id.short)") }
        // The edit is made; if the check render fails, report the solver's prediction instead of failing the tool.
        var after = sol.predicted, measured = true
        do { after = try Self.matchStats(try await soloFrame(updated, local: tl, pictureOnly: true)).0 } catch { measured = false }
        let dB = ShotMatch.distance(before, refStats), dA = ShotMatch.distance(after, refStats)
        var note = "Matched black level, median and white level per channel and the overall saturation. The layer '\(ShotMatch.layerName)' (\(layerID.short)) holds the correction: lower its mix with update_grade_layer, edit it like any layer, or remove it; running match_color again replaces it. Undo removes it in one step."
        if !measured { note += " The check render failed, so distanceAfter and mediansAfter are the solver's prediction, not a measurement; call frame_stats to check." }
        if existing != nil { note += " Replaced the previous match." }
        if hadMask { note += " The layer keeps its mask, so the match only applies inside it (it was solved for the whole frame)." }
        if sol.clamped { note += " Some values hit their limits: the shots differ more than a primary correction can fix." }
        if dA >= dB { note += " The distance did not drop: the frames may show different content; try other times or a manual grade." }
        let m = { (s: ShotMatch.Stats) in s.medians.map { ($0 * 255).rounded() } }
        return MatchResult(clip: tgt.id.short, reference: ref.id.short, clipTime: r3(tgt.start + tl), referenceTime: r3(ref.start + rl), layer: layerID.short,
                           distanceBefore: dB, distanceAfter: dA, saturation: sol.saturation, wheels: sol.wheels,
                           mediansBefore: m(before), mediansAfter: m(after), mediansReference: m(refStats), note: note)
    }
}

// MARK: - Finishing

extension ToolExecutor {
    struct FinishResult: Codable {
        var clip: String
        var finish: ClipFinish?
        var note: String
    }

    /// The value ranges of `set_clip_finish`, by argument name.
    static let finishRanges: [(arg: String, key: WritableKeyPath<ClipFinish, Double>, lo: Double, hi: Double)] = [
        ("noise_reduction", \.noiseReduction, 0, 1), ("sharpen", \.sharpen, 0, 1), ("sharpen_radius", \.sharpenRadius, 0.5, 10),
        ("glow", \.glow, 0, 1), ("glow_radius", \.glowRadius, 2, 200), ("glow_threshold", \.glowThreshold, 0, 1),
        ("vignette", \.vignette, -1, 1), ("vignette_size", \.vignetteSize, 0.1, 1.5), ("vignette_softness", \.vignetteSoftness, 0.05, 1),
        ("grain", \.grain, 0, 1), ("grain_size", \.grainSize, 0.5, 4),
    ]

    /// Stores a clip's finishing (nil when everything is at its default, so the clip is saved and renders as before).
    func setFinish(_ clipID: UUID, _ f: ClipFinish) throws {
        try document.apply("Finishing", origin: origin, coalesce: coalesce) { p in try p.updateClip(clipID) { $0.finish = f == ClipFinish() ? nil : f } }
    }

    func setClipFinish(_ clip: String, values: [String: Double], reset: Bool) throws -> FinishResult {
        let c = try colorClip(clip)
        for k in values.keys where !Self.finishRanges.contains(where: { $0.arg == k }) { throw EditError.invalid("unknown finishing value '\(k)'") }
        for r in Self.finishRanges { try checkRange(r.arg, values[r.arg], r.lo, r.hi) }
        guard !values.isEmpty || reset else { throw EditError.invalid("nothing to change: pass a value (noise_reduction, sharpen, glow, vignette, grain, or their sizes) or reset true") }
        var f = reset ? ClipFinish() : (c.finish ?? ClipFinish())
        for r in Self.finishRanges { if let v = values[r.arg] { f[keyPath: r.key] = v } }
        try setFinish(c.id, f)
        let saved = document.project.clip(c.id)?.clip.finish
        var on: [String] = []
        if let s = saved {
            if s.noiseReduction > 0 { on.append("noise reduction \(ProjectDiff.fmt(s.noiseReduction))") }
            if s.sharpen > 0 { on.append("sharpen \(ProjectDiff.fmt(s.sharpen)) at \(ProjectDiff.fmt(s.sharpenRadius)) px") }
            if s.glow > 0 { on.append("glow \(ProjectDiff.fmt(s.glow)) above \(ProjectDiff.fmt(s.glowThreshold)), \(ProjectDiff.fmt(s.glowRadius)) px") }
            if s.vignette != 0 { on.append("vignette \(ProjectDiff.fmt(s.vignette)) (\(s.vignette > 0 ? "darker" : "lighter") edges)") }
            if s.grain > 0 { on.append("grain \(ProjectDiff.fmt(s.grain)), \(ProjectDiff.fmt(s.grainSize)) px") }
        }
        let note = (on.isEmpty ? "Finishing is off for this clip." : "On: " + on.joined(separator: "; ") + ".")
            + " Order: noise reduction, sharpen, glow, vignette, grain, after the grade and grade layers; sizes are pixels of a 1080-line frame. A size alone does nothing while its amount is 0."
        return FinishResult(clip: c.id.short, finish: saved, note: note)
    }
}

// MARK: - Masks

extension ToolExecutor {
    struct MaskChange {
        var clear = false
        var shape: String? = nil
        var shapeValues: [String: Double] = [:]      // center_x, center_y, width, height, rotation, feather
        var shapeInvert: Bool? = nil
        var qualifierOff = false
        var qualifierValues: [String: Double] = [:]  // hue_center, hue_width, hue_softness, sat_low, sat_high, sat_softness, luma_low, luma_high, luma_softness, blur
        var subject: String? = nil
        var subjectFeather: Double? = nil
        var invert: Bool? = nil
    }

    static let shapeRanges: [(arg: String, key: WritableKeyPath<MaskShape, Double>, lo: Double, hi: Double)] = [
        ("center_x", \.centerX, -0.5, 1.5), ("center_y", \.centerY, -0.5, 1.5), ("width", \.width, 0.01, 3), ("height", \.height, 0.01, 3),
        ("rotation", \.rotation, -360, 360), ("feather", \.feather, 0, 0.5),
    ]
    static let qualifierRanges: [(arg: String, key: WritableKeyPath<ColorQualifier, Double>, lo: Double, hi: Double)] = [
        ("hue_center", \.hueCenter, 0, 360), ("hue_width", \.hueWidth, 0, 360), ("hue_softness", \.hueSoftness, 0, 180),
        ("sat_low", \.satLow, 0, 1), ("sat_high", \.satHigh, 0, 1), ("sat_softness", \.satSoftness, 0, 1),
        ("luma_low", \.lumaLow, 0, 1), ("luma_high", \.lumaHigh, 0, 1), ("luma_softness", \.lumaSoftness, 0, 1), ("blur", \.blur, 0, 50),
    ]

    func setLayerMask(_ clip: String, layer: String, _ ch: MaskChange) throws -> LayersResult {
        let c = try colorClip(clip)
        let id = try resolveLayer(layer, in: c)
        guard let current = c.grades.first(where: { $0.id == id }) else { throw EditError.notFound("layer \(layer)") }
        for r in Self.shapeRanges { try checkRange(r.arg, ch.shapeValues[r.arg], r.lo, r.hi) }
        for r in Self.qualifierRanges { try checkRange(r.arg, ch.qualifierValues[r.arg], r.lo, r.hi) }
        try checkRange("subject_feather", ch.subjectFeather, 0, 50)
        var m = ch.clear ? GradeMask() : (current.mask ?? GradeMask())
        if let s = ch.shape?.lowercased() {
            if s == "none" { m.shape = nil }
            else if let kind = MaskShape.Kind(rawValue: s) { var sh = m.shape ?? MaskShape(kind: kind); sh.kind = kind; m.shape = sh }
            else { throw EditError.invalid("shape must be ellipse, rectangle or none (got '\(s)')") }
        }
        if !ch.shapeValues.isEmpty || ch.shapeInvert != nil {
            guard var sh = m.shape else { throw EditError.invalid("there is no shape to change: pass shape ellipse or rectangle") }
            for r in Self.shapeRanges { if let v = ch.shapeValues[r.arg] { sh[keyPath: r.key] = v } }
            if let inv = ch.shapeInvert { sh.invert = inv }
            m.shape = sh
        }
        if ch.qualifierOff { m.qualifier = nil }
        if !ch.qualifierValues.isEmpty {
            guard !ch.qualifierOff else { throw EditError.invalid("qualifier none removes the colour selection; do not pass its values too") }
            var q = m.qualifier ?? ColorQualifier()
            for r in Self.qualifierRanges { if let v = ch.qualifierValues[r.arg] { q[keyPath: r.key] = v } }
            guard q.satLow <= q.satHigh, q.lumaLow <= q.lumaHigh else { throw EditError.invalid("sat_low must not exceed sat_high, nor luma_low luma_high") }
            m.qualifier = q
        }
        if let s = ch.subject?.lowercased() {
            if s == "none" { m.subject = nil }
            else if let kind = SubjectMask.Kind(rawValue: s) { var sm = m.subject ?? SubjectMask(kind: kind); sm.kind = kind; m.subject = sm }
            else { throw EditError.invalid("subject must be person, foreground or none (got '\(s)')") }
        }
        if let f = ch.subjectFeather {
            guard m.subject != nil else { throw EditError.invalid("there is no subject mask: pass subject person or foreground") }
            m.subject?.feather = f
        }
        if let inv = ch.invert { m.invert = inv }
        let stored: GradeMask? = (m.isEmpty && !m.invert) ? nil : m
        guard stored != current.mask || ch.clear else { throw EditError.invalid("nothing to change: pass a shape, qualifier values, a subject, invert or clear") }
        try document.apply("Layer mask", origin: origin, coalesce: coalesce) { p in
            try p.updateClip(c.id) { cl in if let i = cl.grades.firstIndex(where: { $0.id == id }) { cl.grades[i].mask = stored } }
        }
        var note = "Mask parts multiply: shape × colour selection × subject; invert flips the result. Check it with capture_matte."
        if stored?.subject != nil { note += " The subject matte runs Vision once per source frame (about \(Int(SubjectMatte.lastMilliseconds.rounded())) ms the last time it ran on this Mac) and is cached; preview and export use the same matte." }
        return layersResult(c.id, "mask of layer \(id.short): \(Self.maskSummary(stored))", note: note)
    }

    struct MatteResult: Codable {
        var clip: String, layer: String, time: Double
        /// Share of the frame the layer applies to (mean matte value, 0–1).
        var coverage: Double
        var mask: String
        var note: String
    }

    /// The matte of a layer at a timeline time, as a PNG (white = the layer applies), rendered from the clip on its own.
    func captureMatte(_ clip: String, layer: String, at seconds: Double?, maxWidth: Int) async throws -> (png: Data, result: MatteResult) {
        guard maxWidth >= 160, maxWidth <= 1920 else { throw EditError.invalid("max_width must be between 160 and 1920 (got \(maxWidth))") }
        let c = try colorClip(clip)
        let id = try resolveLayer(layer, in: c)
        let local = try localTime(seconds, in: c, "seconds")
        let (p, solo) = Self.soloProject(document.project, clip: c)
        MatteProbe.shared.register(clip: solo.id, layer: id)
        defer { MatteProbe.shared.remove(clip: solo.id) }
        let frame = try await Self.frame(of: p, at: local)
        let w = min(maxWidth, frame.width), h = max(1, Int(Double(frame.height) * Double(w) / Double(frame.width)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw EditError.invalid("could not make a bitmap") }
        ctx.interpolationQuality = .medium
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let gray = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: gray).representation(using: .png, properties: [:]) else { throw EditError.invalid("could not encode the matte") }
        let coverage = Self.coverage(gray)
        let mask = c.grades.first { $0.id == id }?.mask
        var note = "White = the layer applies, black = it does not, gray = partly."
        if coverage < 0.002 { note += " The matte is empty: nothing matches" + (mask?.subject != nil ? " (Vision found no \(mask!.subject!.kind == .person ? "person" : "subject") in this frame)" : "") + "." }
        if mask == nil || (mask!.isEmpty && !mask!.invert) { note += " The layer has no mask, so it applies to the whole frame." }
        return (png, MatteResult(clip: c.id.short, layer: id.short, time: r3(c.start + local), coverage: r3(coverage), mask: Self.maskSummary(mask), note: note))
    }

    static func coverage(_ gray: CGImage) -> Double {
        guard let data = gray.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
        var sum = 0.0
        for y in 0..<gray.height { for x in 0..<gray.width { sum += Double(p[y * gray.bytesPerRow + x * (gray.bitsPerPixel / 8)]) } }
        return sum / Double(max(1, gray.width * gray.height)) / 255
    }
}
