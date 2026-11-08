import Foundation
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

/// Small video frames along each asset, for the timeline's clip strips and the media list: one frame every `interval`
/// seconds of source, at most 240 per file, 88 px tall (44 pt rows on a Retina display).
///
/// From a slow drive (a T7 on a USB 2 cable reads about 28 MB/s, and a 4K keyframe is 1-2 MB) a whole strip takes
/// 10-60 s a file, so a strip fills in stages and the pictures a person is looking at come first:
/// 1. a 12-frame quick strip for every file (about a second each), for the media list and a first look at the clips;
/// 2. the frames of the seconds the timeline actually uses (`request(_:using:)`), for every file;
/// 3. the rest, behind the waveforms. Gaps show the nearest frame made so far.
/// A finished strip is kept on this Mac's disk (`StripCache`), so opening the project again reads nothing from the drive.
@MainActor
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()
    struct Strip {
        var interval: Double; var frames: [CGImage]; var aspect: CGFloat
        /// Goes up as the strip fills in, so a clip redraws although its frame count is the same.
        var version = 0
    }

    @Published private(set) var strips: [UUID: Strip] = [:]
    private var inFlight: Set<UUID> = []
    /// The source seconds the timeline's clips show of each file: their frames are made before the rest of the strip.
    private var used: [UUID: [ClosedRange<Double>]] = [:]
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
    static let quickFrames = 12.0

    /// Makes the asset's strip if it has none. `range` is the source seconds a clip shows: those frames come early.
    func request(_ asset: Asset, using range: ClosedRange<Double>? = nil) {
        if let range, range.upperBound > range.lowerBound, used[asset.id]?.contains(range) != true { used[asset.id, default: []].append(range) }
        guard asset.kind == .video || asset.kind == .sequence, strips[asset.id] == nil, !inFlight.contains(asset.id) else { return }
        inFlight.insert(asset.id)
        let url = asset.url, id = asset.id, duration = max(0.1, asset.duration)
        Task.detached(priority: .utility) { await self.build(id: id, url: url, duration: duration) }
    }
    /// Reads the asset's file again (after a relink pointed it at another file).
    func refresh(_ asset: Asset) { strips[asset.id] = nil; fineFrames[asset.id] = nil; request(asset) }
    /// A strip made elsewhere (tests: frames for a clip without its file); a later `request` keeps it.
    func install(_ strip: Strip, for id: UUID) { strips[id] = strip }

    nonisolated private func build(id: UUID, url: URL, duration: Double) async {
        let key = StripCache.key(for: url)
        if let key, let cached = StripCache.load(key) {
            await MainActor.run { self.strips[id] = cached; self.inFlight.remove(id) }
            DebugLog.event("thumbnails-cached", ["file": url.lastPathComponent, "frames": cached.frames.count])
            return
        }
        await BackgroundReads.shared.acquire(url, priority: .high)
        var quick = await Self.generate(url: url, duration: duration, frames: Self.quickFrames)
        await BackgroundReads.shared.release(url)
        quick.version = 1
        let first = quick
        await MainActor.run { self.strips[id] = first }
        guard !quick.frames.isEmpty else { await MainActor.run { _ = self.inFlight.remove(id) }; return }

        let ranges = await MainActor.run { self.used[id] ?? [] }
        let full = await Self.fill(url: url, duration: duration, quick: quick, used: ranges) { strip in
            await MainActor.run { self.strips[id] = strip }
        }
        await MainActor.run { self.strips[id] = full.strip; self.inFlight.remove(id) }
        if full.complete, let key { StripCache.save(full.strip, key: key) }
    }

    nonisolated private static func generator(_ asset: AVURLAsset, interval: Double) -> AVAssetImageGenerator {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 88)
        // The nearest keyframe: an exact frame of long-GOP 4K HEVC means reading and decoding from the keyframe before
        // it, which over a whole strip reads most of the file. Cameras put a keyframe every 0.5-1.25 s (DJI Osmo:
        // 1.25 s), so ±0.75 s always finds one. The zoomed-in frames (FineThumbnails) stay exact.
        let tolerance = CMTime(seconds: max(interval / 2, 0.75), preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        return gen
    }

    /// The asset's video can be read (the generator raises an uncatchable ObjC exception, seen once as SIGABRT on its
    /// own queue, when the file has no readable video track).
    nonisolated private static func readable(_ asset: AVURLAsset) async -> Bool {
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return false }
        return (try? await asset.load(.isReadable)) == true
    }

    nonisolated private static func generate(url: URL, duration: Double, frames count: Double = overviewFrames) async -> Strip {
        let started = Date()
        let asset = AVURLAsset(url: url)
        guard await readable(asset) else {
            DebugLog.event("thumbnails-skipped", ["file": url.lastPathComponent, "reason": "no readable video track"])
            return Strip(interval: 1, frames: [], aspect: 16 / 9)
        }
        let interval = max(0.5, duration / count)
        let gen = generator(asset, interval: interval)
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

    /// The slots of a strip of `count` frames `interval` apart, those inside `used` (and one either side) first.
    nonisolated static func order(count: Int, interval: Double, used: [ClosedRange<Double>]) -> (first: [Int], rest: [Int]) {
        var first: [Int] = [], rest: [Int] = []
        for i in 0..<count {
            let t = Double(i) * interval
            if used.contains(where: { t >= $0.lowerBound - interval && t <= $0.upperBound + interval }) { first.append(i) } else { rest.append(i) }
        }
        return (first, rest)
    }

    /// A full-length strip from the frames made so far: each slot shows its own frame, else the nearest made frame when
    /// it is closer than the nearest quick frame, else the quick frame.
    nonisolated static func compose(made: [Int: CGImage], count: Int, interval: Double, quick: Strip) -> [CGImage] {
        let keys = made.keys.sorted()
        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        var k = 0
        for i in 0..<count {
            if let img = made[i] { frames.append(img); continue }
            while k + 1 < keys.count, abs(keys[k + 1] - i) <= abs(keys[k] - i) { k += 1 }
            let t = Double(i) * interval
            let near: (img: CGImage, dt: Double)? = keys.isEmpty ? nil : (made[keys[k]]!, abs(Double(keys[k]) * interval - t))
            var q: (img: CGImage, dt: Double)? = nil
            if !quick.frames.isEmpty {
                let qi = min(quick.frames.count - 1, max(0, Int((t / quick.interval).rounded())))
                q = (quick.frames[qi], abs(Double(qi) * quick.interval - t))
            }
            switch (near, q) {
            case let (n?, q?): frames.append(n.dt <= q.dt ? n.img : q.img)
            case let (n?, nil): frames.append(n.img)
            case let (nil, q?): frames.append(q.img)
            default: break
            }
        }
        return frames
    }

    /// Stages 2 and 3: the used seconds at high priority, the rest at low priority, publishing every few frames.
    nonisolated private static func fill(url: URL, duration: Double, quick: Strip, used: [ClosedRange<Double>],
                                         publish: @escaping @Sendable (Strip) async -> Void) async -> (strip: Strip, complete: Bool) {
        let started = Date()
        let asset = AVURLAsset(url: url)
        let interval = max(0.5, duration / overviewFrames)
        var count = 0
        while Double(count) * interval < duration { count += 1 }
        let gen = generator(asset, interval: interval)
        let (first, rest) = order(count: count, interval: interval, used: used)
        var made: [Int: CGImage] = [:]
        var aspect = quick.aspect
        var version = quick.version
        var unpublished = 0

        func strip() -> Strip {
            version += 1
            return Strip(interval: interval, frames: compose(made: made, count: count, interval: interval, quick: quick), aspect: aspect, version: version)
        }
        func run(_ slots: [Int], _ priority: BackgroundReads.Priority) async {
            guard !slots.isEmpty else { return }
            await BackgroundReads.shared.acquire(url, priority: priority)
            let times = slots.map { CMTime(seconds: min(max(0, duration - 0.05), Double($0) * interval), preferredTimescale: 600) }
            for await r in gen.images(for: times) {
                guard let img = try? r.image else { continue }
                let i = min(count - 1, max(0, Int((r.requestedTime.seconds / interval).rounded())))
                if made.isEmpty { aspect = CGFloat(img.width) / CGFloat(max(1, img.height)) }
                made[i] = img
                unpublished += 1
                if unpublished >= 8 { unpublished = 0; await publish(strip()) }
            }
            await BackgroundReads.shared.release(url)
            if unpublished > 0 { unpublished = 0; await publish(strip()) }
        }
        await run(first, .high)
        let firstSeconds = Date().timeIntervalSince(started)
        await run(rest, .low)
        DebugLog.event("thumbnails", ["file": url.lastPathComponent, "frames": made.count, "usedFrames": first.count,
                                      "usedSeconds": (firstSeconds * 100).rounded() / 100,
                                      "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
        return (strip(), made.count >= max(1, count * 9 / 10))
    }
}

/// Finished strips on this Mac's disk, keyed by the file's path, size and modification date, so a project opens with
/// its pictures without reading the media again. Frames are JPEG, about 2 MB a file.
enum StripCache {
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax/thumbnails", isDirectory: true)
    }
    private static let magic = Data("EMXS1".utf8)

    nonisolated static func key(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] else { return nil }
        let stamp = "\(url.path)|\(size)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|240"
        return SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func save(_ strip: ThumbnailStore.Strip, key: String, in dir: URL = directory) {
        var blobs: [Data] = []
        for img in strip.frames {
            let d = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }
            blobs.append(d as Data)
        }
        let header: [String: Any] = ["interval": strip.interval, "aspect": Double(strip.aspect), "sizes": blobs.map(\.count)]
        guard let head = try? JSONSerialization.data(withJSONObject: header) else { return }
        var out = magic
        var n = UInt32(head.count).littleEndian
        out.append(Data(bytes: &n, count: 4)); out.append(head)
        blobs.forEach { out.append($0) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? out.write(to: dir.appendingPathComponent("\(key).strip"), options: .atomic)
    }

    nonisolated static func load(_ key: String, in dir: URL = directory) -> ThumbnailStore.Strip? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(key).strip")), data.count > magic.count + 4,
              data.prefix(magic.count) == magic else { return nil }
        let base = data.startIndex + magic.count
        let n = Int(data[base..<base + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard data.count >= magic.count + 4 + n,
              let header = try? JSONSerialization.jsonObject(with: data[(base + 4)..<(base + 4 + n)]) as? [String: Any],
              let interval = header["interval"] as? Double, let aspect = header["aspect"] as? Double, let sizes = header["sizes"] as? [Int] else { return nil }
        var at = base + 4 + n
        var frames: [CGImage] = []
        for size in sizes {
            guard size > 0, at + size <= data.endIndex,
                  let src = CGImageSourceCreateWithData(data[at..<at + size] as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            frames.append(img); at += size
        }
        return frames.isEmpty ? nil : ThumbnailStore.Strip(interval: interval, frames: frames, aspect: CGFloat(aspect), version: 1)
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
    static func == (a: ThumbnailStripView, b: ThumbnailStripView) -> Bool { a.strip.frames.count == b.strip.frames.count && a.strip.version == b.strip.version && a.strip.interval == b.strip.interval && a.sourceIn == b.sourceIn && a.sourceOut == b.sourceOut && a.visible == b.visible && a.fine === b.fine }

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
