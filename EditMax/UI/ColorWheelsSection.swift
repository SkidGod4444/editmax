import SwiftUI

/// Lift, gamma, gain and offset wheels for a clip's primary grade or one grade layer. The dot on a wheel is the colour
/// balance, placed where that colour sits on the vectorscope; the slider under it is the master. Drags coalesce into
/// one undo step. Ids: `inspector.color.wheel.<name>` (the pad), `.master.slider`, `.master.reset`, `inspector.color.wheels.reset`.
struct ColorWheelsCard: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    var info: ColorTargetInfo = .primary
    var title: String? = "Color wheels"

    private var wheels: ColorWheels { ToolExecutor(document: document, origin: .user).color(of: clip, info.target).wheelsOrIdentity }

    var body: some View {
        let w = wheels
        InspectorCard(title, footer: title == nil ? nil : "Drag a dot toward a color to tint that range; the slider is the wheel's master. Lift moves black, gamma the middle, gain white, offset everything. Double-click a wheel to reset it.", trailing: {
            if !w.isIdentity {
                Button("Reset") { set(ColorWheels()) }.controlSize(.small).focusable(false).pointer().uiFrame("inspector.color.\(info.idPrefix)wheels.reset")
            }
        }) {
            HStack(alignment: .top, spacing: 10) { wheel(.lift, w); wheel(.gamma, w) }
            HStack(alignment: .top, spacing: 10) { wheel(.gain, w); wheel(.offset, w) }
        }
    }

    private func set(_ new: ColorWheels) { try? ToolExecutor(document: document, origin: .user, coalesce: true).setWheels(clip.id, target: info.target, new) }

    private func wheel(_ name: ColorWheels.Name, _ all: ColorWheels) -> some View {
        let w = all[name]
        let range: ClosedRange<Double> = name == .gain ? -0.5...1 : -0.5...0.5
        let id = "\(info.idPrefix)wheel.\(name.rawValue)"
        return VStack(spacing: 4) {
            HStack {
                Text(name.title).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 2)
                Text(balanceText(w)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            WheelPad(wheel: w, scale: name == .offset ? 0.1 : 0.15) { new in var a = all; a[name] = new; set(a) }
                .frame(height: 96)
                .uiFrame("inspector.color.\(id)")
                .uiTap("inspector.color.\(id).reset", count: 2) { var a = all; a[name] = ColorWheel(); set(a) }
                .help("\(name.title): drag the dot toward a color; double-click to reset")
            HStack(spacing: 4) {
                // The gain master runs −0.5…1, so 0 is not the middle: the fill grows from 0 and a tick marks it.
                InspectorSlider(value: w.master, range: range, neutral: 0) { v in var a = all; var x = w; x.master = v; a[name] = x; set(a) }
                    .controlSize(.mini).pointer().uiFrame("inspector.color.\(id).master.slider")
                Text(String(format: "%+.2f", w.master)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    .onTapGesture(count: 2) { var a = all; var x = w; x.master = 0; a[name] = x; set(a) }.pointer()
                    .uiFrame("inspector.color.\(id).master.reset").uiTap("inspector.color.\(id).master.reset", count: 2) { var a = all; var x = w; x.master = 0; a[name] = x; set(a) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func balanceText(_ w: ColorWheel) -> String {
        guard w.r != 0 || w.g != 0 || w.b != 0 else { return "" }
        return [w.r, w.g, w.b].map { String(format: "%+.2f", $0) }.joined(separator: " ")
    }
}

/// The round pad of one wheel: a hue ring at vectorscope angles and a dot for the balance. Dragging sets r, g, b so
/// that the balance sits under the pointer while its luma (the part a dot cannot show) is kept. The response is
/// squared, so small moves near the centre are fine adjustments.
struct WheelPad: View {
    let wheel: ColorWheel
    /// Cb/Cr distance of the pad's rim.
    let scale: Double
    let onChange: (ColorWheel) -> Void

    /// The dot's position in the unit disc (y up).
    private var dot: CGPoint {
        let s = ColorBalance.scope(r: wheel.r, g: wheel.g, b: wheel.b)
        let u = s.cb / scale, v = s.cr / scale, m = (u * u + v * v).squareRoot()
        guard m > 1e-9 else { return .zero }
        let k = m.squareRoot() / m   // inverse of the squared response
        return CGPoint(x: u * k, y: v * k)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2), R = side / 2 - 2
            ZStack {
                Canvas { ctx, _ in
                    // Hue ring: each pure hue drawn where it sits on a Rec.709 vectorscope.
                    let ring = R, inner = R - 5
                    for h in stride(from: 0.0, to: 360, by: 4) {
                        let a0 = angle(h)
                        var a1 = angle(h + 4.5)
                        if a1 - a0 > .pi { a1 -= 2 * .pi } else if a0 - a1 > .pi { a1 += 2 * .pi }   // across atan2's seam
                        var p = Path()
                        p.move(to: point(c, inner, a0)); p.addLine(to: point(c, ring, a0)); p.addLine(to: point(c, ring, a1)); p.addLine(to: point(c, inner, a1)); p.closeSubpath()
                        let (r, g, b) = ColorBalance.pure(h)
                        ctx.fill(p, with: .color(Color(red: r, green: g, blue: b)))
                    }
                    let disc = Path(ellipseIn: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
                    ctx.fill(disc, with: .color(Color(white: 0.16)))
                    ctx.stroke(Path { $0.move(to: CGPoint(x: c.x - inner, y: c.y)); $0.addLine(to: CGPoint(x: c.x + inner, y: c.y)); $0.move(to: CGPoint(x: c.x, y: c.y - inner)); $0.addLine(to: CGPoint(x: c.x, y: c.y + inner)) },
                               with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - inner / 2, y: c.y - inner / 2, width: inner, height: inner)), with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                    let d = dot, pos = CGPoint(x: c.x + d.x * (inner - 4), y: c.y - d.y * (inner - 4))
                    ctx.stroke(Path { $0.move(to: c); $0.addLine(to: pos) }, with: .color(.white.opacity(0.35)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: pos.x - 4, y: pos.y - 4, width: 8, height: 8)), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: CGRect(x: pos.x - 4, y: pos.y - 4, width: 8, height: 8)), with: .color(.black.opacity(0.6)), lineWidth: 1)
                }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                    let inner = R - 9
                    var u = (g.location.x - c.x) / inner, v = (c.y - g.location.y) / inner
                    let m = (u * u + v * v).squareRoot()
                    if m > 1 { u /= m; v /= m }
                    let mm = min(1, m)
                    let k = mm   // squared response: radius m -> m²
                    let cb = u * k * scale, cr = v * k * scale
                    let y = ColorBalance.luma(wheel.r, wheel.g, wheel.b)
                    let rgb = ColorBalance.rgb(cb: cb, cr: cr, luma: y)
                    var w = wheel
                    w.r = (rgb.r * 1000).rounded() / 1000; w.g = (rgb.g * 1000).rounded() / 1000; w.b = (rgb.b * 1000).rounded() / 1000
                    onChange(w)
                })
                .onTapGesture(count: 2) { var w = wheel; w.r = 0; w.g = 0; w.b = 0; w.master = 0; onChange(w) }
                .pointer()
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// The vectorscope angle (radians, counter-clockwise from +Cb) of a hue.
    private func angle(_ h: Double) -> Double {
        let (r, g, b) = ColorBalance.pure(h), s = ColorBalance.scope(r: r, g: g, b: b)
        return atan2(s.cr, s.cb)
    }
    private func point(_ c: CGPoint, _ radius: CGFloat, _ a: Double) -> CGPoint { CGPoint(x: c.x + radius * cos(a), y: c.y - radius * sin(a)) }
}
