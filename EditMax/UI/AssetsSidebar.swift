import SwiftUI
import UniformTypeIdentifiers

struct AssetsSidebar: View {
    @ObservedObject var document: EditMaxDocument
    @EnvironmentObject var state: EditorState
    @State private var importing = false
    @State private var error: String?
    @State private var hovered: UUID?
    @ObservedObject private var thumbnails = ThumbnailStore.shared
    @ObservedObject private var proxies = ProxyStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // Title row: the panel name with a count badge, and one icon button to import.
            HStack(spacing: 8) {
                Text("Media").font(.system(size: 13, weight: .semibold))
                if !document.project.assets.isEmpty {
                    Text("\(document.project.assets.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                        .padding(.horizontal, 6).frame(height: 16).background(Color.primary.opacity(0.08), in: Capsule())
                }
                Spacer()
                Button { importing = true } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).imageScale(.medium)
                        .frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).focusable(false).help("Import media (or drop files here)").pointer().uiFrame("media.import")
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 36)
            Divider()
            // Plain rows, not a List: List owns the mouse-down for selection on macOS and a drag from a row never starts.
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(document.project.assets) { asset in
                        // "Selected" is derived, not stored: the asset behind a selected timeline clip. Hover is a 6 % wash.
                        let selected = selectedAssetIDs.contains(asset.id)
                        HStack(spacing: 10) {
                            tile(asset)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(asset.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                HStack(spacing: 6) {
                                    Text(subtitle(asset)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                                    if document.project.settings.useProxies, asset.kind == .video, proxies.ready(for: asset) != nil {
                                        Text("PROXY").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange).padding(.horizontal, 4).frame(height: 13).background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 3, style: .continuous)).help("Previewing from a 960×540 proxy; the export uses the original")
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.18) : hovered == asset.id ? Color.primary.opacity(0.06) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
                        .animation(.snappy, value: selected)
                        .onAppear { thumbnails.request(asset) }
                        .contentShape(Rectangle())
                        .onDrag {
                            DebugLog.event("drag-start", ["asset": asset.name])
                            return NSItemProvider(object: AssetDrag.string(asset.id) as NSString)
                        } preview: {
                            Label(asset.name, systemImage: asset.kind == .video ? "film" : asset.kind == .audio ? "waveform" : asset.kind == .sequence ? "film.stack" : "photo")
                                .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .onTapGesture(count: 2) { add(asset) }
                        .uiTap("media.\(asset.name)", count: 2) { add(asset) }
                        .onHover { hovered = $0 ? asset.id : (hovered == asset.id ? nil : hovered) }
                        .help("Drag onto the timeline, or double-click to append")
                        .pointer()
                        .uiFrame("media.\(asset.name)")
                        .contextMenu {
                            Button("Add to timeline", systemImage: "plus") { add(asset) }
                            Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([asset.url]) }
                            Divider()
                            let uses = document.project.allClips.filter { $0.assetID == asset.id }.count
                            Button(uses == 0 ? "Remove from project" : "Remove from project and \(uses) clip\(uses == 1 ? "" : "s")", systemImage: "trash", role: .destructive) {
                                state.selectedClipIDs = []
                                document.apply("Remove \(asset.name)", origin: .user) { p in _ = p.removeAsset(asset.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 8)
            }
            .overlay {
                if document.project.assets.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
                        Text("Drop video, audio or images here").font(.headline).foregroundStyle(.primary).multilineTextAlignment(.center)
                        Text("or press + to import").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .allowsHitTesting(false)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .audio, .image, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .png, .jpeg], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importURLs(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) { urls.append(u) }
                }
                importURLs(urls)
            }
            return true
        }
        .alert("Import failed", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    /// Assets behind the clips selected on the timeline, so the list reflects what the user is working on.
    private var selectedAssetIDs: Set<UUID> {
        guard !state.selectedClipIDs.isEmpty else { return [] }
        return Set(document.project.allClips.filter { state.selectedClipIDs.contains($0.id) }.map(\.assetID))
    }

    /// 56×36 tile: the first frame for video, a glyph on a tinted square for audio and images.
    @ViewBuilder private func tile(_ a: Asset) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(a.kind == .audio ? Color.green.opacity(0.25) : Color.black.opacity(0.35))
            if a.kind == .video || a.kind == .sequence, let frame = thumbnails.strips[a.id]?.frames.first {
                Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else if a.kind == .image, let img = NSImage(contentsOfFile: a.path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: a.kind == .video ? "film" : a.kind == .audio ? "waveform" : a.kind == .sequence ? "film.stack" : "photo").font(.system(size: 13)).foregroundStyle(a.kind == .audio ? Color.green : .secondary)
            }
        }
        .frame(width: 56, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func subtitle(_ a: Asset) -> String {
        var s = Timecode.string(a.duration)
        if let w = a.width, let h = a.height { s += "  \(w)×\(h)" }
        return s
    }
    private func importURLs(_ urls: [URL]) {
        Task {
            do { try await ToolExecutor(document: document, origin: .user).importMedia(paths: urls.map(\.path)) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func add(_ asset: Asset) {
        do { try ToolExecutor(document: document, origin: .user).insertClip(asset: asset.id.uuidString) } catch { self.error = error.localizedDescription }
    }
}

/// Payload of a media-panel drag: a plain string so it travels through NSItemProvider without a custom type declaration.
enum AssetDrag {
    static let prefix = "editmax-asset:"
    static func string(_ id: UUID) -> String { prefix + id.uuidString }
    static func id(from s: String) -> UUID? { s.hasPrefix(prefix) ? UUID(uuidString: String(s.dropFirst(prefix.count))) : nil }
}

enum TrackDrag {
    static let prefix = "editmax-track:"
    static func string(_ id: UUID) -> String { prefix + id.uuidString }
    static func id(from s: String) -> UUID? { s.hasPrefix(prefix) ? UUID(uuidString: String(s.dropFirst(prefix.count))) : nil }
}

enum Timecode {
    static func string(_ seconds: Double, fps: Double = 30) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60, sec = Int(s) % 60, f = Int((s - floor(s)) * fps)
        return String(format: "%02d:%02d.%02d", m, sec, f)
    }
}
