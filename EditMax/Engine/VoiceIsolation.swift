import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import Combine

/// Voice isolation (dialogue cleanup) rendered ahead of time: an asset's sound is run through Apple's
/// `AUSoundIsolation` audio unit offline (AVAudioEngine in manual rendering mode) and kept in Application Support,
/// keyed by the file's path, size and modification date plus the amount (10 % steps). Only the parts of the source the
/// timeline reads are rendered, in 2-minute blocks (`blockSeconds`); a clip plays its blocks joined on the source's
/// timeline once every one it reads is there (`readySource`), and the export renders what is missing first
/// (`ensureAll`). A whole-file render from an older version is still used. Nothing runs inside the real-time audio tap.
@MainActor
final class IsolatedAudio: ObservableObject {
    static let shared = IsolatedAudio()

    /// Cache keys being rendered right now (`key(for:amount:)`).
    @Published private(set) var rendering: Set<String> = []
    /// 0…1 per key while rendering.
    @Published private(set) var progress: [String: Double] = [:]
    /// The last failure per key, cleared by a later successful render.
    @Published private(set) var failed: [String: String] = [:]
    /// Bumped whenever an isolated file becomes ready, so the preview can rebuild with it.
    @Published private(set) var version = 0

    private var inFlight: [String: Task<Void, Error>] = [:]
    private var scheduled: [UUID: Task<Void, Never>] = [:]
    private var missingTask: Task<Void, Never>?

    nonisolated static let sampleRate = 48_000.0

    /// The rendered file: Apple Lossless at 16 bits. Lossless and without encoder priming, so it lines up sample for
    /// sample like the 16-bit PCM it replaced, at about half the size for speech (18 h of stereo PCM is 12.4 GB).
    nonisolated static func fileSettings(channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: 16]
    }
    /// The most disk a render can take (Apple Lossless never ends much above 16-bit PCM), plus 0.5 GB left over.
    nonisolated static func diskNeeded(seconds: Double, channels: Int) -> Int64 {
        Int64(max(0, seconds) * sampleRate * Double(channels) * 2 * 1.02) + 500_000_000
    }
    /// Refuses a render that could fill the disk: an 18-hour file can need over 12 GB.
    nonisolated static func checkDisk(needed: Int64, free: Int64, name: String) throws {
        guard free < needed else { return }
        throw EditError.invalid(String(format: "Voice isolation of '%@' needs up to %.1f GB free on the disk that holds Application Support; %.1f GB is free. Free some space, or isolate less of it (only the parts on the timeline are rendered).",
                                       name, Double(needed) / 1e9, Double(free) / 1e9))
    }
    nonisolated static let chunk: AVAudioFrameCount = 4096

    // MARK: Keys and paths

    nonisolated static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax/isolated")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The amount in whole percent, quantized to 10 % steps (the cache has at most ten renders per asset).
    nonisolated static func pct(_ amount: Double) -> Int { max(0, min(100, Int((amount * 10).rounded()) * 10)) }

    /// `<assetHash>-<pct>`: the asset part is the proxy store's hash of path, size and modification date.
    nonisolated static func key(for asset: Asset, amount: Double) -> String { "\(ProxyStore.key(for: asset))-\(pct(amount))" }
    nonisolated static func url(for asset: Asset, amount: Double) -> URL { directory.appendingPathComponent(key(for: asset, amount: amount) + ".caf") }

    /// The cached isolated file if it exists on disk (no actor hop: callable from the builder).
    nonisolated static func readyURL(for asset: Asset, amount: Double) -> URL? {
        guard pct(amount) > 0, eligible(asset) else { return nil }
        let u = url(for: asset, amount: amount)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Media files with sound. A nested sequence's asset is a cached render made during the build, so it cannot be
    /// isolated as a whole: isolate the clips inside it instead.
    nonisolated static func eligible(_ asset: Asset) -> Bool { asset.kind != .image && asset.sequenceID == nil }
    nonisolated static let sequenceMessage = "voice isolation does not apply to a nested sequence: unnest it, or isolate the clips inside it"

    // MARK: Blocks

    /// Renders cover what the timeline uses, in blocks of the source this long (the last one shorter), each its own file.
    /// One render pass covers a run of neighbouring blocks with one calibration, so they join seamlessly; a run that
    /// starts after the beginning of the file first plays `prerollFrames` of the sound before it. Two minutes: a clip
    /// trimmed into a block not rendered yet plays its original sound for about 8 s (measured on speech: a 2-minute block
    /// 7 s, 11 s for the first pass, which loads the model; 10-minute blocks took 21–27 s), and a short clip renders little
    /// more than it reads. Each pass costs some 4 s on its own, so neighbouring blocks share one.
    nonisolated(unsafe) static var blockSeconds = 120.0   // tests set a few seconds
    nonisolated static func blockCount(_ duration: Double) -> Int { max(1, Int((duration / blockSeconds).rounded(.up))) }
    nonisolated static func blockRange(_ k: Int, duration: Double) -> (start: Double, end: Double) {
        (Double(k) * blockSeconds, min(duration, Double(k + 1) * blockSeconds))
    }
    /// `<key>-b120s-<k>.caf`: the block length is part of the name, so files of another length are never read as these.
    nonisolated static func blockURL(for asset: Asset, amount: Double, block k: Int) -> URL {
        directory.appendingPathComponent("\(key(for: asset, amount: amount))-b\(Int(blockSeconds))s-\(k).caf")
    }
    /// The blocks a span of source seconds reads from.
    nonisolated static func blocks(covering span: ClosedRange<Double>, duration: Double) -> [Int] {
        let last = blockCount(duration) - 1
        let lo = min(last, max(0, Int((span.lowerBound / blockSeconds).rounded(.down))))
        let hi = min(last, max(lo, Int((span.upperBound / blockSeconds).rounded(.up)) - 1))
        return Array(lo...hi)
    }

    /// The source seconds a clip's isolated sound can be read from: its sound (J and L cuts included), the tail that a
    /// transition or a crossfade into `next` reads past its out point, and a second either side.
    nonisolated static func span(of clip: Clip, next: Clip?, in project: Project) -> ClosedRange<Double>? {
        guard let asset = audioAsset(of: clip, in: project), asset.duration > 0 else { return nil }
        let ends = TimeMap.segments(clip.soundClip(), assetDuration: asset.duration).flatMap { [$0.sourceStart, $0.sourceEnd] }
        guard let lo = ends.min(), let hi = ends.max() else { return nil }
        let tail = max(next?.transitionIn?.duration ?? 0, next?.audioCrossfade?.duration ?? 0) * max(1, clip.speed(at: clip.duration))
        let a = min(asset.duration, max(0, lo - 1))
        return a...max(a, min(asset.duration, hi + tail + 1))
    }

    /// What the timeline needs rendered for one cache key (an asset at an amount): the blocks its clips read.
    struct Need { let asset: Asset; let amount: Double; var blocks: Set<Int> }

    /// Every key's needs, from the clips as the composition plays them (`Project.playedClips`), on `tracks` (all of
    /// them when nil) and only clip `only` when given.
    nonisolated static func needs(_ project: Project, tracks: [Track]? = nil, only: UUID? = nil) -> [String: Need] {
        var out: [String: Need] = [:]
        for track in tracks ?? project.tracks {
            let clips = project.playedClips(on: track)
            for (i, clip) in clips.enumerated() where clip.audio.needsIsolation && (only == nil || clip.id == only) {
                guard let asset = audioAsset(of: clip, in: project), eligible(asset),
                      let span = span(of: clip, next: i + 1 < clips.count ? clips[i + 1] : nil, in: project) else { continue }
                let k = key(for: asset, amount: clip.audio.voiceIsolation)
                out[k, default: Need(asset: asset, amount: clip.audio.voiceIsolation, blocks: [])].blocks.formUnion(blocks(covering: span, duration: asset.duration))
            }
        }
        return out
    }

    /// The isolated sound a clip reading `span` of `asset` plays: a whole-file render from an older version when there
    /// is one, else the blocks covering the span joined on the source's timeline. Nil unless every one of those blocks
    /// is on disk: a clip never plays partly isolated. `keep` must outlive any composition made from `asset`.
    nonisolated static func readySource(for asset: Asset, amount: Double, span: ClosedRange<Double>?) async throws -> (asset: AVAsset, keep: [AVAsset])? {
        guard pct(amount) > 0, eligible(asset), let span else { return nil }
        if let whole = readyURL(for: asset, amount: amount) { let a = AVURLAsset(url: whole); return (a, [a]) }
        let ks = blocks(covering: span, duration: asset.duration)
        let urls = ks.map { blockURL(for: asset, amount: amount, block: $0) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return try await stitched(ks, urls, duration: asset.duration)
    }

    /// Joined blocks, reused: the preview rebuilds its composition on every edit.
    private final class Stitches: @unchecked Sendable {
        let lock = NSLock()
        var items: [String: (asset: AVAsset, keep: [AVAsset])] = [:]
    }
    nonisolated private static let stitches = Stitches()

    /// The blocks as one sound on the source's timeline: block k at k × `blockSeconds`, anything between them silent.
    /// A block a little short of its length (a source with dropped packets) leaves a few silent milliseconds, never a
    /// read past the end of its file.
    nonisolated static func stitched(_ ks: [Int], _ urls: [URL], duration: Double) async throws -> (asset: AVAsset, keep: [AVAsset])? {
        let id = urls.map(\.lastPathComponent).joined(separator: "|")
        stitches.lock.lock(); let hit = stitches.items[id]; stitches.lock.unlock()
        if let hit { return hit }
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var keep: [AVAsset] = [comp]
        let at = { (s: Double) in CMTime(value: CMTimeValue((s * sampleRate).rounded()), timescale: CMTimeScale(sampleRate)) }
        for (k, u) in zip(ks, urls) {
            let a = AVURLAsset(url: u)
            guard let t = try await a.loadTracks(withMediaType: .audio).first else { return nil }
            let have = try await t.load(.timeRange)
            let r = blockRange(k, duration: duration)
            let start = at(r.start), length = CMTimeMinimum(have.duration, at(r.end - r.start))
            let end = track.timeRange.end
            if end < start { track.insertEmptyTimeRange(CMTimeRange(start: end, end: start)) }
            if length > .zero { try track.insertTimeRange(CMTimeRange(start: have.start, duration: length), of: t, at: start) }
            keep.append(a)
        }
        let made = (asset: comp as AVAsset, keep: keep)
        stitches.lock.lock(); if stitches.items.count >= 32 { stitches.items = [:] }; stitches.items[id] = made; stitches.lock.unlock()
        return made
    }

    func isRendering(_ asset: Asset, amount: Double) -> Bool { rendering.contains(Self.key(for: asset, amount: amount)) }

    /// Whether the AUSoundIsolation unit exists on this Mac (macOS 13+; some virtual-audio setups hide it).
    nonisolated static var isAvailable: Bool {
        var desc = componentDescription
        return AudioComponentFindNext(nil, &desc) != nil
    }
    nonisolated static let unavailableMessage = "Voice isolation is not available on this Mac: Apple's AUSoundIsolation audio unit was not found (it needs macOS 13 or later)."

    nonisolated static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                  componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    }

    /// The asset whose sound a clip plays (a multicam piece's audio angle, else its own asset).
    nonisolated static func audioAsset(of clip: Clip, in project: Project) -> Asset? {
        clip.audioAssetID.flatMap(project.asset) ?? project.asset(clip.assetID)
    }

    // MARK: Rendering

    /// Renders what is missing of `blocks` (every block of the file when nil) for an asset at an amount; a whole-file
    /// render from an older version counts as all of them. Calls for the same key take turns, and each renders only
    /// what is still missing when its turn comes. Finished blocks stay when a later one fails or is cancelled.
    func ensure(_ asset: Asset, amount: Double, blocks wanted: Set<Int>? = nil) async throws {
        let p = Self.pct(amount)
        guard p > 0 else { throw EditError.invalid("voice isolation amount is 0") }
        guard asset.kind != .image else { throw EditError.invalid("'\(asset.name)' is an image; it has no sound") }
        guard asset.sequenceID == nil else { throw EditError.invalid(Self.sequenceMessage) }
        let k = Self.key(for: asset, amount: amount)
        while let t = inFlight[k] { _ = try? await t.value }
        if Self.readyURL(for: asset, amount: amount) != nil { return }
        let missing = (wanted ?? Set(0..<Self.blockCount(asset.duration)))
            .filter { !FileManager.default.fileExists(atPath: Self.blockURL(for: asset, amount: amount, block: $0).path) }.sorted()
        guard !missing.isEmpty else { return }
        guard Self.isAvailable else { throw EditError.invalid(Self.unavailableMessage) }
        guard FileManager.default.fileExists(atPath: asset.path) else { throw EditError.notFound("'\(asset.name)' at \(asset.path)") }
        // Runs of neighbouring blocks: one render pass (one calibration) each.
        var runs: [[Piece]] = []
        for b in missing {
            let r = Self.blockRange(b, duration: asset.duration)
            let piece = Piece(start: r.start, end: r.end, url: Self.blockURL(for: asset, amount: amount, block: b))
            if let last = runs.last?.last, abs(last.end! - r.start) < 1e-9 { runs[runs.count - 1].append(piece) } else { runs.append([piece]) }
        }
        let total = runs.joined().reduce(0) { $0 + $1.end! - $1.start }
        rendering.insert(k); progress[k] = 0; failed[k] = nil
        let source = asset.url, name = asset.name
        let task = Task<Void, Error> {
            let started = Date()
            let cancel = CancelFlag()
            try await withTaskCancellationHandler {
                var done = 0.0
                for run in runs {
                    let length = run.reduce(0) { $0 + $1.end! - $1.start }, before = done
                    let report: @Sendable (Double) -> Void = { f in Task { @MainActor in self.progress[k] = (before + f * length) / max(1e-9, total) } }
                    try await Self.render(source: source, pieces: run, pct: p, cancel: cancel, progress: report)
                    done += length
                    self.version += 1   // the clips that read only these blocks can play them now
                }
                DebugLog.event("voice-isolation", ["asset": name, "key": k, "blocks": missing.count, "runs": runs.count, "sourceSeconds": total.rounded(),
                                                   "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
            } onCancel: { cancel.cancelled = true }
        }
        inFlight[k] = task
        defer { inFlight[k] = nil; rendering.remove(k); progress[k] = nil }
        do {
            try await task.value
            DebugLog.event("voice-isolation-ready", ["key": k, "version": version])
        } catch {
            failed[k] = error.localizedDescription
            DebugLog.error("voice-isolation-failed", error, ["asset": name, "key": k])
            throw error
        }
    }

    /// Renders after a short quiet period, so a slider drag (one call per step) ends in one render, not ten: what the
    /// timeline reads of this asset at this amount.
    func schedule(_ asset: Asset, amount: Double, in project: Project, delay: Duration = .milliseconds(500)) {
        scheduled[asset.id]?.cancel()
        guard Self.pct(amount) > 0 else { return }
        let blocks = Self.needs(project)[Self.key(for: asset, amount: amount)]?.blocks ?? []
        scheduled[asset.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            try? await self.ensure(asset, amount: amount, blocks: blocks)
        }
    }

    /// Renders, after a quiet period, what the timeline reads now that no render has covered: a trim, a move or a J/L cut
    /// can reach a block of the file not rendered yet, and until it is there the clip plays its original sound. The
    /// preview calls this on every rebuild. A key whose last render failed waits for the amount to change (the inspector
    /// shows the failure), so a full disk is not retried on every edit.
    @discardableResult
    func scheduleMissing(_ project: Project, delay: Duration = .milliseconds(800)) -> Task<Void, Never>? {
        guard Self.isAvailable else { return nil }
        let needs = Self.needs(project).filter { k, n in
            failed[k] == nil && Self.readyURL(for: n.asset, amount: n.amount) == nil
                && n.blocks.contains { !FileManager.default.fileExists(atPath: Self.blockURL(for: n.asset, amount: n.amount, block: $0).path) }
        }.sorted { $0.key < $1.key }
        missingTask?.cancel()   // a render already started carries on; the next call finds its blocks there
        guard !needs.isEmpty else { missingTask = nil; return nil }
        missingTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            for (_, n) in needs {
                guard !Task.isCancelled, let self else { return }
                try? await self.ensure(n.asset, amount: n.amount, blocks: n.blocks)
            }
        }
        return missingTask
    }

    /// Renders the isolated sound every clip that asks for it reads (the export and loudness call this first).
    func ensureAll(_ project: Project) async throws {
        for (_, n) in Self.needs(project).sorted(by: { $0.key < $1.key }) {
            try await ensure(n.asset, amount: n.amount, blocks: n.blocks)
        }
    }

    /// Whether everything `clip` reads is rendered.
    func isReady(_ clip: Clip, in project: Project) -> Bool {
        guard let asset = Self.audioAsset(of: clip, in: project) else { return false }
        if Self.readyURL(for: asset, amount: clip.audio.voiceIsolation) != nil { return true }
        let track = project.tracks.filter { $0.clips.contains { $0.id == clip.id } }
        guard let need = Self.needs(project, tracks: track, only: clip.id).first?.value, !need.blocks.isEmpty else { return false }
        return need.blocks.allSatisfy { FileManager.default.fileExists(atPath: Self.blockURL(for: asset, amount: need.amount, block: $0).path) }
    }

    /// Caption for the inspector: what the slider does, and the state of what this clip reads at its amount.
    func caption(for clip: Clip, in project: Project) -> String {
        let base = "Keeps the speech and drops room noise and background (Apple's voice isolator). Renders on this Mac the parts of the file the timeline uses, once per amount."
        let amount = clip.audio.voiceIsolation
        guard let asset = Self.audioAsset(of: clip, in: project), Self.pct(amount) > 0 else { return base }
        let k = Self.key(for: asset, amount: amount)
        if rendering.contains(k) {
            let f = progress[k] ?? 0
            return base + " Rendering… \(Int((f * 100).rounded()))%" + (isReady(clip, in: project) ? "" : ": this clip plays its original sound until it is done.")
        }
        if isReady(clip, in: project) { return base + " Ready: the preview and the export play the isolated sound." }
        if let e = failed[k] { return base + " Failed: \(e)" }
        if !Self.isAvailable { return base + " " + Self.unavailableMessage }
        return base + " Waiting to render…"
    }

    /// A render cancellation flag shared with the blocking loop.
    final class CancelFlag: @unchecked Sendable { var cancelled = false }

    /// One output file of a render: the source from `start` to `end` seconds (nil: to the end of the sound).
    struct Piece: Sendable { let start: Double; let end: Double?; let url: URL }

    /// The whole file into one output, as older versions cached it.
    nonisolated static func render(source: URL, to url: URL, pct: Int, cancel: CancelFlag, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await render(source: source, pieces: [Piece(start: 0, end: nil, url: url)], pct: pct, cancel: cancel, progress: progress)
    }

    /// Decodes consecutive pieces of the asset's sound (48 kHz float, 1 or 2 channels), each through its own AVAssetReader
    /// started at the piece's own source time (so a source with dropped packets drifts at most within a piece), runs
    /// them through AUSoundIsolation in one offline AVAudioEngine and writes one Apple Lossless .caf per piece of exactly
    /// the frames its reader gave, lined up sample for sample with the source. The unit's delay is measured on the very
    /// instance that renders (`Calibration`: it changes once the model has loaded, at a frame that depends on wall-clock
    /// timing). Then the model warms up on the sound just before the first piece (`prerollFrames`), or, when the first
    /// piece starts the file, on its own first half second, played twice; everything before the first piece plus the
    /// measured delay is dropped and the tail is flushed to the exact length. Blocks a utility-queue thread, never the caller's.
    nonisolated static func render(source: URL, pieces: [Piece], pct: Int, cancel: CancelFlag, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let first = pieces.first else { return }
        let av = AVURLAsset(url: source)
        guard let track = try await av.loadTracks(withMediaType: .audio).first else { throw EditError.invalid("'\(source.lastPathComponent)' has no audio track") }
        var srcChannels = 2
        if let fd = try await track.load(.formatDescriptions).first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            srcChannels = Int(asbd.pointee.mChannelsPerFrame)
        }
        let duration = try await track.load(.timeRange).duration.seconds
        let seconds = pieces.reduce(0) { $0 + max(0, min(duration, $1.end ?? duration) - $1.start) }
        let channels = AVAudioChannelCount(max(1, min(2, srcChannels)))
        if let free = try? first.url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            try checkDisk(needed: diskNeeded(seconds: seconds, channels: Int(channels)), free: free, name: source.lastPathComponent)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do { try renderBlocking(asset: av, track: track, channels: channels, pieces: pieces, seconds: seconds, pct: pct, cancel: cancel, progress: progress); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Warm-up when the first piece starts the file: this many of its own first frames are played (and dropped) before it.
    nonisolated static let warmupFrames = 6 * Int(chunk)
    /// Warm-up when it starts later: the sound just before it, about 8 s (a whole number of render chunks). Measured, 2 s
    /// and 8 s land in the same range: the unit's own run-to-run difference is larger than either leaves.
    nonisolated static let prerollFrames = 96 * Int(chunk)

    nonisolated private static func renderBlocking(asset av: AVURLAsset, track: AVAssetTrack, channels: AVAudioChannelCount, pieces: [Piece], seconds: Double, pct: Int,
                                                   cancel: CancelFlag, progress: @escaping @Sendable (Double) -> Void) throws {
        let name = av.url.lastPathComponent
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
              let readFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: true) else { throw EditError.invalid("audio format") }
        let expected = max(1.0, (seconds.isFinite ? seconds : 0) * sampleRate)
        let time = { (s: Double) in CMTime(value: CMTimeValue((s * sampleRate).rounded()), timescale: CMTimeScale(sampleRate)) }
        /// A started reader over `start`..<`end` of the source (whole when it is the whole file).
        func reader(from start: Double, to end: Double?) throws -> (AVAssetReader, AVAssetReaderOutput) {
            let r = try AVAssetReader(asset: av)
            if start > 0 || end != nil {
                r.timeRange = end.map { CMTimeRange(start: time(start), end: time($0)) } ?? CMTimeRange(start: time(start), duration: .positiveInfinity)
            }
            let o = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: Int(channels),
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
            o.alwaysCopiesSampleData = false
            guard r.canAdd(o) else { throw EditError.invalid("cannot read the sound of '\(name)'") }
            r.add(o)
            guard r.startReading() else { throw r.error ?? EditError.invalid("cannot read '\(name)'") }
            return (r, o)
        }
        let start0 = pieces[0].start
        let preroll = start0 > 0 ? try reader(from: max(0, start0 - Double(prerollFrames) / sampleRate), to: start0) : nil

        // The source: calibration noise, then the warm-up, then the pieces one after another.
        // Manual rendering runs the block synchronously on this thread, so the decoders are pulled on demand.
        let feed = Feed(format: readFmt, channels: Int(channels), warmupFrames: preroll == nil ? warmupFrames : prerollFrames, preroll: preroll) { i in
            i < pieces.count ? try reader(from: pieces[i].start, to: pieces[i].end) : nil
        }
        let cal = Calibration(channels: Int(channels))
        let sourceNode = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let n = Int(frameCount)
            switch cal.phase {
            case .calibrate: cal.emit(abl, frames: n)
            case .warmup: feed.fillWarmup(abl, frames: n)
            case .audio: feed.fill(abl, frames: n)
            }
            return noErr   // silence is never flagged: the unit must keep running to flush its delay line
        }
        let effect = AVAudioUnitEffect(audioComponentDescription: componentDescription)
        let engine = AVAudioEngine()
        engine.attach(sourceNode); engine.attach(effect)
        engine.connect(sourceNode, to: effect, format: fmt)
        engine.connect(effect, to: engine.mainMixerNode, format: fmt)
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: chunk)
        try engine.start()
        defer { engine.stop() }
        AudioUnitSetParameter(effect.audioUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0)
        AudioUnitSetParameter(effect.audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 0, 0)   // dry while calibrating
        let reported = max(0, Int((effect.auAudioUnit.latency * sampleRate).rounded()))
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk), let slice = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { throw EditError.invalid("audio buffer") }

        // 1. Calibration: dry noise until the output is a steady exact copy of it (the lag is the unit's delay).
        let started = Date()
        while cal.phase == .calibrate {
            if cancel.cancelled { throw CancellationError() }
            let status = try engine.renderOffline(chunk, to: out)
            guard status == .success, out.frameLength > 0, let p = out.floatChannelData?[0] else { throw EditError.invalid("the voice isolator stopped rendering (\(status.rawValue))") }
            cal.observe(UnsafeBufferPointer(start: p, count: Int(out.frameLength)), elapsed: Date().timeIntervalSince(started))
        }
        let delay = cal.delay ?? reported
        if cal.delay == nil { DebugLog.event("voice-isolation-latency", ["note": "no steady match for the calibration noise; using the reported latency", "reported": reported]) }

        // 2. Warm-up: the requested mix over the sound before the first piece, or its own first half second (dropped).
        AudioUnitSetParameter(effect.audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, AudioUnitParameterValue(pct), 0)
        cal.phase = .warmup
        var warmed = 0
        while warmed < feed.warmupFrames {
            if cancel.cancelled { throw CancellationError() }
            let status = try engine.renderOffline(chunk, to: out)
            guard status == .success, out.frameLength > 0 else { throw EditError.invalid("the voice isolator stopped rendering (\(status.rawValue))") }
            warmed += Int(out.frameLength)
        }
        cal.phase = .audio

        // 3. The pieces: drop `delay` frames, then write each piece's exact frame count to its own file.
        var current = 0, inPiece = 0
        var file: AVAudioFile?, tmp: URL?
        func open(_ i: Int) throws {
            let t = pieces[i].url.deletingPathExtension().appendingPathExtension("part.caf")
            try? FileManager.default.removeItem(at: t)
            file = try AVAudioFile(forWriting: t, settings: fileSettings(channels: Int(channels)), commonFormat: .pcmFormatFloat32, interleaved: false)
            tmp = t
        }
        func close(_ i: Int) throws {
            file?.close(); file = nil
            guard let t = tmp else { return }
            tmp = nil
            try? FileManager.default.removeItem(at: pieces[i].url)
            try FileManager.default.moveItem(at: t, to: pieces[i].url)
        }
        /// Closes every piece whose reader has finished and whose frames are all written, opening the next.
        func closeFinished() throws {
            while current < pieces.count, current < feed.pieceFrames.count, inPiece >= feed.pieceFrames[current] {
                try close(current); current += 1; inPiece = 0
                if current < pieces.count { try open(current) }
            }
        }
        var skipped = 0, written = 0, lastReport = Date.distantPast
        do {
            try open(0)
            while true {
                if cancel.cancelled { throw CancellationError() }
                if let e = feed.failure { throw e }
                let status = try engine.renderOffline(chunk, to: out)
                guard status == .success, out.frameLength > 0 else { throw EditError.invalid("the voice isolator stopped rendering (\(status.rawValue))") }
                var offset = 0, frames = Int(out.frameLength)
                if skipped < delay { let s = min(delay - skipped, frames); skipped += s; offset += s; frames -= s }
                if feed.exhausted { frames = min(frames, feed.inputFrames - written) }
                try closeFinished()
                while frames > 0, current < pieces.count {
                    // A piece still being read takes everything so far; a finished one takes up to its frame count.
                    let n = min(frames, current < feed.pieceFrames.count ? feed.pieceFrames[current] - inPiece : frames)
                    for ch in 0..<Int(channels) { slice.floatChannelData![ch].update(from: out.floatChannelData![ch] + offset, count: n) }
                    slice.frameLength = AVAudioFrameCount(n)
                    try file?.write(from: slice)
                    inPiece += n; written += n; offset += n; frames -= n
                    try closeFinished()
                }
                if feed.exhausted && written >= feed.inputFrames { break }
                if Date().timeIntervalSince(lastReport) > 0.5 { lastReport = Date(); progress(min(0.99, Double(written) / expected)) }
            }
            try closeFinished()
            guard feed.inputFrames > 0 else { throw EditError.invalid("'\(name)' has no sound to isolate") }
        } catch {
            feed.cancel()
            file?.close()
            if let t = tmp { try? FileManager.default.removeItem(at: t) }
            throw error
        }
        DebugLog.event("voice-isolation-render", ["file": name, "pieces": pieces.count, "from": start0, "delay": delay, "reported": reported,
                                                  "calibrationFrames": cal.emittedFrames, "switched": cal.sawSwitch, "frames": written])
        progress(1)
    }

    /// Measures the unit's delay on the instance in use: pseudo-random noise goes in dry and the exact-copy lag of the
    /// newest output window is tracked chunk by chunk. The unit passes sound through with a short delay until its model
    /// has loaded (macOS 26 stereo: 3665 frames, then 6360 with 2695 inserted in a short crossfade), at a frame that
    /// depends on wall-clock timing, so calibration ends only once the lag has held for a second of frames and either a
    /// switch was seen or three seconds have passed; after twenty seconds the last match is taken.
    final class Calibration {
        enum Phase { case calibrate, warmup, audio }
        var phase: Phase = .calibrate
        private(set) var delay: Int? = nil
        private(set) var sawSwitch = false
        private(set) var emittedFrames = 0
        private let channels: Int
        private var seed: UInt32 = 0x2545_F491
        private var emitted: [Float] = []     // what went in (one channel; all channels get the same)
        private var received: [Float] = []    // what came out, channel 0
        private var lastLag: Int? = nil
        private var stable = 0
        private var firstLag: Int? = nil
        static let window = 512, maxLag = 24_000, stableChunks = 12
        static let minSeconds = 3.0, maxSeconds = 20.0

        init(channels: Int) { self.channels = channels }

        func emit(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
            let out = UnsafeMutableAudioBufferListPointer(abl)
            for i in 0..<frames {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let v = Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.25
                emitted.append(v)
                for b in out where (i + 1) * MemoryLayout<Float>.size <= Int(b.mDataByteSize) { b.mData?.assumingMemoryBound(to: Float.self)[i] = v }
            }
            emittedFrames += frames
        }

        /// One rendered chunk of output; ends the calibration phase when the delay is settled.
        func observe(_ chunk: UnsafeBufferPointer<Float>, elapsed: TimeInterval) {
            received.append(contentsOf: chunk)
            let w = Self.window
            let o0 = received.count - w
            if o0 >= 0, let lag = match(at: o0) {
                if let f = firstLag, lag != f { sawSwitch = true }
                if firstLag == nil { firstLag = lag }
                stable = lag == lastLag ? stable + 1 : 1
                lastLag = lag
            } else {
                stable = 0
            }
            if stable >= Self.stableChunks, let lag = lastLag, sawSwitch || elapsed >= Self.minSeconds {
                delay = lag; phase = .warmup
            } else if elapsed >= Self.maxSeconds {
                delay = lastLag; phase = .warmup
            }
        }

        /// The lag at which `received[o0..<o0+window]` equals `emitted[o0-lag...]`: near the last lag first, else a full search.
        private func match(at o0: Int) -> Int? {
            let w = Self.window
            func diff(_ lag: Int) -> Double? {
                let s = o0 - lag
                guard s >= 0, s + w <= emitted.count else { return nil }
                var acc = 0.0
                for i in 0..<w { acc += Double(abs(received[o0 + i] - emitted[s + i])); if acc > 0.5 { return acc } }
                return acc / Double(w)
            }
            if let l = lastLag {
                var best = Double.infinity, bestLag = l
                for lag in max(0, l - 4)...(l + 4) { if let d = diff(lag), d < best { best = d; bestLag = lag } }
                if best < 1e-3 { return bestLag }
            }
            var best = Double.infinity, bestLag = -1
            for lag in 0...min(Self.maxLag, o0) { if let d = diff(lag), d < best { best = d; bestLag = lag } }
            return best < 1e-3 ? bestLag : nil
        }
    }

    /// Decoded (interleaved) samples, de-interleaved into the source node's buffers a chunk at a time: the warm-up, then
    /// each piece from its own reader (`open` gives piece i's, nil past the last). The warm-up is the first piece's own
    /// first `warmupFrames` (kept, so they play again as its start) or, with `preroll`, the last `warmupFrames` of the
    /// sound before it (played once, padded with silence at its front when shorter).
    final class Feed {
        let format: AVAudioFormat
        let channels: Int
        let warmupFrames: Int
        private let open: (Int) throws -> (AVAssetReader, AVAssetReaderOutput)?
        private let preroll: (AVAssetReader, AVAssetReaderOutput)?
        private var reader: (AVAssetReader, AVAssetReaderOutput)?
        private var piece = -1
        private var warm: [Float] = []          // interleaved
        private var warmDone = false
        private var headPos = 0, warmPos = 0
        private var pending: AVAudioPCMBuffer?
        private var offset = 0
        private var readerExhausted = false
        private var pieceFill = 0
        private(set) var inputFrames = 0
        /// Frames each finished piece gave, in order.
        private(set) var pieceFrames: [Int] = []
        private(set) var failure: Error?
        /// Every piece has been played to its end (the source now gives zeros).
        var exhausted: Bool { headPos >= replayed && readerExhausted }
        private var replayed: Int { preroll == nil ? warm.count / channels : 0 }

        init(format: AVAudioFormat, channels: Int, warmupFrames: Int, preroll: (AVAssetReader, AVAssetReaderOutput)?,
             open: @escaping (Int) throws -> (AVAssetReader, AVAssetReaderOutput)?) {
            self.format = format; self.channels = channels; self.warmupFrames = warmupFrames; self.preroll = preroll; self.open = open
        }

        private func nextPiece() {
            if let (r, _) = reader, r.status == .failed, failure == nil { failure = r.error ?? EditError.invalid("reading the sound failed") }
            if piece >= 0 { pieceFrames.append(pieceFill); pieceFill = 0 }
            piece += 1; pending = nil; offset = 0
            do {
                reader = try open(piece)
                if reader == nil { readerExhausted = true }
            } catch { failure = error; reader = nil; readerExhausted = true }
        }

        private func prepareWarm() {
            guard !warmDone else { return }
            warmDone = true
            if let (_, o) = preroll {
                var all: [Float] = []
                while let b = nextBuffer(from: o), let p = b.floatChannelData?[0] { all.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(b.frameLength) * channels)) }
                let keep = min(all.count, warmupFrames * channels)
                warm = [Float](repeating: 0, count: warmupFrames * channels - keep) + all.suffix(keep)
                nextPiece()
            } else {
                nextPiece()
                while warm.count / channels < warmupFrames, let (_, o) = reader, let b = nextBuffer(from: o), let p = b.floatChannelData?[0] {
                    warm.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(b.frameLength) * channels))
                }
            }
        }

        private func zero(_ out: UnsafeMutableAudioBufferListPointer) { for b in out { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } } }

        private func copy(_ out: UnsafeMutableAudioBufferListPointer, from src: UnsafePointer<Float>, srcFrame: Int, to dstFrame: Int, count n: Int) {
            for ch in 0..<min(channels, out.count) {
                guard let d = out[ch].mData, (dstFrame + n) * MemoryLayout<Float>.size <= Int(out[ch].mDataByteSize) else { continue }
                let dst = d.assumingMemoryBound(to: Float.self) + dstFrame
                var s = src + srcFrame * channels + ch
                for i in 0..<n { dst[i] = s.pointee; s += channels }
            }
        }

        /// The warm-up, once; zeros past it.
        func fillWarmup(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
            let out = UnsafeMutableAudioBufferListPointer(abl)
            zero(out)
            prepareWarm()
            let n = max(0, min(frames, min(warm.count / channels, warmupFrames) - warmPos))
            if n > 0 { warm.withUnsafeBufferPointer { copy(out, from: $0.baseAddress!, srcFrame: warmPos, to: 0, count: n) } }
            warmPos += n
        }

        /// The pieces from the first one's first frame, one after another; zeros once they are over.
        func fill(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
            let out = UnsafeMutableAudioBufferListPointer(abl)
            zero(out)
            prepareWarm()
            var filled = 0
            if headPos < replayed {
                let n = min(frames, replayed - headPos)
                warm.withUnsafeBufferPointer { copy(out, from: $0.baseAddress!, srcFrame: headPos, to: 0, count: n) }
                headPos += n; filled += n; inputFrames += n; pieceFill += n
            }
            while filled < frames && !readerExhausted {
                if pending == nil || offset >= Int(pending!.frameLength) {
                    guard let (_, o) = reader, let next = nextBuffer(from: o) else { nextPiece(); continue }
                    pending = next; offset = 0
                }
                guard let p = pending, let src = p.floatChannelData?[0] else { break }
                let n = min(frames - filled, Int(p.frameLength) - offset)
                copy(out, from: src, srcFrame: offset, to: filled, count: n)
                filled += n; offset += n; inputFrames += n; pieceFill += n
            }
        }

        func cancel() { reader?.0.cancelReading(); preroll?.0.cancelReading() }

        private func nextBuffer(from output: AVAssetReaderOutput) -> AVAudioPCMBuffer? {
            while let sb = output.copyNextSampleBuffer() {
                let n = CMSampleBufferGetNumSamples(sb)
                guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { continue }
                buf.frameLength = AVAudioFrameCount(n)
                let err = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
                guard err == noErr else { continue }
                return buf
            }
            return nil
        }
    }
}
