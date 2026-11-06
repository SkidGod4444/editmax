import XCTest
@testable import EditMax

/// M14: a launch that opens a project never puts Home up first (it flashed up and away ~200 ms later).
@MainActor
final class HomeLaunchTests: XCTestCase {
    func testOnlyAPlainLaunchPutsHomeUpAtOnce() {
        XCTAssertEqual(HomeWindow.launchPlan(isDefaultLaunch: true, projectOpen: false, projectInArguments: false), .showNow, "Dock / Launchpad: Home is the launch screen")
        XCTAssertEqual(HomeWindow.launchPlan(isDefaultLaunch: false, projectOpen: false, projectInArguments: false), .waitForProject, "opened from the Finder, or restoring windows")
        XCTAssertEqual(HomeWindow.launchPlan(isDefaultLaunch: true, projectOpen: false, projectInArguments: true), .waitForProject, "a project path on the command line")
        XCTAssertEqual(HomeWindow.launchPlan(isDefaultLaunch: false, projectOpen: true, projectInArguments: false), .nothing)
        XCTAssertEqual(HomeWindow.launchPlan(isDefaultLaunch: true, projectOpen: true, projectInArguments: false), .nothing)
    }

    /// The project's window arrives a moment after launch: Home stays down.
    func testHomeStaysDownWhenTheProjectArrives() async {
        let launched = Date()
        var shown = 0
        let showed = await HomeWindow.shared.waitForLaunchProject(seconds: 2, poll: 0.02,
                                                                   projectOpen: { Date().timeIntervalSince(launched) > 0.2 },
                                                                   show: { shown += 1 })
        XCTAssertFalse(showed)
        XCTAssertEqual(shown, 0, "Home must not come up for a launch that opened a project")
        XCTAssertLessThan(Date().timeIntervalSince(launched), 1, "the wait ends as soon as the project is there")
        XCTAssertFalse(HomeWindow.shared.waitingForLaunchProject)
    }

    /// Nothing opened (the file failed to open, a restore with no windows): Home comes up once, after the wait.
    func testHomeComesUpWhenNoProjectArrives() async {
        var shown = 0
        let wait = Task { await HomeWindow.shared.waitForLaunchProject(seconds: 0.3, poll: 0.02, projectOpen: { false }, show: { shown += 1 }) }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(HomeWindow.shared.waitingForLaunchProject, "the automatic Home paths stand aside during the wait")
        XCTAssertEqual(shown, 0, "not before the wait is over")
        let showed = await wait.value
        XCTAssertTrue(showed)
        XCTAssertEqual(shown, 1)
        XCTAssertFalse(HomeWindow.shared.waitingForLaunchProject)
    }
}
