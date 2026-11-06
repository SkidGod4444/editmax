import SwiftUI
import AVFoundation
import CoreVideo

/// What the scopes show for one frame: an RGB histogram, a luma waveform, the RGB parade and the vectorscope.
struct ScopeData {
    var histogram: [[Int]]      // 3 channels × 64 bins
    var waveform: CGImage       // 128 columns × 64 rows, bright = many pixels at that luma in that column
    var lumaMean: Double
    var peak: Int               // tallest histogram bin, for scaling
    var parade: CGImage? = nil       // RGB parade and vectorscope (ColorScopes.swift)
    var vectorscope: CGImage? = nil
}

enum ScopeSampler {
    /// Samples a BGRA pixel buffer on a grid (about 240 columns) and builds the scope data.
    static func sample(_ buf: CVPixelBuffer) -> ScopeData? {
        CVPixelBufferLockBaseAddress(buf, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), stride = CVPixelBufferGetBytesPerRow(buf)
        guard w > 0, h > 0 else { return nil }
        let step = max(1, w / 240)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 64), count: 3)
        var wave = [Int](repeating: 0, count: 128 * 64)
        var lumaSum = 0.0, n = 0
        var y = 0
        while y < h {
            let row = p + y * stride
            var x = 0
            while x < w {
                let b = Int(row[x * 4]), g = Int(row[x * 4 + 1]), r = Int(row[x * 4 + 2])
                hist[0][r >> 2] += 1; hist[1][g >> 2] += 1; hist[2][b >> 2] += 1
                let l = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                lumaSum += l; n += 1
                let col = x * 128 / w, rowI = 63 - min(63, Int(l) >> 2)
                wave[rowI * 128 + col] += 1
                x += step
            }
            y += step
        }
        guard n > 0 else { return nil }
        let peakW = max(1, wave.max() ?? 1)
        var gray = [UInt8](repeating: 0, count: 128 * 64)
        for i in 0..<gray.count where wave[i] > 0 {
            // Log scale so a thin line is still visible next to a solid block.
            gray[i] = UInt8(min(255, 40 + 215 * log(1 + Double(wave[i])) / log(1 + Double(peakW))))
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let img = CGImage(width: 128, height: 64, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let (parade, vectorscope) = ColorScopes.images(p, width: w, height: h, stride: stride, bgra: true, step: step)
        return ScopeData(histogram: hist, waveform: img, lumaMean: lumaSum / Double(n), peak: max(1, hist.flatMap { $0 }.max() ?? 1), parade: parade, vectorscope: vectorscope)
    }
}

/// The scopes panel under the preview: luma waveform, RGB parade, vectorscope and RGB histogram.
struct ScopesView: View {
    let data: ScopeData?
    var height: CGFloat = 110

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black)
                if let d = data {
                    Image(decorative: d.waveform, scale: 1).resizable().interpolation(.none).opacity(0.95).colorMultiply(Color(red: 0.6, green: 0.95, blue: 0.6))
                }
                Canvas { ctx, size in
                    for f in [0.25, 0.5, 0.75] {
                        let y = size.height * (1 - f)
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                    }
                }
                Text("Waveform").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).padding(3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            ParadePane(image: data?.parade)
            VectorscopePane(image: data?.vectorscope)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black)
                if let d = data {
                    Canvas { ctx, size in
                        let colors: [Color] = [.red, .green, .blue]
                        for (c, bins) in d.histogram.enumerated() {
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: size.height))
                            for (i, v) in bins.enumerated() {
                                let x = size.width * CGFloat(i) / 63
                                let y = size.height * (1 - CGFloat(log(1 + Double(v))) / CGFloat(log(1 + Double(d.peak))))
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                            path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                            ctx.fill(path, with: .color(colors[c].opacity(0.45)))
                        }
                    }
                }
                Text(data.map { "Histogram · luma \(Int($0.lumaMean))" } ?? "Histogram").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).padding(3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(6)
        .frame(height: height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
