import Foundation
import AppKit
import CoreText

/// Which face a text is drawn with. Every place that draws or measures a text asks here: `OverlayLayerBuilder.renderText`
/// (plain titles and captions), `TitleRasterizer` (animated titles, lower-third name and role), `TextLayout` (the box
/// used to keep texts apart) and the FCPXML export, so preview, export, layout and interchange agree.
///
/// A text with no chosen font (`fontName`/`fontFamily` nil, every project made before fonts existed) gets exactly the
/// font it always had: the preset's, and Helvetica Neue Bold / Medium for a lower third. A chosen font that is not on
/// this Mac falls back the same way (the Title card says so; see `FontLibrary.status(of:)`).
///
/// Thread-safe: renderers call it off the main thread. Core Text sees every font `FontLibrary` registered at launch.
enum TextFont {
    /// One face of a family as Core Text knows it.
    struct Face: Equatable, Hashable {
        var postScript: String
        var family: String
        var style: String
        /// Core Text weight, -1…1 (0 regular, 0.23 medium, 0.4 bold).
        var weight: Double
        var italic: Bool
    }

    /// Every face of `family` on this Mac (system, uploaded and downloaded alike), upright before italic, light to heavy.
    static func faces(family: String) -> [Face] {
        let query = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let found = (CTFontDescriptorCreateMatchingFontDescriptors(query, NSSet(object: kCTFontFamilyNameAttribute) as CFSet) as? [CTFontDescriptor]) ?? []
        var seen = Set<String>()
        return found.compactMap(face(of:))
            .filter { $0.family.caseInsensitiveCompare(family) == .orderedSame && seen.insert($0.postScript).inserted }
            .sorted { ($0.italic ? 1 : 0, $0.weight, $0.style) < ($1.italic ? 1 : 0, $1.weight, $1.style) }
    }

    static func face(of d: CTFontDescriptor) -> Face? {
        guard let ps = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String,
              let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String else { return nil }
        let style = CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String ?? "Regular"
        let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
        let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        return Face(postScript: ps, family: family, style: style, weight: weight, italic: symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0)
    }

    static func face(of font: NSFont) -> Face? { face(of: CTFontCopyFontDescriptor(font as CTFont)) }

    /// Whether Core Text has a face by this PostScript name right now. `NSFont(name:)` alone is not enough: it keeps
    /// answering from its cache after a font is unregistered (a removed custom font).
    static func available(_ postScript: String) -> Bool {
        let d = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: postScript] as CFDictionary)
        return CTFontDescriptorCreateMatchingFontDescriptor(d, NSSet(object: kCTFontNameAttribute) as CFSet) != nil
    }

    /// The face by PostScript name, when Core Text has it.
    static func font(_ postScript: String, size: CGFloat) -> NSFont? {
        available(postScript) ? NSFont(name: postScript, size: size) : nil
    }

    /// The Core Text weight of a font by PostScript name (0 when it is not on this Mac).
    static func weight(of postScript: String) -> Double {
        font(postScript, size: 12).flatMap(face(of:))?.weight ?? 0
    }

    /// The upright face of `family` closest in weight to `weight` (an italic only when the family has no upright).
    static func face(family: String, near weight: Double) -> Face? {
        let all = faces(family: family)
        let upright = all.filter { !$0.italic }
        return (upright.isEmpty ? all : upright).min { abs($0.weight - weight) < abs($1.weight - weight) }
    }

    /// The chosen font at `size`, when it is on this Mac: the face by PostScript name, else the family's face nearest
    /// `weight` (a project moved to a Mac that has the family from another source). nil when neither is here.
    static func chosen(name: String?, family: String?, nearWeight weight: Double, size: CGFloat) -> NSFont? {
        if let name, !name.isEmpty, let f = font(name, size: size) { return f }
        guard let family, !family.isEmpty else { return nil }
        // Same style when the PostScript name says it ("Inter-SemiBold" → SemiBold), else the nearest weight.
        if let suffix = name?.split(separator: "-").last.map(String.init), name?.contains("-") == true,
           let same = faces(family: family).first(where: { $0.style.replacingOccurrences(of: " ", with: "").caseInsensitiveCompare(suffix) == .orderedSame }) {
            return font(same.postScript, size: size)
        }
        if let face = face(family: family, near: weight) { return font(face.postScript, size: size) }
        return nil
    }

    /// A lighter upright face of the same family (for a lower third's role line): the heaviest one at least a step
    /// lighter than `font` (bold → medium, semibold → regular). nil when the family has nothing lighter.
    static func lighter(than font: NSFont, size: CGFloat) -> NSFont? {
        guard let me = face(of: font) else { return nil }
        let lighter = faces(family: me.family).filter { $0.italic == me.italic && $0.weight <= me.weight - 0.12 }
        guard let pick = lighter.max(by: { $0.weight < $1.weight }) else { return nil }
        return TextFont.font(pick.postScript, size: size)
    }

    static let lowerThirdName = "HelveticaNeue-Bold"
    static let lowerThirdRole = "HelveticaNeue-Medium"
}

extension TextOverlay {
    /// True when this text names a font of its own.
    var hasChosenFont: Bool { !(fontName ?? "").isEmpty || !(fontFamily ?? "").isEmpty }

    /// The face this text is drawn with at `size`: its chosen font when that is on this Mac, otherwise the preset's
    /// (`style.fontName`), otherwise the bold system font.
    func font(style: CaptionStyle, size: CGFloat) -> NSFont {
        chosenFont(size: size, nearWeightOf: style.fontName)
            ?? NSFont(name: style.fontName, size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }

    /// A lower third's two lines: the name in the chosen font (else Helvetica Neue Bold); the role in a lighter weight of
    /// the same family when it has one (else the same face), or Helvetica Neue Medium without a chosen font.
    func lowerThirdFonts(nameSize: CGFloat, roleSize: CGFloat) -> (name: NSFont, role: NSFont) {
        if let name = chosenFont(size: nameSize, nearWeightOf: TextFont.lowerThirdName) {
            let role = TextFont.lighter(than: name, size: roleSize) ?? NSFont(name: name.fontName, size: roleSize) ?? name
            return (name, role)
        }
        return (NSFont(name: TextFont.lowerThirdName, size: nameSize) ?? .boldSystemFont(ofSize: nameSize),
                NSFont(name: TextFont.lowerThirdRole, size: roleSize) ?? .systemFont(ofSize: roleSize))
    }

    /// The chosen font, or nil when there is none or it is not on this Mac.
    func chosenFont(size: CGFloat, nearWeightOf fallback: String) -> NSFont? {
        guard hasChosenFont else { return nil }
        return TextFont.chosen(name: fontName, family: fontFamily, nearWeight: TextFont.weight(of: fallback), size: size)
    }

    /// The chosen font is set but not on this Mac: the text draws in its preset's font until it is added or downloaded.
    var fontIsMissing: Bool { hasChosenFont && chosenFont(size: 12, nearWeightOf: TextFont.lowerThirdName) == nil }

    /// What the text's font is called in the UI and tool results: the chosen family, or nil for the preset's font.
    var fontDisplayName: String? { hasChosenFont ? (fontFamily ?? fontName) : nil }
}
