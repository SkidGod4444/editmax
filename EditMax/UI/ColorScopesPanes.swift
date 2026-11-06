import SwiftUI

/// The RGB parade pane of the scopes panel: red, green and blue traces side by side (bright = many pixels).
struct ParadePane: View {
    let image: CGImage?
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black)
            if let image { Image(decorative: image, scale: 1).resizable().interpolation(.medium).opacity(0.95) }
            Canvas { ctx, size in
                for f in [0.25, 0.5, 0.75] {
                    let y = size.height * (1 - f)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(.white.opacity(0.16)), lineWidth: 0.5)
                }
            }
            Text("Parade").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).padding(3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// The vectorscope pane: each spot in the colour of the pixels there, over a Rec.709 graticule with 75 % targets
/// (R, Mg, B, Cy, G, Yl) and the skin-tone line.
struct VectorscopePane: View {
    let image: CGImage?
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black)
            Canvas { ctx, size in
                let side = min(size.width, size.height), c = CGPoint(x: size.width / 2, y: size.height / 2)
                let k = side / CGFloat(ColorScopes.vectorSize)
                func at(_ r: Double, _ g: Double, _ b: Double) -> CGPoint {
                    let p = ColorScopes.vectorPoint(r: r, g: g, b: b)
                    return CGPoint(x: c.x + (p.x - Double(ColorScopes.vectorSize) / 2) * k, y: c.y + (p.y - Double(ColorScopes.vectorSize) / 2) * k)
                }
                let R = side / 2 * 0.92
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)), with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                ctx.stroke(Path { $0.move(to: CGPoint(x: c.x - R, y: c.y)); $0.addLine(to: CGPoint(x: c.x + R, y: c.y)); $0.move(to: CGPoint(x: c.x, y: c.y - R)); $0.addLine(to: CGPoint(x: c.x, y: c.y + R)) },
                           with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                // Skin-tone line: through the hue of typical skin (about 20° HSV), from the centre to the rim.
                let skin = at(0.95, 0.70, 0.55), dx = skin.x - c.x, dy = skin.y - c.y, len = max(1e-6, (dx * dx + dy * dy).squareRoot())
                ctx.stroke(Path { $0.move(to: c); $0.addLine(to: CGPoint(x: c.x + dx / len * R, y: c.y + dy / len * R)) }, with: .color(Color(red: 1, green: 0.75, blue: 0.55).opacity(0.35)), lineWidth: 0.75)
                if let image {
                    ctx.draw(Image(decorative: image, scale: 1).interpolation(.medium), in: CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side))
                }
                let targets: [(Double, Double, Double, String)] = [(0.75, 0, 0, "R"), (0.75, 0, 0.75, "Mg"), (0, 0, 0.75, "B"), (0, 0.75, 0.75, "Cy"), (0, 0.75, 0, "G"), (0.75, 0.75, 0, "Yl")]
                for t in targets {
                    let p = at(t.0, t.1, t.2)
                    ctx.stroke(Path(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white.opacity(0.4)), lineWidth: 0.5)
                    ctx.draw(Text(t.3).font(.system(size: 7)).foregroundStyle(.white.opacity(0.45)), at: CGPoint(x: p.x + (p.x > c.x ? 9 : -9), y: p.y))
                }
            }
            Text("Vectorscope").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).padding(3)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
