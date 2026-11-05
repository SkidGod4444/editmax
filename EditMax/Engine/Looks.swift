import Foundation
import CoreImage

/// Color lookup tables: built-in looks generated in code, and `.cube` files from disk, as `CIColorCube` data.
enum Looks {
    struct Cube { let data: Data; let dimension: Int }

    /// Built-in look names, in menu order.
    static let builtin = ["Teal & Orange", "Black & White", "Film Fade", "Cool Blue", "Warm Vintage", "High Contrast"]
    static func isBuiltin(_ key: String) -> Bool { builtin.contains { $0.caseInsensitiveCompare(key) == .orderedSame } }

    /// The largest cube the current Core Image accepts (read from the filter, not assumed).
    static let maxDimension: Int = {
        let attrs = CIFilter(name: "CIColorCube")?.attributes["inputCubeDimension"] as? [String: Any]
        return (attrs?[kCIAttributeMax] as? Int) ?? 64
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Cube] = [:]

    /// A cube for a built-in look name or a `.cube` path; nil when the file is missing or malformed.
    static func cube(for key: String) -> Cube? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let c: Cube?
        if let name = builtin.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) { c = generate(name) }
        else { c = parseCube(at: URL(fileURLWithPath: key)) }
        if let c { cache[key] = c }
        return c
    }

    /// Applies the look to an image, blended with the original by `mix` (0 = off, 1 = full).
    static func apply(_ img: CIImage, key: String, mix: Double) -> CIImage {
        guard mix > 0.001, let cube = cube(for: key) else { return img }
        let looked = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": cube.dimension, "inputCubeData": cube.data])
        if mix >= 0.999 { return looked }
        return looked.applyingFilter("CIMix", parameters: ["inputBackgroundImage": img, "inputAmount": mix])
    }

    // MARK: Built-in looks

    private static func generate(_ name: String) -> Cube {
        let f: (Double, Double, Double) -> (Double, Double, Double)
        func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        func sat(_ r: Double, _ g: Double, _ b: Double, _ s: Double) -> (Double, Double, Double) { let l = luma(r, g, b); return (l + (r - l) * s, l + (g - l) * s, l + (b - l) * s) }
        func curve(_ v: Double, _ k: Double) -> Double { let x = v - 0.5; return 0.5 + x * (1 + k * (1 - 4 * x * x)) }   // gentle S around the middle
        switch name {
        case "Black & White": f = { r, g, b in let l = luma(r, g, b); return (l, l, l) }
        case "Teal & Orange": f = { r, g, b in
            let l = luma(r, g, b)
            let (sr, sg, sb) = sat(r, g, b, 1.15)
            let shade = (1 - l) * 0.22, light = l * 0.18
            return (sr - shade * 0.5 + light, sg + shade * 0.25 + light * 0.4, sb + shade * 0.5 - light * 0.5) }
        case "Film Fade": f = { r, g, b in let (sr, sg, sb) = sat(r, g, b, 0.85); return (0.06 + sr * 0.9 + 0.02, 0.06 + sg * 0.9, 0.06 + sb * 0.9 - 0.02) }
        case "Cool Blue": f = { r, g, b in let l = luma(r, g, b); return (r - 0.04 * (1 - l), g, b + 0.09 * (1 - l)) }
        case "Warm Vintage": f = { r, g, b in let (sr, sg, sb) = sat(r, g, b, 0.8); return (0.04 + sr * 0.92 + 0.05, 0.03 + sg * 0.92, 0.02 + sb * 0.9 - 0.05) }
        case "High Contrast": f = { r, g, b in let (sr, sg, sb) = sat(r, g, b, 1.1); return (curve(sr, 0.6), curve(sg, 0.6), curve(sb, 0.6)) }
        default: f = { r, g, b in (r, g, b) }
        }
        let dim = 33
        var floats = [Float](repeating: 0, count: dim * dim * dim * 4)
        var i = 0
        for bi in 0..<dim { for gi in 0..<dim { for ri in 0..<dim {
            let (r, g, b) = f(Double(ri) / Double(dim - 1), Double(gi) / Double(dim - 1), Double(bi) / Double(dim - 1))
            floats[i] = Float(max(0, min(1, r))); floats[i + 1] = Float(max(0, min(1, g))); floats[i + 2] = Float(max(0, min(1, b))); floats[i + 3] = 1
            i += 4
        } } }
        return Cube(data: floats.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: dim)
    }

    // MARK: .cube files

    /// Parses an Adobe/Resolve `.cube` 3D LUT (red varies fastest, as Core Image wants). Larger cubes are resampled down to `maxDimension`.
    static func parseCube(at url: URL) -> Cube? {
        // DJI and some Resolve exports write Latin-1 comments, CR line ends and tabs between the keyword and its value.
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return nil }
        var size = 0
        var lo = [0.0, 0.0, 0.0], hi = [1.0, 1.0, 1.0]
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            switch parts.first?.uppercased() {
            case "LUT_3D_SIZE": size = Int(parts.dropFirst().first ?? "") ?? 0
            case "DOMAIN_MIN": lo = parts.dropFirst().compactMap(Double.init); if lo.count != 3 { lo = [0, 0, 0] }
            case "DOMAIN_MAX": hi = parts.dropFirst().compactMap(Double.init); if hi.count != 3 { hi = [1, 1, 1] }
            case "TITLE", "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE": continue
            default:
                let nums = parts.compactMap(Float.init)
                if nums.count == 3 { values.append(contentsOf: nums) }
            }
        }
        guard size >= 2, values.count == size * size * size * 3 else { return nil }
        let scale = (0..<3).map { Float(1 / max(1e-6, hi[$0] - lo[$0])) }, offset = (0..<3).map { Float(lo[$0]) }
        func at(_ r: Int, _ g: Int, _ b: Int) -> (Float, Float, Float) {
            let i = ((b * size + g) * size + r) * 3
            return ((values[i] - offset[0]) * scale[0], (values[i + 1] - offset[1]) * scale[1], (values[i + 2] - offset[2]) * scale[2])
        }
        let dim = min(size, maxDimension)
        var floats = [Float](repeating: 0, count: dim * dim * dim * 4)
        var o = 0
        for bi in 0..<dim { for gi in 0..<dim { for ri in 0..<dim {
            let (r, g, b): (Float, Float, Float)
            if dim == size { (r, g, b) = at(ri, gi, bi) }
            else {   // trilinear resample of the bigger cube
                let fr = Double(ri) / Double(dim - 1) * Double(size - 1), fg = Double(gi) / Double(dim - 1) * Double(size - 1), fb = Double(bi) / Double(dim - 1) * Double(size - 1)
                let r0 = Int(fr), g0 = Int(fg), b0 = Int(fb)
                let r1 = min(size - 1, r0 + 1), g1 = min(size - 1, g0 + 1), b1 = min(size - 1, b0 + 1)
                let tr = Float(fr - Double(r0)), tg = Float(fg - Double(g0)), tb = Float(fb - Double(b0))
                func lerp(_ a: (Float, Float, Float), _ b: (Float, Float, Float), _ t: Float) -> (Float, Float, Float) { (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t) }
                let c00 = lerp(at(r0, g0, b0), at(r1, g0, b0), tr), c10 = lerp(at(r0, g1, b0), at(r1, g1, b0), tr)
                let c01 = lerp(at(r0, g0, b1), at(r1, g0, b1), tr), c11 = lerp(at(r0, g1, b1), at(r1, g1, b1), tr)
                (r, g, b) = lerp(lerp(c00, c10, tg), lerp(c01, c11, tg), tb)
            }
            floats[o] = max(0, min(1, r)); floats[o + 1] = max(0, min(1, g)); floats[o + 2] = max(0, min(1, b)); floats[o + 3] = 1
            o += 4
        } } }
        return Cube(data: floats.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: dim)
    }
}
