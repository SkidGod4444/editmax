import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The font browser (FontLibrary.swift): search, category, sort and source filters, every family drawn in its own font.
// `.pick` is the Title inspector's popover (a click applies the family, downloading a Google family first); `.manage` is
// the full-size `FontsPane`, laid out like Font Book: the list, and the selected family in a preview pane with Download
// and Remove. Both are built from standard controls (List, pop-up buttons, the system search field) and accept font
// files dropped on them.

enum FontSourceFilter: String, CaseIterable, Identifiable {
    case all, recent, project, custom, google, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All fonts"; case .recent: "Recently used"; case .project: "In this project"
        case .custom: "My fonts"; case .google: "Google Fonts"; case .system: "On this Mac"
        }
    }
}

struct FontBrowser: View {
    enum Mode { case pick, manage }
    var mode: Mode = .manage
    /// The family the selected text uses (pick), selected in the list.
    var current: String? = nil
    /// Families the open project's texts use.
    var projectFamilies: [String] = []
    /// Applies a family once it is on this Mac; a thrown error shows under the list.
    var onPick: ((String) throws -> Void)? = nil

    @ObservedObject private var lib = FontLibrary.shared
    @State private var search = ""
    @State private var category: FontLibrary.Category?
    @State private var sort: FontLibrary.Sort = .trending
    @State private var source: FontSourceFilter = .all
    @State private var note: String?
    @State private var dropTargeted = false
    @State private var removing: FontLibrary.Family?
    /// The selected row, "section/family": the preview pane's family (manage) or the text's font (pick).
    @State private var selection: String?
    /// The selection was made for the user (the first row), so it moves to the new first row when the list fills in.
    @State private var autoSelected = true

    private var compact: Bool { mode == .pick }

    var body: some View {
        let sections = self.sections
        VStack(spacing: 0) {
            toolbar
            Divider()
            catalogBanner
            if compact {
                familyList(sections)
            } else {
                HStack(spacing: 0) {
                    familyList(sections).frame(width: 300)
                    Divider()
                    preview(family(for: selection, in: sections))
                }
            }
            statusBar
        }
        .background(compact ? Color.clear : Color(nsColor: .controlBackgroundColor))
        .overlay { if dropTargeted { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
        .uiFrame(compact ? "fonts.popover" : "fonts.pane")   // the drop target for font files
        .task { await lib.refreshCatalog() }
        .onAppear { selectInitial(sections) }
        .onChange(of: lib.catalog.count) { _, _ in if autoSelected { selectInitial(self.sections) } }
        .onDisappear { lib.cancelPendingPreviews() }
        .alert("Remove \(removing?.name ?? "")?", isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let f = removing { lib.remove(family: f.name, source: f.source); note = "Removed \(f.name). Its files are in the Archive." } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its files go to the Archive: restore them from Home ▸ Archive within \(AppArchive.shared.periodText). Titles that use it show their style's font until it is back.")
        }
    }

    // MARK: Toolbar

    @ViewBuilder private var toolbar: some View {
        if compact {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    NativeSearchField(placeholder: "Search fonts", text: $search).uiFrame("fonts.search")
                    addButton
                }
                HStack(spacing: 6) { filters; Spacer(minLength: 0) }.controlSize(.small)
            }
            .padding(10)
        } else {
            HStack(spacing: 8) {
                filters
                Spacer(minLength: 8)
                NativeSearchField(placeholder: "Search fonts", text: $search).frame(width: 220).uiFrame("fonts.search")
                addButton
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }

    @ViewBuilder private var filters: some View {
        Picker("Show", selection: $source) {
            ForEach(FontSourceFilter.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().fixedSize().pointer().uiFrame("fonts.source").help("Which fonts to list")
        Picker("Category", selection: $category) {
            Text("Any style").tag(FontLibrary.Category?.none)
            Divider()
            ForEach(FontLibrary.Category.allCases) { Text($0.title).tag(Optional($0)) }
        }.labelsHidden().fixedSize().pointer().uiFrame("fonts.category").help("Kind of typeface")
        Picker("Sort", selection: $sort) {
            ForEach(FontLibrary.Sort.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().fixedSize().pointer().uiFrame("fonts.sort")
            .help("Trending and Popular are Google's own ranks; Trending favours fonts whose use is growing fast, often new ones. Other fonts follow, A–Z.")
    }

    @ViewBuilder private var addButton: some View {
        if compact {
            Button { addFonts() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).focusable(false).pointer().uiFrame("fonts.add")
                .help("Add font files (.ttf, .otf, .ttc, .woff, .woff2), or drop them here")
        } else {
            Button { addFonts() } label: { Label("Add Fonts…", systemImage: "plus") }
                .pointer().uiFrame("fonts.add").help("Add font files (.ttf, .otf, .ttc, .woff, .woff2), or drop them here")
        }
    }

    private var countLine: String {
        let google = lib.catalog.count, here = lib.systemFamilies.count + lib.customFiles.flatMap(\.families).count
        return google > 0 ? "\(google.formatted()) on Google Fonts · \(here.formatted()) on this Mac" : "\(here.formatted()) on this Mac"
    }

    @ViewBuilder private var catalogBanner: some View {
        if source == .all || source == .google {
            switch lib.catalogState {
            case .unavailable:
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                    Text("Google Fonts could not be loaded. Showing the fonts on this Mac.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Try Again") { Task { await lib.refreshCatalog(force: true) } }.controlSize(.small).pointer().uiFrame("fonts.catalog.retry")
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                Divider()
            case .loading where lib.catalog.isEmpty:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading Google Fonts…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                Divider()
            case .stale:
                Label("Offline: Google Fonts as of \(lib.catalogDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "the last visit")", systemImage: "wifi.slash")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            default: EmptyView()
            }
        }
    }

    /// What just happened (an add, a download, an error); otherwise, in the pane, how many fonts there are.
    @ViewBuilder private var statusBar: some View {
        if note != nil || !compact {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let note {
                    Text(note).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { self.note = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).focusable(false).pointer().uiFrame("fonts.note.close").help("Dismiss")
                } else {
                    Text(countLine).monospacedDigit()
                    Spacer()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    // MARK: List

    private struct ListSection: Identifiable { var id: String; var title: String; var rows: [FontLibrary.Family] }
    /// A row's identity is its section and family: the same family can be in several sections (In This Project, Recently
    /// Used, My Fonts), and one identity in two places would select and highlight them together.
    private struct ListRow: Identifiable { var section: String; var family: FontLibrary.Family; var id: String { "\(section)/\(family.name)" } }

    private var sections: [ListSection] {
        let all = lib.families(search: search, category: category, sort: sort)
        func lookup(_ names: [String]) -> [FontLibrary.Family] {
            names.compactMap { n in
                let same = all.filter { $0.name.caseInsensitiveCompare(n) == .orderedSame }
                return same.first { $0.source == .custom } ?? same.first { $0.source == .google } ?? same.first
            }
        }
        let project = ListSection(id: "project", title: "In This Project", rows: lookup(projectFamilies))
        let recent = ListSection(id: "recent", title: "Recently Used", rows: lookup(lib.recent))
        let custom = ListSection(id: "custom", title: "My Fonts", rows: all.filter { $0.source == .custom })
        let google = ListSection(id: "google", title: "Google Fonts", rows: all.filter { $0.source == .google })
        let system = ListSection(id: "system", title: "On This Mac", rows: all.filter { $0.source == .system })
        switch source {
        case .all: return [project, recent, custom, google, system].filter { !$0.rows.isEmpty || ($0.id == "custom" && !compact) }
        case .recent: return [recent]
        case .project: return [project]
        case .custom: return [custom]
        case .google: return [google]
        case .system: return [system]
        }
    }

    private static func tag(_ section: String, _ f: FontLibrary.Family) -> String { "\(section)/\(f.name)" }

    private func family(for tag: String?, in sections: [ListSection]) -> FontLibrary.Family? {
        guard let tag, let slash = tag.firstIndex(of: "/") else { return nil }
        let sid = String(tag[..<slash]), name = String(tag[tag.index(after: slash)...])
        return sections.first { $0.id == sid }?.rows.first { $0.name == name }
    }

    /// Pick: the text's own font. Manage: the first family, so the preview pane is never empty.
    private func selectInitial(_ sections: [ListSection]) {
        if compact {
            guard let current else { return }
            for s in sections { if let f = s.rows.first(where: { $0.name.caseInsensitiveCompare(current) == .orderedSame }) { selection = Self.tag(s.id, f); return } }
        } else if let s = sections.first(where: { !$0.rows.isEmpty }), let f = s.rows.first {
            selection = Self.tag(s.id, f); autoSelected = true
        }
    }

    private func familyList(_ sections: [ListSection]) -> some View {
        List(selection: $selection) {
            ForEach(sections) { s in
                Section(s.title) {
                    if s.rows.isEmpty {
                        Text(emptyText(s.id)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).selectionDisabled()
                    }
                    ForEach(s.rows.map { ListRow(section: s.id, family: $0) }) { row in
                        let f = row.family
                        FontListRow(family: f, font: nameFont(f, size: compact ? 14 : 15),
                                    isCurrent: compact && current.map { f.name.caseInsensitiveCompare($0) == .orderedSame } == true,
                                    progress: lib.progress[f.name], height: compact ? 22 : 26)
                            .tag(Self.tag(s.id, f))
                            .onAppear { if f.source == .google, !f.installed { lib.requestPreview(f.name) } }
                            .uiFrame("fonts.\(s.id).\(f.name)")
                            .uiTap("fonts.\(s.id).\(f.name)") { if compact { pick(f) } else { selection = Self.tag(s.id, f); autoSelected = false } }
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { tags in
            if !compact, let f = family(for: tags.first, in: sections) { rowMenu(f) }
        } primaryAction: { tags in
            // Double-click or Return: use it (pick) or download it (manage).
            guard let f = family(for: tags.first, in: sections) else { return }
            if compact { pick(f) } else if f.source == .google, !f.installed { download(f) }
        }
        .onChange(of: selection) { _, new in
            guard let new else { return }
            // The selection came from the user (a click or the arrow keys), not from `selectInitial`.
            let event = NSApp.currentEvent?.type
            let byUser = event == .leftMouseDown || event == .leftMouseUp || event == .keyDown
            if byUser { autoSelected = false }
            // Pick: a click applies the font. The arrow keys only move through the list (Return applies), so browsing
            // never downloads a Google family by passing over it.
            if compact, event == .leftMouseDown || event == .leftMouseUp, let f = family(for: new, in: sections),
               current.map({ f.name.caseInsensitiveCompare($0) != .orderedSame }) ?? true {
                pick(f)
            }
        }
        .uiFrame("fonts.list")
    }

    @ViewBuilder private func rowMenu(_ f: FontLibrary.Family) -> some View {
        if f.source == .google, !f.installed { Button("Download \(f.name)") { download(f) } }
        if let url = installedURL(f) { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        if removable(f) {
            Divider()
            Button("Remove \(f.name)…", role: .destructive) { removing = f }
        }
    }

    private func removable(_ f: FontLibrary.Family) -> Bool { f.source == .custom || (f.source == .google && f.installed) }

    private func installedURL(_ f: FontLibrary.Family) -> URL? {
        switch f.source {
        case .custom: return lib.customFiles.first { $0.families.contains { $0.caseInsensitiveCompare(f.name) == .orderedSame } }?.url
        case .google: return lib.googleInstalled.first { $0.key.caseInsensitiveCompare(f.name) == .orderedSame }?.value.first
        case .system: return nil
        }
    }

    private func emptyText(_ section: String) -> String {
        section == "custom" ? "Fonts you add show here. Drop .ttf or .otf files here, or click Add Fonts…"
            : section == "recent" ? "Fonts you pick show here." : search.isEmpty ? "None yet." : "No font matches \u{201C}\(search)\u{201D}."
    }

    /// The family's name in the family itself: an installed face, or the preview subset of a Google family; nil = not yet.
    private func nameFont(_ f: FontLibrary.Family, size: CGFloat) -> Font? {
        _ = lib.previewTick
        if f.installed, let nf = lib.displayFont(f.name, size: size) { return Font(nf as CTFont) }
        if f.source == .google, !f.installed, let ct = lib.previewFont(f.name, size: size) { return Font(ct) }
        return nil
    }

    private func meta(_ f: FontLibrary.Family) -> String {
        let cat = (f.source == .google ? f.category : lib.inferredCategory(f.name))?.title
        let styles = f.source == .system ? TextFont.faces(family: f.name).count : f.styles
        let where_: String
        switch f.source {
        case .google: where_ = f.installed ? "Google Fonts, downloaded" : "Google Fonts"
        case .custom: where_ = "Added by you"
        case .system: where_ = "On this Mac"
        }
        return [cat, styles > 0 ? "\(styles) style\(styles == 1 ? "" : "s")" : nil, where_].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func preview(_ f: FontLibrary.Family?) -> some View {
        if let f {
            FontPreviewPane(family: f, meta: meta(f), progress: lib.progress[f.name],
                            onDownload: f.source == .google && !f.installed ? { download(f) } : nil,
                            onRemove: removable(f) ? { removing = f } : nil,
                            revealURL: installedURL(f))
        } else {
            ContentUnavailableView("No Font Selected", systemImage: "textformat", description: Text("Choose a font in the list to preview it."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func pick(_ f: FontLibrary.Family) {
        guard lib.progress[f.name] == nil else { return }
        if f.source == .google, !f.installed {
            Task { @MainActor in
                do { try await lib.installGoogle(f.name); try onPick?(f.name) } catch { note = error.localizedDescription }
            }
        } else {
            do { try onPick?(f.name) } catch { note = error.localizedDescription }
        }
    }

    private func download(_ f: FontLibrary.Family) {
        Task { @MainActor in
            do { let r = try await lib.installGoogle(f.name); if !compact { note = "\(r.family): \(r.faces.count) style\(r.faces.count == 1 ? "" : "s") ready." } }
            catch { note = error.localizedDescription }
        }
    }

    private func addFonts() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = FontLibrary.fontExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose font files: .ttf, .otf, .ttc, .woff or .woff2"
        panel.prompt = "Add"
        panel.begin { r in
            guard r == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await add(urls) }
        }
    }

    private func add(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let r = await lib.addFontFiles(urls)
        if r.files.isEmpty { note = r.failures.first ?? "No fonts were added."; return }
        // From a title's Font popover: the font the user just added is the one they want on it. (The Open panel has
        // closed the popover by now, so this is also the only answer they see.)
        if compact, let family = r.families.first { do { try onPick?(family) } catch { note = error.localizedDescription } }
        note = "Added \(r.families.joined(separator: ", "))." + (r.failures.isEmpty ? "" : " Skipped: \(r.failures.joined(separator: "; "))")
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for p in files {
                if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) { urls.append(u) }
            }
            await add(urls)
        }
        return true
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            Label("Drop font files to add them", systemImage: "textformat").font(.headline).foregroundStyle(Color.accentColor)
        }
        .padding(6)
        .allowsHitTesting(false)
    }
}

/// One family in the list: its name drawn in it, and whether it still has to come from Google.
private struct FontListRow: View {
    let family: FontLibrary.Family
    let font: Font?
    let isCurrent: Bool
    let progress: Double?
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text(family.name).font(font ?? .body).foregroundStyle(font == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let progress {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.mini).help("Downloading \(family.name)…")
            } else if family.source == .google, !family.installed {
                Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).help("On Google Fonts: it downloads when you use it")
            } else if isCurrent {
                Image(systemName: "checkmark").foregroundStyle(.secondary).help("The font this text uses")
            }
        }
        .frame(height: height)
        .clipped()   // a font with tall ascenders stays in its row
    }
}

/// The selected family full size, as Font Book shows it: its name and details, Download or Remove, then the sample in
/// every style it has on this Mac (or, before a Google family is downloaded, in a preview of its letters).
private struct FontPreviewPane: View {
    let family: FontLibrary.Family
    let meta: String
    let progress: Double?
    let onDownload: (() -> Void)?
    let onRemove: (() -> Void)?
    let revealURL: URL?
    @ObservedObject private var lib = FontLibrary.shared
    @AppStorage("fontPreviewSize") private var size = 36.0
    @State private var sample = ""

    private var shown: String { sample.isEmpty ? FontLibrary.defaultSample : sample }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(family.name).font(.title2.weight(.semibold)).lineLimit(1)
                    Text(meta).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let progress {
                    ProgressView(value: progress).frame(width: 90).help("Downloading \(family.name)…")
                } else if let onDownload {
                    Button("Download", action: onDownload).pointer().uiFrame("fonts.download.\(family.name)")
                        .help("Download every style of \(family.name) from Google Fonts")
                }
                if let revealURL {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([revealURL]) } label: { Image(systemName: "folder") }
                        .pointer().uiFrame("fonts.reveal.\(family.name)").help("Show in Finder")
                }
                if let onRemove {
                    Button("Remove…", role: .destructive, action: onRemove).pointer().uiFrame("fonts.remove.\(family.name)")
                        .help(family.source == .custom ? "Remove this font from EditMax" : "Remove the download")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) { samples }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack(spacing: 10) {
                TextField("Type to preview", text: $sample).textFieldStyle(.roundedBorder).uiFrame("fonts.sampleText")
                Slider(value: $size, in: 12...144).frame(width: 150).pointer().uiFrame("fonts.sampleSize").help("Preview size")
                Text("\(Int(size)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            }
            .controlSize(.small)
            .padding(.horizontal, 20).padding(.vertical, 9)
        }
        .onAppear { requestSample() }
        .onChange(of: family.name) { _, _ in requestSample() }
    }

    @ViewBuilder private var samples: some View {
        let faces = family.installed ? TextFont.faces(family: family.name) : []
        if !faces.isEmpty {
            ForEach(faces.prefix(30), id: \.postScript) { face in
                VStack(alignment: .leading, spacing: 4) {
                    Text(face.style).font(.caption).foregroundStyle(.secondary)
                    Text(shown).font(Font(CTFontCreateWithName(face.postScript as CFString, size, nil)))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let ct = sampleFont {
            Text(shown).font(Font(ct)).fixedSize(horizontal: false, vertical: true)
            Text("A preview of \(family.name). Download it to use it in titles; all \(family.styles) style\(family.styles == 1 ? "" : "s") come with it.")
                .font(.callout).foregroundStyle(.secondary)
        } else if lib.previewUnavailable(family.name, sample: true) {
            Label("The preview could not be loaded. Check the connection, or download the font to see it.", systemImage: "wifi.slash")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading preview…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var sampleFont: CTFont? {
        _ = lib.previewTick
        return lib.previewFont(family.name, size: size, sample: true)
    }

    private func requestSample() {
        if family.source == .google, !family.installed { lib.requestPreview(family.name, sample: true) }
    }
}

/// The system search field (magnifying glass, clear button, the look of every Mac search field), for SwiftUI views
/// with no toolbar to put `.searchable` in.
struct NativeSearchField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        let size: NSControl.ControlSize = switch context.environment.controlSize {
        case .mini: .mini
        case .small: .small
        case .large, .extraLarge: .large
        default: .regular
        }
        if field.controlSize != size { field.controlSize = size; field.font = .systemFont(ofSize: NSFont.systemFontSize(for: size)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ n: Notification) { if let f = n.object as? NSSearchField { text.wrappedValue = f.stringValue } }
        @objc func changed(_ sender: NSSearchField) { text.wrappedValue = sender.stringValue }   // also the clear button
    }
}

/// The font library full size, for the Home window's Assets section: browse Google Fonts and the Mac's fonts, download,
/// add font files (button or drop) and remove the ones you added.
struct FontsPane: View {
    var body: some View { FontBrowser(mode: .manage) }
}

// MARK: - Title inspector rows

/// The Title card's Font row: the current font, drawn in itself; a click opens the browser in a popover. Picking applies
/// to this text as one undoable edit (`ToolExecutor.setTextStyle`).
struct TextFontRow: View {
    @ObservedObject var document: EditMaxDocument
    let text: TextOverlay
    @State private var browsing = false

    var body: some View {
        let style = CaptionPresets.style(text.preset)
        let shown = text.font(style: style, size: 13)
        InspectorRow("Font") {
            HStack(spacing: 4) {
                Button { browsing = true } label: {
                    HStack(spacing: 5) {
                        Text(text.fontDisplayName ?? shown.familyName ?? style.title).font(text.fontIsMissing ? .system(size: 13) : Font(shown as CTFont)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered).focusable(false).pointer().uiFrame("inspector.text.font").help("Choose the font")
                .popover(isPresented: $browsing, arrowEdge: .leading) {
                    FontBrowser(mode: .pick, current: text.fontDisplayName, projectFamilies: FontLibrary.shared.families(in: document.project)) { family in
                        try ToolExecutor(document: document, origin: .user).setTextStyle(text.id.uuidString, font: .family(family, face: nil), fontSize: nil, color: nil)
                        browsing = false
                    }
                    .frame(width: 340, height: 480)
                }
                if text.hasChosenFont {
                    Button { _ = try? ToolExecutor(document: document, origin: .user).setTextStyle(text.id.uuidString, font: .preset, fontSize: nil, color: nil) } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless).focusable(false).pointer().uiFrame("inspector.text.fontReset").help("Back to the style's own font")
                }
            }
        }
    }
}

/// The chosen family's faces (Light, Regular, Bold…), when it has more than one.
struct TextFaceRow: View {
    @ObservedObject var document: EditMaxDocument
    let text: TextOverlay
    let faces: [TextFont.Face]

    var body: some View {
        let selected = faces.contains { $0.postScript == text.fontName } ? text.fontName ?? "" : faces.first?.postScript ?? ""
        InspectorRow("Weight") {
            Picker("Weight", selection: Binding(get: { selected }, set: { ps in
                guard ps != text.fontName, let family = text.fontFamily else { return }
                _ = try? ToolExecutor(document: document, origin: .user).setTextStyle(text.id.uuidString, font: .family(family, face: ps), fontSize: nil, color: nil)
            })) {
                ForEach(faces, id: \.postScript) { f in Text(f.style).tag(f.postScript) }
            }
            .labelsHidden().fixedSize().pointer().uiFrame("inspector.text.fontWeight")
        }
    }
}

/// A chosen font that is not on this Mac: downloading (Google), or what to do about it. The text draws in its style's
/// font meanwhile.
struct TextFontStatusRow: View {
    let status: FontLibrary.FontStatus
    @State private var note: String?

    var body: some View {
        switch status {
        case .ok:
            EmptyView()
        case .downloading(let family, let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).controlSize(.small).frame(width: 60)
                Text("Downloading \(family)…").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        case .missingGoogle(let family, let error):
            warning("\(family) is not on this Mac. It downloads from Google Fonts when you are online.", detail: note ?? error) {
                Button("Download") {
                    Task { @MainActor in do { try await FontLibrary.shared.installGoogle(family); note = nil } catch { note = error.localizedDescription } }
                }.controlSize(.small).pointer().uiFrame("inspector.text.fontDownload")
            }
        case .missingCustom(let family):
            warning("\(family) is not on this Mac. Add the font file to use it.", detail: note) {
                Button("Add font…") { addFile() }.controlSize(.small).pointer().uiFrame("inspector.text.fontAdd")
            }
        }
    }

    private func warning<B: View>(_ text: String, detail: String?, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 4)
            button()
        }
    }

    private func addFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = FontLibrary.fontExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose the font file"
        panel.prompt = "Add"
        panel.begin { r in
            guard r == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                let added = await FontLibrary.shared.addFontFiles(urls)
                note = added.files.isEmpty ? added.failures.first : nil
            }
        }
    }
}
