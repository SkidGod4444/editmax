import XCTest
import AVFoundation
import AppKit
@testable import EditMax

/// Real media files for the library tests, written into a test's own folder.
@MainActor
enum LibraryFixtures {
    /// The 2 s H.264 fixture under another name.
    static func video(_ dir: URL, _ name: String = "Clip.mp4") throws -> URL {
        let src = try XCTUnwrap(Bundle(for: NotchDrawerTests.self).url(forResource: "base", withExtension: "mp4"))
        let dst = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    /// A picture: a diagonal gradient with a disc, so a thumbnail of it is recognisable.
    static func image(hue: Double, width: Int = 320, height: Int = 200) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let a = NSColor(hue: hue, saturation: 0.6, brightness: 0.85, alpha: 1).cgColor, b = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.35, alpha: 1).cgColor
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [a, b] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.fillEllipse(in: CGRect(x: width / 2 - height / 5, y: height / 2 - height / 5, width: height * 2 / 5, height: height * 2 / 5))
        return ctx.makeImage()!
    }

    static func png(_ dir: URL, _ name: String = "Photo.png", hue: Double = 0.58) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try XCTUnwrap(NSBitmapImageRep(cgImage: image(hue: hue)).representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// One second of a 440 Hz tone.
    static func wav(_ dir: URL, _ name: String = "Tone.wav", seconds: Double = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = Float(0.3 * sin(2 * Double.pi * 440 * Double(i) / 44_100)) }
        try file.write(from: buf)
        return url
    }

    /// A real font file (one that ships with macOS) under another name.
    static func font(_ dir: URL, _ name: String = "Brand Script.ttf") throws -> URL {
        let src = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Apple Chancery.ttf")
        guard FileManager.default.fileExists(atPath: src.path) else { throw XCTSkip("no Apple Chancery on this Mac") }
        let dst = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }
}

/// A test's own library index and copy folder, so nothing reaches the user's Assets.
@MainActor
class LibraryTestCase: XCTestCase {
    var dir: URL!
    private var savedIndex: URL!
    private var savedStore: URL?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("drawer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedIndex = AssetLibrary.indexURL; savedStore = AssetLibrary.storeOverride
        AssetLibrary.indexURL = dir.appendingPathComponent("library.json")
        AssetLibrary.storeOverride = dir.appendingPathComponent("Store", isDirectory: true)
        AssetLibrary.shared.load()
        NotchDrawer.shared.preview(mode: .collapsed, geometry: NotchDrawerTests.macBook)
    }
    override func tearDown() async throws {
        AssetLibrary.indexURL = savedIndex; AssetLibrary.storeOverride = savedStore
        AssetLibrary.shared.load()
        NotchDrawer.shared.preview(mode: .collapsed, geometry: NotchDrawerTests.macBook)
        try? FileManager.default.removeItem(at: dir)
    }
}

/// The notch drawer: where it sits, what a drop does (copies into Assets, touches no project), and what new downloads do.
@MainActor
final class NotchDrawerTests: LibraryTestCase {
    /// The user's MacBook: 1352×878 points, safe area top 28.5, the menu bar left of the notch ends at 593.5 and the
    /// right part starts at 758.5.
    static let macBook = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1352, height: 878),
                                       notch: NotchGeometry.notch(screen: CGRect(x: 0, y: 0, width: 1352, height: 878), safeTop: 28.5, leftWidth: 593.5, rightWidth: 1352 - 758.5)!,
                                       isPill: false)

    // MARK: Geometry

    func testTheNotchOfTheMacBookScreen() {
        let g = Self.macBook
        XCTAssertEqual(g.notch, CGRect(x: 593.5, y: 849.5, width: 165, height: 28.5))
        XCTAssertEqual(g.notch.midX, 676, "centred")
        // Collapsed: the notch, 20 pt each side, and the two small ears at the top.
        XCTAssertEqual(g.collapsedBody, CGSize(width: 205, height: 28.5))
        XCTAssertEqual(g.collapsedFrame, CGRect(x: 567.5, y: 849.5, width: 217, height: 28.5))
        // Open: 440 wide and about 190 tall, hanging from the top of the screen, centred on the notch.
        XCTAssertEqual(g.openBody.width, 440)
        XCTAssertEqual(g.openBody.height, 189.5, accuracy: 0.01)
        let open = g.frame(around: g.openBody)
        XCTAssertEqual(open.midX, 676)
        XCTAssertEqual(open.maxY, 878)
        XCTAssertLessThan(g.peekBody.height, g.openBody.height)
    }

    func testTheNotchFollowsTheScreenWhereverItSits() throws {
        // The built-in screen to the left of a main display: its frame starts at x -1352.
        let screen = CGRect(x: -1352, y: 0, width: 1352, height: 878)
        let n = try XCTUnwrap(NotchGeometry.notch(screen: screen, safeTop: 28.5, leftWidth: 593.5, rightWidth: 593.5))
        XCTAssertEqual(n.minX, -758.5)
        XCTAssertEqual(n.width, 165)
    }

    func testAScreenWithoutANotchGetsAPillAtTheTop() {
        XCTAssertNil(NotchGeometry.notch(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeTop: 0, leftWidth: nil, rightWidth: nil))
        let g = NotchGeometry.pill(on: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertTrue(g.isPill)
        XCTAssertEqual(g.notch.midX, 960)
        XCTAssertEqual(g.notch.maxY, 1080)
        XCTAssertEqual(g.collapsedFrame.maxY, 1080)
        XCTAssertEqual(g.collapsedFrame.height, NotchGeometry.pillHit.height)
    }

    // MARK: Drop

    func testADropCopiesTheFilesIntoAssets() async throws {
        let video = try LibraryFixtures.video(dir), photo = try LibraryFixtures.png(dir), tone = try LibraryFixtures.wav(dir)
        let notes = dir.appendingPathComponent("notes.txt"); try Data("x".utf8).write(to: notes)
        let r = await NotchDrawer.shared.handleDrop([video, photo, tone, notes])
        XCTAssertEqual(r.added.count, 3)
        XCTAssertEqual(r.failures.count, 1, "the text file is skipped")
        XCTAssertEqual(r.message, "Added 3 files to Assets. 1 could not be added")
        XCTAssertEqual(NotchDrawer.shared.message, r.message, "the drawer says what happened")
        XCTAssertEqual(Set(r.added.map(\.kind)), [.video, .image, .audio])
        let store = AssetLibrary.storeDirectory.standardizedFileURL.path
        for item in r.added {
            XCTAssertEqual(item.source, .drawer)
            XCTAssertTrue(item.path.hasPrefix(store + "/"), "copied into EditMax's Assets folder")
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
            XCTAssertNotNil(item.original)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path), "the original stays")
        let again = await NotchDrawer.shared.handleDrop([video])
        XCTAssertEqual(again.message, "Already in Assets")
        XCTAssertEqual(AssetLibrary.shared.all.count, 3)
    }

    func testADropChangesNoProjectAndNoView() async throws {
        let video = try LibraryFixtures.video(dir)
        let doc = EditMaxDocument()
        doc.project.assets = [Asset(name: "a.mp4", path: "/tmp/a.mp4", kind: .video, duration: 10)]
        let clip = Clip(assetID: doc.project.assets[0].id, name: "a", start: 0, duration: 4)
        doc.project.tracks[0].clips = [clip]
        DocumentRegistry.shared.register(doc)   // the active project, as when the user works in the editor
        let state = EditorState()
        state.inspectorTab = .history; state.focusMode = true; state.selectedClipIDs = [clip.id]
        let before = doc.project, revision = doc.revision

        _ = await NotchDrawer.shared.handleDrop([video])
        _ = await NotchDrawer.shared.addDownload(try LibraryFixtures.png(dir))

        XCTAssertEqual(doc.project, before, "nothing is imported into the open project")
        XCTAssertEqual(doc.revision, revision)
        XCTAssertEqual(state.inspectorTab, .history)
        XCTAssertTrue(state.focusMode)
        XCTAssertEqual(state.selectedClipIDs, [clip.id])
        XCTAssertEqual(AssetLibrary.shared.all.count, 2)

        // Unregistering the last document brings Home back 0.2 s later unless the app is quitting: not in a test.
        AppDelegate.quitting = true
        DocumentRegistry.shared.unregister(doc)
        try await Task.sleep(for: .milliseconds(350))
        AppDelegate.quitting = false
    }

    // MARK: Downloads

    func testNewDownloadsAreListedAndPeekedAt() async throws {
        let drawer = NotchDrawer.shared
        let files = try (0..<7).map { try LibraryFixtures.png(dir, "shot\($0).png", hue: Double($0) / 7) }
        drawer.handleNewDownload(files[0])
        XCTAssertEqual(drawer.mode, .peek, "a new download makes the closed drawer peek")
        XCTAssertEqual(drawer.peeking, files[0])
        for f in files.dropFirst() { drawer.handleNewDownload(f) }
        XCTAssertEqual(drawer.downloads.first, files[6], "newest first")
        XCTAssertEqual(drawer.downloads.count, NotchDrawer.maxDownloads)

        XCTAssertFalse(drawer.isInLibrary(files[6]))
        let r = await drawer.addDownload(files[6])
        XCTAssertEqual(r.added.first?.source, .download)
        XCTAssertTrue(r.added.first.map { AssetLibrary.shared.isCopy($0) } ?? false, "copied: Downloads gets cleaned")
        XCTAssertTrue(drawer.isInLibrary(files[6]), "the row now shows it is in Assets")
    }

    func testDownloadsFilterSkipsPartialHiddenAndOtherFiles() throws {
        func file(_ name: String) throws -> URL { let u = dir.appendingPathComponent(name); try Data([1, 2, 3]).write(to: u); return u }
        XCTAssertTrue(DownloadsWatcher.isCandidate(try file("Interview.mov")))
        XCTAssertTrue(DownloadsWatcher.isCandidate(try file("song.mp3")))
        XCTAssertTrue(DownloadsWatcher.isCandidate(try file("cover.JPG")))
        XCTAssertTrue(DownloadsWatcher.isCandidate(try file("Brand.otf")))
        for skipped in ["Interview.mov.crdownload", "clip.mp4.part", "upload.tmp", "Unconfirmed 1234.crdownload", ".hidden.mp4", ".DS_Store", "notes.txt", "setup.dmg", "archive.zip"] {
            XCTAssertFalse(DownloadsWatcher.isCandidate(try file(skipped)), skipped)
        }
        // Safari writes into a .download package (a folder) and renames it when done.
        let package = dir.appendingPathComponent("Film.mov.download", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertFalse(DownloadsWatcher.isCandidate(package))
        let folder = dir.appendingPathComponent("Clips.mov", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(DownloadsWatcher.isCandidate(folder), "a folder is never offered")
        XCTAssertFalse(DownloadsWatcher.isCandidate(dir.appendingPathComponent("gone.mov")), "nor a file that is not there")
    }

    func testOnlyFilesThatArriveAndFinishAreReported() throws {
        try Data(repeating: 1, count: 100).write(to: dir.appendingPathComponent("old.mov"))
        var got: [String] = []
        let w = DownloadsWatcher(directory: dir) { got.append($0.lastPathComponent) }
        w.start()
        XCTAssertTrue(w.isRunning)
        defer { w.stop() }

        // A browser writes a partial file, then renames it when it is done.
        let partial = dir.appendingPathComponent("Talk.mp4.crdownload")
        try Data(repeating: 2, count: 500).write(to: partial)
        w.scan()
        XCTAssertTrue(w.pending.isEmpty, "a partial file is not watched")
        try FileManager.default.moveItem(at: partial, to: dir.appendingPathComponent("Talk.mp4"))
        w.scan()
        XCTAssertEqual(Array(w.pending.keys), ["Talk.mp4"])
        w.checkPending()
        XCTAssertEqual(got, [], "one size is not enough to know it has stopped growing")
        w.checkPending()
        XCTAssertEqual(got, ["Talk.mp4"])
        w.scan(); w.checkPending(); w.checkPending()
        XCTAssertEqual(got, ["Talk.mp4"], "reported once; the file there at the start never")
    }

    func testAFileStillGrowingWaitsUntilItsSizeSettles() throws {
        var got: [String] = []
        let w = DownloadsWatcher(directory: dir) { got.append($0.lastPathComponent) }
        w.start(); defer { w.stop() }
        let url = dir.appendingPathComponent("Long.mov")
        FileManager.default.createFile(atPath: url.path, contents: Data())   // Firefox puts an empty file there first
        w.scan(); w.checkPending(); w.checkPending()
        XCTAssertEqual(got, [], "an empty file is not finished")
        let h = try FileHandle(forWritingTo: url)
        try h.write(contentsOf: Data(repeating: 3, count: 1000))
        w.checkPending()
        try h.write(contentsOf: Data(repeating: 3, count: 1000))
        try h.close()
        w.checkPending()
        XCTAssertEqual(got, [], "still growing")
        w.checkPending()
        XCTAssertEqual(got, ["Long.mov"])
    }

    func testTheFolderWatchNoticesANewFileOnItsOwn() async throws {
        let seen = expectation(description: "new download reported")
        var got: [URL] = []
        let w = DownloadsWatcher(directory: dir, interval: 0.1) { got.append($0); seen.fulfill() }
        w.start(); defer { w.stop() }
        _ = try LibraryFixtures.png(dir, "Arrived.png")
        await fulfillment(of: [seen], timeout: 5)
        XCTAssertEqual(got.map(\.lastPathComponent), ["Arrived.png"])
    }

    func testAFolderThatCannotBeReadIsReportedAsDenied() {
        let w = DownloadsWatcher(directory: dir.appendingPathComponent("does-not-exist")) { _ in }
        w.start()
        XCTAssertTrue(w.denied)
        XCTAssertFalse(w.isRunning)
    }

    func testTheDrawerIsOffInTests() {
        XCTAssertFalse(AppSettings.shared.notchDrawer)
        XCTAssertFalse(AppSettings.shared.watchDownloads)
        NotchDrawer.shared.start()
        XCTAssertFalse(NotchDrawer.shared.isShowing, "no panel under XCTest")
    }
}
