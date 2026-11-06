import SwiftUI
import AppKit
import Combine

/// The Home window: the user's projects (drafts and saved ones) and a way to start a new one. Shown at launch when no
/// project is open and again when the last editor window closes; hidden as soon as a project opens. Window → Home (⇧⌘H).
@MainActor
final class HomeWindow {
    static let shared = HomeWindow()
    private var window: NSWindow?
    private var bag: Set<AnyCancellable> = []
    private var hadDocuments = false

    private init() {
        DocumentRegistry.shared.$documents
            .dropFirst()   // the replayed current value would hide a Home that was just summoned over an editor
            .receive(on: RunLoop.main)
            .sink { [weak self] docs in
                guard let self else { return }
                if !docs.isEmpty { hadDocuments = true; hide() }
                else if hadDocuments { hadDocuments = false; show() }
            }
            .store(in: &bag)
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "EditMax"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            w.setFrameAutosaveName("EditMaxHome")
            if w.frame.origin == .zero { w.center() }
            window = w
        }
        // A fresh view each time: ordering a window out does not fire onDisappear, so a kept view would leave Home's
        // ids registered with the UI driver while the editor is up.
        window?.contentView = NSHostingView(rootView: HomeView())
        ProjectLibrary.shared.refresh()
        window?.makeKeyAndOrderFront(nil)   // orders within EditMax's own layer; never activates the app
        DebugLog.event("home-show", ["windowNumber": window?.windowNumber ?? -1])
    }

    func hide() { window?.orderOut(nil); window?.contentView = nil }
}

struct HomeView: View {
    @ObservedObject private var library = ProjectLibrary.shared
    @State private var search = ""
    @State private var template: Templates.Info = Templates.list().first!
    @State private var trashing: ProjectLibrary.Entry?
    @State private var problem: String?

    private var filtered: [ProjectLibrary.Entry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? library.entries : library.entries.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            projects
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Move “\(trashing?.name ?? "")” to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { if let e = trashing { do { try library.trash(e) } catch { problem = error.localizedDescription } }; trashing = nil }
            Button("Cancel", role: .cancel) { trashing = nil }
        } message: { Text("The project file is moved to the Trash; its media stays where it is.") }
        .alert("EditMax", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") { problem = nil } } message: { Text(problem ?? "") }
        .onAppear { library.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 1) {
                    Text("EditMax").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Agentic video editor").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 36)

            VStack(alignment: .leading, spacing: 8) {
                Text("NEW PROJECT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(1.2)
                let chips = Templates.list().filter(\.builtin)
                FlowLayout(spacing: 6) {
                    ForEach(chips) { t in
                        let on = t.name == template.name
                        Button(shortName(t)) { template = t }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .liquidGlass(tint: on ? Color.glassSelection : nil, interactive: true)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .pointer()
                            .help("\(t.name): \(t.width)×\(t.height) at \(Int(t.fps)) fps")
                            .uiFrame("home.template.\(slug(t))").uiTap("home.template.\(slug(t))") { template = t }
                    }
                }
                Text("\(template.width)×\(template.height) · \(Int(template.fps)) fps").font(.caption).foregroundStyle(.secondary)
                Button { newProject() } label: {
                    Label("New project", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .controlSize(.large).glassButtonStyle(prominent: true).tint(.accentColor).keyboardShortcut("n", modifiers: [.command, .shift]).focusEffectDisabled()
                .pointer().uiFrame("home.new").uiTap("home.new") { newProject() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Button { openPanel() } label: { Label("Open…", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).focusable(false).pointer().uiFrame("home.open").uiTap("home.open") { openPanel() }
                Button { NSWorkspace.shared.activateFileViewerSelecting([ProjectLibrary.directory]) } label: { Label("Show library in Finder", systemImage: "arrow.up.forward.square").frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).focusable(false).pointer().uiFrame("home.finder")
            }
            .font(.system(size: 13))

            Spacer()
            Text("Projects live in Movies ▸ EditMax Projects. A draft is a project you have not named yet.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .background(.regularMaterial)
    }

    private var projects: some View {
        VStack(spacing: 0) {
            HStack {
                Text(search.isEmpty ? "Projects" : "Results").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("\(filtered.count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220).uiFrame("home.search")
            }
            .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 12)
            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text(library.entries.isEmpty ? "No projects yet" : "Nothing matches “\(search)”").font(.headline)
                    if library.entries.isEmpty { Text("Pick a format on the left and create your first project.").font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 18)], spacing: 18) {
                        ForEach(filtered) { e in ProjectCard(entry: e, thumbnail: library.thumbnails[e.id], onOpen: { library.open(e.url) }, onTrash: { trashing = e }) }
                    }
                    .padding(.horizontal, 26).padding(.bottom, 26)
                }
            }
        }
    }

    private func newProject() {
        do { library.open(try library.create(template: template)) } catch { problem = error.localizedDescription }
    }

    private func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.editmaxProject]
        p.directoryURL = ProjectLibrary.directory
        p.begin { if $0 == .OK, let u = p.url { library.open(u) } }
    }

    private func shortName(_ t: Templates.Info) -> String {
        switch t.name {
        case "YouTube 16:9 1080p": return "16:9"
        case "Shorts / Reels 9:16": return "9:16"
        case "Square 1:1": return "1:1"
        case "4K 16:9": return "4K"
        case "Cinema 2.39:1 24 fps": return "2.39:1"
        case "Vertical 4:5 (feed)": return "4:5"
        default: return t.name
        }
    }
    private func slug(_ t: Templates.Info) -> String { shortName(t).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "_").lowercased() }
}

private struct ProjectCard: View {
    let entry: ProjectLibrary.Entry
    let thumbnail: CGImage?
    let onOpen: () -> Void
    let onTrash: () -> Void
    @State private var hover = false

    private var aspect: CGFloat { CGFloat(max(1, entry.width)) / CGFloat(max(1, entry.height)) }
    private var id: String { "home.project.\(entry.stem)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.85))
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                } else {
                    // The project's frame shape, empty.
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                        .aspectRatio(aspect, contentMode: .fit).padding(aspect > 1.2 ? 22 : 14)
                        .overlay(Image(systemName: entry.clips == 0 ? "plus.rectangle.on.rectangle" : "film").foregroundStyle(.white.opacity(0.35)))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topLeading) {
                if entry.isDraft { Text("DRAFT").font(.system(size: 9, weight: .bold)).tracking(0.6).padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.orange).padding(8) }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(entry.clips == 0 ? "Empty" : time(entry.duration)).font(.caption2.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(8)
            }
            .overlay(alignment: .topTrailing) {
                if hover {
                    Button { onTrash() } label: { Image(systemName: "trash").padding(6).background(.black.opacity(0.6), in: Circle()).foregroundStyle(.white) }
                        .buttonStyle(.plain).focusable(false).help("Move to Trash").pointer().uiFrame("\(id).trash").padding(6)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.08), lineWidth: hover ? 1.5 : 1))
            .shadow(color: .black.opacity(hover ? 0.35 : 0.18), radius: hover ? 14 : 6, y: hover ? 8 : 3)
            .scaleEffect(hover ? 1.015 : 1)
            .animation(.snappy(duration: 0.18), value: hover)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(relative(entry.modified)) · \(entry.width)×\(entry.height)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .pointer()
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Divider()
            Button("Move to Trash", role: .destructive) { onTrash() }
        }
        .uiFrame(id).uiTap(id) { onOpen() }
        .help("Double-click to open")
    }

    private func time(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return Date().timeIntervalSince(d) < 60 ? "just now" : f.localizedString(for: d, relativeTo: Date())
    }
}
