import SwiftUI
import AppKit

/// Home ▸ Archive: every file deleted in EditMax (EditMax's copies of Assets items, projects, fonts, templates), with
/// Restore to put it back where it was and use it again, until it is erased for good. Laid out like Home's Projects and
/// Assets pages: a title with its count, actions on the right, a kind filter, then the items. Window ▸ Archive and
/// Settings ▸ General ▸ Show Archive open Home here.
struct ArchivePane: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var archive = AppArchive.shared
    @State private var erasing: AppArchive.Entry?
    @State private var confirmEmpty = false
    @State private var erasingPicked = false
    @State private var message: String?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", media = "Media", projects = "Projects", fonts = "Fonts", templates = "Templates"
        var id: String { rawValue }
        func matches(_ e: AppArchive.Entry) -> Bool {
            switch self {
            case .all: true
            case .media: [.asset, .export, .file].contains(e.kind ?? .file)
            case .projects: e.kind == .project
            case .fonts: e.kind == .font
            case .templates: e.kind == .template
            }
        }
    }

    private var shown: [AppArchive.Entry] {
        archive.entries.filter(model.archiveFilter.matches).sorted { $0.archivedAt > $1.archivedAt }
    }
    /// The picked items on the page now (a kind change can hide some; only what is shown is acted on).
    private var picked: [AppArchive.Entry] { shown.filter { model.pickedArchive.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Archive").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("\(shown.count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
                if model.selectingArchive {
                    HomeSelectionBar(id: "archive", picked: picked.count, total: shown.count,
                                     setAll: { model.pickedArchive = $0 ? Set(shown.map(\.id)) : [] },
                                     done: { model.selectingArchive = false }) {
                        Button { restorePicked() } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                            .disabled(picked.isEmpty).help("Put the selected items back where they were")
                            .pointer().uiFrame("archive.restorePicked").uiTap("archive.restorePicked") { if !picked.isEmpty { restorePicked() } }
                        Button(role: .destructive) { erasingPicked = true } label: { Label("Erase…", systemImage: "trash") }
                            .disabled(picked.isEmpty).help("Erase the selected items for good")
                            .pointer().uiFrame("archive.erasePicked").uiTap("archive.erasePicked") { if !picked.isEmpty { erasingPicked = true } }
                    }
                } else {
                    HomeSelectButton(id: "archive", selecting: $model.selectingArchive, disabled: shown.isEmpty)
                    Button { archive.revealInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
                        .pointer().uiFrame("archive.reveal").uiTap("archive.reveal") { archive.revealInFinder() }
                    Button { confirmEmpty = true } label: { Label("Empty Archive…", systemImage: "trash") }
                        .disabled(archive.entries.isEmpty)
                        .pointer().uiFrame("archive.empty").uiTap("archive.empty") { if !archive.entries.isEmpty { confirmEmpty = true } }
                }
            }
            .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 10)
            HStack {
                Picker("Kind", selection: $model.archiveFilter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .pointer().uiFrame("archive.kind")
                .background { ForEach(Filter.allCases) { f in Color.clear.uiTap("archive.kind.\(f.rawValue.lowercased())") { model.archiveFilter = f } } }
                Spacer()
                HStack(spacing: 4) {
                    Text("Erased for good after \(archive.periodText).").foregroundStyle(.secondary)
                    SettingsLink { Text("Change…") }.buttonStyle(.link).pointer().uiFrame("archive.period")
                }
                .font(.caption)
            }
            .padding(.horizontal, 26).padding(.bottom, 14)
            if shown.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "archivebox").font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text(archive.entries.isEmpty ? "Nothing in the Archive" : "No \(model.archiveFilter.rawValue.lowercased()) in the Archive").font(.headline)
                    if archive.entries.isEmpty {
                        Text("Files you delete in EditMax (media, projects, fonts, templates, exports you replace)\nwait here for \(archive.periodText), so you can restore them.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 30)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { e in
                            ArchiveRow(entry: e, selecting: model.selectingArchive, selected: model.pickedArchive.contains(e.id),
                                       onToggle: { model.pickedArchive.formSymmetricDifference([e.id]) },
                                       onRestore: { restore(e) }, onErase: { erasing = e })
                        }
                    }
                    .padding(.horizontal, 26).padding(.bottom, 26)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let m = message {
                Text(m).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 8)
                    .liquidGlass().padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: message)
        .animation(.snappy, value: archive.entries)
        .confirmationDialog("Erase “\(erasing?.name ?? "")” for good?", isPresented: Binding(get: { erasing != nil }, set: { if !$0 { erasing = nil } }), titleVisibility: .visible) {
            Button("Erase", role: .destructive) { if let e = erasing { archive.erase(e.id); say("Erased \(e.name)") }; erasing = nil }
            Button("Cancel", role: .cancel) { erasing = nil }
        } message: { Text("This can't be undone.") }
        .confirmationDialog("Erase \(picked.count) Item\(picked.count == 1 ? "" : "s") for good?", isPresented: $erasingPicked, titleVisibility: .visible) {
            Button("Erase \(picked.count) Item\(picked.count == 1 ? "" : "s")", role: .destructive) {
                let n = archive.erase(Set(picked.map(\.id)))
                model.selectingArchive = false
                say("Erased \(n) item\(n == 1 ? "" : "s")")
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can't be undone.") }
        .confirmationDialog("Erase everything in the Archive?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Erase \(archive.entries.count) Item\(archive.entries.count == 1 ? "" : "s")", role: .destructive) { let n = archive.emptyNow(); say("Erased \(n) item\(n == 1 ? "" : "s")") }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can't be undone.") }
    }

    private func restorePicked() {
        let r = archive.restore(picked.map(\.id))
        model.selectingArchive = false
        let done = "Restored \(r.restored) item\(r.restored == 1 ? "" : "s")"
        say(r.failures.isEmpty ? done : "\(done) · \(r.failures.count) could not be: \(r.failures[0])")
    }

    private func restore(_ e: AppArchive.Entry) {
        do { _ = try archive.restore(e.id); say("Restored \(e.name) to \(Self.place(of: e))") }
        catch { say(error.localizedDescription) }
    }

    /// A line at the foot of the page for a few seconds, as on the Assets page.
    private func say(_ line: String) {
        message = line
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if message == line { message = nil }
        }
    }

    static func place(of e: AppArchive.Entry) -> String {
        switch e.kind ?? .file {
        case .asset: "Assets"
        case .project: "Projects"
        case .font: "your fonts"
        case .template: "templates"
        case .export, .file: URL(fileURLWithPath: e.original).deletingLastPathComponent().lastPathComponent
        }
    }
}

/// One archived file: what it is, when it was deleted, the days left, and Restore. Hover lights it as Home's cards do.
private struct ArchiveRow: View {
    let entry: AppArchive.Entry
    /// Select mode: a click picks the row (a check at its start) instead of Restore and Erase.
    var selecting = false
    var selected = false
    var onToggle: () -> Void = {}
    let onRestore: () -> Void
    let onErase: () -> Void
    @ObservedObject private var archive = AppArchive.shared
    @State private var hover = false

    var body: some View {
        let kind = entry.kind ?? .file
        let left = archive.daysLeft(entry)
        let offline = archive.isOffline(entry)
        let drive = AppArchive.driveName(of: entry).map { " · on \($0)" } ?? ""
        HStack(spacing: 12) {
            if selecting { HomeSelectCheck(selected: selected).uiFrame("archive.\(entry.id.short).check") }
            Image(systemName: kind.symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("\(kind.label) · Deleted \(entry.archivedAt.formatted(.relative(presentation: .named))) · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))\(drive)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(offline ? "Drive not connected" : left == 0 ? "Erased soon" : "\(left) day\(left == 1 ? "" : "s") left")
                .font(.caption.monospacedDigit()).foregroundStyle(!offline && left <= 3 ? Color.orange : Color.secondary)
            if !selecting {
                Button { onRestore() } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .controlSize(.small)   // the page's own button style (Show in Finder, Empty Archive)
                    .disabled(offline)
                    .help(offline ? "Connect the drive to restore it" : "Put it back in \(ArchivePane.place(of: entry)), where it was")
                    .pointer().uiFrame("archive.\(entry.id.short).restore").uiTap("archive.\(entry.id.short).restore") { if !offline { onRestore() } }
                Button { onErase() } label: { Image(systemName: "trash").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Erase for good now")
                    .pointer().uiFrame("archive.\(entry.id.short).erase").uiTap("archive.\(entry.id.short).erase") { onErase() }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minHeight: 56)   // the same height with or without the row's buttons
        .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hover ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : hover ? Color.accentColor.opacity(0.9) : Color.clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { if selecting { onToggle() } }
        .onHover { hover = $0 }
        .animation(.snappy(duration: 0.18), value: hover)
        .animation(.snappy(duration: 0.15), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(selecting ? (selected ? "Click to deselect" : "Click to select") : "")
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") { onRestore() }
            Button("Erase Now…", systemImage: "trash", role: .destructive) { onErase() }
        }
        .uiFrame("archive.\(entry.id.short)")
        .uiTap("archive.\(entry.id.short)") { if selecting { onToggle() } }
    }
}
