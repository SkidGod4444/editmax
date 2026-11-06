import SwiftUI
import AppKit

extension Notification.Name {
    static let editmaxRelinkMedia = Notification.Name("editmaxRelinkMedia")             // object: document id (nil = active)
    static let editmaxConsolidateMedia = Notification.Name("editmaxConsolidateMedia")   // object: document id (nil = active)
}

/// Preview renders (tests) draw these views with ImageRenderer, which cannot draw the AppKit frame probes behind
/// `.uiFrame`; the editing views register through this switch instead.
enum EditingPreview { nonisolated(unsafe) static var rendering = false }
extension View {
    /// `.uiFrame(id)`, except while a preview test renders the view.
    @ViewBuilder func editFrame(_ id: String) -> some View {
        if EditingPreview.rendering { self } else { uiFrame(id) }
    }
}

/// A bordered push button drawn by SwiftUI (so sheets render the same in previews); `prominent` = the default action.
struct EditingButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(prominent ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(prominent ? 0 : 0.12)))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

/// The sheet for missing media: shown when a project opens with files that are not at their paths, and from the media
/// panel. Finds what it can through the bookmarks right away, searches a folder on request, takes a file per row, and
/// relinks everything found in one undoable edit.
struct RelinkSheet: View {
    @ObservedObject var document: EditMaxDocument
    var onClose: () -> Void
    struct Row: Identifiable, Equatable { var id: UUID; var name: String; var path: String; var found: String?; var reason: String?; var why: String? }
    @State var rows: [Row] = []
    @State var busy = false
    @State var message: String?
    private var x: ToolExecutor { ToolExecutor(document: document, origin: .user) }
    private var foundCount: Int { rows.filter { $0.found != nil }.count }

    static func rows(for p: Project) -> [Row] { Relink.missing(p).map { Row(id: $0.id, name: $0.name, path: $0.path) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(rows.isEmpty ? "No media is missing" : "\(rows.count) media file\(rows.count == 1 ? " is" : "s are") missing").font(.system(size: 15, weight: .semibold))
                    Text("Their clips play black and silent until EditMax finds the files again. Choose a folder to search, or a file for each one. Files are only read, never moved.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            list
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Button("Search Folder…") { searchFolder() }.buttonStyle(EditingButtonStyle()).focusable(false).pointer().disabled(busy || rows.isEmpty).editFrame("relink.searchFolder")
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Not Now") { onClose() }.buttonStyle(EditingButtonStyle()).focusable(false).pointer().editFrame("relink.cancel")
                    .keyboardShortcut(.cancelAction)
                Button(foundCount == 0 ? "Relink" : "Relink \(foundCount) File\(foundCount == 1 ? "" : "s")") { apply() }
                    .buttonStyle(EditingButtonStyle(prominent: true)).focusable(false).pointer().disabled(busy || foundCount == 0).editFrame("relink.apply")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            if rows.isEmpty { rows = Self.rows(for: document.project) }
            if !EditingPreview.rendering { run { try await x.relinkMedia(asset: nil, path: nil, folder: nil, recursive: true, dryRun: true) } }
        }
    }

    @ViewBuilder private var list: some View {
        let content = VStack(spacing: 0) {
            ForEach(rows) { row in
                rowView(row)
                if row.id != rows.last?.id { Divider().padding(.leading, 44) }
            }
        }
        Group {
            if rows.count > 6 { ScrollView { content }.frame(height: 330) } else { content }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.found != nil ? "checkmark.circle.fill" : "questionmark.folder")
                .font(.system(size: 16)).foregroundStyle(row.found != nil ? Color.green : Color.orange).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(row.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let f = row.found {
                    Text("Found: \(f)").font(.system(size: 11)).foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                    if let why = row.why { Text(why).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                } else if let r = row.reason {
                    Text(r).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Locate…") { locate(row) }.buttonStyle(EditingButtonStyle()).focusable(false).pointer().disabled(busy).editFrame("relink.row.\(row.id.short).locate")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    /// Runs a dry-run lookup and folds its findings into the rows.
    private func run(_ body: @escaping () async throws -> ToolExecutor.RelinkResult) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let r = try await body()
                for d in r.relinked { if let i = rows.firstIndex(where: { $0.id.short == d.asset }) { rows[i].found = d.to; rows[i].why = d.reason; rows[i].reason = nil } }
                for m in r.stillMissing { if let i = rows.firstIndex(where: { $0.id.short == m.asset }), rows[i].found == nil { rows[i].reason = m.reason } }
                message = r.message.replacingOccurrences(of: "Would relink", with: "Found")
            } catch { message = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }

    private func searchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to search for the missing files (subfolders included)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try await x.relinkMedia(asset: nil, path: nil, folder: url.path, recursive: true, dryRun: true) }
    }

    private func locate(_ row: Row) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the file for \(row.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try await x.relinkMedia(asset: row.id.uuidString, path: url.path, folder: nil, recursive: false, dryRun: true) }
    }

    private func apply() {
        let choices = Dictionary(uniqueKeysWithValues: rows.compactMap { r in r.found.map { (r.id, URL(fileURLWithPath: $0)) } })
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let r = try await x.relinkFiles(choices)
                rows = Self.rows(for: document.project)
                message = r.message
                if rows.isEmpty { onClose() }
            } catch { message = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }
}

/// Media panel pieces: a MISSING badge on a row, and a warning button in the header while any file is missing.
struct MissingBadge: View {
    let asset: Asset
    var body: some View {
        if Relink.isMissing(asset) {
            Text("MISSING").font(.system(size: 8, weight: .bold)).foregroundStyle(.red).padding(.horizontal, 4).frame(height: 13)
                .background(Color.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .help("Not at \(asset.path). Relink it from the warning button above the list or this row's menu.")
        }
    }
}

struct MediaPanelRelinkButton: View {
    @ObservedObject var document: EditMaxDocument
    var body: some View {
        let n = Relink.missing(document.project).count
        if n > 0 {
            Button { NotificationCenter.default.post(name: .editmaxRelinkMedia, object: document.id) } label: {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                    .frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).focusable(false).help("\(n) file\(n == 1 ? " is" : "s are") missing: relink").pointer().uiFrame("media.relink")
        }
    }
}

/// The media row's context-menu items for editing: relink this file, open it in the source viewer.
struct EditingMediaMenu: View {
    @ObservedObject var document: EditMaxDocument
    let asset: Asset
    var body: some View {
        if asset.sequenceID == nil {
            Button(Relink.isMissing(asset) ? "Relink…" : "Relink to Another File…", systemImage: "link") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                panel.message = "Choose the file for \(asset.name)"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let x = ToolExecutor(document: document, origin: .user)
                Task { @MainActor in
                    do { _ = try await x.relinkMedia(asset: asset.id.uuidString, path: url.path, folder: nil, recursive: false, dryRun: false) }
                    catch { NSAlert(error: error).runModal() }
                }
            }
        }
        if asset.kind != .audio, !Relink.isMissing(asset) {
            Button("Open in Source Viewer", systemImage: "rectangle.on.rectangle") {
                NotificationCenter.default.post(name: .editmaxOpenSource, object: document.id, userInfo: ["asset": asset.id])
            }
        }
    }
}

/// File ▸ Relink Media… / Consolidate Media… and View ▸ Source Viewer for the focused project.
struct EditingCommands: Commands {
    @FocusedObject private var document: EditMaxDocument?
    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Relink Media…") { NotificationCenter.default.post(name: .editmaxRelinkMedia, object: document?.id) }.disabled(document == nil)
            Button("Consolidate Media…") { NotificationCenter.default.post(name: .editmaxConsolidateMedia, object: document?.id) }.disabled(document == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Source Viewer") { NotificationCenter.default.post(name: .editmaxToggleSource, object: document?.id) }
                .keyboardShortcut("s", modifiers: [.command, .option]).disabled(document == nil)
        }
    }
}

extension Notification.Name {
    static let editmaxOpenSource = Notification.Name("editmaxOpenSource")       // object: document id; userInfo["asset"]: UUID
    static let editmaxToggleSource = Notification.Name("editmaxToggleSource")   // object: document id (nil = active)
}

/// The editor window's editing sheets: the relink sheet (on open when files are missing, and on request) and the
/// consolidate flow. Attached to EditorRootView with one modifier so the shared file stays untouched otherwise.
struct EditingSheets: ViewModifier {
    @ObservedObject var document: EditMaxDocument
    @State private var relinkShown = false
    @State private var checked = false

    private func mine(_ n: Notification) -> Bool {
        if let id = n.object as? UUID { return id == document.id }
        return DocumentRegistry.shared.activeID == document.id
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $relinkShown) { RelinkSheet(document: document) { relinkShown = false } }
            .onAppear {
                guard !checked else { return }
                checked = true
                // Missing media on open: ask once per window. Never under the unit tests (the host has no user).
                if !AppDelegate.isTesting, !Relink.missing(document.project).isEmpty {
                    DebugLog.event("relink-missing-on-open", ["count": Relink.missing(document.project).count])
                    relinkShown = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .editmaxRelinkMedia)) { n in
                guard mine(n) else { return }
                if Relink.missing(document.project).isEmpty {
                    let a = NSAlert(); a.messageText = "No media is missing"; a.informativeText = "Every file the project uses is at its path."; a.runModal()
                } else { relinkShown = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .editmaxConsolidateMedia)) { n in
                guard mine(n) else { return }
                consolidate()
            }
    }

    private func consolidate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose the folder to copy every file the timeline uses into. The originals are not moved."
        if let f = document.fileURL { panel.directoryURL = f.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let x = ToolExecutor(document: document, origin: .user)
        Task { @MainActor in
            do {
                let plan = try await x.consolidateMedia(folder: url.path, dryRun: true)
                let ask = NSAlert()
                ask.messageText = "Copy \(plan.copied) file\(plan.copied == 1 ? "" : "s") (\(plan.size))?"
                ask.informativeText = "Into \(plan.folder)." + (plan.reused > 0 ? " \(plan.reused) already there will be reused." : "") + (plan.missing.map { " \($0.count) missing file(s) are skipped." } ?? "") + " The project then points at the copies (undo puts it back)."
                ask.addButton(withTitle: "Copy"); ask.addButton(withTitle: "Cancel")
                guard ask.runModal() == .alertFirstButtonReturn else { return }
                let r = try await x.consolidateMedia(folder: url.path, dryRun: false)
                let done = NSAlert(); done.messageText = "Copied \(r.copied) file\(r.copied == 1 ? "" : "s") (\(r.size))"; done.informativeText = r.folder; done.runModal()
            } catch { NSAlert(error: error).runModal() }
        }
    }
}
