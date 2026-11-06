import XCTest
@testable import EditMax

/// Regressions from the 2026-11-07 UI audit (ids in brackets): edits that must change exactly what they say, history
/// that records only real changes, undo steps that stay apart, and a playhead that stays on the frame grid.
@MainActor
final class AuditFixesTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .user) }
    /// What an inspector slider uses: rapid same-kind edits fold into one undo step.
    private var slider: ToolExecutor { ToolExecutor(document: doc, origin: .user, coalesce: true) }
    private var p: Project { doc.project }

    override func setUp() async throws {
        doc = EditMaxDocument()
        for (n, d) in [("ridge.mp4", 30.0), ("interview.mp4", 30.0)] {
            doc.project.assets.append(Asset(name: n, path: "/tmp/audit-\(n)", kind: .video, duration: d, width: 1920, height: 1080))
        }
        doc.project.assets.append(Asset(name: "music.m4a", path: "/tmp/audit-music.m4a", kind: .audio, duration: 60))
    }

    private func now(_ c: Clip) -> Clip { p.clip(c.id)!.clip }

    // MARK: [H2] Ripple delete of an in/out range

    func testRippleDeleteKeepsTheTailOfATitleThatSpansTheRange() throws {
        var q = Project()
        q.texts.append(TextOverlay(text: "Asha Rao", start: 0.8, duration: 4.2))   // 0.8–5.0
        q.rippleDelete(start: 1, end: 3)
        XCTAssertEqual(q.texts.count, 1)
        XCTAssertEqual(q.texts[0].start, 0.8, accuracy: 1e-9)
        XCTAssertEqual(q.texts[0].end, 3.0, accuracy: 1e-9, "the 2 s after the range stay, moved left with the picture")
    }

    func testRippleDeleteHandsOutFadesTheWayASplitDoes() throws {
        let m = try x.insertClip(asset: "music.m4a", duration: 12)   // A1 0–12
        try x.setClipFades(m.id.uuidString, fadeIn: 0.5, fadeOut: 1.5)
        let faded = now(m)
        _ = try x.rippleDelete(start: 1, end: 3)
        let pieces = p.tracks.first { $0.kind == .audio }!.clips.sorted { $0.start < $1.start }
        XCTAssertEqual(pieces.count, 2)
        let (l, r) = (pieces[0], pieces[1])
        XCTAssertEqual(l.start, 0, accuracy: 1e-9); XCTAssertEqual(l.end, 1, accuracy: 1e-9)
        XCTAssertEqual(r.start, 1, accuracy: 1e-9); XCTAssertEqual(r.end, 10, accuracy: 1e-9)
        XCTAssertEqual(r.sourceIn, 3, accuracy: 1e-9)
        XCTAssertEqual(l.fadeIn, 0.5); XCTAssertEqual(l.fadeOut, 0, "no dip in the sound at the cut")
        XCTAssertEqual(r.fadeIn, 0, "no dip in the sound at the cut"); XCTAssertEqual(r.fadeOut, 1.5)
        // The same as a plain split at 1 and 3 with the middle taken out.
        let (sl, srest) = faded.split(atLocal: 1)
        let (_, sr) = srest.split(atLocal: 2)
        XCTAssertEqual(l.fadeIn, sl.fadeIn); XCTAssertEqual(l.fadeOut, sl.fadeOut)
        XCTAssertEqual(r.fadeIn, sr.fadeIn); XCTAssertEqual(r.fadeOut, sr.fadeOut)
    }

    func testRippleDeleteMovesTheKeyframesOfTheKeptTail() throws {
        let c = try x.insertClip(asset: "ridge.mp4", duration: 10)
        _ = try x.setKeyframe(c.id.uuidString, param: "opacity", time: 6, value: 0.5, ease: nil)   // at 6 s on the timeline
        _ = try x.rippleDelete(start: 1, end: 3)
        let tail = p.tracks[0].clips.sorted { $0.start < $1.start }.last!
        XCTAssertEqual(tail.start, 1, accuracy: 1e-9)
        XCTAssertEqual(tail.keyframes(.opacity).first?.time ?? -1, 3, accuracy: 1e-9, "the keyframe stays on its frame of the picture (6 s → 4 s on the timeline)")
    }

    func testRippleDeleteMovesMarkersWithThePicture() throws {
        _ = try x.insertClip(asset: "ridge.mp4", duration: 12)
        _ = x.addMarker(at: 9.5, name: "Jump", colorHex: nil)
        _ = x.addMarker(at: 0.5, name: "Start", colorHex: nil)
        _ = try x.rippleDelete(start: 1, end: 3)
        XCTAssertEqual(p.markers.first { $0.name == "Jump" }!.time, 7.5, accuracy: 1e-9)
        XCTAssertEqual(p.markers.first { $0.name == "Start" }!.time, 0.5, accuracy: 1e-9)
    }

    // MARK: [H3] Split-edit Reset

    /// Ridge 0–5.4 then Interview 5.4–7.8 on V1, touching, both with media around them.
    private func ridgeAndInterview() throws -> (Clip, Clip) {
        let ridge = try x.insertClip(asset: "ridge.mp4", sourceIn: 5, duration: 5.4)
        let interview = try x.insertClip(asset: "interview.mp4", sourceIn: 10, duration: 2.4)
        return (ridge, interview)
    }

    func testSplitEditResetLeavesTheNeighboursOwnJCut() throws {
        let (ridge, interview) = try ridgeAndInterview()
        _ = try x.setSplitEdit(interview.id.uuidString, lead: 1, trail: nil, neighbour: nil)   // Interview's own J cut
        _ = try x.setSplitEdit(ridge.id.uuidString, lead: nil, trail: 0.5, neighbour: nil)
        // The inspector's Reset sends 0 and 0 with whatever the Neighbour picker says.
        _ = try x.setSplitEdit(ridge.id.uuidString, lead: 0, trail: 0, neighbour: "trim")
        XCTAssertEqual(now(ridge).audioLead, 0); XCTAssertEqual(now(ridge).audioTrail, 0)
        XCTAssertEqual(now(interview).audioLead, 1, "Reset changes only this clip's own lead and trail")
    }

    func testSplitEditResetLeavesAJCutThatTrimmedThisClip() throws {
        let (ridge, interview) = try ridgeAndInterview()
        _ = try x.setSplitEdit(interview.id.uuidString, lead: 1, trail: nil, neighbour: "trim")   // Ridge's sound now stops 1 s early
        XCTAssertEqual(now(ridge).audioTrail, -1, accuracy: 1e-9)
        _ = try x.setSplitEdit(ridge.id.uuidString, lead: 0, trail: 0, neighbour: "trim")
        XCTAssertEqual(now(ridge).audioTrail, 0)
        XCTAssertEqual(now(interview).audioLead, 1, "the neighbour's J cut stays")
    }

    func testSplitEditResetGivesBackTheSoundATrimTookFromTheNeighbour() throws {
        let (ridge, interview) = try ridgeAndInterview()
        _ = try x.setSplitEdit(ridge.id.uuidString, lead: nil, trail: 0.5, neighbour: "trim")
        XCTAssertEqual(now(interview).audioLead, -0.5, accuracy: 1e-9, "trim pushed the neighbour's sound back")
        _ = try x.setSplitEdit(ridge.id.uuidString, lead: 0, trail: 0, neighbour: "trim")
        XCTAssertEqual(now(interview).audioLead, 0, accuracy: 1e-9, "and a reset gives it back, so no hole is left")
    }

    // MARK: [M4] Undo steps stay apart

    func testDifferentSlidersMakeSeparateUndoSteps() throws {
        let c = try x.insertClip(asset: "ridge.mp4", duration: 5)
        for v in [1.1, 1.2, 1.3] { try slider.setClipColor(c.id.uuidString, exposure: nil, contrast: nil, saturation: v, temperature: nil, tint: nil, reset: false) }
        for v in [0.1, 0.2] { try slider.setClipColor(c.id.uuidString, exposure: v, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false) }
        XCTAssertEqual(doc.undoStack.count, 3, "insert, saturation drag, exposure drag")
        doc.undo()
        XCTAssertEqual(now(c).color.exposure, 0); XCTAssertEqual(now(c).color.saturation, 1.3, "⌘Z undoes only the exposure drag")
    }

    func testTransformSlidersOnDifferentControlsMakeSeparateUndoSteps() throws {
        let c = try x.insertClip(asset: "ridge.mp4", duration: 5)
        for v in [1.1, 1.2] { try slider.setClipTransform(c.id.uuidString, scale: v, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
        for v in [0.1, 0.2] { try slider.setClipTransform(c.id.uuidString, scale: nil, x: v, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false) }
        XCTAssertEqual(doc.undoStack.count, 3)
        doc.undo()
        XCTAssertEqual(now(c).transform.x, 0); XCTAssertEqual(now(c).transform.scale, 1.2)
    }

    func testAResetButtonNeverMergesIntoTheSliderBeforeIt() throws {
        let c = try x.insertClip(asset: "ridge.mp4", duration: 5)
        for v in [1.1, 1.3] { try slider.setClipColor(c.id.uuidString, exposure: nil, contrast: nil, saturation: v, temperature: nil, tint: nil, reset: false) }
        try slider.setClipColor(c.id.uuidString, exposure: nil, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: true)
        XCTAssertEqual(doc.undoStack.count, 3, "insert, saturation drag, reset")
        doc.undo()
        XCTAssertEqual(now(c).color.saturation, 1.3, "⌘Z after Reset brings back the graded value")
    }

    func testADoubleClickResetAfterADragIsItsOwnStep() throws {
        let c = try x.insertClip(asset: "ridge.mp4", duration: 5)
        for v in [1.2, 1.5] { try slider.setClipColor(c.id.uuidString, exposure: nil, contrast: nil, saturation: v, temperature: nil, tint: nil, reset: false) }
        try slider.setClipColor(c.id.uuidString, exposure: nil, contrast: nil, saturation: 1, temperature: nil, tint: nil, reset: false)   // back to where the drag began
        doc.undo()
        XCTAssertEqual(now(c).color.saturation, 1.5, "⌘Z undoes the reset, not the reset and the drag together")
    }

    func testAWheelsResetIsItsOwnStep() throws {
        let c = try x.insertClip(asset: "ridge.mp4", duration: 5)
        var w = ColorWheels(); w.gamma.master = 0.2
        try x.setWheels(c.id, target: .primary, w)
        for v in [0.1, 0.2] { w.lift.master = v; try slider.setWheels(c.id, target: .primary, w) }
        try slider.setWheels(c.id, target: .primary, ColorWheels())   // the card's Reset
        doc.undo()
        XCTAssertEqual(now(c).color.wheels?.lift.master ?? 0, 0.2, accuracy: 1e-9, "⌘Z undoes only the reset")
    }

    func testAKeyframedDragIsStillOneStep() throws {
        let c = try x.insertClip(asset: "ridge.mp4", duration: 5)
        _ = try x.setKeyframe(c.id.uuidString, param: "opacity", time: 0, value: 1, ease: nil)
        for v in [0.8, 0.6, 0.4] { _ = try slider.setKeyframe(c.id.uuidString, param: "opacity", time: 2, value: v, ease: nil) }   // adds the key, then moves it
        XCTAssertEqual(doc.undoStack.count, 3, "insert, first keyframe, the drag")
    }

    func testUndoEndsACoalescingRun() throws {
        let c = try x.insertClip(asset: "ridge.mp4", duration: 5)
        try slider.setClipProperties(c.id.uuidString, opacity: 0.9)
        doc.undo()
        try slider.setClipProperties(c.id.uuidString, opacity: 0.8)
        try slider.setClipProperties(c.id.uuidString, opacity: 0.7)
        XCTAssertEqual(doc.undoStack.count, 2)
        doc.undo()
        XCTAssertEqual(now(c).opacity, 1)
    }

    func testAClickReleaseNeverContinuesARun() {
        let run = EditMaxDocument.CoalesceRun(key: "Color clip", origin: .user, at: Date(), paths: ["clip:1/color/saturation"])
        let paths: Set<String> = ["clip:1/color/saturation"]
        XCTAssertTrue(EditMaxDocument.continues(run, key: "Color clip", origin: .user, paths: paths, now: Date(), backToStart: false, clickRelease: false))
        XCTAssertFalse(EditMaxDocument.continues(run, key: "Color clip", origin: .user, paths: paths, now: Date(), backToStart: false, clickRelease: true), "a button press or double-click")
        XCTAssertFalse(EditMaxDocument.continues(run, key: "Color clip", origin: .user, paths: ["clip:1/color/exposure"], now: Date(), backToStart: false, clickRelease: false))
        XCTAssertFalse(EditMaxDocument.continues(run, key: "Color clip", origin: .user, paths: paths, now: Date().addingTimeInterval(2), backToStart: false, clickRelease: false))
        XCTAssertFalse(EditMaxDocument.continues(run, key: "Color clip", origin: .agent, paths: paths, now: Date(), backToStart: false, clickRelease: false))
        XCTAssertTrue(EditMaxDocument.continues(run, key: "Color clip", origin: .user, paths: ["clip:1/color/saturation", "clip:1/color"], now: Date(), backToStart: false, clickRelease: false),
                      "a value that grows into its parent (a curve gaining a point) is the same control")
    }


    // MARK: [M9] [L1] No-op edits leave no history

    func testCloseGapsWithNoGapsRecordsNothing() throws {
        _ = try x.insertClip(asset: "ridge.mp4", duration: 5.4)
        _ = try x.insertClip(asset: "interview.mp4", duration: 2.4)
        _ = try x.insertClip(asset: "music.m4a", duration: 12)
        let (history, undo) = (p.history.count, doc.undoStack.count)
        for t in p.tracks { try x.rippleTrack(t.id.uuidString) }
        XCTAssertEqual(p.history.count, history); XCTAssertEqual(doc.undoStack.count, undo)
    }

    func testTheSameTransitionTwiceRecordsOnce() throws {
        _ = try x.insertClip(asset: "ridge.mp4", sourceIn: 0, duration: 5)
        let b = try x.insertClip(asset: "interview.mp4", sourceIn: 5, duration: 5)
        _ = try x.setTransition(b.id.uuidString, kind: "crossDissolve", duration: nil)
        let history = p.history.count
        _ = try x.setTransition(b.id.uuidString, kind: "crossDissolve", duration: nil)   // ⌘T after the toolbar button
        XCTAssertEqual(p.history.count, history)
    }

    func testAddingATransitionWithoutAKindKeepsTheOneThere() throws {
        _ = try x.insertClip(asset: "ridge.mp4", sourceIn: 0, duration: 5)
        let b = try x.insertClip(asset: "interview.mp4", sourceIn: 5, duration: 5)
        _ = try x.setTransition(b.id.uuidString, kind: "pushLeft", duration: 0.6)
        let history = p.history.count
        let r = try x.setTransition(b.id.uuidString, kind: nil, duration: nil)
        XCTAssertEqual(r.kind, "pushLeft"); XCTAssertEqual(now(b).transitionIn?.duration, 0.6)
        XCTAssertEqual(p.history.count, history, "nothing changed, nothing recorded")
    }

    func testResettingAnUnchangedValueRecordsNothing() throws {
        let c = try x.insertClip(asset: "ridge.mp4", duration: 5)
        let history = p.history.count
        try slider.setClipColor(c.id.uuidString, exposure: nil, contrast: nil, saturation: 1, temperature: nil, tint: nil, reset: false)
        try x.setFinish(c.id, ClipFinish())
        XCTAssertEqual(p.history.count, history)
    }

    func testANoOpEditKeepsRedo() throws {
        _ = try x.insertClip(asset: "ridge.mp4", duration: 5)
        _ = x.addMarker(at: 1, name: "Jump", colorHex: nil)
        let m = p.markers[0]
        doc.apply("Rename marker", origin: .user, coalesce: true) { q in q.markers[0].name = "Jump 2" }
        doc.undo()
        XCTAssertTrue(doc.canRedo)
        // Focusing the name field writes the name it shows straight back.
        doc.apply("Rename marker", origin: .user, coalesce: true) { q in if let i = q.markers.firstIndex(where: { $0.id == m.id }) { q.markers[i].name = "Jump" } }
        XCTAssertTrue(doc.canRedo, "a write that changes nothing is not an edit")
        XCTAssertEqual(doc.undoLabel, "Add marker")
    }

    // MARK: [M12] A new video track goes on top

    func testANewVideoTrackGoesAboveV1() throws {
        let r = try x.addTrack(kind: "video", name: nil)
        XCTAssertEqual(r.name, "V2"); XCTAssertEqual(r.row, 0, "the top row, which covers the rows below it")
        XCTAssertEqual(p.tracks.map(\.name), ["V2", "V1", "A1"])
        _ = try x.addTrack(kind: "audio", name: nil)
        XCTAssertEqual(p.tracks.map(\.name), ["V2", "V1", "A1", "A2"], "audio tracks still go below")
        let c = try x.insertClip(asset: "ridge.mp4")
        XCTAssertEqual(p.clip(c.id)!.track.name, "V1", "an insert without a track still goes on V1, the base track")
        let m = try x.insertClip(asset: "music.m4a")
        XCTAssertEqual(p.clip(m.id)!.track.name, "A1")
    }

    func testANewVideoTrackKeepsTheTextLaneInPlace() {
        var q = Project()
        q.textLaneRow = 1   // between V1 and A1
        _ = q.addTrack(kind: .video)
        XCTAssertEqual(q.rows.map(\.id), [q.tracks[0].id, q.tracks[1].id, Project.textRowID, q.tracks[2].id])
        q.textLaneRow = 0   // above every track
        _ = q.addTrack(kind: .video)
        XCTAssertEqual(q.rows.first?.id, Project.textRowID)
        XCTAssertEqual(q.tracks.map(\.name), ["V3", "V2", "V1", "A1"])
    }

    func testANewTrackNeverReusesAName() {
        var q = Project()
        q.tracks = [Track(name: "V3", kind: .video), Track(name: "V1", kind: .video), Track(name: "A1", kind: .audio)]
        XCTAssertEqual(q.addTrack(kind: .video).name, "V4")
    }

    // MARK: [M7] Frames

    func testTimecodeRoundsToTheNearestFrame() {
        XCTAssertEqual(Timecode.string(19.2), "00:19.06")
        XCTAssertEqual(Timecode.string(0.99999), "00:01.00")
        XCTAssertEqual(Timecode.string(2.0 / 30 - 1e-9), "00:00.02")
        XCTAssertEqual(Timecode.string(65.5, fps: 24), "01:05.12")
    }

    func testFrameStepsStayOnTheFrameGrid() {
        let player = PlayerController()
        player.seek(to: 1.0)
        for _ in 0..<6 { player.step(frames: 10, fps: 30) }
        XCTAssertEqual(player.currentTime, 3.0, accuracy: 1e-12)
        player.seek(to: 0.99833)   // what the player reports a hair before a frame
        player.step(frames: 1, fps: 30)
        XCTAssertEqual(player.currentTime, 31.0 / 30, accuracy: 1e-12)
        player.seek(to: 0)
        for _ in 0..<15 { player.step(frames: 1, fps: 29.97) }
        XCTAssertEqual(player.currentTime, 15 / 29.97, accuracy: 1e-12)
        player.step(frames: -100, fps: 30)
        XCTAssertEqual(player.currentTime, 0)
    }

    // MARK: [L10] Speed and labels

    func testSpeedIsSnappedToAHundredth() throws {
        let c = try x.insertClip(asset: "ridge.mp4", duration: 6)
        try slider.setClipProperties(c.id.uuidString, speed: 3.2109839)
        XCTAssertEqual(now(c).speed, 3.21)
        XCTAssertEqual(now(c).duration, 6 / 3.21, accuracy: 1e-9)
        XCTAssertEqual(doc.undoLabel, "Speed 3.21×")
    }

    func testClipPropertyLabelsSayWhatChanged() throws {
        let c = try x.insertClip(asset: "ridge.mp4", duration: 6)
        for v in [0.9, 0.85, 0.8] { try slider.setClipProperties(c.id.uuidString, opacity: v) }
        XCTAssertEqual(doc.undoLabel, "Opacity 80%", "a drag is one step named after where it ended")
        XCTAssertEqual(p.history.last?.label, "Opacity 80%")
        try x.setClipProperties(c.id.uuidString, volume: 0.5)
        XCTAssertEqual(doc.undoLabel, "Volume 50%")
        try x.setClipProperties(c.id.uuidString, name: "Ridge")
        XCTAssertEqual(doc.undoLabel, "Rename clip")
    }
}

/// [H1] Nest and unnest against a real clip (the sequence is rendered before nest returns).
@MainActor
final class AuditNestTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .user) }
    private var fixture: URL { Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4")! }
    private var p: Project { doc.project }

    override func setUp() async throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("video rendering is not reliable on GitHub's macOS runners") }
        doc = EditMaxDocument()
        _ = try await x.importMedia(paths: [fixture.path])
    }

    /// V1: a 0–1, b 1–2, c 2–3; A1: the clip's sound 0–2; a title 0.5–2.5 and a marker at 2.5.
    private func timeline() throws -> (Clip, Clip, Clip, Clip) {
        let a = try x.insertClip(asset: "base.mp4", duration: 1)
        let b = try x.insertClip(asset: "base.mp4", duration: 1)
        let c = try x.insertClip(asset: "base.mp4", duration: 1)
        let s = try x.insertClip(asset: "base.mp4", track: "A1", duration: 2)
        _ = try x.addText("Asha Rao", start: 0.5, duration: 2, fontSize: nil, colorHex: nil, x: nil, y: nil)
        _ = x.addMarker(at: 2.5, name: "Jump", colorHex: nil)
        return (a, b, c, s)
    }

    func testNestReplacesTheSelectionInPlace() async throws {
        let (a, b, c, s) = try timeline()
        let before = p
        let info = try await x.nestClips([a.id.uuidString], name: nil)
        let nested = try XCTUnwrap(p.allClips.first { $0.id.short == info.clip })
        XCTAssertEqual(p.clip(nested.id)!.track.name, "V1")
        XCTAssertEqual(nested.start, 0, accuracy: 1e-9); XCTAssertEqual(nested.end, 1, accuracy: 1e-9)
        for other in [b, c, s] { XCTAssertEqual(p.clip(other.id)?.clip.start, before.clip(other.id)?.clip.start, "\(other.id.short) does not move"); XCTAssertEqual(p.clip(other.id)?.clip, before.clip(other.id)?.clip) }
        XCTAssertEqual(p.texts, before.texts)
        XCTAssertEqual(p.markers, before.markers)
        XCTAssertEqual(p.duration, before.duration, accuracy: 1e-9)

        _ = try x.unnestClip(nested.id.uuidString)
        XCTAssertEqual(p.tracks.map { $0.clips.map(\.id) }, before.tracks.map { $0.clips.map(\.id) }, "unnest puts the same clips back")
        XCTAssertEqual(p.clip(a.id)?.clip, before.clip(a.id)?.clip, "with its own id, where it was")
        XCTAssertEqual(p.duration, before.duration, accuracy: 1e-9)
    }

    func testNestAroundAClipThatStaysGoesOnAFreeTrack() async throws {
        let (a, b, c, _) = try timeline()
        let before = p
        let info = try await x.nestClips([a.id.uuidString, c.id.uuidString], name: nil)   // b, between them, stays on V1
        let nested = try XCTUnwrap(p.allClips.first { $0.id.short == info.clip })
        XCTAssertEqual(p.clip(b.id)?.clip, before.clip(b.id)?.clip)
        XCTAssertEqual(nested.start, 0, accuracy: 1e-9); XCTAssertEqual(nested.end, 3, accuracy: 1e-9)
        let host = try XCTUnwrap(p.clip(nested.id)?.track)
        XCTAssertNotEqual(host.name, "V1")
        let v1 = try XCTUnwrap(p.tracks.firstIndex { $0.name == "V1" })
        XCTAssertEqual(p.tracks.firstIndex { $0.id == host.id }, v1 + 1,
                       "right under V1: b keeps playing over the group's empty middle, and a and c show through V1's holes")
        XCTAssertEqual(p.duration, before.duration, accuracy: 1e-9)
        _ = try x.unnestClip(nested.id.uuidString)
        XCTAssertEqual(p.clip(a.id)?.clip, before.clip(a.id)?.clip); XCTAssertEqual(p.clip(c.id)?.clip, before.clip(c.id)?.clip)
    }
}
