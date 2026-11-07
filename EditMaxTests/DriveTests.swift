import XCTest
import AVFoundation
@testable import EditMax

/// Footage on drives (an SSD, a camera card): used where it is, offline while the drive is out, back when it returns.
/// A folder in the test's own directory stands in for a drive; unplugging it is moving it away.
@MainActor
final class DriveTests: LibraryTestCase {
    private var drive: URL { dir.appendingPathComponent("T7", isDirectory: true) }

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let d = drive.path
        AssetLibrary.keepsInPlaceOverride = { $0.path.hasPrefix(d + "/") }
    }
    override func tearDown() async throws {
        AssetLibrary.keepsInPlaceOverride = nil
        try await super.tearDown()
    }

    /// The user's ask: footage on a drive is not copied onto the Mac, even by a drop that copies other files.
    func testFootageOnADriveIsUsedWhereItIs() async throws {
        let onDrive = try LibraryFixtures.video(drive, "DJI_0001.MP4")
        let onMac = try LibraryFixtures.video(dir, "Screen.mp4")
        let r = await AssetLibrary.shared.addFiles([onDrive, onMac], source: .drawer, copy: true)
        XCTAssertEqual(r.added.count, 2)
        let kept = try XCTUnwrap(r.added.first { $0.name == "DJI_0001.MP4" })
        XCTAssertEqual(kept.path, onDrive.path, "referenced on the drive")
        XCTAssertFalse(AssetLibrary.shared.isCopy(kept))
        XCTAssertTrue(AssetLibrary.shared.isCopy(try XCTUnwrap(r.added.first { $0.name == "Screen.mp4" })), "a file on the Mac is still kept as before")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: AssetLibrary.storeDirectory.path).filter { $0.hasPrefix("DJI") }, [], "no copy in EditMax's folder")
    }

    func testTheAddSaysWhereFootageWasLeft() {
        let item = LibraryItem(name: "C0001.MP4", path: "/Volumes/T7 Shield 4c2e/Footage/C0001.MP4", kind: .video, source: .drawer)
        XCTAssertEqual(LibraryAddResult(added: [item], existing: [], failures: []).message, "Added 1 file to Assets, left on T7 Shield 4c2e")
    }

    /// Unplugged mid-edit: the preview still builds (those clips are a gap), and an export says which drive to plug in.
    func testOfflineClipsAreAGapAndExportNamesTheDrive() async throws {
        let a = try LibraryFixtures.video(drive, "A.mp4"), b = try LibraryFixtures.video(dir, "B.mp4")
        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .user)
        _ = try await x.importMedia(paths: [a.path, b.path])
        _ = try x.insertClip(asset: "A.mp4", at: 0)
        _ = try x.insertClip(asset: "B.mp4", at: 2)
        let unplugged = dir.appendingPathComponent("unplugged", isDirectory: true)
        try FileManager.default.moveItem(at: drive, to: unplugged)   // the drive is pulled out
        let p = doc.project
        XCTAssertEqual(Relink.offline(p).count, 1)
        XCTAssertEqual(Relink.clipCount(using: Relink.offline(p), in: p), 1)
        let out = try await CompositionBuilder.build(p, forPreview: true)   // threw "cannot open" before
        XCTAssertEqual(out.duration.seconds, p.duration, accuracy: 0.05, "the timeline keeps its length; the clip is a gap")
        XCTAssertThrowsError(try Relink.requireOnline(p)) { XCTAssertTrue("\($0)".contains("missing"), "\($0)") }
        // The same on a real /Volumes path that is not mounted: the message names the drive.
        var q = p
        if let i = q.assets.firstIndex(where: { $0.name == "A.mp4" }) { q.assets[i].path = "/Volumes/OSMO 7d1a/DCIM/A.mp4" }
        XCTAssertThrowsError(try Relink.requireOnline(q)) { XCTAssertTrue("\($0)".contains("1 clip uses files on OSMO 7d1a, which is not connected. Plug it in to export."), "\($0)") }
    }

    /// The window's line for a drive going and coming, and only for projects that use it.
    func testTheOpenProjectHearsAboutItsDrive() async throws {
        let a = try LibraryFixtures.video(drive, "A.mp4")
        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .user)
        _ = try await x.importMedia(paths: [a.path])
        _ = try x.insertClip(asset: "A.mp4", at: 0); _ = try x.insertClip(asset: "A.mp4", at: 2)
        let out = await DriveWatcher.apply(.init(name: "T7", path: drive.path, mounted: false), to: doc)
        XCTAssertEqual(out, "T7 was disconnected: 2 clips are offline until you plug it back in")
        let back = await DriveWatcher.apply(.init(name: "T7", path: drive.path, mounted: true), to: doc)
        XCTAssertEqual(back, "T7 is connected: 2 clips are back online")
        let other = await DriveWatcher.apply(.init(name: "Card", path: dir.appendingPathComponent("Card").path, mounted: false), to: doc)
        XCTAssertNil(other, "a drive the project does not use says nothing")
    }

    /// An eject: the player lets go of a drive only when clips play files from it, and picks up where it was after.
    func testThePlayerLetsGoOfADriveOnlyWhenItsClipsUseIt() async throws {
        let a = try LibraryFixtures.video(drive, "A.mp4"), b = try LibraryFixtures.video(dir, "B.mp4")
        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .user)
        _ = try await x.importMedia(paths: [a.path, b.path])
        _ = try x.insertClip(asset: "B.mp4", at: 0)
        let player = PlayerController()
        player.player.isMuted = true
        player.bind(to: doc)
        player.rebuild(doc.project)
        try await until("first build") { player.lastOutput != nil && player.player.currentItem != nil }
        XCTAssertFalse(player.release(drive: drive.path), "A.mp4 is only in the media list: nothing to let go of")
        XCTAssertNotNil(player.player.currentItem)

        _ = try x.insertClip(asset: "A.mp4", at: 2)
        try await until("rebuilt with A") { (player.lastOutput?.duration.seconds ?? 0) > 3.5 && player.player.currentItem?.status == .readyToPlay }
        await player.player.seek(to: CMTime(seconds: 2.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(player.release(drive: drive.path))
        XCTAssertNil(player.player.currentItem, "no file on the drive is held open")
        player.reload(reason: "test")
        try await until("rebuilt after the release") { player.lastOutput != nil && player.player.currentItem != nil && abs(player.player.currentTime().seconds - 2.5) < 0.05 }
    }

    private func until(_ what: String, _ ok: () -> Bool) async throws {
        for _ in 0..<120 { if ok() { return }; try await Task.sleep(for: .milliseconds(50)) }
        XCTFail("timed out: \(what)")
    }

    /// The drive comes back under another name ("Untitled 1"): Assets and the open project follow the files there.
    func testADriveBackUnderAnotherNameIsFollowed() async throws {
        let a = try LibraryFixtures.video(drive, "A.mp4")
        _ = await AssetLibrary.shared.addFiles([a], source: .drawer, copy: true)
        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .user)
        _ = try await x.importMedia(paths: [a.path])
        _ = try x.insertClip(asset: "A.mp4", at: 0)
        let renamed = dir.appendingPathComponent("T7 1", isDirectory: true)
        try FileManager.default.moveItem(at: drive, to: renamed)
        AssetLibrary.shared.drivesChanged(mounted: true)
        let real = { (p: String?) in p.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }   // /var is /private/var
        XCTAssertEqual(real(AssetLibrary.shared.all.first { $0.name == "A.mp4" }?.path), real(renamed.appendingPathComponent("A.mp4").path))
        let line = await DriveWatcher.apply(.init(name: "T7 1", path: renamed.path, mounted: true), to: doc)
        XCTAssertEqual(real(doc.project.assets.first?.path), real(renamed.appendingPathComponent("A.mp4").path), "the project follows its bookmark")
        XCTAssertEqual(line, "T7 1 is connected: 1 clip is back online")
    }
}

/// A real drive: a disk image attached under /Volumes (hidden from the Finder). Run on demand with
/// TEST_RUNNER_EDITMAX_DMG_TEST=1: it checks that a mounted drive counts as external (footage left in place) and that
/// EditMax playing a file from it does not stop the drive from being ejected.
@MainActor
final class RealDriveTests: XCTestCase {
    private func hdiutil(_ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    nonisolated private func hdiutilOff(_ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    func testARealDriveIsExternalAndCanBeEjectedWhilePlaying() async throws {
        guard ProcessInfo.processInfo.environment["EDITMAX_DMG_TEST"] == "1" else { throw XCTSkip("set TEST_RUNNER_EDITMAX_DMG_TEST=1") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dmg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let name = "EMX Test \(UUID().uuidString.prefix(4))"
        let image = tmp.appendingPathComponent("drive.dmg")
        XCTAssertEqual(hdiutil(["create", "-size", "40m", "-fs", "APFS", "-volname", name, image.path]).0, 0)
        XCTAssertEqual(hdiutil(["attach", "-nobrowse", image.path]).0, 0)
        let volume = URL(fileURLWithPath: "/Volumes/\(name)")
        defer { _ = hdiutil(["detach", "-force", volume.path]) }
        let clip = try LibraryFixtures.video(volume, "DJI_0001.MP4")
        XCTAssertTrue(AssetLibrary.keepsInPlace(clip), "a mounted drive is external")
        XCTAssertFalse(AssetLibrary.keepsInPlace(try LibraryFixtures.video(tmp, "Mac.mp4")), "the Mac's own disk is not")
        XCTAssertEqual(Relink.driveName(of: clip.path), name)

        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .user)
        _ = try await x.importMedia(paths: [clip.path])
        _ = try x.insertClip(asset: "DJI_0001.MP4", at: 0)
        let player = PlayerController()
        player.bind(to: doc)
        DriveWatcher.shared.register(player)
        DriveWatcher.shared.watchEjects()
        player.rebuild(doc.project, reason: "dmg-test")
        try await Task.sleep(for: .seconds(1.5))
        player.player.isMuted = true   // the fixture's sound is a test tone: never through the speakers
        player.player.play()
        try await Task.sleep(for: .seconds(0.5))
        // A normal eject, not forced, run off the main thread so macOS can ask EditMax first (as the Finder's would).
        let (status, out) = await Task.detached { [self] in await MainActor.run { () -> Void in }; return self.hdiutilOff(["detach", volume.path]) }.value
        print("DMG-EJECT status=\(status) out=\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        XCTAssertEqual(status, 0, "EditMax playing a file there must not hold the drive: \(out)")
        player.player.pause()
        // Unplugged: the preview builds with the clip as a gap, the export names the drive.
        let built = try await CompositionBuilder.build(doc.project, forPreview: true)
        XCTAssertGreaterThan(built.duration.seconds, 1)
        XCTAssertThrowsError(try Relink.requireOnline(doc.project)) { XCTAssertTrue("\($0)".contains("on \(name), which is not connected"), "\($0)") }
    }
}
