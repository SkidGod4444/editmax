import XCTest
import AVFoundation
import SwiftUI
@testable import EditMax

/// Smooth slow motion, measured: a 30 fps source with a moving disc is slowed to 0.25×, rendered with blend and
/// optical flow, and every in-between frame is compared (PSNR) with a 120 fps render of the same motion, the ground
/// truth. Repeating frames (off) is the baseline. Writes a contact sheet to the preview folder.
@MainActor
final class EditingSlowMotionTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }
    private var dir: URL!

    override func setUp() async throws {
        doc = EditMaxDocument()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("editing-slowmo-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    private var rendered: [String] = []
    /// The renders land in the real cache folder (Application Support/EditMax/interpolated): remove them.
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir); for f in rendered { try? FileManager.default.removeItem(atPath: f) } }
    private func message(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }

    struct Frame { var bytes: [UInt8]; var width: Int; var height: Int; var row: Int; var time: Double }
    private func frames(_ url: URL) async throws -> [Frame] {
        let a = AVURLAsset(url: url)
        let t = try await a.loadTracks(withMediaType: .video).first!
        let r = try AVAssetReader(asset: a)
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        r.add(o); r.startReading()
        var out: [Frame] = []
        while let s = o.copyNextSampleBuffer() {
            guard let px = CMSampleBufferGetImageBuffer(s) else { continue }
            CVPixelBufferLockBaseAddress(px, .readOnly)
            let h = CVPixelBufferGetHeight(px), row = CVPixelBufferGetBytesPerRow(px)
            let bytes = [UInt8](UnsafeBufferPointer(start: CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self), count: row * h))
            out.append(Frame(bytes: bytes, width: CVPixelBufferGetWidth(px), height: h, row: row, time: CMSampleBufferGetPresentationTimeStamp(s).seconds))
            CVPixelBufferUnlockBaseAddress(px, .readOnly)
        }
        return out
    }
    private func psnr(_ a: Frame, _ b: Frame) -> Double {
        var se = 0.0, n = 0.0
        for y in 0..<min(a.height, b.height) { for x in 0..<min(a.width, b.width) { for c in 0..<3 {
            let d = Double(a.bytes[y * a.row + x * 4 + c]) - Double(b.bytes[y * b.row + x * 4 + c]); se += d * d; n += 1
        } } }
        return se == 0 ? 99 : 10 * log10(255 * 255 / (se / n))
    }
    private func image(_ f: Frame) -> CGImage {
        let ctx = CGContext(data: UnsafeMutablePointer(mutating: f.bytes), width: f.width, height: f.height, bitsPerComponent: 8, bytesPerRow: f.row,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        return ctx.makeImage()!
    }

    /// Optical flow that fails during the render (as on a virtual Mac: VTFrameProcessorErrorDomain -19730, though it says
    /// it is supported) falls back to blend, says why, and later renders blend straight away.
    func testOpticalFlowThatFailsFallsBackToBlendAndSaysWhy() async throws {
        guard InterpolatedVideo.flowAvailable else { throw XCTSkip("optical flow is not available on this Mac") }
        InterpolatedVideo.failFlowForTesting = true
        defer { InterpolatedVideo.failFlowForTesting = false; InterpolatedVideo.flowFailure = nil }
        let src = dir.appendingPathComponent("flowfail30.mp4")
        try await EditingTestVideo.write(to: src, seconds: 2, fps: 30, width: 320, height: 180, cuts: [], discSpeed: 600)
        let a = try await MediaImporter.probe(src); doc.project.assets.append(a)
        doc.project.settings.fps = 30
        var slow = Clip(assetID: a.id, name: "Slow", start: 0, duration: 2, sourceIn: 0.5); slow.speed = 0.25
        doc.project.tracks[0].clips.append(slow)
        let r = try await x.setSmoothSlowMotion("Slow", mode: "optical_flow", wait: true)
        if let f = r.file { rendered.append(f) }
        XCTAssertEqual(r.status, "ready")
        XCTAssertEqual(r.method, "blend")
        XCTAssertTrue(r.note?.contains("optical flow failed on this Mac (VTFrameProcessorErrorDomain -19730)") == true, r.note ?? "no note")
        XCTAssertTrue(r.file.map { FileManager.default.fileExists(atPath: $0) && $0.hasSuffix("-blend.mov") } == true, r.file ?? "no file")
        XCTAssertFalse(InterpolatedVideo.flowAvailable, "flow is not tried again until EditMax quits")
        let clip = try XCTUnwrap(doc.project.allClips.first { $0.name == "Slow" })
        XCTAssertEqual(InterpolatedVideo.ready(clip, a, fps: 30)?.url.path, r.file, "the builder plays the blended file")
    }

    func testInterpolatedFramesBeatRepeatedFrames() async throws {
        let src = dir.appendingPathComponent("source30.mp4"), truth = dir.appendingPathComponent("truth120.mp4")
        try await EditingTestVideo.write(to: src, seconds: 2, fps: 30, width: 320, height: 180, cuts: [], discSpeed: 600)
        try await EditingTestVideo.write(to: truth, seconds: 2, fps: 120, width: 320, height: 180, cuts: [], discSpeed: 600)
        let a = try await MediaImporter.probe(src); doc.project.assets.append(a)
        doc.project.settings.fps = 30
        let still = Asset(name: "still.png", path: src.path, kind: .image, duration: 5, width: 320, height: 180); doc.project.assets.append(still)
        let normal = try x.insertClip(asset: a.id.short, sourceIn: 0, duration: 0.5)
        var slow = Clip(assetID: a.id, name: "Slow", start: 1, duration: 4, sourceIn: 0.5); slow.speed = 0.25   // source 0.5–1.5 over 4 s
        doc.project.tracks[0].clips.append(slow)

        // Refusals: 1× clips, unknown modes. Old projects decode with it off (EditingTests).
        do { _ = try await x.setSmoothSlowMotion(normal.id.short, mode: "blend", wait: false); XCTFail("1× must be refused") }
        catch { XCTAssertTrue(message(error).contains("slower than 1"), message(error)) }
        do { _ = try await x.setSmoothSlowMotion("Slow", mode: "fancy", wait: false); XCTFail("unknown mode") } catch { }
        XCTAssertNil(InterpolatedVideo.ready(slow, a, fps: 30), "nothing rendered while off")

        let truthFrames = try await frames(truth), srcFrames = try await frames(src)
        var rows: [(String, [Frame], Double)] = []
        // Baseline: the repeated source frame (what off plays). In-between frames are output k with k % 4 != 0.
        let ks = (0..<120).filter { $0 % 4 != 0 && 60 + $0 < truthFrames.count }
        func mean(_ f: (Int) -> Double) -> Double { ks.map(f).reduce(0, +) / Double(ks.count) }
        let repeatPSNR = mean { k in self.psnr(srcFrames[(60 + k) / 4], truthFrames[60 + k]) }
        rows.append(("Repeat (off)", (1...4).map { srcFrames[(60 + $0) / 4] }, repeatPSNR))

        var results: [String: Double] = [:]
        for mode in ["blend", "optical_flow"] {
            let r = try await x.setSmoothSlowMotion("Slow", mode: mode, wait: true)
            XCTAssertEqual(r.status, "ready"); XCTAssertEqual(r.outputFps, 120)
            let file = try XCTUnwrap(r.file); rendered.append(file)
            let out = try await frames(URL(fileURLWithPath: file))
            XCTAssertEqual(out.count, 120, "one frame per 1/120 source second")
            XCTAssertEqual(out[5].time, 5.0 / 120, accuracy: 1e-3)
            let score = mean { k in self.psnr(out[k], truthFrames[60 + k]) }
            // A frame on a source frame is the source frame: the render must not shift colours or time.
            let onFrame = (0..<120).filter { $0 % 4 == 0 }.map { k in self.psnr(out[k], srcFrames[(60 + k) / 4]) }.reduce(0, +) / 30
            print("SLOWMO-ONFRAME \(mode) \(onFrame)")
            // 53.6 dB here. GitHub's virtual Macs have no hardware encoder, and their software H.264 at the same rate
            // gives 34.9 dB; a frame shifted in time or colour scores under 27 (the repeated frames do).
            XCTAssertGreaterThan(onFrame, ProcessInfo.processInfo.environment["CI"] != nil ? 32 : 40, "frames on a source frame match it")
            results[r.method!] = score
            rows.append((r.method == "optical_flow" ? "Optical flow" : "Blend" + (mode == "optical_flow" ? " (flow unavailable)" : ""), (1...4).map { out[$0] }, score))
            if mode == "optical_flow", !InterpolatedVideo.flowAvailable { XCTAssertEqual(r.method, "blend"); XCTAssertNotNil(r.note) }
            // The builder plays the render in place of the source picture.
            let built = try await CompositionBuilder.build(doc.project)
            let urls = try await built.composition.loadTracks(withMediaType: .video).flatMap { $0.segments.compactMap { $0.sourceURL?.standardizedFileURL.path } }
            XCTAssertTrue(urls.contains(URL(fileURLWithPath: file).standardizedFileURL.path), "the composition reads the interpolated file")
        }
        rows.insert(("Ground truth (120 fps)", (1...4).map { truthFrames[60 + $0] }, 0), at: 0)
        DebugLog.event("smooth-slow-motion-quality", ["repeat_psnr": repeatPSNR, "blend_psnr": results["blend"] ?? 0, "flow_psnr": results["optical_flow"] ?? -1])
        print("SLOWMO-QUALITY repeat=\(repeatPSNR) blend=\(results["blend"] ?? 0) flow=\(results["optical_flow"] ?? -1) flowAvailable=\(InterpolatedVideo.flowAvailable)")
        XCTAssertGreaterThan(results["blend"] ?? 0, repeatPSNR, "blend is closer to the truth than repeating frames")
        if let flow = results["optical_flow"] { XCTAssertGreaterThan(flow, repeatPSNR + 1, "optical flow must be measurably closer to the truth than repeating frames") }

        // Off again: back to the source, the cache file is left for reuse.
        _ = try await x.setSmoothSlowMotion("Slow", mode: "off", wait: false)
        XCTAssertNil(InterpolatedVideo.ready(doc.project.allClips.first { $0.name == "Slow" }!, a, fps: 30))

        guard EditingPreviewTests.dir != nil else { return }
        let imgs = rows.map { ($0.0, $0.1.map(image), $0.2) }
        try EditingPreviewTests.write("slowmo-contact-sheet", width: 820, height: 110 + CGFloat(imgs.count) * 104, darkOnly: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Smooth slow motion at 0.25×: in-between frames 1–4 after source 0.50 s (30 fps source, phases 0.25, 0.5, 0.75, then the next source frame)")
                    .font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(imgs.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0).font(.system(size: 12, weight: .medium))
                            if row.2 > 0 { Text(String(format: "%.1f dB PSNR", row.2)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
                        }.frame(width: 150, alignment: .leading)
                        ForEach(Array(row.1.enumerated()), id: \.offset) { _, im in Image(decorative: im, scale: 1).resizable().frame(width: 160, height: 90) }
                    }
                }
                Text("PSNR: mean over every in-between frame of the clip against the 120 fps ground truth (higher is closer).").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
