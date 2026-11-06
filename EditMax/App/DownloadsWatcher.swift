import Foundation

/// Watches a folder (the user's Downloads) for media files that arrive after it starts, for the notch drawer's
/// "New in Downloads". A DispatchSource on the folder says something changed; the folder is listed again and each new
/// name that EditMax can use becomes pending until its size has stopped changing (a browser writes a download over
/// seconds or minutes), then `onNew` gets it once.
///
/// Skipped: hidden files, the partial files browsers write while downloading (.crdownload, .download, .part, .tmp…),
/// folders (Safari's .download is a package), and anything `AssetLibrary.kind(of:)` does not take.
/// ~/Downloads is protected by macOS: the first listing makes the system ask the user once; if they say no, the
/// listing fails and `denied` is set.
@MainActor
final class DownloadsWatcher {
    let directory: URL
    var onNew: (URL) -> Void
    /// How often a pending file's size is checked.
    var interval: TimeInterval
    private(set) var denied = false
    private(set) var isRunning = false

    /// Names that were there when watching started, or have been reported already.
    private var known: Set<String> = []
    /// New names waiting for their size to settle: the size at the last check.
    private(set) var pending: [String: Int64] = [:]
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?

    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "temp", "opdownload", "filepart", "aria2", "!ut", "dtapart"]

    nonisolated static var userDownloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    init(directory: URL = DownloadsWatcher.userDownloads, interval: TimeInterval = 1, onNew: @escaping (URL) -> Void) {
        self.directory = directory
        self.interval = interval
        self.onNew = onNew
    }

    /// True for a file the drawer can offer: a finished, visible video, audio, image or font file.
    static func isCandidate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") || name.hasPrefix("~$") { return false }
        if partialExtensions.contains(url.pathExtension.lowercased()) { return false }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue else { return false }
        return AssetLibrary.kind(of: url) != nil
    }

    func start() {
        guard !isRunning else { return }
        guard let names = list() else { denied = true; DebugLog.event("downloads-watch-denied"); return }
        denied = false
        known = Set(names)
        pending = [:]
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { DebugLog.event("downloads-watch-failed", ["errno": Int(errno)]); return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        isRunning = true
        DebugLog.event("downloads-watch-start", ["files": names.count])
    }

    func stop() {
        source?.cancel(); source = nil
        timer?.invalidate(); timer = nil
        pending = [:]
        isRunning = false
    }

    /// Lists the folder again: new names that could be media become pending (or, while it is being written, stay so).
    func scan() {
        guard let names = list() else { return }
        let present = Set(names)
        for name in pending.keys where !present.contains(name) { pending.removeValue(forKey: name) }   // renamed or deleted
        for name in names where !known.contains(name) && pending[name] == nil {
            let url = directory.appendingPathComponent(name)
            guard Self.isCandidate(url) else { continue }   // a partial file is looked at again under its final name
            pending[name] = -1   // not measured yet: the next check records a size, the one after compares
        }
        if !pending.isEmpty, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkPending() } }
        }
    }

    /// One size check: a file whose size is above zero and the same as at the last check is finished.
    func checkPending() {
        for (name, last) in pending {
            let url = directory.appendingPathComponent(name)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { pending.removeValue(forKey: name); continue }
            let now = size.int64Value
            if now > 0, now == last, Self.isCandidate(url) {
                pending.removeValue(forKey: name)
                known.insert(name)
                DebugLog.event("downloads-new", ["kind": AssetLibrary.kind(of: url)?.rawValue ?? "?"])
                onNew(url)
            } else {
                pending[name] = now
            }
        }
        if pending.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func list() -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    }
}
