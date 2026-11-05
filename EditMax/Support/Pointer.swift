import SwiftUI
import AppKit

/// The hand cursor over anything clickable (buttons, links, rows that react to a click), as on the web.
/// SwiftUI on macOS keeps the arrow by default; every clickable control in EditMax carries `.pointer()`.
struct PointerCursor: ViewModifier {
    @State private var inside = false
    func body(content: Content) -> some View {
        content.onHover { over in
            guard over != inside else { return }
            inside = over
            if over { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if inside { inside = false; NSCursor.pop() } }
    }
}

extension View {
    func pointer() -> some View { modifier(PointerCursor()) }
}
