import SwiftUI
import AppKit

/// The Settings window (⌘,): four tabs, each with one job, in standard grouped forms (no glass). Every value here is a
/// UserDefaults key or a keychain item that another part of the app reads; nothing lives only in this window.
/// - General: how EditMax looks and starts, the menu bar icon, EditMax updates.
/// - Files: the projects folder, adding files (notch drawer, Downloads), deleted files (the Archive).
/// - Assistant: who edits with you (an agent on this Mac, or a provider and its API keys), Follow the agent.
/// - Advanced: the MCP server, the agent runtime, logs.
struct SettingsView: View {
    enum Pane: String, Hashable, CaseIterable { case general, files, assistant, advanced }
    static let paneKey = "settingsPane"
    /// The tab last shown, and the one `show(_:using:)` asks for.
    @AppStorage(Self.paneKey) private var pane: Pane = .general

    /// Opens Settings at a tab: a link elsewhere (the Archive page's "Change…") lands where its setting is.
    static func show(_ pane: Pane, using open: OpenSettingsAction) {
        UserDefaults.standard.set(pane.rawValue, forKey: paneKey)
        open()
    }

    var body: some View {
        // The `Tab` API with an explicit selection: with the older `.tabItem` form the toolbar kept the first tab's
        // icon tinted after switching away (seen on macOS 26).
        TabView(selection: $pane) {
            Tab(value: Pane.general) { GeneralSettings() } label: { tab("General", "gearshape") }
            Tab(value: Pane.files) { FilesSettings() } label: { tab("Files", "folder") }
            Tab(value: Pane.assistant) { AssistantSettings() } label: { tab("Assistant", "sparkles") }
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

/// How EditMax looks and starts, the menu bar icon, and EditMax's own updates.
struct GeneralSettings: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var updates = AppUpdater.shared
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $s.appearance) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).pointer().uiFrame("settings.general.appearance")
                Toggle(isOn: $s.useLiquidGlass) { Text("Use Liquid Glass"); Text(glassNote) }
                    .pointer().uiFrame("settings.general.glass")
            }
            Section {
                Toggle("Show the splash screen at launch", isOn: $s.showSplash).pointer().uiFrame("settings.general.splash")
                Toggle(isOn: $showMenuBarIcon) {
                    Text("Show EditMax in the menu bar")
                    Text("A new project, Home, recent projects and updates from the top right of the screen.")
                }
                .pointer().uiFrame("settings.general.menuBarIcon")
            }
            Section {
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                    .disabled(!AppUpdater.isEnabled).pointer().uiFrame("settings.general.updates.check")
                Toggle("Download and install them in the background", isOn: $updates.installsAutomatically)
                    .disabled(!AppUpdater.isEnabled || !updates.checksAutomatically).pointer().uiFrame("settings.general.updates.install")
                LabeledContent("Last checked") {
                    HStack(spacing: 8) {
                        Text(updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never").foregroundStyle(.secondary)
                        Button("Check Now") { updates.checkForUpdates() }.controlSize(.small).disabled(!updates.canCheck)
                            .pointer().uiFrame("settings.general.updates.checkNow")
                    }
                }
            } header: {
                Text("EditMax updates")
            } footer: {
                Text(updateNote)
            }
            Section {
                LabeledContent {
                    Button("by Saidev Dhal") { NSWorkspace.shared.open(HomeFooter.makerURL) }
                        .buttonStyle(.link).pointer().help(HomeFooter.makerURL.absoluteString).uiFrame("settings.general.maker")
                } label: { Text(verbatim: "EditMax \(version)") }
            }
        }
        .formStyle(.grouped)
    }

    private var updateNote: String {
        guard AppUpdater.isEnabled else { return "Updates are off in development builds." }
        if !updates.checksAutomatically { return "EditMax checks only when you ask (Check Now, or EditMax ▸ Check for Updates…)." }
        return updates.installsAutomatically
            ? "Once a day; a new version downloads in the background and installs the next time you quit."
            : "Once a day; EditMax asks before downloading a new version."
    }

    private var glassNote: String {
        if #available(macOS 26, *) { return "On the controls over the picture (toolbar, transport, chat bar). Off uses a plain material; takes effect after you relaunch." }
        return "Needs macOS 26; this Mac shows the plain material either way."
    }
}

// MARK: Files

/// Where projects are saved, how files get into Assets from outside EditMax, and what happens to deleted files.
struct FilesSettings: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var archive = AppArchive.shared
    @State private var confirmEmpty = false
    /// A shorter period that would erase items at once, waiting for the user to confirm (nil: none).
    @State private var pendingDays: Int?
    private static func daysText(_ d: Int) -> String { d == 1 ? "1 day" : "\(d) days" }
    private var pendingTitle: String {
        let n = pendingDays.map { archive.wouldErase(days: $0) } ?? 0
        return "Erase \(n) item\(n == 1 ? "" : "s") from the Archive now?"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Projects folder") {
                    HStack(spacing: 8) {
                        Text(ProjectLibrary.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(ProjectLibrary.directory.path)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([ProjectLibrary.directory]) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Show in Finder").pointer().uiFrame("settings.files.library.reveal")
                        Button("Change…") { chooseLibrary() }.controlSize(.small).pointer().uiFrame("settings.files.library.change")
                        if !s.libraryPath.isEmpty {
                            Button("Use Default") { s.libraryPath = "" }.controlSize(.small).pointer().uiFrame("settings.files.library.default")
                        }
                    }
                }
            } header: {
                Text("Projects")
            } footer: {
                Text("New projects are saved here and Home lists them. The default is Movies ▸ EditMax Projects.")
            }
            Section {
                Toggle(isOn: $s.notchDrawer) {
                    Text("Notch drawer")
                    Text("Drop files on the notch at the top of the screen to add them to Assets, from any app.")
                }
                .pointer().uiFrame("settings.files.notchDrawer")
                Toggle(isOn: $s.watchDownloads) {
                    Text("Watch Downloads")
                    Text("The drawer lists video, audio, images and fonts downloaded in the last day, to add with a click. macOS asks once, the first time you open the drawer.")
                }
                .pointer().disabled(!s.notchDrawer).uiFrame("settings.files.watchDownloads")
            } header: {
                Text("Adding files")
            }
            Section {
                Picker("Keep deleted files for", selection: Binding(get: { s.archiveDays }, set: { d in
                    // A shorter period erases what is already older than it: ask first, naming how many.
                    if archive.wouldErase(days: d) > 0 { pendingDays = d } else { s.archiveDays = d }
                })) {
                    ForEach(AppArchive.periods, id: \.self) { d in Text(Self.daysText(d)).tag(d) }
                }
                .pointer().uiFrame("settings.files.archiveDays")
                LabeledContent("Archive") {
                    HStack(spacing: 8) {
                        Text(archive.entries.isEmpty ? "Empty" : "\(archive.entries.count) item\(archive.entries.count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: archive.totalBytes, countStyle: .file))")
                            .foregroundStyle(.secondary).monospacedDigit()
                        Button("Show Archive…") { HomeWindow.shared.show(place: .archive) }.controlSize(.small).pointer().uiFrame("settings.files.archive.show")
                        Button("Empty Now…") { confirmEmpty = true }.controlSize(.small).disabled(archive.entries.isEmpty)
                            .pointer().uiFrame("settings.files.archive.empty")
                    }
                }
            } header: {
                Text("Deleted files")
            } footer: {
                Text("Media copies, projects, fonts, templates and exports you replace wait in the Archive (Home ▸ Archive) so you can restore them, then are erased for good.")
            }
            .confirmationDialog(pendingTitle, isPresented: Binding(get: { pendingDays != nil }, set: { if !$0 { pendingDays = nil } }), titleVisibility: .visible) {
                Button("Erase and Keep \(pendingDays.map(Self.daysText) ?? "")", role: .destructive) { if let d = pendingDays { s.archiveDays = d }; pendingDays = nil }
                Button("Cancel", role: .cancel) { pendingDays = nil }
            } message: { Text("They were deleted more than \(pendingDays.map(Self.daysText) ?? "") ago. This can't be undone; Cancel keeps \(Self.daysText(s.archiveDays)).") }
            .confirmationDialog("Erase everything in the Archive now?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Erase \(archive.entries.count) Item\(archive.entries.count == 1 ? "" : "s")", role: .destructive) { archive.emptyNow() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This can't be undone.") }
        }
        .formStyle(.grouped)
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

/// Who edits with you: a coding agent already on this Mac, or a provider through your own API key (the keys are here
/// too), and how the window follows any agent's edits.
struct AssistantSettings: View {
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
    private var usesAgent: Bool { s.chatBackend == ChatSession.Backend.agent.rawValue }

    var body: some View {
        Form {
            Section {
                Picker("Edit with", selection: $s.chatBackend) {
                    ForEach(ChatSession.Backend.allCases, id: \.rawValue) { Text($0 == .agent ? "An agent on this Mac" : "My API key").tag($0.rawValue) }
                }
                .pickerStyle(.segmented).pointer().uiFrame("settings.assistant.backend")
                if usesAgent {
                    Picker("Agent", selection: $s.chatAgent) {
                        ForEach(agents, id: \.id) { a in
                            Text(a.installed == false ? "\(a.name) (not installed)" : a.name).tag(a.id)
                        }
                        if !agents.contains(where: { $0.id == s.chatAgent }) { Text(s.chatAgent).tag(s.chatAgent) }
                    }
                    .pointer().uiFrame("settings.assistant.agent")
                } else {
                    Picker("Provider", selection: $s.chatProvider) {
                        ForEach(providers, id: \.id) { Text($0.name).tag($0.id) }
                        if !providers.contains(where: { $0.id == s.chatProvider }) { Text(s.chatProvider).tag(s.chatProvider) }
                    }
                    .pointer().uiFrame("settings.assistant.provider")
                    TextField("Model", text: $s.chatModel, prompt: Text(providers.first { $0.id == s.chatProvider }?.model ?? "provider default"))
                        .uiFrame("settings.assistant.model")
                }
            } header: {
                Text("Chat")
            } footer: {
                if usesAgent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claude Code, Codex, OpenCode, Cursor… with its own login. No API key.")
                        if agents.first(where: { $0.id == s.chatAgent })?.installed != true, let hint = ChatSession.installHints[s.chatAgent] { Text("Install: \(hint)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    }
                } else {
                    Text("Your own key, sent only to the provider. Leave Model empty for the provider's default.")
                }
            }
            if !usesAgent { APIKeysSection(inUse: KeychainStore.slot(forProvider: s.chatProvider)) }
            Section {
                Toggle(isOn: $s.followAgent) {
                    Text("Follow the agent in the window")
                    Text("While an agent edits (from the chat or over MCP), the clip is selected, the playhead moves onto it and the inspector shows the setting that changes. It waits while you use the mouse or keyboard.")
                }
                .pointer().uiFrame("settings.assistant.followAgent")
            }
        }
        .formStyle(.grouped)
    }
}

/// The API keys, one row each, in the login keychain (or from the environment, which wins while it is set). The row
/// the chosen provider uses says so.
struct APIKeysSection: View {
    let inUse: String?
    @State private var drafts: [String: String] = [:]
    @State private var version = 0
    private let names = ["anthropic": "Anthropic", "openai": "OpenAI", "google": "Google", "xai": "xAI"]

    var body: some View {
        Section {
            ForEach(KeychainStore.slots, id: \.self) { slot in row(slot) }
        } header: {
            Text("API keys")
        } footer: {
            Text("Keys stay in your login keychain and go only to the provider, never to a log. An environment variable (such as ANTHROPIC_API_KEY) wins while it is set.")
        }
        .id(version)
    }

    @ViewBuilder private func row(_ slot: String) -> some View {
        let source = KeychainStore.source(slot)
        LabeledContent {
            if source == "environment" {
                Text("From \(KeychainStore.envNames[slot] ?? "the environment")").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    SecureField(names[slot] ?? slot, text: binding(slot), prompt: Text(source == "keychain" ? "Saved ••••••" : placeholder(slot)))
                        .labelsHidden().textFieldStyle(.roundedBorder).uiFrame("settings.keys.\(slot).field")
                    Button("Save") { save(slot) }
                        .controlSize(.small).pointer().disabled(draft(slot).isEmpty).uiFrame("settings.keys.\(slot).save")
                    if source == "keychain" {
                        Button("Remove") { remove(slot) }.controlSize(.small).pointer().uiFrame("settings.keys.\(slot).remove")
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(names[slot] ?? slot)
                    if slot == inUse {
                        Text("In use").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                if let url = ChatSession.keyConsoles[slot].flatMap(URL.init(string:)) {
                    Link("Get a key", destination: url).font(.caption).pointer()
                }
            }
        }
        .uiFrame("settings.keys.\(slot)")
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

// MARK: Advanced

/// For connecting other tools and for trouble: the MCP server agents reach the timeline through, the agent runtime
/// that runs the coding agents, and the logs.
struct AdvancedSettings: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var mcp = MCPService.shared
    @ObservedObject private var installer = CodemaxInstaller.shared
    @ObservedObject private var updater = CodemaxUpdater.shared
    @State private var note: String?
    @State private var showToken = false

    var body: some View {
        let st = installer.status, u = updater.status
        let running = u.activeVersion ?? st.bundledVersion ?? "—"
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
            } header: {
                Text("MCP server")
            } footer: {
                Text("Agents reach the timeline through this local server; the token is written into their config for you. A new port takes effect after you relaunch EditMax.")
            }
            Section {
                LabeledContent("Version") {
                    Text(running + " · " + u.activeSource + (st.bundledVersion.map { $0 != running ? " (bundled \($0))" : "" } ?? "")).foregroundStyle(.secondary).monospacedDigit()
                }
                LabeledContent("Latest release") {
                    HStack(spacing: 8) {
                        Text(u.latest ?? "Not checked").foregroundStyle(.secondary)
                        if u.busy { ProgressView().controlSize(.mini) }
                        Button("Check Now") { updater.check(reason: "settings") }
                            .controlSize(.small).pointer().disabled(u.busy).uiFrame("settings.runtime.check")
                    }
                }
                Toggle(isOn: $s.autoUpdateRuntime) {
                    Text("Update the agent runtime automatically")
                    Text(s.autoUpdateRuntime ? "Every 12 hours; a new release installs after a health check and rolls back if it crashes." : "Only Check Now looks for a new release.")
                }
                .pointer().uiFrame("settings.runtime.auto")
                if let p = st.installedPath {
                    LabeledContent("Location") {
                        Text(p.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(p)
                    }
                }
            } header: {
                Text("Agent runtime")
            } footer: {
                Text(["Ships inside EditMax and runs the coding agents on this Mac.", st.message, u.message].filter { !$0.isEmpty }.joined(separator: " "))
                    .textSelection(.enabled)
            }
            Section {
                HStack(spacing: 8) {
                    Button("Reveal Logs") { DebugLog.reveal() }.controlSize(.small).pointer().uiFrame("settings.advanced.logs")
                    Button("Export Diagnostics…") { export() }.controlSize(.small).pointer().uiFrame("settings.advanced.export")
                }
                if let n = note { Text(n).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("The log records the agent runtime, the updaters and the MCP server; prompts, keys and typed text are never written.")
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
