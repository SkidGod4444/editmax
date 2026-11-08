import SwiftUI
import AppKit
import Carbon.HIToolbox

/// One key, alone or with modifiers. Printable keys are kept as the character the key types without modifiers (so
/// ⇧⌘= is "=" with shift and command); the others by name. Saved in UserDefaults as JSON.
struct KeyCombo: Codable, Hashable {
    var key: String
    var command = false, shift = false, option = false, control = false

    init(_ key: String, _ mods: NSEvent.ModifierFlags = []) {
        self.key = key
        command = mods.contains(.command); shift = mods.contains(.shift); option = mods.contains(.option); control = mods.contains(.control)
    }

    /// The combo a key press makes, or nil for a key that cannot be bound (a dead key, a bare modifier). With ⇧ the key
    /// is read from its code (⇧= is "=" with shift, as menus show it), otherwise from the event's own characters.
    init?(event e: NSEvent) {
        guard e.type == .keyDown else { return nil }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let name = Self.names.first(where: { $0.value == e.keyCode })?.key {
            self.init(name, mods)
        } else if let c = (mods.contains(.shift) ? e.characters(byApplyingModifiers: []) : e.charactersIgnoringModifiers)?.lowercased(),
                  c.count == 1, let s = c.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(s), s.value < 0xF700 {
            self.init(c, mods)
        } else { return nil }
    }

    /// From a key code and Carbon modifiers (macOS's own shortcut table), on the US layout.
    init?(keyCode: Int, carbon: Int) {
        let key = Self.names.first(where: { Int($0.value) == keyCode })?.key ?? Self.usKeys.first(where: { Int($0.value) == keyCode })?.key
        guard let key else { return nil }
        self.init(key, [])
        command = carbon & cmdKey != 0; shift = carbon & shiftKey != 0; option = carbon & optionKey != 0; control = carbon & controlKey != 0
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if command { f.insert(.command) }; if shift { f.insert(.shift) }; if option { f.insert(.option) }; if control { f.insert(.control) }
        return f
    }
    /// Works while the person types in a text field too: the menu takes it there (a bare key or ⌥/⇧ only would type).
    var worksWhileTyping: Bool { command || control }
    var isPlain: Bool { !command && !control && !option }

    /// "⌥⌘R", "Space", "⇧←".
    var display: String {
        var s = ""
        if control { s += "⌃" }; if option { s += "⌥" }; if shift { s += "⇧" }; if command { s += "⌘" }
        return s + (Self.symbols[key] ?? key.uppercased())
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard worksWhileTyping, let k = keyEquivalent else { return nil }
        var m: SwiftUI.EventModifiers = []
        if command { m.insert(.command) }; if shift { m.insert(.shift) }; if option { m.insert(.option) }; if control { m.insert(.control) }
        return KeyboardShortcut(k, modifiers: m)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch key {
        case "space": return .space
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "home": return .home
        case "end": return .end
        case "delete": return .delete
        case "forwardDelete": return .deleteForward
        case "return": return .return
        case "escape": return .escape
        case "tab": return .tab
        case "pageUp": return .pageUp
        case "pageDown": return .pageDown
        default:
            if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n), let u = UnicodeScalar(NSF1FunctionKey + n - 1) { return KeyEquivalent(Character(u)) }
            return key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
    }

    /// For the Carbon hot key probe and macOS's table.
    var keyCode: UInt32? { (Self.names[key] ?? Self.usKeys[key]).map(UInt32.init) }
    var carbonModifiers: UInt32 {
        var m = 0
        if command { m |= cmdKey }; if shift { m |= shiftKey }; if option { m |= optionKey }; if control { m |= controlKey }
        return UInt32(m)
    }

    static let names: [String: UInt16] = [
        "space": 49, "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "delete": 51, "forwardDelete": 117,
        "return": 36, "escape": 53, "tab": 48, "pageUp": 116, "pageDown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    static let symbols: [String: String] = [
        "space": "Space", "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "Home", "end": "End", "delete": "⌫", "forwardDelete": "⌦",
        "return": "↩", "escape": "⎋", "tab": "⇥", "pageUp": "Page Up", "pageDown": "Page Down",
    ]
    static let usKeys: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]
}

/// Everything a key can do in EditMax, with its default keys. New Project, Undo/Redo and the standard app keys (⌘Q,
/// ⌘W, ⌘,…) stay fixed: they are macOS's, and listed as such.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case playPause, shuttleBack, pause, shuttleForward, stepBack, stepForward, stepBack10, stepForward10, goToStart, goToEnd, prevKeyframe, nextKeyframe
    case markIn, markOut, clearInOut, deleteInOut, addMarker
    case split, deleteSelection, transition, slowMotion, normalSpeed, fast, reframe, closeGaps
    case toolSelect, toolRoll, toolSlip, toolSlide, insertFromSource, overwriteFromSource, matchFrame
    case askAgent, dictate, stopAgent
    case showInspector, showChat, showAgents, showHistory, zoomIn, zoomOut, fullScreenPreview, focusMode, compare, sourceViewer, home
    case importMedia, exportVideo, batchExport, exportTimeline, keyboardShortcuts

    var id: String { rawValue }

    enum Group: String, CaseIterable { case playback = "Playback", marking = "Marking", editing = "Editing", agent = "Agent", view = "View", file = "File" }

    var group: Group {
        switch self {
        case .playPause, .shuttleBack, .pause, .shuttleForward, .stepBack, .stepForward, .stepBack10, .stepForward10, .goToStart, .goToEnd, .prevKeyframe, .nextKeyframe: .playback
        case .markIn, .markOut, .clearInOut, .deleteInOut, .addMarker: .marking
        case .split, .deleteSelection, .transition, .slowMotion, .normalSpeed, .fast, .reframe, .closeGaps,
             .toolSelect, .toolRoll, .toolSlip, .toolSlide, .insertFromSource, .overwriteFromSource, .matchFrame: .editing
        case .askAgent, .dictate, .stopAgent: .agent
        case .showInspector, .showChat, .showAgents, .showHistory, .zoomIn, .zoomOut, .fullScreenPreview, .focusMode, .compare, .sourceViewer, .home: .view
        case .importMedia, .exportVideo, .batchExport, .exportTimeline, .keyboardShortcuts: .file
        }
    }

    var title: String {
        switch self {
        case .playPause: "Play or pause"
        case .shuttleBack: "Play backward (again: faster)"
        case .pause: "Pause"
        case .shuttleForward: "Play forward (again: faster)"
        case .stepBack: "One frame back"
        case .stepForward: "One frame forward"
        case .stepBack10: "Ten frames back"
        case .stepForward10: "Ten frames forward"
        case .goToStart: "Go to the start"
        case .goToEnd: "Go to the end"
        case .prevKeyframe: "Previous keyframe"
        case .nextKeyframe: "Next keyframe"
        case .markIn: "Mark in"
        case .markOut: "Mark out"
        case .clearInOut: "Clear in and out"
        case .deleteInOut: "Delete in to out"
        case .addMarker: "Add a marker"
        case .split: "Split at the playhead"
        case .deleteSelection: "Remove the selection"
        case .transition: "Cross dissolve"
        case .slowMotion: "Slow motion (0.5×)"
        case .normalSpeed: "Normal speed (1×)"
        case .fast: "Fast (2×)"
        case .reframe: "Auto-reframe the selected clips"
        case .closeGaps: "Close gaps"
        case .toolSelect: "Select tool"
        case .toolRoll: "Roll tool"
        case .toolSlip: "Slip tool"
        case .toolSlide: "Slide tool"
        case .insertFromSource: "Insert from the source viewer"
        case .overwriteFromSource: "Overwrite from the source viewer"
        case .matchFrame: "Match frame"
        case .askAgent: "Ask the agent"
        case .dictate: "Speak to the agent (start or stop)"
        case .stopAgent: "Stop the agent"
        case .showInspector: "Inspector"
        case .showChat: "Chat"
        case .showAgents: "Agents"
        case .showHistory: "History"
        case .zoomIn: "Zoom the timeline in"
        case .zoomOut: "Zoom the timeline out"
        case .fullScreenPreview: "Full screen preview"
        case .focusMode: "Focus on the player and the chat"
        case .compare: "Before / after the grade"
        case .sourceViewer: "Source viewer"
        case .home: "Home"
        case .importMedia: "Import media"
        case .exportVideo: "Export video"
        case .batchExport: "Batch export"
        case .exportTimeline: "Export timeline"
        case .keyboardShortcuts: "Keyboard shortcuts"
        }
    }

    var defaults: [KeyCombo] {
        typealias K = KeyCombo
        switch self {
        case .playPause: return [K("space")]
        case .shuttleBack: return [K("j")]
        case .pause: return [K("k")]
        case .shuttleForward: return [K("l")]
        case .stepBack: return [K("left")]
        case .stepForward: return [K("right")]
        case .stepBack10: return [K("left", .shift)]
        case .stepForward10: return [K("right", .shift)]
        case .goToStart: return [K("home")]
        case .goToEnd: return [K("end")]
        case .prevKeyframe: return [K("[")]
        case .nextKeyframe: return [K("]")]
        case .markIn: return [K("i")]
        case .markOut: return [K("o")]
        case .clearInOut: return [K("x")]
        case .deleteInOut: return [K("delete", [.command, .option])]
        case .addMarker: return [K("m"), K("m", [.command, .shift])]
        case .split: return [K("s"), K("b", .command)]
        case .deleteSelection: return [K("delete"), K("forwardDelete")]
        case .transition: return [K("t", .command)]
        case .slowMotion: return [K("1", [.command, .control])]
        case .normalSpeed: return [K("2", [.command, .control])]
        case .fast: return [K("3", [.command, .control])]
        case .reframe: return [K("r", [.command, .option])]
        case .closeGaps: return [K("g", [.command, .option])]
        case .toolSelect: return [K("a")]
        case .toolRoll: return [K("r")]
        case .toolSlip: return [K("y")]
        case .toolSlide: return [K("u")]
        case .insertFromSource: return [K(",")]
        case .overwriteFromSource: return [K(".")]
        case .matchFrame: return [K("f")]
        case .askAgent: return [K("l", .command)]
        case .dictate: return [K("d", [.command, .shift])]
        case .stopAgent: return [K(".", .command)]
        case .showInspector: return [K("1", .command)]
        case .showChat: return [K("2", .command)]
        case .showAgents: return [K("3", .command)]
        case .showHistory: return [K("4", .command)]
        case .zoomIn: return [K("=", .command), K("=", [.command, .shift])]
        case .zoomOut: return [K("-", .command)]
        case .fullScreenPreview: return [K("f", [.command, .shift])]
        case .focusMode: return [K("f", [.command, .option])]
        case .compare: return [K("b", [.command, .option])]
        case .sourceViewer: return [K("s", [.command, .option])]
        case .home: return [K("p", [.command, .shift])]
        case .importMedia: return [K("i", .command)]
        case .exportVideo: return [K("e", .command)]
        case .batchExport: return [K("e", [.command, .shift])]
        case .exportTimeline: return [K("e", [.command, .option])]
        case .keyboardShortcuts: return [K("/", .command)]
        }
    }

    /// Only a menu can do it (it opens a window through SwiftUI): it needs ⌘ or ⌃.
    var menuOnly: Bool { self == .keyboardShortcuts }
}

/// The keys in use: the defaults, with the person's changes on top (Settings ▸ Shortcuts).
@MainActor final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    static let defaultsKey = "keyboardShortcuts"

    @Published private(set) var custom: [ShortcutAction: [KeyCombo]] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.defaultsKey), let saved = try? JSONDecoder().decode([String: [KeyCombo]].self, from: d) {
            for (k, v) in saved { if let a = ShortcutAction(rawValue: k) { custom[a] = v } }
        }
    }

    func combos(_ a: ShortcutAction) -> [KeyCombo] { custom[a] ?? a.defaults }
    func isCustom(_ a: ShortcutAction) -> Bool { custom[a] != nil }

    func set(_ a: ShortcutAction, _ combos: [KeyCombo]) {
        var seen = Set<KeyCombo>()
        let combos = combos.filter { seen.insert($0).inserted }
        if combos == a.defaults { custom[a] = nil } else { custom[a] = combos }
        save()
    }
    func reset(_ a: ShortcutAction) { custom[a] = nil; save() }
    func resetAll() { custom = [:]; save() }

    /// The action a combo runs, if any.
    func action(for combo: KeyCombo) -> ShortcutAction? { ShortcutAction.allCases.first { combos($0).contains(combo) } }
    func action(matching e: NSEvent) -> ShortcutAction? { KeyCombo(event: e).flatMap(action(for:)) }

    /// The menu item's shortcut: the action's first combo with ⌘ or ⌃ (a bare key in a menu would take it from typing).
    func menuShortcut(_ a: ShortcutAction) -> KeyboardShortcut? { combos(a).lazy.compactMap(\.keyboardShortcut).first }

    /// "S or ⌘B".
    func display(_ a: ShortcutAction) -> String { combos(a).map(\.display).joined(separator: "  or  ") }

    private func save() {
        let out = Dictionary(uniqueKeysWithValues: custom.map { ($0.key.rawValue, $0.value) })
        if out.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) }
        else if let d = try? JSONEncoder().encode(out) { defaults.set(d, forKey: Self.defaultsKey) }
    }
}

/// Who else wants a key: macOS (its shortcut table, and the keys every Mac app keeps), another app's global hot key
/// (a key it claims system-wide never reaches EditMax), or the default of a popular app installed here.
enum ShortcutConflicts {
    enum Clash: Equatable {
        case reserved(String)      // ⌘Q, ⌘W… macOS's in every app
        case system(String)        // in macOS's own shortcut table, turned on, and one macOS takes system-wide
        case systemListed          // in that table, turned on, but unnamed: macOS may take it first, or leave it to the app
        case otherApp              // another app holds it as a global hot key right now
        case appDefault(String)    // an installed app's default global shortcut (it may have been changed there)
        /// A key that cannot reach EditMax; an app default only might.
        var blocks: Bool { switch self { case .appDefault, .systemListed: false; default: true } }
        var message: String {
            switch self {
            case .reserved(let what): "macOS keeps this for \(what) in every app."
            case .system(let what): "macOS uses this for \(what) (System Settings ▸ Keyboard ▸ Keyboard Shortcuts)."
            case .systemListed: "macOS lists this among its own shortcuts (System Settings ▸ Keyboard ▸ Keyboard Shortcuts) and may take it before EditMax."
            case .otherApp: "Another app on this Mac already uses this as a global shortcut, so EditMax would never get it."
            case .appDefault(let app): "\(app), installed on this Mac, uses this by default. If you kept that, pick another key here."
            }
        }
    }

    static let reserved: [KeyCombo: String] = [
        KeyCombo("q", .command): "Quit", KeyCombo("w", .command): "Close Window", KeyCombo("h", .command): "Hide",
        KeyCombo("h", [.command, .option]): "Hide Others", KeyCombo("m", .command): "Minimize", KeyCombo(",", .command): "Settings",
        KeyCombo("n", .command): "New Project", KeyCombo("s", .command): "Save", KeyCombo("s", [.command, .shift]): "Duplicate",
        KeyCombo("z", .command): "Undo", KeyCombo("z", [.command, .shift]): "Redo", KeyCombo("x", .command): "Cut",
        KeyCombo("c", .command): "Copy", KeyCombo("v", .command): "Paste", KeyCombo("a", .command): "Select All",
        KeyCombo("o", .command): "Open", KeyCombo("tab", .command): "the app switcher", KeyCombo("`", .command): "switching windows",
        KeyCombo("f", [.command, .control]): "Enter Full Screen", KeyCombo("q", [.command, .control]): "Lock Screen",
        KeyCombo("escape", [.command, .option]): "Force Quit",
    ]

    /// macOS's shortcut table entries that are on (Spotlight ⌘Space, screenshots ⇧⌘4, Mission Control ⌃↑…). A name
    /// for the ones macOS takes system-wide; "" for the rest.
    static func systemShortcuts() -> [KeyCombo: String] {
        var arr: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&arr) == noErr, let list = arr?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var out: [KeyCombo: String] = [:]
        for d in list where (d[kHISymbolicHotKeyEnabled as String] as? Bool) == true {
            guard let code = d[kHISymbolicHotKeyCode as String] as? Int, let mods = d[kHISymbolicHotKeyModifiers as String] as? Int,
                  let c = systemCombo(code: code, carbon: mods) else { continue }
            out[c] = systemName(c) ?? out[c] ?? ""
        }
        return out
    }

    /// One entry of macOS's table as a key EditMax can bind, or nil. The table marks Globe (fn) chords with the Fn bit:
    /// 🌐F, 🌐A, 🌐M are not F, A, M, and EditMax keys have no Globe, so those are skipped. Arrows, Home/End/Page and
    /// the F keys carry that bit by nature and keep it only alongside a real modifier (⌃← is moving between Spaces).
    nonisolated static func systemCombo(code: Int, carbon mods: Int) -> KeyCombo? {
        let fnBit = 0x20000   // kEventKeyModifierFnMask
        if mods & fnBit != 0 {
            let fKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
            let navigation: Set<Int> = [123, 124, 125, 126, 115, 116, 119, 121, 117]
            let real = mods & (cmdKey | shiftKey | optionKey | controlKey) != 0
            guard fKeys.contains(code) || (navigation.contains(code) && real) else { return nil }
        }
        return KeyCombo(keyCode: code, carbon: mods)
    }

    private static func systemName(_ c: KeyCombo) -> String? {
        switch (c.key, c.modifierFlags) {
        case ("space", [.command]): "Spotlight"
        case ("space", [.command, .option]): "a Finder search window"
        case ("space", [.control]), ("space", [.control, .option]): "switching input sources"
        case ("space", [.control, .command]): "Emoji & Symbols"
        case ("3", [.command, .shift]), ("4", [.command, .shift]), ("5", [.command, .shift]): "screenshots"
        case ("up", [.control]): "Mission Control"
        case ("down", [.control]): "Application windows"
        case ("left", [.control]), ("right", [.control]): "moving between Spaces"
        case ("d", [.command, .option]): "showing the Dock"
        default: nil
        }
    }

    /// Popular apps' default global shortcuts, checked only when the app is installed.
    static let appDefaults: [(bundle: String, name: String, combos: [KeyCombo])] = [
        ("com.raycast.macos", "Raycast", [KeyCombo("space", .option)]),
        ("com.runningwithcrayons.Alfred", "Alfred", [KeyCombo("space", .option)]),
        ("com.openai.chat", "ChatGPT", [KeyCombo("space", .option)]),
        ("com.1password.1password", "1Password", [KeyCombo("space", [.command, .shift]), KeyCombo("\\", .command)]),
        ("com.knollsoft.Rectangle", "Rectangle", ["left", "right", "up", "down", "return", "c", "delete"].map { KeyCombo($0, [.control, .option]) }),
        ("com.crowdcafe.windowmagnet", "Magnet", ["left", "right", "up", "down", "return"].map { KeyCombo($0, [.control, .option]) }),
    ]

    /// Probe: claim the key system-wide for an instant. An app that holds it exclusively makes that fail.
    static func heldByAnotherApp(_ c: KeyCombo) -> Bool {
        guard c.command || c.control || c.option, let code = c.keyCode else { return false }   // apps claim chords, not bare keys
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x45444D58), id: 1)   // "EDMX"
        let s = RegisterEventHotKey(code, c.carbonModifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if s == noErr, let ref { UnregisterEventHotKey(ref) }
        return s == OSStatus(eventHotKeyExistsErr)
    }

    /// Everything that clashes with `c`, the blocking ones first.
    static func clashes(_ c: KeyCombo, system: [KeyCombo: String], installed: (String) -> Bool = installed) -> [Clash] {
        var out: [Clash] = []
        if let r = reserved[c] { out.append(.reserved(r)) }
        if let s = system[c] { out.append(s.isEmpty ? .systemListed : .system(s)) }
        if out.isEmpty, heldByAnotherApp(c) { out.append(.otherApp) }
        for a in appDefaults where a.combos.contains(c) && installed(a.bundle) { out.append(.appDefault(a.name)) }
        return out
    }

    static func installed(_ bundle: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil }
}
