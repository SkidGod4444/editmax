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
    /// True while a launch that opens a project waits for its window (`waitForLaunchProject`).
    private(set) var waitingForLaunchProject = false

    private init() {
        DocumentRegistry.shared.$documents
            .dropFirst()   // the replayed current value would hide a Home that was just summoned over an editor
            .receive(on: RunLoop.main)
            .sink { [weak self] docs in
                guard let self else { return }
                if !docs.isEmpty { hadDocuments = true; hide() }
                else if hadDocuments { hadDocuments = false; if !waitingForLaunchProject { show() } }
            }
            .store(in: &bag)
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "EditMax"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // See-through: the sidebar is glass over the desktop and the content a frosted pane (BehindWindowMaterial).
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            w.setFrameAutosaveName("EditMaxHome")
            if w.frame.origin == .zero { w.center() }
            window = w
        }
        // A fresh view each time: ordering a window out does not fire onDisappear, so a kept view would leave Home's
        // ids registered with the UI driver while the editor is up.
        if let w = window {
            let frame = savedFrame ?? w.frame   // hide() empties the window, which can collapse its frame; keep the real one
            let model = HomeModel()
            let split = NSSplitViewController()
            let sideVC = NSHostingController(rootView: HomeView(part: .sidebar, model: model))
            let mainVC = NSHostingController(rootView: HomeView(part: .projects, model: model))
            sideVC.sizingOptions = []; mainVC.sizingOptions = []   // the window keeps its own frame; SwiftUI does not size it
            let side = NSSplitViewItem(sidebarWithViewController: sideVC)
            side.minimumThickness = 250; side.maximumThickness = 250; side.canCollapse = false
            side.titlebarSeparatorStyle = .none
            let main = NSSplitViewItem(viewController: mainVC)
            main.titlebarSeparatorStyle = .none
            split.addSplitViewItem(side); split.addSplitViewItem(main)
            split.view.frame = NSRect(origin: .zero, size: frame.size)
            w.contentViewController = split
            w.setFrame(frame, display: false)
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }) { w.center() }   // never off every screen
        }
        ProjectLibrary.shared.refresh()
        window?.makeKeyAndOrderFront(nil)   // orders within EditMax's own layer; never activates the app
        DebugLog.event("home-show", ["windowNumber": window?.windowNumber ?? -1])
    }

    var isVisible: Bool { window?.isVisible ?? false }
    private var savedFrame: NSRect?

    func hide() {
        guard let w = window, w.isVisible else { return }
        savedFrame = w.frame
        w.orderOut(nil); w.contentViewController = nil
        DebugLog.event("home-hide")
    }

    // MARK: launch

    /// What Home does when the app finishes launching.
    enum LaunchPlan: Equatable {
        /// A plain launch (Dock, Launchpad, Spotlight): Home is the launch screen, up at once.
        case showNow
        /// A launch that opens a project (double-clicked in the Finder, a path on the command line) or restores the
        /// windows that were open at quit. The project window arrives a moment after launch; Home put up first flashed
        /// up and away, so it waits for the project instead.
        case waitForProject
        /// A project is already open.
        case nothing
    }

    /// `isDefaultLaunch` is AppKit's `launchIsDefaultUserInfoKey`: false when the app was launched to open a file or
    /// to restore saved windows.
    nonisolated static func launchPlan(isDefaultLaunch: Bool, projectOpen: Bool, projectInArguments: Bool) -> LaunchPlan {
        if projectOpen { return .nothing }
        return isDefaultLaunch && !projectInArguments ? .showNow : .waitForProject
    }

    /// A project counts once it has a file or edits: the empty untitled document DocumentGroup opens on its own is
    /// closed 0.3 s after launch.
    static var projectOpen: Bool {
        NSDocumentController.shared.documents.contains { $0.fileURL != nil || $0.isDocumentEdited }
    }

    /// For `.waitForProject`: Home comes up only if no project has opened after `seconds` (a file that fails to open, a
    /// restore with nothing in it), and never over the splash. While it waits, the automatic "no project, so Home"
    /// paths stand aside. Returns true when it put Home up.
    @discardableResult
    func waitForLaunchProject(seconds: Double = 2, poll: Double = 0.05,
                              projectOpen: (() -> Bool)? = nil,
                              show: (() -> Void)? = nil) async -> Bool {
        waitingForLaunchProject = true
        defer { waitingForLaunchProject = false }
        let end = Date().addingTimeInterval(seconds)
        while !(projectOpen?() ?? HomeWindow.projectOpen) {
            if Date() >= end {
                DebugLog.event("home-launch-wait", ["project": false])
                if let show { show() } else {
                    SplashScreen.shared.afterDismiss { if !HomeWindow.projectOpen, !HomeWindow.shared.isVisible { HomeWindow.shared.show() } }
                }
                return true
            }
            try? await Task.sleep(for: .seconds(poll))
        }
        DebugLog.event("home-launch-wait", ["project": true])
        return false
    }
}

struct HomeView: View {
    /// Home is an NSSplitViewController (the sidebar item gets AppKit's official sidebar treatment: Liquid Glass on
    /// macOS 26, the translucent sidebar material before), so the sidebar and the projects pane are two hosting
    /// controllers over one model.
    enum Part { case sidebar, projects }
    let part: Part
    @ObservedObject var model: HomeModel
    @ObservedObject private var library = ProjectLibrary.shared
    @ObservedObject private var assets = AssetLibrary.shared

    private var filtered: [ProjectLibrary.Entry] {
        let q = model.search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? library.entries : library.entries.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            switch part {
            case .sidebar: sidebar
            case .projects:
                Group {
                    switch model.place {
                    case .projects: projects
                    case .assets: LibraryAssetsPane(model: model)
                    }
                }
                .background(BehindWindowMaterial(material: .underWindowBackground).ignoresSafeArea())
            }
        }
        .confirmationDialog("Move “\(model.trashing?.name ?? "")” to the Trash?", isPresented: Binding(get: { model.trashing != nil }, set: { if !$0 { model.trashing = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { if let e = model.trashing { do { try library.trash(e) } catch { model.problem = error.localizedDescription } }; model.trashing = nil }
            Button("Cancel", role: .cancel) { model.trashing = nil }
        } message: { Text("The project file is moved to the Trash; its media stays where it is.") }
        .alert("EditMax", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) { Button("OK") { model.problem = nil } } message: { Text(model.problem ?? "") }
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

            VStack(alignment: .leading, spacing: 2) {
                place(.projects, "Projects", "film.stack", count: library.entries.count)
                place(.assets, "Assets", "photo.on.rectangle.angled", count: assets.all.count)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("NEW PROJECT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(1.2)
                let chips = Templates.list().filter(\.builtin)
                FlowLayout(spacing: 6) {
                    ForEach(chips) { t in
                        let on = t.name == model.template.name
                        Button(shortName(t)) { model.template = t }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .liquidGlass(tint: on ? Color.glassSelection : nil, interactive: true)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .pointer()
                            .help("\(t.name): \(t.width)×\(t.height) at \(Int(t.fps)) fps")
                            .uiFrame("home.template.\(slug(t))").uiTap("home.template.\(slug(t))") { model.template = t }
                    }
                }
                Text("\(model.template.width)×\(model.template.height) · \(Int(model.template.fps)) fps").font(.caption).foregroundStyle(.secondary)
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
                SettingsLink { Label("Settings…", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).focusable(false).pointer().uiFrame("home.settings")
            }
            .font(.system(size: 13))

            Spacer()
            Text("Projects live in Movies ▸ EditMax Projects. A draft is a project you have not named yet.\nEditMax by Saidev Dhal.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var projects: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.search.isEmpty ? "Projects" : "Results").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("\(filtered.count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
                NativeSearchField(placeholder: "Search Projects", text: $model.search).frame(width: 220).uiFrame("home.search")
            }
            .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 12)
            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text(library.entries.isEmpty ? "No projects yet" : "Nothing matches “\(model.search)”").font(.headline)
                    if library.entries.isEmpty { Text("Pick a format on the left and create your first project.").font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 18)], spacing: 18) {
                        ForEach(filtered) { e in ProjectCard(entry: e, thumbnail: library.thumbnails[e.id], onOpen: { library.open(e.url) }, onTrash: { model.trashing = e }) }
                    }
                    .padding(.horizontal, 26).padding(.bottom, 26)
                }
            }
        }
    }

    private func place(_ p: HomeModel.Place, _ title: String, _ symbol: String, count: Int) -> some View {
        HomePlaceRow(place: p, title: title, symbol: symbol, count: count, model: model)
    }

    private func newProject() {
        do { library.open(try library.create(template: model.template)) } catch { model.problem = error.localizedDescription }
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

@MainActor
final class HomeModel: ObservableObject {
    /// The sidebar's places: the user's projects (the default) and the Assets library.
    enum Place: String, CaseIterable { case projects, assets }
    @Published var place: Place = .projects
    @Published var search = ""
    @Published var template: Templates.Info = Templates.list().first!
    @Published var trashing: ProjectLibrary.Entry?
    @Published var problem: String?
    // Assets (LibraryViews.swift)
    @Published var assetFilter: LibraryFilter = .all
    @Published var assetSearch = ""
    @Published var removing: LibraryItem?
    @Published var assetMessage: String?
}

/// One place in Home's sidebar (Projects, Assets): a row like the Finder's sidebar, highlighted when chosen.
struct HomePlaceRow: View {
    let place: HomeModel.Place
    let title: String
    let symbol: String
    let count: Int
    @ObservedObject var model: HomeModel

    var body: some View {
        let on = model.place == place
        Button { model.place = place } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(on ? Color.accentColor : .secondary).frame(width: 20)
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                Spacer()
                if count > 0 { Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(on ? Color.primary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false).pointer()
        .uiFrame("home.place.\(place.rawValue)").uiTap("home.place.\(place.rawValue)") { model.place = place }
    }
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
