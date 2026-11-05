import SwiftUI
import AppKit

/// The hand cursor over anything clickable (buttons, links, rows that react to a click), as on the web, and the
/// "not allowed" cursor over the same thing while it is disabled.
/// SwiftUI on macOS keeps the arrow by default and resets the cursor on its own as the mouse moves, which is why a
/// one-off push on hover does not hold. This sets the cursor again on every mouse move inside the view and puts the
/// arrow back on leaving, so our cursor wins whatever SwiftUI does in between.
/// Order matters: write `.pointer().disabled(x)`, not `.disabled(x).pointer()`. The disabled state reaches this
/// modifier through the environment, which `.disabled` only sets for the views inside it.
struct PointerCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var inside = false
    private var cursor: NSCursor { isEnabled ? .pointingHand : .operationNotAllowed }
    func body(content: Content) -> some View {
        content.onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active:
                inside = true
                if NSCursor.current != cursor { cursor.set() }
            case .ended:
                inside = false
                NSCursor.arrow.set()
            }
        }
        .onChange(of: isEnabled) { _, _ in if inside { cursor.set() } }
        .onDisappear { if inside { inside = false; NSCursor.arrow.set() } }
    }
}

extension View {
    func pointer() -> some View { modifier(PointerCursor()) }
}
