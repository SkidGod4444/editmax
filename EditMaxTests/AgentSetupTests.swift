import XCTest
@testable import EditMax

/// An agent that codemax found but cannot drive yet is "on this Mac", never "not found", and while codemax downloads
/// its engine (Antigravity's ACP server) the chat says so and asks codemax again by itself.
final class AgentSetupTests: XCTestCase {
    private typealias Agent = CodemaxRunner.AgentInfo

    func testAnAgentBeingSetUpIsOnThisMacAndCheckedAgain() {
        let installing = Agent(id: "antigravity", name: "Antigravity CLI", installed: false, version: "1.4.12",
                               problem: "installing Google's ACP server for Antigravity (about 110 MB, once): ready in a minute or two")
        XCTAssertTrue(ChatSession.settingUp([installing]))
        let text = ChatView.agentProblemText(installing)
        XCTAssertTrue(text.hasPrefix("Antigravity CLI 1.4.12 is on this Mac."), text)
        XCTAssertFalse(text.contains("not found"), text)

        // Before codemax 0.1.24 (the report from the other Mac): found, but no engine. Not "not found" either, and
        // nothing to wait for.
        let noEngine = Agent(id: "claude", name: "Claude Code", installed: false, version: "2.1.309", problem: "no protocol engine on this machine")
        XCTAssertFalse(ChatSession.settingUp([noEngine]))
        XCTAssertEqual(ChatView.agentProblemText(noEngine), "Claude Code 2.1.309 is on this Mac, but EditMax cannot drive it yet: no protocol engine on this machine.")

        let missing = Agent(id: "codex", name: "Codex", installed: false, version: nil, problem: nil)
        XCTAssertEqual(ChatView.agentProblemText(missing), "Codex was not found on this Mac.")
        XCTAssertFalse(ChatSession.settingUp([missing, noEngine]))
        XCTAssertTrue(ChatSession.settingUp([missing, installing]), "one agent being set up is enough to check again")

        let ready = Agent(id: "claude", name: "Claude Code", installed: true, version: "2.1.319", problem: nil)
        XCTAssertFalse(ChatSession.settingUp([ready]))
    }
}
