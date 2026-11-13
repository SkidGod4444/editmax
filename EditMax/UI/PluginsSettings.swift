import SwiftUI
import AppKit

// MARK: Plugins

/// Settings ▸ Plugins: what is installed (on or off, with its skills, servers and settings), adding a plugin from
/// this Mac, and the hub. Installing anything goes through the review sheet, which shows the commands the plugin
/// would run and the addresses it would call before it is turned on.
struct PluginsSettings: View {
    @ObservedObject private var store = PluginStore.shared
    @ObservedObject private var hub = PluginHub.shared

    @State private var staged: PluginStore.Staged?
    @State private var details: Plugin?
    /// A plugin with servers that was put in the folder by hand: turning it on asks first.
    @State private var confirmOn: Plugin?
    @State private var note: String?
    @State private var busy: String?

    var body: some View {
        Form {
            installed
            hubSection
        }
        .formStyle(.grouped)
        .task { if hub.index == nil, !AppDelegate.isTesting { await hub.refresh() } }   // tests read a hub on disk, never the network
        .sheet(item: $staged) { s in
            PluginReviewSheet(staged: s) { install in
                if install { commit(s) } else { store.discard(s) }
                staged = nil
            }
        }
        .sheet(item: $details) { p in PluginDetailsSheet(pluginID: p.id) { details = nil } }
        .confirmationDialog("Turn on \(confirmOn?.name ?? "")?", isPresented: Binding(get: { confirmOn != nil }, set: { if !$0 { confirmOn = nil } }), titleVisibility: .visible) {
            Button("Turn On") { if let p = confirmOn { store.setEnabled(p.id, true) }; confirmOn = nil }
            Button("Cancel", role: .cancel) { confirmOn = nil }
        } message: {
            Text("Its tools run without asking each time. It adds:\n" + (confirmOn?.servers.map { ($0.runsLocally ? "Runs on this Mac: " : "Calls: ") + $0.summary }.joined(separator: "\n") ?? ""))
        }
    }

    // MARK: Installed

    private var installed: some View {
        Section {
            if store.plugins.isEmpty {
                Text("No plugins yet. Install one from the hub below, or add one from this Mac.").foregroundStyle(.secondary)
            }
            ForEach(store.plugins) { p in row(p) }
            ForEach(store.problems.keys.sorted(), id: \.self) { name in
                LabeledContent(name) { Text(store.problems[name] ?? "").foregroundStyle(.orange).font(.caption).multilineTextAlignment(.trailing) }
            }
            HStack(spacing: 8) {
                Button("Add from This Mac…") { choose() }.controlSize(.small).pointer().uiFrame("settings.plugins.add")
                Button("Show Folder") { NSWorkspace.shared.open(store.root) }.controlSize(.small).pointer().uiFrame("settings.plugins.reveal")
                Spacer(minLength: 0)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        } header: {
            Text("Installed")
        } footer: {
            Text("A plugin gives the agent skills (how to do a kind of edit) and tools (its MCP servers). While a plugin is on, its tools run without asking each time and its skills are read as instructions, so turn on only plugins you trust. Changes apply from your next chat message.")
        }
    }

    @ViewBuilder private func row(_ p: Plugin) -> some View {
        let missing = store.missingSettings(in: p)
        let notFound = store.isEnabled(p.id) ? store.missingCommands(in: p) : []
        Toggle(isOn: Binding(get: { store.isEnabled(p.id) }, set: { on in
            if on, !p.servers.isEmpty, store.entries[p.id] == nil { confirmOn = p } else { store.setEnabled(p.id, on) }
        })) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name + (p.version.isEmpty ? "" : "  \(p.version)"))
                    Text(Self.contents(p) + (p.summary.isEmpty ? "" : " · \(p.summary)")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if store.isEnabled(p.id), !missing.isEmpty {
                        Text("Needs \(missing.joined(separator: ", ")) before its tools can start. Enter it in Details.").font(.caption).foregroundStyle(.orange)
                    }
                    if !notFound.isEmpty {
                        Text("Not found on this Mac, so its tools will not start: \(notFound.joined(separator: "; ")).").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                Button("Details") { details = p }.controlSize(.small).pointer().uiFrame("settings.plugins.\(p.id).details")
            }
        }
        .pointer().uiFrame("settings.plugins.\(p.id).toggle")
        .id("\(p.id)-\(store.settingsVersion)")
    }

    /// "2 skills · 1 server"
    static func contents(_ p: Plugin) -> String {
        var parts: [String] = []
        if !p.skills.isEmpty { parts.append("\(p.skills.count) skill\(p.skills.count == 1 ? "" : "s")") }
        if !p.servers.isEmpty { parts.append("\(p.servers.count) server\(p.servers.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a plugin folder, a .zip of one, or a SKILL.md file."
        panel.prompt = "Review"
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            do { note = nil; staged = try store.stage(from: url) } catch { note = error.localizedDescription }
        }
    }

    private func commit(_ s: PluginStore.Staged) {
        // An update keeps the plugin as it was: one the person had switched off stays off.
        do { try store.commit(s, enable: s.replaces.map { store.isEnabled($0.id) } ?? true); note = nil } catch { note = "\(s.plugin.name) was not installed: \(error.localizedDescription)" }
    }

    // MARK: Hub

    private var hubSection: some View {
        Section {
            if let idx = hub.index {
                if idx.plugins.isEmpty { Text("This hub lists no plugins.").foregroundStyle(.secondary) }
                ForEach(idx.plugins) { l in hubRow(l) }
            } else if hub.loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the hub…").foregroundStyle(.secondary) }
            }
            if let p = hub.problem { Text(p).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        } header: {
            HStack {
                Text(hub.index?.name ?? "Hub")
                Spacer()
                if hub.loading, hub.index != nil { ProgressView().controlSize(.mini) }
                Button("Refresh") { Task { await hub.refresh() } }.controlSize(.small).pointer().disabled(hub.loading).uiFrame("settings.plugins.hub.refresh")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Plugins published for EditMax. Each file is checked against the hub's checksum, and you review a plugin before it is installed.")
                Button("Made a plugin? Add it to the hub with a pull request") { NSWorkspace.shared.open(PluginHub.contributeURL) }
                    .buttonStyle(.link).pointer().help(PluginHub.contributeURL.absoluteString).uiFrame("settings.plugins.hub.contribute")
            }
        }
    }

    @ViewBuilder private func hubRow(_ l: PluginHub.Listing) -> some View {
        let have = store.plugin(l.id)
        let update = have.map { PluginHub.isNewer(l.version, than: $0.version) } ?? false
        LabeledContent {
            if busy == l.id { ProgressView().controlSize(.small) }
            else if have != nil, !update { Text("Installed").foregroundStyle(.secondary) }
            else {
                Button(update ? "Update" : "Install") { install(l) }.controlSize(.small).pointer().disabled(busy != nil).uiFrame("settings.plugins.hub.\(l.id).install")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(l.name + "  \(l.version)")
                Text(l.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Text(Self.hubContents(l)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    static func hubContents(_ l: PluginHub.Listing) -> String {
        var parts: [String] = []
        if let a = l.author, !a.isEmpty { parts.append("by \(a)") }
        if let s = l.skills, !s.isEmpty { parts.append("\(s.count) skill\(s.count == 1 ? "" : "s")") }
        if let s = l.servers, !s.isEmpty { parts.append("\(s.count) server\(s.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func install(_ l: PluginHub.Listing) {
        busy = l.id; note = nil
        Task {
            defer { busy = nil }
            do {
                let folder = try await hub.download(l)
                defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
                staged = try store.stage(from: folder, source: "hub")
            } catch { note = error.localizedDescription }
        }
    }
}

/// What a plugin holds, as both sheets show it: each skill with what it is for, and each server with the command it
/// runs on this Mac or the address it calls, exactly as written (settings not filled in).
struct PluginContents: View {
    let plugin: Plugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !plugin.skills.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Skills").font(.headline)
                    ForEach(plugin.skills) { s in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                            if !s.description.isEmpty { Text(s.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
            }
            if !plugin.servers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tools (MCP servers)").font(.headline)
                    ForEach(plugin.servers) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name + (s.runsLocally ? "  ·  runs this command on your Mac" : "  ·  calls this address")).font(.system(size: 12, weight: .medium))
                            Text(s.summary).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
        }
    }
}

/// Shown before anything is installed: what the plugin adds and what turning it on allows.
struct PluginReviewSheet: View {
    let staged: PluginStore.Staged
    let done: (Bool) -> Void

    var body: some View {
        let p = staged.plugin
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text((staged.replaces == nil ? "Install " : "Update ") + p.name + "?").font(.title3.weight(.semibold))
                Text([p.version.isEmpty ? nil : "Version \(p.version)" + (staged.replaces.map { $0.version.isEmpty ? "" : ", replacing \($0.version)" } ?? ""),
                      p.author.isEmpty ? nil : "by \(p.author)", staged.source == "hub" ? "from the hub" : "from this Mac"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if !p.summary.isEmpty { Text(p.summary).font(.callout).fixedSize(horizontal: false, vertical: true) }
            }
            ScrollView { PluginContents(plugin: p).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 280)
            Text(warning(p)).font(.caption).foregroundStyle(p.servers.isEmpty ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(false) }.keyboardShortcut(.cancelAction).pointer().uiFrame("plugins.review.cancel")
                Button(staged.replaces == nil ? "Install and Turn On" : "Update") { done(true) }.keyboardShortcut(.defaultAction).pointer().uiFrame("plugins.review.install")
            }
        }
        .padding(20).frame(width: 500)
    }

    private func warning(_ p: Plugin) -> String {
        if p.servers.isEmpty { return "The agent reads these skills as instructions for its edits. Install plugins from people you trust." }
        let local = p.servers.contains { $0.runsLocally }
        return (local ? "This plugin runs a program on your Mac with your account's access. " : "This plugin sends requests to the address above. ")
            + "Once it is on, the agent uses its tools without asking each time, and what the agent reads from your project can be passed to them. Install it only if you trust who made it."
    }
}

/// One installed plugin: what it holds, the values it needs (kept in the login keychain), and Remove.
struct PluginDetailsSheet: View {
    let pluginID: String
    let done: () -> Void
    @ObservedObject private var store = PluginStore.shared
    @State private var drafts: [String: String] = [:]
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let p = store.plugin(pluginID) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name).font(.title3.weight(.semibold))
                    Text([p.version.isEmpty ? nil : "Version \(p.version)", p.author.isEmpty ? nil : "by \(p.author)",
                          store.entries[p.id]?.source == "hub" ? "from the hub" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    if !p.summary.isEmpty { Text(p.summary).font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        PluginContents(plugin: p)
                        if !p.settings.isEmpty { settings(p) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
                HStack {
                    Button("Remove…", role: .destructive) { confirmRemove = true }.pointer().uiFrame("plugins.details.remove")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.directory]) }.pointer().uiFrame("plugins.details.reveal")
                    if let h = p.homepage, let u = URL(string: h), u.scheme == "https" { Button("Website") { NSWorkspace.shared.open(u) }.pointer().help(h).uiFrame("plugins.details.website") }
                    Spacer()
                    Button("Done") { done() }.keyboardShortcut(.defaultAction).pointer().uiFrame("plugins.details.done")
                }
                .confirmationDialog("Remove \(p.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { store.remove(p.id); done() }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Its files and the settings saved for it are deleted. You can install it again later.") }
            } else {
                Text("This plugin is not installed any more.")
                Button("Done") { done() }.pointer()
            }
        }
        .padding(20).frame(width: 500)
    }

    @ViewBuilder private func settings(_ p: Plugin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.headline)
            ForEach(p.settings) { s in
                let saved = store.value(s.key, of: p.id) != nil
                let fromEnvironment = !saved && !(store.environment[s.key] ?? "").isEmpty
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(s.label).font(.system(size: 12, weight: .medium))
                        if !s.required { Text("optional").font(.caption).foregroundStyle(.tertiary) }
                    }
                    HStack(spacing: 6) {
                        let prompt = Text(saved ? "Saved ••••••" : fromEnvironment ? "From this Mac's \(s.key)" : s.key)
                        Group {
                            if s.secret { SecureField(s.label, text: draft(s.key), prompt: prompt) } else { TextField(s.label, text: draft(s.key), prompt: prompt) }
                        }
                        .labelsHidden().textFieldStyle(.roundedBorder).uiFrame("plugins.details.\(s.key).field")
                        Button("Save") { store.setValue(drafts[s.key] ?? "", for: s.key, of: p.id); drafts[s.key] = "" }
                            .controlSize(.small).pointer().disabled((drafts[s.key] ?? "").isEmpty).uiFrame("plugins.details.\(s.key).save")
                        if saved { Button("Remove") { store.setValue("", for: s.key, of: p.id) }.controlSize(.small).pointer().uiFrame("plugins.details.\(s.key).remove") }
                    }
                    if let h = s.help, !h.isEmpty { Text(h).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Text("Kept in your login keychain and given only to this plugin's own server, never to a log.").font(.caption).foregroundStyle(.secondary)
        }
        .id(store.settingsVersion)
    }

    private func draft(_ key: String) -> Binding<String> { Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 }) }
}
