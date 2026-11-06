import SwiftUI

/// Custom curves for a clip's primary grade or one grade layer: master, red, green, blue and hue vs saturation.
/// Click to add a point, drag to move it, double-click a point to remove it. The corner points of an RGB curve can be
/// dragged up or down (fading the blacks or dimming the whites). Ids: `inspector.color.curves.channel`,
/// `inspector.color.curves.pad`, `inspector.color.curves.reset`.
struct CurvesCard: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    var info: ColorTargetInfo = .primary
    var title: String? = "Curves"
    @State private var channel: ColorCurves.Name = .master

    private var curves: ColorCurves { ToolExecutor(document: document, origin: .user).color(of: clip, info.target).curvesOrIdentity }

    var body: some View {
        let all = curves
        InspectorCard(title, footer: title == nil ? nil : "Click to add a point, drag to move it, double-click it to remove it. Master moves R, G and B together; hue vs sat changes the saturation of one hue (1 = unchanged).", trailing: {
            if !all[channel].isEmpty {
                Button("Reset") { set(channel, []) }.controlSize(.small).focusable(false).pointer().uiFrame("inspector.color.\(info.idPrefix)curves.reset")
            }
        }) {
            Picker("Curve", selection: $channel) {
                ForEach(ColorCurves.Name.allCases, id: \.self) { n in
                    Text(n == .hueSat ? "Hue sat" : n == .master ? "Master" : String(n.title.prefix(1))).tag(n)
                }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).pointer().uiFrame("inspector.color.\(info.idPrefix)curves.channel")
            CurvePad(points: all[channel], kind: channel, others: ColorCurves.Name.allCases.filter { $0 != channel && $0 != .hueSat && channel != .hueSat }.map { ($0, all[$0]) }) { set(channel, $0) }
                .frame(height: 170)
                .uiFrame("inspector.color.\(info.idPrefix)curves.pad")
        }
    }

    private func set(_ n: ColorCurves.Name, _ points: [CurvePoint]) {
        var c = curves; c[n] = points
        try? ToolExecutor(document: document, origin: .user, coalesce: true).setCurves(clip.id, target: info.target, c)
    }
}

/// The square editor of one curve.
struct CurvePad: View {
    let points: [CurvePoint]
    let kind: ColorCurves.Name
    /// The other RGB curves, drawn faintly behind.
    var others: [(ColorCurves.Name, [CurvePoint])] = []
    let onChange: ([CurvePoint]) -> Void
    @State private var dragging: Int?

    private var isHue: Bool { kind == .hueSat }
    private var yMax: Double { isHue ? 2 : 1 }
    private var tint: Color {
        switch kind { case .master: return .white; case .red: return Color(red: 1, green: 0.35, blue: 0.35); case .green: return Color(red: 0.35, green: 0.9, blue: 0.4); case .blue: return Color(red: 0.4, green: 0.6, blue: 1); case .hueSat: return .white }
    }

    /// What the pad shows and drags: the explicit points plus, on an RGB curve, the implied corners.
    private var handles: [CurvePoint] {
        var p = points.sorted { $0.x < $1.x }
        guard !isHue else { return p }
        if p.first.map({ $0.x > 0.0005 }) ?? true { p.insert(CurvePoint(0, 0), at: 0) }
        if p.last.map({ $0.x < 0.9995 }) ?? true { p.append(CurvePoint(1, 1)) }
        return p
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, _ in
                let rect = CGRect(origin: .zero, size: size)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(Color(white: 0.12)))
                if isHue {
                    // A hue strip along the bottom, so x reads as a colour.
                    for i in 0..<72 {
                        let (r, g, b) = ColorBalance.pure(Double(i) * 5)
                        ctx.fill(Path(CGRect(x: size.width * Double(i) / 72, y: size.height - 6, width: size.width / 72 + 1, height: 6)), with: .color(Color(red: r, green: g, blue: b)))
                    }
                }
                var grid = Path()
                for f in [0.25, 0.5, 0.75] {
                    grid.move(to: pos(CurvePoint(f, 0), size)); grid.addLine(to: pos(CurvePoint(f, yMax), size))
                    grid.move(to: pos(CurvePoint(0, f * yMax), size)); grid.addLine(to: pos(CurvePoint(1, f * yMax), size))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                var ref = Path()
                if isHue { ref.move(to: pos(CurvePoint(0, 1), size)); ref.addLine(to: pos(CurvePoint(1, 1), size)) }
                else { ref.move(to: pos(CurvePoint(0, 0), size)); ref.addLine(to: pos(CurvePoint(1, 1), size)) }
                ctx.stroke(ref, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                for (n, ps) in others where !ps.isEmpty {
                    let col: Color = n == .red ? .red : n == .green ? .green : n == .blue ? .blue : .white
                    ctx.stroke(curvePath(ps, size), with: .color(col.opacity(0.3)), lineWidth: 1)
                }
                ctx.stroke(curvePath(points, size), with: .color(tint), lineWidth: 1.5)
                for (i, p) in handles.enumerated() {
                    let c = pos(p, size)
                    let r: CGFloat = dragging == i ? 5 : 4
                    let explicit = points.contains { abs($0.x - p.x) < 1e-6 }
                    let dotPath = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    if explicit { ctx.fill(dotPath, with: .color(tint)) }
                    ctx.stroke(dotPath, with: .color(explicit ? .black.opacity(0.6) : tint.opacity(0.7)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in drag(g, size) }.onEnded { _ in dragging = nil })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { e in removeNear(e.location, size) })
            .pointer()
        }
    }

    /// The plotting area sits `inset` points inside the pad, so the corner handles are drawn whole.
    private let inset: CGFloat = 6
    private func pos(_ p: CurvePoint, _ size: CGSize) -> CGPoint {
        let w = size.width - 2 * inset, h = size.height - 2 * inset - (isHue ? 6 : 0)
        return CGPoint(x: inset + p.x * w, y: inset + h * (1 - p.y / yMax))
    }
    private func value(_ q: CGPoint, _ size: CGSize) -> CurvePoint {
        let w = max(1, size.width - 2 * inset), h = max(1, size.height - 2 * inset - (isHue ? 6 : 0))
        return CurvePoint(min(1, max(0, (q.x - inset) / w)), min(yMax, max(0, (1 - (q.y - inset) / h) * yMax)))
    }

    private func curvePath(_ ps: [CurvePoint], _ size: CGSize) -> Path {
        let spline = CurveSpline(ps, periodic: isHue)
        var path = Path()
        let n = 96
        for i in 0...n {
            let x = Double(i) / Double(n)
            let y = ps.isEmpty ? (isHue ? 1 : x) : spline.value(x)
            let p = pos(CurvePoint(x, min(yMax, max(0, y))), size)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func nearest(_ q: CGPoint, _ size: CGSize) -> Int? {
        let hs = handles
        let d = hs.enumerated().map { ($0.offset, hypot(pos($0.element, size).x - q.x, pos($0.element, size).y - q.y)) }.min { $0.1 < $1.1 }
        return d.flatMap { $0.1 <= 9 ? $0.0 : nil }
    }

    private func drag(_ g: DragGesture.Value, _ size: CGSize) {
        var hs = handles
        if dragging == nil {
            if let i = nearest(g.startLocation, size) { dragging = i }
            else {
                guard hs.count < 32 else { return }
                let p = value(g.startLocation, size)
                // Keep x apart from the neighbours (the tools refuse points closer than 0.01).
                guard !hs.contains(where: { abs($0.x - p.x) < 0.012 }) else { return }
                hs.append(p); hs.sort { $0.x < $1.x }
                dragging = hs.firstIndex { $0.x == p.x && $0.y == p.y }
            }
        }
        guard let i = dragging, i < hs.count else { return }
        var p = value(g.location, size)
        let isCorner = !isHue && (abs(hs[i].x) < 0.0005 || abs(hs[i].x - 1) < 0.0005)
        if isCorner { p.x = hs[i].x }
        else {
            let lo = i > 0 ? hs[i - 1].x + 0.012 : 0, hi = i < hs.count - 1 ? hs[i + 1].x - 0.012 : 1
            p.x = min(max(p.x, lo), max(lo, hi))
        }
        p.x = (p.x * 1000).rounded() / 1000; p.y = (p.y * 1000).rounded() / 1000
        hs[i] = p
        onChange(explicitPoints(hs))
    }

    private func removeNear(_ q: CGPoint, _ size: CGSize) {
        guard let i = nearest(q, size) else { return }
        var hs = handles
        let isCorner = !isHue && (abs(hs[i].x) < 0.0005 || abs(hs[i].x - 1) < 0.0005)
        if isCorner { hs[i].y = hs[i].x } else { hs.remove(at: i) }   // a corner goes back to where it was implied
        onChange(explicitPoints(hs))
    }

    /// Drops corners that sit where they would be implied anyway, so an untouched curve stays empty.
    private func explicitPoints(_ hs: [CurvePoint]) -> [CurvePoint] {
        guard !isHue else { return hs }
        var out = hs
        if let f = out.first, abs(f.x) < 0.0005, abs(f.y) < 0.0005 { out.removeFirst() }
        if let l = out.last, abs(l.x - 1) < 0.0005, abs(l.y - 1) < 0.0005 { out.removeLast() }
        return out
    }
}
