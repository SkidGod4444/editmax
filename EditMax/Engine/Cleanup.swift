import Foundation

/// Finds quiet stretches in the waveform peaks (100 per second, 0...1 after normalization).
enum SilenceDetector {
    /// Silent ranges in source seconds within [from, to): runs below `thresholdDb` (relative to the loudest peak) lasting at
    /// least `minDuration`, shrunk by `padding` on each side so the cut does not clip the speech around it.
    static func ranges(peaks: [Float], from: Double, to: Double, thresholdDb: Double, minDuration: Double, padding: Double) -> [(start: Double, end: Double)] {
        guard !peaks.isEmpty, to > from else { return [] }
        let pps = Double(WaveformStore.peaksPerSecond)
        let threshold = Float(pow(10, thresholdDb / 20))
        let i0 = max(0, Int(from * pps)), i1 = min(peaks.count, Int(to * pps))
        guard i1 > i0 else { return [] }
        var out: [(Double, Double)] = []
        var runStart: Int? = nil
        for i in i0...i1 {
            let quiet = i < i1 && peaks[i] < threshold
            if quiet { if runStart == nil { runStart = i } }
            else if let s = runStart {
                let a = Double(s) / pps + padding, b = Double(i) / pps - padding
                if b - a >= minDuration { out.append((max(from, a), min(to, b))) }
                runStart = nil
            }
        }
        return out
    }
}

enum FillerWords {
    static let defaults: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "hmm", "hm", "mm", "mmm", "er", "erm", "ah", "eh", "ehm"]
    static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}

extension Project {
    /// Ripple delete: removes [start, end) from every track and shifts everything after it left, so tracks stay in sync.
    /// A clip the range cuts is cut exactly as a split at each edge would cut it (`Clip.split`: media, speed ramps,
    /// keyframes, multicam cuts, J/L sound), so a clip spanning the range becomes two pieces with no fade or transition at
    /// the new cut, as a plain split leaves them; a clip that only loses its head or tail keeps the fade and transition at
    /// the edge it still has, as a trim does. Texts and markers move with the picture: a text spanning the range keeps the
    /// part on each side, a marker inside it lands on the cut.
    mutating func rippleDelete(start: Double, end: Double) {
        guard end > start else { return }
        let gap = end - start
        for ti in tracks.indices {
            var out: [Clip] = []
            for var c in tracks[ti].clips {
                if c.end <= start { c.trimSound(before: start); out.append(c); continue }            // before: untouched (an L cut's sound stops at the range)
                if c.start >= end { c.trimSound(after: end); c.start -= gap; out.append(c); continue }  // after: shifted (a J cut's sound starts after the range)
                if c.start >= start && c.end <= end { continue }                    // inside: gone
                if c.start < start && c.end > end {                                 // spans: two splits, the middle taken out
                    let (left, rest) = c.split(atLocal: start - c.start)
                    var (_, right) = rest.split(atLocal: end - rest.start)
                    right.start = start
                    out.append(left); out.append(right); continue
                }
                if c.start < start {                                                // overlaps the start: its tail is trimmed
                    var (left, _) = c.split(atLocal: start - c.start)
                    left.fadeOut = min(c.fadeOut, left.duration)
                    out.append(left); continue
                }
                // overlaps the end: its head is trimmed, then it moves to where the range began
                var (_, right) = c.split(atLocal: end - c.start)
                right.id = c.id
                right.fadeIn = min(c.fadeIn, right.duration); right.transitionIn = c.transitionIn; right.audioCrossfade = c.audioCrossfade
                right.start = start
                out.append(right)
            }
            tracks[ti].clips = out.filter { $0.duration > 0.01 }.sorted { $0.start < $1.start }
        }
        texts = texts.compactMap { t in
            var t = t
            if t.end <= start { return t }
            if t.start >= end { t.start -= gap; return t }
            if t.start >= start && t.end <= end { return nil }
            if t.start < start && t.end > end { t.duration -= gap; return t }   // spans: the part after the range moves up to it
            // partly inside: keep the part outside the range
            if t.start < start { t.duration = start - t.start } else { t.duration = t.end - end; t.start = start }
            return t.duration > 0.05 ? t : nil
        }
        for i in markers.indices where markers[i].time > start {
            markers[i].time = markers[i].time >= end ? markers[i].time - gap : start
        }
    }
}
