import AppKit
import ObjectiveC

/// Slim scroll bars everywhere in EditMax: hidden at rest, a thin knob while scrolling, then fading, whatever the Mac's
/// "Show scroll bars" setting and whether a mouse is attached. With a mouse, macOS otherwise gives every scroll view
/// permanent legacy bars with a track, in lists, the inspector, the timeline (both ways), chat, Home and Settings.
///
/// Every `NSScrollView` (SwiftUI's `ScrollView` and `List` included) takes its style from
/// `NSScroller.preferredScrollerStyle` when it is made and again when that preference changes, so answering `.overlay`
/// there covers all of them, including ones SwiftUI makes later. Hovering the edge of a scroll area still shows the
/// knob for dragging.
enum OverlayScrollers {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        guard let m = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)) else {
            DebugLog.event("overlay-scrollers-unavailable", [:]); return
        }
        let overlay: @convention(block) (AnyObject) -> Int = { _ in NSScroller.Style.overlay.rawValue }
        method_setImplementation(m, imp_implementationWithBlock(overlay))
        // Scroll views made before this (none at launch, but cheap) pick the new style up from the change notification.
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }
}
