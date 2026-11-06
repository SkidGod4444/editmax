import Foundation
import AppKit

// Text fonts and style edits, shared by the Title inspector and the MCP tools (`set_text_style`, `add_text font:`,
// `list_fonts`). Fonts themselves are found, downloaded and added by `FontLibrary`.

extension ToolExecutor {
    /// A resolved font argument (`FontLibrary.resolve`): back to the preset's font, or a family on this Mac with an
    /// optional exact face (PostScript name). Without a face the family's face nearest the preset's weight is used.
    enum FontChoice: Equatable {
        case preset
        case family(String, face: String?)
    }

    struct TextStyleResult: Codable {
        var text: String
        var content: String
        /// The chosen family, absent for the preset's font.
        var font: String?
        /// The face (PostScript name).
        var face: String?
        var fontSize: Double
        var color: String
        var note: String?
    }

    /// The face a choice lands on for a text with this preset: the exact one asked for, else the family's face nearest
    /// the preset's weight (Title → bold, Minimal → regular).
    func face(for choice: FontChoice, preset: String?) throws -> (name: String?, family: String?) {
        switch choice {
        case .preset: return (nil, nil)
        case .family(let family, let face):
            if let face, let f = TextFont.font(face, size: 12), let found = TextFont.face(of: f) { return (found.postScript, found.family) }
            let weight = TextFont.weight(of: CaptionPresets.style(preset).fontName)
            guard let found = TextFont.face(family: family, near: weight) else { throw EditError.invalid("the font \(family) is not on this Mac") }
            return (found.postScript, found.family)
        }
    }

    fileprivate func text(_ s: String) throws -> TextOverlay {
        let p = document.project
        if let id = Project.resolve(s, in: p.texts.map(\.id)), let t = p.texts.first(where: { $0.id == id }) { return t }
        throw EditError.notFound("text '\(s)' (use the id inspect_timeline lists)")
    }

    /// Font, size and color of one text, as one edit (one undo step). `font` comes from `FontLibrary.resolve`.
    @discardableResult
    func setTextStyle(_ text: String, font: FontChoice?, fontSize: Double?, color: String?) throws -> TextStyleResult {
        let t = try self.text(text)
        guard font != nil || fontSize != nil || color != nil else { throw EditError.invalid("give at least one of font, font_size, color") }
        if let fontSize, !(8...500).contains(fontSize) { throw EditError.invalid("font_size must be 8 to 500 (got \(fontSize))") }
        var hex: String?
        if let color {
            guard let (r, g, b) = Keyer.rgb(color) else { throw EditError.invalid("color must be a hex colour like #FFFFFF (got \(color))") }
            hex = Keyer.hex(r, g, b)
        }
        let chosen = try font.map { try face(for: $0, preset: t.preset) }
        let label = font != nil && fontSize == nil && color == nil ? "Text font" : "Text style"
        try document.apply(label, origin: origin, coalesce: coalesce) { p in
            guard let i = p.texts.firstIndex(where: { $0.id == t.id }) else { throw EditError.notFound("text \(t.id.short)") }
            if let chosen { p.texts[i].fontName = chosen.name; p.texts[i].fontFamily = chosen.family }
            if let fontSize { p.texts[i].fontSize = fontSize }
            if let hex { p.texts[i].colorHex = hex }
        }
        if let family = chosen?.family { FontLibrary.shared.noteUsed(family) }
        let final = document.project.texts.first { $0.id == t.id } ?? t
        var note: String?
        let blockers = TextLayout.blockers(of: final, among: document.project.texts, canvas: document.project.settings.canvas)
        if !blockers.isEmpty { note = "it now overlaps \(blockers.map { "'\($0.text.prefix(20))'" }.joined(separator: ", ")) on screen; move it with the Position card or a smaller font_size" }
        return TextStyleResult(text: final.id.short, content: String(final.text.prefix(40)), font: final.fontFamily, face: final.fontName,
                               fontSize: final.fontSize, color: final.colorHex, note: note)
    }

    // MARK: list_fonts

    struct FontInfo: Codable {
        var family: String
        var source: String
        var category: String?
        var installed: Bool
        /// Faces on this Mac (PostScript names), for installed families; at most 24.
        var faces: [String]?
        /// Styles Google offers ("400", "700i"…), for Google families.
        var styles: [String]?
        var popularity: Int?
        var trending: Int?
        var added: String?
    }

    struct FontList: Codable {
        /// ready, cached (offline, from the last fetch), or unavailable (only fonts on this Mac are listed).
        var catalog: String
        var total: Int
        var fonts: [FontInfo]
        var note: String?
    }

    static func fontList(search: String?, category: String?, sort: String?, source: String?, limit: Int?) async throws -> FontList {
        let lib = FontLibrary.shared
        let cat: FontLibrary.Category?
        if let category, !category.isEmpty {
            guard let c = FontLibrary.Category.parse(category) else { throw EditError.invalid("category must be sans-serif, serif, display, handwriting or monospace (got \(category))") }
            cat = c
        } else { cat = nil }
        let order: FontLibrary.Sort
        if let sort, !sort.isEmpty {
            guard let s = FontLibrary.Sort.parse(sort) else { throw EditError.invalid("sort must be trending, popular, newest or name (got \(sort))") }
            order = s
        } else { order = .trending }
        var sources = Set(FontLibrary.Source.allCases), installedOnly = false
        switch source?.lowercased() {
        case nil, "", "all": break
        case "installed": installedOnly = true
        case "google": sources = [.google]
        case "custom", "uploaded", "mine": sources = [.custom]
        case "system": sources = [.system]
        default: throw EditError.invalid("source must be installed, google, custom or system (got \(source!))")
        }
        let n = limit ?? 50
        guard (1...500).contains(n) else { throw EditError.invalid("limit must be 1 to 500 (got \(n))") }
        if sources.contains(.google) { await lib.refreshCatalog() }
        let all = lib.families(search: search ?? "", category: cat, sort: order, sources: sources, installedOnly: installedOnly)
        let fonts = all.prefix(n).map { f -> FontInfo in
            let faces = f.installed ? Array(TextFont.faces(family: f.name).map(\.postScript).prefix(24)) : nil
            return FontInfo(family: f.name, source: f.source.rawValue, category: (f.source == .google ? f.category : lib.inferredCategory(f.name))?.rawValue,
                            installed: f.installed, faces: faces, styles: f.google?.styles, popularity: f.google?.popularity, trending: f.google?.trending, added: f.google?.dateAdded)
        }
        let state: String
        switch lib.catalogState { case .ready: state = "ready"; case .stale: state = "cached"; case .loading, .unavailable: state = lib.catalog.isEmpty ? "unavailable" : "cached" }
        var note: String?
        if order == .trending { note = "trending is Google's own trending rank; it favours families whose use is growing fast, often recent additions" }
        if state == "unavailable", sources.contains(.google) { note = "the Google Fonts list could not be loaded (offline?); only fonts on this Mac are listed" }
        return FontList(catalog: state, total: all.count, fonts: fonts, note: note)
    }
}
