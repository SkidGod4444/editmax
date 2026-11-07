import XCTest
@testable import EditMax

/// Every edit goes through `EditMaxDocument.apply`: it must leave a History version, an undo step, and come back
/// exactly on undo/redo/restore. These are the guarantees the History tab and ⌘Z make to the user.
@MainActor
final class DocumentHistoryTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var asset: UUID!

    override func setUp() async throws {
        doc = EditMaxDocument()
        let a = Asset(name: "a.mp4", path: "/tmp/a.mp4", kind: .video, duration: 10, width: 1920, height: 1080)
        asset = a.id
        doc.project.assets.append(a)
    }

    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .user) }

    func testApplyRecordsAVersionAndAnUndoStep() throws {
        XCTAssertEqual(doc.project.history.count, 0)
        _ = try x.insertClip(asset: "a.mp4")
        XCTAssertEqual(doc.project.history.count, 1)
        XCTAssertEqual(doc.project.history[0].label, "Insert a.mp4")
        XCTAssertTrue(doc.canUndo)
        XCTAssertEqual(doc.undoLabel, "Insert a.mp4")
        XCTAssertEqual(doc.revision, 1)
    }

    func testUndoRedoRestoreTheTimelineAndStayInHistory() throws {
        _ = try x.insertClip(asset: "a.mp4")
        _ = try x.insertClip(asset: "a.mp4", duration: 2)
        XCTAssertEqual(doc.project.allClips.count, 2)
        doc.undo()
        XCTAssertEqual(doc.project.allClips.count, 1)
        XCTAssertTrue(doc.canRedo)
        doc.redo()
        XCTAssertEqual(doc.project.allClips.count, 2)
        XCTAssertEqual(doc.project.history.map(\.label), ["Insert a.mp4", "Insert a.mp4", "Undo Insert a.mp4", "Redo Insert a.mp4"],
                       "undo and redo are themselves versions, so the log is complete")
    }

    func testAFailedEditLeavesNothingBehind() throws {
        _ = try x.insertClip(asset: "a.mp4")
        XCTAssertThrowsError(try x.splitClip("nope", at: 1))
        XCTAssertEqual(doc.project.history.count, 1)
        XCTAssertEqual(doc.undoStack.count, 1)
    }

    func testCoalescedEditsMakeOneUndoStep() throws {
        let c = try x.insertClip(asset: "a.mp4")
        let slider = ToolExecutor(document: doc, origin: .user, coalesce: true)
        for v in [0.9, 0.8, 0.7] { try slider.setClipProperties(c.id.uuidString, opacity: v) }
        XCTAssertEqual(doc.project.clip(c.id)!.clip.opacity, 0.7)
        XCTAssertEqual(doc.undoStack.count, 2, "insert + one folded opacity step")
        doc.undo()
        XCTAssertEqual(doc.project.clip(c.id)!.clip.opacity, 1, "one ⌘Z undoes the whole drag")
    }

    func testRestoreSnapshotIsItselfAnEdit() throws {
        _ = try x.insertClip(asset: "a.mp4")
        let before = doc.project.history[0].id   // the state before the insert: empty timeline
        _ = try x.insertClip(asset: "a.mp4")
        try x.restore(before.uuidString)
        XCTAssertEqual(doc.project.allClips.count, 0)
        XCTAssertEqual(doc.project.history.count, 3)
        XCTAssertTrue(doc.project.history.last!.label.hasPrefix("Restore"))
        doc.undo()
        XCTAssertEqual(doc.project.allClips.count, 2, "a restore can be undone")
    }

    func testUndoStackIsCapped() throws {
        for _ in 0..<(EditMaxDocument.maxUndo + 10) { _ = try x.addMarker(at: 1, name: nil, colorHex: nil) }
        XCTAssertEqual(doc.undoStack.count, EditMaxDocument.maxUndo)
        XCTAssertLessThanOrEqual(doc.project.history.count, EditMaxDocument.maxHistory)
    }

    func testTranscriptCacheSurvivesUndo() throws {
        _ = try x.insertClip(asset: "a.mp4")
        doc.project.transcripts = ["k": Transcript(locale: "en", words: [])]
        _ = try x.addMarker(at: 2, name: "m", colorHex: nil)
        doc.undo()
        XCTAssertNotNil(doc.project.transcripts?["k"], "analysis caches are not part of the edit history")
    }
}

/// The interaction log's measurements: drag lateness and near misses are pure functions a test can feed.
@MainActor
final class InteractionLogTests: XCTestCase {
    func testDragTimingMeasuresLatenessAndGaps() {
        var t = DragTiming(start: 10)
        t.moved(at: 10.02, now: 10.021)   // on time
        t.moved(at: 10.04, now: 10.30)    // delivered 260 ms late: the main thread was blocked
        t.moved(at: 10.50, now: 10.501)   // a 460 ms pause between moves
        XCTAssertEqual(t.updates, 3)
        XCTAssertEqual(t.maxLate, 0.26, accuracy: 0.001)
        XCTAssertEqual(t.maxGap, 0.46, accuracy: 0.001)
    }

    func testNearestRegisteredElementWithinReach() {
        let reg = UIRegistry.shared
        // Far from any real window's elements: windows other tests closed but still hold keep their views registered.
        let o = CGFloat(50_000)
        reg.set("test.divider", CGRect(x: o + 100, y: o, width: 32, height: 300))
        reg.set("test.far", CGRect(x: o + 900, y: o, width: 32, height: 300))
        defer { reg.remove("test.divider"); reg.remove("test.far") }
        let n = reg.nearest(to: CGPoint(x: o + 90, y: o + 150), within: 24)
        XCTAssertEqual(n?.id, "test.divider")
        XCTAssertEqual(n!.distance, 10, accuracy: 0.001)
        XCTAssertNil(reg.nearest(to: CGPoint(x: o + 60, y: o + 150), within: 24), "40 points away is not a near miss")
        XCTAssertEqual(reg.nearest(to: CGPoint(x: o + 110, y: o + 150), within: 24)?.distance, 0, "inside counts as distance 0")
    }
}
