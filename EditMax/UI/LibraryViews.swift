import SwiftUI
import AppKit
import AVFoundation
import CoreText
import ImageIO
import UniformTypeIdentifiers

// The Assets library on screen: Home's Assets section (a grid with a kind filter, search and a drop zone) and the
// editor media panel's Library list. Labelled "Assets" for the user; the types are Library… (AssetLibrary.swift holds
// the index).

/// Thumbnails, font specimens and file sizes for library items, made once per item and kept in memory.
@MainActor
final class LibraryThumbnails: ObservableObject {
    static let shared = LibraryThumbnails()
    @Published private(set) var images: [UUID: CGImage] = [:]
    /// The font in a font file, read without registering it with the system (so it never shadows an installed font).
    @Published private(set) var fonts: [UUID: CTFontDescriptor] = [:]
    private(set) var sizes: [UUID: Int64] = [:]
    private var tried: Set<UUID> = []

    func request(_ item: LibraryItem) {
        guard !tried.contains(item.id), item.exists else { return }
        tried.insert(item.id)
        let url = item.url, id = item.id
        if let size = (try? FileManager.default.attributesOfItem(atPath: item.path))?[.size] as? NSNumber { sizes[id] = size.int64Value }
        guard images[id] == nil else { return }
        switch item.kind {
        case .font:
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let d = descriptors.first { fonts[id] = d }
        case .image:
            Task.detached(priority: .utility) {
                let img = Self.imageThumbnail(url)
                await MainActor.run { if let img { self.images[id] = img } }
            }
        case .video:
            let at = min(1, (item.duration ?? 0) / 3)
            Task { if let img = await ProjectLibrary.poster(url: url, kind: .video, at: at) { images[id] = img } }
        case .audio: break
        }
    }

    /// A thumbnail made elsewhere (the offscreen previews).
    func set(_ image: CGImage, for id: UUID) { images[id] = image }

    func font(for id: UUID, size: CGFloat) -> Font? { fonts[id].map { Font(CTFontCreateWithFontDescriptor($0, size, nil)) } }

    nonisolated static func imageThumbnail(_ url: URL, maxPixels: Int = 480) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// The words under an item: what it is and who uses it.
enum LibraryText {
    static func detail(_ item: LibraryItem, size: Int64?) -> String {
        var parts: [String] = []
        switch item.kind {
        case .video:
            if let d = item.duration { parts.append(time(d)) }
            if let w = item.width, let h = item.height { parts.append("\(w)×\(h)") }
        case .audio:
            if let d = item.duration { parts.append(time(d)) }
        case .image:
            if let w = item.width, let h = item.height { parts.append("\(w)×\(h)") } else { parts.append("Image") }
        case .font:
            parts.append("Font")
        }
        if let size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    static func usedIn(_ item: LibraryItem) -> String {
        let names = item.usedIn.values.sorted()
        if names.isEmpty { return item.kind == .font ? "Added \(added(item))" : "Not in a project yet" }
        if names.count <= 2 { return "Used in " + names.joined(separator: ", ") }
        return "Used in \(names[0]), \(names[1]) and \(names.count - 2) more"
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    private static func added(_ item: LibraryItem) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return Date().timeIntervalSince(item.added) < 60 ? "just now" : f.localizedString(for: item.added, relativeTo: Date())
    }

    static func symbol(_ kind: LibraryItem.Kind) -> String {
        switch kind {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .font: return "textformat"
        }
    }
}

/// The picture for an item: a video frame or the image, a waveform glyph for sound, "Aa" in the font for a font file,
/// and a warning when the file is not where the library says.
struct LibraryTile: View {
    let item: LibraryItem
    var corner: CGFloat = 10
    var specimen: CGFloat = 34
    @ObservedObject private var thumbs = LibraryThumbnails.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous).fill(background)
            if !item.exists {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: specimen * 0.5)).foregroundStyle(.orange)
                    if specimen >= 24 { Text("Missing").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange) }
                }
            } else if let img = thumbs.images[item.id], item.kind == .video || item.kind == .image {
                // Drawn over a frame that takes the tile's size: a 16:9 or portrait picture fills the tile and is cut to
                // it, and never sizes the tile itself (it used to push past its card into the next one).
                Color.clear.overlay { Image(decorative: img, scale: 1).resizable().scaledToFill() }.clipped()
            } else if item.kind == .font {
                Text("Aa").font(thumbs.font(for: item.id, size: specimen) ?? .system(size: specimen, weight: .regular)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.5)
            } else if item.kind == .audio {
                Image(systemName: "waveform").font(.system(size: specimen * 0.7, weight: .medium)).foregroundStyle(Color.green)
            } else {
                Image(systemName: LibraryText.symbol(item.kind)).font(.system(size: specimen * 0.5)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .onAppear { thumbs.request(item) }
    }

    private var background: Color {
        switch item.kind {
        case .audio: return Color.green.opacity(0.22)
        case .font: return Color(white: 0.16)
        default: return Color.black.opacity(0.85)
        }
    }
}

/// A file drag out of the library (to Finder, the timeline or a project's media panel): the file's URL, which every
/// drop target that takes files already understands.
enum LibraryDrag {
    static func provider(_ item: LibraryItem) -> NSItemProvider {
        DebugLog.event("drag-start", ["library": item.kind.rawValue])
        let p = NSItemProvider(object: item.url as NSURL)
        p.suggestedName = item.name
        return p
    }
    @ViewBuilder static func preview(_ item: LibraryItem) -> some View {
        Label(item.name, systemImage: LibraryText.symbol(item.kind))
            .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
    /// File URLs out of dropped providers.
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) { urls.append(u) }
        }
        return urls
    }
}

/// The kind filter above the grid.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", video = "Video", audio = "Audio", images = "Images", fonts = "Fonts"
    var id: String { rawValue }
    var kind: LibraryItem.Kind? {
        switch self {
        case .all: return nil
        case .video: return .video
        case .audio: return .audio
        case .images: return .image
        case .fonts: return .font
        }
    }
}

// MARK: Home ▸ Assets

/// Home's Assets section: everything the user has brought into EditMax, as a grid. Files dropped here are copied into
/// EditMax's Assets folder (the user is putting them into the app, as with the notch drawer).
struct LibraryAssetsPane: View {
    @ObservedObject var model: HomeModel
    @ObservedObject private var library = AssetLibrary.shared
    @State private var targeted = false

    private var shown: [LibraryItem] { library.items(kind: model.assetFilter.kind, search: model.assetSearch) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.assetSearch.isEmpty ? "Assets" : "Results").font(.system(size: 22, weight: .bold, design: .rounded))
                if model.assetFilter != .fonts {   // the font browser counts its own fonts
                    Text("\(shown.count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Color.primary.opacity(0.08), in: Capsule())
                }
                Spacer()
                if model.assetFilter != .fonts {   // the font browser has its own search and Add Fonts
                    Button { chooseFiles() } label: { Label("Add Files…", systemImage: "plus") }
                        .pointer().uiFrame("home.assets.add").uiTap("home.assets.add") { chooseFiles() }
                    NativeSearchField(placeholder: "Search Assets", text: $model.assetSearch).frame(width: 220).uiFrame("home.assets.search")
                }
            }
            .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 10)
            HStack {
                Picker("Kind", selection: $model.assetFilter) {
                    ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .pointer().uiFrame("home.assets.kind")
                .background { ForEach(LibraryFilter.allCases) { f in Color.clear.uiTap("home.assets.kind.\(f.rawValue.lowercased())") { model.assetFilter = f } } }
                Spacer()
                if model.assetFilter != .fonts { Text("Drop files here to add them").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 26).padding(.bottom, 14)
            if model.assetFilter == .fonts {
                // Fonts: the whole font library (Google Fonts, your own fonts, add and remove), FontBrowser.swift, in a
                // box lined up with the rest of the page.
                FontsPane()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                    .padding(.horizontal, 26).padding(.bottom, 26)
            } else if shown.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text(library.all.isEmpty ? "No assets yet" : model.assetSearch.isEmpty ? "No \(model.assetFilter.rawValue.lowercased()) yet" : "Nothing matches “\(model.assetSearch)”").font(.headline)
                    if library.all.isEmpty {
                        Text("Files you import into a project show up here.\nDrop files here, or on the notch at the top of the screen, to add them.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 30)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 16)], spacing: 18) {
                        ForEach(shown) { item in
                            LibraryCard(item: item, onRemove: { model.removing = item })
                        }
                    }
                    .padding(.horizontal, 26).padding(.bottom, 26)
                }
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { Label("Drop to add to Assets", systemImage: "tray.and.arrow.down").font(.headline).foregroundStyle(Color.accentColor) }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let m = model.assetMessage {
                Text(m).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 8)
                    .liquidGlass().padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.assetMessage)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { add(await LibraryDrag.urls(from: providers)) }
            return true
        }
        .uiFrame("home.assets")
        .confirmationDialog("Remove “\(model.removing?.name ?? "")” from Assets?", isPresented: Binding(get: { model.removing != nil }, set: { if !$0 { model.removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let it = model.removing {
                    // An installed font leaves the font library too, so it is out of the Font picker at once.
                    if it.kind == .font, let f = FontLibrary.shared.installedFamily(ofFile: it.path) { FontLibrary.shared.remove(family: f.family, source: f.source) }
                    else { library.remove([it.id]) }
                }
                model.removing = nil
            }
            Button("Cancel", role: .cancel) { model.removing = nil }
        } message: { Text(model.removing.map(removeNote) ?? "") }
    }

    private func removeNote(_ item: LibraryItem) -> String {
        if item.kind == .font, let f = FontLibrary.shared.installedFamily(ofFile: item.path) {
            return "\(f.family) is uninstalled from EditMax and its files go to the Trash. Titles that use it switch to their preset font."
        }
        if !item.usedIn.isEmpty {
            let names = item.usedIn.values.sorted().joined(separator: ", ")
            return "\(names) still use\(item.usedIn.count == 1 ? "s" : "") it, so the file stays on disk. It comes back here the next time \(item.usedIn.count == 1 ? "that project opens" : "one of them opens")."
        }
        return library.isCopy(item) ? "EditMax's copy of the file is moved to the Trash." : "The file stays where it is."
    }

    private func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let r = await library.addFiles(urls, source: .upload, copy: true)
            show(r.message)
        }
    }

    private func show(_ message: String) {
        model.assetMessage = message
        Task { try? await Task.sleep(for: .seconds(2.5)); if model.assetMessage == message { model.assetMessage = nil } }
    }

    private func chooseFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = [.movie, .audio, .image, .font]
        p.prompt = "Add to Assets"
        p.begin { if $0 == .OK { add(p.urls) } }
    }
}

/// One item in the Assets grid. Drag it to Finder or into an open project; hover for Reveal and Remove.
struct LibraryCard: View {
    let item: LibraryItem
    let onRemove: () -> Void
    @State private var hover = false
    @ObservedObject private var thumbs = LibraryThumbnails.shared
    private var id: String { "home.asset.\(item.name)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LibraryTile(item: item, specimen: 40)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if item.kind == .video || item.kind == .audio, let d = item.duration, item.exists {
                        Text(LibraryText.time(d)).font(.caption2.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if hover {
                        HStack(spacing: 4) {
                            Button { reveal() } label: { Image(systemName: "folder").padding(6).background(.black.opacity(0.6), in: Circle()).foregroundStyle(.white) }
                                .buttonStyle(.plain).focusable(false).help("Reveal in Finder").pointer().disabled(!item.exists).uiFrame("\(id).reveal")
                            Button { onRemove() } label: { Image(systemName: "trash").padding(6).background(.black.opacity(0.6), in: Circle()).foregroundStyle(.white) }
                                .buttonStyle(.plain).focusable(false).help("Remove from Assets").pointer().uiFrame("\(id).remove")
                        }
                        .padding(6)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover ? Color.accentColor.opacity(0.9) : Color.clear, lineWidth: 1.5))
                .shadow(color: .black.opacity(hover ? 0.3 : 0.15), radius: hover ? 10 : 5, y: hover ? 6 : 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(item.exists ? Color.primary : Color.secondary)
                Text(item.exists ? LibraryText.detail(item, size: thumbs.sizes[item.id]) : "Missing: not at \(abbreviated(item.path))")
                    .font(.caption).foregroundStyle(item.exists ? Color.secondary : Color.orange).lineLimit(1).truncationMode(.middle)
                Text(LibraryText.usedIn(item)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.snappy(duration: 0.18), value: hover)
        .modifier(LibraryDragSource(item: item))
        .pointer()
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder") { reveal() }.disabled(!item.exists)
            Divider()
            Button("Remove from Assets…", systemImage: "trash", role: .destructive) { onRemove() }
        }
        .uiFrame(id)
        .help(item.exists ? "Drag into a project or to the Finder" : "The file is not at \(item.path)")
    }

    private func reveal() { if item.exists { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
}

/// `onDrag` with the file URL, only for a file that is there.
private struct LibraryDragSource: ViewModifier {
    let item: LibraryItem
    func body(content: Content) -> some View {
        if item.exists {
            content.onDrag { LibraryDrag.provider(item) } preview: { LibraryDrag.preview(item) }
        } else {
            content
        }
    }
}

private func abbreviated(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

// MARK: Editor ▸ media panel ▸ Library

/// The editor media panel's Library list: the same items as Home's Assets section (fonts aside: a project holds video,
/// sound and images), compact. Drag one onto the timeline or the Project list to add it to the project (the drop
/// imports it first, then places it); double-click adds it to the project's media.
struct LibraryPanelList: View {
    @ObservedObject var document: EditMaxDocument
    let onError: (String) -> Void
    @ObservedObject private var library = AssetLibrary.shared
    @ObservedObject private var thumbs = LibraryThumbnails.shared
    @State private var search = ""
    @State private var hovered: UUID?
    /// A line shown on a row for a moment after a double-click that adds nothing, saying why.
    @State private var notice: (item: UUID, text: String)?

    private var shown: [LibraryItem] { library.items(search: search).filter { $0.kind != .font } }

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(placeholder: "Search Assets", text: $search).controlSize(.small)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4).uiFrame("media.library.search")
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { item in row(item) }
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
            }
            .overlay {
                if shown.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                        Text(library.all.isEmpty ? "Nothing in Assets yet" : "Nothing matches “\(search)”").font(.headline).multilineTextAlignment(.center)
                        if library.all.isEmpty { Text("Files you import into any project show up here.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    }
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func row(_ item: LibraryItem) -> some View {
        let inProject = document.project.assets.contains { $0.path == item.path }
        return HStack(spacing: 10) {
            LibraryTile(item: item, corner: 8, specimen: 16).frame(width: 56, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(item.exists ? Color.primary : Color.secondary)
                if let notice, notice.item == item.id {
                    Text(notice.text).font(.system(size: 11, weight: .medium)).foregroundStyle(item.exists ? Color.accentColor : Color.orange).lineLimit(1)
                } else {
                    Text(item.exists ? subtitle(item) : "Missing").font(.system(size: 11)).foregroundStyle(item.exists ? Color.secondary : Color.orange)
                        .monospacedDigit().lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            if inProject {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor).help("In this project")
            }
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered == item.id ? Color.primary.opacity(0.06) : Color.clear))
        .contentShape(Rectangle())
        .modifier(LibraryDragSource(item: item))
        .onTapGesture(count: 2) { doubleClicked(item) }
        .uiTap("media.library.\(item.name)", count: 2) { doubleClicked(item) }
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        .help(item.exists ? "Drag onto the timeline, or double-click to add it to this project" : "The file is not at \(item.path)")
        .pointer()
        .uiFrame("media.library.\(item.name)")
        .contextMenu {
            Button("Add to project", systemImage: "plus") { addToProject(item) }.disabled(!item.exists || inProject)
            Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }.disabled(!item.exists)
        }
    }

    /// Length (or size for a picture), then where it is used: "00:02.00 · Launch video", "320×200 · 2 projects".
    private func subtitle(_ item: LibraryItem) -> String {
        let names = item.usedIn.values.sorted()
        let first: String
        switch item.kind {
        case .video, .audio: first = item.duration.map { Timecode.string($0) } ?? ""
        default: first = item.width.flatMap { w in item.height.map { "\(w)×\($0)" } } ?? "Image"
        }
        return names.isEmpty ? first : first + " · " + (names.count == 1 ? names[0] : "\(names.count) projects")
    }

    /// Adds the item, or says on its row why a double-click does not: it is already in this project (the Project list
    /// has it), or its file is gone.
    private func doubleClicked(_ item: LibraryItem) {
        if document.project.assets.contains(where: { $0.path == item.path }) { show("Already in this project", on: item) }
        else if !item.exists { show("The file is missing, so it can't be added", on: item) }
        else { addToProject(item) }
    }

    private func show(_ text: String, on item: LibraryItem) {
        withAnimation(.snappy) { notice = (item.id, text) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if notice?.item == item.id, notice?.text == text { withAnimation(.snappy) { notice = nil } }
        }
    }

    private func addToProject(_ item: LibraryItem) {
        guard item.exists else { return }
        Task {
            do { try await ToolExecutor(document: document, origin: .user).importMedia(paths: [item.path]) }
            catch { onError(InspectorMessage.text(error)) }
        }
    }
}
