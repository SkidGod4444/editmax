import Foundation

/// Background reads of whole media files (timeline thumbnails, waveforms, proxies) take turns, at most `perDrive` at a
/// time on each drive. Each one reads most of its file, and importing 22 4K clips from a USB SSD started 66 of them
/// at once: on a T7 that came up at USB 2 speed (about 30 MB/s) the preview, frame captures and auto_reframe got no
/// data for minutes and agent tool calls timed out. The Mac's own disk and each external drive have separate turns,
/// so a slow drive never holds up files elsewhere. Interactive reads (playback, capture_frame, export) are not gated.
actor BackgroundReads {
    /// Thumbnails and waveforms: short reads the media list and the timeline are waiting on.
    static let shared = BackgroundReads(perDrive: 2)
    /// Proxies read and re-encode a whole file (minutes each from a USB 2 drive), so they have their own lane and
    /// never hold the turns the pictures and waveforms need.
    static let proxies = BackgroundReads(perDrive: 1)

    /// Who goes next when reads wait for a turn on a drive: the playback warm-up, the pictures a person is looking at,
    /// then waveforms, then the rest of the strips. Equal priorities keep their order.
    enum Priority: Int, Sendable { case low, normal, high, urgent }

    /// While the player plays, only urgent reads (the warm-up) start: the others wait, so playback has the drive.
    static func setPlaying(_ playing: Bool) {
        Task { await shared.setPaused(playing); await proxies.setPaused(playing) }
    }

    private struct Waiter { let priority: Int; let seq: Int; let resume: CheckedContinuation<Void, Never> }
    private let perDrive: Int
    private var running: [String: Int] = [:]
    private var waiting: [String: [Waiter]] = [:]
    private var seq = 0
    private var paused = false

    init(perDrive: Int) { self.perDrive = max(1, perDrive) }

    /// The turn key for a file: its drive's name under /Volumes, or "" for the Mac's own disk.
    nonisolated static func drive(of url: URL) -> String { Relink.driveName(of: url.path) ?? "" }

    /// Waits for a turn on `url`'s drive. Pair every call with `release(url)`.
    func acquire(_ url: URL, priority: Priority = .normal) async {
        let d = Self.drive(of: url)
        if !held(priority.rawValue), running[d, default: 0] < perDrive { running[d, default: 0] += 1; return }
        seq += 1
        let s = seq
        await withCheckedContinuation { waiting[d, default: []].append(Waiter(priority: priority.rawValue, seq: s, resume: $0)) }
    }

    /// Ends a turn: the waiting read with the highest priority (the earliest of those) starts and inherits the slot, or
    /// the slot frees.
    func release(_ url: URL) {
        let d = Self.drive(of: url)
        if let i = next(on: d) {
            let w = waiting[d]!.remove(at: i)
            w.resume.resume()
        } else {
            running[d] = max(0, running[d, default: 0] - 1)
        }
    }

    /// Holds every read but urgent ones from starting (reads already running finish), or lets them go again.
    func setPaused(_ p: Bool) {
        paused = p
        guard !p else { return }
        for d in waiting.keys {
            while running[d, default: 0] < perDrive, let i = next(on: d) {
                running[d, default: 0] += 1
                waiting[d]!.remove(at: i).resume.resume()
            }
        }
    }

    private func held(_ priority: Int) -> Bool { paused && priority < Priority.urgent.rawValue }

    private func next(on d: String) -> Int? {
        guard let q = waiting[d] else { return nil }
        return q.indices.filter { !held(q[$0].priority) }.max { (q[$0].priority, -q[$0].seq) < (q[$1].priority, -q[$1].seq) }
    }

    /// Reads running and waiting on a drive (tests).
    func load(_ url: URL) -> (running: Int, waiting: Int) {
        let d = Self.drive(of: url)
        return (running[d, default: 0], waiting[d, default: []].count)
    }
}
