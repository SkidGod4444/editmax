import XCTest
import AVFoundation
@testable import EditMax

/// The isolated-voice file: Apple Lossless instead of 16-bit PCM (half the disk for speech), the same samples and the
/// same exact length, and a render that could fill the disk is refused before it starts.
final class VoiceIsolationFileTests: XCTestCase {
    typealias S = TestSignal

    func testAppleLosslessGivesBackEveryFrameOfSixteenBitPCMAtAboutHalfTheSizeForSpeech() throws {
        // 10 s of speech-like sound, an odd length (not a whole number of 4096-frame packets).
        let n = 480_000 + 1234
        let a = Array(S.voice(seconds: 11, level: 0.2).prefix(n)), b = Array(S.voice(seconds: 11, level: 0.2, seed: 3).prefix(n))
        func write(_ settings: [String: Any], _ name: String) throws -> URL {
            let url = S.scratch.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            a.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
            b.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: n) }
            try f.write(from: buf)
            return url
        }
        let pcm = try write([AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                             AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false], "iso-pcm.caf")
        let alac = try write(IsolatedAudio.fileSettings(channels: 2), "iso-alac.caf")
        func read(_ url: URL) throws -> (frames: Int, l: [Float], r: [Float]) {
            let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try f.read(into: buf)
            let k = Int(buf.frameLength)
            return (Int(f.length), Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: k)), Array(UnsafeBufferPointer(start: buf.floatChannelData![1], count: k)))
        }
        let p = try read(pcm), l = try read(alac)
        XCTAssertEqual(l.frames, n, "exactly the frames written: no priming, no padding")
        XCTAssertEqual(p.frames, n)
        XCTAssertEqual(l.l, p.l, "lossless: the same 16-bit samples")
        XCTAssertEqual(l.r, p.r)
        let size = { (u: URL) in Double((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        print("ISO-FILE pcm \(Int(size(pcm) / 1000)) KB, alac \(Int(size(alac) / 1000)) KB")
        XCTAssertLessThan(size(alac), size(pcm) * 0.75)
    }

    func testARenderThatCouldFillTheDiskIsRefused() throws {
        let need = IsolatedAudio.diskNeeded(seconds: 18 * 3600, channels: 2)
        XCTAssertEqual(Double(need) / 1e9, 12.69 + 0.5, accuracy: 0.1, "18 h stereo: 12.4 GB of 16-bit samples, 2 % over, 0.5 GB spare")
        XCTAssertThrowsError(try IsolatedAudio.checkDisk(needed: need, free: 4_600_000_000, name: "stream.mp4")) { e in
            XCTAssertTrue("\(e.localizedDescription)".contains("13.2 GB"), e.localizedDescription)
            XCTAssertTrue("\(e.localizedDescription)".contains("4.6 GB is free"), e.localizedDescription)
        }
        XCTAssertNoThrow(try IsolatedAudio.checkDisk(needed: IsolatedAudio.diskNeeded(seconds: 600, channels: 2), free: 4_600_000_000, name: "talk.mp4"))
    }

    /// Isolated sound is kept in blocks of the source and joined on the source's timeline by a composition, which the
    /// timeline's composition then reads like a file: what this relies on is that one composition can be the source of
    /// another, sample for sample, with a missing block reading as silence.
    func testACompositionOfBlocksIsTheSourceOfAnotherSampleForSample() async throws {
        let a = S.sine(440, seconds: 2, dbfs: -12), b = S.sine(880, seconds: 2, dbfs: -12)
        let fa = AVURLAsset(url: try S.writeWAV([a, a], to: S.scratch.appendingPathComponent("stitch-a.wav")))
        let fb = AVURLAsset(url: try S.writeWAV([b, b], to: S.scratch.appendingPathComponent("stitch-b.wav")))
        let ta = try await fa.loadTracks(withMediaType: .audio)[0], tb = try await fb.loadTracks(withMediaType: .audio)[0]
        let sec = { (x: Double) in CMTime(value: CMTimeValue(x * 48_000), timescale: 48_000) }
        // The blocks: a at 0–2 s, nothing at 2–4 s, b at 4–6 s.
        let stitch = AVMutableComposition()
        let st = try XCTUnwrap(stitch.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try st.insertTimeRange(CMTimeRange(start: .zero, duration: sec(2)), of: ta, at: .zero)
        st.insertEmptyTimeRange(CMTimeRange(start: sec(2), duration: sec(2)))
        try st.insertTimeRange(CMTimeRange(start: .zero, duration: sec(2)), of: tb, at: sec(4))
        // The timeline reads 1–5 s of it, as it would read a clip's source range.
        let outer = AVMutableComposition()
        let ot = try XCTUnwrap(outer.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try ot.insertTimeRange(CMTimeRange(start: sec(1), duration: sec(4)), of: try await stitch.loadTracks(withMediaType: .audio)[0], at: .zero)
        defer { withExtendedLifetime([fa, fb, stitch] as [AnyObject]) {} }   // a composition does not keep its sources alive
        let got = try await Self.readStereo(outer)
        XCTAssertEqual(got.count / 2, 4 * 48_000)
        let left = stride(from: 0, to: got.count, by: 2).map { got[$0] }
        func close(_ x: ArraySlice<Float>, _ y: ArraySlice<Float>) -> Bool { zip(x, y).allSatisfy { abs($0 - $1) < 1e-4 } }
        XCTAssertTrue(close(left[0..<48_000], a[48_000..<96_000]), "a's second second")
        XCTAssertTrue(left[48_000..<144_000].allSatisfy { $0 == 0 }, "the missing block is silence")
        XCTAssertTrue(close(left[144_000..<192_000], b[0..<48_000]), "b's first second")
    }

    /// The plumbing, exactly. With the isolator dry (amount 0) a render is the source delayed with the delay taken out,
    /// so every block must be its own stretch of the source sample for sample: the first block (warmed on its own head),
    /// two neighbours in one pass, and a neighbour rendered later on its own (warmed on the sound before it).
    func testEachBlockIsExactlyItsStretchOfTheSourceWithTheIsolatorDry() async throws {
        guard IsolatedAudio.isAvailable else { throw XCTSkip(IsolatedAudio.unavailableMessage) }
        let sr = 48_000, n = 20 * sr + 321
        let a = Array(S.voice(seconds: 21, level: 0.2).prefix(n)), b = Array(S.voice(seconds: 21, level: 0.2, seed: 5).prefix(n))
        let src = try S.writeWAV([a, b], to: S.scratch.appendingPathComponent("iso-dry-src.wav"))
        let url = { (name: String) -> URL in let u = S.scratch.appendingPathComponent(name); try? FileManager.default.removeItem(at: u); return u }
        let head = url("iso-dry-0.caf"), one = url("iso-dry-8.caf"), two = url("iso-dry-11.caf"), later = url("iso-dry-11-later.caf"), tail = url("iso-dry-17.caf")
        let run = { (pieces: [IsolatedAudio.Piece]) in try await IsolatedAudio.render(source: src, pieces: pieces, pct: 0, cancel: IsolatedAudio.CancelFlag(), progress: { _ in }) }
        try await run([.init(start: 0, end: 5, url: head)])
        try await run([.init(start: 8, end: 11, url: one), .init(start: 11, end: 14, url: two)])
        try await run([.init(start: 11, end: 14, url: later)])
        try await run([.init(start: 17, end: nil, url: tail)])   // to the end of the sound
        for (file, from, to) in [(head, 0, 5 * sr), (one, 8 * sr, 11 * sr), (two, 11 * sr, 14 * sr), (later, 11 * sr, 14 * sr), (tail, 17 * sr, n)] {
            let f = try Self.readFile(file)
            XCTAssertEqual(f.frames, to - from, file.lastPathComponent)
            let worst = max(zip(f.l, a[from..<to]).map { abs($0 - $1) }.max() ?? 1, zip(f.r, b[from..<to]).map { abs($0 - $1) }.max() ?? 1)
            XCTAssertLessThan(worst, 1.0 / 32_768, "\(file.lastPathComponent): the source's own samples (16-bit)")
        }
    }

    /// The real unit at full strength: a block rendered on its own gives the same isolated sound as a render of the whole
    /// file over its stretch. Not the same samples: the unit is not repeatable (its model loads at a moment that depends
    /// on wall-clock timing), and two renders of the whole file differ by as much (measured −39 to −62 dB against a −33
    /// dB signal); a block lands in the same range. Lined up (no lag) and well under the signal's level.
    func testABlockRenderedOnItsOwnSoundsLikeTheSameStretchOfAWholeRender() async throws {
        guard IsolatedAudio.isAvailable else { throw XCTSkip(IsolatedAudio.unavailableMessage) }
        let sr = 48_000, n = 20 * sr
        let a = Array(S.voice(seconds: 21, level: 0.2).prefix(n)), b = Array(S.voice(seconds: 21, level: 0.2, seed: 5).prefix(n))
        let src = try S.writeWAV([a, b], to: S.scratch.appendingPathComponent("iso-range-src.wav"))
        let url = { (name: String) -> URL in let u = S.scratch.appendingPathComponent(name); try? FileManager.default.removeItem(at: u); return u }
        let whole = url("iso-range-whole.caf"), again = url("iso-range-whole2.caf"), block = url("iso-range-11.caf")
        try await IsolatedAudio.render(source: src, to: whole, pct: 100, cancel: IsolatedAudio.CancelFlag(), progress: { _ in })
        try await IsolatedAudio.render(source: src, to: again, pct: 100, cancel: IsolatedAudio.CancelFlag(), progress: { _ in })
        try await IsolatedAudio.render(source: src, pieces: [.init(start: 11, end: 16, url: block)], pct: 100, cancel: IsolatedAudio.CancelFlag(), progress: { _ in })
        let ref = Array(try Self.readFile(whole).l[11 * sr..<16 * sr]), other = Array(try Self.readFile(again).l[11 * sr..<16 * sr])
        let got = try Self.readFile(block)
        XCTAssertEqual(got.frames, 5 * sr)
        let diff = { (x: [Float]) in S.rmsDB(zip(x, ref).map { $0 - $1 }) }
        let level = S.rmsDB(ref), blockOff = diff(got.l), wholeOff = diff(other)
        print(String(format: "ISO-RANGE level %.1f dB; block alone %.1f dB off the whole render; a second whole render %.1f dB off", level, blockOff, wholeOff))
        XCTAssertLessThan(blockOff, level - 3, "the same isolated sound, not shifted or broken")
        // Shifted by any lag, it would match worse.
        let shifted = S.rmsDB(zip(got.l.dropFirst(480), ref).map { $0 - $1 })
        XCTAssertLessThan(blockOff, shifted - 3, "lined up with the whole render")
    }

    /// A file's samples, both channels.
    /// Times one 10-minute block of real speech (how long a clip lengthened into a block not yet rendered plays its
    /// original sound) and measures the seam between two blocks rendered in separate passes against one pass: set
    /// TEST_RUNNER_EDITMAX_SPEECH_FILE to a speech file of 20 min or more.
    func testTimeOneBlockOfSpeechAndTheSeamBetweenSeparatePasses() async throws {
        guard IsolatedAudio.isAvailable else { throw XCTSkip(IsolatedAudio.unavailableMessage) }
        guard let path = ProcessInfo.processInfo.environment["EDITMAX_SPEECH_FILE"] else { throw XCTSkip("no speech file given") }
        let src = URL(fileURLWithPath: path), b = IsolatedAudio.blockSeconds
        let url = { (name: String) -> URL in let u = S.scratch.appendingPathComponent(name); try? FileManager.default.removeItem(at: u); return u }
        let a0 = url("seam-a0.caf"), a1 = url("seam-a1.caf"), p0 = url("seam-p0.caf"), p1 = url("seam-p1.caf")
        defer { for u in [a0, a1, p0, p1] { try? FileManager.default.removeItem(at: u) } }
        let run = { (pieces: [IsolatedAudio.Piece]) -> Double in
            let t = Date()
            try await IsolatedAudio.render(source: src, pieces: pieces, pct: 100, cancel: IsolatedAudio.CancelFlag(), progress: { _ in })
            return Date().timeIntervalSince(t)
        }
        let first = try await run([.init(start: 0, end: b, url: a0)])
        let later = try await run([.init(start: b, end: 2 * b, url: a1)])   // warmed on the 8 s before it
        let both = try await run([.init(start: 0, end: b, url: p0), .init(start: b, end: 2 * b, url: p1)])
        // 50 ms either side of the seam: the step across it, against the sound's own sample-to-sample steps there.
        let w = 2_400
        func seam(_ x: URL, _ y: URL) throws -> (jump: Float, p99: Float, top: Float) {
            let s = try Self.readWindow(x, from: -w, count: w) + Self.readWindow(y, from: 0, count: w)
            var steps = (1..<s.count).filter { $0 != w }.map { abs(s[$0] - s[$0 - 1]) }
            steps.sort()
            return (abs(s[w] - s[w - 1]), steps[steps.count * 99 / 100], steps.last ?? 0)
        }
        let apart = try seam(a0, a1), one = try seam(p0, p1)
        print(String(format: "ISO-BLOCK %.0f s of speech: first block %.1f s (%.0fx real time), a later block on its own %.1f s, two in one pass %.1f s; seam step, separate passes %.5f (sound's own steps there: 99th pct %.5f, top %.5f); one pass %.5f",
                     b, first, b / first, later, both, apart.jump, apart.p99, apart.top, one.jump))
        XCTAssertLessThanOrEqual(apart.jump, max(apart.top, 1e-4), "no step at the seam bigger than the sound makes on its own")
    }

    /// Left channel, `count` frames from `from` (negative: from the end).
    static func readWindow(_ url: URL, from: Int, count: Int) throws -> [Float] {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        f.framePosition = from < 0 ? max(0, f.length + AVAudioFramePosition(from)) : AVAudioFramePosition(from)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(count))!
        try f.read(into: buf, frameCount: AVAudioFrameCount(count))
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    static func readFile(_ url: URL) throws -> (frames: Int, l: [Float], r: [Float]) {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(max(1, f.length)))!
        try f.read(into: buf)
        let k = Int(buf.frameLength), ch = Int(f.processingFormat.channelCount)
        return (Int(f.length), Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: k)), Array(UnsafeBufferPointer(start: buf.floatChannelData![ch - 1], count: k)))
    }

    /// An asset's sound as interleaved stereo float at 48 kHz.
    static func readStereo(_ asset: AVAsset) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                                                                 AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(o)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var out: [Float] = []
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(bb)
            var chunk = [Float](repeating: 0, count: n / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
            out += chunk
        }
        if reader.status == .failed { throw reader.error! }
        return out
    }

    /// The real unit, a short file: the output is Apple Lossless and exactly as long as the source.
    func testAnIsolatedRenderIsAppleLosslessAndExactlyAsLongAsItsSource() async throws {
        guard IsolatedAudio.isAvailable else { throw XCTSkip(IsolatedAudio.unavailableMessage) }
        let n = 3 * 48_000 + 777
        let a = Array(S.voice(seconds: 4, level: 0.2).prefix(n)), b = Array(S.voice(seconds: 4, level: 0.2, seed: 5).prefix(n))
        let src = try S.writeWAV([a, b], to: S.scratch.appendingPathComponent("iso-src.wav"))
        let out = S.scratch.appendingPathComponent("iso-out.caf")
        try? FileManager.default.removeItem(at: out)
        try await IsolatedAudio.render(source: src, to: out, pct: 100, cancel: IsolatedAudio.CancelFlag(), progress: { _ in })
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(Int(f.length), n)
        XCTAssertEqual(f.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatAppleLossless)
        XCTAssertEqual(f.fileFormat.channelCount, 2)
        // The composition plays it as an AVAsset: read it that way too, to the last frame.
        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
        reader.add(o); XCTAssertTrue(reader.startReading())
        var frames = 0
        while let sb = o.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sb) }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(frames, n)
    }
}
