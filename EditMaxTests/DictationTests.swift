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

    @MainActor func testIdleDictationKeepsTheFieldAndSendsAtOnce() async {
        let d = Dictation()
        XCTAssertFalse(d.isActive)
        let t = await d.finish()
        XCTAssertEqual(t, "", "finishing when idle changes nothing")
        XCTAssertEqual(d.state, .idle)
    }
}
