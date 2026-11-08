import AppKit

/// Bringing EditMax in front of what the person is looking at: from the menu bar icon, the notch drawer, an update
/// prompt. `NSApp.activate()` is only a request since macOS 14, and the system turns it down while another app is in
/// front, so a window shown from the menu bar stayed behind that app, or on the desktop's Space while another app was
/// full screen ("the menu does nothing").
@MainActor enum BringForward {
    /// Makes EditMax the active app. `activate(ignoringOtherApps:)` is the call that still wins from a menu bar item;
    /// it is marked "to be deprecated", not deprecated, and `activate()` goes first for the day it stops working.
    static func app() {
        NSApp.activate()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shows `window` on the Space the person is on, over a full-screen app too, in front and key.
    static func show(_ window: NSWindow) {
        window.collectionBehavior = joiningTheActiveSpace(window.collectionBehavior)
        if window.isMiniaturized { window.deminiaturize(nil) }
        app()
        window.orderFrontRegardless()   // in front even before the activation lands
        window.makeKeyAndOrderFront(nil)
    }

    /// The window comes to the Space in use when shown, and may sit over another app's full-screen Space. AppKit
    /// throws on contradicting options, so the ones these exclude go first.
    nonisolated static func joiningTheActiveSpace(_ b: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        var b = b
        if !b.contains(.canJoinAllSpaces) { b.remove(.stationary); b.insert(.moveToActiveSpace) }   // a window on every Space is already here
        b.remove([.fullScreenPrimary, .fullScreenNone])
        b.insert(.fullScreenAuxiliary)
        return b
    }

    /// After SwiftUI opens a window (Settings, Keyboard Shortcuts) it has no handle on: the newest window whose
    /// identifier or title matches is brought forward once it exists.
    static func showWhenOpen(matching match: @escaping (NSWindow) -> Bool) {
        app()
        Task { @MainActor in
            for _ in 0..<20 {   // up to a second for the scene to make its window
                if let w = NSApp.windows.last(where: { $0.isVisible && match($0) }) { show(w); return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
