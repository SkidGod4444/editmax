import XCTest
import AVFoundation
@testable import EditMax

/// Roll, slip and slide trims, J/L cuts, relink and consolidate, scene detection, three/four-point edits and match
/// frame, smooth slow motion. Model edits are tested on the document and `ToolExecutor` directly, without rendering.
@MainActor
final class EditingTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }
    private var p: Project { doc.project }

    override func setUp() async throws {
        doc = EditMaxDocument()
        doc.project.name = "Editing"
        for (n, d) in [("a.mp4", 10.0), ("b.mp4", 10.0), ("short.mp4", 3.0)] {
            doc.project.assets.append(Asset(name: n, path: "/tmp/editing-\(n)", kind: .video, duration: d, width: 1920, height: 1080))
        }
        doc.project.assets.append(Asset(name: "still.png", path: "/tmp/editing-still.png", kind: .image, duration: 5, width: 800, height: 600))
    }

    /// Wide: a.mp4 2–6 at 0–4, Close: b.mp4 3–7 at 4–8, Tail: a.mp4 1–3 at 8–10 (all on V1, touching). Names that are not
    /// hex, since a hex name like "B" also matches clip ids by prefix.
    @discardableResult
    private func threeClips() throws -> (Clip, Clip, Clip) {
        let a = try x.insertClip(asset: "a.mp4", sourceIn: 2, duration: 4)
        let b = try x.insertClip(asset: "b.mp4", sourceIn: 3, duration: 4)
        let c = try x.insertClip(asset: "a.mp4", sourceIn: 1, duration: 2)
        try x.setClipProperties(a.id.short, name: "Wide"); try x.setClipProperties(b.id.short, name: "Close"); try x.setClipProperties(c.id.short, name: "Tail")
        return (p.clip(a.id)!.clip, p.clip(b.id)!.clip, p.clip(c.id)!.clip)
    }
    private func now(_ c: Clip) -> Clip { p.clip(c.id)!.clip }
    private func message(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }

    // MARK: Roll

    func testRollMovesTheCutAndNothingElse() throws {
        let (a, b, c) = try threeClips()
        let before = p.duration
        let r = try x.rollEdit("Wide", edge: "end", delta: 1.5, to: nil)
        XCTAssertEqual(r.cutFrom, 4); XCTAssertEqual(r.cutTo, 5.5)
        XCTAssertEqual(now(a).end, 5.5, accuracy: 1e-9); XCTAssertEqual(now(a).sourceIn, 2, accuracy: 1e-9)
        XCTAssertEqual(now(b).start, 5.5, accuracy: 1e-9); XCTAssertEqual(now(b).sourceIn, 4.5, accuracy: 1e-9)
        XCTAssertEqual(now(b).end, 8, accuracy: 1e-9, "the incoming clip's out point stays")
        XCTAssertEqual(now(c).start, 8, accuracy: 1e-9)
        XCTAssertEqual(p.duration, before, accuracy: 1e-9)
        // The same cut from the other side, back by `to`.
        _ = try x.rollEdit("Close", edge: "start", delta: nil, to: 4)
        XCTAssertEqual(now(a).end, 4, accuracy: 1e-9); XCTAssertEqual(now(b).sourceIn, 3, accuracy: 1e-9)
    }

    func testRollRefusesToRunOutOfMediaAndSaysHowFar() throws {
        try threeClips()
        // B starts at source 3, so the cut can move at most 3 s earlier... but A is only 4 s long: 3 s.
        XCTAssertThrowsError(try x.rollEdit("Wide", edge: "end", delta: -3.5, to: nil)) { e in
            XCTAssertTrue(self.message(e).contains("at most 3.00 s earlier"), self.message(e))
        }
        // A's source ends at 6 of 10: 4 s of media after its out point; B is 4 s long (minus a frame).
        XCTAssertThrowsError(try x.rollEdit("Wide", edge: "end", delta: 4, to: nil)) { e in
            XCTAssertTrue(self.message(e).contains("later"), self.message(e))
        }
        XCTAssertThrowsError(try x.rollEdit("Tail", edge: "end", delta: 0.5, to: nil), "no clip after C")
        // short.mp4 (3 s) used whole cannot grow at all.
        let s = try x.insertClip(asset: "short.mp4", at: nil, sourceIn: 0, duration: 3)
        let after = try x.insertClip(asset: "b.mp4", sourceIn: 0, duration: 2)
        XCTAssertThrowsError(try x.rollEdit(s.id.short, edge: "end", delta: 0.5, to: nil)) { e in
            XCTAssertTrue(self.message(e).contains("0.00 s of media after"), self.message(e))
        }
        XCTAssertEqual(now(after).start, now(s).end, accuracy: 1e-9, "a refused roll changes nothing")
        XCTAssertThrowsError(try x.rollEdit("Wide", edge: "middle", delta: 0.5, to: nil))
        XCTAssertThrowsError(try x.rollEdit("Wide", edge: nil, delta: 0.5, to: 4.5), "delta and to together are refused")
    }

    func testRollIsOneUndoStep() throws {
        let (a, b, _) = try threeClips()
        try x.rollEdit("Wide", edge: nil, delta: 1, to: nil)
        doc.undo()
        XCTAssertEqual(now(a).end, 4, accuracy: 1e-9); XCTAssertEqual(now(b).start, 4, accuracy: 1e-9); XCTAssertEqual(now(b).sourceIn, 3, accuracy: 1e-9)
    }

    // MARK: Slip

    func testSlipChangesSourceNotPlace() throws {
        let (_, b, c) = try threeClips()
        let r = try x.slipClip("Close", delta: 1.25, sourceIn: nil)
        XCTAssertEqual(r.sourceInTo, 4.25)
        XCTAssertEqual(now(b).start, 4, accuracy: 1e-9); XCTAssertEqual(now(b).duration, 4, accuracy: 1e-9)
        XCTAssertEqual(now(b).sourceOut, 8.25, accuracy: 1e-9)
        XCTAssertEqual(now(c).start, 8, accuracy: 1e-9)
        _ = try x.slipClip("Close", delta: nil, sourceIn: 0)
        XCTAssertEqual(now(b).sourceIn, 0, accuracy: 1e-9)
        XCTAssertThrowsError(try x.slipClip("Close", delta: -0.1, sourceIn: nil)) { e in XCTAssertTrue(self.message(e).contains("at most 0.00 s earlier"), self.message(e)) }
        XCTAssertThrowsError(try x.slipClip("Close", delta: 6.5, sourceIn: nil)) { e in XCTAssertTrue(self.message(e).contains("at most 6.00 s later"), self.message(e)) }
        let still = try x.insertClip(asset: "still.png", track: "V1", duration: 2)
        XCTAssertThrowsError(try x.slipClip(still.id.short, delta: 0.5, sourceIn: nil)) { e in XCTAssertTrue(self.message(e).contains("still"), self.message(e)) }
    }

    func testSlipKeepsKeyframesOnTheTimeline() throws {
        let (_, b, _) = try threeClips()
        _ = try x.setKeyframe("Close", param: "opacity", time: 5, value: 0.5, ease: nil)
        _ = try x.slipClip("Close", delta: 1, sourceIn: nil)
        XCTAssertEqual(now(b).keyframes(.opacity).first?.time ?? -1, 1, accuracy: 1e-9)
    }

    // MARK: Slide

    func testSlideTrimsBothNeighbours() throws {
        let (a, b, c) = try threeClips()
        let r = try x.slideClip("Close", delta: 1, to: nil)
        XCTAssertEqual(r.to, 5)
        XCTAssertEqual(now(a).end, 5, accuracy: 1e-9, "the clip before grows")
        XCTAssertEqual(now(b).start, 5, accuracy: 1e-9); XCTAssertEqual(now(b).sourceIn, 3, accuracy: 1e-9); XCTAssertEqual(now(b).duration, 4, accuracy: 1e-9)
        XCTAssertEqual(now(c).start, 9, accuracy: 1e-9); XCTAssertEqual(now(c).sourceIn, 2, accuracy: 1e-9); XCTAssertEqual(now(c).end, 10, accuracy: 1e-9)
        // Earlier: C's head would need media before source 1 → at most 1 s... from the original place. Back to 4, then to 2.9.
        _ = try x.slideClip("Close", delta: nil, to: 4)
        XCTAssertThrowsError(try x.slideClip("Close", delta: -1.1, to: nil)) { e in XCTAssertTrue(self.message(e).contains("at most 1.00 s earlier"), self.message(e)) }
        XCTAssertThrowsError(try x.slideClip("Close", delta: 2, to: nil)) { e in XCTAssertTrue(self.message(e).contains("shorter than one frame"), self.message(e)) }
        XCTAssertEqual(now(b).start, 4, accuracy: 1e-9)
    }

    func testSlideIntoAGapButNotOverAClip() throws {
        let a = try x.insertClip(asset: "a.mp4", sourceIn: 0, duration: 2)
        let b = try x.insertClip(asset: "b.mp4", sourceIn: 2, duration: 2)   // 2–4, touching a
        try x.moveClip(b.id.short, to: 2)
        let lone = try x.insertClip(asset: "a.mp4", track: "V1", sourceIn: 0, duration: 1)
        try x.moveClip(lone.id.short, to: 6)
        XCTAssertThrowsError(try x.slideClip(lone.id.short, delta: 1, to: nil)) { e in XCTAssertTrue(self.message(e).contains("move_clip"), self.message(e)) }
        // b has a before it and a gap after: it can slide later into the gap (up to the lone clip at 6).
        _ = try x.slideClip(b.id.short, delta: 1, to: nil)
        XCTAssertEqual(now(a).end, 3, accuracy: 1e-9); XCTAssertEqual(now(b).start, 3, accuracy: 1e-9)
        XCTAssertThrowsError(try x.slideClip(b.id.short, delta: 1.5, to: nil)) { e in XCTAssertTrue(self.message(e).contains("overlap"), self.message(e)) }
    }

    // MARK: J and L cuts

    func testSplitEditSetsLeadAndTrailWithinMedia() throws {
        let (a, b, _) = try threeClips()
        let r = try x.setSplitEdit("Close", lead: 1, trail: nil, neighbour: nil)
        XCTAssertEqual(r.kind, "J cut"); XCTAssertEqual(r.lead, 1); XCTAssertEqual(r.clip.soundStart, 3)
        XCTAssertEqual(r.maxLead, 3, "B starts at source 3 and at 4 s on the timeline")
        XCTAssertNotNil(r.overlaps, "A's sound plays under the lead")
        XCTAssertEqual(now(a).audioTrail, 0, "overlap leaves the neighbour alone")
        XCTAssertThrowsError(try x.setSplitEdit("Close", lead: 3.5, trail: nil, neighbour: nil)) { e in XCTAssertTrue(self.message(e).contains("it has 3.00 s"), self.message(e)) }
        let l = try x.setSplitEdit("Wide", lead: nil, trail: 2, neighbour: nil)
        XCTAssertEqual(l.kind, "L cut"); XCTAssertEqual(l.clip.soundEnd, 6)
        XCTAssertThrowsError(try x.setSplitEdit("Wide", lead: 1.5, trail: nil, neighbour: nil), "A starts at 0: no room for a lead") { e in XCTAssertTrue(self.message(e).contains("before 0"), self.message(e)) }
        // Picture media is untouched by a split edit.
        XCTAssertEqual(now(b).sourceIn, b.sourceIn); XCTAssertEqual(now(b).start, b.start)
        XCTAssertThrowsError(try x.setSplitEdit("Close", lead: nil, trail: nil, neighbour: nil))
        XCTAssertThrowsError(try x.setSplitEdit("Close", lead: 1, trail: nil, neighbour: "duck"))
    }

    func testSplitEditTrimNeighbourMovesTheAudioCut() throws {
        let (a, b, _) = try threeClips()
        let r = try x.setSplitEdit("Close", lead: 1.5, trail: nil, neighbour: "trim")
        XCTAssertEqual(now(a).audioTrail, -1.5, accuracy: 1e-9)
        XCTAssertEqual(now(a).soundEnd, now(b).soundStart, accuracy: 1e-9, "the sounds meet at the audio cut")
        XCTAssertNil(r.overlaps)
        // A negative lead with trim extends the neighbour's sound into the gap (an audio-only roll later).
        _ = try x.setSplitEdit("Close", lead: -1, trail: nil, neighbour: "trim")
        XCTAssertEqual(now(a).audioTrail, 1, accuracy: 1e-9)
        XCTAssertEqual(now(a).soundEnd, 5, accuracy: 1e-9); XCTAssertEqual(now(b).soundStart, 5, accuracy: 1e-9)
    }

    func testSplitEditRefusesAudioTracksAndStills() throws {
        doc.project.assets.append(Asset(name: "music.m4a", path: "/tmp/editing-music.m4a", kind: .audio, duration: 30))
        let m = try x.insertClip(asset: "music.m4a")
        XCTAssertThrowsError(try x.setSplitEdit(m.id.short, lead: 1, trail: nil, neighbour: nil)) { e in XCTAssertTrue(self.message(e).contains("audio track"), self.message(e)) }
        let s = try x.insertClip(asset: "still.png", duration: 2)
        XCTAssertThrowsError(try x.setSplitEdit(s.id.short, lead: 0, trail: 1, neighbour: nil)) { e in XCTAssertTrue(self.message(e).contains("still"), self.message(e)) }
    }

    func testSplitKeepsJAndLAtTheirOwnEdges() throws {
        let (_, b, _) = try threeClips()
        _ = try x.setSplitEdit("Close", lead: 1, trail: 0.5, neighbour: nil)
        let (l, r) = try x.splitClip("Close", at: 6)
        XCTAssertEqual(l.audioLead, 1); XCTAssertEqual(l.audioTrail, 0, "the left piece's sound ends at the cut")
        XCTAssertEqual(r.audioLead, 0); XCTAssertEqual(r.audioTrail, 0.5)
        XCTAssertEqual(l.id, b.id)
        // Ripple delete through a sound that extends past its picture: the L cut stops where the range begins.
        _ = try x.setSplitEdit(r.id.short, lead: nil, trail: 1.5, neighbour: nil)   // C at 8–10 is under it
        _ = try x.rippleDelete(start: 8, end: 9)
        XCTAssertEqual(now(r).audioTrail, 0, accuracy: 1e-9)
    }

    func testTrimAndSpeedRefuseToRunASplitEditOutOfMedia() throws {
        try threeClips()
        _ = try x.setSplitEdit("Close", lead: 2.5, trail: nil, neighbour: nil)   // source 0.5–3 before its in point
        XCTAssertThrowsError(try x.trimClip("Close", start: 3, end: nil), "head 1 s earlier needs 3.5 s of lead media; only 3 exist") { e in
            XCTAssertTrue(self.message(e).contains("J cut"), self.message(e))
        }
        XCTAssertThrowsError(try x.rollEdit("Close", edge: "start", delta: -1, to: nil))
        XCTAssertThrowsError(try x.setClipProperties("Close", speed: 2), "a 2.5 s lead at 2× needs 5 s of media")
        XCTAssertEqual(now(p.allClips.first { $0.name == "Close" }!).speed, 1)
    }

    func testOldProjectsDecodeWithSplitEditOff() throws {
        let c = Clip(assetID: UUID(), name: "x", start: 0, duration: 1, sourceIn: 0)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        for k in ["audioLead", "audioTrail", "smoothSlowMotion"] { XCTAssertNotNil(json.removeValue(forKey: k), k) }
        let back = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.audioLead, 0); XCTAssertEqual(back.audioTrail, 0); XCTAssertEqual(back.smoothSlowMotion, .off)
        var d = c; d.audioLead = 0.5; d.audioTrail = -0.25; d.smoothSlowMotion = .opticalFlow
        let rt = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(rt.audioLead, 0.5); XCTAssertEqual(rt.audioTrail, -0.25); XCTAssertEqual(rt.smoothSlowMotion, .opticalFlow)
    }

    // MARK: Rendering checks (real media)

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4"))
    }

    /// `CompositionBuilder.build`, retried: in the test host AVFoundation fails a fair share of builds of any project
    /// with -11800/-12780 (plain ones too, also on main), the known flake.
    private func build(_ project: Project) async throws -> CompositionBuilder.Output {
        var last: Error?
        for _ in 0..<8 {
            do { return try await CompositionBuilder.build(project) } catch { last = error; try await Task.sleep(for: .milliseconds(50)) }
        }
        throw last!
    }

    /// RMS of the mixed sound between two timeline times.
    private func rms(_ out: CompositionBuilder.Output, from t0: Double, to t1: Double) async throws -> Float {
        let tracks = try await out.composition.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: out.composition)
        let o = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        o.audioMix = out.audioMix
        reader.add(o)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: t0, preferredTimescale: 600), end: CMTime(seconds: t1, preferredTimescale: 600))
        reader.startReading()
        var sum: Double = 0, n = 0
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            var len = 0; var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            guard let ptr else { continue }
            ptr.withMemoryRebound(to: Float.self, capacity: len / 4) { f in for k in 0..<(len / 4) { sum += Double(f[k] * f[k]) } }
            n += len / 4
        }
        return n == 0 ? 0 : Float((sum / Double(n)).squareRoot())
    }

    func testJCutPlaysTheIncomingSoundUnderTheOutgoingPicture() async throws {
        let url = try fixture()
        let asset = try await MediaImporter.probe(url)
        doc.project.assets = [asset]
        let a = try x.insertClip(asset: asset.id.uuidString, sourceIn: 0, duration: 0.9)
        let b = try x.insertClip(asset: asset.id.uuidString, sourceIn: 1.0, duration: 1.0)
        try x.setClipProperties(a.id.short, volume: 0)   // only B can make sound
        let plain = try await build(p)
        let silent = try await rms(plain, from: 0.2, to: 0.8)
        let jr = try x.setSplitEdit(b.id.short, lead: 0.8, trail: nil, neighbour: nil)
        XCTAssertEqual(jr.clip.soundStart ?? -1, 0.1, accuracy: 1e-6)
        let j = try await build(p)
        let lead = try await rms(j, from: 0.2, to: 0.8)
        let body = try await rms(j, from: 1.1, to: 1.8)
        XCTAssertLessThan(silent, 0.005, "without the J cut nothing sounds under A")
        XCTAssertGreaterThan(lead, 0.02, "the J cut's sound plays before B's picture")
        XCTAssertGreaterThan(body, 0.02)
        // L cut on the last clip: the composition runs on for the trail.
        doc.project.tracks[0].clips[1].audioLead = 0
        try x.trimClip(b.id.short, start: nil, end: 1.5)   // B: source 1.0–1.6, media left: 0.4 s
        _ = try x.setSplitEdit(b.id.short, lead: nil, trail: 0.35, neighbour: nil)
        let l = try await build(p)
        XCTAssertEqual(l.duration.seconds, 1.85, accuracy: 0.01)
        let tail = try await rms(l, from: 1.55, to: 1.8)
        XCTAssertGreaterThan(tail, 0.02, "the L cut's sound runs past the last picture")
    }
}
