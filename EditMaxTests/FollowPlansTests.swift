import XCTest
@testable import EditMax

/// Follow the agent: every MCP tool says where its edit lands in the window, or is listed as one that changes nothing
/// worth following. A new tool that is in neither list fails here.
final class FollowPlansTests: XCTestCase {
    func testEveryToolIsFollowedOrListedAsNotFollowed() {
        let names = Set(EditMaxTools.tools.map(\.name))
        let planned = Set(FollowPlans.plans.keys), skipped = FollowPlans.none
        XCTAssertEqual(names.subtracting(planned).subtracting(skipped).sorted(), [], "tools with no follow plan")
        XCTAssertEqual(planned.intersection(skipped).sorted(), [], "tools both followed and skipped")
        XCTAssertEqual(planned.union(skipped).subtracting(names).sorted(), [], "plans for tools that do not exist")
    }

    func testEditToolsLandOnACardOrTheMixer() {
        // Tools that change a clip's settings must name the card they change, so the inspector can show it.
        for (name, plan) in FollowPlans.plans where name.hasPrefix("set_clip_") || name.hasPrefix("set_color_") {
            XCTAssertTrue(plan.anchor != nil || plan.anchorFor != nil, "\(name) names no inspector card")
        }
        for name in ["set_track_mix", "set_bus", "set_master", "normalize_loudness"] {
            XCTAssertTrue(FollowPlans.plans[name]?.mixer == true, "\(name) should open the mixer")
        }
    }
}

/// The user's chosen view is never switched: in the focus layout (player and chat only) only the playhead follows, and
/// the Chat tab stays the Chat tab.
@MainActor
final class FollowViewChoiceTests: XCTestCase {
    private func setup() -> (EditMaxDocument, EditorState, PlayerController, UUID) {
        let doc = EditMaxDocument()
        let clip = Clip(assetID: UUID(), name: "c", start: 2, duration: 3)
        doc.project.tracks[0].clips = [clip]
        return (doc, EditorState(), PlayerController(), clip.id)
    }

    func testFocusLayoutOnlyMovesThePlayhead() {
        let (doc, state, player, clip) = setup()
        state.focusMode = true
        let mixerWas = UserDefaults.standard.object(forKey: "mixerOpen")
        _ = FollowUI.apply(FollowTarget(clip: clip, anchor: .wheels, time: 2.5, range: 2...5, mixer: true), document: doc, state: state, player: player)
        XCTAssertEqual(doc.seekRequest?.time, 2.5, "the edit shows in the player")
        XCTAssertTrue(state.selectedClipIDs.isEmpty, "selection unchanged")
        XCTAssertNil(state.reveal.anchor, "inspector unchanged")
        XCTAssertEqual(state.inspectorTab, .inspector)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "mixerOpen") as? Bool, mixerWas as? Bool, "mixer unchanged")
    }

    func testChatTabIsNotSwitchedAway() {
        let (doc, state, player, clip) = setup()
        state.inspectorTab = .chat
        _ = FollowUI.apply(FollowTarget(clip: clip, anchor: .wheels, time: 2.5, range: 2...5), document: doc, state: state, player: player)
        XCTAssertEqual(state.inspectorTab, .chat)
        XCTAssertEqual(state.selectedClipIDs, [clip], "the clip is still selected on the timeline")
    }
}
