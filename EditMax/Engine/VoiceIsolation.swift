import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import Combine

/// Voice isolation (dialogue cleanup) rendered ahead of time: an asset's sound is run once through Apple's
/// `AUSoundIsolation` audio unit offline (AVAudioEngine in manual rendering mode) and the result is kept in
/// Application Support, keyed by the file's path, size and modification date plus the amount (10 % steps).
/// The composition builder plays the isolated file in place of the original sound when it exists; the export
/// renders every missing one first (`ensureAll`). Nothing runs inside the real-time audio tap.
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

    private var inFlight: [String: Task<URL, Error>] = [:]
    private var scheduled: [UUID: Task<Void, Never>] = [:]

    nonisolated static let sampleRate = 48_000.0
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

    func ready(for asset: Asset, amount: Double) -> URL? { Self.readyURL(for: asset, amount: amount) }
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

    /// The isolated file for an asset at an amount, rendering it first when the cache has none. Concurrent calls for
    /// the same key share one render.
    func ensure(_ asset: Asset, amount: Double) async throws -> URL {
        let p = Self.pct(amount)
        guard p > 0 else { throw EditError.invalid("voice isolation amount is 0") }
        guard asset.kind != .image else { throw EditError.invalid("'\(asset.name)' is an image; it has no sound") }
        guard asset.sequenceID == nil else { throw EditError.invalid(Self.sequenceMessage) }
        let url = Self.url(for: asset, amount: amount)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let k = Self.key(for: asset, amount: amount)
        if let t = inFlight[k] { return try await t.value }
        guard Self.isAvailable else { throw EditError.invalid(Self.unavailableMessage) }
        guard FileManager.default.fileExists(atPath: asset.path) else { throw EditError.notFound("'\(asset.name)' at \(asset.path)") }
        rendering.insert(k); progress[k] = 0; failed[k] = nil
        let source = asset.url, name = asset.name
        let task = Task<URL, Error> {
            let started = Date()
            let cancel = CancelFlag()
            let report: @Sendable (Double) -> Void = { f in Task { @MainActor in self.progress[k] = f } }
            return try await withTaskCancellationHandler {
                try await Self.render(source: source, to: url, pct: p, cancel: cancel, progress: report)
                DebugLog.event("voice-isolation", ["asset": name, "key": k, "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
                return url
            } onCancel: { cancel.cancelled = true }
        }
        inFlight[k] = task
        defer { inFlight[k] = nil; rendering.remove(k); progress[k] = nil }
        do {
            let out = try await task.value
            version += 1
            return out
        } catch {
            failed[k] = error.localizedDescription
            DebugLog.error("voice-isolation-failed", error, ["asset": name, "key": k])
            throw error
        }
    }

    /// Renders after a short quiet period, so a slider drag (one call per step) ends in one render, not ten.
    func schedule(_ asset: Asset, amount: Double, delay: Duration = .milliseconds(500)) {
        scheduled[asset.id]?.cancel()
        guard Self.pct(amount) > 0 else { return }
        scheduled[asset.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            _ = try? await self.ensure(asset, amount: amount)
        }
    }

    /// Renders the isolated sound of every clip that asks for it (the export calls this before building).
    func ensureAll(_ project: Project) async throws {
        var done: Set<String> = []
        for clip in project.tracks.flatMap({ $0.clips.flatMap { $0.multicamPieces(in: project) } }) where clip.audio.needsIsolation {
            guard let asset = Self.audioAsset(of: clip, in: project), Self.eligible(asset) else { continue }
            let k = Self.key(for: asset, amount: clip.audio.voiceIsolation)
            guard !done.contains(k) else { continue }
            done.insert(k)
            _ = try await ensure(asset, amount: clip.audio.voiceIsolation)
        }
    }

    /// Caption for the inspector: what the slider does, and this asset's state at the current amount.
    func caption(for asset: Asset?, amount: Double) -> String {
        let base = "Keeps the speech and drops room noise and background (Apple's voice isolator). Renders on this Mac once per file and amount."
        guard let asset, Self.pct(amount) > 0 else { return base }
        let k = Self.key(for: asset, amount: amount)
        if rendering.contains(k) { let f = progress[k] ?? 0; return base + " Rendering… \(Int((f * 100).rounded()))%" }
        if ready(for: asset, amount: amount) != nil { return base + " Ready: the preview and the export play the isolated sound." }
        if let e = failed[k] { return base + " Failed: \(e)" }
        if !Self.isAvailable { return base + " " + Self.unavailableMessage }
        return base + " Waiting to render…"
    }

    /// A render cancellation flag shared with the blocking loop.
    final class CancelFlag: @unchecked Sendable { var cancelled = false }

    /// Decodes the asset's sound (48 kHz float, 1 or 2 channels) through an AVAssetReader, runs it through AUSoundIsolation
    /// in an offline AVAudioEngine and writes a PCM .caf of exactly the decoded frame count, lined up sample for sample
    /// with the source. The unit's delay is measured on the very instance that renders (`Calibration`: it changes once
    /// the model has loaded, at a frame that depends on wall-clock timing), then the first half second of the recording
    /// warms the model up, then the recording plays from its first frame; everything before that plus the measured delay
    /// is dropped from the output and the tail is flushed to the exact length. Blocks a utility-queue thread, never the caller's.
    nonisolated static func render(source: URL, to url: URL, pct: Int, cancel: CancelFlag, progress: @escaping @Sendable (Double) -> Void) async throws {
        let av = AVURLAsset(url: source)
        guard let track = try await av.loadTracks(withMediaType: .audio).first else { throw EditError.invalid("'\(source.lastPathComponent)' has no audio track") }
        var srcChannels = 2
        if let fd = try await track.load(.formatDescriptions).first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            srcChannels = Int(asbd.pointee.mChannelsPerFrame)
        }
        let seconds = try await track.load(.timeRange).duration.seconds
        let channels = AVAudioChannelCount(max(1, min(2, srcChannels)))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do { try renderBlocking(asset: av, track: track, channels: channels, seconds: seconds, to: url, pct: pct, cancel: cancel, progress: progress); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Warm-up: this many frames of the recording's own start are played (and dropped) before the recording itself.
    nonisolated static let warmupFrames = 6 * Int(chunk)

    nonisolated private static func renderBlocking(asset av: AVURLAsset, track: AVAssetTrack, channels: AVAudioChannelCount, seconds: Double, to url: URL, pct: Int,
                                                   cancel: CancelFlag, progress: @escaping @Sendable (Double) -> Void) throws {
        let name = av.url.lastPathComponent
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
              let readFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: true) else { throw EditError.invalid("audio format") }
        let expected = max(1.0, (seconds.isFinite ? seconds : 0) * sampleRate)

        let reader = try AVAssetReader(asset: av)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EditError.invalid("cannot read the sound of '\(name)'") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError.invalid("cannot read '\(name)'") }

        // The source: calibration noise, then the recording's own first frames as a warm-up, then the recording.
        // Manual rendering runs the block synchronously on this thread, so the decoder is pulled on demand.
        let feed = Feed(output: output, format: readFmt, channels: Int(channels), headFrames: warmupFrames)
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

        // 2. Warm-up: the requested mix, the recording's first half second (dropped).
        AudioUnitSetParameter(effect.audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, AudioUnitParameterValue(pct), 0)
        cal.phase = .warmup
        var warmed = 0
        while warmed < warmupFrames {
            if cancel.cancelled { throw CancellationError() }
            let status = try engine.renderOffline(chunk, to: out)
            guard status == .success, out.frameLength > 0 else { throw EditError.invalid("the voice isolator stopped rendering (\(status.rawValue))") }
            warmed += Int(out.frameLength)
        }
        cal.phase = .audio

        // 3. The recording: drop `delay` frames, write exactly the decoded frame count.
        let tmp = url.deletingPathExtension().appendingPathExtension("part.caf")
        try? FileManager.default.removeItem(at: tmp)
        let file = try AVAudioFile(forWriting: tmp, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: Int(channels),
                                                                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        var skipped = 0, written = 0, lastReport = Date.distantPast
        do {
            while true {
                if cancel.cancelled { throw CancellationError() }
                if reader.status == .failed { throw reader.error ?? EditError.invalid("reading '\(name)' failed") }
                let status = try engine.renderOffline(chunk, to: out)
                guard status == .success, out.frameLength > 0 else { throw EditError.invalid("the voice isolator stopped rendering (\(status.rawValue))") }
                var offset = 0, frames = Int(out.frameLength)
                if skipped < delay { let s = min(delay - skipped, frames); skipped += s; offset += s; frames -= s }
                if feed.exhausted { frames = min(frames, feed.inputFrames - written) }
                if frames > 0 {
                    for ch in 0..<Int(channels) { slice.floatChannelData![ch].update(from: out.floatChannelData![ch] + offset, count: frames) }
                    slice.frameLength = AVAudioFrameCount(frames)
                    try file.write(from: slice)
                    written += frames
                }
                if feed.exhausted && written >= feed.inputFrames { break }
                if Date().timeIntervalSince(lastReport) > 0.5 { lastReport = Date(); progress(min(0.99, Double(written) / expected)) }
            }
            guard feed.inputFrames > 0 else { throw EditError.invalid("'\(name)' has no sound to isolate") }
        } catch {
            reader.cancelReading()
            file.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        file.close()
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        DebugLog.event("voice-isolation-render", ["file": name, "delay": delay, "reported": reported, "calibrationFrames": cal.emittedFrames, "switched": cal.sawSwitch, "frames": written])
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

    /// Decoded (interleaved) samples from the asset reader, de-interleaved into the source node's buffers a chunk at a
    /// time. The first `headFrames` are kept, so they can be played once as a warm-up and again as the recording's start.
    final class Feed {
        let output: AVAssetReaderOutput
        let format: AVAudioFormat
        let channels: Int
        let headFrames: Int
        private var head: [Float] = []          // interleaved
        private var headDone = false
        private var headPos = 0, warmPos = 0
        private var pending: AVAudioPCMBuffer?
        private var offset = 0
        private var readerExhausted = false
        private(set) var inputFrames = 0
        /// The recording has been played to its end (the source now gives zeros).
        var exhausted: Bool { headPos >= head.count / channels && readerExhausted }

        init(output: AVAssetReaderOutput, format: AVAudioFormat, channels: Int, headFrames: Int) {
            self.output = output; self.format = format; self.channels = channels; self.headFrames = headFrames
        }

        private func decodeHead() {
            guard !headDone else { return }
            while head.count / channels < headFrames, let b = nextBuffer(), let p = b.floatChannelData?[0] {
                head.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(b.frameLength) * channels))
            }
            if head.count / channels < headFrames { readerExhausted = true }
            headDone = true
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

        /// The recording's first frames, once; zeros past them.
        func fillWarmup(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
            let out = UnsafeMutableAudioBufferListPointer(abl)
            zero(out)
            decodeHead()
            let avail = head.count / channels
            let n = max(0, min(frames, avail - warmPos))
            if n > 0 { head.withUnsafeBufferPointer { copy(out, from: $0.baseAddress!, srcFrame: warmPos, to: 0, count: n) } }
            warmPos += n
        }

        /// The recording from its first frame: the kept head, then the decoder; zeros once it is over.
        func fill(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
            let out = UnsafeMutableAudioBufferListPointer(abl)
            zero(out)
            decodeHead()
            var filled = 0
            let avail = head.count / channels
            if headPos < avail {
                let n = min(frames, avail - headPos)
                head.withUnsafeBufferPointer { copy(out, from: $0.baseAddress!, srcFrame: headPos, to: 0, count: n) }
                headPos += n; filled += n; inputFrames += n
            }
            while filled < frames && !readerExhausted {
                if pending == nil || offset >= Int(pending!.frameLength) {
                    guard let next = nextBuffer() else { readerExhausted = true; break }
                    pending = next; offset = 0
                }
                guard let p = pending, let src = p.floatChannelData?[0] else { break }
                let n = min(frames - filled, Int(p.frameLength) - offset)
                copy(out, from: src, srcFrame: offset, to: filled, count: n)
                filled += n; offset += n; inputFrames += n
            }
        }

        private func nextBuffer() -> AVAudioPCMBuffer? {
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
