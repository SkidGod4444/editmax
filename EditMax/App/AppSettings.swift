import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by Settings after it writes a chat default (backend, agent, provider, model); open chats re-read them.
    static let editmaxChatDefaultsChanged = Notification.Name("editmaxChatDefaultsChanged")
    /// Posted after an API key is saved or removed; open chats hand the sidecar its keys again.
    static let editmaxKeysChanged = Notification.Name("editmaxKeysChanged")
}

/// App-wide preferences behind the Settings window (⌘,). Each one is a UserDefaults key read by the part of the app it
/// drives; the chat keys are the ones ChatSession already uses, so the chat header and Settings edit the same values.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Appearance: String, CaseIterable { case system = "System", light = "Light", dark = "Dark" }
    enum Key {
        static let showSplash = "showSplash", appearance = "appearance", library = "libraryDirectory"
        static let autoUpdate = "autoUpdateRuntime", mcpPort = "mcpPort", liquidGlass = "useLiquidGlass"
        static let chatBackend = "chatBackend", chatAgent = "chatAgent", chatProvider = "chatProvider", chatModel = "chatModel"
        static let followAgent = "followAgent"
    }

    /// A Bool default with a default: UserDefaults reads an unset key as false.
    nonisolated static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }

    private let d = UserDefaults.standard
    private var loading = false

    @Published var showSplash: Bool { didSet { d.set(showSplash, forKey: Key.showSplash) } }
    @Published var appearance: Appearance { didSet { d.set(appearance.rawValue, forKey: Key.appearance); applyAppearance() } }
    /// Empty: the default (Movies ▸ EditMax Projects).
    @Published var libraryPath: String { didSet { d.set(libraryPath, forKey: Key.library); ProjectLibrary.shared.refresh() } }
    @Published var autoUpdateRuntime: Bool { didSet { d.set(autoUpdateRuntime, forKey: Key.autoUpdate) } }
    @Published var mcpPort: Int { didSet { d.set(mcpPort, forKey: Key.mcpPort) } }
    @Published var useLiquidGlass: Bool { didSet { d.set(useLiquidGlass, forKey: Key.liquidGlass) } }
    @Published var followAgent: Bool { didSet { d.set(followAgent, forKey: Key.followAgent) } }

    @Published var chatBackend: String { didSet { d.set(chatBackend, forKey: Key.chatBackend); broadcast() } }
    @Published var chatAgent: String { didSet { d.set(chatAgent, forKey: Key.chatAgent); broadcast() } }
    @Published var chatProvider: String { didSet { d.set(chatProvider, forKey: Key.chatProvider); broadcast() } }
    @Published var chatModel: String { didSet { d.set(chatModel, forKey: Key.chatModel); broadcast() } }

    private init() {
        showSplash = Self.bool(Key.showSplash, default: true)
        appearance = d.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
        libraryPath = d.string(forKey: Key.library) ?? ""
        autoUpdateRuntime = Self.bool(Key.autoUpdate, default: true)
        mcpPort = d.integer(forKey: Key.mcpPort).nonZero ?? 19790
        useLiquidGlass = Self.bool(Key.liquidGlass, default: true)
        followAgent = Self.bool(Key.followAgent, default: true)
        chatBackend = d.string(forKey: Key.chatBackend) ?? "Agent"
        chatAgent = d.string(forKey: Key.chatAgent) ?? "claude"
        chatProvider = d.string(forKey: Key.chatProvider) ?? "claude-agent"
        chatModel = d.string(forKey: Key.chatModel) ?? ""
    }

    /// The chat header writes the same keys; Settings re-reads them when it comes up.
    func reloadChatDefaults() {
        loading = true; defer { loading = false }
        let b = d.string(forKey: Key.chatBackend) ?? "Agent"; if b != chatBackend { chatBackend = b }
        let a = d.string(forKey: Key.chatAgent) ?? "claude"; if a != chatAgent { chatAgent = a }
        let p = d.string(forKey: Key.chatProvider) ?? "claude-agent"; if p != chatProvider { chatProvider = p }
        let m = d.string(forKey: Key.chatModel) ?? ""; if m != chatModel { chatModel = m }
    }

    private func broadcast() {
        guard !loading else { return }
        NotificationCenter.default.post(name: .editmaxChatDefaultsChanged, object: nil)
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// The library folder in use: the chosen one when it exists, else the default.
    var libraryURL: URL { ProjectLibrary.directory }
}

private extension Int { var nonZero: Int? { self == 0 ? nil : self } }
