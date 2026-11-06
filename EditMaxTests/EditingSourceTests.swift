import XCTest
import AVFoundation
@testable import EditMax

/// Three/four-point insert and overwrite, fit to fill, match frame. Media: a generated 8 s video (so it is not missing).
@MainActor
final class EditingSourceTests: XCTestCase {
    private static var media: URL?
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }
    private var p: Project { doc.project }
    private var asset: Asset!

    override func setUp() async throws {
        if Self.media == nil {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("editing-source-\(UUID().uuidString.prefix(8)).mp4")
            try await EditingTestVideo.write(to: u, seconds: 8, cuts: [4])
            Self.media = u
        }
        doc = EditMaxDocument()
        var a = try await MediaImporter.probe(Self.media!); a.name = "Interview"
        asset = a
        doc.project.assets.append(a)
    }
    override class func tearDown() { if let m = media { try? FileManager.default.removeItem(at: m) }; media = nil }
    private func message(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }
    private var v1: [Clip] { p.tracks[0].clips }
    /// Puts a clip on a track at a time without moving anything (test setup; insertClip(at:) is a ripple insert).
    private func place(on track: UUID, at start: Double, sourceIn: Double, duration: Double) -> Clip {
        let c = Clip(assetID: asset.id, name: "Other", start: start, duration: duration, sourceIn: sourceIn)
        doc.project.tracks[doc.project.tracks.firstIndex { $0.id == track }!].clips.append(c)
        return c
    }

    func testThreePointInsertSplitsAndRipplesEveryTrack() throws {
        let wide = try x.insertClip(asset: "Interview", sourceIn: 0, duration: 6)        // V1 0–6
        let other = p.addTrackCopy(kind: .video, in: doc)                                  // a second video track
        let late = place(on: other, at: 4, sourceIn: 0, duration: 1)   // 4–5 there (placed, not a ripple insert)
        let r = try x.pointEdit(overwrite: false, asset: "Interview", sourceIn: 1, sourceOut: 3, timelineIn: 2, timelineOut: nil, track: nil)
        XCTAssertEqual(r.timelineOut, 4); XCTAssertEqual(r.speed, 1); XCTAssertEqual(r.rippled, 2)
        XCTAssertEqual(v1.map(\.start), [0, 2, 4]); XCTAssertEqual(v1.map(\.duration), [2, 2, 4])
        XCTAssertEqual(v1[0].id, wide.id); XCTAssertEqual(v1[1].sourceIn, 1)
        XCTAssertEqual(p.clip(late.id)?.clip.start, 6, "the other track ripples too, so nothing drifts out of sync")
        doc.undo(); XCTAssertEqual(v1.count, 1, "one undo step")
    }

    func testBacktimedAndFitToFill() throws {
        let back = try x.pointEdit(overwrite: false, asset: "Interview", sourceIn: 1, sourceOut: 2.5, timelineIn: nil, timelineOut: 4, track: nil)
        XCTAssertEqual(back.timelineIn, 2.5)
        doc.undo()
        let fit = try x.pointEdit(overwrite: false, asset: "Interview", sourceIn: 0, sourceOut: 2, timelineIn: 0, timelineOut: 4, track: nil)
        XCTAssertTrue(fit.fitToFill); XCTAssertEqual(fit.speed, 0.5)
        let c = v1[0]
        XCTAssertEqual(c.duration, 4); XCTAssertEqual(c.speed, 0.5); XCTAssertEqual(c.sourceOut, 2, accuracy: 1e-9)
        do { _ = try x.pointEdit(overwrite: false, asset: "Interview", sourceIn: 0, sourceOut: 8, timelineIn: 0, timelineOut: 0.5, track: nil); XCTFail("16× is outside 0.1–10×") }
        catch { XCTAssertTrue(message(error).contains("speed"), message(error)) }
    }

    func testOverwriteReplacesOneTrackOnly() throws {
        let base = try x.insertClip(asset: "Interview", sourceIn: 0, duration: 6)
        let other = p.addTrackCopy(kind: .video, in: doc)
        let up = place(on: other, at: 0, sourceIn: 0, duration: 6)
        let r = try x.pointEdit(overwrite: true, asset: "Interview", sourceIn: 5, sourceOut: nil, timelineIn: 2, timelineOut: 3, track: p.tracks[0].id.uuidString)
        XCTAssertEqual(r.replaced, [base.name]); XCTAssertNil(r.rippled)
        XCTAssertEqual(v1.map(\.start), [0, 2, 3]); XCTAssertEqual(v1.map(\.end), [2, 3, 6])
        XCTAssertEqual(v1[1].sourceIn, 5); XCTAssertEqual(v1[2].sourceIn, 3, accuracy: 1e-9, "the right piece keeps its own media")
        XCTAssertEqual(p.clip(up.id)?.clip.start, 0); XCTAssertEqual(p.clip(up.id)?.clip.duration, 6, "the other track is untouched")
        // Over the end of the timeline: nothing to replace, nothing moves.
        let tail = try x.pointEdit(overwrite: true, asset: "Interview", sourceIn: 0, sourceOut: 1, timelineIn: 7, timelineOut: nil, track: p.tracks[0].id.uuidString)
        XCTAssertNil(tail.replaced); XCTAssertEqual(v1.last?.start, 7)
    }

    func testRefusals() throws {
        let cases: [(Double?, Double?, Double?, Double?, String)] = [
            (0, 9, 0, nil, "past the end"),          // source out past the 8 s media
            (0, 2, nil, nil, "three of"),            // two points, no playhead in tests
            (3, 2, 0, nil, "at least a frame"),      // out before in
            (0, 2, nil, 1, "before the start of the timeline"),
        ]
        for (a, b, c, d, want) in cases {
            do { _ = try x.pointEdit(overwrite: false, asset: "Interview", sourceIn: a, sourceOut: b, timelineIn: c, timelineOut: d, track: nil); XCTFail("must refuse: \(want)") }
            catch { XCTAssertTrue(message(error).contains(want), "\(message(error)) should say \(want)") }
        }
        let audio = p.addTrackCopy(kind: .audio, in: doc)
        do { _ = try x.pointEdit(overwrite: true, asset: "Interview", sourceIn: 0, sourceOut: 1, timelineIn: 0, timelineOut: nil, track: audio.uuidString); XCTFail("video on an audio track") }
        catch { XCTAssertTrue(message(error).contains("audio track"), message(error)) }
        XCTAssertTrue(p.allClips.isEmpty, "nothing placed by a refused edit")
    }

    func testMatchFrameFollowsSpeedAndTopTrack() throws {
        let fast = try x.insertClip(asset: "Interview", sourceIn: 1, duration: 3)
        try x.setClipProperties(fast.id.short, speed: 2)
        let m = try x.matchFrame(clip: nil, time: 1)
        XCTAssertEqual(m.clip.id, fast.id.short); XCTAssertEqual(m.sourceTime, 3, accuracy: 1e-6, "1 s into a 2× clip from source 1 = source 3")
        XCTAssertEqual(m.assetName, "Interview")
        do { _ = try x.matchFrame(clip: nil, time: 50); XCTFail("no picture there") } catch { XCTAssertTrue(message(error).contains("no picture")) }
        // Another clip covering the same time on a higher row wins.
        let top = p.tracks[0].id
        let lower = p.addTrackCopy(kind: .video, in: doc)
        _ = place(on: lower, at: 0, sourceIn: 6, duration: 2)
        XCTAssertEqual(p.tracks.firstIndex { $0.id == top }, 0, "the new track is below")
        XCTAssertEqual(try x.matchFrame(clip: nil, time: 1).clip.id, fast.id.short)
    }
}

@MainActor private extension Project {
    /// Adds a track through the document (undoable like any edit) and returns its id.
    func addTrackCopy(kind: TrackKind, in doc: EditMaxDocument) -> UUID {
        var id = UUID()
        doc.apply("Add track", origin: .agent) { p in id = p.addTrack(kind: kind).id }
        return id
    }
}
