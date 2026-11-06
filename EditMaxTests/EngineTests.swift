import XCTest
import AVFoundation
@testable import EditMax

/// The engine against a real 2-second 1920×1080 clip (Fixtures/base.mp4): import, frame render, export.
@MainActor
final class EngineTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }
    private var fixture: URL { Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4")! }

    override func setUp() async throws {
        doc = EditMaxDocument()
        _ = try await x.importMedia(paths: [fixture.path])
    }

    /// GitHub's macOS runners are VMs where AVFoundation cannot decode H.264 (error -12780) even though they report a
    /// hardware decoder. On CI, a one-frame probe decides; on a developer Mac the tests always run, so a broken
    /// decoder there fails loudly.
    private func requireVideoDecoding() async throws {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: fixture))
        do { _ = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) }
        catch { throw XCTSkip("this CI runner cannot decode H.264: \(error)") }
    }

    func testImportProbesTheFile() throws {
        let a = x.listAssets()
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].name, "base.mp4")
        XCTAssertEqual(a[0].kind, "video")
        XCTAssertEqual(a[0].duration, 2, accuracy: 0.05)
        XCTAssertEqual(a[0].width, 1920)
        XCTAssertEqual(a[0].height, 1080)
        XCTAssertEqual(doc.project.history.last?.label, "Import 1 file")
    }

    func testRenderFrameHasTheProjectSize() async throws {
        try await requireVideoDecoding()
        _ = try x.insertClip(asset: "base.mp4")
        let (img, size) = try await x.renderFrame(at: 1)
        XCTAssertEqual(Int(size.width), 1920)
        XCTAssertEqual(Int(size.height), 1080)
        XCTAssertGreaterThan(img.width, 0)
        let png = try await x.captureFrame(at: 1, maxWidth: 320)
        XCTAssertGreaterThan(png.count, 100)
    }

    func testRenderFrameFailsOnAnEmptyTimeline() async {
        do { _ = try await x.renderFrame(at: 0); XCTFail("expected an error") } catch {}
    }

    func testExportWritesAPlayableMovieOfTheTimelineLength() async throws {
        try await requireVideoDecoding()
        _ = try x.insertClip(asset: "base.mp4")
        _ = try x.insertClip(asset: "base.mp4", duration: 1)   // 3 s total
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("editmax-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try await x.exportVideo(to: out.path, preset: .high)
        XCTAssertEqual(r.path, out.path)
        XCTAssertGreaterThan(r.bytes, 1000)
        let asset = AVURLAsset(url: out)
        let d = try await asset.load(.duration).seconds
        XCTAssertEqual(d, 3, accuracy: 0.1)
        let v = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(v.count, 1)
        let n = try await v[0].load(.naturalSize)
        XCTAssertEqual(Int(n.width), 1920)
    }

    func testExportRefusesAnEmptyTimeline() async {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("editmax-empty.mp4")
        do { _ = try await x.exportVideo(to: out.path); XCTFail("expected an error") } catch {}
    }

    func testNestAndUnnestKeepTheClipCount() async throws {
        try await requireVideoDecoding()
        let a = try x.insertClip(asset: "base.mp4", duration: 1)
        let b = try x.insertClip(asset: "base.mp4", duration: 1)
        let seq = try await x.nestClips([a.id.short, b.id.short], name: "Intro")
        XCTAssertEqual(seq.clips.count, 2)
        XCTAssertEqual(doc.project.allClips.count, 1, "two clips folded into one")
        XCTAssertEqual(doc.project.sequences.count, 1)
        XCTAssertEqual(doc.project.allClips[0].duration, 2, accuracy: 0.001)
        let n = try x.unnestClip(doc.project.allClips[0].id.short)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(doc.project.allClips.count, 2)
        XCTAssertTrue(doc.project.sequences.isEmpty, "nothing plays the sequence any more")
    }

    func testFrameStatsSeesThePicture() async throws {
        try await requireVideoDecoding()
        _ = try x.insertClip(asset: "base.mp4")
        let s = try await x.frameStats(at: 1)
        XCTAssertGreaterThan(s.lumaMean, 0); XCTAssertEqual(s.lumaHistogram.count, 16)
    }
}
