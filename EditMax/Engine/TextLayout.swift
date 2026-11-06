import Foundation
import AppKit

/// Where texts land in the frame and in the Text lane, so two of them never sit on top of each other.
/// The frame box comes from the same font, wrapping width and padding the rasterizer uses (`OverlayLayerBuilder.renderText`),
/// measured without drawing.
enum TextLayout {
    /// The rect a text occupies in the frame, normalized (0–1, y down), centred on its (x, y).
    static func box(_ t: TextOverlay, canvas: CGSize) -> CGRect {
        if let s = TitleRasterizer.measure(t, canvas: canvas) { return CGRect(x: t.x - s.width / canvas.width / 2, y: t.y - s.height / canvas.height / 2, width: s.width / canvas.width, height: s.height / canvas.height) }   // lower thirds
        let style = CaptionPresets.style(t.preset)
        let font = t.font(style: style, size: t.fontSize)
        let maxWidth = (canvas.width * 0.9).rounded()
        let str = NSAttributedString(string: style.uppercase ? t.text.uppercased() : t.text, attributes: [.font: font])
        let used = str.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        let pad = style.box?.padding ?? 0
        let w = min(maxWidth, ceil(used.width) + 2 * pad + 8), h = ceil(used.height) + (style.box == nil ? 12 : pad + 4)
        return CGRect(x: t.x - w / canvas.width / 2, y: t.y - h / canvas.height / 2, width: w / canvas.width, height: h / canvas.height)
    }

    static func overlapInTime(_ a: TextOverlay, _ b: TextOverlay) -> Bool { a.start < b.end - 0.001 && b.start < a.end - 0.001 }

    /// True when the two texts are on screen together and their boxes intersect.
    static func collide(_ a: TextOverlay, _ b: TextOverlay, canvas: CGSize) -> Bool {
        overlapInTime(a, b) && box(a, canvas: canvas).insetBy(dx: 0, dy: 0.004).intersects(box(b, canvas: canvas))
    }

    struct Collision { let a: TextOverlay, b: TextOverlay; var start: Double { max(a.start, b.start) }; var end: Double { min(a.end, b.end) } }

    /// Every pair of texts that sit on top of each other at some moment.
    static func collisions(in texts: [TextOverlay], canvas: CGSize) -> [Collision] {
        var out: [Collision] = []
        for i in texts.indices { for j in texts.indices where j > i && collide(texts[i], texts[j], canvas: canvas) { out.append(Collision(a: texts[i], b: texts[j])) } }
        return out
    }

    /// The texts `t` collides with, among `others`.
    static func blockers(of t: TextOverlay, among others: [TextOverlay], canvas: CGSize) -> [TextOverlay] {
        others.filter { $0.id != t.id && collide(t, $0, canvas: canvas) }
    }

    /// A vertical position for `t` that clears every text on screen with it, the nearest free band to its own y: below
    /// first, then above, never off the frame. Nil when it already clears them or no band is free.
    static func clearY(for t: TextOverlay, among others: [TextOverlay], canvas: CGSize) -> Double? {
        let live = others.filter { $0.id != t.id && overlapInTime(t, $0) }
        guard live.contains(where: { collide(t, $0, canvas: canvas) }) else { return nil }
        let mine = box(t, canvas: canvas)
        let gap = 0.015
        var candidates: [Double] = []
        for o in live {
            let ob = box(o, canvas: canvas)
            candidates.append(ob.maxY + gap + mine.height / 2)   // just below it
            candidates.append(ob.minY - gap - mine.height / 2)   // just above it
        }
        let fits: (Double) -> Bool = { y in
            guard y - mine.height / 2 >= 0.02, y + mine.height / 2 <= 0.98 else { return false }
            var probe = t; probe.y = y
            return !live.contains { collide(probe, $0, canvas: canvas) }
        }
        // Nearest band wins; within 3 % of the frame, below beats above (a subtitle belongs under its title).
        return candidates.filter(fits).min { a, b in
            let da = abs(a - t.y), db = abs(b - t.y)
            return abs(da - db) < 0.03 ? a > b : da < db
        }
    }

    /// Sub-row (0 or 1) of each text in the Text lane: concurrent texts take turns so their bars never cover each other.
    /// Texts that overlap nothing in time stay on row 0; the lane shows two rows only while a row 1 exists.
    static func laneRows(_ texts: [TextOverlay]) -> [UUID: Int] {
        var rows: [UUID: Int] = [:]
        var ends: [Double] = [-1, -1]   // when each sub-row is next free
        for t in texts.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            let row = ends[0] <= t.start + 0.001 ? 0 : (ends[1] <= t.start + 0.001 ? 1 : (ends[0] <= ends[1] ? 0 : 1))
            rows[t.id] = row
            ends[row] = max(ends[row], t.end)
        }
        return rows
    }
}
