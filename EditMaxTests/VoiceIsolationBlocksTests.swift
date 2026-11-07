import XCTest
import AVFoundation
@testable import EditMax

/// Voice isolation renders only the blocks of the source the timeline reads (an 18-hour stream cut down to an hour
/// renders about an hour), and a clip plays its isolated sound only once every block it reads is there.
@MainActor
final class VoiceIsolationBlocksTests: XCTestCase {
    typealias S = TestSignal
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }
    private var saved = 0.0

    override func setUp() async throws {
        doc = EditMaxDocument()
        saved = IsolatedAudio.blockSeconds
        IsolatedAudio.blockSeconds = 4   // 4-second blocks, so a 20-second file has five
    }
    override func tearDown() async throws { IsolatedAudio.blockSeconds = saved }

    func testASpanCoversItsSoundATailIntoTheNextClipAndASecondEachSide() throws {
        XCTAssertEqual(IsolatedAudio.blocks(covering: 0...4, duration: 20), [0])
        XCTAssertEqual(IsolatedAudio.blocks(covering: 3...4.5, duration: 20), [0, 1])
        XCTAssertEqual(IsolatedAudio.blocks(covering: 15...40, duration: 18), [3, 4], "never past the last block")
        var p = Project()
        let asset = Asset(name: "talk.wav", path: "/tmp/talk.wav", kind: .audio, duration: 20)
        p.assets = [asset]
        var c = Clip(assetID: asset.id, name: "c", start: 0, duration: 4); c.sourceIn = 9
        XCTAssertEqual(IsolatedAudio.span(of: c, next: nil, in: p), 8...14)
        var next = Clip(assetID: asset.id, name: "c", start: 4, duration: 3); next.audioCrossfade = .init(duration: 0.5)
        XCTAssertEqual(IsolatedAudio.span(of: c, next: next, in: p), 8...14.5, "a crossfade reads half a second past the out point")
        c.audioLead = 2   // a J cut: the sound starts 2 s earlier, from earlier in the media
        XCTAssertEqual(IsolatedAudio.span(of: c, next: nil, in: p), 6...14)
    }

    func testClipsOfOneFileAtOneAmountShareTheirBlocks() throws {
        var p = Project()
        let asset = Asset(name: "talk.wav", path: "/tmp/talk.wav", kind: .audio, duration: 20)
        p.assets = [asset]
        var a = Clip(assetID: asset.id, name: "c", start: 0, duration: 2); a.sourceIn = 1; a.audio.voiceIsolation = 1
        var b = Clip(assetID: asset.id, name: "c", start: 2, duration: 2); b.sourceIn = 13; b.audio.voiceIsolation = 1
        var c = Clip(assetID: asset.id, name: "c", start: 4, duration: 2); c.sourceIn = 13; c.audio.voiceIsolation = 0.5
        var t = Track(name: "A1", kind: .audio); t.clips = [a, b, c]; p.tracks = [t]
        let needs = IsolatedAudio.needs(p)
        XCTAssertEqual(needs.count, 2, "one render key per amount")
        XCTAssertEqual(needs[IsolatedAudio.key(for: asset, amount: 1)]?.blocks, [0, 3])
        XCTAssertEqual(needs[IsolatedAudio.key(for: asset, amount: 0.5)]?.blocks, [3])
    }

    /// The real unit, through the timeline: a clip reading 9–13 s of a 20-second file renders blocks 2 and 3 only, and the
    /// mix plays exactly their samples; lengthened into block 4 it plays the original until block 4 is rendered too.
    func testOnlyTheBlocksTheTimelineReadsAreRenderedAndTheClipPlaysExactlyThem() async throws {
        guard IsolatedAudio.isAvailable else { throw XCTSkip(IsolatedAudio.unavailableMessage) }
        let sr = 48_000
        let a = Array(S.voice(seconds: 20, level: 0.2)), b = Array(S.voice(seconds: 20, level: 0.2, seed: 9))
        let path = try S.writeWAV([a, b], to: S.scratch.appendingPathComponent("iso-blocks-\(UUID().uuidString.prefix(6)).wav")).path
        _ = try await x.importMedia(paths: [path])
        let asset = doc.project.assets[0]
        let block = { (k: Int) in IsolatedAudio.blockURL(for: asset, amount: 1, block: k) }
        defer { for k in 0..<5 { try? FileManager.default.removeItem(at: block(k)) } }
        _ = try x.insertClip(asset: asset.name, track: nil, sourceIn: 9, duration: 4)
        let t = try XCTUnwrap(doc.project.tracks.firstIndex { !$0.clips.isEmpty })
        doc.project.tracks[t].clips[0].audio.voiceIsolation = 1
        try await IsolatedAudio.shared.ensureAll(doc.project)
        let exists = { (0..<5).map { FileManager.default.fileExists(atPath: block($0).path) } }
        XCTAssertEqual(exists(), [false, false, true, true, false], "the clip reads 8–14 s: blocks 2 (8–12 s) and 3 (12–16 s)")
        XCTAssertTrue(IsolatedAudio.shared.isReady(doc.project.tracks[t].clips[0], in: doc.project))

        // Timeline 0–4 s is source 9–13 s: block 2 from its first second, then block 3's first second.
        let b2 = try VoiceIsolationFileTests.readFile(block(2)), b3 = try VoiceIsolationFileTests.readFile(block(3))
        let want = Array(b2.l[sr..<4 * sr] + b3.l[0..<sr])
        let mix = try await Loudness.render(doc.project)
        let left = stride(from: 0, to: min(mix.count, 8 * sr), by: 2).map { mix[$0] }
        XCTAssertEqual(left.count, 4 * sr)
        XCTAssertLessThan(zip(left, want).map { abs($0 - $1) }.max() ?? 1, 1e-5, "the mix plays the isolated blocks, sample for sample")

        // Lengthened to read block 4: never partly isolated, so the original plays until block 4 is there.
        doc.project.tracks[t].clips[0].duration = 7
        XCTAssertFalse(IsolatedAudio.shared.isReady(doc.project.tracks[t].clips[0], in: doc.project))
        let plain = try await Loudness.render(doc.project, seconds: 1)
        let plainLeft = stride(from: 0, to: plain.count, by: 2).map { plain[$0] }
        XCTAssertLessThan(zip(plainLeft, a[9 * sr..<10 * sr]).map { abs($0 - $1) }.max() ?? 1, 1e-4, "the original sound")
        // The preview's rebuild after the trim starts the render of what is missing, without anyone asking.
        let started = try XCTUnwrap(IsolatedAudio.shared.scheduleMissing(doc.project, delay: .zero), "block 4 is missing: a render starts")
        await started.value
        XCTAssertEqual(exists(), [false, false, true, true, true], "only block 4 was added")
        XCTAssertNil(IsolatedAudio.shared.scheduleMissing(doc.project), "nothing missing: nothing starts")
        XCTAssertTrue(IsolatedAudio.shared.isReady(doc.project.tracks[t].clips[0], in: doc.project))
    }
}
