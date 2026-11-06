import Foundation
import CoreImage

/// Color wheels and custom curves, baked into lookup tables on the CPU and applied with built-in Core Image filters.
///
/// The wheels and the master / R / G / B curves are per-channel functions, so they become one 1D LUT per channel
/// (`CIColorCurves`, 4096 entries over −0.5…2.5): half-float values above 1 (exposure pushes, superwhites) are mapped
/// through the curve, not clipped, and linear interpolation between entries keeps 10-bit precision. Only the
/// hue-vs-saturation curve depends on all three channels; it is a 3D cube (`CIColorCube`, 64³) fed with the picture
/// halved and doubled again afterwards, so the cube's 0…1 input domain covers 0…2 (32 lattice steps per unit; values
/// below 0 or above 2 clamp there, and only when a hue-vs-saturation curve is set). Tables are cached by a hash of
/// the parameters, so a frame that does not change them never rebuilds one.
enum ColorCorrection {
    static let lutSize = 4096
    static let lutDomain: (lo: Double, hi: Double) = (-0.5, 2.5)
    static let cubeDimension = min(64, Looks.maxDimension)

    /// The wheels and curves applied to an image (nothing happens when both are nil or untouched).
    static func apply(_ img: CIImage, wheels: ColorWheels?, curves: ColorCurves?) -> CIImage {
        let w = wheels.flatMap { $0.isIdentity ? nil : $0 }, c = curves.flatMap { $0.isIdentity ? nil : $0 }
        guard w != nil || c != nil else { return img }
        var out = img
        var separable = c ?? ColorCurves(); separable.hueSat = []
        if w != nil || !separable.isIdentity {
            out = out.applyingFilter("CIColorCurves", parameters: ["inputCurvesData": table(wheels: w, curves: separable),
                                                                   "inputCurvesDomain": CIVector(x: lutDomain.lo, y: lutDomain.hi)])
        }
        if let c, c.hasHueSat {
            let half = scale(out, 0.5)
            let cubed = half.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": cubeDimension, "inputCubeData": hueSatCube(c.hueSat)])
            out = scale(cubed, 2)
        }
        return out
    }

    /// RGB scaled by `k`, alpha untouched.
    static func scale(_ img: CIImage, _ k: Double) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                                                         "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }

    /// One channel through the wheels, then the master curve, then the channel's own curve (what the LUT holds).
    static func transfer(_ x: Double, channel: Int, wheels: ColorWheels?, curves: ColorCurves?) -> Double {
        var v = wheels?.apply(x, channel: channel) ?? x
        if let curves {
            if !curves.master.isEmpty { v = CurveSpline(curves.master).value(v) }
            let own = channel == 0 ? curves.red : channel == 1 ? curves.green : curves.blue
            if !own.isEmpty { v = CurveSpline(own).value(v) }
        }
        return v
    }

    // MARK: Tables

    private struct SepKey: Hashable { let wheels: ColorWheels?; let curves: ColorCurves }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tables = BoundedCache<SepKey, Data>(limit: 64)
    nonisolated(unsafe) private static var cubes = BoundedCache<[CurvePoint], Data>(limit: 6)

    /// RGB float triplets for `CIColorCurves`.
    static func table(wheels: ColorWheels?, curves: ColorCurves) -> Data {
        let key = SepKey(wheels: wheels, curves: curves)
        lock.lock(); if let d = tables[key] { lock.unlock(); return d }; lock.unlock()
        let master = curves.master.isEmpty ? nil : CurveSpline(curves.master)
        let own = [curves.red, curves.green, curves.blue].map { $0.isEmpty ? nil : CurveSpline($0) }
        var f = [Float](repeating: 0, count: lutSize * 3)
        for i in 0..<lutSize {
            let x = lutDomain.lo + (lutDomain.hi - lutDomain.lo) * Double(i) / Double(lutSize - 1)
            for ch in 0..<3 {
                var v = wheels?.apply(x, channel: ch) ?? x
                if let master { v = master.value(v) }
                if let o = own[ch] { v = o.value(v) }
                f[i * 3 + ch] = Float(v)
            }
        }
        let d = f.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); tables[key] = d; lock.unlock()
        return d
    }

    /// The hue-vs-saturation cube over 0…2 (lattice value v stands for 2v; it stores the result halved).
    static func hueSatCube(_ points: [CurvePoint]) -> Data {
        lock.lock(); if let d = cubes[points] { lock.unlock(); return d }; lock.unlock()
        let spline = CurveSpline(points, periodic: true)
        let steps = 1024
        let gainTable = (0...steps).map { spline.value(Double($0) / Double(steps)) }
        let n = cubeDimension
        var f = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let r = 2 * Double(ri) / Double(n - 1), g = 2 * Double(gi) / Double(n - 1), b = 2 * Double(bi) / Double(n - 1)
            let mx = max(r, g, b), mn = min(r, g, b), chroma = mx - mn
            var o = (r, g, b)
            if chroma > 1e-6 {
                let h = ColorQualifier.hue(r: r, g: g, b: b, chroma: chroma, max: mx) / 360
                let k = gainTable[min(steps, max(0, Int((h * Double(steps)).rounded())))]
                let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                o = (y + (r - y) * k, y + (g - y) * k, y + (b - y) * k)
            }
            f[i] = Float(o.0 / 2); f[i + 1] = Float(o.1 / 2); f[i + 2] = Float(o.2 / 2); f[i + 3] = 1
            i += 4
        } } }
        let d = f.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); cubes[points] = d; lock.unlock()
        return d
    }
}

/// A small dictionary that forgets its oldest entries past `limit` (callers lock).
struct BoundedCache<K: Hashable, V> {
    let limit: Int
    private var values: [K: V] = [:]
    private var order: [K] = []
    init(limit: Int) { self.limit = limit }
    subscript(_ k: K) -> V? {
        get { values[k] }
        set {
            guard let v = newValue else { values[k] = nil; order.removeAll { $0 == k }; return }
            if values[k] == nil { order.append(k) }
            values[k] = v
            while order.count > limit { values[order.removeFirst()] = nil }
        }
    }
}

/// A smooth curve through points (monotone cubic Hermite, Fritsch–Carlson: no overshoot between points).
/// Outside the first and last point it continues in a straight line with the end slope, so values above 1 keep going.
/// `periodic` wraps x around 0…1 (the hue curve).
struct CurveSpline {
    private var xs: [Double] = []
    private var ys: [Double] = []
    private var ms: [Double] = []
    let periodic: Bool

    init(_ points: [CurvePoint], periodic: Bool = false) {
        self.periodic = periodic
        var p = points.sorted { $0.x < $1.x }
        if periodic {
            guard !p.isEmpty else { xs = [0, 1]; ys = [1, 1]; ms = [0, 0]; return }
            let before = p.suffix(2).map { CurvePoint($0.x - 1, $0.y) }, after = p.prefix(2).map { CurvePoint($0.x + 1, $0.y) }
            p = before + p + after
        } else {
            if p.first.map({ $0.x > 0.0005 }) ?? true { p.insert(CurvePoint(0, 0), at: 0) }
            if p.last.map({ $0.x < 0.9995 }) ?? true { p.append(CurvePoint(1, 1)) }
        }
        // Drop x duplicates (keep the later point).
        var cleaned: [CurvePoint] = []
        for q in p { if let l = cleaned.last, abs(l.x - q.x) < 1e-6 { cleaned[cleaned.count - 1] = q } else { cleaned.append(q) } }
        xs = cleaned.map(\.x); ys = cleaned.map(\.y)
        let n = xs.count
        guard n >= 2 else { ms = [Double](repeating: 0, count: n); return }
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
            if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        ms = m
    }

    func value(_ xIn: Double) -> Double {
        var x = xIn
        if periodic { x = x - floor(x) }
        let n = xs.count
        guard n >= 2 else { return ys.first ?? x }
        if x <= xs[0] { return ys[0] + (x - xs[0]) * ms[0] }
        if x >= xs[n - 1] { return ys[n - 1] + (x - xs[n - 1]) * ms[n - 1] }
        var lo = 0, hi = n - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if xs[mid] <= x { lo = mid } else { hi = mid } }
        let h = xs[hi] - xs[lo], t = (x - xs[lo]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[lo] + (t3 - 2 * t2 + t) * h * ms[lo] + (-2 * t3 + 3 * t2) * ys[hi] + (t3 - t2) * h * ms[hi]
    }
}

/// Colour balance helpers shared by the wheels tool and the wheel pads.
enum ColorBalance {
    /// Colour words an agent or a person may use for a direction, as HSV hue degrees.
    static let named: [(String, Double)] = [("red", 0), ("orange", 30), ("warm", 35), ("amber", 40), ("yellow", 60), ("lime", 90), ("green", 120),
                                             ("cyan", 180), ("teal", 190), ("cool", 210), ("blue", 240), ("purple", 270), ("violet", 275), ("magenta", 300), ("pink", 330)]

    /// Parses "blue", "teal", "240" or "240°" to hue degrees.
    static func hue(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "°", with: "")
        if let d = Double(t) { return d }
        return named.first { $0.0 == t }?.1
    }
    static func name(ofHue h: Double) -> String {
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let plain = named.filter { !["warm", "cool", "amber", "violet", "lime"].contains($0.0) }
        return plain.min { a, b in angle(a.1, hh) < angle(b.1, hh) }?.0 ?? "red"
    }
    static func angle(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return d > 180 ? 360 - d : d }

    /// The fully saturated colour of a hue (HSV s = v = 1).
    static func pure(_ h: Double) -> (Double, Double, Double) {
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(hh) {
        case 0: return (1, x, 0); case 1: return (x, 1, 0); case 2: return (0, 1, x)
        case 3: return (0, x, 1); case 4: return (x, 0, 1); default: return (1, 0, x)
        }
    }
    /// Rec.709 luma weights.
    static let weights = (r: 0.2126, g: 0.7152, b: 0.0722)
    static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// A luma-neutral RGB balance pointing at a hue: the largest component is `amount` (Rec.709 luma unchanged).
    static func toward(hue h: Double, amount: Double) -> (r: Double, g: Double, b: Double) {
        let (r, g, b) = pure(h), y = luma(r, g, b)
        let d = (r - y, g - y, b - y), m = max(abs(d.0), abs(d.1), abs(d.2))
        return (amount * d.0 / m, amount * d.1 / m, amount * d.2 / m)
    }

    /// Where an RGB balance sits on a Rec.709 vectorscope: (Cb, Cr). Luma does not move it.
    static func scope(r: Double, g: Double, b: Double) -> (cb: Double, cr: Double) {
        let y = luma(r, g, b)
        return ((b - y) / 1.8556, (r - y) / 1.5748)
    }
    /// The RGB balance at a vectorscope position, with the given luma (the inverse of `scope`).
    static func rgb(cb: Double, cr: Double, luma y: Double) -> (r: Double, g: Double, b: Double) {
        let r = y + 1.5748 * cr, b = y + 1.8556 * cb
        let g = (y - 0.2126 * r - 0.0722 * b) / 0.7152
        return (r, g, b)
    }
}
