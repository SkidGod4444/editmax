import Foundation
import CoreImage

/// The compositor's hooks for per-clip effects, one line each in `FrameRenderer`. Each returns its input untouched
/// (the very same expression as before) when the clip does not use the effect, so a plain project renders as it did.
///
/// Order of operations for a clip: decoded source → face / region blur → green-screen key → crop → stabilization →
/// transform → colour → opacity and fades → transition → blend with the rows below.
enum Effects {
    /// Face / region blur, then the key, on the oriented source picture (its own pixels, origin at 0) before crop,
    /// stabilization and transform, so both follow the picture through every later step. The key is computed from the
    /// ungraded pixels, so a grade never moves it; Core Image's colour filters unpremultiply, so grading a keyed picture
    /// keeps its edges.
    static func source(_ img: CIImage, clip: Clip, sourceTime: Double) -> CIImage {
        let fx = clip.effects
        guard fx.chromaKey != nil || fx.blur != nil else { return img }
        var out = img
        if let fb = fx.blur { out = FaceBlurRenderer.apply(out, fb, at: sourceTime) }
        if let key = fx.chromaKey { out = Keyer.apply(out, key) }
        return out
    }

    /// A true premultiplied opacity (the alpha channel scaled, colour kept), so a blend filter mixes its result with the
    /// rows below by exactly `a`. (`FrameRenderer.withAlpha`, used for normal clips, scales colour and alpha both, which
    /// Core Image's unpremultiply turns into colour × a²; kept as it was for normal clips.)
    static func opacity(_ img: CIImage, _ a: Double) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, min(1, a))))])
    }

    /// A clip's picture over the rows below it. Normal is the plain source-over it always was; the others are Core
    /// Image's blend filters, which honour the picture's alpha (outside it, or where keyed out, the rows below show as they are).
    static func composite(_ img: CIImage, over canvas: CIImage, mode: ClipBlendMode) -> CIImage {
        guard let f = mode.filterName else { return img.composited(over: canvas) }
        let out = img.applyingFilter(f, parameters: [kCIInputBackgroundImageKey: canvas])
        // Addition adds the alphas too (2 over an opaque canvas); the canvas is opaque, so the sum is.
        return mode == .add ? out.settingAlphaOne(in: canvas.extent) : out
    }

    // MARK: History and hand-offs

    /// The history line for a clip whose effects changed.
    static func diff(_ a: ClipEffects, _ b: ClipEffects) -> String {
        var c: [String] = []
        if a.chromaKey != b.chromaKey { c.append(b.chromaKey.map { "key \($0.colorHex)" } ?? "key removed") }
        if a.blend != b.blend { c.append("blend \(b.blend.rawValue)") }
        if a.blur != b.blur {
            if let fb = b.blur { c.append("blur: \(fb.faceCount) face\(fb.faceCount == 1 ? "" : "s"), \(fb.regions.count) region\(fb.regions.count == 1 ? "" : "s")") } else { c.append("blur removed") }
        }
        return c.isEmpty ? "effects" : c.joined(separator: ", ")
    }

    /// What `export_timeline` cannot carry of these effects, for `Interchange.report`'s notTransferred list.
    static func notTransferred(_ p: Project, clips: [Clip], edl: Bool) -> [String] {
        func n(_ k: Int, _ one: String, _ many: String? = nil) -> String { "\(k) \(k == 1 ? one : (many ?? one + "s"))" }
        var no: [String] = []
        let original: Set<Transition.Kind> = [.crossDissolve, .dipToBlack, .wipeLeft, .wipeRight]
        let newer = clips.compactMap { $0.transitionIn?.kind }.filter { !original.contains($0) }
        if !newer.isEmpty {
            let kinds = Array(Set(newer.map(\.title))).sorted().joined(separator: ", ")
            no.append("\(n(newer.count, "transition")) (\(kinds.lowercased())): sent as cross dissolves; pick the matching transition in Resolve or Final Cut")
        }
        let keyed = clips.filter { $0.effects.chromaKey != nil }
        if !keyed.isEmpty { no.append("Green-screen keys on \(n(keyed.count, "clip")): the clips come in unkeyed; key them again (Resolve's 3D Keyer, Final Cut's Keyer)") }
        let blended = clips.filter { $0.effects.blend != .normal }
        if !blended.isEmpty { no.append("Blend modes on \(n(blended.count, "clip")) (\(Array(Set(blended.map { $0.effects.blend.title.lowercased() })).sorted().joined(separator: ", "))): the clips come in as normal") }
        let blurred = clips.filter { $0.effects.blur.map { !$0.isEmpty } ?? false }
        if !blurred.isEmpty { no.append("Face and region blur on \(n(blurred.count, "clip")): the faces come in unblurred; blur them again, or export a master with them baked in") }
        if !edl {
            let animated = p.texts.filter { !($0.animation?.isNone ?? true) }
            if !animated.isEmpty { no.append("Title animations on \(n(animated.count, "text")): they come in without their in / out moves") }
            let thirds = p.texts.filter { $0.lowerThird != nil }
            if !thirds.isEmpty { no.append("Lower thirds (\(thirds.count)): they come in as basic titles with the name only; the role, bar or box and colours stay behind") }
        }
        if p.settings.color.isHDR { no.append("The \(p.settings.color.title) colour setting: the file says Rec.709; set the timeline to Rec.2020 \(p.settings.color == .pq ? "PQ (ST 2084)" : "HLG") in Resolve or Final Cut") }
        return no
    }
}
