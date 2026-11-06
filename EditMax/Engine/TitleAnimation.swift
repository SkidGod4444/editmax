import Foundation
import AppKit
import CoreImage

// MARK: - Raster

/// An animated title or a lower third, rasterized once per composition build (like every title) into the pieces its
/// animation moves: the box, the accent (bar or rule), and each block of text with its glyph geometry (line bands, the
/// right edge after every character, word boxes), all in render pixels with the title's own origin at 0 (y-up).
/// Typewriter, word-by-word and wipe reveal the pieces by cropping them; fade, slide and pop move or fade the composed
/// title. Nothing is drawn again per frame, so preview, export and `capture_frame` show the same picture.
final class TitleRaster {
    struct Line { let band: CGRect; let start: Int; let end: Int; let edges: [CGFloat] }
    struct Word { let rect: CGRect; let first: Int; let last: Int }
    struct Text {
        let image: CIImage
        let lines: [Line]
        let words: [Word]
        var count: Int { lines.last?.end ?? 0 }
    }
    let size: CGSize
    let fontSize: CGFloat
    let template: LowerThird.Template?
    var box: CIImage?, boxRect = CGRect.zero
    var box2: CIImage?, box2Rect = CGRect.zero        // the "box" template's role box
    var accent: CIImage?, accentRect = CGRect.zero    // the bar or the rule
    var text: Text?                                   // a plain title's text
    var name: Text?, role: Text?                      // a lower third's lines
    /// Every piece at rest: what the title looks like between its in and out animations.
    var full: CIImage = .empty()

    init(size: CGSize, fontSize: CGFloat, template: LowerThird.Template?) { self.size = size; self.fontSize = fontSize; self.template = template }
}

enum TitleRasterizer {
    /// Drawn at twice the render size, then scaled down, like `OverlayLayerBuilder.renderText` on a Retina screen.
    static let oversample: CGFloat = 2

    /// The layer for a text that animates or is a lower third; nil for a plain title (the builder then rasterizes it as before).
    static func layer(_ t: TextOverlay, canvas: CGSize) -> TextLayer? {
        guard t.lowerThird != nil || !(t.animation?.isNone ?? true) else { return nil }
        guard let r = t.lowerThird != nil ? lowerThird(t, canvas: canvas) : title(t, canvas: canvas) else { return nil }
        return TextLayer(text: t, image: r.full, size: r.size, raster: r)
    }

    /// The size a lower third takes in the frame (render pixels), measured without drawing; nil for other texts.
    static func measure(_ t: TextOverlay, canvas: CGSize) -> CGSize? {
        guard t.lowerThird != nil else { return nil }
        return lowerThirdLayout(t, canvas: canvas).size
    }

    // MARK: Drawing helpers

    /// A transparent bitmap of `size` render pixels drawn at `oversample`, as a CIImage in render pixels (values untagged, as titles always are).
    static func bitmap(_ size: CGSize, _ draw: () -> Void) -> CIImage? {
        let w = max(1, Int((size.width * oversample).rounded(.up))), h = max(1, Int((size.height * oversample).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.scaleBy(x: oversample, y: oversample)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()]).transformed(by: CGAffineTransform(scaleX: 1 / oversample, y: 1 / oversample))
    }

    static func color(_ hex: String, _ alpha: CGFloat = 1) -> NSColor { (NSColor(cgColor: OverlayLayerBuilder.cgColor(hex: hex)) ?? .white).withAlphaComponent(alpha) }

    /// Lays `str` out in `rect` (render pixels, y-up, the text's top at `rect.maxY`) with TextKit, draws it with that
    /// same layout and reads back where every line and character landed, so the reveal cuts match the pixels exactly.
    static func text(_ str: NSAttributedString, in rect: CGRect, raster size: CGSize, pad: CGFloat) -> TitleRaster.Text? {
        let storage = NSTextStorage(attributedString: str)
        let lm = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: rect.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0   // as NSString drawing lays out
        lm.addTextContainer(container); storage.addLayoutManager(lm)
        lm.ensureLayout(for: container)
        let image = bitmap(size) {
            // TextKit draws top-down: flip the bitmap's y-up space for it.
            guard let cg = NSGraphicsContext.current?.cgContext else { return }
            cg.saveGState()
            cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            let glyphs = lm.glyphRange(for: container), origin = CGPoint(x: rect.minX, y: size.height - rect.maxY)
            lm.drawBackground(forGlyphRange: glyphs, at: origin)
            lm.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            cg.restoreGState()
        }
        guard let image else { return nil }
        let ns = str.string as NSString
        var frags: [(rect: CGRect, chars: NSRange)] = []
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { r, _, _, glyphs, _ in
            frags.append((r, lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
        }
        var lines: [TitleRaster.Line] = []
        for (i, f) in frags.enumerated() {
            let top = rect.maxY - f.rect.minY, bottom = rect.maxY - f.rect.maxY
            // Bands meet halfway between lines; the outer ones reach the raster's edge (shadows and strokes stay in).
            let upper = i == 0 ? size.height : (rect.maxY - frags[i - 1].rect.maxY + top) / 2
            let lower = i == frags.count - 1 ? 0 : (bottom + rect.maxY - frags[i + 1].rect.minY) / 2
            var edges: [CGFloat] = []
            var right = rect.minX
            for c in f.chars.location..<(f.chars.location + f.chars.length) {
                let g = lm.glyphRange(forCharacterRange: NSRange(location: c, length: 1), actualCharacterRange: nil)
                if g.length > 0 {
                    let b = lm.boundingRect(forGlyphRange: g, in: container)
                    let isSpace = ns.substring(with: NSRange(location: c, length: 1)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if !isSpace { right = max(right, rect.minX + b.maxX) }
                }
                edges.append(right + pad)
            }
            lines.append(TitleRaster.Line(band: CGRect(x: 0, y: lower, width: size.width, height: max(1, upper - lower)), start: f.chars.location, end: f.chars.location + f.chars.length, edges: edges))
        }
        // Words: runs of non-space characters within a line.
        var words: [TitleRaster.Word] = []
        for line in lines {
            var c = line.start
            while c < line.end {
                while c < line.end, ns.substring(with: NSRange(location: c, length: 1)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c += 1 }
                guard c < line.end else { break }
                let first = c
                while c < line.end, !ns.substring(with: NSRange(location: c, length: 1)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c += 1 }
                let g = lm.glyphRange(forCharacterRange: NSRange(location: first, length: c - first), actualCharacterRange: nil)
                let b = lm.boundingRect(forGlyphRange: g, in: container)
                words.append(TitleRaster.Word(rect: CGRect(x: rect.minX + b.minX - pad, y: line.band.minY, width: b.width + 2 * pad, height: line.band.height), first: first, last: c - 1))
            }
        }
        return TitleRaster.Text(image: image, lines: lines, words: words)
    }

    // MARK: Plain titles

    /// The same box, font, wrapping and padding as `OverlayLayerBuilder.renderText`, split into box and text.
    static func title(_ t: TextOverlay, canvas: CGSize) -> TitleRaster? {
        let style = CaptionPresets.style(t.preset)
        let font = NSFont(name: style.fontName, size: t.fontSize) ?? NSFont.boldSystemFont(ofSize: t.fontSize)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(t.colorHex), .paragraphStyle: para]
        if style.shadow {
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.8); shadow.shadowBlurRadius = 4; shadow.shadowOffset = NSSize(width: 0, height: -2)
            attrs[.shadow] = shadow
        }
        if style.strokeWidth > 0 { attrs[.strokeWidth] = -style.strokeWidth; attrs[.strokeColor] = color(style.strokeColor) }
        let maxWidth = (canvas.width * 0.9).rounded()
        let str = NSAttributedString(string: style.uppercase ? t.text.uppercased() : t.text, attributes: attrs)
        let used = str.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        let padX = style.box?.padding ?? 0, padY = padX * 0.5
        let width = style.box == nil ? maxWidth : min(maxWidth, ceil(used.width) + 2 * padX + 8)
        let h = ceil(used.height) + (style.box == nil ? 12 : 2 * padY + 4)
        let size = CGSize(width: width, height: h)
        let r = TitleRaster(size: size, fontSize: t.fontSize, template: nil)
        if let box = style.box {
            r.box = bitmap(size) {
                color(box.color, box.alpha).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: h), xRadius: box.radius, yRadius: box.radius).fill()
            }
            r.boxRect = CGRect(origin: .zero, size: size)
        }
        let textRect = CGRect(x: (width - min(width, maxWidth)) / 2, y: (h - ceil(used.height)) / 2, width: min(width, maxWidth), height: ceil(used.height))
        r.text = text(str, in: textRect, raster: size, pad: 2 + style.strokeWidth * 0.5)
        r.full = [r.text?.image, r.box].compactMap { $0 }.reduce(CIImage.empty()) { $0.composited(over: $1) }   // text over box
        return r
    }

    // MARK: Lower thirds

    struct LowerThirdLayout {
        var size: CGSize
        var name: NSAttributedString, nameRect: CGRect
        var role: NSAttributedString?, roleRect: CGRect
        var box: CGRect, box2: CGRect, accent: CGRect
    }

    /// Lower-third geometry in render pixels (y-up, origin at the raster's bottom-left), left-aligned:
    /// - bar: an accent bar, then a dark box holding the name over the role;
    /// - box: the name on an accent box, the role on a dark box under it;
    /// - line: the name, an accent rule, the role, no box (with a shadow for legibility).
    static func lowerThirdLayout(_ t: TextOverlay, canvas: CGSize) -> LowerThirdLayout {
        let lt = t.lowerThird ?? LowerThird()
        let fs = CGFloat(t.fontSize)
        let nameFont = NSFont(name: "HelveticaNeue-Bold", size: fs) ?? .boldSystemFont(ofSize: fs)
        let roleFont = NSFont(name: "HelveticaNeue-Medium", size: fs * 0.55) ?? .systemFont(ofSize: fs * 0.55)
        let para = NSMutableParagraphStyle(); para.alignment = .left
        var nameAttrs: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: color(t.colorHex), .paragraphStyle: para]
        var roleAttrs: [NSAttributedString.Key: Any] = [.font: roleFont, .foregroundColor: color("#FFFFFF", lt.template == .box ? 1 : 0.85), .paragraphStyle: para]
        if lt.template == .line {
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.75); shadow.shadowBlurRadius = 5; shadow.shadowOffset = NSSize(width: 0, height: -2)
            nameAttrs[.shadow] = shadow; roleAttrs[.shadow] = shadow
        }
        let maxW = (canvas.width * 0.7).rounded()
        let name = NSAttributedString(string: t.text, attributes: nameAttrs)
        let role = lt.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : NSAttributedString(string: lt.role, attributes: roleAttrs)
        let measure = { (s: NSAttributedString) -> CGSize in
            let b = s.boundingRect(with: NSSize(width: maxW, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]); return CGSize(width: ceil(b.width), height: ceil(b.height))
        }
        let ns = measure(name), rs = role.map(measure) ?? .zero
        let padX = (fs * 0.45).rounded(), padY = (fs * 0.22).rounded(), gap = role == nil ? 0 : (fs * 0.1).rounded()
        let edge: CGFloat = 8   // room for shadows
        var L = LowerThirdLayout(size: .zero, name: name, nameRect: .zero, role: role, roleRect: .zero, box: .zero, box2: .zero, accent: .zero)
        switch lt.template {
        case .bar:
            let barW = max(4, (fs * 0.12).rounded())
            let boxW = max(ns.width, rs.width) + 2 * padX, boxH = padY + ns.height + gap + rs.height + padY
            L.size = CGSize(width: edge + barW + boxW + edge, height: edge + boxH + edge)
            L.accent = CGRect(x: edge, y: edge, width: barW, height: boxH)
            L.box = CGRect(x: edge + barW, y: edge, width: boxW, height: boxH)
            L.roleRect = CGRect(x: L.box.minX + padX, y: edge + padY, width: rs.width + 2, height: rs.height)
            L.nameRect = CGRect(x: L.box.minX + padX, y: edge + padY + rs.height + gap, width: ns.width + 2, height: ns.height)
        case .box:
            let nameBox = CGSize(width: ns.width + 2 * padX, height: ns.height + 1.6 * padY)
            let roleBox = role == nil ? CGSize.zero : CGSize(width: rs.width + 1.6 * padX, height: rs.height + 1.2 * padY)
            L.size = CGSize(width: edge + max(nameBox.width, roleBox.width) + edge, height: edge + nameBox.height + roleBox.height + edge)
            L.box2 = CGRect(x: edge, y: edge, width: roleBox.width, height: roleBox.height)
            L.box = CGRect(x: edge, y: edge + roleBox.height, width: nameBox.width, height: nameBox.height)
            L.nameRect = CGRect(x: L.box.minX + padX, y: L.box.minY + 0.8 * padY, width: ns.width + 2, height: ns.height)
            L.roleRect = CGRect(x: L.box2.minX + 0.8 * padX, y: L.box2.minY + 0.6 * padY, width: rs.width + 2, height: rs.height)
        case .line:
            let ruleH = max(2, (fs * 0.06).rounded()), w = max(ns.width, rs.width)
            let space = (fs * 0.14).rounded()
            L.size = CGSize(width: edge + w + edge, height: edge + rs.height + (role == nil ? 0 : space) + ruleH + space + ns.height + edge)
            L.roleRect = CGRect(x: edge, y: edge, width: rs.width + 2, height: rs.height)
            L.accent = CGRect(x: edge, y: edge + rs.height + (role == nil ? 0 : space), width: w, height: ruleH)
            L.nameRect = CGRect(x: edge, y: L.accent.maxY + space, width: ns.width + 2, height: ns.height)
        }
        L.size = CGSize(width: ceil(L.size.width), height: ceil(L.size.height))
        return L
    }

    static func lowerThird(_ t: TextOverlay, canvas: CGSize) -> TitleRaster? {
        let lt = t.lowerThird ?? LowerThird()
        let L = lowerThirdLayout(t, canvas: canvas)
        let r = TitleRaster(size: L.size, fontSize: t.fontSize, template: lt.template)
        let accent = color(lt.accentHex)
        switch lt.template {
        case .bar:
            r.accent = bitmap(L.size) { accent.setFill(); NSBezierPath(rect: L.accent).fill() }; r.accentRect = L.accent
            r.box = bitmap(L.size) { NSColor.black.withAlphaComponent(0.6).setFill(); NSBezierPath(rect: L.box).fill() }; r.boxRect = L.box
        case .box:
            r.box = bitmap(L.size) { accent.setFill(); NSBezierPath(rect: L.box).fill() }; r.boxRect = L.box
            if L.role != nil { r.box2 = bitmap(L.size) { NSColor.black.withAlphaComponent(0.75).setFill(); NSBezierPath(rect: L.box2).fill() }; r.box2Rect = L.box2 }
        case .line:
            r.accent = bitmap(L.size) { accent.setFill(); NSBezierPath(rect: L.accent).fill() }; r.accentRect = L.accent
        }
        r.name = text(L.name, in: L.nameRect, raster: L.size, pad: 2)
        if let role = L.role { r.role = text(role, in: L.roleRect, raster: L.size, pad: 2) }
        r.full = [r.box, r.box2, r.accent, r.name?.image, r.role?.image].compactMap { $0 }.reduce(CIImage.empty()) { $1.composited(over: $0) }
        return r
    }
}

// MARK: - Animation

/// Draws an animated title or lower third at a time (see `TitleRaster`). In and out each have their own kind and
/// length; when both overlap (a short text) both apply. Positions follow the plain titles' formula exactly.
enum TitleAnimator {
    static func clamp(_ x: Double) -> Double { max(0, min(1, x)) }
    static func ease(_ x: Double) -> Double { let u = clamp(x); return u * u * (3 - 2 * u) }
    static func easeOut(_ x: Double) -> Double { let u = clamp(x); return 1 - pow(1 - u, 3) }
    /// Portion `a…b` of the progress, eased.
    static func seg(_ p: Double, _ a: Double, _ b: Double) -> Double { ease((p - a) / max(1e-6, b - a)) }

    /// The progress of the in and out animations at `t` (1 = at rest).
    static func phases(_ text: TextOverlay, at t: Double) -> (inP: Double, outP: Double) {
        let a = text.animation ?? TextAnimation()
        let inP = a.inKind == .none ? 1 : clamp((t - text.start) / max(0.01, a.inDuration))
        let outP = a.outKind == .none ? 1 : clamp((text.end - t) / max(0.01, a.outDuration))
        return (inP, outP)
    }

    /// The title composited over `canvas`, or nil when the layer has no raster (a plain title: drawn as before).
    static func draw(_ tl: TextLayer, at t: Double, size: CGSize, over canvas: CIImage) -> CIImage? {
        guard tl.raster != nil else { return nil }
        guard let img = picture(tl, at: t, canvasHeight: size.height) else { return canvas }
        let origin = CGPoint(x: size.width * tl.text.x - tl.size.width / 2, y: size.height * (1 - tl.text.y) - tl.size.height / 2)
        return img.image.transformed(by: img.transform.concatenating(CGAffineTransform(translationX: origin.x.rounded(), y: origin.y.rounded()))).composited(over: canvas)
    }

    /// The title at `t` in its own pixels and the move (scale about its centre, slide) to apply before placing it.
    static func picture(_ tl: TextLayer, at t: Double, canvasHeight H: CGFloat) -> (image: CIImage, transform: CGAffineTransform)? {
        guard let r = tl.raster else { return nil }
        let anim = tl.text.animation ?? TextAnimation()
        let (inP, outP) = phases(tl.text, at: t)
        if inP <= 0 || outP <= 0 { return nil }
        var alpha = 1.0, dy = 0.0, scale = 1.0
        func motion(_ kind: TextAnimation.Kind, _ p: Double, entering: Bool) {
            guard p < 1 else { return }
            switch kind {
            case .fade: alpha *= ease(p)
            case .slideUp: alpha *= ease(p); dy += (entering ? -1 : 1) * (1 - easeOut(p)) * 0.05 * Double(H)    // enters from below, leaves upwards
            case .slideDown: alpha *= ease(p); dy += (entering ? 1 : -1) * (1 - easeOut(p)) * 0.05 * Double(H)
            case .pop:
                alpha *= clamp(p * 2.5)
                scale *= entering ? 0.6 + 0.4 * backOut(p) : 0.6 + 0.4 * ease(p)
            case .none, .typewriter, .words, .wipe: break
            }
        }
        motion(anim.inKind, inP, entering: true)
        motion(anim.outKind, outP, entering: false)
        // Reveals: the in animation's, then the out animation's on top of it (both crop).
        var img = compose(r, reveal: [(anim.inKind, inP), (anim.outKind, outP)].filter { $0.1 < 1 && [.typewriter, .words, .wipe].contains($0.0) })
        if alpha < 0.999 { img = Effects.opacity(img, alpha) }
        let c = CGPoint(x: r.size.width / 2, y: r.size.height / 2)
        var T = CGAffineTransform.identity
        if abs(scale - 1) > 1e-4 { T = CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: c.x, y: c.y)) }
        if abs(dy) > 0.01 { T = T.concatenating(CGAffineTransform(translationX: 0, y: dy.rounded())) }
        return (img, T)
    }

    /// Overshoots to about 1.07 and settles (an ease-out-back).
    static func backOut(_ x: Double) -> Double { let u = clamp(x), k = 1.70158; return 1 + (k + 1) * pow(u - 1, 3) + k * pow(u - 1, 2) }

    /// The title's pieces with every active reveal applied (`p` 0 = hidden, 1 = shown).
    static func compose(_ r: TitleRaster, reveal: [(TextAnimation.Kind, Double)]) -> CIImage {
        guard !reveal.isEmpty else { return r.full }
        var box = r.box, box2 = r.box2, accent = r.accent
        var textReveals: [(TextAnimation.Kind, Double)] = []
        var wipe = 1.0
        var nameMove = CGVector.zero, roleMove = CGVector.zero, nameAlpha = 1.0, roleAlpha = 1.0, boxAlpha = 1.0
        for (kind, p) in reveal {
            switch kind {
            case .wipe where r.template != nil:
                // Lower thirds build up piece by piece.
                let fs = Double(r.fontSize)
                switch r.template! {
                case .bar:
                    let s = seg(p, 0, 0.35), a = r.accentRect
                    accent = accent?.cropped(to: CGRect(x: a.minX, y: a.midY - a.height * s / 2, width: a.width, height: a.height * s))
                    box = box?.cropped(to: CGRect(x: 0, y: 0, width: r.boxRect.minX + r.boxRect.width * seg(p, 0.15, 0.7), height: r.size.height))
                    nameAlpha *= seg(p, 0.35, 0.85); roleAlpha *= seg(p, 0.5, 1)
                    nameMove.dx -= (1 - seg(p, 0.35, 0.85)) * 0.4 * fs; roleMove.dx -= (1 - seg(p, 0.5, 1)) * 0.4 * fs
                case .box:
                    box = box?.cropped(to: CGRect(x: 0, y: 0, width: r.boxRect.minX + r.boxRect.width * seg(p, 0, 0.5), height: r.size.height))
                    box2 = box2?.cropped(to: CGRect(x: 0, y: 0, width: r.box2Rect.minX + r.box2Rect.width * seg(p, 0.25, 0.75), height: r.size.height))
                    nameAlpha *= seg(p, 0.3, 0.8); roleAlpha *= seg(p, 0.5, 1)
                    nameMove.dx -= (1 - seg(p, 0.3, 0.8)) * 0.3 * fs; roleMove.dx -= (1 - seg(p, 0.5, 1)) * 0.3 * fs
                case .line:
                    accent = accent?.cropped(to: CGRect(x: 0, y: 0, width: r.accentRect.minX + r.accentRect.width * seg(p, 0, 0.5), height: r.size.height))
                    nameAlpha *= seg(p, 0.2, 0.75); roleAlpha *= seg(p, 0.4, 1)
                    nameMove.dy -= (1 - seg(p, 0.2, 0.75)) * 0.3 * fs; roleMove.dy += (1 - seg(p, 0.4, 1)) * 0.3 * fs
                }
            case .wipe:
                wipe = min(wipe, p)
            case .typewriter, .words:
                textReveals.append((kind, p))
                boxAlpha *= seg(p, 0, 0.2)
            default: break
            }
        }
        // Typewriter and word by word: a lower third types its name, then its role.
        func revealed(_ piece: TitleRaster.Text?, _ part: (Double) -> Double) -> CIImage? {
            guard let tx = piece else { return nil }
            var img = tx.image
            for (kind, p) in textReveals { img = TitleAnimator.reveal(tx, kind, part(p), from: img) }
            return img
        }
        var parts: [CIImage?] = []
        let fadedBox = { (img: CIImage?) in boxAlpha < 0.999 ? img.map { Effects.opacity($0, boxAlpha) } : img }
        parts.append(fadedBox(box)); parts.append(fadedBox(box2)); parts.append(fadedBox(accent))
        if r.template == nil {
            parts.append(revealed(r.text, { $0 }))
        } else {
            let hasRole = r.role != nil
            var n = revealed(r.name, { hasRole ? seg($0, 0, 0.6) : $0 }), ro = revealed(r.role, { seg($0, 0.45, 1) })
            if nameAlpha < 0.999 { n = n.map { Effects.opacity($0, nameAlpha) } }
            if roleAlpha < 0.999 { ro = ro.map { Effects.opacity($0, roleAlpha) } }
            if nameMove != .zero { n = n?.transformed(by: CGAffineTransform(translationX: nameMove.dx.rounded(), y: nameMove.dy.rounded())) }
            if roleMove != .zero { ro = ro?.transformed(by: CGAffineTransform(translationX: roleMove.dx.rounded(), y: roleMove.dy.rounded())) }
            // Moving text stays inside its box (it slides in from under the box's edge, not from outside the title).
            if r.template != .line, nameMove != .zero || roleMove != .zero {
                let clip = r.template == .bar ? r.boxRect : r.boxRect.union(r.box2Rect)
                n = n?.cropped(to: clip); ro = ro?.cropped(to: clip)
            }
            parts.append(n); parts.append(ro)
        }
        var out = parts.compactMap { $0 }.reduce(CIImage.empty()) { $1.composited(over: $0) }
        if wipe < 1 { out = softReveal(out, width: r.size.width, height: r.size.height, p: wipe) }
        return out.cropped(to: CGRect(origin: .zero, size: r.size))
    }

    /// A text piece with `p` of it shown: typewriter shows the first characters, word by word fades the words in
    /// one after another with a small rise.
    static func reveal(_ tx: TitleRaster.Text, _ kind: TextAnimation.Kind, _ p: Double, from img: CIImage) -> CIImage {
        if p >= 1 { return img }
        if p <= 0 { return .empty() }
        switch kind {
        case .typewriter:
            let k = Int((p * Double(tx.count) - 1e-9).rounded(.up))   // a letter appears as its share of the time starts, so the last one is on before the animation ends
            var out = CIImage.empty()
            for line in tx.lines where k > line.start {
                let x = k >= line.end ? line.band.maxX : (line.edges[max(0, min(line.edges.count - 1, k - line.start - 1))])
                out = img.cropped(to: CGRect(x: 0, y: line.band.minY, width: x, height: line.band.height)).composited(over: out)
            }
            return out
        case .words:
            let n = Double(max(1, tx.words.count)), u = p * n
            var out = CIImage.empty()
            for (i, w) in tx.words.enumerated() {
                let a = clamp(u - Double(i))
                guard a > 0 else { continue }
                var piece = img.cropped(to: w.rect)
                if a < 1 { piece = Effects.opacity(piece, ease(a)).transformed(by: CGAffineTransform(translationX: 0, y: (-(1 - ease(a)) * 0.15 * Double(w.rect.height)).rounded())) }
                out = piece.composited(over: out)
            }
            return out
        default:
            return img
        }
    }

    /// Left-to-right reveal with a soft edge (4 % of the width).
    static func softReveal(_ img: CIImage, width: CGFloat, height: CGFloat, p: Double) -> CIImage {
        guard p < 1 else { return img }
        guard p > 0 else { return .empty() }
        let soft = max(2, width * 0.04)
        let x = (width + soft) * CGFloat(p)
        let mask = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: x - soft, y: 0), "inputPoint1": CIVector(x: x, y: 0),
                                                                   "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
    }
}
