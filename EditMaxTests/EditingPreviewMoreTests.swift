import XCTest
import SwiftUI
import AppKit
import AVFoundation
@testable import EditMax

/// Previews of the relink sheet, the source viewer, scene detection and the interpolation contact sheet (dark).
@MainActor
final class EditingPreviewMoreTests: XCTestCase {
    override func setUp() { EditingPreview.rendering = true }
    override func tearDown() { EditingPreview.rendering = false }

    func testRelinkSheet() throws {
        let doc = EditMaxDocument()
        let rows: [RelinkSheet.Row] = [
            .init(id: UUID(), name: "A001_C003_interview.mov", path: "/Volumes/CARD A/DCIM/A001_C003_interview.mov",
                  found: "/Volumes/Archive/Shoot 12/Card A/A001_C003_interview.mov", why: "same file name, duration and picture size"),
            .init(id: UUID(), name: "street-broll.mp4", path: "/Users/dev/Movies/street-broll.mp4",
                  found: "/Users/dev/Movies/Old Exports/broll take 2.mp4", why: "renamed: only file with the same type, duration and picture size"),
            .init(id: UUID(), name: "music-bed.wav", path: "/Users/dev/Music/music-bed.wav",
                  reason: "2 files named music-bed.wav match equally; relink this one with path"),
            .init(id: UUID(), name: "logo.png", path: "/Users/dev/Desktop/logo.png", reason: "no file named logo.png in the folder"),
        ]
        try EditingPreviewTests.write("relink-sheet", width: 600, height: 470, darkOnly: true) {
            RelinkSheet(document: doc, onClose: {}, rows: rows, message: "Found 2 of 4 files; 2 still missing.")
        }
    }

    /// The source viewer as it fills the preview area: a generated clip, marked 1.20–3.60 s, playhead at 2.40 s.
    func testSourceViewer() async throws {
        guard EditingPreviewTests.dir != nil else { throw XCTSkip("set TEST_RUNNER_EDITMAX_PREVIEW_DIR") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editing-sourceview-\(UUID().uuidString.prefix(8)).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await EditingTestVideo.write(to: url, seconds: 6, width: 320, height: 180, cuts: [3])
        var a = try await MediaImporter.probe(url); a.name = "A001_C003_interview.mov"
        let m = SourceMonitor()
        m.open(a, at: 2.4, in: 1.2, out: 3.6)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let still = try gen.copyCGImage(at: CMTime(seconds: 2.4, preferredTimescale: 600), actualTime: nil)
        try EditingPreviewTests.write("source-viewer", width: 720, height: 470, darkOnly: true) {
            SourceViewer(asset: a, monitor: m, actions: nil, still: still)
        }
        m.close()
    }
}
