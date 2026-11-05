import SwiftUI
import UniformTypeIdentifiers

struct AssetsSidebar: View {
    @ObservedObject var document: EditMaxDocument
    @EnvironmentObject var state: EditorState
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Media").font(.headline)
                Spacer()
                Button { importing = true } label: { Image(systemName: "plus") }.help("Import media").pointer()
            }
            .padding(10)
            List(document.project.assets) { asset in
                HStack(spacing: 8) {
                    Image(systemName: asset.kind == .video ? "film" : asset.kind == .audio ? "waveform" : "photo").frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.name).lineLimit(1)
                        Text(subtitle(asset)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { add(asset) } label: { Image(systemName: "arrow.down.to.line") }.buttonStyle(.borderless).help("Add to timeline").pointer()
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { add(asset) }.pointer()
            }
            .listStyle(.sidebar)
            if document.project.assets.isEmpty {
                Text("Drop files here or press +").font(.caption).foregroundStyle(.secondary).padding()
            }
        }
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

enum Timecode {
    static func string(_ seconds: Double, fps: Double = 30) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60, sec = Int(s) % 60, f = Int((s - floor(s)) * fps)
        return String(format: "%02d:%02d.%02d", m, sec, f)
    }
}
