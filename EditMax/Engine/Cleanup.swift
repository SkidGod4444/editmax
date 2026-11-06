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
    /// Clips are split or trimmed as needed; text overlays inside the range go, later ones move with the content.
    mutating func rippleDelete(start: Double, end: Double) {
        guard end > start else { return }
        let gap = end - start
        for ti in tracks.indices {
            var out: [Clip] = []
            for var c in tracks[ti].clips {
                if c.end <= start { c.trimSound(before: start); out.append(c); continue }            // before: untouched (an L cut's sound stops at the range)
                if c.start >= end { c.trimSound(after: end); c.start -= gap; out.append(c); continue }  // after: shifted (a J cut's sound starts after the range)
                if c.start >= start && c.end <= end { continue }                    // inside: gone
                let original = c   // a J/L cut's sound is cut by the same range (`cutSoundHead/Tail`)
                if c.start < start && c.end > end {                                 // spans: split into two
                    var right = c; right.id = UUID()
                    right.sourceIn = c.sourceIn + (end - c.start) * c.speed
                    right.duration = c.end - end
                    right.start = start
                    c.duration = start - c.start
                    c.cutSoundTail(at: start, from: original); right.cutSoundHead(at: end, from: original)
                    out.append(c); out.append(right); continue
                }
                if c.start < start { c.duration = start - c.start; c.cutSoundTail(at: start, from: original); out.append(c); continue }   // overlaps the start: trimmed
                // overlaps the end: head trimmed, then shifted to where the range began
                let cut = end - c.start
                c.sourceIn += cut * c.speed; c.duration -= cut; c.start = start
                c.cutSoundHead(at: end, from: original)
                out.append(c)
            }
            tracks[ti].clips = out.filter { $0.duration > 0.01 }.sorted { $0.start < $1.start }
        }
        texts = texts.compactMap { t in
            var t = t
            if t.end <= start { return t }
            if t.start >= end { t.start -= gap; return t }
            if t.start >= start && t.end <= end { return nil }
            // partly inside: keep the part outside the range
            if t.start < start { t.duration = start - t.start } else { t.duration = t.end - end; t.start = start }
            return t.duration > 0.05 ? t : nil
        }
    }
}
