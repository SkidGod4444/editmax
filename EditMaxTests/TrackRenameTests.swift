import XCTest
import SwiftUI
@testable import EditMax

/// The audit's missing features (L11): renaming a track, and choosing the project's resolution and frame rate.
@MainActor
final class TrackRenameTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .user) }
    private var p: Project { doc.project }

    override func setUp() async throws { doc = EditMaxDocument() }

    func testRenameATrackAndFindItByItsNewName() throws {
        let r = try x.renameTrack("A1", to: "  Dialogue ")
        XCTAssertEqual(r.name, "Dialogue", "spaces around the name are dropped")
        XCTAssertEqual(p.tracks.first { $0.kind == .audio }?.name, "Dialogue")
        XCTAssertNotNil(try x.resolveTrack("dialogue"), "tools find it by its new name, any case")
        XCTAssertEqual(p.history.last?.label, "Rename track A1 to Dialogue")
        doc.undo()
        XCTAssertEqual(p.tracks.first { $0.kind == .audio }?.name, "A1", "one undo step")
    }

    func testRefusedNamesKeepTheOldOne() throws {
        _ = try x.addTrack(kind: "audio", name: nil)   // A2
        for bad in ["a2", "", "   ", "Text", String(repeating: "x", count: 33)] {
            XCTAssertThrowsError(try x.renameTrack("A1", to: bad), "'\(bad)' is refused")
        }
        XCTAssertEqual(p.tracks.filter { $0.kind == .audio }.map(\.name), ["A1", "A2"])
        let history = p.history.count
        _ = try x.renameTrack("A1", to: "A1")
        XCTAssertEqual(p.history.count, history, "the same name changes nothing and records nothing")
    }

    func testRenameTrackOverMCP() async throws {
        DocumentRegistry.shared.register(doc)
        defer { DocumentRegistry.shared.unregister(doc) }
        _ = try await EditMaxTools.call("rename_track", ["track": .string("V1"), "name": .string("B-roll"), "project": .string(doc.id.short)])
        XCTAssertEqual(p.tracks.first { $0.kind == .video }?.name, "B-roll")
    }

    func testProjectSettingsSayWhatChanged() throws {
        try x.setProjectSettings(width: 1080, height: 1920, fps: nil, name: nil)
        XCTAssertEqual(p.history.last?.label, "Resolution 1080×1920")
        try x.setProjectSettings(width: nil, height: nil, fps: 29.97, name: nil)
        XCTAssertEqual(p.history.last?.label, "Frame rate 29.97 fps")
        XCTAssertEqual(p.settings.fps, 29.97)
    }

    func testFormatText() {
        XCTAssertEqual(ProjectFormat.fpsText(30), "30 fps")
        XCTAssertEqual(ProjectFormat.fpsText(23.976), "23.976 fps")
        XCTAssertEqual(ProjectFormat.fpsText(59.94), "59.94 fps")
        XCTAssertEqual(ProjectFormat.sizeText(width: 1080, height: 1920), "1080×1920 (Vertical 9:16)")
        XCTAssertEqual(ProjectFormat.sizeText(width: 1000, height: 500), "1000×500")
    }

    /// The Project card with its two pop-ups, for the eye; both are reachable by the UI driver.
    func testPreviewProjectCard() throws {
        doc.project.settings.fps = 29.97
        for dark in [true, false] {
            let h = OffscreenHost(ProjectInspector(document: doc).environmentObject(EditorState()).environmentObject(PlayerController()),
                                  size: CGSize(width: 360, height: 420), dark: dark)
            XCTAssertNotNil(h.frame("inspector.project.resolution"))
            XCTAssertNotNil(h.frame("inspector.project.fps"))
            h.save("l11-project-card-\(dark ? "dark" : "light")")
            h.close()
        }
    }
}
