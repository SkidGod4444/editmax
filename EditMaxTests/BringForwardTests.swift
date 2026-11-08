import XCTest
import AppKit
@testable import EditMax

/// Home and Settings from the menu bar come to the Space in use, over a full-screen app too, and AppKit accepts it:
/// contradicting collection behaviors throw.
@MainActor
final class BringForwardTests: XCTestCase {
    func testAWindowJoinsTheSpaceInUseAndMayCoverAFullScreenApp() {
        let b = BringForward.joiningTheActiveSpace([.fullScreenPrimary, .managed])
        XCTAssertTrue(b.contains(.moveToActiveSpace))
        XCTAssertTrue(b.contains(.fullScreenAuxiliary))
        XCTAssertFalse(b.contains(.fullScreenPrimary), "primary and auxiliary contradict")
        XCTAssertTrue(b.contains(.managed))

        let everywhere = BringForward.joiningTheActiveSpace([.canJoinAllSpaces, .fullScreenNone])
        XCTAssertFalse(everywhere.contains(.moveToActiveSpace), "a window on every Space cannot also move")
        XCTAssertFalse(everywhere.contains(.fullScreenNone))

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        w.collectionBehavior = [.fullScreenPrimary]
        w.collectionBehavior = BringForward.joiningTheActiveSpace(w.collectionBehavior)   // throws if AppKit rejects it
        XCTAssertTrue(w.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}
