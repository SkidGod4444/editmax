import XCTest
import AVFoundation
import AppKit
import MCP
@testable import EditMax

/// describe_video: shots, segments, what each picture shows, the camera move, the sound, the contact sheet and the cache.
@MainActor
final class VideoContextTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }
    private var dir: URL!

    override func setUp() async throws {
        doc = EditMaxDocument()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("video-context-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        VideoContext.Cache.directoryOverride = dir.appendingPathComponent("cache")
    }
    override func tearDown() async throws {
        VideoContext.Cache.directoryOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }
    private func message(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }

    func testDescribesShotsSegmentsPicturesAndSheet() async throws {
        let url = dir.appendingPathComponent("shots.mp4")
        try await EditingTestVideo.write(to: url, seconds: 6, width: 320, height: 180, cuts: [2, 4])
        let a = try await MediaImporter.probe(url); doc.project.assets.append(a)

        let (info, png) = try await x.describeVideo(asset: a.id.short, clip: nil, sensitivity: nil, sheet: true, maxWidth: 800, transcript: false, language: nil)
        XCTAssertEqual(info.kind, "video")
        XCTAssertEqual(info.shots, 3, "\(info.cuts)")
        XCTAssertEqual(info.cuts.count, 2)
        for (c, want) in zip(info.cuts, [2.0, 4.0]) { XCTAssertEqual(c, want, accuracy: 1.0 / 30 + 1e-6) }
        XCTAssertEqual(info.media.width, 320); XCTAssertEqual(info.media.height, 180)
        XCTAssertEqual(info.media.codec, "H.264")
        XCTAssertEqual(info.media.fps ?? 0, 30, accuracy: 0.01)
        XCTAssertNil(info.audio, "the test file has no sound")
        XCTAssertTrue(info.summary.contains("3 shots"), info.summary)

        // Segments cover the range in order, each shot at least once, and every picture is described.
        XCTAssertEqual(Set(info.segments.map(\.shot)), [1, 2, 3])
        XCTAssertEqual(info.segments.first!.start, 0, accuracy: 1e-6)
        XCTAssertEqual(info.segments.last!.end, 6, accuracy: 0.05)
        for (s, next) in zip(info.segments, info.segments.dropFirst()) { XCTAssertEqual(s.end, next.start, accuracy: 1e-6) }
        for s in info.segments {
            let frame = try XCTUnwrap(s.frame, "segment \(s)")
            XCTAssertTrue(frame >= s.start - 0.15 && frame <= s.end + 0.15, "\(frame) outside \(s.start)–\(s.end)")
            XCTAssertNotNil(s.brightness); XCTAssertNotNil(s.color); XCTAssertNotNil(s.camera)
            XCTAssertGreaterThan(s.motion, 0, "the disc moves inside every shot")
            XCTAssertLessThan(s.motion, 0.2)
        }
        // The shots are red, green and blue-ish at 0.7 saturation (EditingTestVideo's hues 0, 0.33, 0.62).
        let colors = info.segments.map { $0.color ?? "" }
        XCTAssertTrue(colors.first!.hasPrefix("red"), "\(colors)")
        XCTAssertTrue(colors.last!.contains("blue") || colors.last!.contains("azure") || colors.last!.contains("cyan"), "\(colors)")

        let sheet = try XCTUnwrap(png)
        let img = try XCTUnwrap(NSBitmapImageRep(data: sheet))
        XCTAssertEqual(img.pixelsWide, 800)
        XCTAssertGreaterThan(img.pixelsHigh, 100)

        // Asking again reads the cache.
        let started = Date()
        let (again, png2) = try await x.describeVideo(asset: a.id.short, clip: nil, sensitivity: nil, sheet: true, maxWidth: 800, transcript: false, language: nil)
        XCTAssertEqual(again.cached, true)
        XCTAssertEqual(again.segments, info.segments)
        XCTAssertEqual(png2, sheet)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        // Without the sheet: no image, same description.
        let (bare, none) = try await x.describeVideo(asset: a.id.short, clip: nil, sensitivity: nil, sheet: false, maxWidth: nil, transcript: false, language: nil)
        XCTAssertNil(none); XCTAssertEqual(bare.shots, 3)
    }

    func testClipGivesItsSourceRangeWithTimelineTimes() async throws {
        let url = dir.appendingPathComponent("clip.mp4")
        try await EditingTestVideo.write(to: url, seconds: 6, width: 320, height: 180, cuts: [2, 4])
        let a = try await MediaImporter.probe(url); doc.project.assets.append(a)
        _ = try x.insertClip(asset: a.id.short, duration: 1)                                  // something before it
        let clip = try x.insertClip(asset: a.id.short, sourceIn: 1, duration: 4)               // source 1–5 at timeline 1–5

        let (info, _) = try await x.describeVideo(asset: nil, clip: clip.id.short, sensitivity: nil, sheet: false, maxWidth: nil, transcript: false, language: nil)
        XCTAssertEqual(info.range[0], 1, accuracy: 1e-6); XCTAssertEqual(info.range[1], 5, accuracy: 1e-6)
        XCTAssertEqual(info.shots, 3)
        let first = try XCTUnwrap(info.segments.first?.timeline), last = try XCTUnwrap(info.segments.last?.timeline)
        XCTAssertEqual(first[0], 1, accuracy: 1e-3)
        XCTAssertEqual(last[1], 5, accuracy: 0.05)
        XCTAssertEqual(doc.project.allClips.count, 2, "describing changes nothing")

        do { _ = try await x.describeVideo(asset: a.id.short, clip: clip.id.short, sensitivity: nil, sheet: false, maxWidth: nil, transcript: false, language: nil); XCTFail("both given") }
        catch { XCTAssertTrue(message(error).contains("one of them"), message(error)) }
        do { _ = try await x.describeVideo(asset: a.id.short, clip: nil, sensitivity: 2, sheet: false, maxWidth: nil, transcript: false, language: nil); XCTFail("sensitivity 2") }
        catch { XCTAssertTrue(message(error).contains("0...1"), message(error)) }
        do { _ = try await x.describeVideo(asset: a.id.short, clip: nil, sensitivity: nil, sheet: true, maxWidth: 100, transcript: false, language: nil); XCTFail("max_width 100") }
        catch { XCTAssertTrue(message(error).contains("320 to 4096"), message(error)) }
    }

    func testCameraMoveFromTheMovingPicture() async throws {
        let right = dir.appendingPathComponent("pan-right.mp4"), up = dir.appendingPathComponent("tilt-up.mp4"), still = dir.appendingPathComponent("still.mp4")
        try await Self.writePan(to: right, velocity: CGVector(dx: 60, dy: 0))    // the view slides right over the texture: a pan right
        try await Self.writePan(to: up, velocity: CGVector(dx: 0, dy: 40))       // the view slides up (y up): a tilt up
        try await Self.writePan(to: still, velocity: .zero)
        let r = try await VideoContext.describe(url: right, sheet: false).0.segments.compactMap(\.camera)
        let u = try await VideoContext.describe(url: up, sheet: false).0.segments.compactMap(\.camera)
        let s = try await VideoContext.describe(url: still, sheet: false).0.segments.compactMap(\.camera)
        XCTAssertFalse(r.isEmpty); XCTAssertFalse(u.isEmpty); XCTAssertFalse(s.isEmpty)
        XCTAssertTrue(r.allSatisfy { $0 == "pans right" }, "\(r)")
        XCTAssertTrue(u.allSatisfy { $0 == "tilts up" }, "\(u)")
        XCTAssertTrue(s.allSatisfy { $0 == "static" }, "\(s)")
    }

    func testCameraMoveWords() {
        XCTAssertEqual(VideoContext.cameraMove(dx: -0.2, dy: 0), "pans right")
        XCTAssertEqual(VideoContext.cameraMove(dx: 0.2, dy: 0.01), "pans left")
        XCTAssertEqual(VideoContext.cameraMove(dx: 0, dy: 0.2), "tilts up")
        XCTAssertEqual(VideoContext.cameraMove(dx: 0.01, dy: -0.15), "tilts down")
        XCTAssertEqual(VideoContext.cameraMove(dx: -0.2, dy: 0.15), "pans right, tilts up")
        XCTAssertEqual(VideoContext.cameraMove(dx: 0.02, dy: -0.03), "static")
        XCTAssertEqual(VideoContext.proResBits(kCMVideoCodecType_AppleProRes422HQ), 10)
        XCTAssertEqual(VideoContext.proResBits(kCMVideoCodecType_AppleProRes4444), 12)
        XCTAssertNil(VideoContext.proResBits(kCMVideoCodecType_HEVC))
    }

    func testSegmentsSplitLongShotsAndPickSpreadsEvenly() {
        // A 60 s single shot is cut into 24 parts of 2.5 s; a 1 s shot stays whole.
        let long = VideoContext.plan(start: 0, end: 60, cuts: [], times: [], diffs: [])
        XCTAssertEqual(long.count, 24); XCTAssertTrue(long.allSatisfy { $0.shot == 1 })
        XCTAssertEqual(long[1].start, 2.5, accuracy: 1e-6)
        let mixed = VideoContext.plan(start: 0, end: 10, cuts: [1], times: [], diffs: [])
        XCTAssertEqual(mixed.first.map { [$0.start, $0.end] }, [0, 1])
        XCTAssertEqual(mixed.filter { $0.shot == 2 }.count, 5, "9 s at a 2 s target: 5 parts of 1.8 s")
        XCTAssertEqual(VideoContext.pick(5, max: 48), [0, 1, 2, 3, 4])
        let spread = VideoContext.pick(100, max: 5)
        XCTAssertEqual(spread, [0, 25, 50, 74, 99])
    }

    func testSoundAndSpeech() async throws {
        let url = dir.appendingPathComponent("tone.m4a")
        try await Self.writeTone(to: url, seconds: 4, silentAfter: 2)
        let (info, png) = try await VideoContext.describe(url: url, sheet: true)
        XCTAssertEqual(info.kind, "audio"); XCTAssertNil(png); XCTAssertTrue(info.segments.isEmpty)
        let audio = try XCTUnwrap(info.audio)
        XCTAssertEqual(audio.silent, 0.5, accuracy: 0.15, "\(audio.levels)")
        XCTAssertGreaterThan(audio.integrated, -30); XCTAssertLessThan(audio.integrated, -6)
        XCTAssertTrue(info.summary.contains("LUFS"), info.summary)

        let words = [TranscriptWord(text: "hello", start: 0.5, end: 0.9), TranscriptWord(text: "there", start: 1.0, end: 1.4), TranscriptWord(text: "later", start: 9, end: 9.5)]
        let sp = VideoContext.speech(words, from: 0, to: 4)
        XCTAssertEqual(sp.words, 2); XCTAssertEqual(sp.text, "hello there"); XCTAssertEqual(sp.coverage, 0.2, accuracy: 1e-6)
    }

    func testPathNeedsNoProjectAndRefusesFoldersAndImages() async throws {
        let url = dir.appendingPathComponent("loose.mp4")
        try await EditingTestVideo.write(to: url, seconds: 3, width: 320, height: 180, cuts: [1.5])
        let (info, _) = try await ToolExecutor.describeFile(path: url.path, sensitivity: nil, sheet: false, maxWidth: nil, transcript: false, language: nil)
        XCTAssertEqual(info.shots, 2); XCTAssertEqual(info.file, "loose.mp4")
        do { _ = try await ToolExecutor.describeFile(path: dir.path, sensitivity: nil, sheet: false, maxWidth: nil, transcript: false, language: nil); XCTFail("folder") }
        catch { XCTAssertTrue(message(error).contains("folder"), message(error)) }
        let png = dir.appendingPathComponent("still.png"); try Data([0x89, 0x50]).write(to: png)
        do { _ = try await ToolExecutor.describeFile(path: png.path, sensitivity: nil, sheet: false, maxWidth: nil, transcript: false, language: nil); XCTFail("image") }
        catch { XCTAssertTrue(message(error).contains("image"), message(error)) }

        // Over MCP the path form runs with no project open, and the catalog marks the tool read-only.
        let tool = try XCTUnwrap(EditMaxTools.tools.first { $0.name == "describe_video" })
        XCTAssertEqual(tool.annotations.readOnlyHint, true)
        let payload = try await EditMaxTools.call("describe_video", ["path": .string(url.path), "max_width": .int(640)])
        XCTAssertTrue(payload.text.contains("\"shots\" : 2"), String(payload.text.prefix(300)))
        XCTAssertNotNil(payload.image); XCTAssertEqual(payload.imageType, "image/jpeg")
    }

    // MARK: Fixtures

    /// A 320×180 view moving over a large random-block texture at `velocity` points per second (y up, as CGContext draws).
    static func writePan(to url: URL, velocity: CGVector, seconds: Double = 3, fps: Int32 = 30) async throws {
        try? FileManager.default.removeItem(at: url)
        let width = 320, height = 180
        var rng = SystemRandomNumberGenerator()
        let tw = 900, th = 600
        let texture = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for by in stride(from: 0, to: th, by: 12) { for bx in stride(from: 0, to: tw, by: 12) {
            texture.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng), blue: .random(in: 0...1, using: &rng), alpha: 1))
            texture.fill(CGRect(x: bx, y: by, width: 12, height: 12))
        } }
        let image = texture.makeImage()!
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        w.add(input)
        guard w.startWriting() else { throw w.error ?? EditError.invalid("writer") }
        w.startSession(atSourceTime: .zero)
        for f in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let t = Double(f) / Double(fps)
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let px = pb else { throw EditError.invalid("pixel buffer") }
            CVPixelBufferLockBaseAddress(px, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(px), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(px),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            // The view's origin over the texture: it moves with the velocity, so the texture is drawn at minus that.
            let ox = 200 + velocity.dx * t, oy = 200 + velocity.dy * t
            ctx.draw(image, in: CGRect(x: -ox, y: -oy, width: Double(tw), height: Double(th)))
            CVPixelBufferUnlockBaseAddress(px, [])
            adaptor.append(px, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
        }
        input.markAsFinished()
        await w.finishWriting()
        if w.status != .completed { throw w.error ?? EditError.invalid("writer status \(w.status.rawValue)") }
    }

    /// A 440 Hz tone at -12 dBFS for `silentAfter` seconds, then silence.
    static func writeTone(to url: URL, seconds: Double, silentAfter: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
        let frames = AVAudioFrameCount(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let amp = Float(pow(10, -12.0 / 20))
        for c in 0..<2 { for i in 0..<Int(frames) {
            let t = Double(i) / rate
            buf.floatChannelData![c][i] = t < silentAfter ? amp * Float(sin(2 * .pi * 440 * t)) : 0
        } }
        try file.write(from: buf)
    }
}
