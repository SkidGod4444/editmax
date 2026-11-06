import XCTest
import AVFoundation
@testable import EditMax

/// Timeline export (FCPXML 1.10, CMX 3600 EDL) and ProRes masters, against the 2-second fixture clip.
/// To also check the FCPXML against Apple's DTD (not in this repo: it ships with Final Cut Pro), run the tests with
/// `TEST_RUNNER_EDITMAX_FCPXML_DTD=/path/FCPXMLv1_10.dtd`; `TEST_RUNNER_EDITMAX_INTERCHANGE_OUT=<dir>` keeps the files.
@MainActor
final class InterchangeTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }
    private var fixture: URL { Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4")! }
    private var tmp: URL!

    override func setUp() async throws {
        doc = EditMaxDocument()
        _ = try await x.importMedia(paths: [fixture.path])
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("editmax-interchange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let keep = ProcessInfo.processInfo.environment["EDITMAX_INTERCHANGE_OUT"], let files = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) {
            try? FileManager.default.createDirectory(atPath: keep, withIntermediateDirectories: true)
            for f in files { try? FileManager.default.removeItem(atPath: keep + "/" + f); try? FileManager.default.copyItem(atPath: tmp.path + "/" + f, toPath: keep + "/" + f) }
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Base track: A [0, 1.5) then B [1.5, 2.5) from 0.5 s in, dissolving in over 0.4 s with a 0.3 s fade out; A graded
    /// and at half volume. Above: a half-size clip at 2× speed. Below: the fixture's sound on A1. A title, a marker.
    private func sampleProject() throws {
        let base = try x.addTrack(kind: "video", name: "Base")
        let a = try x.insertClip(asset: "base.mp4", track: base.name, duration: 1.5)
        let b = try x.insertClip(asset: "base.mp4", track: base.name, sourceIn: 0.5, duration: 1)
        _ = try x.setTransition(b.id.short, kind: "crossDissolve", duration: 0.4)
        try x.setClipProperties(a.id.short, volume: 0.5)
        try x.setClipFades(b.id.short, fadeIn: nil, fadeOut: 0.3)
        try x.setClipColor(a.id.short, exposure: 0.3, contrast: nil, saturation: nil, temperature: nil, tint: nil, reset: false)
        // Inserting at a time ripples every track, so these go in at the end of their empty tracks and are moved after.
        let top = try x.insertClip(asset: "base.mp4", track: "V1", duration: 1)
        try x.moveClip(top.id.short, to: 0.5)
        try x.setClipProperties(top.id.short, speed: 2)
        try x.setClipTransform(top.id.short, scale: 0.5, x: 0.25, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false)
        _ = try x.insertClip(asset: "base.mp4", track: "A1", duration: 1)
        _ = try x.addText("Hello & <welcome>", start: 0.2, duration: 1, fontSize: nil, colorHex: "#FF0000", x: nil, y: nil)
        _ = x.addMarker(at: 1, name: "Chapter one", colorHex: nil)
    }

    // MARK: Time

    func testTimesAreExactFrameFractions() {
        let ntsc = Interchange.FrameRate(fps: 29.97)
        XCTAssertEqual(ntsc.frame.fcp, "1001/30000s")
        XCTAssertEqual(ntsc.time(30).fcp, "1001/1000s")
        XCTAssertEqual(Interchange.FrameRate(fps: 23.976).frame.fcp, "1001/24000s")
        let p30 = Interchange.FrameRate(fps: 30)
        XCTAssertEqual(p30.time(45).fcp, "3/2s")
        XCTAssertEqual(p30.time(60).fcp, "2s")
        XCTAssertEqual(p30.time(0).fcp, "0s")
        XCTAssertEqual(p30.timecode(p30.timebase * 3600 + 61), "01:00:02:01")
        XCTAssertEqual(Interchange.Rational(1, 30) + Interchange.Rational(1, 20), Interchange.Rational(1, 12))
    }

    func testFormatNamesParse() throws {
        XCTAssertEqual(try Interchange.Format.parse(nil), .fcpxml)
        XCTAssertEqual(try Interchange.Format.parse("Resolve"), .fcpxml)
        XCTAssertEqual(try Interchange.Format.parse("CMX 3600"), .edl)
        XCTAssertThrowsError(try Interchange.Format.parse("aaf"))
        XCTAssertEqual(ExportService.Preset.parse("prores"), .prores422hq)
        XCTAssertEqual(ExportService.Preset.parse("ProRes 422"), .prores422)
        XCTAssertEqual(ExportService.Preset.parse("prores4444"), .prores4444)
        XCTAssertEqual(ExportService.Preset.parse("hevc"), .hevc10)
        XCTAssertEqual(ExportService.Preset.parse("med"), .medium)
    }

    // MARK: FCPXML

    func testFCPXMLCarriesTheCut() async throws {
        try sampleProject()
        let r = try await x.exportTimeline(to: tmp.appendingPathComponent("cut.xml").path, format: .fcpxml)
        XCTAssertTrue(r.path.hasSuffix("/cut.fcpxml"), r.path)
        let xml = try XMLDocument(contentsOf: URL(fileURLWithPath: r.path), options: [])
        func nodes(_ q: String) throws -> [XMLElement] { try xml.nodes(forXPath: q).compactMap { $0 as? XMLElement } }
        func attr(_ e: XMLElement?, _ n: String) -> String? { e?.attribute(forName: n)?.stringValue }

        XCTAssertEqual(attr(xml.rootElement(), "version"), "1.10")
        let spine = try nodes("/fcpxml/library/event/project/sequence/spine/*")
        XCTAssertEqual(spine.map(\.name!), ["asset-clip", "transition", "asset-clip"], "the base track is the primary storyline")
        // A plays from 0 for 45 frames; the dissolve starts at the cut and lasts 12 frames; B starts at the cut, 15 frames in.
        XCTAssertEqual(attr(spine[0], "offset"), "0s"); XCTAssertEqual(attr(spine[0], "duration"), "3/2s"); XCTAssertEqual(attr(spine[0], "start"), "0s")
        XCTAssertEqual(attr(spine[1], "offset"), "3/2s"); XCTAssertEqual(attr(spine[1], "duration"), "2/5s")
        XCTAssertEqual(attr(spine[2], "offset"), "3/2s"); XCTAssertEqual(attr(spine[2], "start"), "1/2s"); XCTAssertEqual(attr(spine[2], "duration"), "1s")
        XCTAssertEqual(attr(try nodes("//sequence").first, "duration"), "5/2s")
        XCTAssertEqual(attr(try nodes("/fcpxml/library/event/project/sequence/spine/asset-clip[1]/adjust-volume").first, "amount"), "-6.0dB")
        XCTAssertNotNil(try nodes("/fcpxml/library/event/project/sequence/spine/asset-clip[2]/adjust-volume/param/fadeOut").first)

        // Every other track hangs off the first primary clip at its own start (0s here): V1 on lane 1, titles above, A1 below.
        let lanes = try nodes("/fcpxml/library/event/project/sequence/spine/asset-clip[1]/spine")
        XCTAssertEqual(lanes.compactMap { attr($0, "lane") }, ["1", "2", "-1"])
        guard lanes.count == 3 else { return }
        XCTAssertTrue(lanes.allSatisfy { attr($0, "offset") == "0s" })
        let over = try XCTUnwrap(lanes[0].elements(forName: "asset-clip").first)
        XCTAssertEqual(attr(over, "offset"), "1/2s")
        XCTAssertEqual(attr(over, "duration"), "1/2s", "1 s of source at 2× is half a second")
        XCTAssertEqual(over.elements(forName: "timeMap").first?.elements(forName: "timept").count, 2)
        XCTAssertEqual(attr(over.elements(forName: "adjust-transform").first, "scale"), "0.5 0.5")
        XCTAssertEqual(lanes[0].elements(forName: "gap").count, 1, "a gap holds the lane until the clip")
        let title = try XCTUnwrap(lanes[1].elements(forName: "title").first)
        XCTAssertEqual(title.elements(forName: "text").first?.stringValue, "Hello & <welcome>")
        XCTAssertEqual(attr(lanes[2].elements(forName: "asset-clip").first, "srcEnable"), "audio")
        let marker = try XCTUnwrap(try nodes("//marker").first)
        XCTAssertEqual(attr(marker, "start"), "1s"); XCTAssertEqual(attr(marker, "value"), "Chapter one")

        // Every time is a whole number of 30 fps frames.
        for e in try nodes("//*[@offset or @start or @duration]") {
            for name in ["offset", "start", "duration"] {
                guard let v = attr(e, name) else { continue }
                XCTAssertTrue(Self.isWholeFrames(v, fps: 30), "\(e.name!) \(name)=\(v)")
            }
        }
        // The media points at the fixture.
        XCTAssertEqual(attr(try nodes("//media-rep").first, "src"), fixture.absoluteString)

        XCTAssertTrue(r.transferred.contains { $0.hasPrefix("1 dissolve") }, "\(r.transferred)")
        XCTAssertTrue(r.notTransferred.contains { $0.hasPrefix("Color grades") }, "\(r.notTransferred)")
        XCTAssertTrue(r.sidecars.isEmpty, "no captions, no .srt")

        if let dtd = ProcessInfo.processInfo.environment["EDITMAX_FCPXML_DTD"] {
            let checked = try XMLDocument(contentsOf: URL(fileURLWithPath: r.path), options: [])
            let d = try XMLDTD(contentsOf: URL(fileURLWithPath: dtd), options: [])
            d.name = "fcpxml"
            checked.dtd = d
            XCTAssertNoThrow(try checked.validate())
        }
    }

    func testCaptionsGoToAnSRTBesideTheFCPXML() async throws {
        _ = try x.insertClip(asset: "base.mp4")
        try doc.apply("captions", origin: .agent) { p in
            var c = TextOverlay(text: "first line", start: 0.25, duration: 0.75)
            c.group = UUID()
            p.texts.append(c)
        }
        let r = try await x.exportTimeline(to: tmp.appendingPathComponent("cap").path, format: .fcpxml)
        XCTAssertEqual(r.sidecars.count, 1)
        let srt = try String(contentsOfFile: r.sidecars[0], encoding: .utf8)
        XCTAssertEqual(srt, "1\n00:00:00,250 --> 00:00:01,000\nfirst line\n")
        XCTAssertTrue(r.notTransferred.contains("Caption styles"))
    }

    // MARK: EDL

    func testEDLListsTheBaseTrackWithADissolve() async throws {
        try sampleProject()
        let r = try await x.exportTimeline(to: tmp.appendingPathComponent("cut").path, format: .edl)
        XCTAssertTrue(r.path.hasSuffix("/cut.edl"))
        XCTAssertEqual(r.clips, 2)
        let lines = try String(contentsOfFile: r.path, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "TITLE: Untitled")
        XCTAssertEqual(lines[1], "FCM: NON-DROP FRAME")
        let events = lines.filter { $0.first?.isNumber == true }
        XCTAssertEqual(events, [
            "001  AX       V     C        00:00:00:00 00:00:01:15 01:00:00:00 01:00:01:15",
            "002  AX       V     C        00:00:01:15 00:00:01:15 01:00:01:15 01:00:01:15",
            "002  AX       V     D    012 00:00:00:15 00:00:01:15 01:00:01:15 01:00:02:15",
        ])
        XCTAssertTrue(lines.contains("* FROM CLIP NAME: base.mp4"))
        XCTAssertTrue(lines.contains("* SOURCE FILE: \(fixture.path)"))
        XCTAssertTrue(r.notTransferred.contains { $0.hasPrefix("Other video tracks (V1)") }, "\(r.notTransferred)")
        XCTAssertTrue(r.notTransferred.contains { $0.hasPrefix("Sound") })
    }

    func testEDLNeedsAVideoTrack() async throws {
        try doc.apply("no video", origin: .agent) { p in p.tracks.removeAll { $0.kind == .video } }
        _ = try x.insertClip(asset: "base.mp4", track: "A1")
        do { _ = try await x.exportTimeline(to: tmp.appendingPathComponent("a").path, format: .edl); XCTFail("expected an error") } catch {}
    }

    // MARK: ProRes

    func testProResMasterIsAQuickTimeMovieWithPCMSound() async throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("video rendering is not reliable on GitHub's macOS runners") }
        _ = try x.insertClip(asset: "base.mp4", duration: 1)
        let r = try await x.exportVideo(to: tmp.appendingPathComponent("master.mp4").path, preset: .prores422hq)
        XCTAssertTrue(r.path.hasSuffix("/master.mov"), r.path)
        let asset = AVURLAsset(url: URL(fileURLWithPath: r.path))
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.05)
        let vt = try await asset.loadTracks(withMediaType: .video)
        let v = try XCTUnwrap(vt.first)
        let vfs = try await v.load(.formatDescriptions)
        let vf = try XCTUnwrap(vfs.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(vf), kCMVideoCodecType_AppleProRes422HQ)
        let size = try await v.load(.naturalSize)
        XCTAssertEqual(Int(size.width), 1920)
        let at = try await asset.loadTracks(withMediaType: .audio)
        let au = try XCTUnwrap(at.first)
        let afs = try await au.load(.formatDescriptions)
        let af = try XCTUnwrap(afs.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(af), kAudioFormatLinearPCM)
        XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee.mBitsPerChannel, 24)
    }

    func testHEVC10MasterStillRenders() async throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("video rendering is not reliable on GitHub's macOS runners") }
        _ = try x.insertClip(asset: "base.mp4", duration: 1)
        let r = try await x.exportVideo(to: tmp.appendingPathComponent("master").path, preset: .hevc10)
        XCTAssertTrue(r.path.hasSuffix("/master.mp4"), r.path)
        let vt = try await AVURLAsset(url: URL(fileURLWithPath: r.path)).loadTracks(withMediaType: .video)
        let fds = try await XCTUnwrap(vt.first).load(.formatDescriptions)
        XCTAssertEqual(fds.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_HEVC)
    }

    private static func isWholeFrames(_ v: String, fps: Int64) -> Bool {
        guard v.hasSuffix("s") else { return false }
        let parts = v.dropLast().split(separator: "/").compactMap { Int64($0) }
        let (n, d) = parts.count == 2 ? (parts[0], parts[1]) : (parts.first ?? -1, 1)
        return n >= 0 && (n * fps) % d == 0
    }
}
