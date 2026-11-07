import AppKit
import SwiftUI
import DiskArbitration

/// Drives being plugged in and removed: an SSD, a camera card, a camera that mounts as a drive. Footage on them is used
/// where it is (never copied onto the Mac), so EditMax follows them. On a removal the clips that play those files go
/// offline: the preview plays a gap where they are and an export names the drive to plug in. On a plug-in they come
/// back, following their bookmarks when the drive mounts under another name ("Untitled 1").
@MainActor
final class DriveWatcher {
    static let shared = DriveWatcher()
    struct Change: Equatable { var name: String; var path: String; var mounted: Bool }
    private var tokens: [NSObjectProtocol] = []
    private var session: DASession?
    /// The open players, so an eject can make them let go of a drive's files (weak: a closed window is gone).
    private var players = NSHashTable<PlayerController>.weakObjects()

    func register(_ player: PlayerController) { players.add(player) }

    /// At launch; never under XCTest (tests call `handle` and `watchEjects`).
    func start() {
        guard tokens.isEmpty, !AppDelegate.isTesting else { return }
        watchEjects()
        let nc = NSWorkspace.shared.notificationCenter
        for (name, mounted) in [(NSWorkspace.didMountNotification, true), (NSWorkspace.didUnmountNotification, false)] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                let label = n.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String ?? url.lastPathComponent
                MainActor.assumeIsolated { DriveWatcher.shared.handle(Change(name: label, path: url.standardizedFileURL.path, mounted: mounted)) }
            })
        }
    }

    /// Asked by macOS before any drive is unmounted (an eject in the Finder, a camera switched off): the players let go
    /// of that drive's files right then, so the eject goes through instead of failing with "EditMax is using it". If the
    /// drive is still there a few seconds later (another app kept it), the players pick its files up again.
    func watchEjects() {
        guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        DARegisterDiskUnmountApprovalCallback(s, nil, { disk, _ in
            guard let desc = DADiskCopyDescription(disk) as? [CFString: Any],
                  let url = desc[kDADiskDescriptionVolumePathKey] as? URL else { return nil }
            let volume = url.standardizedFileURL.path
            let held = DriveWatcher.openFiles(under: volume)
            autoreleasepool { MainActor.assumeIsolated { DriveWatcher.shared.releasing(volume) } }
            // The player closes its files on the main thread a moment after it lets go: let that run (at most 2 s)
            // before answering, or the unmount finds them still open and the eject fails with "in use".
            if !held.isEmpty {
                let t0 = Date()
                while !DriveWatcher.openFiles(under: volume).isEmpty, Date().timeIntervalSince(t0) < 2 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
                let still = DriveWatcher.openFiles(under: volume)
                DebugLog.event("drive-eject-released", ["files": held.count, "stillOpen": still.count, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
            }
            return nil   // approve: nothing of ours is open there now
        }, nil)
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        session = s
    }

    /// The files EditMax has open under a folder (a drive's mount point), from the process's own descriptor table.
    nonisolated static func openFiles(under folder: String) -> [String] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        var out: [String] = []
        for fd in fds.prefix(max(0, Int(got)) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if path.hasPrefix(prefix) { out.append(path) }
        }
        return out
    }

    func releasing(_ volume: String) {
        Relink.setLeaving(volume, true)
        let released = players.allObjects.filter { $0.release(drive: volume) }
        if !released.isEmpty { DebugLog.event("drive-ejecting", ["volume": URL(fileURLWithPath: volume).lastPathComponent, "players": released.count]) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            Relink.setLeaving(volume, false)
            // The eject did not happen (another app kept the drive): the players pick its files up again, quietly.
            if FileManager.default.fileExists(atPath: volume) { for p in released { p.reload(reason: "eject-cancelled") } }
        }
    }

    func handle(_ c: Change) {
        if !c.mounted { Relink.setLeaving(c.path, false) }
        DebugLog.event(c.mounted ? "drive-mounted" : "drive-removed", ["name": c.name])
        AssetLibrary.shared.drivesChanged(mounted: c.mounted)
        NotificationCenter.default.post(name: .editmaxDriveChanged, object: nil, userInfo: ["change": c])
    }

    /// What a plugged-in or removed drive means for one open project, as the line the window shows; nil when the project
    /// uses nothing there. On a plug-in, files that are still missing follow their bookmarks (the drive came back under
    /// another name), and the drive's thumbnails and waveforms are read again.
    static func apply(_ c: Change, to document: EditMaxDocument) async -> String? {
        if c.mounted {
            var relinked = 0
            if !Relink.missing(document.project).isEmpty,
               let r = try? await ToolExecutor(document: document, origin: .user).relinkMedia(asset: nil, path: nil, folder: nil, recursive: false, dryRun: false) {
                relinked = r.relinked.count
            }
            let here = Relink.assets(onDrive: c.path, in: document.project)
            for a in here { ThumbnailStore.shared.refresh(a); WaveformStore.shared.refresh(a) }
            let n = Relink.clipCount(using: Set(here.map(\.id)), in: document.project)
            guard n > 0 || relinked > 0 else { return nil }
            return "\(c.name) is connected: \(max(n, relinked)) clip\(max(n, relinked) == 1 ? " is" : "s are") back online"
        }
        let gone = Relink.assets(onDrive: c.path, in: document.project)
        let n = Relink.clipCount(using: Set(gone.map(\.id)), in: document.project)
        guard n > 0 else { return nil }
        return "\(c.name) was disconnected: \(n) clip\(n == 1 ? " is" : "s are") offline until you plug it back in"
    }
}

/// The editor window's side of DriveWatcher: when a drive its project uses comes or goes, the player is rebuilt (offline
/// clips play as a gap) and a line at the top says what happened.
struct DriveNotices: ViewModifier {
    @ObservedObject var document: EditMaxDocument
    @ObservedObject var state: EditorState
    let player: PlayerController

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .editmaxDriveChanged)) { n in
                guard let c = n.userInfo?["change"] as? DriveWatcher.Change else { return }
                Task {
                    guard let line = await DriveWatcher.apply(c, to: document) else { return }
                    player.reload(reason: c.mounted ? "drive-mounted" : "drive-removed")
                    state.notify(line)
                }
            }
            .overlay(alignment: .top) {
                if state.exportStatus == nil, let s = state.notice {
                    Label(s, systemImage: "externaldrive").font(.caption).lineLimit(1)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .liquidGlass()
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .uiFrame("editor.notice")
                }
            }
            .animation(.snappy, value: state.notice)
    }
}

extension Notification.Name {
    /// A drive was plugged in or removed; userInfo "change" is a `DriveWatcher.Change`.
    static let editmaxDriveChanged = Notification.Name("io.openhorizon.editmax.driveChanged")
}
