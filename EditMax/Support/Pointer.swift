import SwiftUI
import AppKit

/// The hand cursor over anything clickable (buttons, links, rows that react to a click), as on the web.
/// SwiftUI on macOS keeps the arrow by default and resets the cursor on its own as the mouse moves, which is why a
/// one-off push on hover does not hold. This sets the hand again on every mouse move inside the view and puts the
/// arrow back on leaving, so the hand wins whatever SwiftUI does in between.
struct PointerCursor: ViewModifier {
    @State private var inside = false
    func body(content: Content) -> some View {
        content.onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active:
                inside = true
                if NSCursor.current != NSCursor.pointingHand { NSCursor.pointingHand.set() }
            case .ended:
                inside = false
                NSCursor.arrow.set()
            }
        }
        .onDisappear { if inside { inside = false; NSCursor.arrow.set() } }
    }
}

extension View {
    func pointer() -> some View { modifier(PointerCursor()) }
}
