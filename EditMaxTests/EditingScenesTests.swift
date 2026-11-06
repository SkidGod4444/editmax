import XCTest
import AVFoundation
import SwiftUI
@testable import EditMax

/// Generated test videos: shots of distinct colours with a moving disc and a slow brightness drift (so motion inside a
/// shot is not a cut), hard cuts at known times.
enum EditingTestVideo {
    static func write(to url: URL, seconds: Double, fps: Int32 = 30, width: Int = 160, height: Int = 90, cuts: [Double], discSpeed: Double = 70) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        w.add(input)
        guard w.startWriting() else { throw w.error ?? EditError.invalid("writer") }
        w.startSession(atSourceTime: .zero)
        let hues: [Double] = [0.0, 0.33, 0.62, 0.12, 0.8, 0.5]
        let frames = Int(seconds * Double(fps))
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let t = Double(f) / Double(fps)
            let shot = cuts.filter { $0 <= t + 1e-9 }.count
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let px = pb else { throw EditError.invalid("pixel buffer") }
            CVPixelBufferLockBaseAddress(px, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(px), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(px),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let drift = 0.6 + 0.15 * sin(t * 1.3)
            ctx.setFillColor(NSColor(hue: hues[shot % hues.count], saturation: 0.7, brightness: drift, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let x = (t * discSpeed).truncatingRemainder(dividingBy: Double(width + 30)) - 15
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: Double(height) / 2 - 12 + 8 * sin(t * 4), width: 24, height: 24))
            CVPixelBufferUnlockBaseAddress(px, [])
            adaptor.append(px, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
        }
        input.markAsFinished()
        await w.finishWriting()
        if w.status != .completed { throw w.error ?? EditError.invalid("writer status \(w.status.rawValue)") }
    }
}

@MainActor
final class EditingScenesTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }
    private var p: Project { doc.project }
    private var url: URL!

    override func setUp() async throws {
        doc = EditMaxDocument()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("editing-scenes-\(UUID().uuidString.prefix(8)).mp4")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: url) }
    private func message(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }

    func testDetectsKnownCutsAndSplitsOrMarks() async throws {
        let cuts = [1.5, 3.0, 4.2]
        try await EditingTestVideo.write(to: url, seconds: 6, cuts: cuts)
        let a = try await MediaImporter.probe(url); doc.project.assets.append(a)
        let clip = try x.insertClip(asset: a.id.short, sourceIn: 0.5, duration: 5)   // source 0.5–5.5 at timeline 0–5

        let found = try await x.detectScenes(clip: clip.id.short, asset: nil, sensitivity: nil, minScene: nil, action: "none")
        XCTAssertEqual(found.cuts.count, 3, "\(found.cuts)")
        for (c, want) in zip(found.cuts, cuts) {
            XCTAssertEqual(c.source, want, accuracy: 1.0 / 30 + 1e-6)
            XCTAssertEqual(c.timeline!, want - 0.5, accuracy: 1.0 / 30 + 1e-6)
        }
        XCTAssertEqual(p.allClips.count, 1, "action none changes nothing")

        let split = try await x.detectScenes(clip: clip.id.short, asset: nil, sensitivity: nil, minScene: nil, action: "split")
        XCTAssertEqual(split.clips?.count, 4)
        let starts = p.tracks[0].clips.map(\.start)
        XCTAssertEqual(starts.count, 4)
        for (s, want) in zip(starts, [0, 1.0, 2.5, 3.7]) { XCTAssertEqual(s, want, accuracy: 1.0 / 30 + 1e-6) }
        doc.undo()
        XCTAssertEqual(p.allClips.count, 1, "the split is one undo step")

        let marked = try await x.detectScenes(clip: clip.id.short, asset: nil, sensitivity: nil, minScene: nil, action: "markers")
        XCTAssertEqual(marked.markers?.count, 3); XCTAssertEqual(p.markers.map(\.name), ["Scene 2", "Scene 3", "Scene 4"])

        // Low sensitivity still finds these clear cuts; min_scene longer than the shots drops the close ones.
        let strict = try await x.detectScenes(clip: nil, asset: a.id.short, sensitivity: 0.1, minScene: nil, action: nil)
        XCTAssertEqual(strict.cuts.count, 3)
        let sparse = try await x.detectScenes(clip: nil, asset: a.id.short, sensitivity: nil, minScene: 2, action: nil)
        XCTAssertEqual(sparse.cuts.map(\.source).count, 2, "\(sparse.cuts)")   // 1.5 and 4.2 (3.0 is 1.5 s after 1.5)

        // Refusals.
        for (s, act, asset) in [(2.0, "none", false), (0.5, "explode", false), (0.5, "split", true)] {
            do {
                _ = try await x.detectScenes(clip: asset ? nil : clip.id.short, asset: asset ? a.id.short : nil, sensitivity: s, minScene: nil, action: act)
                XCTFail("must refuse sensitivity \(s) action \(act)")
            } catch { XCTAssertFalse(message(error).isEmpty) }
        }

        try writePreview(found: try await SceneDetector.detect(url: url, from: 0.5, to: 5.5), range: 0.5...5.5)
    }

    /// The scan's curve with the picked cuts, and the frames either side of each cut, dark.
    private func writePreview(found: SceneDetector.Result, range: ClosedRange<Double>) throws {
        guard EditingPreviewTests.dir != nil else { return }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        func frame(_ t: Double) -> CGImage? { try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) }
        let pairs = found.cuts.map { c in (c, frame(c.time - 1.0 / 30), frame(c.time)) }
        try EditingPreviewTests.write("scene-detection", width: 640, height: 240, darkOnly: true) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Scenes · \(found.cuts.count) cuts in \(found.frames) frames (generated test video, cuts at 1.50, 3.00, 4.20 s)")
                    .font(.system(size: 13, weight: .semibold))
                SceneCurve(result: found, range: range).frame(height: 90)
                HStack(spacing: 14) {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pr in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 2) {
                                if let a = pr.1 { Image(decorative: a, scale: 1).resizable().frame(width: 80, height: 45) }
                                if let b = pr.2 { Image(decorative: b, scale: 1).resizable().frame(width: 80, height: 45) }
                            }
                            Text(String(format: "%.2f s · score %.2f", pr.0.time, pr.0.score)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Grey: frame difference. Dashed orange: adaptive threshold. Blue: cuts.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
