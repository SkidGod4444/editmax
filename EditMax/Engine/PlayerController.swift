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
    @Published var scopesEnabled = false { didSet { if scopesEnabled { attachScopes(); sampleScopes() } else { scopes = nil } } }
    @Published private(set) var scopes: ScopeData?
    private var videoOutput: AVPlayerItemVideoOutput?
    private let scopeQueue = DispatchQueue(label: "io.openhorizon.editmax.scopes", qos: .utility)
    private var scopeBusy = false

    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds.isFinite ? t.seconds : 0
            if self.scopesEnabled { self.sampleScopes() }
            if self.player.timeControlStatus != .playing, self.isPlaying { self.isPlaying = false; self.rate = 0 }
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
            .sink { [weak self, weak document] _ in guard let document, document.project.settings.useProxies else { return }; self?.rebuild(document.project) }
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

    func rebuild(_ project: Project) {
        rebuildTask?.cancel()
        rebuildTask = Task {
            do {
                let out = try await CompositionBuilder.build(project, forPreview: true, compositor: EditMaxPreviewCompositor.self)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: out.composition)
                item.videoComposition = out.videoComposition
                item.audioMix = out.audioMix
                let keep = player.currentTime()
                player.replaceCurrentItem(with: item)
                renderSize = out.renderSize
                lastOutput = out
                buildError = nil
                if scopesEnabled { attachScopes() }
                if keep.isValid, keep.seconds < out.duration.seconds { await item.seek(to: keep, toleranceBefore: .zero, toleranceAfter: .zero) }
                if scopesEnabled { try? await Task.sleep(for: .milliseconds(150)); sampleScopes() }
            } catch {
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

    /// Pulls the frame at the current time and computes the scopes off the main thread (one at a time).
    func sampleScopes() {
        guard scopesEnabled, !scopeBusy, let out = videoOutput else { return }
        let t = player.currentTime()
        guard let buf = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        scopeBusy = true
        scopeQueue.async { [weak self] in
            let data = ScopeSampler.sample(buf)
            DispatchQueue.main.async { self?.scopeBusy = false; if let data { self?.scopes = data } }
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
    @Published var compareMode: CompareMode = .off { didSet { CompareState.shared.mode = compareMode; redraw() } }
    @Published var compareSplit: Double = 0.5 { didSet { CompareState.shared.split = compareSplit; redraw() } }
    func cycleCompare() { compareMode = compareMode == .off ? .split : compareMode == .split ? .before : .off }

    /// Re-render the frame on screen while paused (a compositor setting changed, not the composition).
    private func redraw() {
        guard let item = player.currentItem, let vc = item.videoComposition else { return }
        item.videoComposition = (vc.mutableCopy() as? AVMutableVideoComposition) ?? vc
        if scopesEnabled { Task { try? await Task.sleep(for: .milliseconds(120)); sampleScopes() } }
    }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: CompositionBuilder.timescale)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in self?.sampleScopes() }
        currentTime = max(0, seconds)
    }
    func step(frames: Int, fps: Double) { pause(); seek(to: currentTime + Double(frames) / max(1, fps)) }
}
