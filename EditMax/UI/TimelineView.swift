import SwiftUI

struct TimelineView: View {
    @ObservedObject var document: EditMaxDocument
    @ObservedObject var player: PlayerController
    @EnvironmentObject var state: EditorState

    private let headerWidth: CGFloat = 90
    private let rowHeight: CGFloat = 54
    private let rulerHeight: CGFloat = 24

    private var pps: CGFloat { CGFloat(state.pixelsPerSecond) }
    private var contentWidth: CGFloat { max(800, CGFloat(document.project.duration + 10) * pps) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    headers.frame(width: headerWidth)
                    ZStack(alignment: .topLeading) {
                        tracksArea
                        playhead
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }.keyboardShortcut(.space, modifiers: []).pointer()
            Button { player.step(frames: -1, fps: document.project.settings.fps) } label: { Image(systemName: "backward.frame") }.pointer()
            Button { player.step(frames: 1, fps: document.project.settings.fps) } label: { Image(systemName: "forward.frame") }.pointer()
            Text(Timecode.string(player.currentTime, fps: document.project.settings.fps)).monospacedDigit().frame(width: 90, alignment: .leading)
            Text("/ \(Timecode.string(document.project.duration, fps: document.project.settings.fps))").monospacedDigit().foregroundStyle(.secondary)
            Divider().frame(height: 16)
            Button("Split", systemImage: "scissors") { splitAtPlayhead() }.keyboardShortcut("s", modifiers: []).disabled(state.selectedClipIDs.isEmpty).pointer()
            Button("Delete", systemImage: "trash") { deleteSelection() }.keyboardShortcut(.delete, modifiers: []).disabled(state.selectedClipIDs.isEmpty && state.selectedTextID == nil).pointer()
            Button("Close gaps", systemImage: "arrow.left.and.line.vertical.and.arrow.right") { closeGaps() }.pointer()
            Spacer()
            Slider(value: $state.pixelsPerSecond, in: 10...400).frame(width: 140)
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var headers: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            ForEach(document.project.tracks) { track in
                HStack {
                    Text(track.name).font(.caption.bold())
                    Spacer()
                    Button { toggleMute(track) } label: { Image(systemName: track.isMuted ? "speaker.slash" : "speaker.wave.2") }.buttonStyle(.borderless).font(.caption).pointer()
                }
                .padding(.horizontal, 8).frame(height: rowHeight)
                Divider()
            }
            HStack { Text("Text").font(.caption.bold()); Spacer() }.padding(.horizontal, 8).frame(height: rowHeight)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var tracksArea: some View {
        VStack(spacing: 0) {
            ruler.frame(height: rulerHeight)
            ForEach(document.project.tracks) { track in
                ZStack(alignment: .leading) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { location in seek(x: location.x); state.selectedClipIDs = []; state.selectedTextID = nil }
                    ForEach(track.clips) { clip in clipView(clip, track: track) }
                }
                .frame(height: rowHeight)
                Divider()
            }
            ZStack(alignment: .leading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { location in seek(x: location.x); state.selectedClipIDs = []; state.selectedTextID = nil }
                ForEach(document.project.texts) { t in textView(t) }
            }
            .frame(height: rowHeight)
        }
    }

    private var ruler: some View {
        Canvas { ctx, size in
            let step: Double = pps >= 120 ? 0.5 : pps >= 40 ? 1 : pps >= 20 ? 2 : 5
            var t = 0.0
            while CGFloat(t) * pps < size.width {
                let x = CGFloat(t) * pps
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height)); $0.addLine(to: CGPoint(x: x, y: size.height - 8)) }, with: .color(.secondary))
                ctx.draw(Text(Timecode.string(t)).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x + 3, y: 7), anchor: .leading)
                t += step
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in seek(x: v.location.x) })
    }

    private func clipView(_ clip: Clip, track: Track) -> some View {
        let selected = state.selectedClipIDs.contains(clip.id)
        let w = max(4, CGFloat(clip.duration) * pps)
        return RoundedRectangle(cornerRadius: 5)
            .fill(track.kind == .video ? Color.blue.opacity(selected ? 0.9 : 0.6) : Color.green.opacity(selected ? 0.9 : 0.6))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.white : Color.clear, lineWidth: 1.5))
            .overlay(alignment: .leading) { Text(clip.name).font(.caption).lineLimit(1).padding(.horizontal, 6).foregroundStyle(.white) }
            .frame(width: w, height: rowHeight - 10)
            .offset(x: CGFloat(clip.start) * pps)
            .onTapGesture { select(clip.id) }
            .gesture(DragGesture(minimumDistance: 3).onEnded { v in
                let newStart = max(0, clip.start + Double(v.translation.width) / Double(pps))
                try? ToolExecutor(document: document, origin: .user).moveClip(clip.id.uuidString, to: (newStart * 100).rounded() / 100)
            })
            .help("\(clip.name)  \(Timecode.string(clip.start)) → \(Timecode.string(clip.end))").pointer()
    }

    private func textView(_ t: TextOverlay) -> some View {
        let selected = state.selectedTextID == t.id
        return RoundedRectangle(cornerRadius: 5)
            .fill(Color.orange.opacity(selected ? 0.95 : 0.65))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.white : Color.clear, lineWidth: 1.5))
            .overlay(alignment: .leading) { Text(t.text).font(.caption).lineLimit(1).padding(.horizontal, 6).foregroundStyle(.white) }
            .frame(width: max(4, CGFloat(t.duration) * pps), height: rowHeight - 10)
            .offset(x: CGFloat(t.start) * pps)
            .onTapGesture { state.selectedTextID = t.id; state.selectedClipIDs = [] }.pointer()
    }

    private var playhead: some View {
        Rectangle().fill(Color.red).frame(width: 1.5)
            .offset(x: CGFloat(player.currentTime) * pps)
            .allowsHitTesting(false)
    }

    // MARK: actions
    private func seek(x: CGFloat) { player.pause(); player.seek(to: Double(max(0, x) / pps)) }
    private func select(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.shift) { state.selectedClipIDs.formSymmetricDifference([id]) } else { state.selectedClipIDs = [id] }
        state.selectedTextID = nil
    }
    private func splitAtPlayhead() {
        let x = ToolExecutor(document: document, origin: .user)
        for id in state.selectedClipIDs { try? x.splitClip(id.uuidString, at: player.currentTime) }
    }
    private func deleteSelection() {
        let x = ToolExecutor(document: document, origin: .user)
        if !state.selectedClipIDs.isEmpty { try? x.removeClips(state.selectedClipIDs.map(\.uuidString)); state.selectedClipIDs = [] }
        if let t = state.selectedTextID { try? x.removeTexts([t.uuidString]); state.selectedTextID = nil }
    }
    private func closeGaps() {
        let x = ToolExecutor(document: document, origin: .user)
        for t in document.project.tracks { try? x.rippleTrack(t.id.uuidString) }
    }
    private func toggleMute(_ track: Track) {
        document.apply(track.isMuted ? "Unmute \(track.name)" : "Mute \(track.name)", origin: .user) { p in
            if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].isMuted.toggle() }
        }
    }
}