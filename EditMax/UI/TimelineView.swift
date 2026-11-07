import SwiftUI
import UniformTypeIdentifiers

struct TimelineView: View {
    @ObservedObject var document: EditMaxDocument
    /// Not observed: the player publishes its time 30 times a second while playing, and re-rendering the whole timeline
    /// for each tick froze long timelines. Only the views that show the time watch it (`PlayerReader`).
    let player: PlayerController
    @EnvironmentObject var state: EditorState
    @ObservedObject private var waveforms = WaveformStore.shared
    @ObservedObject private var thumbnails = ThumbnailStore.shared
    @State private var scroll = ScrollPosition()
    /// What part of the lanes is on screen. Only the views that draw along the time axis read it (ruler, grid, clip
    /// bodies), so a scroll redraws them and not the whole timeline.
    @State private var viewport = TimelineViewport()
    @State private var dropLane: UUID?          // lane under a drag, for the highlight (nil id = the default lane)
    @State private var dropError: String?
    @State private var trackDropTarget: UUID?   // header row a dragged track hovers over
    @State private var hoveredHeader: UUID?
    // Renaming a track in its header: which one, the text being typed, and why the last try was refused.
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var renameError: String?
    @FocusState private var renameFocused: Bool
    /// How far the lanes are scrolled down: the ruler and the corner above the headers are held at the top by it.
    @State private var vertical = PinnedOffset()
    private var actions: EditorActions { EditorActions(document: document, state: state, player: player) }

    private let headerWidth: CGFloat = 150
    private let rowHeight: CGFloat = 66
    /// Two bands: timecodes along the top, marker pins and names along the bottom, so a marker never covers a time.
    private let rulerHeight: CGFloat = 30

    private var pps: CGFloat { CGFloat(state.pixelsPerSecond) }
    private var fps: Double { document.project.settings.fps }
    private var contentWidth: CGFloat { max(800, CGFloat(document.project.duration + 10) * pps) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                // Track headers stay put while the lanes scroll sideways; both scroll together vertically. The ruler
                // scrolls sideways with the lanes (it lives in their scroll view) and is held at the top when they
                // scroll down, as is the corner above the headers.
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        headers.frame(width: headerWidth, alignment: .leading).clipped().frame(minHeight: geo.size.height, alignment: .top)
                            .overlay(alignment: .top) { PinnedToTop(offset: vertical) { corner } }
                        ScrollView(.horizontal) {
                            // The lanes, grid and playhead fill the whole pane, so an empty project still reads as a timeline.
                            ZStack(alignment: .topLeading) {
                                grid
                                tracksArea
                                playhead
                                PinnedToTop(offset: vertical) { rulerStrip }
                            }
                            .frame(width: max(contentWidth, geo.size.width - headerWidth), alignment: .topLeading).frame(minHeight: geo.size.height, alignment: .topLeading)
                        }
                        .scrollPosition($scroll)
                        .onScrollGeometryChange(for: ClosedRange<CGFloat>.self) { g in g.contentOffset.x...(g.contentOffset.x + g.containerSize.width) } action: { _, new in viewport.scrolled(to: new) }
                        .background { PlayerReader(player: player) { p in Color.clear.onChange(of: p.currentTime) { _, t in followPlayhead(t) } } }
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { g in max(0, g.contentOffset.y + g.contentInsets.top) } action: { _, y in vertical.y = y }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    /// Above the headers, level with the ruler: opaque, so header rows scrolled up pass under it.
    private var corner: some View {
        Rectangle().fill(Color(nsColor: .controlBackgroundColor))
            .frame(width: headerWidth, height: rulerHeight)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1) }
    }

    /// The ruler and the playhead's head, on an opaque ground so lanes scrolled up pass under them.
    private var rulerStrip: some View {
        ZStack(alignment: .topLeading) {
            ruler
            playheadHead
        }
        .frame(height: rulerHeight)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// Fixed strip above the ruler: transport | timecode HUD | undo/redo | icon-only edit actions in purpose groups | zoom.
    /// Standard bordered/plain controls, not glass: nothing here floats over content.
    private var toolbar: some View {
        let fps = document.project.settings.fps
        return HStack(spacing: 12) {
            // Transport: one compact group on a faint plate.
            HStack(spacing: 0) {
                toolButton("backward.frame", help: "Previous frame", id: "toolbar.stepBack") { player.step(frames: -1, fps: fps) }
                PlayerReader(player: player) { p in toolButton(p.isPlaying ? "pause.fill" : "play.fill", help: "Play or pause (space)", id: "toolbar.play", width: 28) { p.togglePlay() } }
                toolButton("forward.frame", help: "Next frame", id: "toolbar.stepForward") { player.step(frames: 1, fps: fps) }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Timecode HUD: the current time prominent, the duration secondary.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PlayerReader(player: player) { p in Text(Timecode.string(p.currentTime, fps: fps)).font(.system(size: 13, weight: .semibold, design: .monospaced)).monospacedDigit() }
                Text(Timecode.string(document.project.duration, fps: fps)).font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
            }
            .fixedSize()   // a narrow timeline (the mixer open) squeezes the zoom slider, never the time
            .padding(.horizontal, 10).frame(height: 24)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .help("Playhead / project duration")
            toolbarSeparator
            HStack(spacing: 0) {
                toolButton("arrow.uturn.backward", help: document.undoLabel.map { "Undo \($0) (⌘Z)" } ?? "Undo (⌘Z)", id: "toolbar.undo", disabled: !document.canUndo) { document.undo() }
                toolButton("arrow.uturn.forward", help: document.redoLabel.map { "Redo \($0) (⇧⌘Z)" } ?? "Redo (⇧⌘Z)", id: "toolbar.redo", disabled: !document.canRedo) { document.redo() }
            }
            toolbarSeparator
            // Editing actions, grouped by purpose: cut & remove | add | range.
            HStack(spacing: 0) {
                toolButton("scissors", help: "Split the selected clip at the playhead (S)", id: "toolbar.split", disabled: state.selectedClipIDs.isEmpty) { actions.splitAtPlayhead() }
                toolButton("trash", help: "Delete the selection (⌫)", id: "toolbar.delete", disabled: state.selectedClipIDs.isEmpty && state.selectedTextID == nil) { actions.deleteSelection() }
                toolButton("arrow.left.and.line.vertical.and.arrow.right", help: "Remove the empty space between clips", id: "toolbar.closeGaps") { actions.closeGaps() }
            }
            toolbarSeparator
            HStack(spacing: 0) {
                toolButton("square.on.square.dashed", help: "Cross dissolve into the selected clip from the one before it; a transition already there is kept (⌘T)", id: "toolbar.transition", disabled: state.selectedClipIDs.isEmpty) { actions.addTransition() }
                toolButton("flag", help: "Add a marker at the playhead (M)", id: "toolbar.marker") { actions.addMarker() }
            }
            toolbarSeparator
            toolButton("scissors.badge.ellipsis", help: "Ripple out everything between the in and out points (I and O set them, X clears)", id: "toolbar.deleteRange", disabled: !actions.hasRange) { actions.deleteRange() }
            toolbarSeparator
            MixerToggleButton()
            TrimToolPicker(tool: $state.editTool)   // select / roll / slip / slide (TrimTools.swift)
            Spacer(minLength: 8)
            // Zoom: − slider + at the far right.
            HStack(spacing: 4) {
                toolButton("minus", help: "Zoom out", id: "toolbar.zoomOut", width: 20) { state.pixelsPerSecond = max(10, state.pixelsPerSecond / 1.4) }
                Slider(value: $state.pixelsPerSecond, in: 10...400).frame(width: 110).controlSize(.small).help("Timeline zoom").pointer().uiFrame("toolbar.zoom")
                toolButton("plus", help: "Zoom in", id: "toolbar.zoomIn", width: 20) { state.pixelsPerSecond = min(400, state.pixelsPerSecond * 1.4) }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var toolbarSeparator: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14)
    }

    /// One icon-only toolbar button: 24×22 hit area, medium symbol, help text, and the pointer/disabled/uiFrame chain in the required order.
    private func toolButton(_ symbol: String, help: String, id: String, width: CGFloat = 24, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).imageScale(.medium)
                .frame(width: width, height: 22)
                .contentShape(Rectangle())
        }
        .focusable(false)
        .help(help)
        .pointer().disabled(disabled)
        .uiFrame(id)
    }

    private var headers: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)   // under the pinned corner; rows then line up with the lanes
            ForEach(document.project.rows) { row in
                switch row {
                case .text: textHeader
                case .track(let track): trackHeader(track)
                }
                Divider()
            }
            addTrackRow
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .trailing) { Divider() }
    }

    /// The row whose selection the user is working in: a track holding a selected clip, or the Text lane with a selected title.
    private func isActiveRow(_ id: UUID) -> Bool {
        if id == Project.textRowID { return state.selectedTextID != nil }
        guard let track = document.project.track(id) else { return false }
        return track.clips.contains { state.selectedClipIDs.contains($0.id) }
    }

    /// Name 12 pt semibold over the kind 10 pt secondary; mute/hide in a fixed trailing column so the icons line up across rows.
    private func headerTitle(_ name: String, kind: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            Text(kind).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// `on` draws the icon in `tint` (orange for hide and mute, yellow for solo, as in the mixer); `faded` greys an icon
    /// whose state is overridden elsewhere (a track silenced because another one is soloed).
    private func headerIcon(_ symbol: String, on: Bool, tint: Color = .orange, faded: Bool = false, help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium)).imageScale(.medium)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).focusable(false)
        .foregroundStyle(on ? tint : faded ? Color.secondary.opacity(0.4) : Color.secondary)
        .help(help).pointer().uiFrame(id)
    }

    private func trackHeader(_ track: Track) -> some View {
                let silencedBySolo = !track.isMuted && Mixer.isSilencedBySolo(track, in: document.project)
                return HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(hoveredHeader == track.id ? .secondary : .quaternary)
                    if renaming == track.id {
                        TextField("Name", text: $renameText)
                            .textFieldStyle(.roundedBorder).controlSize(.small).font(.system(size: 12, weight: .semibold))
                            .focused($renameFocused)
                            .onSubmit { commitRename(track) }
                            .onExitCommand { renaming = nil }
                            .onChange(of: renameFocused) { _, now in if !now, renaming == track.id { commitRename(track) } }
                            .uiFrame("header.\(track.name).name")
                    } else {
                        headerTitle(track.name, kind: track.kind == .video ? "Video" : "Audio")
                            .onTapGesture(count: 2) { startRename(track) }
                            .uiTap("header.\(track.name).title", count: 2) { startRename(track) }
                    }
                    Spacer(minLength: 2)
                    // Hide | mute | solo in fixed slots, so the icons line up across rows.
                    HStack(spacing: 0) {
                        if track.kind == .video {
                            headerIcon(track.isHidden ? "eye.slash" : "eye", on: track.isHidden, help: track.isHidden ? "Hidden; click to show" : "Hide this track", id: "header.\(track.name).hide") { toggleHidden(track) }
                        } else {
                            Color.clear.frame(width: 20, height: 20)
                        }
                        headerIcon(track.isMuted || silencedBySolo ? "speaker.slash" : "speaker.wave.2", on: track.isMuted, faded: silencedBySolo,
                                   help: track.isMuted ? "Muted; click to unmute" : silencedBySolo ? "Silent while another track is soloed; click to mute it as well" : "Mute this track",
                                   id: "header.\(track.name).mute") { toggleMute(track) }
                        headerIcon("headphones", on: track.mix.solo, tint: .yellow,
                                   help: track.mix.solo ? "Soloed: only soloed tracks are heard; click to unsolo" : "Solo: hear only this track (and any other soloed one)",
                                   id: "header.\(track.name).solo") { toggleSolo(track) }
                    }
                    .frame(width: 60)
                }
                .padding(.leading, 8).padding(.trailing, 4).frame(height: rowHeight)
                .contentShape(Rectangle())
                .onHover { hoveredHeader = $0 ? track.id : (hoveredHeader == track.id ? nil : hoveredHeader) }
                .background(trackDropTarget == track.id ? Color.accentColor.opacity(0.15) : hoveredHeader == track.id ? Color.primary.opacity(0.06) : Color.clear)
                .overlay(alignment: .leading) { if isActiveRow(track.id) { Rectangle().fill(Color.accentColor).frame(width: 2) } }
                .overlay(alignment: .top) { if trackDropTarget == track.id { Rectangle().fill(Color.accentColor).frame(height: 2) } }
                // Drag a header onto another to reorder: the top row covers the rows below it in the picture.
                .onDrag { NSItemProvider(object: TrackDrag.string(track.id) as NSString) } preview: {
                    Label(track.name, systemImage: track.kind == .video ? "film" : "waveform").padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .onDrop(of: [.utf8PlainText], delegate: TrackDrop(onHover: { trackDropTarget = $0 ? track.id : nil }, onDrop: { providers in dropRow(providers, onto: track.id) }))
                .help("Drag to reorder tracks. The top row covers the rows below it.")
                .uiFrame("header.\(track.name)")
                .contextMenu {
                    Button("Rename Track…", systemImage: "pencil") { startRename(track) }
                    Divider()
                    Button(track.isMuted ? "Unmute" : "Mute", systemImage: track.isMuted ? "speaker.wave.2" : "speaker.slash") { toggleMute(track) }
                    Button(track.mix.solo ? "Unsolo" : "Solo", systemImage: "headphones") { toggleSolo(track) }
                    if track.kind == .video { Button(track.isHidden ? "Show" : "Hide", systemImage: track.isHidden ? "eye" : "eye.slash") { toggleHidden(track) } }
                    Divider()
                    Button(track.clips.isEmpty ? "Delete track" : "Delete track and \(track.clips.count) clip\(track.clips.count == 1 ? "" : "s")", systemImage: "trash", role: .destructive) {
                        state.selectedClipIDs.subtract(track.clips.map(\.id))
                        document.apply("Delete track \(track.name)", origin: .user) { p in _ = p.removeTrack(track.id) }
                    }
                    .disabled(document.project.tracks.filter { $0.kind == track.kind }.count == 1)
                }
    }

    private func startRename(_ track: Track) {
        renameText = track.name
        renaming = track.id
        DispatchQueue.main.async { renameFocused = true }   // once the field exists
    }

    /// Return or leaving the field renames; Escape cancels. A refused name (taken, empty, "Text") says why and keeps the old one.
    private func commitRename(_ track: Track) {
        guard renaming == track.id else { return }
        renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != track.name else { return }
        do { _ = try ToolExecutor(document: document, origin: .user).renameTrack(track.id.uuidString, to: name) }
        catch { renameError = InspectorMessage.text(error) }
    }

    private var textHeader: some View {
        let id = Project.textRowID
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(hoveredHeader == id ? .secondary : .quaternary)
            headerTitle("Text", kind: "Titles & captions")   // no icons on this row, so the kind has the room
            Spacer(minLength: 2)
        }
        .padding(.leading, 8).padding(.trailing, 4).frame(height: rowHeight)
        .contentShape(Rectangle())
        .onHover { hoveredHeader = $0 ? id : (hoveredHeader == id ? nil : hoveredHeader) }
        .background(trackDropTarget == id ? Color.accentColor.opacity(0.15) : hoveredHeader == id ? Color.primary.opacity(0.06) : Color.clear)
        .overlay(alignment: .leading) { if isActiveRow(id) { Rectangle().fill(Color.accentColor).frame(width: 2) } }
        .overlay(alignment: .top) { if trackDropTarget == id { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .onDrag { NSItemProvider(object: TrackDrag.string(id) as NSString) } preview: {
            Label("Text", systemImage: "textformat").padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .onDrop(of: [.utf8PlainText], delegate: TrackDrop(onHover: { trackDropTarget = $0 ? id : nil }, onDrop: { providers in dropRow(providers, onto: id) }))
        .help("Drag to move the Text lane. Text always draws over the picture.")
        .uiFrame("header.Text")
    }

    private var addTrackRow: some View {
            HStack(spacing: 2) {
                Button { addTrack(.video) } label: { Label("Video", systemImage: "plus").font(.system(size: 11, weight: .medium)).lineLimit(1).padding(.horizontal, 4).frame(height: 20).contentShape(Rectangle()) }.focusable(false).help("Add a video track").pointer().uiFrame("addtrack.video")
                Button { addTrack(.audio) } label: { Label("Audio", systemImage: "plus").font(.system(size: 11, weight: .medium)).lineLimit(1).padding(.horizontal, 4).frame(height: 20).contentShape(Rectangle()) }.focusable(false).help("Add an audio track").pointer().uiFrame("addtrack.audio")
            }
            .buttonStyle(.plain).labelStyle(.titleAndIcon).foregroundStyle(.secondary)
            .padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading).frame(height: 32)
    }

    /// Time ticks and lane stripes behind the clips, covering the full pane height.
    private var grid: some View {
        TimelineGrid(viewport: viewport, pps: pps, rows: document.project.tracks.count + 1, rulerHeight: rulerHeight, rowHeight: rowHeight)
            .allowsHitTesting(false)
    }

    /// Keeps the playhead in view: when it leaves the visible range (playback, seeking from the agent), the lanes scroll
    /// so it sits a little in from the left edge.
    private func followPlayhead(_ t: Double) {
        let x = CGFloat(t) * pps, visible = viewport.visible
        guard visible.upperBound > visible.lowerBound, !visible.contains(x) else { return }
        DebugLog.event("timeline-follow", ["t": t, "x": Double(x), "from": Double(visible.lowerBound), "to": Double(visible.upperBound)])
        scroll.scrollTo(x: max(0, x - 80))
    }

    private func addTrack(_ kind: TrackKind) {
        document.apply(kind == .video ? "Add video track" : "Add audio track", origin: .user) { p in _ = p.addTrack(kind: kind) }
    }

    /// Clips and texts get views only inside the drawn span (and when selected, so a drag keeps its bar): an 18-hour
    /// stream cut by silence removal is thousands of clips, and every view costs layout on each playhead tick.
    /// Reading `viewport.drawn` here rebuilds the lanes once per 2048-pt tile crossed, not per scroll step.
    private func inDrawnSpan(_ start: Double, _ end: Double, _ span: ClosedRange<CGFloat>) -> Bool {
        CGFloat(end) * pps >= span.lowerBound && CGFloat(start) * pps <= span.upperBound
    }

    private var tracksArea: some View {
        let span = viewport.drawn
        return VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)   // the ruler itself is pinned above the lanes (rulerStrip)
            ForEach(document.project.rows) { row in
                switch row {
                case .track(let track):
                    ZStack(alignment: .leading) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { location in seek(x: location.x); state.selectedClipIDs = []; state.selectedTextID = nil }
                        ForEach(track.clips.filter { inDrawnSpan($0.start, $0.end, span) || state.selectedClipIDs.contains($0.id) }) { clip in clipView(clip, track: track) }
                        if track.kind == .video, track.clips.contains(where: \.hasSplitEdit) { SplitEditLane(clips: track.clips, project: document.project, pps: pps, rowHeight: rowHeight, barHeight: rowHeight - 10, peaks: waveforms.peaks) }
                    }
                    .frame(height: rowHeight)
                    .background(dropLane == track.id ? Color.accentColor.opacity(0.15) : Color.clear)
                    .onDrop(of: [.utf8PlainText, .fileURL], delegate: LaneDrop(lane: track.id, onHover: { dropLane = $0 ? track.id : nil }, onDrop: { providers, x in drop(providers, track: track, x: x) }))
                    .uiFrame("lane.\(track.name)")
                case .text:
                    ZStack(alignment: .leading) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { location in seek(x: location.x); state.selectedClipIDs = []; state.selectedTextID = nil }
                        let rows = TextLayout.laneRows(document.project.texts)
                        let stacked = rows.values.contains(1)
                        ForEach(document.project.texts.filter { inDrawnSpan($0.start, $0.end, span) || state.selectedTextID == $0.id }) { t in
                            // Concurrent texts take two sub-rows so neither bar covers the other; alone, a bar sits centred.
                            textView(t).offset(y: stacked ? (rows[t.id] == 1 ? 16.5 : -16.5) : 0)
                        }
                    }
                    .frame(height: rowHeight)
                    .uiFrame("lane.Text")
                }
                Divider()
            }
            if document.project.allClips.isEmpty {
                Text("Drag media from the left panel onto a lane, or double-click a file to add it").font(.system(size: 12)).foregroundStyle(.tertiary)
                    .padding(.leading, 16).padding(.top, 10).allowsHitTesting(false)
            }
            // Below the last lane: still the timeline (click to seek, deselect, drop onto the default track).
            Color.clear.contentShape(Rectangle()).frame(maxHeight: .infinity)
                .onTapGesture { location in seek(x: location.x); state.selectedClipIDs = []; state.selectedTextID = nil }
                .onDrop(of: [.utf8PlainText, .fileURL], delegate: LaneDrop(lane: nil, onHover: { _ in }, onDrop: { providers, x in drop(providers, track: nil, x: x) }))
        }
        .alert("Could not rename the track", isPresented: .init(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) { Button("OK") {} } message: { Text(renameError ?? "") }
        .alert("Could not add to timeline", isPresented: .init(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) { Button("OK") {} } message: { Text(dropError ?? "") }
    }

    /// A media-panel asset or Finder files dropped on a lane: placed at the drop time on that track (a track of the right
    /// kind when the lane does not match, e.g. audio onto a video lane). A drop inside an existing clip lands after it.
    private func drop(_ providers: [NSItemProvider], track: Track?, x: CGFloat) -> Bool {
        let time = max(0, (Double(x / pps) * 100).rounded() / 100)
        DebugLog.event("drop", ["lane": track?.name ?? "default", "x": Double(x), "time": time, "types": providers.flatMap(\.registeredTypeIdentifiers).joined(separator: ",")])
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
                handled = true
                p.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier) { item, _ in
                    let s = (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? (item as? String)
                    guard let s, let id = AssetDrag.id(from: s) else { return }   // a track-header drag has no asset id and is ignored
                    Task { @MainActor in place(assetID: id, track: track, at: time) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        do {
                            let imported = try await ToolExecutor(document: document, origin: .user).importMedia(paths: [url.path])
                            if let first = imported.first, let id = UUID(uuidString: first.id) ?? document.project.assets.first(where: { $0.path == url.path })?.id { place(assetID: id, track: track, at: time) }
                        } catch { dropError = error.localizedDescription }
                    }
                }
            }
        }
        return handled
    }

    private func place(assetID: UUID, track: Track?, at time: Double) {
        guard let asset = document.project.asset(assetID) else { return }
        let kind: TrackKind = asset.kind == .audio ? .audio : .video
        let target = (track?.kind == kind ? track : nil) ?? document.project.defaultTrack(of: kind)
        var start = time
        if let target, let under = target.clips.first(where: { $0.start < start && $0.end > start }) { start = under.end }
        do { try ToolExecutor(document: document, origin: .user).insertClip(asset: assetID.uuidString, track: target?.id.uuidString, at: start) }
        catch { dropError = error.localizedDescription }
    }

    /// A header (track or the Text lane) dropped onto another row takes that row's place.
    private func dropRow(_ providers: [NSItemProvider], onto target: UUID) -> Bool {
        guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) }) else { return false }
        p.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier) { item, _ in
            let s = (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? (item as? String)
            guard let s, let id = TrackDrag.id(from: s), id != target else { return }
            Task { @MainActor in
                guard let to = document.project.rows.firstIndex(where: { $0.id == target }) else { return }
                let name = id == Project.textRowID ? "Text lane" : "track \(document.project.track(id)?.name ?? "")"
                document.apply("Move \(name)", origin: .user) { p in _ = p.moveRow(id, toRow: to) }
            }
        }
        return true
    }

    private struct TrackDrop: DropDelegate {
        let onHover: (Bool) -> Void
        let onDrop: ([NSItemProvider]) -> Bool
        func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.utf8PlainText]) }
        func dropEntered(info: DropInfo) { onHover(true) }
        func dropExited(info: DropInfo) { onHover(false) }
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
        func performDrop(info: DropInfo) -> Bool { onHover(false); return onDrop(info.itemProviders(for: [.utf8PlainText])) }
    }

    /// Drop handling for one lane: reports hover for the highlight and hands the providers plus the drop x to the view.
    private struct LaneDrop: DropDelegate {
        let lane: UUID?
        let onHover: (Bool) -> Void
        let onDrop: ([NSItemProvider], CGFloat) -> Bool
        func dropEntered(info: DropInfo) { DebugLog.event("drag-enter", ["lane": lane?.uuidString ?? "default"]); onHover(true) }
        func dropExited(info: DropInfo) { onHover(false) }
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
        func performDrop(info: DropInfo) -> Bool {
            onHover(false)
            return onDrop(info.itemProviders(for: [.utf8PlainText, .fileURL]), info.location.x)
        }
    }

    private var ruler: some View {
        TimelineRuler(viewport: viewport, pps: pps, fps: fps, inPoint: state.inPoint, outPoint: state.outPoint, markers: document.project.markers)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in seek(x: v.location.x) })
        .contextMenu {
            Button("Add marker here", systemImage: "flag") { actions.addMarker() }
            Button("Set in point", systemImage: "arrow.right.to.line") { actions.setIn() }
            Button("Set out point", systemImage: "arrow.left.to.line") { actions.setOut() }
            if actions.hasRange { Button("Delete range", systemImage: "scissors.badge.ellipsis", role: .destructive) { actions.deleteRange() } }
            if state.inPoint != nil || state.outPoint != nil { Button("Clear in/out", systemImage: "xmark") { actions.clearInOut() } }
            if !document.project.markers.isEmpty {
                Divider()
                ForEach(document.project.markers) { m in
                    Button("Remove marker \(m.name.isEmpty ? Timecode.string(m.time, fps: fps) : m.name)", systemImage: "flag.slash") { document.apply("Remove marker", origin: .user) { p in p.markers.removeAll { $0.id == m.id } } }
                }
            }
        }
        .uiFrame("ruler")
    }

    private func clipView(_ clip: Clip, track: Track) -> some View {
        let selected = state.selectedClipIDs.contains(clip.id)
        let asset = document.project.asset(clip.assetID)
        let x = ToolExecutor(document: document, origin: .user)
        return TimelineBar(id: clip.id, uiID: "clip.\(clip.id.short)", start: clip.start, duration: clip.duration, pps: pps, height: rowHeight - 10,
                           minStart: TrimLimitsUI.minStart(clip, asset: asset, project: document.project),
                           maxEnd: TrimLimitsUI.maxEnd(clip, asset: asset, project: document.project),
                           help: "\(clip.name)  \(Timecode.string(clip.start, fps: fps)) → \(Timecode.string(clip.end, fps: fps))",
                           snaps: { snapTimes(excluding: clip.id) },
                           onSelect: { drag in select(clip.id, keepGroup: drag) },
                           onMove: { newStart in
                               let group = state.selectedClipIDs
                               if group.count > 1, group.contains(clip.id) {
                                   document.apply("Move \(group.count) clips", origin: .user) { p in p.moveClips(group, by: newStart - clip.start) }
                               } else { try? x.moveClip(clip.id.uuidString, to: newStart) }
                           },
                           onTrimStart: { try? x.trimClip(clip.id.uuidString, start: $0, end: nil) },
                           onTrimEnd: { try? x.trimClip(clip.id.uuidString, start: nil, end: $0) },
                           editing: BarEditing.make(clip: clip, track: track, document: document, tool: state.editTool, strip: thumbnails.strips[clip.assetID], peaks: waveforms.peaks[clip.assetID] ?? []),
                           viewport: viewport) {
            ClipBody(clip: clip, kind: track.kind, selected: selected, height: rowHeight - 10, pps: pps,
                     peaks: waveforms.peaks[clip.assetID] ?? [], strip: thumbnails.strips[clip.assetID],
                     off: ClipBody.Off(track: track, in: document.project), viewport: viewport)
                .equatable()
                .onAppear { if let asset { waveforms.request(asset); thumbnails.request(asset) } }
                .contextMenu {
            PlayerReader(player: player) { p in
                Button("Split at playhead", systemImage: "scissors") { select(clip.id, keepGroup: false); try? x.splitClip(clip.id.uuidString, at: p.currentTime) }
                    .disabled(p.currentTime <= clip.start + 0.01 || p.currentTime >= clip.end - 0.01)
            }
            Button("Go to start", systemImage: "arrow.left.to.line") { player.pause(); player.seek(to: clip.start) }
            Menu("Transition in") {
                ForEach(Transition.Kind.allCases, id: \.self) { k in Button(k.title) { _ = try? x.setTransition(clip.id.uuidString, kind: k.rawValue, duration: nil) } }
                if clip.transitionIn != nil { Divider(); Button("Remove") { _ = try? x.setTransition(clip.id.uuidString, kind: "none", duration: nil) } }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { state.selectedClipIDs.remove(clip.id); try? x.removeClips([clip.id.uuidString]) }
                }
        }
    }

    private func textView(_ t: TextOverlay) -> some View {
        let selected = state.selectedTextID == t.id
        func edit(_ label: String, _ body: @escaping (inout TextOverlay) -> Void) {
            document.apply(label, origin: .user) { p in if let i = p.texts.firstIndex(where: { $0.id == t.id }) { body(&p.texts[i]) } }
        }
        return TimelineBar(id: t.id, uiID: "text.\(t.id.short)", start: t.start, duration: t.duration, pps: pps, height: 30, minStart: 0, maxEnd: .infinity,
                           help: "\(t.text)  \(Timecode.string(t.start, fps: fps)) → \(Timecode.string(t.end, fps: fps))", snaps: { snapTimes(excluding: t.id) },
                           onSelect: { _ in state.selectedTextID = t.id; state.selectedClipIDs = [] },
                           onMove: { s in edit("Move text to \(s)s") { $0.start = s } },
                           onTrimStart: { s in edit("Trim text") { $0.duration = t.end - s; $0.start = s } },
                           onTrimEnd: { e in edit("Trim text") { $0.duration = e - t.start } }) {
            TextBody(text: t, selected: selected).equatable()
                .contextMenu {
            Button("Show", systemImage: "eye") { player.pause(); player.seek(to: t.start + 0.05) }
            Menu("Style") {
                ForEach(CaptionPresets.all, id: \.name) { s in
                    Button(s.title) { edit("Text style") { $0.preset = s.name } }
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { if state.selectedTextID == t.id { state.selectedTextID = nil }; document.apply("Delete text", origin: .user) { p in p.texts.removeAll { $0.id == t.id } } }
                }
        }
    }

    private var playhead: some View {
        PlayerReader(player: player) { p in
            Rectangle().fill(Color.red).frame(width: 1).frame(maxHeight: .infinity).offset(x: CGFloat(p.currentTime) * pps)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    /// The playhead's head in the ruler: a small downward triangle whose tip meets the line at the ruler's bottom edge.
    private var playheadHead: some View {
        PlayerReader(player: player) { pl in
            Path { p in
                p.move(to: CGPoint(x: 0, y: rulerHeight - 8)); p.addLine(to: CGPoint(x: 10, y: rulerHeight - 8))
                p.addLine(to: CGPoint(x: 5, y: rulerHeight)); p.closeSubpath()
            }
            .fill(Color.red).frame(width: 10, height: rulerHeight).offset(x: CGFloat(pl.currentTime) * pps - 4.5)
        }
        .allowsHitTesting(false)
    }

    // MARK: actions
    private func seek(x: CGFloat) { player.pause(); player.seek(to: Double(max(0, x) / pps)) }
    /// ⇧/⌘ toggle membership; dragging a clip that is already selected keeps the group (so a group moves together).
    private func select(_ id: UUID, keepGroup: Bool) {
        let mods = UIRegistry.shared.currentModifiers
        if mods.contains(.shift) || mods.contains(.command) { state.selectedClipIDs.formSymmetricDifference([id]) }
        else if !(keepGroup && state.selectedClipIDs.contains(id)) { state.selectedClipIDs = [id] }
        state.selectedTextID = nil
    }
    /// Edges a dragged bar snaps to: every other clip and text edge, the markers, the in/out points, the playhead and 0.
    /// Asked for during a drag (not built for every bar on every render: that was clips × clips per playhead tick).
    private func snapTimes(excluding id: UUID) -> [Double] {
        var t: [Double] = [0, player.currentTime]
        for c in document.project.allClips where c.id != id { t.append(c.start); t.append(c.end) }
        for x in document.project.texts where x.id != id { t.append(x.start); t.append(x.end) }
        t.append(contentsOf: document.project.markers.map(\.time))
        if let i = state.inPoint { t.append(i) }
        if let o = state.outPoint { t.append(o) }
        return t
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
    /// The same solo as the mixer's S button (one history entry, same label).
    private func toggleSolo(_ track: Track) {
        let x = ToolExecutor(document: document, origin: .user)
        Task { _ = try? await x.setTrackMix(track.id.uuidString, gain: nil, pan: nil, solo: !track.mix.solo, mute: nil, bus: nil) }
    }
}

/// The look of a clip: frames on top and a waveform band for video, a full waveform for audio, the name in a pill.
/// Equatable, so a drag elsewhere on the timeline does not redraw every clip's canvases.
struct ClipBody: View, Equatable {
    let clip: Clip
    let kind: TrackKind
    let selected: Bool
    let height: CGFloat
    let pps: CGFloat
    let peaks: [Float]
    let strip: ThumbnailStore.Strip?
    /// What of the clip is left out of the program by its track, so the bar can say so (dimmed).
    var off = Off()
    /// The timeline's viewport: the frames and the waveform are drawn only across its span (read in `body`, so a scroll
    /// past a tile edge redraws this bar; not part of ==). nil draws the whole bar.
    var viewport: TimelineViewport? = nil

    /// A hidden track leaves its clips out of the program entirely (picture and sound); a muted track, or one silenced
    /// because another track is soloed, leaves out their sound only.
    struct Off: Equatable {
        var picture = false
        var sound = false
        init(picture: Bool = false, sound: Bool = false) { self.picture = picture; self.sound = sound }
        init(track: Track, in project: Project) {
            picture = track.isHidden
            sound = track.isHidden || track.isMuted || Mixer.isSilencedBySolo(track, in: project)
        }
        /// The whole bar dims: a hidden track, or an audio clip that is not heard.
        func whole(_ kind: TrackKind) -> Bool { picture || (kind == .audio && sound) }
    }

    static func == (a: ClipBody, b: ClipBody) -> Bool {
        a.clip == b.clip && a.kind == b.kind && a.selected == b.selected && a.height == b.height && a.pps == b.pps
            && a.peaks.count == b.peaks.count && a.strip?.frames.count == b.strip?.frames.count && a.off == b.off
    }

    /// Transition wedge at the head, fade ramps at both ends, as other editors draw them.
    private var marks: some View {
        Canvas { ctx, size in
            if let tr = clip.transitionIn {
                let w = min(size.width, CGFloat(tr.duration) * pps)
                ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: size.height)), with: .color(.white.opacity(0.22)))
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height)); $0.addLine(to: CGPoint(x: w, y: 0)) }, with: .color(.white.opacity(0.9)), lineWidth: 1)
                ctx.stroke(Path { $0.move(to: CGPoint(x: w, y: 0)); $0.addLine(to: CGPoint(x: w, y: size.height)) }, with: .color(.white.opacity(0.6)), lineWidth: 1)
            }
            if clip.fadeIn > 0 {
                let w = min(size.width, CGFloat(clip.fadeIn) * pps)
                ctx.fill(Path { $0.move(to: CGPoint(x: 0, y: size.height)); $0.addLine(to: CGPoint(x: w, y: 0)); $0.addLine(to: CGPoint(x: 0, y: 0)); $0.closeSubpath() }, with: .color(.black.opacity(0.45)))
            }
            if clip.fadeOut > 0 {
                let w = min(size.width, CGFloat(clip.fadeOut) * pps)
                ctx.fill(Path { $0.move(to: CGPoint(x: size.width, y: size.height)); $0.addLine(to: CGPoint(x: size.width - w, y: 0)); $0.addLine(to: CGPoint(x: size.width, y: 0)); $0.closeSubpath() }, with: .color(.black.opacity(0.45)))
            }
            // Multicam: a line per angle cut, labeled with the angle number.
            if let mc = clip.multicam {
                for cut in mc.cuts where cut.time >= 0 && cut.time < clip.duration {
                    let x = max(1, CGFloat(cut.time) * pps)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                    ctx.draw(Text("\(cut.angle + 1)").font(.system(size: 9, weight: .bold)).foregroundColor(.white), at: CGPoint(x: x + 8, y: 8))
                }
            }
            // Keyframes: a diamond per animated time, on a thin lane along the bottom of the bar.
            let kts = clip.keyframeTimes
            if !kts.isEmpty {
                let y = size.height - 5, r: CGFloat = 3.5
                ctx.fill(Path(CGRect(x: 0, y: size.height - 10, width: size.width, height: 10)), with: .color(.black.opacity(0.25)))
                for kt in kts where kt >= 0 && kt <= clip.duration {
                    let cx = CGFloat(kt) * pps
                    let d = Path { $0.move(to: CGPoint(x: cx, y: y - r)); $0.addLine(to: CGPoint(x: cx + r, y: y)); $0.addLine(to: CGPoint(x: cx, y: y + r)); $0.addLine(to: CGPoint(x: cx - r, y: y)); $0.closeSubpath() }
                    ctx.fill(d, with: .color(.yellow)); ctx.stroke(d, with: .color(.black.opacity(0.6)), lineWidth: 0.5)
                }
            }
        }
        .allowsHitTesting(false)
    }

    var body: some View {
        let visible = viewport?.local(start: clip.start, pps: pps, width: CGFloat(clip.duration) * pps)
        let waveBand: CGFloat = kind == .video ? 18 : height
        let base = kind == .video ? Color(red: 0.16, green: 0.32, blue: 0.62) : Color(red: 0.15, green: 0.45, blue: 0.3)
        let whole = off.whole(kind), soundBand = kind == .video && off.sound && !off.picture
        RoundedRectangle(cornerRadius: 6)
            .fill(base.opacity(selected ? 1 : 0.85))
            .overlay {
                VStack(spacing: 0) {
                    if kind == .video {
                        ZStack {
                            Color.black.opacity(0.25)
                            if let strip, !strip.frames.isEmpty {
                                ThumbnailStripView(strip: strip, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, visible: visible).equatable()
                            }
                        }
                        .frame(height: height - waveBand)
                    }
                    ZStack {
                        if kind == .video { Color.black.opacity(0.35) }
                        if !peaks.isEmpty {
                            WaveformView(peaks: peaks, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, color: .white.opacity(kind == .video ? 0.75 : 0.8), visible: visible)
                                .equatable()
                                .padding(.vertical, kind == .video ? 2 : 6)
                        }
                    }
                    .frame(height: waveBand)
                    .saturation(soundBand ? 0 : 1).opacity(soundBand ? 0.35 : 1)   // a muted video track: picture plays, sound does not
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .overlay { if clip.transitionIn != nil || clip.fadeIn > 0 || clip.fadeOut > 0 || clip.isAnimated || clip.multicam != nil { marks.clipShape(RoundedRectangle(cornerRadius: 6)) } }
            // Left out of the program (hidden track, audio not heard): greyed and faded, as other editors show a disabled
            // clip; the selection ring and the name stay readable.
            .saturation(whole ? 0.1 : 1).opacity(whole ? 0.4 : 1)
            // Selection: a slight brightening plus a 1.5 pt accent ring; at rest a hairline edge.
            .overlay { if selected { RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)).allowsHitTesting(false) } }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: selected ? 1.5 : 0.5))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    if off.picture { Image(systemName: "eye.slash").font(.system(size: 8, weight: .semibold)) }
                    else if off.sound { Image(systemName: "speaker.slash").font(.system(size: 8, weight: .semibold)) }
                    Text(clip.name).font(.caption2.weight(.medium)).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(whole ? 0.75 : 1))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(4)
            }
    }
}

/// Slim bar with a colored edge: titles orange, captions teal.
private struct TextBody: View, Equatable {
    let text: TextOverlay
    let selected: Bool
    var body: some View {
        let tint = text.isCaption ? Color.teal : Color.orange
        RoundedRectangle(cornerRadius: 4)
            .fill(tint.opacity(selected ? 0.5 : 0.28))
            .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
            .overlay { if selected { RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)) } }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : tint.opacity(0.5), lineWidth: selected ? 1.5 : 0.5))
            .overlay(alignment: .leading) {
                Label(text.text, systemImage: text.isCaption ? "captions.bubble" : "textformat").font(.system(size: 10, weight: .medium)).lineLimit(1).padding(.leading, 8).padding(.trailing, 6).foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// One movable, trimmable bar on a lane. Keeps its own drag state, so dragging re-renders this bar alone, not the
/// whole timeline; the move or trim is committed once, on release. Edges (8 pt) trim, the middle moves.
private struct TimelineBar<Content: View>: View {
    let id: UUID
    let uiID: String
    let start: Double
    let duration: Double
    let pps: CGFloat
    let height: CGFloat
    let minStart: Double      // earliest start the leading edge may reach
    let maxEnd: Double        // latest end the trailing edge may reach
    let help: String
    /// Times the dragged edges snap to, asked for when a drag needs them.
    var snaps: () -> [Double] = { [] }
    let onSelect: (_ dragging: Bool) -> Void
    let onMove: (Double) -> Void
    let onTrimStart: (Double) -> Void
    let onTrimEnd: (Double) -> Void
    var editing: BarEditing? = nil   // roll / slip / slide (TrimTools.swift); nil = move and trim only
    var viewport: TimelineViewport? = nil   // a slip's preview is drawn only across its span
    @ViewBuilder let content: () -> Content

    @State private var moveDX: CGFloat = 0
    @State private var trim: (leading: Bool, dx: CGFloat)?
    @State private var toolDrag: (kind: TrimDragKind, context: TrimDragContext, amount: Double, limited: Bool)?

    private var end: Double { start + duration }
    private var dragKey: String { "\(start)|\(duration)|\(pps)|\(minStart)|\(maxEnd)" }
    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    var body: some View {
        let fullW = CGFloat(duration) * pps
        let trimL: CGFloat = trim?.leading == true ? min(fullW - 8, max(-CGFloat(start - minStart) * pps, trim!.dx)) : 0
        let trimR: CGFloat = trim?.leading == false ? max(-fullW + 8, min(maxEnd.isFinite ? CGFloat(maxEnd - end) * pps : .infinity, trim!.dx)) : 0
        // A roll draws like a trim of the dragged edge, a slide like a move (the tools' own amounts, clamped).
        let toolPx = toolDrag.map { CGFloat($0.amount) * pps } ?? 0
        let rollL: CGFloat = toolDrag?.kind == .roll(leading: true) ? toolPx : 0, rollR: CGFloat = toolDrag?.kind == .roll(leading: false) ? toolPx : 0
        let slidePx: CGFloat = toolDrag?.kind == .slide ? toolPx : 0
        let w = max(4, fullW - trimL + trimR - rollL + rollR)
        content()
            .frame(width: w, height: height)
            .uiFrame(uiID)
            .overlay(alignment: .leading) { handle(leading: true).uiFrame(uiID + ".left") }
            .overlay(alignment: .trailing) { handle(leading: false).uiFrame(uiID + ".right") }
            .overlay(alignment: .topLeading) {
                if let d = toolDrag, let e = editing {
                    TrimFeedback(kind: d.kind, amount: d.amount, limited: d.limited, context: d.context, clip: e.clip, assetDuration: e.assetDuration,
                                 strip: e.strip, peaks: e.peaks, pps: pps, width: fullW, height: height, shift: rollL + slidePx,
                                 visible: viewport?.local(start: start, pps: pps, width: fullW))
                }
            }
            .offset(x: CGFloat(start) * pps + trimL + rollL + slidePx + max(-CGFloat(start) * pps, moveDX))
            .zIndex(toolDrag != nil || trim != nil || moveDX != 0 ? 1 : 0)
            .onTapGesture { onSelect(false) }
            .uiTap(uiID, key: dragKey) { onSelect(false) }
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { v in
                    if let k = editing?.kind(edge: nil) { toolDragChanged(k, dx: v.translation.width); return }
                    if moveDX == 0 { onSelect(true) }; moveDX = snappedMove(v.translation.width)
                }
                .onEnded { v in
                    if editing?.kind(edge: nil) != nil { toolDragEnded(); return }
                    let dx = snappedMove(v.translation.width); moveDX = 0; commitMove(dx)
                })
            .uiDrag(uiID, key: dragKey + "|\(editing?.tool.rawValue ?? "")") { dx in
                if let k = editing?.kind(edge: nil) { toolDragChanged(k, dx: dx); toolDragEnded(); return }
                onSelect(true); commitMove(snappedMove(dx))
            }
            .uiDrag(uiID + ".left", key: dragKey + "|\(editing?.tool.rawValue ?? "")") { dx in
                if let k = editing?.kind(edge: true) { toolDragChanged(k, dx: dx); toolDragEnded(); return }
                commitTrim(leading: true, dx: snappedTrim(leading: true, dx))
            }
            .uiDrag(uiID + ".right", key: dragKey + "|\(editing?.tool.rawValue ?? "")") { dx in
                if let k = editing?.kind(edge: false) { toolDragChanged(k, dx: dx); toolDragEnded(); return }
                commitTrim(leading: false, dx: snappedTrim(leading: false, dx))
            }
            .help(help).pointer()
    }

    /// A roll, slip or slide drag: limits read once at the start, the amount clamped to them (the tag says so).
    private func toolDragChanged(_ kind: TrimDragKind, dx: CGFloat) {
        guard let e = editing else { return }
        if toolDrag == nil { onSelect(true) }
        let context = toolDrag?.kind == kind ? toolDrag!.context : e.context(kind)
        var raw = e.amount(kind, dx: dx, pps: pps)
        if kind != .slip, snapping {   // the moving edge snaps like a trim
            let edge: Double = kind == .roll(leading: true) ? start : kind == .slide ? start : end
            let cand = edge + raw
            let snaps = self.snaps()
            if let s = snaps.first(where: { abs(CGFloat($0 - cand) * pps) < snapPx }) { raw = s - edge }
            else if kind == .slide, let s = snaps.first(where: { abs(CGFloat($0 - (end + raw)) * pps) < snapPx }) { raw = s - end }
        }
        let c = BarEditing.clamp(raw, context.limits)
        toolDrag = (kind, context, c.value, c.limited || context.refusal != nil)
    }
    private func toolDragEnded() {
        guard let d = toolDrag else { return }
        toolDrag = nil
        if d.context.refusal == nil { editing?.commit(d.kind, d.amount) }
    }

    private var snapPx: CGFloat { 8 }
    private var snapping: Bool { !UIRegistry.shared.currentModifiers.contains(.option) }   // ⌥ drags free

    /// A move whose leading or trailing edge lands within 8 pt of a snap time sticks to it.
    private func snappedMove(_ dx: CGFloat) -> CGFloat {
        guard snapping else { return dx }
        let cand = start + Double(dx) / Double(pps)
        for s in snaps() {
            if abs(CGFloat(cand - s) * pps) < snapPx { return CGFloat(s - start) * pps }
            if abs(CGFloat(cand + duration - s) * pps) < snapPx { return CGFloat(s - duration - start) * pps }
        }
        return dx
    }
    private func snappedTrim(leading: Bool, _ dx: CGFloat) -> CGFloat {
        guard snapping else { return dx }
        let edge = leading ? start : end
        let cand = edge + Double(dx) / Double(pps)
        for s in snaps() where abs(CGFloat(cand - s) * pps) < snapPx { return CGFloat(s - edge) * pps }
        return dx
    }

    private func commitMove(_ dx: CGFloat) {
        let newStart = round2(max(0, start + Double(dx) / Double(pps)))
        if newStart != start { onMove(newStart) }
    }

    private func commitTrim(leading: Bool, dx: CGFloat) {
        let d = Double(dx) / Double(pps)
        if leading {
            let s = round2(max(minStart, min(end - 0.1, start + d)))
            if s != start { onTrimStart(s) }
        } else {
            let e = round2(min(maxEnd, max(start + 0.1, end + d)))
            if e != end { onTrimEnd(e) }
        }
    }

    private func handle(leading: Bool) -> some View {
        let active = trim?.leading == leading || toolDrag?.kind == .roll(leading: leading)
        return Rectangle().fill(active ? Color.white.opacity(0.9) : Color.white.opacity(0.001))
            .frame(width: active ? 3 : 8)
            .contentShape(Rectangle().inset(by: -2))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            // Measured in the window's space: the handle itself moves with the live trim, which would halve its own translation.
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { v in
                    if let k = editing?.kind(edge: leading) { toolDragChanged(k, dx: v.translation.width); return }
                    trim = (leading, snappedTrim(leading: leading, v.translation.width))
                }
                .onEnded { v in
                    if editing?.kind(edge: leading) != nil { toolDragEnded(); return }
                    let dx = snappedTrim(leading: leading, v.translation.width); trim = nil; commitTrim(leading: leading, dx: dx)
                })
    }
}

/// The part of the lanes on screen, in content points, and the span worth drawing around it. A long timeline is wide
/// (18 hours at 60 pt/s is 3.9 million points), so the ruler, the grid and the clip bodies draw only `drawn`: the
/// visible part and a screen either side, widened to whole 2048-point tiles. `drawn` changes only when a scroll crosses
/// a tile edge, so a scroll redraws them a few times a screen, not every frame; `visible` itself is not observed.
@Observable final class TimelineViewport {
    static let tile: CGFloat = 2048
    @ObservationIgnored private(set) var visible: ClosedRange<CGFloat> = 0...0
    /// Before the scroll view first reports: the first two tiles.
    private(set) var drawn: ClosedRange<CGFloat> = 0...(2 * TimelineViewport.tile)

    func scrolled(to v: ClosedRange<CGFloat>) {
        visible = v
        let d = Self.span(around: v)
        if d != drawn { drawn = d }
    }

    static func span(around v: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        guard v.upperBound > v.lowerBound else { return 0...(2 * tile) }
        let w = v.upperBound - v.lowerBound
        let lo = max(0, ((v.lowerBound - w) / tile).rounded(.down) * tile)
        return lo...max(lo + tile, ((v.upperBound + w) / tile).rounded(.up) * tile)
    }

    /// `drawn` in a bar's own coordinates (its x 0 at `start` seconds, `width` wide), clamped to the bar: the whole bar
    /// when it is all in the span (so it does not redraw while the span moves), 0...0 when none of it is.
    func local(start: Double, pps: CGFloat, width: CGFloat) -> ClosedRange<CGFloat> {
        let x0 = CGFloat(start) * pps
        let lo = max(0, drawn.lowerBound - x0), hi = min(width, drawn.upperBound - x0)
        return hi > lo ? lo...hi : 0...0
    }
}

/// Lane stripes and time lines behind the clips. Background fills span the whole width (one rectangle each); the
/// lines are drawn only across the viewport's span.
private struct TimelineGrid: View {
    let viewport: TimelineViewport
    let pps: CGFloat
    let rows: Int
    let rulerHeight: CGFloat
    let rowHeight: CGFloat

    var body: some View {
        let span = viewport.drawn
        Canvas { ctx, size in
            let step: Double = pps >= 120 ? 0.5 : pps >= 40 ? 1 : pps >= 20 ? 2 : 5
            let lanesBottom = rulerHeight + CGFloat(rows) * (rowHeight + 1)
            // Lanes carry a faint fill; the space below them stays bare so the stack has a visible end.
            for lane in 0..<rows {
                let y = rulerHeight + CGFloat(lane) * (rowHeight + 1)
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)), with: .color(.primary.opacity(lane % 2 == 1 ? 0.04 : 0.02)))
            }
            // Grid lines sit well under the clips: 6 % for the step lines, 9 % on every fifth (the ruler's labelled marks).
            // Counted from 0 (k), not from the span's edge, so a line is at the same place whichever span draws it.
            let hi = min(size.width, span.upperBound)
            var k = max(0, Int((Double(span.lowerBound / pps) / step).rounded(.down)))
            while CGFloat(Double(k) * step) * pps < hi {
                let x = CGFloat(Double(k) * step) * pps + 0.5
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: rulerHeight)); $0.addLine(to: CGPoint(x: x, y: lanesBottom)) }, with: .color(.primary.opacity(k % 5 == 0 ? 0.09 : 0.06)), lineWidth: 1)
                k += 1
            }
        }
    }
}

/// Ticks, timecodes, the in/out range and markers. Ticks, labels and markers are drawn only across the viewport's span:
/// at 60 pt/s an 18-hour ruler has 65,000 labels, and laying them all out took 1.7 s per redraw.
private struct TimelineRuler: View {
    let viewport: TimelineViewport
    let pps: CGFloat
    let fps: Double
    let inPoint: Double?
    let outPoint: Double?
    let markers: [Marker]

    var body: some View {
        let span = viewport.drawn
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.18)))
            let step: Double = pps >= 120 ? 0.5 : pps >= 40 ? 1 : pps >= 20 ? 2 : 5
            let minor = step / 5
            // Timecodes in the top band; ticks and marker pins share the bottom band (markers are drawn after, on top).
            let labelY: CGFloat = 8, markerTop = size.height - 14
            let lo = span.lowerBound, hi = min(size.width, span.upperBound)
            var i = max(0, Int((Double(lo / pps) / minor).rounded(.down)))
            while CGFloat(Double(i) * minor) * pps < hi {
                let t = Double(i) * minor   // computed from the tick's index, not accumulated, so labels stay exact
                let x = CGFloat(t) * pps
                let isMajor = i % 5 == 0
                let h: CGFloat = isMajor ? 8 : 4
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height)); $0.addLine(to: CGPoint(x: x, y: size.height - h)) }, with: .color(.primary.opacity(isMajor ? 0.5 : 0.22)), lineWidth: 1)
                if isMajor { ctx.draw(Text(Timecode.string(t, fps: fps)).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.secondary), at: CGPoint(x: x + 4, y: labelY), anchor: .leading) }
                i += 1
            }
            if let i = inPoint, let o = outPoint, o > i {
                ctx.fill(Path(CGRect(x: CGFloat(i) * pps, y: 0, width: CGFloat(o - i) * pps, height: size.height)), with: .color(.yellow.opacity(0.18)))
                for e in [i, o] { ctx.stroke(Path { $0.move(to: CGPoint(x: CGFloat(e) * pps, y: 0)); $0.addLine(to: CGPoint(x: CGFloat(e) * pps, y: size.height)) }, with: .color(.yellow), lineWidth: 1) }
            } else if let i = inPoint ?? outPoint {
                ctx.stroke(Path { $0.move(to: CGPoint(x: CGFloat(i) * pps, y: 0)); $0.addLine(to: CGPoint(x: CGFloat(i) * pps, y: size.height)) }, with: .color(.yellow), lineWidth: 1)
            }
            for m in markers {
                let x = CGFloat(m.time) * pps
                guard x > lo - 140, x < hi else { continue }   // the pin and its tag (up to ~130 pt) reach right of x
                let flag = Path { p in p.move(to: CGPoint(x: x, y: markerTop)); p.addLine(to: CGPoint(x: x + 7, y: markerTop)); p.addLine(to: CGPoint(x: x + 7, y: markerTop + 6)); p.addLine(to: CGPoint(x: x, y: markerTop + 6)); p.addLine(to: CGPoint(x: x, y: size.height)) }
                ctx.fill(Path(CGRect(x: x, y: markerTop, width: 7, height: 6)), with: .color(Color(hex: m.colorHex)))
                ctx.stroke(flag, with: .color(Color(hex: m.colorHex)), lineWidth: 1)
                if !m.name.isEmpty {
                    // A tag in the marker's colour beside the pin, in the bottom band: it covers ticks, never a timecode.
                    let label = ctx.resolve(Text(m.name).font(.system(size: 8, weight: .medium)).foregroundColor(.white))
                    let s = label.measure(in: CGSize(width: 120, height: 12))
                    let tag = CGRect(x: x + 10, y: markerTop - 1, width: s.width + 6, height: 11)
                    ctx.fill(Path(roundedRect: tag, cornerRadius: 3), with: .color(Color(hex: m.colorHex).opacity(0.9)))
                    ctx.draw(label, at: CGPoint(x: tag.minX + 3, y: tag.midY), anchor: .leading) }
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height - 0.5)); $0.addLine(to: CGPoint(x: size.width, y: size.height - 0.5)) }, with: .color(.primary.opacity(0.15)))
        }
    }
}

/// Re-renders `content` when the player publishes (its time, 30 times a second while playing), so the timeline that
/// holds it does not.
private struct PlayerReader<Content: View>: View {
    @ObservedObject var player: PlayerController
    @ViewBuilder let content: (PlayerController) -> Content
    var body: some View { content(player) }
}

/// How far a scroll view is scrolled, shared with the views it pins. Observable, so a scroll redraws only the pinned
/// views (they read `y`), not the whole timeline that owns it.
@Observable final class PinnedOffset {
    var y: CGFloat = 0
}

/// Holds `content` at the top of the visible part of an enclosing vertical scroll view: offset down by as much as the
/// scroll view has scrolled. Inside a horizontal scroll view it still scrolls sideways with its neighbours.
struct PinnedToTop<Content: View>: View {
    let offset: PinnedOffset
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().offset(y: offset.y).zIndex(1)
    }
}
