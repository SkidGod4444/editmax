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
