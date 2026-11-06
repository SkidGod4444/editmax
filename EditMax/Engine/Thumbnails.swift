import Foundation
import AVFoundation
import SwiftUI

/// Small video frames along each asset, for the timeline's clip strips. Generated once per asset in the background:
/// one frame every `interval` seconds of source, at most ~240 per file, 88 px tall (44 pt rows on a Retina display).
@MainActor
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()
    struct Strip { var interval: Double; var frames: [CGImage]; var aspect: CGFloat }

    @Published private(set) var strips: [UUID: Strip] = [:]
    private var inFlight: Set<UUID> = []

    func request(_ asset: Asset) {
        guard asset.kind == .video || asset.kind == .sequence, strips[asset.id] == nil, !inFlight.contains(asset.id) else { return }
        inFlight.insert(asset.id)
        let url = asset.url, id = asset.id, duration = max(0.1, asset.duration)
        Task.detached(priority: .utility) {
            let strip = await Self.generate(url: url, duration: duration)
            await MainActor.run { self.strips[id] = strip; self.inFlight.remove(id) }
        }
    }
    /// Reads the asset's file again (after a relink pointed it at another file).
    func refresh(_ asset: Asset) { strips[asset.id] = nil; request(asset) }

    private static func generate(url: URL, duration: Double) async -> Strip {
        let started = Date()
        let asset = AVURLAsset(url: url)
        // The generator's reader raises an uncatchable ObjC exception (seen once: SIGABRT on its own queue) when the
        // file has no readable video track, so check first and give such a file an empty strip.
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty, (try? await asset.load(.isReadable)) == true else {
            DebugLog.event("thumbnails-skipped", ["file": url.lastPathComponent, "reason": "no readable video track"])
            return Strip(interval: 1, frames: [], aspect: 16 / 9)
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 88)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let interval = max(0.5, duration / 240)
        var times: [CMTime] = []
        var t = 0.0
        while t < duration { times.append(CMTime(seconds: t, preferredTimescale: 600)); t += interval }
        var frames: [CGImage] = []
        var aspect: CGFloat = 16 / 9
        for await result in gen.images(for: times) {
            guard let img = try? result.image else { continue }   // a frame that fails is skipped; the strip repeats its neighbour
            if frames.isEmpty { aspect = CGFloat(img.width) / CGFloat(max(1, img.height)) }
            frames.append(img)
        }
        DebugLog.event("thumbnails", ["file": url.lastPathComponent, "frames": frames.count, "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
        return Strip(interval: interval, frames: frames, aspect: aspect)
    }
}

/// Frames of one clip's source range, tiled left to right; each tile shows the frame nearest its own time.
struct ThumbnailStripView: View, Equatable {
    let strip: ThumbnailStore.Strip
    let sourceIn: Double
    let sourceOut: Double
    static func == (a: ThumbnailStripView, b: ThumbnailStripView) -> Bool { a.strip.frames.count == b.strip.frames.count && a.strip.interval == b.strip.interval && a.sourceIn == b.sourceIn && a.sourceOut == b.sourceOut }

    var body: some View {
        Canvas { ctx, size in
            guard !strip.frames.isEmpty, sourceOut > sourceIn, size.height > 0 else { return }
            let tileW = max(8, size.height * strip.aspect)
            var x: CGFloat = 0
            while x < size.width {
                let t = sourceIn + Double(x / size.width) * (sourceOut - sourceIn)
                let i = min(strip.frames.count - 1, max(0, Int((t / strip.interval).rounded())))
                ctx.draw(Image(decorative: strip.frames[i], scale: 1).interpolation(.medium), in: CGRect(x: x, y: 0, width: tileW - 1, height: size.height))
                x += tileW
            }
        }
    }
}
