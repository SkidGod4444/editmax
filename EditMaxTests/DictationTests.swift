import XCTest
@testable import EditMax

/// What is heard joins what was typed the way a person would write it: one space between, none before punctuation.
final class DictationTests: XCTestCase {
    func testSpeechJoinsWhatWasTyped() {
        XCTAssertEqual(Dictation.merge(base: "", heard: "Make the first clip faster."), "Make the first clip faster.")
        XCTAssertEqual(Dictation.merge(base: "Add music", heard: "and fade it out"), "Add music and fade it out")
        XCTAssertEqual(Dictation.merge(base: "Add music ", heard: "and fade it out"), "Add music and fade it out", "no double space")
        XCTAssertEqual(Dictation.merge(base: "Add music", heard: ""), "Add music", "nothing heard leaves the field as it was")
    }

    func testPiecesOfSpeechReadAsOneSentence() {
        XCTAssertEqual(Dictation.join("Cut at the beat.", "Then add a title."), "Cut at the beat. Then add a title.")
        XCTAssertEqual(Dictation.join("Cut here", ", then fade"), "Cut here, then fade", "no space before a comma")
        XCTAssertEqual(Dictation.join("Is it too long", "?"), "Is it too long?")
        XCTAssertEqual(Dictation.join("Louder", "  please  "), "Louder please", "the recognizer's padding is trimmed")
    }

    /// The chat redraws when dictation changes state, so the send button can wait for the last words.
    @MainActor func testTheChatSeesDictationChange() {
        let chat = ChatSession(document: EditMaxDocument())
        var fired = 0
        let c = chat.objectWillChange.sink { _ in fired += 1 }
        chat.dictation.problem = "No microphone is connected."
        XCTAssertGreaterThan(fired, 0)
        c.cancel()
    }

    @MainActor func testIdleDictationKeepsTheFieldAndSendsAtOnce() async {
        let d = Dictation()
        XCTAssertFalse(d.isActive)
        let t = await d.finish()
        XCTAssertEqual(t, "", "finishing when idle changes nothing")
        XCTAssertEqual(d.state, .idle)
    }
}

/// Hold right ⌥ alone to talk; with a letter it is a typed character, and letting go stops.
final class PushToTalkTests: XCTestCase {
    func testHoldingTheKeyAloneTalksAndLettingGoStops() {
        var m = PushToTalk.Machine()
        XCTAssertEqual(m.keyDown(), .arm)
        XCTAssertEqual(m.held(), .start)
        XCTAssertEqual(m.otherInput(), .none, "typing while talking does not cut it off")
        XCTAssertEqual(m.keyUp(), .stop)
        XCTAssertEqual(m.phase, .idle)
    }

    func testAChordOrATapNeverTalks() {
        var m = PushToTalk.Machine()
        XCTAssertEqual(m.keyDown(), .arm)
        XCTAssertEqual(m.otherInput(), .disarm, "⌥E is a character")
        XCTAssertEqual(m.held(), .none)
        XCTAssertEqual(m.keyUp(), .none)
        XCTAssertEqual(m.keyDown(), .arm)
        XCTAssertEqual(m.keyUp(), .disarm, "a quick tap")
        XCTAssertEqual(m.held(), .none)
    }
}

/// "my Whitey channel" was "my YT channel": the trade's words come out as written, the same sound elsewhere stays.
@MainActor
final class DictationWordsTests: XCTestCase {
    func testTheTradesWordsComeOutAsWritten() {
        XCTAssertEqual(Dictation.corrected("Edit this into a short and dramatic cinematic look video for my Whitey channel??"),
                       "Edit this into a short and dramatic cinematic look video for my YT channel??")
        XCTAssertEqual(Dictation.corrected("post it to my why tee shorts"), "post it to my YT shorts")
        XCTAssertEqual(Dictation.corrected("add some b roll and a lut"), "add some B-roll and a LUT")
        XCTAssertEqual(Dictation.corrected("upload to you tube and tick tock"), "upload to YouTube and TikTok")
        XCTAssertEqual(Dictation.corrected("Whitey came over"), "Whitey came over", "only before a platform word")
        XCTAssertEqual(Dictation.merge(base: "Hey,", heard: "make it for my Whitey channel"), "Hey, make it for my YT channel")
    }

    func testHintsCarryTheProjectsOwnNames() {
        var p = Project()
        p.assets.append(Asset(name: "KL-drone-sunset.MP4", path: "/tmp/KL-drone-sunset.MP4", kind: .video, duration: 4))
        let h = Dictation.hints(for: p)
        XCTAssertTrue(h.contains("YT"))
        XCTAssertTrue(h.contains("KL-drone-sunset"))
        XCTAssertLessThanOrEqual(h.count, 100)
        XCTAssertEqual(h.count, Set(h.map { $0.lowercased() }).count, "no word twice")
    }
}
