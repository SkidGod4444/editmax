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
