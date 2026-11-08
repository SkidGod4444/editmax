import Foundation

/// Background reads of whole media files (timeline thumbnails, waveforms, proxies) take turns, at most `perDrive` at a
/// time on each drive. Each one reads most of its file, and importing 22 4K clips from a USB SSD started 66 of them
/// at once: on a T7 that came up at USB 2 speed (about 30 MB/s) the preview, frame captures and auto_reframe got no
/// data for minutes and agent tool calls timed out. The Mac's own disk and each external drive have separate turns,
/// so a slow drive never holds up files elsewhere. Interactive reads (playback, capture_frame, export) are not gated.
actor BackgroundReads {
    static let shared = BackgroundReads(perDrive: 2)

    private let perDrive: Int
    private var running: [String: Int] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(perDrive: Int) { self.perDrive = max(1, perDrive) }

    /// The turn key for a file: its drive's name under /Volumes, or "" for the Mac's own disk.
    nonisolated static func drive(of url: URL) -> String { Relink.driveName(of: url.path) ?? "" }

    /// Waits for a turn on `url`'s drive. Pair every call with `release(url)`.
    func acquire(_ url: URL) async {
        let d = Self.drive(of: url)
        if running[d, default: 0] < perDrive { running[d, default: 0] += 1; return }
        await withCheckedContinuation { waiting[d, default: []].append($0) }
    }

    /// Ends a turn: the next waiting read on that drive starts (it inherits the slot), or the slot frees.
    func release(_ url: URL) {
        let d = Self.drive(of: url)
        if var q = waiting[d], !q.isEmpty {
            let next = q.removeFirst()
            waiting[d] = q
            next.resume()
        } else {
            running[d] = max(0, running[d, default: 0] - 1)
        }
    }

    /// Reads running and waiting on a drive (tests).
    func load(_ url: URL) -> (running: Int, waiting: Int) {
        let d = Self.drive(of: url)
        return (running[d, default: 0], waiting[d, default: []].count)
    }
}
