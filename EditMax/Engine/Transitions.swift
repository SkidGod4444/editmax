import Foundation
import CoreImage

/// The transitions after the original four (cross dissolve, dip to black, wipe left/right, drawn in
/// `FrameRenderer.blend`). Same contract: `a` is the outgoing picture (black when there is none), `b` the incoming one,
/// `p` the linear progress 0…1 over the transition; each eases its own motion. Results are cropped to the frame.
/// These use a true premultiplied alpha for their mixes (`Effects.opacity`), so a mid-point is an even mix.
enum Transitions {
    static func title(_ k: Transition.Kind) -> String {
        switch k {
        case .crossDissolve: return "Cross dissolve"; case .dipToBlack: return "Dip to black"; case .wipeLeft: return "Wipe left"; case .wipeRight: return "Wipe right"
        case .dipToWhite: return "Dip to white"; case .blurDissolve: return "Blur dissolve"
        case .pushLeft: return "Push left"; case .pushRight: return "Push right"; case .pushUp: return "Push up"; case .pushDown: return "Push down"
        case .slideLeft: return "Slide left"; case .slideRight: return "Slide right"; case .slideUp: return "Slide up"; case .slideDown: return "Slide down"
        case .zoom: return "Zoom"; case .iris: return "Iris"; case .wipeUp: return "Wipe up"; case .wipeDown: return "Wipe down"
        }
    }

    /// Smooth start and stop.
    static func ease(_ p: Double) -> Double { let u = max(0, min(1, p)); return u * u * (3 - 2 * u) }

    static func blend(_ kind: Transition.Kind, from a: CIImage, to b: CIImage, progress p: Double, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let W = size.width, H = size.height
        let e = ease(p)
        func moved(_ img: CIImage, _ dx: Double, _ dy: Double) -> CIImage { img.transformed(by: CGAffineTransform(translationX: dx.rounded(), y: dy.rounded())) }
        func mix(_ top: CIImage, over base: CIImage, _ amount: Double) -> CIImage { Effects.opacity(top, amount).composited(over: base) }
        func scaled(_ img: CIImage, _ s: Double) -> CIImage {
            img.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2).concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: W / 2, y: H / 2)))
        }
        let black = CIImage(color: .black).cropped(to: rect)
        let out: CIImage
        switch kind {
        // Push: both pictures move together, the incoming one taking the outgoing one's place. Directions say where they move.
        case .pushLeft: out = moved(b, W * (1 - e), 0).composited(over: moved(a, -W * e, 0))
        case .pushRight: out = moved(b, -W * (1 - e), 0).composited(over: moved(a, W * e, 0))
        case .pushUp: out = moved(b, 0, -H * (1 - e)).composited(over: moved(a, 0, H * e))       // Core Image is y-up
        case .pushDown: out = moved(b, 0, H * (1 - e)).composited(over: moved(a, 0, -H * e))
        // Slide: the incoming picture slides in over the outgoing one, which stays put.
        case .slideLeft: out = moved(b, W * (1 - e), 0).composited(over: a)
        case .slideRight: out = moved(b, -W * (1 - e), 0).composited(over: a)
        case .slideUp: out = moved(b, 0, -H * (1 - e)).composited(over: a)
        case .slideDown: out = moved(b, 0, H * (1 - e)).composited(over: a)
        case .zoom:
            // The outgoing picture pushes in and fades; the incoming one settles from a slight zoom-in.
            out = mix(scaled(b, 1.25 - 0.25 * e).cropped(to: rect), over: scaled(a, 1 + 0.6 * e).cropped(to: rect), e)
        case .blurDissolve:
            let r = 0.025 * H * sin(.pi * max(0, min(1, p)))
            let blur = { (img: CIImage) in r < 0.3 ? img : img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: rect) }
            out = mix(blur(b), over: blur(a), e)
        case .iris:
            // A circle from the centre that opens until it covers the corners, with a soft rim.
            let reach = hypot(W, H) / 2, radius = reach * e, soft = max(1, 0.015 * H)
            let mask = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: W / 2, y: H / 2), "inputRadius0": max(0, radius - soft), "inputRadius1": radius + 0.001,
                                                                       "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: rect)
            out = p >= 1 ? b : b.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: a, kCIInputMaskImageKey: mask])
        case .dipToWhite:
            let white = CIImage(color: .white).cropped(to: rect)
            out = p < 0.5 ? mix(a, over: white, 1 - 2 * p) : mix(b, over: white, 2 * p - 1)
        case .wipeUp: out = b.cropped(to: CGRect(x: 0, y: 0, width: W, height: H * p)).composited(over: a)          // reveals from the bottom up
        case .wipeDown: out = b.cropped(to: CGRect(x: 0, y: H * (1 - p), width: W, height: H * p)).composited(over: a)
        case .crossDissolve, .dipToBlack, .wipeLeft, .wipeRight:
            out = mix(b, over: a, p)   // drawn by FrameRenderer.blend; never reached
        }
        return out.composited(over: black).cropped(to: rect)
    }
}
