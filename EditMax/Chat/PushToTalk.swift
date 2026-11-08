import AppKit

/// Push to talk: hold a modifier key alone (right ⌥ by default, Settings ▸ Assistant) and speak into the front
/// project's chat; let go and listening stops, the words staying in the field until Return sends them. A modifier, not
/// a letter: holding it types nothing into the chat field, and it works while that field has the keyboard.
/// The key must be held a moment alone: right ⌥ with a letter is a typed character (⌥E, ⌥U), not a request to talk.
@MainActor final class PushToTalk {
    static let shared = PushToTalk()

    enum Key: String, CaseIterable, Identifiable {
        case rightOption, rightCommand, off
        var id: String { rawValue }
        var label: String { switch self { case .rightOption: "Hold right ⌥"; case .rightCommand: "Hold right ⌘"; case .off: "Off" } }
        var symbol: String? { switch self { case .rightOption: "right ⌥"; case .rightCommand: "right ⌘"; case .off: nil } }
        /// The modifier key's code in flagsChanged events.
        var keyCode: UInt16? { switch self { case .rightOption: 61; case .rightCommand: 54; case .off: nil } }
        /// The device-dependent flag of that one key (NX_DEVICERALTKEYMASK, NX_DEVICERCMDKEYMASK): the left key has its own.
        var deviceFlag: UInt { switch self { case .rightOption: 0x40; case .rightCommand: 0x10; case .off: 0 } }
        var modifier: NSEvent.ModifierFlags { switch self { case .rightOption: .option; case .rightCommand: .command; case .off: [] } }
    }

    /// What happens between the key going down and coming up, apart from the events and the clock (tested alone).
    struct Machine: Equatable {
        enum Phase: Equatable { case idle, pending, talking }
        enum Action: Equatable { case none, arm, start, stop, disarm }
        private(set) var phase: Phase = .idle

        /// The key went down alone (no other modifier held).
        mutating func keyDown() -> Action { guard phase == .idle else { return .none }; phase = .pending; return .arm }
        /// Held long enough alone: talk.
        mutating func held() -> Action { guard phase == .pending else { return .none }; phase = .talking; return .start }
        /// Another key or modifier while waiting: it was a chord (⌥E), not a request to talk.
        mutating func otherInput() -> Action { guard phase == .pending else { return .none }; phase = .idle; return .disarm }
        /// The key came up, or EditMax lost the keyboard.
        mutating func keyUp() -> Action {
            defer { phase = .idle }
            switch phase { case .talking: return .stop; case .pending: return .disarm; case .idle: return .none }
        }
    }

    /// How long the key is held alone before listening starts.
    static let holdDelay: TimeInterval = 0.25

    private var machine = Machine()
    private var monitor: Any?
    private var armed: DispatchWorkItem?
    private var resign: NSObjectProtocol?

    var key: Key { Key(rawValue: AppSettings.shared.pushToTalk) ?? .rightOption }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            self?.handle(e)
            return e   // a modifier is never swallowed: the rest of the app sees it as before
        }
        // Switching apps mid-hold: the key's release goes to the other app, so stop here.
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.perform(self?.machine.keyUp() ?? .none) }
        }
    }

    private func handle(_ e: NSEvent) {
        let key = self.key
        guard let code = key.keyCode else { return }
        if e.type == .keyDown { perform(machine.otherInput()); return }
        let others = e.modifierFlags.intersection([.shift, .control, .option, .command, .function]).subtracting(key.modifier)
        if e.keyCode == code {
            let down = e.modifierFlags.rawValue & key.deviceFlag != 0
            if down, others.isEmpty { perform(machine.keyDown()) } else if !down { perform(machine.keyUp()) } else { perform(machine.otherInput()) }
        } else {
            perform(machine.otherInput())   // another modifier joined in
        }
    }

    private func perform(_ a: Machine.Action) {
        switch a {
        case .none: break
        case .arm:
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { guard let self else { return }; self.perform(self.machine.held()) } }
            armed = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: w)
        case .disarm: armed?.cancel(); armed = nil
        case .start: armed = nil; postEditorCommand(.talkStart); DebugLog.event("push-to-talk", ["key": key.rawValue])
        case .stop: postEditorCommand(.talkStop)
        }
    }
}
