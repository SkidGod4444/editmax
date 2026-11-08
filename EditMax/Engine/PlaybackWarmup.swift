import Foundation
import AVFoundation

/// The first play of a timeline cut from a slow drive stalls: every cut needs its file's data from the keyframe before
/// the in-point, and a 30 s reel of 0.5-2 s 4K clips asks a T7 on a USB 2 cable (about 28 MB/s) for more than it can
/// read in real time. The second play was smooth only because macOS had cached the data by then.
///
/// The warm-up reads the bytes of the seconds each clip plays, in timeline order from the playhead, into macOS's file
/// cache right after the timeline is built, so the first play reads them from memory. It reads no more than the clips use (a 30 s
/// reel: about 600 MB of 27 GB of source), skips files on the Mac's own disk, and goes before every other background
/// read on the drive.
actor PlaybackWarmup {
    static let shared = PlaybackWarmup()

    struct Span: Equatable { var url: URL; var range: ClosedRange<Double> }
    /// A little before the in-point; `byteRange` goes back from there to the keyframe the decoder starts at.
    static let preroll = 0.1

    private var done: [URL: [ClosedRange<Double>]] = [:]
    private var task: Task<Void, Never>?

    /// The spans to read: each visible or audible clip whose file is on an external drive, from just before its in-point
    /// to its out-point, overlapping spans of a file merged, the clips at or after the playhead first.
    nonisolated static func spans(_ project: Project, from playhead: Double) -> [Span] {
        var items: [(start: Double, span: Span)] = []
        for track in project.tracks where !(track.kind == .video && track.isHidden && track.isMuted) {
            for clip in track.clips {
                guard let asset = project.asset(clip.assetID), asset.kind == .video || asset.kind == .audio,
                      Relink.driveName(of: asset.path) != nil else { continue }
                let lo = max(0, clip.sourceIn - preroll), hi = max(lo, clip.sourceOut + 0.2)
                items.append((clip.start, Span(url: asset.url, range: lo...hi)))
            }
        }
        let ordered = items.sorted { a, b in
            let aAhead = a.start >= playhead - 0.001, bAhead = b.start >= playhead - 0.001
            return aAhead != bAhead ? aAhead : a.start < b.start
        }
        var out: [Span] = []
        for item in ordered {
            if let i = out.firstIndex(where: { $0.url == item.span.url && $0.range.overlaps(item.span.range) }) {
                out[i].range = min(out[i].range.lowerBound, item.span.range.lowerBound)...max(out[i].range.upperBound, item.span.range.upperBound)
            } else { out.append(item.span) }
        }
        return out
    }

    /// Reads the spans not read yet (a new timeline replaces the previous list).
    func warm(_ spans: [Span]) {
        task?.cancel()
        let todo = spans.filter { s in !(done[s.url] ?? []).contains { $0.lowerBound <= s.range.lowerBound && $0.upperBound >= s.range.upperBound } }
        guard !todo.isEmpty else { return }
        task = Task.detached(priority: .userInitiated) {
            let started = Date()
            var bytes = 0, count = 0
            for s in todo {
                if Task.isCancelled { break }
                await BackgroundReads.shared.acquire(s.url, priority: .urgent)
                bytes += await Self.read(s)
                await BackgroundReads.shared.release(s.url)
                await self.finished(s)
                count += 1
            }
            DebugLog.event("playback-warmup", ["spans": count, "of": todo.count, "mb": bytes / 1_000_000,
                                               "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
        }
    }

    private func finished(_ s: Span) { done[s.url, default: []].append(s.range) }

    /// Reads the bytes a span plays, as one sequential read through macOS's file cache. AVFoundation's own reads skip
    /// that cache (an AVAssetReader pass over 6 s of a T7 clip read 77 MB from the drive the second time too), but they
    /// use pages that are already in memory: after a plain read of the same bytes the pass took 0.38 s instead of 3.7 s.
    nonisolated static func read(_ s: Span) async -> Int {
        guard let range = await byteRange(s), let fh = try? FileHandle(forReadingFrom: s.url) else { return 0 }
        defer { try? fh.close() }
        var read = 0
        do {
            try fh.seek(toOffset: UInt64(range.lowerBound))
            while read < range.count, !Task.isCancelled {
                guard let d = try fh.read(upToCount: min(range.count - read, 4 << 20)), !d.isEmpty else { break }
                read += d.count
            }
        } catch {}
        return read
    }

    /// Where a span's samples sit in the file: from the keyframe the decoder starts at to the last sample, video and
    /// audio (an interleaved file keeps them together, so this is one stretch of the file).
    nonisolated static func byteRange(_ s: Span) async -> Range<Int>? {
        let asset = AVURLAsset(url: s.url)
        var lo = Int64.max, hi = Int64(0)
        for type in [AVMediaType.video, .audio] {
            guard let track = try? await asset.loadTracks(withMediaType: type).first,
                  let c = track.makeSampleCursor(presentationTimeStamp: CMTime(seconds: s.range.lowerBound, preferredTimescale: 600)) else { continue }
            if type == .video { while !c.currentSampleSyncInfo.sampleIsFullSync.boolValue, c.stepInDecodeOrder(byCount: -1) == -1 {} }
            var steps = 0
            repeat {
                let r = c.currentChunkStorageRange
                if r.length > 0 { lo = min(lo, r.offset); hi = max(hi, r.offset + r.length) }
                steps += 1
                if c.presentationTimeStamp.seconds > s.range.upperBound || steps > 100_000 { break }
            } while c.stepInDecodeOrder(byCount: 1) == 1
        }
        return lo < hi ? Int(lo)..<Int(hi) : nil
    }
}
