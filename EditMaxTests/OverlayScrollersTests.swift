import XCTest
import SwiftUI
@testable import EditMax

/// Slim scroll bars: every scroll view uses the overlay style (no track, no bar at rest), mouse or not.
@MainActor
final class OverlayScrollersTests: XCTestCase {
    func testEveryScrollViewIsOverlayStyle() throws {
        OverlayScrollers.install()
        XCTAssertEqual(NSScroller.preferredScrollerStyle, .overlay)
        XCTAssertEqual(NSScrollView(frame: .zero).scrollerStyle, .overlay, "a scroll view made now")
        // One SwiftUI makes for a ScrollView, in a real window.
        let host = NSHostingView(rootView: ScrollView { VStack { ForEach(0..<80, id: \.self) { Text("Row \($0)") } } }.frame(width: 200, height: 120))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let scrolls = Self.scrollViews(in: host)
        XCTAssertFalse(scrolls.isEmpty)
        for s in scrolls { XCTAssertEqual(s.scrollerStyle, .overlay) }
        // A change of the Mac's setting (plugging in a mouse) keeps it.
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        for s in scrolls { XCTAssertEqual(s.scrollerStyle, .overlay) }
        w.close()
    }

    static func scrollViews(in v: NSView) -> [NSScrollView] {
        ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap { scrollViews(in: $0) }
    }
}
