import Foundation
import AVFoundation
import Combine
import QuartzCore

/// Owns the AVPlayer for one document. Rebuilds the composition whenever the document revision changes.
@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    /// Playback rate: 1 = play, 0 = paused, -1/-2/-4/-8 and 2/4/8 = J/L shuttle.
    @Published private(set) var rate: Float = 0
    @Published private(set) var renderSize = CGSize(width: 1920, height: 1080)
    @Published private(set) var buildError: String?
    @Published private(set) var lastOutput: CompositionBuilder.Output?
    /// Scopes (waveform + histogram) of the frame on screen, sampled while `scopesEnabled`.
    @Published var scopesEnabled = false { didSet { if scopesEnabled { attachScopes(); sampleScopesWhenReady(redraw: true) } else { scopeWait?.cancel(); scopes = nil } } }
    @Published private(set) var scopes: ScopeData?
    private var videoOutput: AVPlayerItemVideoOutput?
    private let scopeQueue = DispatchQueue(label: "io.openhorizon.editmax.scopes", qos: .utility)
    private var scopeBusy = false
    private var scopeWait: Task<Void, Never>?

    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds.isFinite ? t.seconds : 0
            if self.scopesEnabled { self.sampleScopes() }
            // Keep the flag true while AVPlayer is still "waiting to play" right after play(): that is playback starting,
            // not playback ending. Only a paused player ends it (the item's end pauses, see actionAtItemEnd).
            if self.player.timeControlStatus == .paused, self.isPlaying { self.isPlaying = false; self.rate = 0 }
            if self.rate < 0, self.currentTime <= 0.001 { self.pause() }
        }
        player.actionAtItemEnd = .pause
    }

    /// A history version shown instead of the live project (History tab). Any edit to the document drops it.
    @Published private(set) var viewingProject: Project?
    private weak var boundDocument: EditMaxDocument?

    func view(_ project: Project?) {
        viewingProject = project
        if let project { rebuild(project) } else if let d = boundDocument { rebuild(d.project) }
    }

    func bind(to document: EditMaxDocument) {
        cancellables.removeAll()
        boundDocument = document
        document.$revision
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self, weak document] _ in guard let self, let document else { return }; self.viewingProject = nil; self.rebuild(document.project) }
            .store(in: &cancellables)
        ProxyStore.shared.$version.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self, weak document] _ in guard let document, document.project.settings.useProxies else { return }; self?.rebuild(document.project, reason: "proxy-version") }
            .store(in: &cancellables)
        InterpolatedVideo.shared.$version.dropFirst().receive(on: DispatchQueue.main)   // a smooth slow-motion render became ready: play it
            .sink { [weak self, weak document] v in guard let document else { return }; self?.rebuild(document.project, reason: "interpolated-version-\(v)") }
            .store(in: &cancellables)
        IsolatedAudio.shared.$version.dropFirst().receive(on: DispatchQueue.main)   // an isolated sound file became ready: play it
            .sink { [weak self, weak document] v in guard let document else { return }; self?.rebuild(document.project, reason: "isolated-audio-version-\(v)") }
            .store(in: &cancellables)
        FontLibrary.shared.$version.dropFirst().receive(on: DispatchQueue.main)   // a font arrived or went: redraw titles that use it
            .sink { [weak self, weak document] v in guard let document, document.project.texts.contains(where: \.hasChosenFont) else { return }; self?.rebuild(document.project, reason: "fonts-version-\(v)") }
            .store(in: &cancellables)
        document.$seekRequest
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] req in
                self?.seek(to: req.time)
                if req.play { self?.play() } else { self?.pause() }
            }
            .store(in: &cancellables)
        rebuild(document.project)
    }

    /// A drive the project plays files from is being ejected: let go of every file now (the picture goes black until
    /// the rebuild that follows the eject), so the eject is not refused with "EditMax is using it".
    /// True when it let go (only when clips on screen play files from that drive). The playhead is kept for the rebuild.
    @discardableResult func release(drive volume: String) -> Bool {
        guard let d = boundDocument else { return false }
        let p = viewingProject ?? d.project
        let ids = Set(Relink.assets(onDrive: volume, in: p).map(\.id))
        guard Relink.clipCount(using: ids, in: p) > 0 else { return false }
        rebuildTask?.cancel()
        if player.currentItem != nil { heldTime = player.currentTime() }
        player.replaceCurrentItem(with: nil)
        lastOutput = nil
        DebugLog.event("player-released-drive", ["assets": ids.count])
        return true
    }

    /// Builds again what the player shows: the live project, or the History version being viewed.
    func reload(reason: String) {
        if let p = viewingProject ?? boundDocument?.project { rebuild(p, reason: reason) }
    }
    /// Where the playhead was when the player let go of its files (an eject), for the next rebuild.
    private var heldTime: CMTime?

    func rebuild(_ project: Project, reason: String = "revision") {
        rebuildTask?.cancel()
        rebuildTask = Task {
            do {
                let out = try await CompositionBuilder.build(project, forPreview: true, compositor: EditMaxPreviewCompositor.self)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: out.composition)
                item.videoComposition = out.videoComposition
                item.audioMix = out.audioMix
                let keep = heldTime ?? player.currentTime()
                heldTime = nil
                player.replaceCurrentItem(with: item)
                DebugLog.event("player-rebuild", ["reason": reason, "audioTracks": out.composition.tracks(withMediaType: .audio).count])
                renderSize = out.renderSize
                lastOutput = out
                buildError = nil
                if scopesEnabled { attachScopes() }
                if keep.isValid, keep.seconds < out.duration.seconds { await item.seek(to: keep, toleranceBefore: .zero, toleranceAfter: .zero) }
                if scopesEnabled { sampleScopesWhenReady(redraw: false) }
            } catch {
                DebugLog.error("player-rebuild-failed", error, ["reason": reason])
                buildError = error.localizedDescription
            }
        }
    }

    private func attachScopes() {
        guard let item = player.currentItem else { return }
        if let out = videoOutput, item.outputs.contains(out) { return }
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        videoOutput = out
    }

    /// Pulls the frame at the current time and computes the scopes off the main thread (one at a time). False when the
    /// output has no new frame for that time yet.
    @discardableResult func sampleScopes() -> Bool {
        guard scopesEnabled, !scopeBusy, let out = videoOutput else { return false }
        let t = player.currentTime()
        guard let buf = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return false }
        scopeBusy = true
        scopeQueue.async { [weak self] in
            let data = ScopeSampler.sample(buf)
            DispatchQueue.main.async { self?.scopeBusy = false; if let data { self?.scopes = data } }
        }
        return true
    }

    /// A video output only receives the frames rendered after it was added, and a paused player renders nothing new, so
    /// scopes opened while paused stayed empty until the playhead moved. `redraw` renders the frame on screen again
    /// (paused only); then the output is polled until that frame arrives (a new item's first frame, a redraw), up to 2 s.
    private func sampleScopesWhenReady(redraw: Bool) {
        scopeWait?.cancel()
        if redraw, !isRunning, let item = player.currentItem, let vc = item.videoComposition {
            item.videoComposition = (vc.mutableCopy() as? AVMutableVideoComposition) ?? vc
        }
        scopeWait = Task { [weak self] in
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, !Task.isCancelled, self.scopesEnabled else { return }
                if self.sampleScopes() { return }
            }
        }
    }

    func togglePlay() { isPlaying ? pause() : play() }
    func play() {
        if let item = player.currentItem, item.currentTime() >= item.duration - CMTime(value: 1, timescale: 30) { seek(to: 0) }
        player.play(); isPlaying = true; rate = 1
    }
    func pause() { player.pause(); isPlaying = false; rate = 0 }
    /// J/L shuttle: first press plays at 1× in that direction, each further press doubles up to 8×.
    func shuttle(backward: Bool) {
        let dir: Float = backward ? -1 : 1
        let speed: Float = rate * dir > 0 ? min(8, abs(rate) * 2) : 1
        if backward, let item = player.currentItem, !item.canPlayReverse { return }
        if !backward, let item = player.currentItem, item.currentTime() >= item.duration - CMTime(value: 1, timescale: 30) { seek(to: 0) }
        player.rate = dir * speed; rate = dir * speed; isPlaying = true
    }
    /// Before/after view (see `CompareMode`); the divider position is a fraction of the frame width.
    @Published var compareMode: CompareMode = .off {
        didSet { CompareState.shared.mode = compareMode; if let s = CompareStyle(compareMode) { compareStyle = s }; redrawIfPaused() }
    }
    /// The way before/after compares when it is turned on: the last one shown (split at a divider until another is chosen).
    @Published private(set) var compareStyle: CompareStyle = .split
    @Published var compareSplit: Double = 0.5 { didSet { CompareState.shared.split = compareSplit; redrawIfPaused() } }

    /// The compositor reads the compare state on every frame, so while the video plays the next frame already shows the
    /// new divider; swapping the video composition then (the paused-frame trick below) only stalls the pipeline and made
    /// the divider lag behind the mouse. Paused, one redraw per run-loop turn is enough for any number of drag updates.
    private var redrawScheduled = false
    /// The player's own word: running or waiting to run, as opposed to the published flag the UI binds to.
    var isRunning: Bool { player.timeControlStatus != .paused }
    private func redrawIfPaused() {
        guard !isRunning, !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.redrawScheduled = false; self.redraw() }
    }
    /// The preview button and ⌥⌘B: before/after on, the way it was last shown, or off. Two states, so the button's look
    /// (tinted or not) always says whether the picture is the graded one.
    func toggleCompare() { compareMode = compareMode == .off ? compareStyle.mode : .off }
    /// The button's menu: compare this way (turns before/after on).
    func showCompare(_ style: CompareStyle) { compareMode = style.mode }

    /// Re-render the frame on screen while paused (a compositor setting changed, not the composition).
    private func redraw() {
        guard let item = player.currentItem, let vc = item.videoComposition else { return }
        item.videoComposition = (vc.mutableCopy() as? AVMutableVideoComposition) ?? vc
        if scopesEnabled { sampleScopesWhenReady(redraw: false) }
    }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: CompositionBuilder.timescale)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in self?.sampleScopes() }
        currentTime = max(0, seconds)
    }
    /// Moves by whole frames from the frame the playhead is on. Counted in frames, not by adding 1/fps to the time: the
    /// player reports times a hair off the grid (0.99833 for 1.0) and the sums drift, so ten steps used to land on 2.998.
    func step(frames: Int, fps: Double) {
        pause()
        let rate = max(1, fps)
        seek(to: max(0, (currentTime * rate).rounded() + Double(frames)) / rate)
    }
}

/// How before/after shows the grade while it is on.
enum CompareStyle: String, CaseIterable {
    case split    // before left of a divider you can drag, after right of it
    case before   // the whole picture without the grade
    var mode: CompareMode { self == .split ? .split : .before }
    init?(_ mode: CompareMode) {
        switch mode {
        case .off: return nil
        case .split: self = .split
        case .before: self = .before
        }
    }
}
