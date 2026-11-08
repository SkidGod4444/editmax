import SwiftUI
import AppKit

/// Settings ▸ Shortcuts: every EditMax key, changeable. Click a key to record a new one (Esc cancels), × removes it,
/// + adds another, the arrow restores the default. A key macOS or another app takes first is refused with the reason;
/// a key an installed app uses by default is allowed with a warning; a key another EditMax action has can be moved.
struct ShortcutsSettings: View {
    @ObservedObject private var store = ShortcutStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var recorder = KeyRecorder()
    @State private var system: [KeyCombo: String] = [:]
    @State private var clashes: [KeyCombo: [ShortcutConflicts.Clash]] = [:]
    @State private var notice: Notice?
    @State private var search = ""

    struct Notice: Equatable {
        var action: ShortcutAction
        var text: String
        var warning = true
        var moveFrom: ShortcutAction? = nil
        var combo: KeyCombo? = nil
        var index: Int? = nil
    }

    var body: some View {
        Form {
            Section {
                Picker("Push to talk", selection: $settings.pushToTalk) {
                    ForEach(PushToTalk.Key.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pointer().uiFrame("settings.shortcuts.pushToTalk")
            } header: {
                Text("Voice")
            } footer: {
                Text("Hold the key and speak to the agent; let go to stop. Your words stay in the chat field until you press Return. A modifier held alone types nothing and works while you type.")
            }
            if !taken.isEmpty {
                Section {
                    ForEach(taken, id: \.id) { t in
                        Label("\(t.combo.display) (\(t.action.title)): \(t.clash.message)", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor).font(.callout)
                    }
                } header: { Text("Collisions on this Mac") }
            }
            Section {
                TextField("Search", text: $search, prompt: Text("Find an action or a key"))
                    .textFieldStyle(.roundedBorder).uiFrame("settings.shortcuts.search")
            } footer: {
                Text("Keys with ⌘ or ⌃ work everywhere in a project, the chat field included. Single keys and ⌥ or ⇧ keys work while the timeline or player has the keyboard, so typing in the chat never triggers them.")
            }
            ForEach(ShortcutAction.Group.allCases, id: \.self) { g in
                let actions = ShortcutAction.allCases.filter { $0.group == g && matches($0) }
                if !actions.isEmpty {
                    Section(g.rawValue) {
                        ForEach(actions) { a in row(a) }
                    }
                }
            }
            Section {
                HStack {
                    Text("Fixed: ⌘N new project, ⌘Z / ⇧⌘Z undo and redo, ⌘Q, ⌘W, ⌘, and the other keys every Mac app keeps.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { store.resetAll(); notice = nil; refreshClashes() }
                        .disabled(store.custom.isEmpty).pointer().uiFrame("settings.shortcuts.restore")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { system = ShortcutConflicts.systemShortcuts(); refreshClashes() }
        .onDisappear { recorder.stop() }
    }

    private func matches(_ a: ShortcutAction) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return a.title.lowercased().contains(q) || store.combos(a).contains { $0.display.lowercased().contains(q) }
    }

    @ViewBuilder private func row(_ a: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(a.title)
                if store.combos(a).contains(where: { clashes[$0]?.isEmpty == false }) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        .help(store.combos(a).compactMap { c in clashes[c]?.first.map { "\(c.display): \($0.message)" } }.joined(separator: "\n"))
                }
                Spacer()
                let combos = store.combos(a)
                ForEach(Array(combos.enumerated()), id: \.offset) { i, c in
                    chip(c.display, active: recorder.target == .init(action: a, index: i)) { record(a, index: i) } remove: {
                        var list = combos; list.remove(at: i); store.set(a, list); refreshClashes()
                    }
                }
                if recorder.target == .init(action: a, index: combos.count) {
                    chip("Type a key…", active: true, tap: { recorder.stop() }, remove: nil)
                } else if combos.count < 3 {
                    Button { record(a, index: combos.count) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Add another key").pointer()
                }
                if store.isCustom(a) {
                    Button { store.reset(a); notice = nil; refreshClashes() } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless).help("Back to \(a.defaults.map(\.display).joined(separator: " or "))").pointer()
                }
            }
            if let n = notice, n.action == a {
                HStack(spacing: 6) {
                    Image(systemName: n.warning ? "exclamationmark.triangle.fill" : "info.circle").foregroundStyle(n.warning ? .yellow : .secondary)
                    Text(n.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let from = n.moveFrom, let c = n.combo, let i = n.index {
                        Button("Use here instead") {
                            store.set(from, store.combos(from).filter { $0 != c })
                            assign(c, to: a, at: i); notice = nil
                        }
                    }
                    Button { notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            }
        }
        .uiFrame("settings.shortcuts.\(a.rawValue)")
    }

    private func chip(_ text: String, active: Bool, tap: @escaping () -> Void, remove: (() -> Void)?) -> some View {
        HStack(spacing: 2) {
            Button(action: tap) {
                Text(text).font(.system(.callout, design: .rounded).weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(active ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).help(active ? "Press the new key, or Esc to cancel" : "Click, then press the new key").pointer()
            if let remove, !active {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("Remove this key").pointer()
            }
        }
    }

    private func record(_ a: ShortcutAction, index: Int) {
        notice = nil
        recorder.start(.init(action: a, index: index)) { combo in take(combo, for: a, at: index) }
    }

    /// A recorded key: refused with its reason, offered to move from another action, or assigned (with a warning when an
    /// installed app uses it by default).
    private func take(_ c: KeyCombo, for a: ShortcutAction, at i: Int) {
        if a.menuOnly && !c.worksWhileTyping {
            notice = Notice(action: a, text: "This one runs from the menu, so it needs ⌘ or ⌃."); return
        }
        let found = ShortcutConflicts.clashes(c, system: system)
        if let block = found.first(where: \.blocks) { notice = Notice(action: a, text: "\(c.display): \(block.message)"); return }
        if let other = store.action(for: c), other != a {
            notice = Notice(action: a, text: "\(c.display) is already “\(other.title)”.", warning: false, moveFrom: other, combo: c, index: i); return
        }
        assign(c, to: a, at: i)
        if let w = found.first { notice = Notice(action: a, text: "\(c.display): \(w.message)") }
    }

    private func assign(_ c: KeyCombo, to a: ShortcutAction, at i: Int) {
        var list = store.combos(a)
        if i < list.count { list[i] = c } else { list.append(c) }
        store.set(a, list)
        refreshClashes()
    }

    /// Clashes of every key in use, worked out once per change (the other-app probe claims each chord for an instant).
    private func refreshClashes() {
        var out: [KeyCombo: [ShortcutConflicts.Clash]] = [:]
        for a in ShortcutAction.allCases { for c in store.combos(a) where out[c] == nil { out[c] = ShortcutConflicts.clashes(c, system: system) } }
        clashes = out
    }

    private var taken: [(id: String, action: ShortcutAction, combo: KeyCombo, clash: ShortcutConflicts.Clash)] {
        ShortcutAction.allCases.flatMap { a in store.combos(a).compactMap { c in clashes[c]?.first.map { (a.rawValue + c.display, a, c, $0) } } }
    }
}

/// Catches the next key press for the shortcut being changed; the key does nothing else meanwhile.
@MainActor final class KeyRecorder: ObservableObject {
    struct Target: Equatable { var action: ShortcutAction; var index: Int }
    @Published private(set) var target: Target?
    private var monitor: Any?

    func start(_ t: Target, _ done: @escaping (KeyCombo) -> Void) {
        stop()
        target = t
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return e }
                let plainEscape = e.keyCode == 53 && e.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
                if !plainEscape, let c = KeyCombo(event: e) { self.stop(); done(c) } else { self.stop() }
                return nil   // swallowed: ⌘B while recording must not split a clip
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; target = nil
    }
}
