import SwiftUI
import AVFoundation
import AppKit

/// One source monitor per project window: the asset loaded in the source viewer, its marks, and its own player
/// (separate from the timeline's).
@MainActor
final class SourceMonitor: ObservableObject {
    private static var monitors: [UUID: SourceMonitor] = [:]
    static func of(_ doc: UUID) -> SourceMonitor { if let m = monitors[doc] { return m }; let m = SourceMonitor(); monitors[doc] = m; return m }

    @Published private(set) var assetID: UUID?
    @Published var showing = false            // the preview area shows the source (true) or the timeline (false)
    @Published var inPoint: Double?
    @Published var outPoint: Double?
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    let player = AVPlayer()
    private var observer: Any?

    func open(_ a: Asset, at t: Double? = nil, in i: Double? = nil, out o: Double? = nil) {
        if assetID != a.id {
            player.replaceCurrentItem(with: AVPlayerItem(url: a.url))
            assetID = a.id; duration = a.duration
        }
        inPoint = i; outPoint = o; showing = true
        seek(t ?? i ?? 0)
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.time = t.seconds.isFinite ? t.seconds : 0; self?.playing = (self?.player.rate ?? 0) != 0 }
            }
        }
    }
    func close() { player.pause(); player.replaceCurrentItem(with: nil); assetID = nil; showing = false; inPoint = nil; outPoint = nil }
    func seek(_ t: Double) {
        let c = min(max(0, t), duration); time = c
        player.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func togglePlay() { if player.rate != 0 { player.pause() } else { if time >= duration - 0.05 { seek(inPoint ?? 0) }; player.play() }; playing = player.rate != 0 }
    func markIn() { inPoint = time; if let o = outPoint, o <= time { outPoint = nil } }
    func markOut() { outPoint = time; if let i = inPoint, i >= time { inPoint = nil } }
}

/// The source viewer's edits and match frame, shared by its buttons and the , . F keys.
@MainActor
struct SourceActions {
    let document: EditMaxDocument
    let state: EditorState
    let player: PlayerController
    var monitor: SourceMonitor { SourceMonitor.of(document.id) }

    /// Insert or overwrite the source marks at the timeline: timeline in/out marks when both are set (with both
    /// source marks: fit to fill), else at the playhead. Source marks default to the whole asset (in) / to the end.
    @discardableResult
    func edit(overwrite: Bool) -> String? {
        guard let id = monitor.assetID else { return "Open a clip in the source viewer first (media panel: right-click ▸ Open in Source Viewer)." }
        let sIn = monitor.inPoint ?? (monitor.outPoint == nil ? 0 : nil), sOut = monitor.outPoint
        var tIn: Double? = state.inPoint, tOut: Double? = state.outPoint
        if tIn == nil || tOut == nil || sOut == nil { tOut = nil; tIn = tIn ?? player.currentTime }
        var sOutFinal = sOut
        if [sIn, sOutFinal, tIn, tOut].compactMap({ $0 }).count < 3 { sOutFinal = monitor.duration }
        do {
            let r = try ToolExecutor(document: document, origin: .user).pointEdit(overwrite: overwrite, asset: id.uuidString, sourceIn: sIn, sourceOut: sOutFinal, timelineIn: tIn, timelineOut: tOut, track: nil)
            if let c = document.project.allClips.first(where: { $0.id.short == r.clip.id }) { state.selectedClipIDs = [c.id] }
            player.seek(to: r.timelineOut)
            return nil
        } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    /// Opens the frame under the playhead in the source viewer, marked with the clip's source range.
    func matchFrame() {
        guard let m = try? ToolExecutor(document: document, origin: .user).matchFrame(clip: nil, time: player.currentTime),
              let a = document.project.assets.first(where: { $0.id.short == m.asset }) else { NSSound.beep(); return }
        player.pause()
        monitor.open(a, at: m.sourceTime, in: m.sourceIn, out: m.sourceOut)
    }
}

/// Over the program preview: a Source / Timeline switch while a source is loaded, and the source viewer itself when
/// it is showing. One viewer at a time keeps the picture as large as before on small windows.
struct SourceViewerHost: View {
    @ObservedObject var document: EditMaxDocument
    @ObservedObject private var monitor: SourceMonitor
    @EnvironmentObject private var state: EditorState
    @EnvironmentObject private var player: PlayerController
    init(document: EditMaxDocument) { self.document = document; _monitor = ObservedObject(wrappedValue: SourceMonitor.of(document.id)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if monitor.assetID != nil, monitor.showing, let a = document.project.asset(monitor.assetID!) {
                SourceViewer(asset: a, monitor: monitor, actions: SourceActions(document: document, state: state, player: player))
            }
            if monitor.assetID != nil {
                Picker("Viewer", selection: $monitor.showing) {
                    Text("Source").tag(true)
                    Text("Timeline").tag(false)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 150).padding(10).pointer().uiFrame("source.toggle")
                .help("Show the source viewer or the timeline (⌥⌘S)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editmaxOpenSource)) { n in
            guard (n.object as? UUID) == document.id, let id = n.userInfo?["asset"] as? UUID, let a = document.project.asset(id) else { return }
            player.pause(); monitor.open(a)
        }
        .onReceive(NotificationCenter.default.publisher(for: .editmaxToggleSource)) { n in
            guard (n.object as? UUID).map({ $0 == document.id }) ?? (DocumentRegistry.shared.activeID == document.id) else { return }
            if monitor.assetID != nil { monitor.showing.toggle() } else { SourceActions(document: document, state: state, player: player).matchFrame() }
        }
        .onChange(of: monitor.showing) { _, s in if !s { monitor.player.pause() } else { player.pause() } }
    }
}

/// The source viewer: the asset's picture, a scrubber with its in/out marks, transport, and Insert / Overwrite.
struct SourceViewer: View {
    let asset: Asset
    @ObservedObject var monitor: SourceMonitor
    var actions: SourceActions?
    /// Preview renders draw this frame instead of the player layer.
    var still: CGImage? = nil
    @State var note: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let still { Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                else { SourcePlayerLayer(player: monitor.player) }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    Text(asset.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Button { monitor.close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle()) }
                        .buttonStyle(.plain).focusable(false).pointer().help("Close the source viewer").editFrame("source.close")
                }
                .foregroundStyle(.white).padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(Color.black.opacity(0.55))).padding(10)
            }
            .overlay(alignment: .bottomLeading) {
                Text("SOURCE").font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 6).frame(height: 16).background(RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.85))).padding(10)
            }
            VStack(spacing: 8) {
                SourceScrubber(monitor: monitor).frame(height: 26).editFrame("source.scrubber")
                HStack(spacing: 8) {
                    Button { monitor.togglePlay() } label: { Image(systemName: monitor.playing ? "pause.fill" : "play.fill").frame(width: 14) }
                        .buttonStyle(EditingButtonStyle()).focusable(false).pointer().help("Play or pause the source").editFrame("source.play")
                    Button("Mark In") { monitor.markIn() }.buttonStyle(EditingButtonStyle()).focusable(false).pointer().help("Source in at this frame").editFrame("source.markIn")
                    Button("Mark Out") { monitor.markOut() }.buttonStyle(EditingButtonStyle()).focusable(false).pointer().help("Source out at this frame").editFrame("source.markOut")
                    Text(marks).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Insert") { note = actions?.edit(overwrite: false) }.buttonStyle(EditingButtonStyle()).focusable(false).pointer()
                        .help("Insert the marked source at the playhead (or the timeline in/out marks), pushing later clips right (,)").editFrame("source.insert")
                    Button("Overwrite") { note = actions?.edit(overwrite: true) }.buttonStyle(EditingButtonStyle(prominent: true)).focusable(false).pointer()
                        .help("Overwrite the timeline from the playhead (or the in/out marks) on one track (.)").editFrame("source.overwrite")
                }
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var marks: String {
        func tc(_ t: Double?) -> String { t.map { String(format: "%02d:%05.2f", Int($0) / 60, $0.truncatingRemainder(dividingBy: 60)) } ?? "--:--.--" }
        let dur = (monitor.outPoint ?? monitor.duration) - (monitor.inPoint ?? 0)
        return "\(tc(monitor.time))   In \(tc(monitor.inPoint))   Out \(tc(monitor.outPoint))   \(EditFormat.s(max(0, dur))) s"
    }
}

/// A scrubber drawn in SwiftUI: the in/out range shaded, the marks as brackets, the playhead as a line. Drag or click
/// to scrub.
struct SourceScrubber: View {
    @ObservedObject var monitor: SourceMonitor
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(0.001, monitor.duration)
            let x: (Double) -> CGFloat = { t in CGFloat(t / d) * w }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)).frame(height: 8)
                let i = monitor.inPoint ?? 0, o = monitor.outPoint ?? d
                if monitor.inPoint != nil || monitor.outPoint != nil {
                    Rectangle().fill(Color.accentColor.opacity(0.45)).frame(width: max(2, x(o) - x(i)), height: 8).offset(x: x(i))
                    if monitor.inPoint != nil { Bracket(open: true).stroke(Color.accentColor, lineWidth: 2).frame(width: 6, height: 20).offset(x: x(i)) }
                    if monitor.outPoint != nil { Bracket(open: false).stroke(Color.accentColor, lineWidth: 2).frame(width: 6, height: 20).offset(x: x(o) - 6) }
                }
                Rectangle().fill(Color.orange).frame(width: 2, height: 24).offset(x: x(monitor.time) - 1)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in monitor.seek(Double(min(max(0, v.location.x), w) / max(1, w)) * d) })
        }
        .pointer()
    }
    struct Bracket: Shape {
        let open: Bool
        func path(in r: CGRect) -> Path {
            var p = Path()
            let xEdge = open ? r.minX : r.maxX, xTip = open ? r.maxX : r.minX
            p.move(to: CGPoint(x: xTip, y: r.minY)); p.addLine(to: CGPoint(x: xEdge, y: r.minY))
            p.addLine(to: CGPoint(x: xEdge, y: r.maxY)); p.addLine(to: CGPoint(x: xTip, y: r.maxY))
            return p
        }
    }
}

struct SourcePlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        let l = AVPlayerLayer(player: player); l.videoGravity = .resizeAspect
        v.layer = l
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { (v.layer as? AVPlayerLayer)?.player = player }
}
