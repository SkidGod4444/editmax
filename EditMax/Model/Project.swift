import Foundation

// MARK: - Core model. Plain Codable values; all times are seconds.

struct ProjectSettings: Codable, Equatable {
    var width: Int = 1920
    var height: Int = 1080
    var fps: Double = 30
}

enum AssetKind: String, Codable { case video, audio, image }

struct Asset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var path: String                // absolute path on disk
    var bookmark: Data? = nil       // security-scoped bookmark for sandbox-free reopen
    var kind: AssetKind
    var duration: Double            // seconds; images use 5s default
    var width: Int? = nil
    var height: Int? = nil
    var url: URL { URL(fileURLWithPath: path) }
}

enum TrackKind: String, Codable { case video, audio }

struct Clip: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var assetID: UUID
    var name: String
    var start: Double          // position on timeline
    var duration: Double       // timeline duration (= source length / speed)
    var sourceIn: Double = 0   // offset into the asset
    var speed: Double = 1
    var volume: Double = 1
    var opacity: Double = 1
    var end: Double { start + duration }
    var sourceOut: Double { sourceIn + duration * speed }
}

struct Track: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var kind: TrackKind
    var clips: [Clip] = []
    var isMuted = false
    var isHidden = false
}

struct TextOverlay: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var start: Double
    var duration: Double
    var fontSize: Double = 64
    var colorHex: String = "#FFFFFF"
    var x: Double = 0.5     // normalized center
    var y: Double = 0.85
    var preset: String? = nil   // CaptionPresets name; nil = "title"
    var group: UUID? = nil      // set on captions made in one go, so they can be removed together
    var end: Double { start + duration }
    var isCaption: Bool { group != nil }
}

/// One recognized word of an asset's audio, in asset seconds.
struct TranscriptWord: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// Speech recognized in an asset, cached on the project so captions and searches do not transcribe twice.
struct Transcript: Codable, Equatable {
    var locale: String
    var words: [TranscriptWord]
    var createdAt: Date = Date()
    var text: String { words.map(\.text).joined(separator: " ") }
}

enum EditOrigin: String, Codable { case user, agent, system }

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String
    var origin: EditOrigin
    var createdAt: Date = Date()
    var project: Data        // encoded Project without history
}

struct Project: Codable, Equatable {
    var name: String = "Untitled"
    var settings = ProjectSettings()
    var assets: [Asset] = []
    var tracks: [Track] = [Track(name: "V1", kind: .video), Track(name: "A1", kind: .audio)]
    /// Row of the Text lane in the timeline (0 = top); nil = below the tracks. Display only: text always draws over the picture.
    var textLaneRow: Int? = nil
    var texts: [TextOverlay] = []
    var transcripts: [String: Transcript]? = nil   // keyed by asset id; a cache, left out of history snapshots
    var history: [HistoryEntry] = []

    var duration: Double {
        let clipEnd = tracks.flatMap(\.clips).map(\.end).max() ?? 0
        let textEnd = texts.map(\.end).max() ?? 0
        return max(clipEnd, textEnd)
    }

    func asset(_ id: UUID) -> Asset? { assets.first { $0.id == id } }
    func track(_ id: UUID) -> Track? { tracks.first { $0.id == id } }
    func clip(_ id: UUID) -> (track: Track, clip: Clip)? {
        for t in tracks { if let c = t.clips.first(where: { $0.id == id }) { return (t, c) } }
        return nil
    }
    var allClips: [Clip] { tracks.flatMap(\.clips) }

    /// Copy of this project with history (and the transcript cache) stripped, for snapshots and resource reads.
    var withoutHistory: Project { var p = self; p.history = []; p.transcripts = nil; return p }
    func transcript(for assetID: UUID) -> Transcript? { transcripts?[assetID.uuidString] }
}

enum EditError: LocalizedError {
    case notFound(String), invalid(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let s): return "Not found: \(s)"
        case .invalid(let s): return "Invalid: \(s)"
        }
    }
}

// MARK: - Timeline operations (pure mutations on Project)

extension Project {
    private func trackIndex(_ id: UUID) throws -> Int {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("track \(id)") }
        return i
    }
    private func clipIndex(_ id: UUID) throws -> (Int, Int) {
        for (ti, t) in tracks.enumerated() {
            if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        throw EditError.notFound("clip \(id)")
    }

    /// Resolve a user/agent supplied prefix or full UUID against a list of ids.
    static func resolve(_ text: String, in ids: [UUID]) -> UUID? {
        let needle = text.lowercased()
        if let full = UUID(uuidString: text) { return ids.contains(full) ? full : nil }
        let matches = ids.filter { $0.uuidString.lowercased().hasPrefix(needle) }
        return matches.count == 1 ? matches[0] : nil
    }

    func firstTrack(of kind: TrackKind) -> Track? { tracks.first { $0.kind == kind } }

    /// End of the last clip on a track (0 if empty).
    func trackEnd(_ trackID: UUID) -> Double { track(trackID)?.clips.map(\.end).max() ?? 0 }

    /// Timeline rows top to bottom: tracks with the Text lane at `textLaneRow`.
    enum Row: Identifiable, Equatable {
        case track(Track), text
        var id: UUID { if case .track(let t) = self { return t.id }; return Project.textRowID }
    }
    static let textRowID = UUID(uuidString: "00000000-0000-0000-0000-00000000007E")!
    var rows: [Row] {
        var r = tracks.map(Row.track)
        r.insert(.text, at: min(textLaneRow ?? tracks.count, tracks.count))
        return r
    }

    /// Moves a row (a track or the Text lane) to another row. Returns false when nothing changed.
    @discardableResult
    mutating func moveRow(_ id: UUID, toRow index: Int) -> Bool {
        var r = rows
        guard let from = r.firstIndex(where: { $0.id == id }) else { return false }
        let to = max(0, min(r.count - 1, index))
        guard from != to else { return false }
        let row = r.remove(at: from)
        r.insert(row, at: to)
        tracks = r.compactMap { if case .track(let t) = $0 { return t }; return nil }
        textLaneRow = r.firstIndex(of: .text)
        return true
    }

    /// Moves a track to another row. The top row covers the rows below it in the picture. Returns false when nothing changed.
    @discardableResult
    mutating func moveTrack(_ id: UUID, toIndex index: Int) -> Bool {
        guard let from = tracks.firstIndex(where: { $0.id == id }) else { return false }
        let to = max(0, min(tracks.count - 1, index))
        guard from != to else { return false }
        let t = tracks.remove(at: from)
        tracks.insert(t, at: to)
        return true
    }

    mutating func addTrack(name: String? = nil, kind: TrackKind) -> Track {
        let n = tracks.filter { $0.kind == kind }.count + 1
        let t = Track(name: name ?? "\(kind == .video ? "V" : "A")\(n)", kind: kind)
        tracks.append(t)
        return t
    }

    /// Insert a clip for `assetID`. `at == nil` appends after the last clip on the track.
    @discardableResult
    mutating func insertClip(assetID: UUID, trackID: UUID? = nil, at: Double? = nil,
                             sourceIn: Double = 0, duration: Double? = nil) throws -> Clip {
        guard let asset = asset(assetID) else { throw EditError.notFound("asset \(assetID)") }
        let kind: TrackKind = asset.kind == .audio ? .audio : .video
        let tid = trackID ?? firstTrack(of: kind)?.id ?? addTrack(kind: kind).id
        let ti = try trackIndex(tid)
        let maxDur = max(0.01, asset.duration - sourceIn)
        let dur = min(duration ?? maxDur, maxDur)
        guard dur > 0 else { throw EditError.invalid("duration must be > 0") }
        let start = at ?? trackEnd(tid)
        let clip = Clip(assetID: assetID, name: asset.name, start: max(0, start), duration: dur, sourceIn: sourceIn)
        tracks[ti].clips.append(clip)
        tracks[ti].clips.sort { $0.start < $1.start }
        return clip
    }

    /// Split a clip at an absolute timeline time. Returns (left, right).
    @discardableResult
    mutating func splitClip(_ id: UUID, at time: Double) throws -> (Clip, Clip) {
        let (ti, ci) = try clipIndex(id)
        var left = tracks[ti].clips[ci]
        guard time > left.start + 0.01, time < left.end - 0.01 else {
            throw EditError.invalid("split time \(time) is outside clip \(left.start)...\(left.end)")
        }
        var right = left
        right.id = UUID()
        let leftDur = time - left.start
        left.duration = leftDur
        right.start = time
        right.duration = right.duration - leftDur
        right.sourceIn = left.sourceIn + leftDur * left.speed
        tracks[ti].clips[ci] = left
        tracks[ti].clips.insert(right, at: ci + 1)
        return (left, right)
    }

    mutating func moveClip(_ id: UUID, to start: Double, trackID: UUID? = nil) throws {
        let (ti, ci) = try clipIndex(id)
        var clip = tracks[ti].clips.remove(at: ci)
        clip.start = max(0, start)
        let target = try trackID.map(trackIndex) ?? ti
        guard tracks[target].kind == tracks[ti].kind else { throw EditError.invalid("track kind mismatch") }
        tracks[target].clips.append(clip)
        tracks[target].clips.sort { $0.start < $1.start }
    }

    /// Trim by setting new timeline in/out points (absolute seconds). Either may be nil.
    mutating func trimClip(_ id: UUID, newStart: Double?, newEnd: Double?) throws {
        let (ti, ci) = try clipIndex(id)
        var c = tracks[ti].clips[ci]
        let s = newStart ?? c.start
        let e = newEnd ?? c.end
        guard e - s > 0.01 else { throw EditError.invalid("trim would leave an empty clip") }
        let delta = s - c.start
        guard c.sourceIn + delta * c.speed >= 0 else { throw EditError.invalid("cannot trim before source start") }
        c.sourceIn += delta * c.speed
        c.start = s
        c.duration = e - s
        tracks[ti].clips[ci] = c
    }

    mutating func removeClips(_ ids: [UUID]) -> Int {
        var removed = 0
        for ti in tracks.indices {
            let before = tracks[ti].clips.count
            tracks[ti].clips.removeAll { ids.contains($0.id) }
            removed += before - tracks[ti].clips.count
        }
        return removed
    }

    mutating func updateClip(_ id: UUID, _ body: (inout Clip) -> Void) throws {
        let (ti, ci) = try clipIndex(id)
        body(&tracks[ti].clips[ci])
    }

    /// Close gaps on a track so clips play back to back.
    mutating func ripple(trackID: UUID) throws {
        let ti = try trackIndex(trackID)
        var cursor = 0.0
        for ci in tracks[ti].clips.indices {
            tracks[ti].clips[ci].start = cursor
            cursor += tracks[ti].clips[ci].duration
        }
    }

    @discardableResult
    mutating func addText(_ text: String, start: Double, duration: Double,
                          fontSize: Double = 64, colorHex: String = "#FFFFFF", x: Double = 0.5, y: Double = 0.85) -> TextOverlay {
        let t = TextOverlay(text: text, start: start, duration: duration, fontSize: fontSize, colorHex: colorHex, x: x, y: y)
        texts.append(t)
        return t
    }

    mutating func removeTexts(_ ids: [UUID]) -> Int {
        let before = texts.count
        texts.removeAll { ids.contains($0.id) }
        return before - texts.count
    }
    /// Remove the captions of one group, or every caption when `group` is nil.
    mutating func removeCaptions(group: UUID?) -> Int {
        let before = texts.count
        texts.removeAll { $0.group != nil && (group == nil || $0.group == group) }
        return before - texts.count
    }
}

// MARK: - Short IDs for humans and agents

extension UUID {
    /// First 8 hex chars; `Project.resolve` accepts these as prefixes.
    var short: String { String(uuidString.lowercased().prefix(8)) }
}
