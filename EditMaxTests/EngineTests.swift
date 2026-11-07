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

    /// GitHub's macOS VMs render video intermittently (AVFoundation -12780 inside a composition, while a probe of the
    /// same render a moment earlier succeeds), so the tests that render skip there outright and run on every
    /// developer Mac, where a broken renderer fails loudly. Import, validation and the model still run on CI.
    private func requireRendering() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("video rendering is not reliable on GitHub's macOS runners; this test runs on developer Macs")
        }
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
        try requireRendering()
        _ = try x.insertClip(asset: "base.mp4")
        let (img, size) = try await x.renderFrame(at: 1)
        XCTAssertEqual(Int(size.width), 1920)
        XCTAssertEqual(Int(size.height), 1080)
        XCTAssertGreaterThan(img.width, 0)
        let png = try await x.captureFrame(at: 1, maxWidth: 320)
        XCTAssertGreaterThan(png.count, 100)
    }

    func testRenderFrameFailsOnAnEmptyTimeline() async throws {
        try requireRendering()
        do { _ = try await x.renderFrame(at: 0); XCTFail("expected an error") } catch {}
    }

    func testExportWritesAPlayableMovieOfTheTimelineLength() async throws {
        try requireRendering()
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

    /// A 6K project (6144×3456, the Project card's largest size) exports at 6K in every format the Export sheet offers
    /// at full size (High quality as HEVC: H.264 would shrink it to 3840×2160), and a frame renders at that size.
    func testA6KProjectExportsAt6K() async throws {
        XCTAssertTrue(ExportService.fitsH264(width: 3840, height: 2160)); XCTAssertTrue(ExportService.fitsH264(width: 2160, height: 3840))
        XCTAssertFalse(ExportService.fitsH264(width: 4096, height: 2160), "H.264 shrinks DCI 4K to 3840×2024")
        XCTAssertEqual(ProjectFormat.sizeText(width: 6144, height: 3456), "6144×3456 (6K)")
        try requireRendering()
        doc.project.settings.width = 6144; doc.project.settings.height = 3456
        _ = try x.insertClip(asset: "base.mp4", duration: 1)
        let (_, size) = try await x.renderFrame(at: 0.5)
        XCTAssertEqual(size, CGSize(width: 6144, height: 3456))
        for preset in [ExportService.Preset.high, .hevc10, .prores422] {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("editmax-6k-\(UUID().uuidString).\(preset.fileExtension)")
            defer { try? FileManager.default.removeItem(at: out) }
            let t0 = Date()
            let r = try await x.exportVideo(to: out.path, preset: preset)
            let v = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
            let n = try await XCTUnwrap(v.first).load(.naturalSize)
            print("6K-EXPORT \(preset.rawValue): \(Int(n.width))x\(Int(n.height)) \(r.bytes / 1024) KB in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            XCTAssertEqual(Int(n.width), 6144, preset.rawValue)
            XCTAssertEqual(Int(n.height), 3456, preset.rawValue)
        }
    }

    func testExportRefusesAnEmptyTimeline() async {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("editmax-empty.mp4")
        do { _ = try await x.exportVideo(to: out.path); XCTFail("expected an error") } catch {}
    }

    func testNestAndUnnestKeepTheClipCount() async throws {
        try requireRendering()
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
        try requireRendering()
        _ = try x.insertClip(asset: "base.mp4")
        let s = try await x.frameStats(at: 1)
        XCTAssertGreaterThan(s.lumaMean, 0); XCTAssertEqual(s.lumaHistogram.count, 16)
    }
}
