import XCTest
@testable import EditMax

/// The timeline model on its own: no document, no engine. These are the rules every edit relies on.
final class ProjectModelTests: XCTestCase {
    private func project(clips: [(String, Double)] = []) -> (Project, UUID) {
        var p = Project()
        let a = Asset(name: "a.mp4", path: "/tmp/a.mp4", kind: .video, duration: 10, width: 1920, height: 1080)
        p.assets.append(a)
        return (p, a.id)
    }
    private func v1(_ p: Project) -> [Clip] { p.tracks[0].clips.sorted { $0.start < $1.start } }

    // MARK: insert

    func testAppendGoesAfterTheLastClip() throws {
        var (p, a) = project()
        _ = try p.insertClip(assetID: a)
        _ = try p.insertClip(assetID: a, duration: 4)
        XCTAssertEqual(v1(p).map(\.start), [0, 10])
        XCTAssertEqual(p.duration, 14, accuracy: 0.001)
    }

    func testInsertAtATimeRipplesInsteadOfStacking() throws {
        var (p, a) = project()
        _ = try p.insertClip(assetID: a)                       // 0–10
        _ = try p.insertClip(assetID: a, at: 4, duration: 2)   // into the middle
        let c = v1(p)
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c.map { ($0.start * 100).rounded() / 100 }, [0, 4, 6])
        XCTAssertEqual(c.map { ($0.end * 100).rounded() / 100 }, [4, 6, 12])
        XCTAssertEqual(c[2].sourceIn, 4, accuracy: 0.001, "the split-off tail keeps its source offset")
        for i in 0..<c.count - 1 { XCTAssertLessThanOrEqual(c[i].end, c[i + 1].start + 0.001, "clips never overlap") }
    }

    func testInsertAtATimeRipplesEveryTrackTextsAndMarkers() throws {
        var (p, a) = project()
        let v2 = p.addTrack(kind: .video)
        _ = try p.insertClip(assetID: a)                                   // V1 0–10
        _ = try p.insertClip(assetID: a, trackID: v2.id, at: 8, duration: 1)   // V2 8–9
        p.texts.append(TextOverlay(text: "late", start: 8, duration: 2))
        p.markers.append(Marker(time: 9, name: "m"))
        _ = try p.insertClip(assetID: a, at: 2, duration: 3)
        XCTAssertEqual(p.track(v2.id)!.clips[0].start, 11, accuracy: 0.001)
        XCTAssertEqual(p.texts[0].start, 11, accuracy: 0.001)
        XCTAssertEqual(p.markers[0].time, 12, accuracy: 0.001)
    }

    func testInsertAtZeroPushesEverythingRight() throws {
        var (p, a) = project()
        _ = try p.insertClip(assetID: a, duration: 5)
        _ = try p.insertClip(assetID: a, at: 0, duration: 2)
        XCTAssertEqual(v1(p).map(\.start), [0, 2])
        XCTAssertEqual(v1(p)[0].duration, 2)
    }

    func testInsertRejectsEmptyAndUnknownAsset() {
        var (p, a) = project()
        XCTAssertThrowsError(try p.insertClip(assetID: UUID()))
        XCTAssertThrowsError(try p.insertClip(assetID: a, sourceIn: 10))   // nothing left after the source offset
    }

    // MARK: tracks

    func testNewVideoTracksStayAboveAudio() {
        var p = Project()
        _ = p.addTrack(kind: .video)
        _ = p.addTrack(kind: .audio)
        _ = p.addTrack(kind: .video)
        let kinds = p.tracks.map(\.kind)
        XCTAssertEqual(p.tracks.map(\.name), ["V1", "V2", "V3", "A1", "A2"])
        XCTAssertLessThan(kinds.lastIndex(of: .video)!, kinds.firstIndex(of: .audio)!)
    }

    func testTextLaneRowFollowsAnInsertedVideoTrack() {
        var p = Project()
        p.textLaneRow = 1   // between V1 and A1
        _ = p.addTrack(kind: .video)
        XCTAssertEqual(p.textLaneRow, 2, "the Text lane keeps its place relative to the audio tracks")
        XCTAssertEqual(p.rows.count, 4)
    }

    func testRemoveTrackReportsItsClips() throws {
        var (p, a) = project()
        _ = try p.insertClip(assetID: a)
        _ = try p.insertClip(assetID: a)
        XCTAssertEqual(p.removeTrack(p.tracks[0].id), 2)
        XCTAssertEqual(p.tracks.map(\.name), ["A1"])
    }

    // MARK: split, trim, move

    func testSplitKeepsSourceContinuity() throws {
        var (p, a) = project()
        let c = try p.insertClip(assetID: a, sourceIn: 1, duration: 6)   // source 1–7 on timeline 0–6
        let (l, r) = try p.splitClip(c.id, at: 2.5)
        XCTAssertEqual(l.end, 2.5, accuracy: 0.001)
        XCTAssertEqual(r.start, 2.5, accuracy: 0.001)
        XCTAssertEqual(r.sourceIn, 3.5, accuracy: 0.001)
        XCTAssertEqual(l.duration + r.duration, 6, accuracy: 0.001)
        XCTAssertThrowsError(try p.splitClip(c.id, at: 0), "a split at the very edge is refused")
    }

    func testTrimCannotRunBeforeTheSourceStart() throws {
        var (p, a) = project()
        let c = try p.insertClip(assetID: a, at: 2, duration: 4)   // sourceIn 0
        XCTAssertThrowsError(try p.trimClip(c.id, newStart: 1, newEnd: nil))
        try p.trimClip(c.id, newStart: 3, newEnd: nil)
        let t = p.clip(c.id)!.clip
        XCTAssertEqual(t.sourceIn, 1, accuracy: 0.001)
        XCTAssertEqual(t.duration, 3, accuracy: 0.001)
        XCTAssertThrowsError(try p.trimClip(c.id, newStart: nil, newEnd: 3.001), "cannot trim to nothing")
    }

    func testMoveClipsNeverGoesNegative() throws {
        var (p, a) = project()
        let c = try p.insertClip(assetID: a, at: 1, duration: 2)
        p.moveClips([c.id], by: -5)
        XCTAssertEqual(p.clip(c.id)!.clip.start, 0)
    }

    func testMoveClipToAnotherTrackOfTheSameKindOnly() throws {
        var (p, a) = project()
        let c = try p.insertClip(assetID: a, duration: 2)
        XCTAssertThrowsError(try p.moveClip(c.id, to: 0, trackID: p.tracks[1].id), "video onto an audio track")
        let v2 = p.addTrack(kind: .video)
        try p.moveClip(c.id, to: 3, trackID: v2.id)
        XCTAssertEqual(p.clip(c.id)!.track.id, v2.id)
        XCTAssertEqual(p.clip(c.id)!.clip.start, 3)
    }

    // MARK: ripple delete

    func testRippleDeleteClosesTheGapOnEveryTrackAndText() throws {
        var (p, a) = project()
        _ = try p.insertClip(assetID: a)                     // 0–10
        p.texts.append(TextOverlay(text: "t", start: 6, duration: 1))
        p.rippleDelete(start: 2, end: 4)
        let c = v1(p)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[1].start, 2, accuracy: 0.001)
        XCTAssertEqual(c[1].sourceIn, 4, accuracy: 0.001)
        XCTAssertEqual(p.duration, 8, accuracy: 0.001)
        XCTAssertEqual(p.texts[0].start, 4, accuracy: 0.001)
    }

    // MARK: file format

    func testRoundTripsThroughJSON() throws {
        var (p, a) = project()
        _ = try p.insertClip(assetID: a, duration: 3)
        p.markers.append(Marker(time: 1, name: "one"))
        p.texts.append(TextOverlay(text: "hi", start: 0, duration: 1))
        let data = try EditMaxDocument.encoder.encode(p)
        let back = try EditMaxDocument.decoder.decode(Project.self, from: data)
        XCTAssertEqual(back, p)
    }

    func testOldFilesDecodeWithDefaults() throws {
        // A minimal pre-2026-11-05 file: no formatVersion, no settings, no texts. Must open, not throw.
        let json = #"{"name":"Old","assets":[],"tracks":[{"name":"V1","kind":"video","clips":[]}]}"#
        let p = try EditMaxDocument.decoder.decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(p.formatVersion, 1)
        XCTAssertEqual(p.settings.width, 1920)
        XCTAssertEqual(p.settings.useProxies, false)
        XCTAssertEqual(p.tracks.count, 1)
        XCTAssertTrue(p.texts.isEmpty && p.markers.isEmpty)
    }
}
