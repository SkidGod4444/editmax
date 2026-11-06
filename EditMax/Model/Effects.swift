import Foundation

// MARK: - Per-clip picture effects
// Green-screen key, blend mode and face / region blur. Every field decodes with a default and defaults to off, so a
// clip saved before these existed (or one that never uses them) renders exactly as it did.

// Enums decode from their raw string with a fallback, so a value a newer build wrote never fails the whole project.

struct ClipEffects: Codable, Equatable {
    /// Green-screen (chroma) key; nil = the picture is opaque as decoded.
    var chromaKey: ChromaKey? = nil
    /// How the clip's picture combines with the rows below it. `.normal` covers them (with its opacity), as before.
    var blend: ClipBlendMode = .normal
    /// Faces found by `blur_faces` and rectangles added by `blur_region`, blurred or pixelated; nil = none.
    var blur: FaceBlur? = nil

    var isDefault: Bool { self == ClipEffects() }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chromaKey = try? c.decodeIfPresent(ChromaKey.self, forKey: .chromaKey)
        blend = (try? c.decodeIfPresent(String.self, forKey: .blend)).flatMap(ClipBlendMode.init(rawValue:)) ?? .normal
        blur = try? c.decodeIfPresent(FaceBlur.self, forKey: .blur)
    }
}

/// A green-screen key (see `Keyer`). The key colour is the screen's colour in the clip's own pixel values; tolerance
/// and softness say how far from it still counts as screen; spill removes the screen's colour cast from what stays;
/// shrink (+) / grow (−) and edge blur clean up the matte, in pixels of a 1080-line picture (scaled with the source).
struct ChromaKey: Codable, Equatable {
    var colorHex: String = "#00B140"
    var tolerance: Double = 0.4
    var softness: Double = 0.3
    var spill: Double = 0.6
    var shrink: Double = 0
    var edgeBlur: Double = 0
    /// The colour came from `color: auto` (the frame's edges); display only.
    var autoPicked: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#00B140"
        tolerance = try c.decodeIfPresent(Double.self, forKey: .tolerance) ?? 0.4
        softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? 0.3
        spill = try c.decodeIfPresent(Double.self, forKey: .spill) ?? 0.6
        shrink = try c.decodeIfPresent(Double.self, forKey: .shrink) ?? 0
        edgeBlur = try c.decodeIfPresent(Double.self, forKey: .edgeBlur) ?? 0
        autoPicked = try c.decodeIfPresent(Bool.self, forKey: .autoPicked) ?? false
    }

    static let toleranceRange = 0.0...1.0, softnessRange = 0.0...1.0, spillRange = 0.0...1.0
    static let shrinkRange = -20.0...20.0, edgeBlurRange = 0.0...20.0
}

/// Blend modes for a clip over the rows below it, through Core Image's blend filters.
enum ClipBlendMode: String, Codable, CaseIterable {
    case normal, multiply, screen, overlay, softLight, hardLight, add, subtract, difference, exclusion, darken, lighten
    case colorDodge, colorBurn, linearBurn, hue, saturation, color, luminosity

    var title: String {
        switch self {
        case .normal: return "Normal"; case .multiply: return "Multiply"; case .screen: return "Screen"; case .overlay: return "Overlay"
        case .softLight: return "Soft light"; case .hardLight: return "Hard light"; case .add: return "Add"; case .subtract: return "Subtract"
        case .difference: return "Difference"; case .exclusion: return "Exclusion"; case .darken: return "Darken"; case .lighten: return "Lighten"
        case .colorDodge: return "Color dodge"; case .colorBurn: return "Color burn"; case .linearBurn: return "Linear burn"
        case .hue: return "Hue"; case .saturation: return "Saturation"; case .color: return "Color"; case .luminosity: return "Luminosity"
        }
    }
    /// The Core Image filter that draws it (the clip's picture is the input, the rows below the background).
    var filterName: String? {
        switch self {
        case .normal: return nil
        case .multiply: return "CIMultiplyBlendMode"; case .screen: return "CIScreenBlendMode"; case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"; case .hardLight: return "CIHardLightBlendMode"; case .add: return "CIAdditionCompositing"
        case .subtract: return "CISubtractBlendMode"; case .difference: return "CIDifferenceBlendMode"; case .exclusion: return "CIExclusionBlendMode"
        case .darken: return "CIDarkenBlendMode"; case .lighten: return "CILightenBlendMode"; case .colorDodge: return "CIColorDodgeBlendMode"
        case .colorBurn: return "CIColorBurnBlendMode"; case .linearBurn: return "CILinearBurnBlendMode"; case .hue: return "CIHueBlendMode"
        case .saturation: return "CISaturationBlendMode"; case .color: return "CIColorBlendMode"; case .luminosity: return "CILuminosityBlendMode"
        }
    }
    static func parse(_ text: String) -> ClipBlendMode? {
        let key = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if key == "linearDodge".lowercased() || key == "addition" { return .add }
        return allCases.first { $0.rawValue.lowercased() == key }
    }
}

/// One box per analysed moment, in SOURCE seconds of the clip's asset (trims and speed never move it), normalized to the
/// oriented picture: x, y = top-left corner, 0…1 with y down.
struct BlurBox: Codable, Equatable {
    var t: Double, x: Double, y: Double, w: Double, h: Double
}

/// One face followed through the clip (`id` is its number, 1 = the first to appear), or one tracked region.
struct FaceTrack: Codable, Equatable {
    var id: Int
    var boxes: [BlurBox]

    /// Gaps up to this long between two boxes are bridged by interpolation (a missed detection, a turned head).
    static let maxGap = 1.0
    /// A box is held this long before the first and after the last sample, and on either side of a longer gap.
    static let hold = 0.3

    var start: Double { boxes.first?.t ?? 0 }
    var end: Double { boxes.last?.t ?? 0 }

    /// The box at a source time: linear between samples, held briefly at the ends and around long gaps, nil outside.
    func box(at t: Double) -> BlurBox? {
        guard let first = boxes.first, let last = boxes.last else { return nil }
        if t < first.t - Self.hold || t > last.t + Self.hold { return nil }
        if t <= first.t { return first }
        if t >= last.t { return last }
        var lo = 0, hi = boxes.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if boxes[mid].t <= t { lo = mid } else { hi = mid } }
        let a = boxes[lo], b = boxes[hi]
        if b.t - a.t > Self.maxGap {
            if t - a.t <= Self.hold { return a }
            if b.t - t <= Self.hold { return b }
            return nil
        }
        let u = (t - a.t) / max(1e-9, b.t - a.t)
        func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * u }
        return BlurBox(t: t, x: mix(a.x, b.x), y: mix(a.y, b.y), w: mix(a.w, b.w), h: mix(a.h, b.h))
    }
}

/// A rectangle to blur that the user (or agent) placed: fixed, or followed through the picture from where it was drawn.
struct BlurRegion: Codable, Equatable {
    var id: Int
    /// Where it was drawn (normalized, top-left, y down) and the source seconds it covers.
    var x: Double, y: Double, w: Double, h: Double
    var start: Double, end: Double
    /// The tracked path in `Project.faceTracks` (nil = it stays where it was drawn).
    var pathKey: String? = nil
    /// The path, filled from the cache by `Project.hydrated`; empty in the document.
    var path: [BlurBox] = []

    init(id: Int, x: Double, y: Double, w: Double, h: Double, start: Double, end: Double, pathKey: String? = nil) {
        self.id = id; self.x = x; self.y = y; self.w = w; self.h = h; self.start = start; self.end = end; self.pathKey = pathKey
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 1
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.35
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.35
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 0.3
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 0.3
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? .greatestFiniteMagnitude
        pathKey = try c.decodeIfPresent(String.self, forKey: .pathKey)
        path = try c.decodeIfPresent([BlurBox].self, forKey: .path) ?? []
    }

    /// The box at a source time: the tracked path (held where tracking stopped) or the rectangle as drawn; nil outside it.
    func box(at t: Double) -> BlurBox? {
        guard t >= start - 0.001, t <= end + 0.001 else { return nil }
        if !path.isEmpty, let b = FaceTrack(id: id, boxes: path).box(at: t) ?? (t > (path.last?.t ?? 0) ? path.last : path.first) { return b }
        return BlurBox(t: t, x: x, y: y, w: w, h: h)
    }
}

/// Blur or pixelate the faces of a clip and any regions placed on it.
struct FaceBlur: Codable, Equatable {
    enum Style: String, Codable, CaseIterable {
        case blur, pixelate, solid
        var title: String { switch self { case .blur: return "Blur"; case .pixelate: return "Pixelate"; case .solid: return "Black box" } }
    }
    var style: Style = .blur
    /// 0…1: how strong the blur or how coarse the pixels are, relative to each box's size.
    var strength: Double = 0.6
    /// 0…1: each face box grows by this fraction of its size (Vision's boxes are tight around the features).
    var expand: Double = 0.25
    /// 0…1: how soft the edge of the blurred shape is.
    var feather: Double = 0.4
    /// Face numbers left sharp ("blur everyone but the speaker").
    var exclude: [Int] = []
    /// The faces found, in `Project.faceTracks` (a cache history snapshots skip); "" = no face analysis yet.
    var pathKey: String = ""
    /// The faces, filled from the cache by `Project.hydrated`; empty in the document.
    var tracks: [FaceTrack] = []
    /// How many faces the analysis found (kept on the clip so the inspector and inspect_timeline can say it).
    var faceCount: Int = 0
    var regions: [BlurRegion] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? c.decodeIfPresent(String.self, forKey: .style)).flatMap(Style.init(rawValue:)) ?? .blur
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 0.6
        expand = try c.decodeIfPresent(Double.self, forKey: .expand) ?? 0.25
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.4
        exclude = try c.decodeIfPresent([Int].self, forKey: .exclude) ?? []
        pathKey = try c.decodeIfPresent(String.self, forKey: .pathKey) ?? ""
        tracks = try c.decodeIfPresent([FaceTrack].self, forKey: .tracks) ?? []
        faceCount = try c.decodeIfPresent(Int.self, forKey: .faceCount) ?? 0
        regions = try c.decodeIfPresent([BlurRegion].self, forKey: .regions) ?? []
    }

    /// Every box to blur at a source time: the faces not excluded, then the regions.
    func boxes(at t: Double) -> [BlurBox] {
        tracks.filter { !exclude.contains($0.id) }.compactMap { $0.box(at: t) } + regions.compactMap { $0.box(at: t) }
    }
    var isEmpty: Bool { pathKey.isEmpty && regions.isEmpty }

    static let strengthRange = 0.0...1.0, expandRange = 0.0...1.0, featherRange = 0.0...1.0
}

// MARK: - Title animation and lower thirds

/// How a text comes on and goes off. Each side has its own kind and length; `none` = it cuts, as before.
struct TextAnimation: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case none, fade, slideUp, slideDown, pop, typewriter, words, wipe
        var title: String {
            switch self {
            case .none: return "None"; case .fade: return "Fade"; case .slideUp: return "Slide up"; case .slideDown: return "Slide down"
            case .pop: return "Pop"; case .typewriter: return "Typewriter"; case .words: return "Word by word"; case .wipe: return "Wipe"
            }
        }
        static func parse(_ text: String) -> Kind? {
            let key = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
            if key == "wordbyword" { return .words }
            if key == "scale" || key == "popscale" { return .pop }
            return allCases.first { $0.rawValue.lowercased() == key }
        }
    }
    var inKind: Kind = .none
    var inDuration: Double = 0.5
    var outKind: Kind = .none
    var outDuration: Double = 0.4

    var isNone: Bool { inKind == .none && outKind == .none }

    init(inKind: Kind = .none, inDuration: Double = 0.5, outKind: Kind = .none, outDuration: Double = 0.4) {
        self.inKind = inKind; self.inDuration = inDuration; self.outKind = outKind; self.outDuration = outDuration
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inKind = (try? c.decodeIfPresent(String.self, forKey: .inKind)).flatMap(Kind.init(rawValue:)) ?? Kind.none
        inDuration = try c.decodeIfPresent(Double.self, forKey: .inDuration) ?? 0.5
        outKind = (try? c.decodeIfPresent(String.self, forKey: .outKind)).flatMap(Kind.init(rawValue:)) ?? Kind.none
        outDuration = try c.decodeIfPresent(Double.self, forKey: .outDuration) ?? 0.4
    }
    static let durationRange = 0.05...5.0
}

/// A lower third: the text overlay's `text` is the name, `role` the line under it, drawn by a template.
struct LowerThird: Codable, Equatable {
    enum Template: String, Codable, CaseIterable {
        case bar, box, line
        var title: String { switch self { case .bar: return "Bar"; case .box: return "Box"; case .line: return "Line" } }
    }
    var template: Template = .bar
    var role: String = ""
    /// The accent: the bar, the name box or the rule, by template.
    var accentHex: String = "#FF9F0A"

    init(template: Template = .bar, role: String = "", accentHex: String = "#FF9F0A") { self.template = template; self.role = role; self.accentHex = accentHex }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = (try? c.decodeIfPresent(String.self, forKey: .template)).flatMap(Template.init(rawValue:)) ?? .bar
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? "#FF9F0A"
    }
}

// MARK: - Project colour

/// The project's output colour. SDR Rec.709 is the original pass-through path, untouched; the HDR settings colour-manage
/// every frame (see `ColorManagement`).
enum ProjectColor: String, Codable, CaseIterable {
    case sdr, hlg, pq
    var title: String { switch self { case .sdr: return "SDR Rec.709"; case .hlg: return "HDR HLG (Rec.2020)"; case .pq: return "HDR PQ (Rec.2020)" } }
    var isHDR: Bool { self != .sdr }
    static func parse(_ text: String) -> ProjectColor? {
        let key = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        switch key {
        case "sdr", "sdr709", "rec709", "709", "bt709": return .sdr
        case "hlg", "hdrhlg", "hlg2020", "bt2100hlg": return .hlg
        case "pq", "hdrpq", "pq2020", "hdr10", "st2084", "bt2100pq": return .pq
        default: return nil
        }
    }
}
