import SwiftUI
import AppKit

/// The Settings window (⌘,): standard grouped forms, no glass. Every value here is a UserDefaults key or a keychain
/// item that another part of the app reads; nothing lives only in this window.
struct SettingsView: View {
    enum Pane: String, Hashable, CaseIterable { case general, assistant, keys, runtime, advanced }
    @State private var pane: Pane = .general

    var body: some View {
        // The `Tab` API with an explicit selection: with the older `.tabItem` form the toolbar kept the first tab's
        // icon tinted after switching away (seen on macOS 26).
        TabView(selection: $pane) {
            Tab(value: Pane.general) { GeneralSettings() } label: { tab("General", "gearshape") }
            Tab(value: Pane.assistant) { AssistantSettings() } label: { tab("Assistant", "sparkles") }
            Tab(value: Pane.keys) { KeysSettings() } label: { tab("API Keys", "key") }
            Tab(value: Pane.runtime) { RuntimeSettings() } label: { tab("Agent Runtime", "shippingbox") }
            Tab(value: Pane.advanced) { AdvancedSettings() } label: { tab("Advanced", "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 580)
        .onAppear { AppSettings.shared.reloadChatDefaults() }
    }

    /// Monochrome on purpose: some symbols (gearshape) carry a multicolor variant that the toolbar would otherwise
    /// use, which left the General icon tinted whichever tab was selected.
    private func tab(_ title: String, _ symbol: String) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).symbolRenderingMode(.monochrome) }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var updates = AppUpdater.shared
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Library folder") {
                    HStack(spacing: 8) {
                        Text(ProjectLibrary.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(ProjectLibrary.directory.path)
                        Button("Change…") { chooseLibrary() }.controlSize(.small).pointer().uiFrame("settings.general.library.change")
                        if !s.libraryPath.isEmpty {
                            Button("Use Default") { s.libraryPath = "" }.controlSize(.small).pointer().uiFrame("settings.general.library.default")
                        }
                    }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ProjectLibrary.directory]) }
                    .controlSize(.small).pointer().uiFrame("settings.general.library.reveal")
            } footer: {
                Text("New projects are saved here and Home lists what it finds here. The default is Movies ▸ EditMax Projects.")
            }
            Section {
                Toggle("Show the splash screen at launch", isOn: $s.showSplash).pointer().uiFrame("settings.general.splash")
            }
            Section {
                Picker("Appearance", selection: $s.appearance) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).pointer().uiFrame("settings.general.appearance")
                Toggle("Use Liquid Glass", isOn: $s.useLiquidGlass).pointer().uiFrame("settings.general.glass")
            } footer: {
                Text(glassNote)
            }
            Section {
                Toggle("Show EditMax in the menu bar", isOn: $showMenuBarIcon).pointer().uiFrame("settings.general.menuBarIcon")
            } footer: {
                Text("The icon at the top right of the screen: a new project, Home, recent projects, the MCP server and updates.")
            }
            Section {
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                    .disabled(!AppUpdater.isEnabled).pointer().uiFrame("settings.general.updates.check")
                Toggle("Download and install updates in the background", isOn: $updates.installsAutomatically)
                    .disabled(!AppUpdater.isEnabled || !updates.checksAutomatically).pointer().uiFrame("settings.general.updates.install")
                LabeledContent("Last checked") {
                    HStack(spacing: 8) {
                        Text(updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never").foregroundStyle(.secondary)
                        Button("Check Now") { updates.checkForUpdates() }.controlSize(.small).disabled(!updates.canCheck)
                            .pointer().uiFrame("settings.general.updates.checkNow")
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updateNote)
            }
            Section {
                LabeledContent("EditMax \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")", value: "by Saidev Dhal")
            }
        }
        .formStyle(.grouped)
    }

    private var updateNote: String {
        guard AppUpdater.isEnabled else { return "Updates are off in development builds." }
        if !updates.checksAutomatically { return "EditMax checks only when you ask (Check Now, or EditMax ▸ Check for Updates…)." }
        return updates.installsAutomatically
            ? "EditMax checks once a day, downloads a new version in the background and installs it the next time you quit."
            : "EditMax checks once a day and asks before downloading a new version."
    }

    private var glassNote: String {
        if #available(macOS 26, *) { return "Liquid Glass on the controls that float over the picture (toolbar, transport, chat bar, tab strip). Turning it off uses a plain material; takes effect after you relaunch EditMax." }
        return "Liquid Glass needs macOS 26; this Mac shows the plain material either way."
    }

    private func chooseLibrary() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = ProjectLibrary.directory
        p.prompt = "Use Folder"
        p.begin { if $0 == .OK, let u = p.url { s.libraryPath = u.path } }
    }
}

// MARK: Assistant

private struct AssistantSettings: View {
    @ObservedObject private var s = AppSettings.shared

    /// Agents and providers the open chats know about (asked of the agent runtime); a fixed list before any chat ran.
    private var agents: [(id: String, name: String, installed: Bool?)] {
        if let live = ChatSession.anyAgents, !live.isEmpty { return live.map { ($0.id, $0.name, $0.installed) } }
        return [("claude", "Claude Code", nil), ("codex", "Codex CLI", nil), ("opencode", "OpenCode", nil), ("cursor", "Cursor", nil),
                ("grok", "Grok", nil), ("antigravity", "Antigravity", nil), ("copilot", "Copilot", nil)]
    }
    private var providers: [(id: String, name: String, model: String?)] {
        if let live = ChatSession.anyProviders, !live.isEmpty { return live.map { ($0.id, $0.name, $0.defaultModel) } }
        return [("claude-agent", "Claude Agent SDK", nil), ("anthropic", "Anthropic", nil), ("openai", "OpenAI", nil), ("google", "Google", nil), ("xai", "xAI", nil)]
    }

    var body: some View {
        Form {
            Section {
                Picker("Backend", selection: $s.chatBackend) {
                    ForEach(ChatSession.Backend.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).pointer().uiFrame("settings.assistant.backend")
            } footer: {
                Text(s.chatBackend == ChatSession.Backend.agent.rawValue
                     ? "Agent: a coding agent already on this Mac (Claude Code, Codex, OpenCode, Cursor…) works the timeline through EditMax's agent runtime, with its own login. No API key."
                     : "API key: your own key, through EditMax's bundled sidecar. Keys live in the keychain; see the API Keys tab.")
            }
            if s.chatBackend == ChatSession.Backend.agent.rawValue {
                Section {
                    Picker("Agent", selection: $s.chatAgent) {
                        ForEach(agents, id: \.id) { a in
                            Text(a.installed == false ? "\(a.name) (not installed)" : a.name).tag(a.id)
                        }
                        if !agents.contains(where: { $0.id == s.chatAgent }) { Text(s.chatAgent).tag(s.chatAgent) }
                    }
                    .pointer().uiFrame("settings.assistant.agent")
                } footer: {
                    Text(ChatSession.installHints[s.chatAgent].map { "Install: \($0)" } ?? "Which agents are installed shows in the chat once a project is open.")
                        .font(.system(size: 11, design: .monospaced))
                }
            } else {
                Section {
                    Picker("Provider", selection: $s.chatProvider) {
                        ForEach(providers, id: \.id) { Text($0.name).tag($0.id) }
                        if !providers.contains(where: { $0.id == s.chatProvider }) { Text(s.chatProvider).tag(s.chatProvider) }
                    }
                    .pointer().uiFrame("settings.assistant.provider")
                    TextField("Model", text: $s.chatModel, prompt: Text(providers.first { $0.id == s.chatProvider }?.model ?? "provider default"))
                        .uiFrame("settings.assistant.model")
                } footer: {
                    Text("A model id, or empty for the provider's default.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: API keys

private struct KeysSettings: View {
    @State private var drafts: [String: String] = [:]
    @State private var version = 0
    private let names = ["anthropic": "Anthropic", "openai": "OpenAI", "google": "Google", "xai": "xAI"]

    var body: some View {
        Form {
            ForEach(KeychainStore.slots, id: \.self) { slot in
                let source = KeychainStore.source(slot)
                Section {
                    if source == "environment" {
                        LabeledContent(names[slot] ?? slot) { Text("From \(KeychainStore.envNames[slot] ?? "the environment")").foregroundStyle(.secondary) }
                    } else {
                        HStack(spacing: 8) {
                            SecureField(names[slot] ?? slot, text: binding(slot), prompt: Text(source == "keychain" ? "Saved in the keychain; paste a new one to replace it" : placeholder(slot)))
                                .textFieldStyle(.roundedBorder).uiFrame("settings.keys.\(slot).field")
                            Button("Save") { save(slot) }
                                .controlSize(.small).pointer().disabled(draft(slot).isEmpty).uiFrame("settings.keys.\(slot).save")
                            if source == "keychain" {
                                Button("Remove") { remove(slot) }.controlSize(.small).pointer().uiFrame("settings.keys.\(slot).remove")
                            }
                        }
                    }
                } footer: {
                    HStack(alignment: .top) {
                        Text(source == "keychain" ? "Saved in your login keychain. Keys go only to the sidecar, never to a log."
                             : source == "environment" ? "The environment variable wins over the keychain while it is set."
                             : "Used by the API-key backend with \(names[slot] ?? slot).")
                        Spacer(minLength: 12)
                        if let url = ChatSession.keyConsoles[slot].flatMap(URL.init(string:)) {
                            Link("Get a key", destination: url).pointer()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .id(version)
    }

    private func placeholder(_ slot: String) -> String { slot == "anthropic" ? "sk-ant-…" : slot == "google" ? "AIza…" : slot == "xai" ? "xai-…" : "sk-…" }
    private func draft(_ slot: String) -> String { (drafts[slot] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private func binding(_ slot: String) -> Binding<String> { Binding(get: { drafts[slot] ?? "" }, set: { drafts[slot] = $0 }) }
    private func save(_ slot: String) {
        KeychainStore.save(draft(slot), slot: slot)
        drafts[slot] = ""
        DebugLog.event("key-saved", ["slot": slot])   // the slot only, never the key
        NotificationCenter.default.post(name: .editmaxKeysChanged, object: nil)
        version += 1
    }
    private func remove(_ slot: String) {
        KeychainStore.save("", slot: slot)
        DebugLog.event("key-removed", ["slot": slot])
        NotificationCenter.default.post(name: .editmaxKeysChanged, object: nil)
        version += 1
    }
}

// MARK: Agent runtime

private struct RuntimeSettings: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var installer = CodemaxInstaller.shared
    @ObservedObject private var updater = CodemaxUpdater.shared

    var body: some View {
        let st = installer.status, u = updater.status
        Form {
            Section {
                LabeledContent("Bundled", value: st.bundledVersion ?? "—")
                LabeledContent("Running", value: (u.activeVersion ?? st.bundledVersion ?? "—") + " · " + u.activeSource)
                LabeledContent("Latest release", value: u.latest ?? "not checked")
                HStack(spacing: 8) {
                    Text(u.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if u.busy { ProgressView().controlSize(.mini) }
                    Button("Check Now") { updater.check(reason: "settings") }
                        .controlSize(.small).pointer().disabled(u.busy).uiFrame("settings.runtime.check")
                }
            } footer: {
                Text("The agent runtime ships inside EditMax and drives the coding agents on this Mac. " + st.message)
            }
            Section {
                Toggle("Check for updates automatically", isOn: $s.autoUpdateRuntime).pointer().uiFrame("settings.runtime.auto")
            } footer: {
                Text(s.autoUpdateRuntime ? "Checked every 12 hours; a new release installs after a health check and rolls back if it crashes."
                     : "Only Check Now looks for a new release.")
            }
            if let p = st.installedPath {
                Section {
                    LabeledContent("Location") {
                        Text(p.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(p)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Advanced

private struct AdvancedSettings: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var mcp = MCPService.shared
    @State private var note: String?
    @State private var showToken = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    switch mcp.status {
                    case .running(let p): Text("Running on port \(String(p))")
                    case .failed(let e): Text("Failed: \(e)").foregroundStyle(.red)
                    case .stopped: Text("Stopped")
                    }
                }
                TextField("Port", value: $s.mcpPort, format: .number.grouping(.never)).uiFrame("settings.advanced.port")
                LabeledContent("Token") {
                    HStack(spacing: 8) {
                        Text(showToken ? mcp.token : String(repeating: "•", count: 24)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Button(showToken ? "Hide" : "Show") { showToken.toggle() }.controlSize(.small).pointer().uiFrame("settings.advanced.token.show")
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(mcp.token, forType: .string) }
                            .controlSize(.small).pointer().uiFrame("settings.advanced.token.copy")
                    }
                }
                LabeledContent("Config file") {
                    Text(MCPService.configDirectory.appendingPathComponent("mcp.json").path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            } footer: {
                Text("Agents reach the timeline through this local server. A new port takes effect after you relaunch EditMax; the token is written into the agents' config for you.")
            }
            Section {
                Toggle("Follow the agent in the window", isOn: $s.followAgent).pointer().uiFrame("settings.advanced.followAgent")
            } footer: {
                Text("While an agent edits, the window shows where: the clip is selected, the playhead moves onto it, the inspector scrolls to the setting that changes and the mixer opens for a mix change. It waits while you are using the mouse or keyboard.")
            }
            Section {
                HStack(spacing: 8) {
                    Button("Reveal Logs") { DebugLog.reveal() }.controlSize(.small).pointer().uiFrame("settings.advanced.logs")
                    Button("Export Diagnostics…") { export() }.controlSize(.small).pointer().uiFrame("settings.advanced.export")
                }
                if let n = note { Text(n).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("The log records the agent runtime, the updater and the MCP server; prompts, keys and typed text are never written.")
            }
        }
        .formStyle(.grouped)
    }

    private func export() {
        do {
            let zip = try DebugLog.exportDiagnostics(versions: ["editmax": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                                                                "codemax-bundled": CodemaxInstaller.shared.status.bundledVersion ?? ""])
            note = "Saved \(zip.lastPathComponent) to the Desktop."
            NSWorkspace.shared.activateFileViewerSelecting([zip])
        } catch { note = "Export failed: \(error.localizedDescription)" }
    }
}
