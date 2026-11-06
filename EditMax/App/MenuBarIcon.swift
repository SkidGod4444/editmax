import AppKit

/// The menu bar glyph: the app icon's play triangle cut into three diagonal stripes (AppIcon.svg), drawn as a template
/// image so macOS tints it for light and dark menu bars and for the highlighted state. The gaps are wider than the app
/// icon's (26 of 1024 units would be under a point here and vanish at 1x), and the corners rounder, so it still reads as
/// the same mark at 18 points.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    /// The template image the menu bar shows.
    static let image: NSImage = {
        let image = NSImage(size: size, flipped: true) { rect in draw(in: rect); return true }
        image.isTemplate = true
        image.accessibilityDescription = "EditMax"
        return image
    }()

    /// Draws the glyph in black into `rect` (a template image only uses the alpha). y runs down, as in the SVG.
    ///
    /// The geometry is AppIcon.svg's, in its 1024-unit space: the triangle (381.8,316) (734.6,512) (381.8,708) and two
    /// gaps along the "/" diagonal at ±102 units from the canvas centre (512,512), measured along (1,1)/√2. That leaves
    /// the icon's three pieces: a corner at the top left, the big middle, and a sliver at the tip. Here the triangle is
    /// 14.5 points tall, the gaps 1.5 points wide (the icon's 26 units would be under a point), and the tip gap sits a
    /// little further in (90 units) so the sliver stays about 1.7 points thick.
    static func draw(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let k = rect.height / size.height                // 1 at the menu bar size
        let s = 14.5 * k / 392                           // points per SVG unit
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {   // SVG units → rect, with the triangle centred
            CGPoint(x: rect.midX + (x - 558.2) * s, y: rect.midY + (y - 512) * s)
        }
        ctx.saveGState()
        ctx.addPath(roundedTriangle(point(381.8, 316), point(734.6, 512), point(381.8, 708), radius: 1.1 * k))
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()

        let centre = point(512, 512)
        let gap = 1.5 * k
        ctx.setBlendMode(.clear)
        for d in [-102.0 * s, 90.0 * s] {
            ctx.saveGState()
            ctx.translateBy(x: centre.x, y: centre.y)
            ctx.rotate(by: -.pi / 4)                     // in this y-down space, y now runs along (1,1)/√2, the gaps' normal
            ctx.fill(CGRect(x: -rect.width * 2, y: d - gap / 2, width: rect.width * 4, height: gap))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// A triangle with each corner rounded by `radius` (the SVG's round stroke join).
    private static func roundedTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let mid = CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2)   // start on the flat left edge
        p.move(to: mid)
        p.addArc(tangent1End: a, tangent2End: b, radius: radius)
        p.addArc(tangent1End: b, tangent2End: c, radius: radius)
        p.addArc(tangent1End: c, tangent2End: a, radius: radius)
        p.closeSubpath()
        return p
    }
}
