import Foundation
import AVFoundation
import CoreMedia

/// Hands the cut to another editor. FCPXML 1.10 (DaVinci Resolve, Final Cut Pro) carries every track; a CMX 3600 EDL
/// carries the picture of the bottom video track, for a conform. Both are edit lists: they point at the original media
/// files and carry the edit (order, trims, gaps, dissolves, speed, volume and fades), not EditMax's processing (grades,
/// LUTs, EQ, voice isolation, ducking, stabilization, keyframes). `report` says, for the project at hand, exactly what
/// went over and what did not, so the result never promises more than the file holds.
///
/// Layout in FCPXML: the bottom video track is the primary storyline (gaps fill the holes, a transition sits before each
/// clip that dissolves in); every other track is a connected storyline anchored at 0 on the first primary element:
/// video tracks above it on lanes 1, 2… (the top row highest), titles above those, audio tracks on lanes −1, −2….
/// Every time is a whole number of frames at the project rate, written as a fraction ("1001/30000s").
enum Interchange {
    enum Format: String, CaseIterable, Codable {
        case fcpxml, edl
        var fileExtension: String { rawValue }
        var title: String {
            switch self {
            case .fcpxml: return "Final Cut Pro XML (DaVinci Resolve, Final Cut Pro)"
            case .edl: return "EDL, CMX 3600 (picture conform)"
            }
        }
        /// "fcpxml", "xml", "fcp", "resolve" → fcpxml; "edl", "cmx" → edl; nothing → fcpxml.
        static func parse(_ text: String?) throws -> Format {
            let w = (text ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
            if w.isEmpty || ["fcpxml", "xml", "fcp", "finalcut", "finalcutpro", "resolve", "davinci", "davinciresolve"].contains(w) { return .fcpxml }
            if w.hasPrefix("edl") || w.hasPrefix("cmx") { return .edl }
            throw EditError.invalid("Unknown timeline format '\(text ?? "")'. Formats: fcpxml, edl")
        }
    }

    struct Result: Codable {
        var format: String
        var path: String
        /// Files written beside it: the captions as `<name>.srt` (FCPXML only, when the project has captions).
        var sidecars: [String]
        var clips: Int
        var transferred: [String]
        var notTransferred: [String]
    }

    // MARK: Time

    /// A time in seconds as a fraction, the way FCPXML writes it.
    struct Rational: Equatable, Comparable {
        private(set) var n: Int64
        private(set) var d: Int64
        init(_ n: Int64, _ d: Int64) {
            let g = Rational.gcd(Swift.abs(n), Swift.abs(d))
            let s: Int64 = d < 0 ? -1 : 1
            self.n = g > 0 ? s * n / g : n
            self.d = g > 0 ? s * d / g : max(1, d)
        }
        static let zero = Rational(0, 1)
        var seconds: Double { Double(n) / Double(d) }
        var fcp: String { n == 0 ? "0s" : d == 1 ? "\(n)s" : "\(n)/\(d)s" }
        static func + (a: Rational, b: Rational) -> Rational { let l = lcm(a.d, b.d); return Rational(a.n * (l / a.d) + b.n * (l / b.d), l) }
        static func - (a: Rational, b: Rational) -> Rational { a + Rational(-b.n, b.d) }
        static func * (a: Rational, k: Int64) -> Rational { Rational(a.n * k, a.d) }
        static func < (a: Rational, b: Rational) -> Bool { (a - b).n < 0 }
        static func gcd(_ a: Int64, _ b: Int64) -> Int64 { var a = a, b = b; while b != 0 { (a, b) = (b, a % b) }; return a }
        static func lcm(_ a: Int64, _ b: Int64) -> Int64 { a / max(1, gcd(a, b)) * b }
    }

    /// One frame's duration, exact for the NTSC rates (29.97 fps = 1001/30000 s a frame).
    struct FrameRate: Equatable {
        let frame: Rational
        init(fps: Double) {
            let ntsc: [(Double, Int64)] = [(23.976, 24000), (29.97, 30000), (47.952, 48000), (59.94, 60000), (119.88, 120000)]
            if let m = ntsc.first(where: { Swift.abs(fps - $0.0) < 0.01 }) { frame = Rational(1001, m.1) }
            else { frame = Rational(1, Int64(max(1, fps.rounded()))) }
        }
        var fps: Double { 1 / frame.seconds }
        /// Frames per second on a timecode clock (30 for 29.97).
        var timebase: Int64 { Int64(fps.rounded()) }
        func frames(_ seconds: Double) -> Int64 { Int64((seconds / frame.seconds).rounded()) }
        func time(_ frames: Int64) -> Rational { frame * frames }
        /// "HH:MM:SS:FF", non-drop frame.
        func timecode(_ frames: Int64) -> String {
            let tb = timebase, f = max(0, frames)
            return String(format: "%02lld:%02lld:%02lld:%02lld", f / (tb * 3600), (f / (tb * 60)) % 60, (f / tb) % 60, f % tb)
        }
    }

    // MARK: Media

    /// What another editor needs to know about a file beyond the project: frame rate, embedded start timecode, streams.
    struct Media: Equatable {
        var path: String
        var exists = true
        var rate: FrameRate? = nil        // the picture's rate; nil for sound and stills
        var startFrames: Int64 = 0        // the file's own start timecode, in frames of `rate`
        var hasVideo = false
        var hasAudio = false
        var channels = 2
        var sampleRate = 48_000
        var duration: Double = 0
        var width: Int? = nil
        var height: Int? = nil
        var isStill = false
    }

    /// Reads each asset's file. A nested sequence is its cached render.
    static func probe(_ project: Project) async -> [UUID: Media] {
        var out: [UUID: Media] = [:]
        for a in project.assets {
            var m = Media(path: a.path, duration: a.duration, width: a.width, height: a.height)
            m.exists = FileManager.default.fileExists(atPath: a.path)
            if a.kind == .image { m.isStill = true; m.hasVideo = true; out[a.id] = m; continue }
            guard m.exists else { m.hasVideo = a.kind != .audio; m.hasAudio = true; out[a.id] = m; continue }
            let av = AVURLAsset(url: a.url)
            if let v = try? await av.loadTracks(withMediaType: .video).first {
                m.hasVideo = true
                if let fps = try? await v.load(.nominalFrameRate), fps > 0 { m.rate = FrameRate(fps: Double(fps)) }
            }
            if let au = try? await av.loadTracks(withMediaType: .audio).first {
                m.hasAudio = true
                if let fd = (try? await au.load(.formatDescriptions))?.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                    m.channels = max(1, Int(asbd.mChannelsPerFrame)); m.sampleRate = max(8000, Int(asbd.mSampleRate))
                }
            }
            if let d = try? await av.load(.duration).seconds, d.isFinite, d > 0 { m.duration = d }
            if let r = m.rate { m.startFrames = await startTimecodeFrames(av, rate: r) }
            out[a.id] = m
        }
        return out
    }

    /// The first sample of the file's timecode track, in frames of the picture's rate; 0 when it has none.
    static func startTimecodeFrames(_ av: AVURLAsset, rate: FrameRate) async -> Int64 {
        guard let track = try? await av.loadTracks(withMediaType: .timecode).first, let reader = try? AVAssetReader(asset: av) else { return 0 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        defer { reader.cancelReading() }
        guard reader.startReading(), let sb = output.copyNextSampleBuffer(), let fd = CMSampleBufferGetFormatDescription(sb), let bb = CMSampleBufferGetDataBuffer(sb) else { return 0 }
        var count: Int64 = 0
        switch CMFormatDescriptionGetMediaSubType(fd) {
        case kCMTimeCodeFormatType_TimeCode32:
            var v: Int32 = 0
            guard CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: 4, destination: &v) == noErr else { return 0 }
            count = Int64(Int32(bigEndian: v))
        case kCMTimeCodeFormatType_TimeCode64:
            var v: Int64 = 0
            guard CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: 8, destination: &v) == noErr else { return 0 }
            count = Int64(bigEndian: v)
        default: return 0
        }
        let tcFrame = CMTimeCodeFormatDescriptionGetFrameDuration(fd).seconds
        guard tcFrame > 0, count >= 0 else { return 0 }
        return Int64((Double(count) * tcFrame / rate.frame.seconds).rounded())
    }

    // MARK: Layout

    enum Streams: String { case all, video, audio }

    /// One clip as another editor places it: a plain clip, one multicam cut of it, or the detached sound of such a cut.
    struct ClipItem {
        var clip: Clip                 // timing, speed, volume, fades, transform
        var asset: UUID
        var sourceIn: Double
        var streams: Streams = .all
        var enabled = true
        var muted = false
    }

    enum Item {
        case clip(ClipItem), title(TextOverlay)
        var start: Double { switch self { case .clip(let c): return c.clip.start; case .title(let t): return t.start } }
        var end: Double { switch self { case .clip(let c): return c.clip.end; case .title(let t): return t.end } }
        var transition: Transition? { if case .clip(let c) = self { return c.clip.transitionIn }; return nil }
    }

    struct Lane { var number: Int; var name: String; var items: [Item] }

    struct Layout {
        var primary: Lane
        var lanes: [Lane]
        /// The video track on the primary storyline (and in an EDL); nil when the project has none.
        var baseTrack: String?
        var captions: [TextOverlay]
        var clipCount: Int
    }

    static func layout(_ p: Project, media: [UUID: Media]) -> Layout {
        let video = p.tracks.filter { $0.kind == .video }, audio = p.tracks.filter { $0.kind == .audio }
        var count = 0
        func items(_ t: Track) -> (main: [Item], sound: [Item]) {
            var main: [Item] = [], sound: [Item] = []
            for clip in t.clips.sorted(by: { $0.start < $1.start }) {
                for piece in clip.multicamPieces(in: p) {
                    count += 1
                    var it = ClipItem(clip: piece, asset: piece.assetID, sourceIn: piece.sourceIn)
                    if t.kind == .audio {
                        it.streams = .audio; it.muted = t.isMuted
                    } else {
                        let soundAsset = piece.audioAssetID ?? piece.assetID
                        let ownSound = soundAsset == piece.assetID && (media[piece.assetID]?.hasAudio ?? false) && !t.isMuted
                        if soundAsset != piece.assetID, !t.isMuted {
                            var s = ClipItem(clip: piece, asset: soundAsset, sourceIn: piece.audioSourceIn ?? piece.sourceIn, streams: .audio)
                            s.clip.transitionIn = nil
                            sound.append(.clip(s))
                        }
                        let picture = !t.isHidden
                        if !picture && !ownSound { it.enabled = false } else { it.streams = picture && ownSound ? .all : picture ? .video : .audio }
                    }
                    main.append(.clip(it))
                }
            }
            return (main, sound)
        }

        var lanes: [Lane] = []
        var detached: [(String, [Item])] = []
        var primary = Lane(number: 0, name: "", items: [])
        if let base = video.last {
            let (m, s) = items(base)
            primary = Lane(number: 0, name: base.name, items: m)
            if !s.isEmpty { detached.append((base.name, s)) }
        }
        for (i, t) in video.dropLast().reversed().enumerated() {   // the track just above the base is lane 1, the top row highest
            let (m, s) = items(t)
            lanes.append(Lane(number: i + 1, name: t.name, items: m))
            if !s.isEmpty { detached.append((t.name, s)) }
        }
        // Titles above every video lane, as many lanes as overlapping titles need.
        let titles = p.texts.filter { !$0.isCaption }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var rows: [[Item]] = [], rowEnds: [Double] = []
        for t in titles {
            if let r = rowEnds.firstIndex(where: { $0 <= t.start + 0.001 }) { rows[r].append(.title(t)); rowEnds[r] = t.end }
            else { rows.append([.title(t)]); rowEnds.append(t.end) }
        }
        let topVideo = max(0, video.count - 1)
        for (r, row) in rows.enumerated() { lanes.append(Lane(number: topVideo + 1 + r, name: "Titles", items: row)) }
        for (i, t) in audio.enumerated() { lanes.append(Lane(number: -(i + 1), name: t.name, items: items(t).main)) }
        for (k, d) in detached.enumerated() { lanes.append(Lane(number: -(audio.count + 1 + k), name: "\(d.0) sound", items: d.1)) }
        lanes.removeAll { $0.items.isEmpty }
        return Layout(primary: primary, lanes: lanes, baseTrack: video.last?.name, captions: p.texts.filter(\.isCaption).sorted { $0.start < $1.start }, clipCount: count)
    }

    // MARK: Writing

    /// Writes `<path>.fcpxml` (with `<name>.srt` beside it when the project has captions) or `<path>.edl`.
    static func export(_ project: Project, to url: URL, format: Format) async throws -> Result {
        guard project.duration > 0 else { throw EditError.invalid("timeline is empty") }
        var url = url
        if url.pathExtension.lowercased() != format.fileExtension {
            if ["fcpxml", "edl", "xml"].contains(url.pathExtension.lowercased()) { url.deletePathExtension() }
            url.appendPathExtension(format.fileExtension)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let media = await probe(project)
        let layout = layout(project, media: media)
        var sidecars: [String] = []
        switch format {
        case .fcpxml:
            try fcpxml(project, media: media, layout: layout).write(to: url, atomically: true, encoding: .utf8)
            if !layout.captions.isEmpty {
                let srt = url.deletingPathExtension().appendingPathExtension("srt")
                try self.srt(layout.captions).write(to: srt, atomically: true, encoding: .utf8)
                sidecars.append(srt.path)
            }
        case .edl:
            guard layout.baseTrack != nil else { throw EditError.invalid("an EDL holds picture, and the project has no video track") }
            try edl(project, media: media, layout: layout).write(to: url, atomically: true, encoding: .utf8)
        }
        let r = report(project, format: format, layout: layout, media: media, srt: sidecars.first)
        return Result(format: format.rawValue, path: url.path, sidecars: sidecars, clips: format == .edl ? r.edlEvents : layout.clipCount,
                      transferred: r.transferred, notTransferred: r.notTransferred)
    }

    /// An XML element; `xml` writes it indented, with text and attributes escaped.
    final class Node {
        let name: String
        var attrs: [(String, String)]
        var children: [Node]
        var text: String?
        init(_ name: String, _ attrs: [(String, String)] = [], _ children: [Node] = [], text: String? = nil) {
            self.name = name; self.attrs = attrs; self.children = children; self.text = text
        }
        func write(_ depth: Int, into s: inout String) {
            let pad = String(repeating: "    ", count: depth)
            s += pad + "<" + name
            for (k, v) in attrs { s += " \(k)=\"\(Interchange.escape(v))\"" }
            if let text { s += ">" + Interchange.escape(text) + "</\(name)>\n"; return }
            if children.isEmpty { s += "/>\n"; return }
            s += ">\n"
            for c in children { c.write(depth + 1, into: &s) }
            s += pad + "</\(name)>\n"
        }
    }

    static func escape(_ s: String) -> String {
        var o = ""
        for ch in s {
            switch ch {
            case "&": o += "&amp;"; case "<": o += "&lt;"; case ">": o += "&gt;"; case "\"": o += "&quot;"; case "'": o += "&apos;"
            default:
                // XML 1.0 has no place for control characters other than tab, newline and return.
                if let a = ch.asciiValue, a < 0x20, a != 0x09, a != 0x0A, a != 0x0D { continue }
                o.append(ch)
            }
        }
        return o
    }

    /// FCPXML 1.10, valid against Apple's DTD for that version.
    static func fcpxml(_ p: Project, media: [UUID: Media], layout: Layout) -> String {
        var w = FCPXMLWriter(project: p, media: media)
        return w.document(layout)
    }

    struct FCPXMLWriter {
        let project: Project
        let media: [UUID: Media]
        let seq: FrameRate
        private var resources: [Node] = []
        private var formatIDs: [String: String] = [:]
        private var assetIDs: [UUID: String] = [:]
        private var effectIDs: [String: String] = [:]
        private var nextID = 1
        private var styleCount = 0
        static let dissolveUID = "FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265"
        static let basicTitleUID = ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"

        init(project: Project, media: [UUID: Media]) { self.project = project; self.media = media; self.seq = FrameRate(fps: project.settings.fps) }

        private mutating func id() -> String { defer { nextID += 1 }; return "r\(nextID)" }

        private mutating func format(rate: FrameRate?, width: Int, height: Int) -> String {
            let key = "\(rate?.frame.fcp ?? "still") \(width)x\(height)"
            if let f = formatIDs[key] { return f }
            let f = id()
            var a: [(String, String)] = [("id", f)]
            if let rate { a.append(("frameDuration", rate.frame.fcp)) } else { a.append(("name", "FFVideoFormatRateUndefined")) }
            a += [("width", "\(width)"), ("height", "\(height)"), ("colorSpace", "1-1-1 (Rec. 709)")]
            resources.append(Node("format", a))
            formatIDs[key] = f
            return f
        }

        private mutating func effect(_ name: String, uid: String) -> String {
            if let e = effectIDs[uid] { return e }
            let e = id()
            resources.append(Node("effect", [("id", e), ("name", name), ("uid", uid)]))
            effectIDs[uid] = e
            return e
        }

        /// Where the media's own timeline starts: its embedded timecode.
        private func assetStart(_ m: Media?) -> Rational { guard let m, let r = m.rate else { return .zero }; return r.time(m.startFrames) }

        private mutating func asset(_ aid: UUID) -> String {
            if let a = assetIDs[aid] { return a }
            let m = media[aid] ?? Media(path: project.asset(aid)?.path ?? "")
            let a = project.asset(aid)
            let rid = id()
            var attrs: [(String, String)] = [("id", rid), ("name", a?.name ?? URL(fileURLWithPath: m.path).lastPathComponent)]
            if m.isStill {
                attrs += [("start", "0s"), ("duration", "0s"), ("hasVideo", "1"), ("format", format(rate: nil, width: m.width ?? project.settings.width, height: m.height ?? project.settings.height)), ("videoSources", "1")]
            } else {
                let dur: Rational = m.rate.map { $0.time($0.frames(m.duration)) } ?? Rational(Int64((m.duration * Double(m.sampleRate)).rounded()), Int64(m.sampleRate))
                attrs += [("start", assetStart(m).fcp), ("duration", dur.fcp)]
                if m.hasVideo {
                    attrs += [("hasVideo", "1"), ("format", format(rate: m.rate ?? seq, width: m.width ?? project.settings.width, height: m.height ?? project.settings.height)), ("videoSources", "1")]
                }
                if m.hasAudio { attrs += [("hasAudio", "1"), ("audioSources", "1"), ("audioChannels", "\(m.channels)"), ("audioRate", "\(m.sampleRate)")] }
            }
            resources.append(Node("asset", attrs, [Node("media-rep", [("kind", "original-media"), ("src", URL(fileURLWithPath: m.path).absoluteString)])]))
            assetIDs[aid] = rid
            return rid
        }

        /// An element placed on a storyline, with its range in sequence frames and where its own timeline starts.
        struct Placed { var node: Node; var offset: Int64; var length: Int64; var localStart: Rational }

        /// The items of one lane, left to right: gaps where nothing plays, a transition before an item that dissolves
        /// in from whatever precedes it (the transition starts at the cut and uses the outgoing media past its out point,
        /// as EditMax plays it). Offsets are frames from the storyline's start (sequence 0 for every storyline here).
        mutating func storyline(_ items: [Item], padTo: Int64? = nil) -> (nodes: [Node], placed: [Placed]) {
            var nodes: [Node] = [], placed: [Placed] = []
            var cursor: Int64 = 0
            for item in items.sorted(by: { $0.start < $1.start }) {
                var sf = seq.frames(item.start)
                let ef = seq.frames(item.end)
                if sf < cursor { sf = cursor }          // never overlap the item before
                let len = max(1, ef - sf)
                if sf > cursor {
                    let g = Node("gap", [("name", "Gap"), ("offset", seq.time(cursor).fcp), ("start", "0s"), ("duration", seq.time(sf - cursor).fcp)])
                    nodes.append(g); placed.append(Placed(node: g, offset: cursor, length: sf - cursor, localStart: .zero))
                }
                if let tr = item.transition, !nodes.isEmpty {
                    let d = min(len, max(1, seq.frames(tr.duration)))
                    nodes.append(Node("transition", [("name", "Cross Dissolve"), ("offset", seq.time(sf).fcp), ("duration", seq.time(d).fcp)],
                                      [Node("filter-video", [("ref", effect("Cross Dissolve", uid: Self.dissolveUID)), ("name", "Cross Dissolve")])]))
                }
                let (node, local) = element(item, offset: sf, length: len)
                nodes.append(node); placed.append(Placed(node: node, offset: sf, length: len, localStart: local))
                cursor = sf + len
            }
            if let padTo, padTo > cursor {
                let g = Node("gap", [("name", "Gap"), ("offset", seq.time(cursor).fcp), ("start", "0s"), ("duration", seq.time(padTo - cursor).fcp)])
                nodes.append(g); placed.append(Placed(node: g, offset: cursor, length: padTo - cursor, localStart: .zero))
            }
            return (nodes, placed)
        }

        private mutating func element(_ item: Item, offset: Int64, length: Int64) -> (Node, Rational) {
            switch item {
            case .title(let t): return (title(t, offset: offset, length: length), .zero)
            case .clip(let c): return clip(c, offset: offset, length: length)
            }
        }

        private mutating func clip(_ c: ClipItem, offset: Int64, length: Int64) -> (Node, Rational) {
            let m = media[c.asset]
            let clip = c.clip
            let name = clip.name.isEmpty ? (project.asset(c.asset)?.name ?? "Clip") : clip.name
            var children: [Node] = []
            var local: Rational

            if m?.isStill == true {
                local = .zero
            } else if clip.isAnimated(.speed) {
                // A speed ramp: the clip's own timeline runs from 0, mapped through points sampled along the ramp.
                local = .zero
                let r = m?.rate ?? seq
                var ts = Set(clip.keyframes(.speed).map(\.time).filter { $0 > 0 && $0 < clip.duration })
                var t = 0.5; while t < clip.duration { ts.insert(t); t += 0.5 }
                let points = ([0] + ts.sorted() + [clip.duration]).map { tau in
                    Node("timept", [("time", seq.time(seq.frames(tau)).fcp), ("value", (assetStart(m) + r.time(r.frames(c.sourceIn + clip.sourceOffset(at: tau)))).fcp), ("interp", "linear")])
                }
                children.append(Node("timeMap", [], dedupe(points)))
            } else if Swift.abs(clip.speed - 1) > 0.0005, clip.speed > 0 {
                // A constant speed: the whole file retimed, so handles stay available for transitions.
                let r = m?.rate ?? seq
                let total = m?.duration ?? clip.sourceOut
                local = seq.time(seq.frames(c.sourceIn / clip.speed))
                children.append(Node("timeMap", [], [
                    Node("timept", [("time", "0s"), ("value", assetStart(m).fcp), ("interp", "linear")]),
                    Node("timept", [("time", seq.time(seq.frames(total / clip.speed)).fcp), ("value", (assetStart(m) + r.time(r.frames(total))).fcp), ("interp", "linear")])
                ]))
            } else if let r = m?.rate {
                local = assetStart(m) + r.time(r.frames(c.sourceIn))
            } else {
                local = seq.time(seq.frames(c.sourceIn))
            }

            let picture = c.streams != .audio && (m?.hasVideo ?? true)
            let sound = c.streams != .video && (m?.hasAudio ?? false) && m?.isStill != true
            let tf = clip.transform
            if picture, tf.scale != 1 || tf.x != 0 || tf.y != 0 || tf.rotation != 0 {
                // FCP measures position in percent of the frame height, y up, and rotation counter-clockwise.
                let aspect = Double(project.settings.width) / Double(max(1, project.settings.height))
                children.append(Node("adjust-transform", [("position", "\(num(tf.x * aspect * 100)) \(num(-tf.y * 100))"), ("scale", "\(num(tf.scale)) \(num(tf.scale))"), ("rotation", num(-tf.rotation))]))
            }
            let fadeIn = min(seq.frames(clip.fadeIn), length), fadeOut = min(seq.frames(clip.fadeOut), length)
            if picture, Swift.abs(clip.opacity - 1) > 0.0005 || fadeIn > 0 || fadeOut > 0 {
                var blend = Node("adjust-blend", [("amount", num(clip.opacity))])
                if fadeIn > 0 || fadeOut > 0 {
                    var keys: [Node] = []
                    func key(_ f: Int64, _ v: Double) { keys.append(Node("keyframe", [("time", (local + seq.time(f)).fcp), ("value", num(v))])) }
                    if fadeIn > 0 { key(0, 0); key(fadeIn, clip.opacity) }
                    if fadeOut > 0 { key(max(fadeIn, length - fadeOut), clip.opacity); key(length, 0) }
                    blend = Node("adjust-blend", [("amount", num(clip.opacity))], [Node("param", [("name", "amount")], [Node("keyframeAnimation", [], dedupe(keys))])])
                }
                children.append(blend)
            }
            if sound, Swift.abs(clip.volume - 1) > 0.0005 || fadeIn > 0 || fadeOut > 0 || c.muted {
                var fades: [Node] = []
                if fadeIn > 0 { fades.append(Node("fadeIn", [("type", "easeIn"), ("duration", seq.time(fadeIn).fcp)])) }
                if fadeOut > 0 { fades.append(Node("fadeOut", [("type", "easeOut"), ("duration", seq.time(fadeOut).fcp)])) }
                let amount = c.muted ? "-96dB" : decibels(clip.volume)
                children.append(Node("adjust-volume", [("amount", amount)], fades.isEmpty ? [] : [Node("param", [("name", "amount")], fades)]))
            }

            var attrs: [(String, String)] = [("ref", asset(c.asset)), ("offset", seq.time(offset).fcp), ("name", name), ("start", local.fcp), ("duration", seq.time(length).fcp)]
            if !c.enabled { attrs.append(("enabled", "0")) }
            if m?.isStill == true {
                return (Node("video", attrs, children.filter { $0.name != "adjust-volume" }), local)
            }
            if c.streams != .all, (m?.hasVideo ?? false), (m?.hasAudio ?? false) { attrs.append(("srcEnable", c.streams.rawValue)) }
            return (Node("asset-clip", attrs, children), local)
        }

        private mutating func title(_ t: TextOverlay, offset: Int64, length: Int64) -> Node {
            styleCount += 1
            let ts = "ts\(styleCount)"
            let style = CaptionPresets.style(t.preset)
            // FCP sizes titles in points of a 1080-line frame.
            let size = t.fontSize * 1080 / Double(max(1, project.settings.height))
            let label = String(t.text.replacingOccurrences(of: "\n", with: " ").prefix(40))
            return Node("title", [("ref", effect("Basic Title", uid: Self.basicTitleUID)), ("offset", seq.time(offset).fcp), ("name", label.isEmpty ? "Title" : label), ("start", "0s"), ("duration", seq.time(length).fcp)], [
                Node("text", [], [Node("text-style", [("ref", ts)], text: style.uppercase ? t.text.uppercased() : t.text)]),
                Node("text-style-def", [("id", ts)], [Node("text-style", [("font", style.fontName), ("fontSize", num(size)), ("fontColor", rgba(t.colorHex)), ("alignment", "center")])])
            ])
        }

        mutating func document(_ layout: Layout) -> String {
            let total = max(1, seq.frames(project.duration))
            let seqFormat = format(rate: seq, width: project.settings.width, height: project.settings.height)
            var (spine, placed) = storyline(layout.primary.items, padTo: total)
            // Every other lane is a connected storyline anchored at 0 on the first primary element.
            if let first = placed.first {
                for lane in layout.lanes {
                    let (nodes, _) = storyline(lane.items)
                    first.node.children.append(Node("spine", [("lane", "\(lane.number)"), ("offset", first.localStart.fcp), ("name", lane.name)], nodes))
                }
            }
            // Markers ride the primary element under them, in its own timeline.
            for (k, mk) in project.markers.sorted(by: { $0.time < $1.time }).enumerated() {
                let f = min(seq.frames(mk.time), total - 1)
                guard let host = placed.first(where: { f >= $0.offset && f < $0.offset + $0.length }) ?? placed.last else { continue }
                host.node.children.append(Node("marker", [("start", (host.localStart + seq.time(f - host.offset)).fcp), ("duration", seq.frame.fcp), ("value", mk.name.isEmpty ? "Marker \(k + 1)" : mk.name)]))
            }
            if spine.isEmpty { spine = [Node("gap", [("name", "Gap"), ("offset", "0s"), ("start", "0s"), ("duration", seq.time(total).fcp)])] }
            let sequence = Node("sequence", [("format", seqFormat), ("duration", seq.time(total).fcp), ("tcStart", "0s"), ("tcFormat", "NDF"), ("audioLayout", "stereo"), ("audioRate", "48k")],
                                [Node("spine", [], spine)])
            let root = Node("fcpxml", [("version", "1.10")], [
                Node("resources", [], resources),
                Node("library", [], [Node("event", [("name", "EditMax")], [Node("project", [("name", project.name)], [sequence])])])
            ])
            var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n\n"
            root.write(0, into: &s)
            return s
        }

        /// Keyframes and time points at the same time collapse to the last one.
        private func dedupe(_ nodes: [Node]) -> [Node] {
            var out: [Node] = []
            for n in nodes {
                let t = n.attrs.first { $0.0 == "time" }?.1
                if let last = out.last, last.attrs.first(where: { $0.0 == "time" })?.1 == t { out[out.count - 1] = n } else { out.append(n) }
            }
            return out
        }
        private func num(_ v: Double) -> String {
            let r = (v * 10000).rounded() / 10000
            return r == r.rounded() ? String(Int(r)) : String(format: "%g", r)
        }
        private func decibels(_ v: Double) -> String { v <= 0.0001 ? "-96dB" : String(format: "%.1fdB", 20 * log10(v)) }
        private func rgba(_ hex: String) -> String {
            var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
            guard h.count == 6, let v = UInt32(h, radix: 16) else { return "1 1 1 1" }
            return [Double((v >> 16) & 0xff), Double((v >> 8) & 0xff), Double(v & 0xff)].map { num($0 / 255) }.joined(separator: " ") + " 1"
        }
    }

    // MARK: EDL

    /// CMX 3600 of the bottom video track's picture: one event per clip (record from 01:00:00:00), a dissolve as the
    /// outgoing clip's zero-length cut plus a D event, an M2 line for a constant speed, and the clip and file names as
    /// comments, which Resolve relinks on.
    static func edl(_ p: Project, media: [UUID: Media], layout: Layout) -> String {
        edlEvents(p, media: media, layout: layout).text
    }

    static func edlEvents(_ p: Project, media: [UUID: Media], layout: Layout) -> (text: String, events: Int) {
        let seq = FrameRate(fps: p.settings.fps)
        let rec0 = seq.timebase * 3600
        let title = String(p.name.map { $0.isASCII && !$0.isNewline ? $0 : "_" }.prefix(70))
        var lines = ["TITLE: \(title.isEmpty ? "EditMax" : title)", "FCM: NON-DROP FRAME", ""]
        var n = 0
        var prev: (item: ClipItem, end: Int64)?
        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - s.count) }
        func event(_ k: Int, _ kind: String, _ dur: Int64?, _ sIn: Int64, _ sOut: Int64, _ src: FrameRate, _ rIn: Int64, _ rOut: Int64) -> String {
            let d = dur.map { String(format: "%03lld", min(999, $0)) } ?? "   "
            return "\(String(format: "%03d", k % 1000))  \(pad("AX", 8)) \(pad("V", 5)) \(pad(kind, 4)) \(d) \(src.timecode(sIn)) \(src.timecode(sOut)) \(seq.timecode(rIn)) \(seq.timecode(rOut))"
        }
        func names(_ c: ClipItem) -> (clip: String, file: String) {
            let a = p.asset(c.asset)
            return (a?.name ?? c.clip.name, media[c.asset]?.path ?? a?.path ?? "")
        }
        var cursor: Int64 = 0
        for item in layout.primary.items {
            guard case .clip(let c) = item, c.enabled, c.streams != .audio else { continue }
            var sf = seq.frames(c.clip.start)
            if sf < cursor { sf = cursor }
            let ef = max(sf + 1, seq.frames(c.clip.end))
            let m = media[c.asset]
            let src = m?.rate ?? seq
            let sIn = (m?.isStill == true ? 0 : (m?.startFrames ?? 0)) + src.frames(c.sourceIn)
            let sOut = sIn + (ef - sf)
            n += 1
            if let tr = c.clip.transitionIn, let pv = prev, pv.end == sf {
                // The outgoing clip carries on under the dissolve: where its source stands at the cut.
                let pm = media[pv.item.asset], prate = pm?.rate ?? seq
                let pAt = (pm?.startFrames ?? 0) + prate.frames(pv.item.sourceIn) + (sf - seq.frames(pv.item.clip.start))
                let d = min(ef - sf, max(1, seq.frames(tr.duration)))
                lines.append(event(n, "C", nil, pAt, pAt, prate, rec0 + sf, rec0 + sf))
                lines.append(event(n, "D", d, sIn, sOut, src, rec0 + sf, rec0 + ef))
                lines.append("* FROM CLIP NAME: \(names(pv.item).clip)")
                lines.append("* TO CLIP NAME: \(names(c).clip)")
            } else {
                lines.append(event(n, "C", nil, sIn, sOut, src, rec0 + sf, rec0 + ef))
                lines.append("* FROM CLIP NAME: \(names(c).clip)")
            }
            if !c.clip.isAnimated(.speed), Swift.abs(c.clip.speed - 1) > 0.0005 {
                lines.append("M2   \(pad("AX", 8)) \(String(format: "%05.1f", src.fps * c.clip.speed))                \(src.timecode(sIn))")
            }
            lines.append("* SOURCE FILE: \(names(c).file)")
            lines.append("")
            prev = (c, ef)
            cursor = ef
        }
        return (lines.joined(separator: "\n") + "\n", n)
    }

    // MARK: Captions

    /// The captions as SubRip, the subtitle file Resolve, Final Cut and Premiere all import.
    static func srt(_ captions: [TextOverlay]) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return captions.enumerated().map { i, c in "\(i + 1)\n\(ts(c.start)) --> \(ts(c.end))\n\(c.text)\n" }.joined(separator: "\n")
    }

    // MARK: Report

    /// What this project's file carries, and what stays behind in EditMax, in plain sentences.
    static func report(_ p: Project, format: Format, layout: Layout, media: [UUID: Media], srt: String?) -> (transferred: [String], notTransferred: [String], edlEvents: Int) {
        var yes: [String] = [], no: [String] = []
        func n(_ k: Int, _ one: String, _ many: String? = nil) -> String { "\(k) \(k == 1 ? one : (many ?? one + "s"))" }
        let clips = p.allClips
        let base = p.tracks.last { $0.kind == .video }
        let edlClips = layout.primary.items.filter { if case .clip(let c) = $0 { return c.enabled && c.streams != .audio }; return false }
        let inFile: [Clip] = format == .edl ? (base?.clips ?? []) : clips
        let dissolves = inFile.filter { $0.transitionIn != nil }
        let others = dissolves.filter { [.dipToBlack, .wipeLeft, .wipeRight].contains($0.transitionIn?.kind) }   // the newer kinds: Effects.notTransferred
        let constantSpeed = inFile.filter { !$0.isAnimated(.speed) && Swift.abs($0.speed - 1) > 0.0005 }
        let ramps = inFile.filter { $0.isAnimated(.speed) }
        let edlEvents = format == .edl ? edlEvents(p, media: media, layout: layout).events : 0

        switch format {
        case .fcpxml:
            let tracks = p.tracks.filter { !$0.clips.isEmpty }.count
            yes.append("\(n(layout.clipCount, "clip")) on \(n(tracks, "track")): order, trims and gaps, pointing at the original media files")
        case .edl:
            yes.append("\(n(edlEvents, "event")) from \(base?.name ?? "the video track") (its picture), pointing at the original media files by name")
            if edlEvents > 999 { no.append("Events past 999: CMX 3600 numbers wrap after 999") }
        }
        if !dissolves.isEmpty { yes.append(n(dissolves.count, "dissolve")) }
        if !others.isEmpty { no.append("\(n(others.count, "dip or wipe", "dips and wipes")): sent as cross dissolves") }
        if !constantSpeed.isEmpty { yes.append("Speed changes on \(n(constantSpeed.count, "clip"))") }
        if !ramps.isEmpty {
            if format == .fcpxml { yes.append("Speed ramps on \(n(ramps.count, "clip")), as retime points every half second") }
            else { no.append("Speed ramps on \(n(ramps.count, "clip")) (an EDL has one speed per event)") }
        }

        if format == .fcpxml {
            let volume = clips.filter { Swift.abs($0.volume - 1) > 0.0005 || $0.fadeIn > 0 || $0.fadeOut > 0 }
            if !volume.isEmpty { yes.append("Volume and fades on \(n(volume.count, "clip"))") }
            let moved = clips.filter { $0.transform.scale != 1 || $0.transform.x != 0 || $0.transform.y != 0 || $0.transform.rotation != 0 }
            if !moved.isEmpty { yes.append("Scale, position and rotation on \(n(moved.count, "clip"))") }
            if !p.markers.isEmpty { yes.append(n(p.markers.count, "marker")) }
            let titles = p.texts.filter { !$0.isCaption }
            if !titles.isEmpty {
                yes.append("\(n(titles.count, "title")) as text")
                no.append("Title styles and positions: titles come in as basic centered titles")
            }
            if let srt { yes.append("\(n(layout.captions.count, "caption")) to \(URL(fileURLWithPath: srt).lastPathComponent): import it as subtitles") ; no.append("Caption styles") }
        } else {
            let above = p.tracks.filter { $0.kind == .video && $0.id != base?.id && !$0.clips.isEmpty }
            if !above.isEmpty { no.append("Other video tracks (\(above.map(\.name).joined(separator: ", "))): an EDL holds one; use FCPXML for every track") }
            if p.tracks.contains(where: { $0.kind == .audio && !$0.clips.isEmpty }) || clips.contains(where: { media[$0.assetID]?.hasAudio == true }) { no.append("Sound: audio tracks, volume and fades") }
            if !p.texts.isEmpty { no.append("Titles and captions") }
            if !p.markers.isEmpty { no.append("Markers") }
            if edlClips.contains(where: { if case .clip(let c) = $0 { return media[c.asset]?.isStill == true }; return false }) { no.append("Stills keep their file name only: give them a reel or relink by hand") }
        }

        let graded = inFile.filter { $0.color.hasGrade }
        if !graded.isEmpty { no.append("Color grades and looks on \(n(graded.count, "clip")): grade in Resolve, or export ProRes to keep them baked in") }
        let input = inFile.filter { $0.color.inputLut != nil }
        if !input.isEmpty { no.append("Input LUTs on \(n(input.count, "log clip")): apply the same LUT in Resolve") }
        if format == .fcpxml {
            let fx = clips.filter { $0.audio.hasCleanup || $0.audio.needsIsolation }
            if !fx.isEmpty { no.append("EQ, high-pass, gate or voice isolation on \(n(fx.count, "clip"))") }
            no.append(contentsOf: Mixer.notTransferred(p))
            let ducked = p.tracks.filter { $0.duck != nil }
            if !ducked.isEmpty { no.append("Auto-ducking on \(ducked.map(\.name).joined(separator: ", "))") }
        }
        let stab = inFile.filter { $0.stabilization != nil }
        if !stab.isEmpty { no.append("Stabilization on \(n(stab.count, "clip"))") }
        no += ColorPipeline.notTransferred(inFile)   // wheels, curves, grade layers, masks, finishing (GradeStack.swift)
        no.append(contentsOf: Effects.notTransferred(p, clips: inFile, edl: format == .edl))   // keys, blend modes, blurs, newer transitions, title animations, HDR
        let keyed = inFile.filter { c in c.animations.contains { $0.key != ClipParam.speed.rawValue && !$0.value.isEmpty } }
        if !keyed.isEmpty { no.append("Keyframes on \(n(keyed.count, "clip")) (animated transform, auto-reframe, color, opacity or volume)") }
        let cropped = inFile.filter { $0.transform.cropLeft != 0 || $0.transform.cropRight != 0 || $0.transform.cropTop != 0 || $0.transform.cropBottom != 0 }
        if !cropped.isEmpty { no.append("Crops on \(n(cropped.count, "clip"))") }
        if format == .edl {
            let moved = inFile.filter { $0.transform.scale != 1 || $0.transform.x != 0 || $0.transform.y != 0 || $0.transform.rotation != 0 || Swift.abs($0.opacity - 1) > 0.0005 }
            if !moved.isEmpty { no.append("Scale, position, rotation and opacity on \(n(moved.count, "clip"))") }
        }
        let nested = Set(inFile.compactMap { c in p.asset(c.assetID).flatMap { $0.kind == .sequence ? $0.name : nil } })
        if !nested.isEmpty { no.append("Nested sequences (\(nested.sorted().joined(separator: ", "))) come in as their rendered file, not as editable timelines") }
        let missing = Set(inFile.compactMap { c in media[c.assetID].flatMap { $0.exists ? nil : URL(fileURLWithPath: $0.path).lastPathComponent } })
        if !missing.isEmpty { no.append("Missing on this Mac, so they will need relinking: \(missing.sorted().joined(separator: ", "))") }
        return (yes, no, edlEvents)
    }
}

extension ToolExecutor {
    /// The live project as an edit list for another editor (the document is not changed).
    func exportTimeline(to path: String, format: Interchange.Format) async throws -> Interchange.Result {
        var copy = document.project
        copy.name = document.displayName
        return try await Interchange.export(copy, to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), format: format)
    }
}
