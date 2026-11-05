import Foundation

/// Transcript-span editing: find a phrase in what was said and cut it out of the timeline (Descript-style).
/// Words come from `timelineWords`, so their indices match `get_transcript` for the clip, and the asset transcript
/// stays valid after a ripple (the mapping goes through `sourceIn`), so nothing is ever transcribed twice.
extension ToolExecutor {
    struct TranscriptMatch: Codable {
        var occurrence: Int            // 1-based, counted across clips in timeline order
        var clip: String, clipName: String
        var fromWord: Int, toWord: Int // 0-based indices into get_transcript's words for that clip
        var start: Double, end: Double // timeline seconds
        var text: String               // the words as spoken
        var context: String            // a few words either side, the match in brackets
    }

    /// The clips a transcript search covers: one clip, every clip of one asset, or every captionable clip.
    private func transcriptClips(clip: String?, asset: String?) throws -> [Clip] {
        if let clip, !clip.isEmpty { let id = try resolveClip(clip); return [document.project.clip(id)!.clip] }
        var clips = captionableClips()
        if let asset, !asset.isEmpty { let aid = try resolveAsset(asset); clips = clips.filter { $0.assetID == aid } }
        guard !clips.isEmpty else { throw EditError.invalid("No clip with audio on the timeline") }
        return clips
    }

    private func context(_ words: [TranscriptWord], from: Int, to: Int) -> String {
        let before = words[max(0, from - 3)..<from].map(\.text).joined(separator: " ")
        let hit = words[from...to].map(\.text).joined(separator: " ")
        let after = words[(to + 1)..<min(words.count, to + 4)].map(\.text).joined(separator: " ")
        return [before, "[\(hit)]", after].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Case- and punctuation-insensitive phrase search over the spoken words, one clip at a time.
    func searchTranscript(clip: String?, asset: String?, query: String, language: String?) async throws -> [TranscriptMatch] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { FillerWords.normalize(String($0)) }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw EditError.invalid("'query' needs at least one word") }
        var out: [TranscriptMatch] = []
        for c in try transcriptClips(clip: clip, asset: asset) {
            let t = try await ensureTranscript(assetID: c.assetID, language: language)
            let words = timelineWords(t, clip: c)
            let norm = words.map { FillerWords.normalize($0.text) }
            guard words.count >= tokens.count else { continue }
            var i = 0
            while i + tokens.count <= words.count {
                if Array(norm[i..<(i + tokens.count)]) == tokens {
                    let j = i + tokens.count - 1
                    out.append(TranscriptMatch(occurrence: out.count + 1, clip: c.id.short, clipName: c.name, fromWord: i, toWord: j,
                                               start: round3(words[i].start), end: round3(words[j].end),
                                               text: words[i...j].map(\.text).joined(separator: " "), context: context(words, from: i, to: j)))
                    i = j + 1   // matches do not overlap
                } else { i += 1 }
            }
        }
        return out
    }

    /// Cuts a span of speech out of the timeline (ripple across every track). The span is chosen by phrase, by word
    /// indices into one clip's transcript, or by a timeline time range; the cut covers the words' own time, padded by
    /// `padding` but never into a neighbouring word.
    func cutTranscript(clip: String?, asset: String?, phrase: String?, occurrence: Int?, fromWord: Int?, toWord: Int?,
                       startTime: Double?, endTime: Double?, padding: Double, language: String?) async throws -> CleanupResult {
        let chosen: Clip
        let words: [TranscriptWord]
        let from: Int, to: Int
        if let phrase, !phrase.isEmpty {
            let matches = try await searchTranscript(clip: clip, asset: asset, query: phrase, language: language)
            guard !matches.isEmpty else { throw EditError.notFound("'\(phrase)' in the transcript") }
            let m: TranscriptMatch
            if let occurrence {
                guard matches.indices.contains(occurrence - 1) else { throw EditError.invalid("'\(phrase)' occurs \(matches.count) time\(matches.count == 1 ? "" : "s"); occurrence must be 1 to \(matches.count)") }
                m = matches[occurrence - 1]
            } else if matches.count == 1 {
                m = matches[0]
            } else {
                let lines = matches.prefix(10).map { "\($0.occurrence): \(round3($0.start))s in clip \($0.clip) — \($0.context)" }
                throw EditError.invalid("'\(phrase)' occurs \(matches.count) times; say which occurrence:\n" + lines.joined(separator: "\n") + (matches.count > 10 ? "\n…" : ""))
            }
            chosen = document.project.clip(try resolveClip(m.clip))!.clip
            words = timelineWords(try await ensureTranscript(assetID: chosen.assetID, language: language), clip: chosen)
            from = m.fromWord; to = m.toWord
        } else if let fromWord {
            let clips = try transcriptClips(clip: clip, asset: asset)
            guard clips.count == 1 else { throw EditError.invalid("from_word needs one clip; say which (\(clips.map(\.id.short).joined(separator: ", ")))") }
            chosen = clips[0]
            words = timelineWords(try await ensureTranscript(assetID: chosen.assetID, language: language), clip: chosen)
            from = fromWord; to = toWord ?? fromWord
            guard words.indices.contains(from), words.indices.contains(to), from <= to else {
                throw EditError.invalid("word indices must be 0 to \(words.count - 1) with from_word <= to_word")
            }
        } else if let startTime, let endTime {
            guard endTime > startTime else { throw EditError.invalid("end must be after start") }
            // A word belongs to the range when its middle lies inside it, so a range drawn roughly still takes whole words.
            var hit: (Clip, [TranscriptWord], Int, Int)? = nil
            for c in try transcriptClips(clip: clip, asset: asset) where c.start < endTime && c.end > startTime {
                let ws = timelineWords(try await ensureTranscript(assetID: c.assetID, language: language), clip: c)
                let inside = ws.indices.filter { let mid = (ws[$0].start + ws[$0].end) / 2; return mid >= startTime && mid <= endTime }
                if let a = inside.first, let b = inside.last {
                    guard hit == nil else { throw EditError.invalid("\(round3(startTime))s–\(round3(endTime))s spans words in more than one clip; cut one clip at a time or use ripple_delete") }
                    hit = (c, ws, a, b)
                }
            }
            guard let hit else { throw EditError.notFound("spoken words between \(round3(startTime))s and \(round3(endTime))s") }
            chosen = hit.0; words = hit.1; from = hit.2; to = hit.3
        } else {
            throw EditError.invalid("Say what to cut: a phrase, from_word/to_word, or start/end")
        }
        // Pad into the silence around the words, but stop at the neighbours (and the clip's edges) so no other word is clipped.
        let lo = from > 0 ? words[from - 1].end : chosen.start
        let hi = to + 1 < words.count ? words[to + 1].start : chosen.end
        let start = max(0, max(lo, words[from].start - max(0, padding)))
        let end = min(hi, words[to].end + max(0, padding))
        guard end > start + 0.01 else { throw EditError.invalid("The span is too short to cut") }
        let text = words[from...to].map(\.text).joined(separator: " ")
        let short = text.count > 40 ? String(text.prefix(37)) + "…" : text
        var result = rippleDelete([RangeInfo(start: round3(start), end: round3(end), duration: round3(end - start))], label: "Cut \"\(short)\"")
        result.words = words[from...to].map(\.text)
        return result
    }
}

private func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
