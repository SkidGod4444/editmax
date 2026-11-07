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
    /// Not published: made on first use while a view body runs, and each one publishes its own frames.
    private var fineFrames: [UUID: FineThumbnails] = [:]

    /// Frames as dense as the zoom needs, for a file whose overview strip is sparser than 0.5 s a frame (over 2 min).
    func fine(for asset: Asset?) -> FineThumbnails? {
        guard let asset, asset.kind == .video || asset.kind == .sequence, asset.duration / Self.overviewFrames > FineThumbnails.step(0) else { return nil }
        if let f = fineFrames[asset.id], f.url == asset.url { return f }
        let f = FineThumbnails(url: asset.url, duration: asset.duration)
        fineFrames[asset.id] = f
        return f
    }
    static let overviewFrames = 240.0

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
    func refresh(_ asset: Asset) { strips[asset.id] = nil; fineFrames[asset.id] = nil; request(asset) }
    /// A strip made elsewhere (tests: frames for a clip without its file); a later `request` keeps it.
    func install(_ strip: Strip, for id: UUID) { strips[id] = strip }

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
        let interval = max(0.5, duration / overviewFrames)
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

/// Frames of a long file at the density the zoom needs, made for what is on screen and kept up to `capacity`. The
/// overview strip has at most 240 frames a file (one every 4.5 min of an 18-hour file), so zoomed in, every tile would
/// show the same picture. Frames sit on a grid per level (0.5 s, 1 s, 2 s, 4 s … apart), so zooming reuses them.
@MainActor
final class FineThumbnails: ObservableObject {
    struct Key: Hashable { var level: Int, index: Int }
    nonisolated static func step(_ level: Int) -> Double { 0.5 * Double(1 << max(0, min(level, 24))) }
    /// The widest spacing that still gives every tile its own frame.
    nonisolated static func level(tileSeconds s: Double) -> Int {
        var l = 0
        while l < 24, step(l + 1) <= s { l += 1 }
        return l
    }
    nonisolated static func key(_ t: Double, level: Int) -> Key { Key(level: level, index: max(0, Int((t / step(level)).rounded()))) }
    static let capacity = 600   // about 33 MB of 156×88 frames

    let url: URL, duration: Double
    @Published private(set) var frames: [Key: CGImage] = [:]
    private var lastWanted: [Key: Int] = [:], clock = 0
    private var pending: Set<Key> = []
    private var generators: [Int: AVAssetImageGenerator] = [:]

    init(url: URL, duration: Double) { self.url = url; self.duration = duration }

    /// Makes the frames for `keys` that are not made yet, publishing them a few at a time. A cancelled task stops taking
    /// them (scrolled past).
    func want(_ keys: [Key]) async {
        clock += 1
        for k in keys { lastWanted[k] = clock }
        let missing = keys.filter { frames[$0] == nil && !pending.contains($0) }
        guard let level = missing.first?.level else { return }
        pending.formUnion(missing)
        defer { pending.subtract(missing) }
        let gen = generator(level)
        let step = Self.step(level)
        let times = missing.map { CMTime(seconds: min(max(0, duration - 0.05), Double($0.index) * step), preferredTimescale: 600) }
        var got: [Key: CGImage] = [:]
        for await r in gen.images(for: times) {
            if Task.isCancelled { break }
            guard let img = try? r.image else { continue }
            got[Self.key(r.requestedTime.seconds, level: level)] = img
            if got.count >= 6 { frames.merge(got) { $1 }; got = [:] }
        }
        if !got.isEmpty { frames.merge(got) { $1 } }
        evict()
    }

    private func generator(_ level: Int) -> AVAssetImageGenerator {
        if let g = generators[level] { return g }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 320, height: 88)
        // Any frame within half a step stands for its grid point: often a keyframe, which needs no decoding run.
        let tol = CMTime(seconds: min(2, Self.step(level) / 2), preferredTimescale: 600)
        g.requestedTimeToleranceBefore = tol; g.requestedTimeToleranceAfter = tol
        generators[level] = g
        return g
    }

    /// Keeps the `capacity` frames wanted most recently.
    private func evict() {
        guard frames.count > Self.capacity else { return }
        let drop = frames.keys.sorted { (lastWanted[$0] ?? 0) < (lastWanted[$1] ?? 0) }.prefix(frames.count - Self.capacity)
        for k in drop { frames[k] = nil; lastWanted[k] = nil }
    }
}

/// Frames of one clip's source range, tiled left to right; each tile shows the frame nearest its own time.
struct ThumbnailStripView: View, Equatable {
    let strip: ThumbnailStore.Strip
    let sourceIn: Double
    let sourceOut: Double
    /// The part worth drawing, in the view's own points (nil: all of it): a long clip's tiles are drawn only where the
    /// timeline can show them.
    var visible: ClosedRange<CGFloat>? = nil
    /// Denser frames for a long file, made for the tiles on screen when the overview strip is too sparse for the zoom.
    var fine: FineThumbnails? = nil
    static func == (a: ThumbnailStripView, b: ThumbnailStripView) -> Bool { a.strip.frames.count == b.strip.frames.count && a.strip.interval == b.strip.interval && a.sourceIn == b.sourceIn && a.sourceOut == b.sourceOut && a.visible == b.visible && a.fine === b.fine }

    var body: some View {
        if let fine { FineStrip(fine: fine, base: self) } else { canvas(nil) }
    }

    /// Tile times for a size: where each tile goes and the source second it shows.
    func tiles(_ size: CGSize) -> (tileW: CGFloat, items: [(x: CGFloat, t: Double)]) {
        guard sourceOut > sourceIn, size.width > 0, size.height > 0 else { return (0, []) }
        let tileW = max(8, size.height * strip.aspect)
        // Tiles stay on the grid they have when the whole strip is drawn (counted from 0).
        var x: CGFloat = visible.map { max(0, ($0.lowerBound / tileW).rounded(.down) * tileW) } ?? 0
        let end = min(size.width, visible?.upperBound ?? size.width)
        var items: [(CGFloat, Double)] = []
        while x < end { items.append((x, sourceIn + Double(x / size.width) * (sourceOut - sourceIn))); x += tileW }
        return (tileW, items)
    }

    /// The fine level the tiles need, or nil when the overview strip is dense enough.
    func fineLevel(_ size: CGSize) -> Int? {
        guard sourceOut > sourceIn, size.width > 0, size.height > 0 else { return nil }
        let tileSeconds = Double(max(8, size.height * strip.aspect) / size.width) * (sourceOut - sourceIn)
        return strip.interval > tileSeconds * 1.5 ? FineThumbnails.level(tileSeconds: tileSeconds) : nil
    }

    /// `fine` is a snapshot of the fine frames, not the object: the canvas redraws when its captured values change, and
    /// a new batch of frames is a new snapshot (read through the object, later batches were never drawn).
    func canvas(_ fine: [FineThumbnails.Key: CGImage]?) -> some View {
        Canvas { ctx, size in
            guard !strip.frames.isEmpty else { return }
            let (tileW, items) = tiles(size)
            let level = fine == nil ? nil : fineLevel(size)
            for (x, t) in items {
                let img = level.flatMap { fine?[FineThumbnails.key(t, level: $0)] }
                    ?? strip.frames[min(strip.frames.count - 1, max(0, Int((t / strip.interval).rounded())))]
                ctx.draw(Image(decorative: img, scale: 1).interpolation(.medium), in: CGRect(x: x, y: 0, width: tileW - 1, height: size.height))
            }
        }
    }
}

/// The strip with fine frames: watches them, and asks for the ones its tiles need whenever those change.
private struct FineStrip: View {
    @ObservedObject var fine: FineThumbnails
    let base: ThumbnailStripView
    /// At most this many tiles are asked for at once (a whole long clip drawn without a viewport would be thousands).
    static let maxWanted = 240

    var body: some View {
        GeometryReader { geo in
            base.canvas(fine.frames)
                .task(id: wanted(geo.size)) { if let keys = wanted(geo.size), !keys.isEmpty { await fine.want(keys) } }
        }
    }

    private func wanted(_ size: CGSize) -> [FineThumbnails.Key]? {
        guard let level = base.fineLevel(size) else { return nil }
        var seen = Set<FineThumbnails.Key>(), keys: [FineThumbnails.Key] = []
        for (_, t) in base.tiles(size).items.prefix(Self.maxWanted) {
            let k = FineThumbnails.key(t, level: level)
            if seen.insert(k).inserted { keys.append(k) }
        }
        return keys
    }
}
