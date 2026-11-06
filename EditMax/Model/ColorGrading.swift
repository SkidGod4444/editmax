import Foundation

// MARK: - Color grading model: wheels, curves, grade layers, masks, finishing.
// Every type decodes with defaults and is "off" at its default, so a project without these keys renders as before.
// Hue everywhere (the wheels' `toward`, the qualifier, the hue-vs-saturation curve, the vectorscope summary) is the HSV
// hue in degrees or as a fraction of the circle: 0 = red, 60 = yellow, 120 = green, 180 = cyan, 240 = blue, 300 = magenta.

/// One primary wheel: an RGB balance plus a master amount. A channel's effective value is `master + r|g|b`.
/// All zero = untouched. Meaning per wheel (see `ColorWheels`).
struct ColorWheel: Codable, Equatable, Hashable {
    var r: Double = 0
    var g: Double = 0
    var b: Double = 0
    var master: Double = 0

    init(r: Double = 0, g: Double = 0, b: Double = 0, master: Double = 0) { self.r = r; self.g = g; self.b = b; self.master = master }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        r = try c.decodeIfPresent(Double.self, forKey: .r) ?? 0
        g = try c.decodeIfPresent(Double.self, forKey: .g) ?? 0
        b = try c.decodeIfPresent(Double.self, forKey: .b) ?? 0
        master = try c.decodeIfPresent(Double.self, forKey: .master) ?? 0
    }
    var isIdentity: Bool { r == 0 && g == 0 && b == 0 && master == 0 }
    /// The effective value per channel (master + balance).
    var channels: [Double] { [master + r, master + g, master + b] }
}

/// Lift, gamma, gain and offset, like Resolve's primary wheels. Per channel c, in this order:
///   x += offset_c                    (everything moves)
///   x  = x + lift_c · (1 − x)        (black moves to lift, white stays)
///   x  = x ^ 2^(−2·gamma_c)          (for x ≥ 0: + brightens the mids, black and white stay)
///   x  = x · (1 + gain_c)            (white moves to 1 + gain, black stays)
struct ColorWheels: Codable, Equatable, Hashable, CustomStringConvertible {
    var lift = ColorWheel()
    var gamma = ColorWheel()
    var gain = ColorWheel()
    var offset = ColorWheel()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lift = try c.decodeIfPresent(ColorWheel.self, forKey: .lift) ?? ColorWheel()
        gamma = try c.decodeIfPresent(ColorWheel.self, forKey: .gamma) ?? ColorWheel()
        gain = try c.decodeIfPresent(ColorWheel.self, forKey: .gain) ?? ColorWheel()
        offset = try c.decodeIfPresent(ColorWheel.self, forKey: .offset) ?? ColorWheel()
    }
    var isIdentity: Bool { lift.isIdentity && gamma.isIdentity && gain.isIdentity && offset.isIdentity }

    enum Name: String, CaseIterable { case lift, gamma, gain, offset
        var title: String { rawValue.capitalized }
    }
    subscript(_ n: Name) -> ColorWheel {
        get { switch n { case .lift: return lift; case .gamma: return gamma; case .gain: return gain; case .offset: return offset } }
        set { switch n { case .lift: lift = newValue; case .gamma: gamma = newValue; case .gain: gain = newValue; case .offset: offset = newValue } }
    }

    /// The wheels applied to one channel value (0 = red, 1 = green, 2 = blue). Values outside 0…1 are mapped, not clipped.
    func apply(_ v: Double, channel ch: Int) -> Double {
        var x = v + offset.channels[ch]
        let l = lift.channels[ch]
        x = x + l * (1 - x)
        if x > 0 { x = pow(x, pow(2, -2 * gamma.channels[ch])) }
        return x * max(0, 1 + gain.channels[ch])
    }

    /// Short form for the History tab: "lift b+0.05 master−0.05, gain master+0.1".
    var description: String {
        let parts = Name.allCases.compactMap { n -> String? in
            let w = self[n]
            guard !w.isIdentity else { return nil }
            let f = { (k: String, v: Double) -> String? in v == 0 ? nil : "\(k)\(v > 0 ? "+" : "")\(ProjectDiff.fmt(v))" }
            return ([n.rawValue] + [f("r", w.r), f("g", w.g), f("b", w.b), f("master", w.master)].compactMap { $0 }).joined(separator: " ")
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}

struct CurvePoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// Custom curves. Master runs on R, G and B alike (an RGB curve, not luma-only), then each channel's own curve.
/// Points are x → y in 0…1; (0,0) and (1,1) are implied unless a point sits at x = 0 or 1. An empty list = untouched.
/// `hueSat` maps hue (x as a fraction of the circle, 0 = red) to a saturation gain (y, 1 = unchanged, 0 = gray, 2 = double);
/// it wraps around at red.
struct ColorCurves: Codable, Equatable, Hashable, CustomStringConvertible {
    var master: [CurvePoint] = []
    var red: [CurvePoint] = []
    var green: [CurvePoint] = []
    var blue: [CurvePoint] = []
    var hueSat: [CurvePoint] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        master = try c.decodeIfPresent([CurvePoint].self, forKey: .master) ?? []
        red = try c.decodeIfPresent([CurvePoint].self, forKey: .red) ?? []
        green = try c.decodeIfPresent([CurvePoint].self, forKey: .green) ?? []
        blue = try c.decodeIfPresent([CurvePoint].self, forKey: .blue) ?? []
        hueSat = try c.decodeIfPresent([CurvePoint].self, forKey: .hueSat) ?? []
    }
    var isIdentity: Bool { master.isEmpty && red.isEmpty && green.isEmpty && blue.isEmpty && hueSat.isEmpty }
    /// True when only the separable part (master, R, G, B) is set.
    var hasHueSat: Bool { !hueSat.isEmpty }

    enum Name: String, CaseIterable { case master, red, green, blue, hueSat
        var title: String { switch self { case .master: return "Master"; case .red: return "Red"; case .green: return "Green"; case .blue: return "Blue"; case .hueSat: return "Hue vs sat" } }
        /// The tool argument spelling.
        var argName: String { self == .hueSat ? "hue_sat" : rawValue }
    }
    subscript(_ n: Name) -> [CurvePoint] {
        get { switch n { case .master: return master; case .red: return red; case .green: return green; case .blue: return blue; case .hueSat: return hueSat } }
        set { switch n { case .master: master = newValue; case .red: red = newValue; case .green: green = newValue; case .blue: blue = newValue; case .hueSat: hueSat = newValue } }
    }

    var description: String {
        let parts = Name.allCases.compactMap { n -> String? in
            let ps = self[n]
            return ps.isEmpty ? nil : "\(n.title.lowercased()) \(ps.count) point\(ps.count == 1 ? "" : "s")"
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}

// MARK: - Finishing

/// Per-clip finishing after the grade, in this order: noise reduction → sharpen → glow → vignette → grain.
/// Amounts are 0 = off. Sizes and radii are in pixels of a 1080-line frame (scaled with the project height).
struct ClipFinish: Codable, Equatable, Hashable {
    var noiseReduction: Double = 0   // 0…1
    var sharpen: Double = 0          // 0…1
    var sharpenRadius: Double = 1.5  // 0.5…10 px
    var glow: Double = 0             // 0…1
    var glowRadius: Double = 24      // 2…200 px
    var glowThreshold: Double = 0.75 // 0…1: only what is brighter glows
    var vignette: Double = 0         // −1…1: + darkens the edges, − lightens them
    var vignetteSize: Double = 0.8   // 0.1…1.5: where the falloff is centred (1 = the corners)
    var vignetteSoftness: Double = 0.5 // 0.05…1: how wide the falloff is
    var grain: Double = 0            // 0…1
    var grainSize: Double = 1        // 0.5…4 px

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let z = ClipFinish()
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? z.noiseReduction
        sharpen = try c.decodeIfPresent(Double.self, forKey: .sharpen) ?? z.sharpen
        sharpenRadius = try c.decodeIfPresent(Double.self, forKey: .sharpenRadius) ?? z.sharpenRadius
        glow = try c.decodeIfPresent(Double.self, forKey: .glow) ?? z.glow
        glowRadius = try c.decodeIfPresent(Double.self, forKey: .glowRadius) ?? z.glowRadius
        glowThreshold = try c.decodeIfPresent(Double.self, forKey: .glowThreshold) ?? z.glowThreshold
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? z.vignette
        vignetteSize = try c.decodeIfPresent(Double.self, forKey: .vignetteSize) ?? z.vignetteSize
        vignetteSoftness = try c.decodeIfPresent(Double.self, forKey: .vignetteSoftness) ?? z.vignetteSoftness
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? z.grain
        grainSize = try c.decodeIfPresent(Double.self, forKey: .grainSize) ?? z.grainSize
    }
    /// Nothing is drawn: every amount is 0 (the sizes alone do nothing).
    var isIdentity: Bool { noiseReduction == 0 && sharpen == 0 && glow == 0 && vignette == 0 && grain == 0 }
}

// MARK: - Grade layers and masks

/// A rectangle or ellipse in frame space. Centre and size are fractions of the frame (y down, as everywhere in
/// EditMax), rotation is clockwise degrees, feather is the soft edge's width as a fraction of the frame height.
struct MaskShape: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable { case rectangle, ellipse }
    var kind: Kind = .ellipse
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var width: Double = 0.5
    var height: Double = 0.5
    var rotation: Double = 0
    var feather: Double = 0.05
    var invert = false

    init(kind: Kind = .ellipse) { self.kind = kind }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .ellipse
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.5
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0.5
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.05
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
    }
}

/// An HSL qualifier (colour selection). Hue in degrees (0 = red); saturation is max − min of R, G, B (0 = gray,
/// 1 = a pure colour); luma is Rec.709. A pixel is selected inside every range, fading to unselected over the
/// softness outside it. Defaults select everything.
struct ColorQualifier: Codable, Equatable, Hashable {
    var hueCenter: Double = 0
    var hueWidth: Double = 360     // degrees; 360 = every hue
    var hueSoftness: Double = 20   // degrees
    var satLow: Double = 0
    var satHigh: Double = 1
    var satSoftness: Double = 0.05
    var lumaLow: Double = 0
    var lumaHigh: Double = 1
    var lumaSoftness: Double = 0.05
    /// Blur of the selection, in pixels of a 1080-line frame (cleans up a noisy key).
    var blur: Double = 2

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hueCenter = try c.decodeIfPresent(Double.self, forKey: .hueCenter) ?? 0
        hueWidth = try c.decodeIfPresent(Double.self, forKey: .hueWidth) ?? 360
        hueSoftness = try c.decodeIfPresent(Double.self, forKey: .hueSoftness) ?? 20
        satLow = try c.decodeIfPresent(Double.self, forKey: .satLow) ?? 0
        satHigh = try c.decodeIfPresent(Double.self, forKey: .satHigh) ?? 1
        satSoftness = try c.decodeIfPresent(Double.self, forKey: .satSoftness) ?? 0.05
        lumaLow = try c.decodeIfPresent(Double.self, forKey: .lumaLow) ?? 0
        lumaHigh = try c.decodeIfPresent(Double.self, forKey: .lumaHigh) ?? 1
        lumaSoftness = try c.decodeIfPresent(Double.self, forKey: .lumaSoftness) ?? 0.05
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 2
    }

    /// Membership 0…1 of one colour (components clamped to 0…1).
    func membership(r: Double, g: Double, b: Double) -> Double {
        let r = min(1, max(0, r)), g = min(1, max(0, g)), b = min(1, max(0, b))
        let mx = max(r, g, b), mn = min(r, g, b), chroma = mx - mn
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        func ramp(_ v: Double, _ lo: Double, _ hi: Double, _ soft: Double) -> Double {
            if v >= lo && v <= hi { return 1 }
            let d = v < lo ? lo - v : v - hi
            guard soft > 1e-6 else { return 0 }
            let t = max(0, 1 - d / soft)
            return t * t * (3 - 2 * t)
        }
        var m = ramp(luma, lumaLow, lumaHigh, lumaSoftness) * ramp(chroma, satLow, satHigh, satSoftness)
        if m == 0 { return 0 }
        if hueWidth < 360 {
            let h = Self.hue(r: r, g: g, b: b, chroma: chroma, max: mx)
            var d = abs(h - hueCenter).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            m *= ramp(d, 0, hueWidth / 2, hueSoftness)
        }
        return m
    }

    /// HSV hue in degrees, 0…360 (0 for grays).
    static func hue(r: Double, g: Double, b: Double, chroma: Double, max mx: Double) -> Double {
        guard chroma > 1e-9 else { return 0 }
        var h: Double
        if mx == r { h = ((g - b) / chroma).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = (b - r) / chroma + 2 }
        else { h = (r - g) / chroma + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }
}

/// An AI subject matte from Apple's Vision: a person (`VNGeneratePersonSegmentationRequest`) or the salient
/// foreground objects (`VNGenerateForegroundInstanceMaskRequest`). See `SubjectMatte` for how it runs.
struct SubjectMask: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable { case person, foreground
        var title: String { self == .person ? "Person" : "Foreground objects" }
    }
    var kind: Kind = .person
    /// Soft edge, in pixels of a 1080-line frame.
    var feather: Double = 4

    init(kind: Kind = .person) { self.kind = kind }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .person
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 4
    }
}

/// Where a grade layer applies. The parts that are set multiply (shape × colour selection × subject); `invert`
/// flips the result. No part set = the whole picture.
struct GradeMask: Codable, Equatable {
    var shape: MaskShape? = nil
    var qualifier: ColorQualifier? = nil
    var subject: SubjectMask? = nil
    var invert = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decodeIfPresent(MaskShape.self, forKey: .shape)
        qualifier = try c.decodeIfPresent(ColorQualifier.self, forKey: .qualifier)
        subject = try c.decodeIfPresent(SubjectMask.self, forKey: .subject)
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
    }
    var isEmpty: Bool { shape == nil && qualifier == nil && subject == nil }
}

/// One grade in a clip's grade stack (a simple version of Resolve's serial nodes): its own corrections, applied to
/// the picture after the clip's primary grade and the layers before it, blended back by `mix` inside its mask.
/// The input (conversion) LUT is not used in a layer.
struct GradeLayer: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Layer"
    var enabled = true
    var mix: Double = 1
    var color = ClipColor()
    var mask: GradeMask? = nil

    init(id: UUID = UUID(), name: String = "Layer") { self.id = id; self.name = name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Layer"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mix = try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1
        color = try c.decodeIfPresent(ClipColor.self, forKey: .color) ?? ClipColor()
        mask = try c.decodeIfPresent(GradeMask.self, forKey: .mask)
    }
    /// It changes the picture: enabled, mixed in, with a correction.
    var isActive: Bool { enabled && mix > 0.0005 && !color.isIdentity }
}

extension Clip {
    /// The clip has a grade layer or finishing that draws something (for the before/after button).
    var hasColorExtras: Bool { grades.contains { $0.isActive } || !(finish?.isIdentity ?? true) }
}
