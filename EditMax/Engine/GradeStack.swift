import Foundation
import CoreImage

/// Everything color does to a clip's picture after its transform, in this order:
///   1. the primary grade (`FrameRenderer.graded`: input LUT → exposure → contrast/saturation → temperature/tint →
///      tone curve → vibrance → wheels → curves → look)
///   2. the grade layers, first to last, each graded on the result so far and blended back inside its mask by its mix
///   3. finishing: noise reduction → sharpen → glow → vignette → grain
/// Opacity, fades and transitions follow in `FrameRenderer.render`. The before/after view bypasses all of it.
enum ColorPipeline {
    static func apply(_ img: CIImage, clip: Clip, color: ClipColor, at t: Double, size: CGSize) -> CIImage {
        let probe = clip.grades.isEmpty ? nil : MatteProbe.shared.layer(for: clip.id)
        var out = color.isIdentity ? img : FrameRenderer.graded(img, color)
        if !clip.grades.isEmpty {
            let stacked = GradeStack.apply(out, pre: img, clip: clip, color: color, at: t, size: size, probe: probe)
            if stacked.isMatte { return stacked.image }
            out = stacked.image
        }
        if let f = clip.finish, !f.isIdentity { out = Finishing.apply(out, f, at: t, size: size) }
        return out
    }

    /// `Interchange.report` lines for the color features an EDL or FCPXML cannot carry.
    static func notTransferred(_ clips: [Clip]) -> [String] {
        func n(_ k: Int) -> String { k == 1 ? "1 clip" : "\(k) clips" }
        var no: [String] = []
        let wheels = clips.filter { c in [c.color.wheels].compactMap { $0 }.contains { !$0.isIdentity } || c.grades.contains { !($0.color.wheels?.isIdentity ?? true) } }
        if !wheels.isEmpty { no.append("Color wheels (lift, gamma, gain, offset) on \(n(wheels.count))") }
        let curves = clips.filter { c in !(c.color.curves?.isIdentity ?? true) || c.grades.contains { !($0.color.curves?.isIdentity ?? true) } }
        if !curves.isEmpty { no.append("Custom curves on \(n(curves.count))") }
        let layered = clips.filter { !$0.grades.isEmpty }
        if !layered.isEmpty { no.append("Grade layers on \(n(layered.count)), with their masks (shapes, colour selections, AI subject mattes) and shot matches") }
        let finished = clips.filter { !($0.finish?.isIdentity ?? true) }
        if !finished.isEmpty { no.append("Finishing (grain, glow, vignette, sharpen, noise reduction) on \(n(finished.count))") }
        return no
    }
}

/// `capture_matte` renders a solo copy of a clip whose id is registered here: the compositor then draws that layer's
/// matte (white = graded by the layer) instead of the picture. The copy gets a fresh id, so the live preview and the
/// export, which never see that id, are not affected.
final class MatteProbe: @unchecked Sendable {
    static let shared = MatteProbe()
    private let lock = NSLock()
    private var layers: [UUID: UUID] = [:]
    func register(clip: UUID, layer: UUID) { lock.withLock { layers[clip] = layer } }
    func remove(clip: UUID) { _ = lock.withLock { layers.removeValue(forKey: clip) } }
    func layer(for clip: UUID) -> UUID? { lock.withLock { layers[clip] } }
}

enum GradeStack {
    /// The picture after the clip's grade layers, or (for a matte probe) that layer's matte as an opaque gray picture.
    static func apply(_ img: CIImage, pre: CIImage, clip: Clip, color: ClipColor, at t: Double, size: CGSize, probe: UUID?) -> (image: CIImage, isMatte: Bool) {
        var out = img
        let frame = CGRect(origin: .zero, size: size)
        for layer in clip.grades {
            let probing = probe == layer.id
            guard layer.enabled || probing else { continue }
            // The qualifier keys the picture entering the layer; the subject matte comes from the clip's own picture.
            let matte = Masks.matte(layer.mask, input: out, pre: pre, clip: clip, inputLut: color.inputLut, at: t, size: size)
            if probing {
                let m = matte ?? CIImage(color: .white).cropped(to: frame)
                return (m.composited(over: CIImage(color: .black).cropped(to: frame)).cropped(to: frame), true)
            }
            guard layer.isActive else { continue }
            var c = layer.color; c.inputLut = nil
            out = blend(FrameRenderer.graded(out, c), over: out, matte: matte, mix: layer.mix)
        }
        return (out, false)
    }

    /// `top` inside the matte (gray, white = top) scaled by `mix`, `base` elsewhere. Both share alpha, so it is kept.
    static func blend(_ top: CIImage, over base: CIImage, matte: CIImage?, mix: Double) -> CIImage {
        if matte == nil && mix >= 0.9995 { return top }
        var m = matte ?? CIImage(color: .white).cropped(to: base.extent)
        if mix < 0.9995 { m = ColorCorrection.scale(m, max(0, mix)) }
        return top.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": base, "inputMaskImage": m])
    }
}
