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
    @Published private(set) var renderSize = CGSize(width: 1920, height: 1080)
    @Published private(set) var overlayLayer: CALayer?
    @Published private(set) var syncLayer: AVSynchronizedLayer?
    @Published private(set) var buildError: String?
    @Published private(set) var lastOutput: CompositionBuilder.Output?

    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds.isFinite ? t.seconds : 0
            if self.player.timeControlStatus != .playing, self.isPlaying { self.isPlaying = false }
        }
        player.actionAtItemEnd = .pause
    }

    func bind(to document: EditMaxDocument) {
        cancellables.removeAll()
        document.$revision
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self, weak document] _ in guard let document else { return }; self?.rebuild(document.project) }
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
                let out = try await CompositionBuilder.build(project)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: out.composition)
                item.videoComposition = out.videoComposition
                item.audioMix = out.audioMix
                let keep = player.currentTime()
                player.replaceCurrentItem(with: item)
                let overlay = out.makeOverlay()
                let sync = AVSynchronizedLayer(playerItem: item)
                sync.frame = CGRect(origin: .zero, size: out.renderSize)
                sync.addSublayer(overlay)
                overlayLayer = overlay; syncLayer = sync
                renderSize = out.renderSize
                lastOutput = out
                buildError = nil
                if keep.isValid, keep.seconds < out.duration.seconds { await item.seek(to: keep, toleranceBefore: .zero, toleranceAfter: .zero) }
            } catch {
                buildError = error.localizedDescription
            }
        }
    }

    func togglePlay() { isPlaying ? pause() : play() }
    func play() {
        if let item = player.currentItem, item.currentTime() >= item.duration - CMTime(value: 1, timescale: 30) { seek(to: 0) }
        player.play(); isPlaying = true
    }
    func pause() { player.pause(); isPlaying = false }
    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: CompositionBuilder.timescale)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, seconds)
    }
    func step(frames: Int, fps: Double) { pause(); seek(to: currentTime + Double(frames) / max(1, fps)) }
}
