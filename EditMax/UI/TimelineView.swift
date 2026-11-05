import SwiftUI

struct TimelineView: View {
    @ObservedObject var document: EditMaxDocument
    @ObservedObject var player: PlayerController
    @EnvironmentObject var state: EditorState
    @ObservedObject private var waveforms = WaveformStore.shared
    @ObservedObject private var thumbnails = ThumbnailStore.shared
    @State private var scroll = ScrollPosition()
    @State private var visibleX: ClosedRange<CGFloat> = 0...0

    private let headerWidth: CGFloat = 124
    private let rowHeight: CGFloat = 66
    private let rulerHeight: CGFloat = 24

    private var pps: CGFloat { CGFloat(state.pixelsPerSecond) }
    private var contentWidth: CGFloat { max(800, CGFloat(document.project.duration + 10) * pps) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                // Track headers stay put while the lanes scroll sideways; both scroll together vertically.
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        headers.frame(width: headerWidth).frame(minHeight: geo.size.height, alignment: .top)
                        ScrollView(.horizontal) {
                            // The lanes, grid and playhead fill the whole pane, so an empty project still reads as a timeline.
                            ZStack(alignment: .topLeading) {
                                grid
                                tracksArea
                                playhead
                            }
                            .frame(width: contentWidth, alignment: .topLeading).frame(minHeight: geo.size.height, alignment: .topLeading)
                        }
                        .scrollPosition($scroll)
                        .onScrollGeometryChange(for: ClosedRange<CGFloat>.self) { g in g.contentOffset.x...(g.contentOffset.x + g.containerSize.width) } action: { _, new in visibleX = new }
                        .onChange(of: player.currentTime) { _, t in followPlayhead(t) }
                    }
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
                HStack(spacing: 4) {
                    Image(systemName: track.kind == .video ? "film" : "waveform").font(.caption2).foregroundStyle(.secondary)
                    Text(track.name).font(.caption.bold()).lineLimit(1).fixedSize()
                    Spacer()
                    if track.kind == .video {
                        Button { toggleHidden(track) } label: { Image(systemName: track.isHidden ? "eye.slash" : "eye") }.buttonStyle(.borderless).font(.caption).help("Show or hide this track").pointer()
                    }
                    Button { toggleMute(track) } label: { Image(systemName: track.isMuted ? "speaker.slash" : "speaker.wave.2") }.buttonStyle(.borderless).font(.caption).help("Mute or unmute this track").pointer()
                }
                .padding(.horizontal, 8).frame(height: rowHeight)
                Divider()
            }
            HStack { Text("Text").font(.caption.bold()); Spacer() }.padding(.horizontal, 8).frame(height: rowHeight)
            Divider()
            HStack(spacing: 4) {
                Button { addTrack(.video) } label: { Label("Video", systemImage: "plus").font(.caption2).fixedSize() }.help("Add a video track").pointer()
                Button { addTrack(.audio) } label: { Label("Audio", systemImage: "plus").font(.caption2).fixedSize() }.help("Add an audio track").pointer()
            }
            .buttonStyle(.borderless).labelStyle(.titleAndIcon).padding(.horizontal, 8).frame(height: 28)
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Time ticks and lane stripes behind the clips, covering the full pane height.
    private var grid: some View {
        Canvas { ctx, size in
            let step: Double = pps >= 120 ? 0.5 : pps >= 40 ? 1 : pps >= 20 ? 2 : 5
            var y = rulerHeight
            var lane = 0
            while y < size.height {   // alternating lane stripes continue below the last track
                if lane % 2 == 1 { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)), with: .color(.primary.opacity(0.03))) }
                y += rowHeight + 1; lane += 1
            }
            var t = 0.0
            while CGFloat(t) * pps < size.width {
                let x = CGFloat(t) * pps
                let major = t.truncatingRemainder(dividingBy: step * 5) == 0
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: rulerHeight)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.primary.opacity(major ? 0.12 : 0.05)))
                t += step
            }
        }
        .allowsHitTesting(false)
    }

    /// Keeps the playhead in view: when it leaves the visible range (playback, seeking from the agent), the lanes scroll
    /// so it sits a little in from the left edge.
    private func followPlayhead(_ t: Double) {
        let x = CGFloat(t) * pps
        guard visibleX.upperBound > visibleX.lowerBound, !visibleX.contains(x) else { return }
        DebugLog.event("timeline-follow", ["t": t, "x": Double(x), "from": Double(visibleX.lowerBound), "to": Double(visibleX.upperBound)])
        scroll.scrollTo(x: max(0, x - 80))
    }

    private func addTrack(_ kind: TrackKind) {
        document.apply(kind == .video ? "Add video track" : "Add audio track", origin: .user) { p in _ = p.addTrack(kind: kind) }
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
            Divider()
            // Below the last lane: still the timeline (click to seek, deselect).
            Color.clear.contentShape(Rectangle()).frame(maxHeight: .infinity)
                .onTapGesture { location in seek(x: location.x); state.selectedClipIDs = []; state.selectedTextID = nil }
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
        let asset = document.project.asset(clip.assetID)
        let peaks = waveforms.peaks[clip.assetID] ?? []
        let strip = thumbnails.strips[clip.assetID]
        let h = rowHeight - 10
        let waveBand: CGFloat = track.kind == .video ? 18 : h   // video: frames on top, audio in a band below; audio: the whole clip
        let base = track.kind == .video ? Color(red: 0.16, green: 0.32, blue: 0.62) : Color(red: 0.15, green: 0.45, blue: 0.3)
        return RoundedRectangle(cornerRadius: 6)
            .fill(base.opacity(selected ? 1 : 0.85))
            .overlay {
                VStack(spacing: 0) {
                    if track.kind == .video {
                        ZStack {
                            Color.black.opacity(0.25)
                            if let strip, !strip.frames.isEmpty {
                                ThumbnailStripView(strip: strip, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut)
                            }
                        }
                        .frame(height: h - waveBand)
                    }
                    ZStack {
                        if track.kind == .video { Color.black.opacity(0.35) }
                        if !peaks.isEmpty {
                            WaveformView(peaks: peaks, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, color: .white.opacity(track.kind == .video ? 0.75 : 0.8))
                                .padding(.vertical, track.kind == .video ? 2 : 6)
                        }
                    }
                    .frame(height: waveBand)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.white : Color.white.opacity(0.12), lineWidth: selected ? 1.5 : 0.5))
            .overlay(alignment: .topLeading) {
                Text(clip.name).font(.caption2.weight(.medium)).lineLimit(1).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
            .onAppear { if let asset { waveforms.request(asset); thumbnails.request(asset) } }
            .frame(width: w, height: h)
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
            .fill((t.isCaption ? Color.teal : Color.orange).opacity(selected ? 0.95 : 0.65))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.white : Color.clear, lineWidth: 1.5))
            .overlay(alignment: .leading) { Text(t.text).font(.caption).lineLimit(1).padding(.horizontal, 6).foregroundStyle(.white) }
            .frame(width: max(4, CGFloat(t.duration) * pps), height: rowHeight - 10)
            .offset(x: CGFloat(t.start) * pps)
            .onTapGesture { state.selectedTextID = t.id; state.selectedClipIDs = [] }.pointer()
    }

    private var playhead: some View {
        Rectangle().fill(Color.red).frame(width: 1.5).frame(maxHeight: .infinity)
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
    private func toggleHidden(_ track: Track) {
        document.apply(track.isHidden ? "Show \(track.name)" : "Hide \(track.name)", origin: .user) { p in
            if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].isHidden.toggle() }
        }
    }
    private func toggleMute(_ track: Track) {
        document.apply(track.isMuted ? "Unmute \(track.name)" : "Mute \(track.name)", origin: .user) { p in
            if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].isMuted.toggle() }
        }
    }
}