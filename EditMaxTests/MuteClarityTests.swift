import XCTest
import AVFoundation
@testable import EditMax

/// A track left out of the sound is said plainly: the header says Muted (or why it is silent), an export warns before it
/// starts, and an agent's export result lists it.
@MainActor
final class MuteClarityTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }
    private var p: Project { doc.project }
    private var dir: URL!

    override func setUp() async throws {
        doc = EditMaxDocument()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mute-clarity-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func silenced() async -> [Mixer.Silenced] { await Mixer.silencedTracks(in: p) }
    private func track(_ name: String) -> Track { p.tracks.first { $0.name == name }! }

    /// A silent picture file, a tone, and a picture file with the tone as its sound.
    private func media() async throws -> (silentVideo: Asset, tone: Asset, videoWithSound: Asset) {
        let video = dir.appendingPathComponent("picture.mp4"), tone = dir.appendingPathComponent("tone.m4a"), both = dir.appendingPathComponent("both.mov")
        try await EditingTestVideo.write(to: video, seconds: 2, cuts: [])
        try await VideoContextTests.writeTone(to: tone, seconds: 2, silentAfter: 2)
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        let v = AVURLAsset(url: video), a = AVURLAsset(url: tone)
        try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: try await v.loadTracks(withMediaType: .video)[0], at: .zero)
        try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: try await a.loadTracks(withMediaType: .audio)[0], at: .zero)
        let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: both, as: .mov)
        var out: [Asset] = []
        for u in [video, tone, both] { let asset = try await MediaImporter.probe(u); doc.project.assets.append(asset); out.append(asset) }
        return (out[0], out[1], out[2])
    }

    func testOnlyTracksWithSoundThatIsLeftOutAreListed() async throws {
        let m = try await media()
        _ = try x.insertClip(asset: m.silentVideo.id.short)                       // V1: picture only
        _ = try x.insertClip(asset: m.tone.id.short)                              // A1: a tone
        let empty = try x.addTrack(kind: "audio", name: "A2")
        var none = await silenced()
        XCTAssertEqual(none, [], "nothing is muted")

        _ = try await x.setTrackMix("V1", gain: nil, pan: nil, solo: nil, mute: true, bus: nil)
        _ = try await x.setTrackMix(empty.name, gain: nil, pan: nil, solo: nil, mute: true, bus: nil)
        none = await silenced()
        XCTAssertEqual(none, [], "a muted row of silent pictures and an empty muted track raise nothing")

        _ = try await x.setTrackMix("A1", gain: nil, pan: nil, solo: nil, mute: true, bus: nil)
        let muted = await silenced()
        XCTAssertEqual(muted, [Mixer.Silenced(track: "A1", reason: .muted)])
        XCTAssertEqual(muted[0].text, "A1 is muted")

        // A video file with sound on a muted video track is listed: the case that left the engine out of three exports.
        let v2 = try x.addTrack(kind: "video", name: "V2")
        _ = try x.insertClip(asset: m.videoWithSound.id.short, track: v2.name)
        _ = try await x.setTrackMix(v2.name, gain: nil, pan: nil, solo: nil, mute: true, bus: nil)
        let withV2 = await silenced()
        XCTAssertEqual(withV2.map(\.track).sorted(), ["A1", "V2"])

        // Turn Sound On hears them all again, in one undoable edit.
        let before = p
        doc.apply("Turn sound on for export", origin: .user) { q in Mixer.turnSoundOn(withV2, in: &q) }
        XCTAssertFalse(track("A1").isMuted); XCTAssertFalse(track("V2").isMuted)
        XCTAssertTrue(track("V1").isMuted, "a track that was not listed keeps its mute")
        doc.undo()
        XCTAssertEqual(p.tracks.map(\.isMuted), before.tracks.map(\.isMuted))
    }

    func testSoloAndMutedBusAreNamedWithTheirReason() async throws {
        let m = try await media()
        _ = try x.insertClip(asset: m.tone.id.short)                              // A1
        let a2 = try x.addTrack(kind: "audio", name: "A2")
        _ = try x.insertClip(asset: m.tone.id.short, track: a2.name)
        _ = try await x.setTrackMix(a2.name, gain: nil, pan: nil, solo: true, mute: nil, bus: nil)
        let solo = await silenced()
        XCTAssertEqual(solo, [Mixer.Silenced(track: "A1", reason: .solo)])
        XCTAssertEqual(solo[0].text, "A1 is silent because another track is soloed")
        XCTAssertEqual(TimelineView.headerStatus(track("A1"), in: p)?.text, "Silent")
        XCTAssertEqual(TimelineView.headerStatus(track("A1"), in: p)?.why, "Silent because another track is soloed")
        XCTAssertNil(TimelineView.headerStatus(track(a2.name), in: p))

        doc.apply("Turn sound on", origin: .user) { q in Mixer.turnSoundOn(solo, in: &q) }
        XCTAssertFalse(p.tracks.contains { $0.mix.solo }, "every solo is cleared")
        let cleared = await silenced()
        XCTAssertEqual(cleared, [])

        _ = try x.setBus("Music", rename: nil, gain: nil, mute: true, compressor: nil, removeCompressor: false, limiter: nil, removeLimiter: false, remove: false)
        _ = try await x.setTrackMix("A1", gain: nil, pan: nil, solo: nil, mute: nil, bus: "Music")
        let bus = await silenced()
        XCTAssertEqual(bus, [Mixer.Silenced(track: "A1", reason: .bus, bus: "Music")])
        XCTAssertEqual(bus[0].text, "A1 is silent because its bus Music is muted")
        XCTAssertEqual(TimelineView.headerStatus(track("A1"), in: p)?.why, "Silent because its bus Music is muted")
        doc.apply("Turn sound on", origin: .user) { q in Mixer.turnSoundOn(bus, in: &q) }
        XCTAssertEqual(p.mix.buses.first?.isMuted, false)
    }

    func testHeaderSaysMutedOrHidden() async throws {
        let m = try await media()
        _ = try x.insertClip(asset: m.silentVideo.id.short)
        XCTAssertNil(TimelineView.headerStatus(track("V1"), in: p), "a normal track shows its kind")
        _ = try await x.setTrackMix("V1", gain: nil, pan: nil, solo: nil, mute: true, bus: nil)
        XCTAssertEqual(TimelineView.headerStatus(track("V1"), in: p)?.text, "Muted")
        doc.apply("Hide V1", origin: .user) { q in q.tracks[0].isHidden = true }
        XCTAssertEqual(TimelineView.headerStatus(track("V1"), in: p)?.text, "Hidden")
    }

    func testAgentExportListsTheTracksLeftOut() async throws {
        let m = try await media()
        _ = try x.insertClip(asset: m.videoWithSound.id.short)
        let clean = try await x.exportVideo(to: dir.appendingPathComponent("clean.mp4").path, preset: .low)
        XCTAssertNil(clean.warnings)
        _ = try await x.setTrackMix("V1", gain: nil, pan: nil, solo: nil, mute: true, bus: nil)
        let r = try await x.exportVideo(to: dir.appendingPathComponent("muted.mp4").path, preset: .low)
        let w = try XCTUnwrap(r.warnings)
        XCTAssertEqual(w.first, "V1 is muted: its sound is not in this file")
        XCTAssertTrue(w.last!.contains("set_track_mix"), "\(w)")
        // The tool description tells the agent to pass it on.
        let tool = try XCTUnwrap(EditMaxTools.tools.first { $0.name == "export_video" })
        XCTAssertTrue(tool.description?.contains("warnings") == true)
    }

    /// "Don't ask again" covers exactly the tracks the user saw: muting another one, or unmuting one, asks again.
    func testDontAskAgainHoldsOnlyForTheSameSilentTracks() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "mute-clarity-\(UUID().uuidString)"))
        let project = UUID(), other = UUID()
        let camera = [Mixer.Silenced(track: "V1", reason: .muted)]
        XCTAssertFalse(SoundCheck.isQuiet(camera, project: project, defaults: defaults))
        SoundCheck.remember(camera, project: project, defaults: defaults)
        XCTAssertTrue(SoundCheck.isQuiet(camera, project: project, defaults: defaults))
        XCTAssertFalse(SoundCheck.isQuiet(camera, project: other, defaults: defaults), "only for that project")
        XCTAssertFalse(SoundCheck.isQuiet(camera, project: nil, defaults: defaults), "an unsaved project always asks")
        XCTAssertFalse(SoundCheck.isQuiet(camera + [Mixer.Silenced(track: "A1", reason: .muted)], project: project, defaults: defaults),
                       "another track muted since: ask again")
        XCTAssertFalse(SoundCheck.isQuiet([Mixer.Silenced(track: "V1", reason: .solo)], project: project, defaults: defaults),
                       "the same track silent for another reason: ask again")
        let two = [Mixer.Silenced(track: "A1", reason: .muted), Mixer.Silenced(track: "V1", reason: .muted)]
        SoundCheck.remember(two, project: project, defaults: defaults)
        XCTAssertTrue(SoundCheck.isQuiet(two.reversed(), project: project, defaults: defaults), "order does not matter")
    }
}
