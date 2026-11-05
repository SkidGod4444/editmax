import Foundation

/// A named look for text overlays. Titles and captions share one renderer (`OverlayLayerBuilder.renderText`); the preset
/// decides font, case, stroke, background box and default size and position. `maxChars`/`maxWords` shape caption lines.
struct CaptionStyle: Equatable {
    var name: String
    var title: String
    var fontName: String
    var fontSize: Double
    var color: String
    var uppercase = false
    var shadow = true
    var strokeWidth: Double = 0          // percent of font size; 0 = none
    var strokeColor = "#000000"
    var box: (color: String, alpha: Double, padding: Double, radius: Double)? = nil
    var y: Double
    var maxChars: Int
    var maxWords: Int

    static func == (a: CaptionStyle, b: CaptionStyle) -> Bool { a.name == b.name }
}

enum CaptionPresets {
    static let title = CaptionStyle(name: "title", title: "Title", fontName: "HelveticaNeue-Bold", fontSize: 64, color: "#FFFFFF", y: 0.85, maxChars: 40, maxWords: 8)
    static let all: [CaptionStyle] = [
        title,
        CaptionStyle(name: "subtitle", title: "Subtitle", fontName: "HelveticaNeue-Medium", fontSize: 40, color: "#FFFFFF", shadow: false,
                     box: ("#000000", 0.6, 14, 8), y: 0.9, maxChars: 42, maxWords: 9),
        CaptionStyle(name: "boxed", title: "Boxed", fontName: "HelveticaNeue-Bold", fontSize: 44, color: "#FFFFFF", shadow: false,
                     box: ("#000000", 1, 16, 4), y: 0.88, maxChars: 32, maxWords: 7),
        CaptionStyle(name: "bold", title: "Bold", fontName: "HelveticaNeue-CondensedBlack", fontSize: 72, color: "#FFD60A", uppercase: true,
                     strokeWidth: 6, y: 0.78, maxChars: 22, maxWords: 4),
        CaptionStyle(name: "outline", title: "Outline", fontName: "HelveticaNeue-Bold", fontSize: 50, color: "#FFFFFF", shadow: false,
                     strokeWidth: 5, y: 0.88, maxChars: 34, maxWords: 7),
        CaptionStyle(name: "minimal", title: "Minimal", fontName: "HelveticaNeue", fontSize: 32, color: "#FFFFFF", y: 0.92, maxChars: 48, maxWords: 10),
    ]
    static let names = all.map(\.name)
    static func style(_ name: String?) -> CaptionStyle { all.first { $0.name == name } ?? title }
    static func resolve(_ name: String?) throws -> CaptionStyle {
        guard let name, !name.isEmpty else { return style("subtitle") }
        guard let s = all.first(where: { $0.name == name.lowercased() }) else { throw EditError.invalid("Unknown caption preset '\(name)'. Presets: \(names.joined(separator: ", "))") }
        return s
    }
}

enum Captioner {
    struct Segment: Equatable { var text: String; var start: Double; var end: Double }

    /// Groups timed words into caption lines: a new line starts when the limits are hit, after a long pause, or after a
    /// sentence ends. Each line shows from its first word to just after its last, never overlapping the next line.
    static func segments(_ words: [TranscriptWord], maxChars: Int, maxWords: Int, maxGap: Double = 0.8, maxDuration: Double = 4.5) -> [Segment] {
        var out: [Segment] = []
        var current: [TranscriptWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(Segment(text: current.map(\.text).joined(separator: " "), start: first.start, end: last.end))
            current = []
        }
        for w in words.sorted(by: { $0.start < $1.start }) {
            if let last = current.last {
                let chars = current.reduce(0) { $0 + $1.text.count } + current.count
                let endsSentence = { (t: String) in t.last.map { ".?!।".contains($0) } ?? false }
                // A word that closes a sentence may run a little past the limits so the full stop stays on its line.
                let limit = endsSentence(w.text) ? maxChars + maxChars / 5 : maxChars
                if current.count >= maxWords || chars + w.text.count > limit || w.start - last.end > maxGap
                    || w.end - current[0].start > maxDuration || endsSentence(last.text) { flush() }
            }
            current.append(w)
        }
        flush()
        for i in out.indices {
            var end = max(out[i].end + 0.15, out[i].start + 0.5)
            if i + 1 < out.count { end = min(end, max(out[i].start + 0.3, out[i + 1].start - 0.02)) }
            out[i].end = end
        }
        return out
    }
}
