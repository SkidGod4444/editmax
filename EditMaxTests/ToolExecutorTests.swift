import XCTest
@testable import EditMax

/// The string-addressed API the MCP tools and the UI share: names, short ids, validation and the summaries agents read.
@MainActor
final class ToolExecutorTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }

    override func setUp() async throws {
        doc = EditMaxDocument()
        doc.project.name = "Test"
        for (n, d) in [("a.mp4", 10.0), ("b.mp4", 4.0)] {
            doc.project.assets.append(Asset(name: n, path: "/tmp/\(n)", kind: .video, duration: d, width: 1920, height: 1080))
        }
        doc.project.assets.append(Asset(name: "music.m4a", path: "/tmp/music.m4a", kind: .audio, duration: 30))
    }

    func testResolvesByNameShortIDAndFullID() throws {
        let c = try x.insertClip(asset: "a.mp4")
        XCTAssertEqual(try x.resolveClip(c.id.uuidString), c.id)
        XCTAssertEqual(try x.resolveClip(c.id.short), c.id)
        XCTAssertEqual(try x.resolveAsset("b.mp4"), doc.project.assets[1].id)
        XCTAssertThrowsError(try x.resolveAsset("nothing.mov")) { XCTAssertTrue("\($0)".contains("nothing.mov")) }
        XCTAssertThrowsError(try x.resolveTrack("V9"))
    }

    func testAudioAssetsLandOnAnAudioTrack() throws {
        let c = try x.insertClip(asset: "music.m4a")
        XCTAssertEqual(doc.project.clip(c.id)!.track.kind, .audio)
        XCTAssertThrowsError(try x.insertClip(asset: "music.m4a", track: "V1"), "audio on a video track is refused")
    }

    func testInspectTimelineDescribesTheProject() throws {
        _ = try x.insertClip(asset: "a.mp4")
        _ = try x.addMarker(at: 3, name: "m", colorHex: nil)
        try x.setProjectSettings(width: nil, height: nil, fps: nil, name: nil, useProxies: true)
        let s = x.inspectTimeline()
        XCTAssertEqual(s.project, "Test")
        XCTAssertEqual(s.clips.count, 1)
        XCTAssertEqual(s.clips[0].track, "V1")
        XCTAssertEqual(s.markers.first?.name, "m")
        XCTAssertEqual(s.tracks.map(\.name), ["V1", "A1"])
        XCTAssertTrue(s.useProxies)
        XCTAssertEqual(s.duration, 10, accuracy: 0.001)
        XCTAssertNil(s.clips[0].transform, "defaults are left out of the summary")
    }

    func testTextsAndCaptionsBookkeeping() throws {
        let t = try x.addText("Hello", start: 1, duration: 2, fontSize: nil, colorHex: nil, x: nil, y: nil)
        XCTAssertEqual(doc.project.texts.count, 1)
        XCTAssertEqual(doc.project.texts[0].text, "Hello")
        XCTAssertEqual(try x.removeTexts([t.id.short]), 1)
        XCTAssertTrue(doc.project.texts.isEmpty)
        XCTAssertThrowsError(try x.addText("", start: 0, duration: 1, fontSize: nil, colorHex: nil, x: nil, y: nil))
    }

    func testTransitionNeedsAPrecedingClipOnTheTrack() throws {
        let a = try x.insertClip(asset: "a.mp4", duration: 3)
        let first = try x.setTransition(a.id.short, kind: "crossDissolve", duration: 0.5)
        XCTAssertNotNil(first.note, "nothing ends before the first clip: allowed, from black, with a note the agent can read")
        let b = try x.insertClip(asset: "b.mp4")
        let r = try x.setTransition(b.id.short, kind: "crossDissolve", duration: 0.5)
        XCTAssertEqual(r.kind, "crossDissolve")
        XCTAssertNil(r.note)
        XCTAssertNotNil(doc.project.clip(b.id)!.clip.transitionIn)
        XCTAssertThrowsError(try x.setTransition(b.id.short, kind: "wobble", duration: nil), "unknown kinds are refused")
    }

    func testKeyframesRoundTrip() throws {
        let c = try x.insertClip(asset: "a.mp4")
        _ = try x.setKeyframe(c.id.short, param: "opacity", time: 0, value: 1, ease: nil)
        _ = try x.setKeyframe(c.id.short, param: "opacity", time: 5, value: 0, ease: "smooth")
        XCTAssertEqual(x.inspectTimeline().clips[0].keyframes?["opacity"]?.count, 2)
        XCTAssertEqual(try x.removeKeyframe(c.id.short, param: "opacity", time: nil, all: true), 2)
        XCTAssertThrowsError(try x.setKeyframe(c.id.short, param: "flavour", time: 0, value: 1, ease: nil))
    }

    func testMarkersAndTracks() throws {
        let m = try x.addMarker(at: 2, name: "two", colorHex: "#ff0000")
        XCTAssertEqual(doc.project.markers.count, 1)
        try x.removeMarker(m.id)
        XCTAssertTrue(doc.project.markers.isEmpty)
        XCTAssertThrowsError(try x.removeMarker("ghost"))
        _ = try x.addTrack(kind: "video", name: nil)
        _ = try x.addTrack(kind: "audio", name: "VO")
        XCTAssertEqual(doc.project.tracks.map(\.name), ["V2", "V1", "A1", "VO"])
        XCTAssertThrowsError(try x.addTrack(kind: "midi", name: nil))
    }

    func testRippleDeleteRangeThroughTheExecutor() throws {
        _ = try x.insertClip(asset: "a.mp4")
        let r = try x.rippleDelete(start: 2, end: 5)
        XCTAssertEqual(r.removedSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(doc.project.duration, 7, accuracy: 0.001)
        XCTAssertThrowsError(try x.rippleDelete(start: 5, end: 2))
    }

    func testTemplatesListAndApply() throws {
        let list = x.listTemplates()
        XCTAssertFalse(list.isEmpty)
        let shorts = list.first { $0.name.hasPrefix("Shorts") }!
        _ = try x.applyTemplate(shorts.name)
        XCTAssertEqual(doc.project.settings.width, 1080)
        XCTAssertEqual(doc.project.settings.height, 1920)
        XCTAssertThrowsError(try x.applyTemplate("No such template"))
    }
}

/// Texts never sit on top of each other: the frame nudges a new one clear, the summary names overlaps, the lane stacks.
@MainActor
final class TextLayoutTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }
    override func setUp() async throws { doc = EditMaxDocument() }

    func testATitleAddedOverAnotherMovesToAFreeBand() throws {
        let a = try x.addText("GOLDEN HOUR", start: 0, duration: 4, fontSize: 96, colorHex: nil, x: nil, y: 0.5)
        let b = try x.addText("City at dusk", start: 1, duration: 3, fontSize: 34, colorHex: nil, x: nil, y: 0.5)
        XCTAssertEqual(a.y, 0.5)
        XCTAssertNotEqual(b.y, 0.5, "the second text is moved off the first")
        XCTAssertGreaterThan(b.y, 0.5, "below first")
        XCTAssertFalse(TextLayout.collide(a, b, canvas: doc.project.settings.canvas))
        XCTAssertNil(x.inspectTimeline().textOverlaps)
    }

    func testTextsAtDifferentTimesKeepTheirPlace() throws {
        _ = try x.addText("One", start: 0, duration: 2, fontSize: nil, colorHex: nil, x: nil, y: 0.5)
        let b = try x.addText("Two", start: 2, duration: 2, fontSize: nil, colorHex: nil, x: nil, y: 0.5)
        XCTAssertEqual(b.y, 0.5)
    }

    func testInspectTimelineReportsOverlapsMadeByHand() throws {
        doc.project.texts = [TextOverlay(text: "A", start: 0, duration: 4, y: 0.5), TextOverlay(text: "B", start: 1, duration: 4, y: 0.5)]
        let o = x.inspectTimeline().textOverlaps
        XCTAssertEqual(o?.count, 1)
        XCTAssertTrue(o![0].contains("'A' and 'B'"))
        XCTAssertTrue(o![0].contains("1.0–4.0"))
    }

    func testLaneRowsStackOnlyConcurrentTexts() {
        let a = TextOverlay(text: "a", start: 0, duration: 4), b = TextOverlay(text: "b", start: 1, duration: 2), c = TextOverlay(text: "c", start: 5, duration: 1)
        let rows = TextLayout.laneRows([a, b, c])
        XCTAssertEqual(rows[a.id], 0); XCTAssertEqual(rows[b.id], 1); XCTAssertEqual(rows[c.id], 0, "after both ended, back to the first row")
        XCTAssertEqual(Set(TextLayout.laneRows([a, c]).values), [0], "nothing concurrent, nothing stacked")
    }
}

/// The MCP layer itself: a wrong argument name is an error, never a silent no-op.
final class ToolCatalogTests: XCTestCase {
    func testUnknownArgumentsAreRejectedWithTheRealNames() async {
        do {
            _ = try await EditMaxTools.call("remove_texts", ["texts": .array([.string("abc")])])
            XCTFail("expected an error")
        } catch {
            let m = "\(error)"
            XCTAssertTrue(m.contains("'texts'"), m)
            XCTAssertTrue(m.contains("ids"), m)
        }
    }

    func testEveryToolDeclaresItsArguments() {
        for t in EditMaxTools.tools { XCTAssertNotNil(EditMaxTools.argumentNames(of: t.name), t.name) }
        XCTAssertEqual(EditMaxTools.argumentNames(of: "remove_texts"), ["ids", "project"])
    }
}

/// The Claude Agent SDK never runs without an API key: no fallback to a Claude subscription login, even if an older
/// sidecar still reports the key as optional.
final class ProviderKeyTests: XCTestCase {
    private func provider(_ id: String, keyOptional: Bool, needsClaude: Bool) -> CodemaxRunner.ProviderInfo {
        .init(id: id, name: id, keySlot: "anthropic", keyEnv: "ANTHROPIC_API_KEY", keyOptional: keyOptional, defaultModel: nil, models: [], needsClaude: needsClaude, hasClaude: true)
    }

    func testTheAgentSDKAlwaysNeedsAKey() {
        XCTAssertTrue(ChatSession.keyRequired(provider("claude-agent", keyOptional: false, needsClaude: true)))
        XCTAssertTrue(ChatSession.keyRequired(provider("claude-agent", keyOptional: true, needsClaude: true)), "an older sidecar's 'optional' is overruled")
    }

    func testOtherProvidersFollowTheSidecar() {
        XCTAssertTrue(ChatSession.keyRequired(provider("anthropic", keyOptional: false, needsClaude: false)))
        XCTAssertFalse(ChatSession.keyRequired(provider("local", keyOptional: true, needsClaude: false)))
    }
}

/// A failed agent turn shows one card in plain words, not the friendly card plus the adapter's raw error under it.
@MainActor
final class ChatErrorTests: XCTestCase {
    func testAFailedTurnShowsOnePlainCard() {
        let chat = ChatSession(document: EditMaxDocument())
        chat.appendError("Internal error: Claude ended the turn without returning results for tool calls: srvtoolu_01 {\"errorKind\":\"incomplete_tool_call\"}")
        chat.appendError("Claude ended the turn without returning results for tool calls: srvtoolu_01 {\"errorKind\":\"incomplete_tool_call\"}")
        let errors = chat.items.filter { $0.kind == .error }
        XCTAssertEqual(errors.count, 1)
        XCTAssertFalse(errors[0].text.contains("srvtoolu"), "no raw ids in front of the user")
        XCTAssertTrue(errors[0].text.contains("continue"))
    }

    /// The PostHog "EditMax.Agent.protocol" report: the agent wrote its whole reply, then a server tool it had called
    /// (the advisor, from the person's own Claude Code settings) never answered, and the finished turn read as failed.
    func testAReplyThatLeftAToolOpenIsANoteNotAnError() {
        let chat = ChatSession(document: EditMaxDocument())
        chat.turnReplied = true
        let raw = "Internal error: Claude ended the turn without returning results for tool calls: srvtoolu_01 {\"errorKind\":\"incomplete_tool_call\"}"
        chat.appendError(raw)
        chat.appendError(raw)   // the turn's result repeats it
        XCTAssertTrue(chat.items.filter { $0.kind == .error }.isEmpty)
        XCTAssertEqual(chat.items.filter { $0.kind == .note }.count, 1)
        chat.turnReplied = false
        chat.appendError(raw)
        XCTAssertEqual(chat.items.filter { $0.kind == .error }.count, 1, "with no reply it is still a failure")
    }

    func testTheHarnessErrorKindNamesTheIssue() {
        XCTAssertEqual(Telemetry.errorKind(in: "Claude ended the turn: srvtoolu_01 {\"errorKind\":\"incomplete_tool_call\"}"), "incomplete_tool_call")
        XCTAssertEqual(Telemetry.errorKind(in: "{\"errorKind\" : \"max_turns\"}"), "max_turns")
        XCTAssertNil(Telemetry.errorKind(in: "The operation timed out."))
        XCTAssertNil(Telemetry.errorKind(in: "{\"errorKind\":\"/Users/me/secret.mov\"}"), "never a path or text")
    }

    /// Every tool the agent's instructions name exists: a renamed tool would leave the agent calling one that is gone.
    func testTheInstructionsNameOnlyRealTools() throws {
        let names = Set(EditMaxTools.tools.map(\.name))
        let re = try NSRegularExpression(pattern: #"\b[a-z]+(?:_[a-z]+)+\b"#)
        let text = ChatSession.agentInstructions
        let cited = Set(re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
        let notTools: Set<String> = ["input_lut", "look_mix", "high_pass", "voice_isolation", "optical_flow", "max_words", "turn_text"]
        XCTAssertEqual(cited.subtracting(names).subtracting(notTools), [], "named in the instructions but not a tool")
        XCTAssertTrue(text.contains("November 2026"), "the reels paragraph says when it was true")
    }

    func testDifferentFailuresStillShowEach() {
        let chat = ChatSession(document: EditMaxDocument())
        chat.appendError("429 rate limit")
        chat.appendError("The operation timed out.")
        XCTAssertEqual(chat.items.filter { $0.kind == .error }.count, 2)
    }
}
