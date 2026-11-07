import XCTest
import AVFoundation
@testable import EditMax

/// An export the disk cannot hold is refused before any of it is written (an 18-hour 1080p export is some 80 GB), and
/// the result says what the check counted on.
@MainActor
final class ExportDiskTests: XCTestCase {
    override func tearDown() async throws {
        ExportService.volumeFree = ExportService.realVolumeFree
        ExportService.watchInterval = .seconds(1)
    }

    private func fixtureProject() async throws -> EditMaxDocument {
        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4"))
        _ = try await x.importMedia(paths: [fixture.path])
        for _ in 0..<5 { _ = try x.insertClip(asset: "base.mp4") }
        return doc
    }

    /// Export Anyway goes past the estimate; without it the refusal says what it needs and what is free.
    func testExportAnywayGoesPastTheEstimate() async throws {
        let doc = try await fixtureProject()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("anyway-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        ExportService.volumeFree = { _ in 505_000_000 }   // above the 0.5 GB stop, below the estimate plus its margin
        do {
            _ = try await ExportService.export(doc.project, to: out, preset: .medium)
            XCTFail("refused before it starts")
        } catch let e as ExportService.DiskTooSmall {
            XCTAssertEqual(e.free, 505_000_000)
            XCTAssertTrue(e.localizedDescription.contains("Export anyway"), e.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "nothing written")
        let r = try await ExportService.export(doc.project, to: out, preset: .medium, ignoreDiskEstimate: true)
        XCTAssertGreaterThan(r.bytes, 0)
    }

    /// A disk that runs low while the export writes: it stops, removes the unfinished file and says how far it got,
    /// for the export session and for a master alike.
    func testAnExportStopsAndRemovesItsFileWhenTheDiskRunsLow() async throws {
        let doc = try await fixtureProject()
        final class Calls: @unchecked Sendable { let lock = NSLock(); var n = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n } }
        ExportService.watchInterval = .milliseconds(20)
        for preset in [ExportService.Preset.low, .hevc10] {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("low-\(UUID().uuidString).\(preset.fileExtension)")
            defer { try? FileManager.default.removeItem(at: out) }
            let calls = Calls()
            ExportService.volumeFree = { _ in calls.next() == 1 ? 10_000_000_000 : 300_000_000 }   // fine before it starts, then low
            do {
                _ = try await ExportService.export(doc.project, to: out, preset: preset)
                XCTFail("\(preset.rawValue): stops")
            } catch let e as ExportService.DiskRanLow {
                XCTAssertTrue(e.localizedDescription.contains("0.3 GB free"), e.localizedDescription)
                XCTAssertTrue(e.localizedDescription.contains("was removed"), e.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "\(preset.rawValue): the unfinished file is removed")
        }
    }
    func testAnExportTheDiskCannotHoldIsRefusedBeforeItStarts() throws {
        let dest = URL(fileURLWithPath: "/Volumes/Work/stream-cut.mp4")
        XCTAssertThrowsError(try ExportService.checkDisk(estimate: 79_000_000_000, free: 20_000_000_000, destination: dest)) { e in
            let m = e.localizedDescription
            XCTAssertTrue(m.contains("87.4 GB"), m)   // 79 GB, 10 % over, 0.5 GB to spare
            XCTAssertTrue(m.contains("20.0 GB is free"), m)
            XCTAssertTrue(m.contains("/Volumes/Work"), m)
        }
        XCTAssertNoThrow(try ExportService.checkDisk(estimate: 1_000_000_000, free: 20_000_000_000, destination: dest))
        XCTAssertNoThrow(try ExportService.checkDisk(estimate: 79_000_000_000, free: nil, destination: dest), "free space unknown: no refusal")
    }

    func testMastersAreEstimatedAtTheirCodecsRates() {
        // ProRes 422 HQ at 1080p 29.97 is Apple's 220 Mb/s, plus 24-bit stereo PCM: a minute is about 1.67 GB.
        let hq = ExportService.masterBytes(.prores422hq, width: 1920, height: 1080, fps: 29.97, seconds: 60)
        XCTAssertEqual(Double(hq) / 1e9, (220e6 + 2.304e6) * 60 / 8 / 1e9, accuracy: 0.001)
        // 4K is four times the pixels: four times the picture.
        let uhd = ExportService.masterBytes(.prores422hq, width: 3840, height: 2160, fps: 29.97, seconds: 60)
        XCTAssertEqual(Double(uhd - Int64(2.304e6 * 60 / 8)) / Double(hq - Int64(2.304e6 * 60 / 8)), 4, accuracy: 0.001)
        // HEVC 10-bit, an hour at 1080p30: 15.6 Mb/s plus AAC, about 7.1 GB.
        XCTAssertEqual(Double(ExportService.masterBytes(.hevc10, width: 1920, height: 1080, fps: 30, seconds: 3600)) / 1e9, 7.08, accuracy: 0.01)
    }

    /// Real exports: the estimate the check uses, against the file written.
    func testTheEstimateIsInTheResultAndNearTheFileWritten() async throws {
        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
        // TEST_RUNNER_EDITMAX_EXPORT_FILE: real or busy footage instead of the small fixture, every preset.
        let given = ProcessInfo.processInfo.environment["EDITMAX_EXPORT_FILE"]
        let fixture = try given.map { URL(fileURLWithPath: $0) } ?? XCTUnwrap(Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4"))
        _ = try await x.importMedia(paths: [fixture.path])
        for _ in 0..<(given == nil ? 5 : 1) { _ = try x.insertClip(asset: fixture.lastPathComponent) }
        if given != nil { doc.project.settings.width = 1920; doc.project.settings.height = 1080; doc.project.settings.fps = 30 }
        for preset in given == nil ? [ExportService.Preset.medium, .hevc10] : [.high, .medium, .hevc10, .prores422] {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("estimate-\(UUID().uuidString).\(preset.fileExtension)")
            defer { try? FileManager.default.removeItem(at: out) }
            let r = try await ExportService.export(doc.project, to: out, preset: preset)
            let est = try XCTUnwrap(r.estimatedBytes, preset.rawValue)
            print("EXPORT-SIZE \(preset.rawValue): \(r.duration) s, estimated \(est / 1000) KB, wrote \(r.bytes / 1000) KB")
            XCTAssertGreaterThan(est, 0)
            XCTAssertLessThan(Int64(r.bytes), ExportService.diskNeeded(estimate: est) - 500_000_000, "10 % over the estimate covers what was written")
        }
    }
}
