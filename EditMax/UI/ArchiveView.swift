import SwiftUI
import AppKit

/// The Archive window (Window ▸ Archive, or Settings ▸ General ▸ Show Archive): every file deleted in EditMax, with
/// Restore to put it back where it was and use it again, until it is erased for good.
@MainActor
final class ArchiveWindow {
    static let shared = ArchiveWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Archive"
            w.contentMinSize = NSSize(width: 440, height: 300)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ArchiveView())
            w.center()
            w.setFrameAutosaveName("EditMaxArchive")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ArchiveView: View {
    @ObservedObject private var archive = AppArchive.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var erasing: AppArchive.Entry?
    @State private var confirmEmpty = false
    @State private var notice: String?
    @State private var problem: String?

    private var shown: [AppArchive.Entry] { archive.entries.sorted { $0.archivedAt > $1.archivedAt } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "archivebox").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text("Nothing in the Archive").font(.headline)
                    Text("Files you delete in EditMax (Assets items, projects, fonts, templates) wait here so you can put them back.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) { ForEach(shown) { row($0) } }.padding(8)
                }
            }
            if let line = problem ?? notice {
                Divider()
                Text(line).font(.callout).foregroundStyle(problem == nil ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .frame(minWidth: 440, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Erase “\(erasing?.name ?? "")” for good?", isPresented: Binding(get: { erasing != nil }, set: { if !$0 { erasing = nil } }), titleVisibility: .visible) {
            Button("Erase", role: .destructive) { if let e = erasing { archive.erase(e.id); say("Erased \(e.name)") }; erasing = nil }
            Button("Cancel", role: .cancel) { erasing = nil }
        } message: { Text("This can't be undone.") }
        .confirmationDialog("Erase everything in the Archive?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Erase \(archive.entries.count) Item\(archive.entries.count == 1 ? "" : "s")", role: .destructive) { let n = archive.emptyNow(); say("Erased \(n) item\(n == 1 ? "" : "s")") }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can't be undone.") }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(archive.entries.isEmpty ? "Empty" : "\(archive.entries.count) item\(archive.entries.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: archive.totalBytes, countStyle: .file))")
                    .font(.headline).monospacedDigit()
                Text("Erased for good after \(archive.periodText). Change this in Settings ▸ General.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Show in Finder") { archive.revealInFinder() }.controlSize(.small).pointer().uiFrame("archive.reveal")
            Button("Empty Archive…") { confirmEmpty = true }.controlSize(.small).disabled(archive.entries.isEmpty).pointer().uiFrame("archive.empty")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func row(_ e: AppArchive.Entry) -> some View {
        let kind = e.kind ?? .file
        let left = archive.daysLeft(e)
        return HStack(spacing: 10) {
            Image(systemName: kind.symbol).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("\(kind.label) · deleted \(e.archivedAt.formatted(.relative(presentation: .named))) · \(ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(left == 0 ? "Erased soon" : "\(left) day\(left == 1 ? "" : "s") left").font(.caption).foregroundStyle(left <= 3 ? Color.orange : Color.secondary).monospacedDigit()
            Button("Restore") { restore(e) }
                .controlSize(.small).help("Put it back where it was (\(Self.place(of: e)))").pointer().uiFrame("archive.\(e.id.short).restore")
            Button { erasing = e } label: { Image(systemName: "trash").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Erase for good now").pointer().uiFrame("archive.\(e.id.short).erase")
        }
        .padding(.horizontal, 8).frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") { restore(e) }
            Button("Erase Now…", systemImage: "trash", role: .destructive) { erasing = e }
        }
        .uiFrame("archive.\(e.id.short)")
    }

    private func restore(_ e: AppArchive.Entry) {
        do { _ = try archive.restore(e.id); say("Restored \(e.name) to \(Self.place(of: e))") }
        catch { problem = error.localizedDescription; notice = nil }
    }

    private func say(_ line: String) { notice = line; problem = nil }

    static func place(of e: AppArchive.Entry) -> String {
        switch e.kind ?? .file {
        case .asset: "Assets"
        case .project: "Home"
        case .font: "your fonts"
        case .template: "templates"
        case .file: URL(fileURLWithPath: e.original).deletingLastPathComponent().lastPathComponent
        }
    }
}
