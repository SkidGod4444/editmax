import SwiftUI
import AppKit

// Follow the agent: while an agent edits over MCP, the window goes where the edit lands, the way it would if a person
// made it: the clip is selected, the playhead moves onto it, the inspector scrolls to the card that changes (outlined
// for a moment), the mixer opens for a mix change, and the change itself animates. The edit still runs through the same
// `ToolExecutor` code as the user's clicks; only the window follows. It stands aside while the user is working.

/// A card in the inspector an edit can land on.
enum InspectorAnchor: String, CaseIterable {
    // Clip
    case header, timing, multicam, speed, transform, color, wheels, curves, look, shotMatch, gradeLayers, finish
    case key, blend, faceBlur, audio, eq, compressor, limiter, deEsser, hum, gainPan, crossfade, transition
    case splitEdit, slowMotion, scenes
    // Text
    case title, textAnimation, lowerThird
    // Project
    case project, markers, ducking
}

/// Where one agent call lands in the window.
struct FollowTarget {
    var clip: UUID?
    var text: UUID?
    /// Show the project inspector (nothing selected).
    var project = false
    var anchor: InspectorAnchor?
    /// A grade layer to open in the inspector.
    var layer: UUID?
    /// Move the playhead here, unless it is already inside `range` (or playing).
    var time: Double?
    var range: ClosedRange<Double>?
    var mixer = false
}

@MainActor
final class AgentFollow {
    static let shared = AgentFollow()

    /// The last mouse, key or scroll event the user made (the driver's own events do not count).
    var lastUserInput = Date.distantPast
    /// While the user works the window stays where they put it: no reveal and no animation, the edit still applies.
    var userIsBusy: Bool { Date().timeIntervalSince(lastUserInput) < 2.5 || NSEvent.pressedMouseButtons != 0 }
    var isEnabled: Bool { !AppDelegate.isTesting && AppSettings.bool(AppSettings.Key.followAgent, default: true) }

    /// When the last followed edit landed: a screenshot waits for its animation to settle (`settle()`).
    var lastAnimatedEdit = Date.distantPast
    private var handlers: [UUID: (FollowTarget) -> Bool] = [:]

    /// Waits out the animation of an edit that has just landed, so a capture shows where it ends, not a frame of the way.
    func settle() async {
        let left = 0.45 - Date().timeIntervalSince(lastAnimatedEdit)
        if left > 0 { try? await Task.sleep(for: .milliseconds(Int(left * 1000))) }
    }

    func register(_ doc: UUID, _ handler: @escaping (FollowTarget) -> Bool) { handlers[doc] = handler }
    func unregister(_ doc: UUID) { handlers[doc] = nil }

    /// True when the agent's next edit to `doc` should be shown (window open, follow on, user not busy).
    func isFollowing(_ doc: UUID) -> Bool { isEnabled && !userIsBusy && handlers[doc] != nil }

    /// Moves the window to the target. Returns whether anything on screen changed.
    @discardableResult
    func reveal(_ doc: UUID, _ target: FollowTarget) -> Bool {
        guard isFollowing(doc), let h = handlers[doc] else { return false }
        return h(target)
    }

    /// An editor window the user can see right now (a pause before the edit is only worth it then).
    var windowIsVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && $0.occlusionState.contains(.visible) && $0.contentView != nil }
    }
}

/// Applies a target to one window's state. Lives with the window (`EditorRootView` registers it).
@MainActor
enum FollowUI {
    static func apply(_ t: FollowTarget, document: EditMaxDocument, state: EditorState, player: PlayerController) -> Bool {
        let p = document.project
        var changed = false
        if t.project, !state.selectedClipIDs.isEmpty || state.selectedTextID != nil {
            state.selectedClipIDs = []; state.selectedTextID = nil; changed = true
        }
        if let id = t.clip, p.clip(id) != nil, state.selectedClipIDs != [id] || state.selectedTextID != nil {
            state.selectedClipIDs = [id]; state.selectedTextID = nil; changed = true
        }
        if let id = t.text, p.texts.contains(where: { $0.id == id }), state.selectedTextID != id || !state.selectedClipIDs.isEmpty {
            state.selectedTextID = id; state.selectedClipIDs = []; changed = true
        }
        // The playhead goes onto the change, unless it already shows it or the user is playing.
        if let time = t.time, !player.isRunning {
            let now = player.currentTime
            let inside = t.range.map { now >= $0.lowerBound && now < $0.upperBound } ?? (abs(now - time) < 1e-3)
            if !inside { document.seekRequest = (max(0, time), false); changed = true }
        }
        // History and Agents hide the inspector; the Chat tab and the focus layout are the user's view of the
        // conversation and stay put (the selection, playhead and mixer still follow).
        if t.anchor != nil || t.clip != nil || t.text != nil || t.project, !state.focusMode,
           state.inspectorTab == .history || state.inspectorTab == .agents {
            state.inspectorTab = .inspector; changed = true
        }
        let r = state.reveal
        if let layer = t.layer, r.layer != layer { r.layer = layer; changed = true }
        if let a = t.anchor {
            r.anchor = a; r.at = Date(); r.tick += 1; r.highlight = a
            let tick = r.tick
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak r] in
                if let r, r.tick == tick { r.highlight = nil }
            }
            changed = true
        }
        if t.mixer, !UserDefaults.standard.bool(forKey: "mixerOpen") {
            UserDefaults.standard.set(true, forKey: "mixerOpen"); changed = true   // the toolbar's @AppStorage follows
        }
        return changed
    }
}

// MARK: - Inspector scrolling and the highlight

/// The inspector card an agent edit lands on, kept apart from `EditorState` so a reveal redraws the cards and nothing
/// else. Views reach it through `\.reveal`; where it is absent (a card drawn on its own, as the tests do) they draw plainly.
@MainActor
final class RevealState: ObservableObject {
    @Published var anchor: InspectorAnchor?
    @Published var tick = 0
    var at = Date.distantPast
    /// Outlined for a moment after the inspector scrolls to it.
    @Published var highlight: InspectorAnchor?
    /// A grade layer the agent is working on: the inspector opens its cards.
    @Published var layer: UUID?
}

private struct RevealKey: EnvironmentKey { static let defaultValue: RevealState? = nil }
extension EnvironmentValues {
    var reveal: RevealState? { get { self[RevealKey.self] } set { self[RevealKey.self] = newValue } }
}

/// Marks a card as a place an edit can land: the inspector scrolls to it and outlines it for a moment.
struct RevealAnchorModifier: ViewModifier {
    let anchor: InspectorAnchor
    @Environment(\.reveal) private var reveal
    func body(content: Content) -> some View {
        if let reveal { content.modifier(RevealOutline(anchor: anchor, reveal: reveal)) } else { content.id(anchor) }
    }
}

private struct RevealOutline: ViewModifier {
    let anchor: InspectorAnchor
    @ObservedObject var reveal: RevealState
    func body(content: Content) -> some View {
        content
            .id(anchor)
            .overlay {
                if reveal.highlight == anchor {
                    RoundedRectangle(cornerRadius: InspectorStyle.cardRadius + 3, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: reveal.highlight == anchor)
    }
}

extension View {
    func revealAnchor(_ a: InspectorAnchor) -> some View { modifier(RevealAnchorModifier(anchor: a)) }
}

/// Wraps an inspector's scroll view: scrolls to the card an agent edit lands on.
struct RevealScroller<Content: View>: View {
    @Environment(\.reveal) private var reveal
    @ViewBuilder let content: Content
    var body: some View {
        if let reveal { RevealScrolling(reveal: reveal, content: content) } else { content }
    }
}

private struct RevealScrolling<Content: View>: View {
    @ObservedObject var reveal: RevealState
    let content: Content
    var body: some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: reveal.tick) { _, _ in scroll(proxy) }
                // A clip, text or project inspector that has just replaced another one: scroll once it is laid out.
                .onAppear { scroll(proxy) }
        }
    }
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let a = reveal.anchor, Date().timeIntervalSince(reveal.at) < 1.5 else { return }
        let tick = reveal.tick
        DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(a, anchor: .top) } }
        // A scroll asked for while an earlier one is still animating can lose to it (two quick agent calls do this):
        // once the animation is over, settle on the latest card unless a newer reveal has taken over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [reveal] in
            if reveal.tick == tick { proxy.scrollTo(a, anchor: .top) }
        }
    }
}
