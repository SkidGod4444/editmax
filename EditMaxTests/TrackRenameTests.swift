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

    /// A project from before new video tracks went on top: V2 sits under V1, which covers it. A clip added with no track
    /// named must still land on V1, where it can be seen, not on the bottom row.
    func testOlderProjectsStillAddToV1() throws {
        var q = Project()
        let v2 = Track(name: "V2", kind: .video)
        q.tracks.insert(v2, at: 1)   // [V1, V2, A1]: the old order
        XCTAssertEqual(q.tracks.map(\.name), ["V1", "V2", "A1"])
        XCTAssertEqual(q.defaultTrack(of: .video)?.name, "V1")
        doc.project.tracks = q.tracks
        doc.project.assets.append(Asset(name: "ridge.mp4", path: "/tmp/old-ridge.mp4", kind: .video, duration: 10, width: 1920, height: 1080))
        let c = try x.insertClip(asset: "ridge.mp4")
        XCTAssertEqual(p.clip(c.id)?.track.name, "V1")
        // New order, and with V1 renamed: the bottom video row is the base.
        var n = Project(); _ = n.addTrack(kind: .video)
        XCTAssertEqual(n.defaultTrack(of: .video)?.name, "V1")
        n.tracks[n.tracks.firstIndex { $0.name == "V1" }!].name = "Main"
        XCTAssertEqual(n.defaultTrack(of: .video)?.name, "Main", "no V1: the bottom video row")
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
