import XCTest
import SwiftUI
@testable import EditMax

/// EditMax's Archive: deleted files wait there for the period set in Settings, then are erased for good.
@MainActor
final class AppArchiveTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppArchive.directoryOverride = dir.appendingPathComponent("Archive", isDirectory: true)
        AppArchive.shared.load()
    }
    override func tearDown() async throws {
        AppArchive.directoryOverride = nil
        AppArchive.shared.load()
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data(repeating: 7, count: 1000).write(to: u)
        return u
    }

    func testDeletedFilesWaitThenAreErasedAfterThePeriod() throws {
        let days = AppSettings.shared.archiveDays
        let t0 = Date()
        let a = try AppArchive.shared.archive(try file("Old.mp4"), now: t0)
        let b = try AppArchive.shared.archive(try file("New.mp4"), now: t0.addingTimeInterval(Double(days - 2) * 86_400))
        XCTAssertEqual(AppArchive.shared.totalBytes, 2000)
        // A day before the first is due: nothing goes.
        XCTAssertEqual(AppArchive.shared.purge(now: t0.addingTimeInterval(Double(days - 1) * 86_400)), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        // Past it: the first is erased for good, the second waits.
        XCTAssertEqual(AppArchive.shared.purge(now: t0.addingTimeInterval(Double(days) * 86_400 + 60)), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertEqual(AppArchive.shared.entries.map(\.name), ["New.mp4"])
        // The list survives a relaunch.
        AppArchive.shared.load()
        XCTAssertEqual(AppArchive.shared.entries.map(\.name), ["New.mp4"])
    }

    func testTheSameNameTwiceKeepsBothAndEmptyNowErasesAll() throws {
        let a = try AppArchive.shared.archive(try file("Clip.mp4"))
        let b = try AppArchive.shared.archive(try file("Clip.mp4"))
        XCTAssertEqual(a.lastPathComponent, "Clip.mp4"); XCTAssertEqual(b.lastPathComponent, "Clip 2.mp4")
        XCTAssertEqual(AppArchive.shared.emptyNow(), 2)
        XCTAssertTrue(AppArchive.shared.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
    }

    func testAFileRemovedByHandIsForgotten() throws {
        let a = try AppArchive.shared.archive(try file("Gone.mp4"))
        try FileManager.default.removeItem(at: a)
        AppArchive.shared.purge()
        XCTAssertTrue(AppArchive.shared.entries.isEmpty)
    }

    func testRestorePutsAFileBackAndBesideWhenTheNameIsTaken() throws {
        let orig = try file("Intro.emx")
        let e1 = try AppArchive.shared.archive(orig, kind: .project, name: "Intro")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orig.path))
        _ = e1
        let id = try XCTUnwrap(AppArchive.shared.entries.last?.id)
        XCTAssertEqual(try AppArchive.shared.entry(matching: "intro").id, id, "found by name")
        XCTAssertEqual(try AppArchive.shared.entry(matching: id.short).id, id, "and by id prefix")
        try Data([1]).write(to: orig)   // something new took the name since
        let back = try AppArchive.shared.restore(id)
        XCTAssertEqual(back.lastPathComponent, "Intro 2.emx")
        XCTAssertEqual(try Data(contentsOf: back).count, 1000, "the archived file, unchanged")
        XCTAssertTrue(AppArchive.shared.entries.isEmpty, "out of the Archive")
    }

    func testTheWindowListsWhatCanBeRestored() throws {
        try AppArchive.shared.archive(try file("Beach day.mp4"), kind: .asset, now: Date().addingTimeInterval(-3_600))
        try AppArchive.shared.archive(try file("Launch video.emx"), kind: .project, name: "Launch video", now: Date().addingTimeInterval(-86_400 * 2))
        let dir2 = dir.appendingPathComponent("Inter", isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 300).write(to: dir2.appendingPathComponent("Inter-Regular.ttf"))
        try AppArchive.shared.archive(dir2, kind: .font, name: "Inter", now: Date().addingTimeInterval(-86_400 * 28))
        for dark in [true, false] {
            let h = OffscreenHost(ArchivePane(model: HomeModel()), size: CGSize(width: 760, height: 420), dark: dark)
            for e in AppArchive.shared.entries {
                XCTAssertNotNil(h.frame("archive.\(e.id.short).restore"), e.name)
                XCTAssertNotNil(h.frame("archive.\(e.id.short).erase"), e.name)
            }
            h.save("archive-window-\(dark ? "dark" : "light")")
            h.close()
        }
        XCTAssertEqual(AppArchive.shared.entries.first { $0.name == "Inter" }?.bytes, 300, "a folder counts what is in it")
    }

    /// Home's sidebar ends with the Archive (a place like Projects and Assets, with its count), and every row in the
    /// sidebar (places and links) has the same inset and height, so the icons line up.
    func testHomeSidebarHasTheArchiveAtTheBottom() throws {
        try AppArchive.shared.archive(try file("Old cut.emx"), kind: .project, name: "Old cut")
        GlassCompat.forceFallback = true   // glass does not draw offscreen; its stand-in does
        defer { GlassCompat.forceFallback = false }
        for dark in [true, false] {
            let model = HomeModel(); model.place = .archive
            let h = OffscreenHost(HomeView(part: .sidebar, model: model), size: CGSize(width: 250, height: 660), dark: dark)
            let archive = try XCTUnwrap(h.frame("home.place.archive"))
            let settings = try XCTUnwrap(h.frame("home.settings"))
            XCTAssertGreaterThan(archive.minY, settings.maxY + 40, "at the foot, not with the other links")
            XCTAssertLessThan(archive.maxY, 660 - 22 - 12, "with only the one-line footer under it")
            let byline = try XCTUnwrap(h.frame("home.byline"), "the maker's link")
            XCTAssertGreaterThan(byline.minY, archive.maxY)
            XCTAssertEqual(byline.minX, archive.minX + 8, accuracy: 0.5, "lined up with the rows' text inset")
            let rows = try ["home.place.projects", "home.place.assets", "home.open", "home.finder", "home.settings", "home.place.archive"].map { try XCTUnwrap(h.frame($0), $0) }
            for r in rows {
                XCTAssertEqual(r.minX, rows[0].minX, accuracy: 0.5, "same inset")
                XCTAssertEqual(r.width, rows[0].width, accuracy: 0.5, "same width")
                XCTAssertEqual(r.height, 28, accuracy: 0.5, "same height")
            }
            h.save("home-sidebar-\(dark ? "dark" : "light")")
            h.close()
            let foot = OffscreenHost(VStack(alignment: .leading, spacing: 18) {
                HomePlaceRow(place: .archive, title: "Archive", symbol: "archivebox", count: 1, model: model)
                HomeFooter()
            }.padding(22), size: CGSize(width: 250, height: 110), dark: dark)
            foot.save("home-sidebar-foot-\(dark ? "dark" : "light")")
            foot.close()
        }
    }

    /// Select mode: Select All, Restore and Erase act on the picked rows; each row shows a check instead of its buttons.
    func testSelectModeRestoresAndErasesSeveral() throws {
        GlassCompat.forceFallback = true
        defer { GlassCompat.forceFallback = false }
        let a = try file("A.mp4"), b = try file("B.mp4"), c = try file("C.mp4")
        for u in [a, b, c] { try AppArchive.shared.archive(u, kind: .asset) }
        let ids = AppArchive.shared.entries.map(\.id)
        for dark in [true, false] {
            let model = HomeModel()
            model.selectingArchive = true
            model.pickedArchive = [ids[0], ids[1]]
            let h = OffscreenHost(ArchivePane(model: model), size: CGSize(width: 760, height: 360), dark: dark)
            for id in ["archive.selectAll", "archive.restorePicked", "archive.erasePicked", "archive.done"] { XCTAssertNotNil(h.frame(id), id) }
            XCTAssertNil(h.frame("archive.reveal"), "the select bar replaces the usual buttons")
            for e in AppArchive.shared.entries {
                XCTAssertNotNil(h.frame("archive.\(e.id.short).check"), e.name)
                XCTAssertNil(h.frame("archive.\(e.id.short).restore"), "no row buttons while selecting")
            }
            h.save("archive-select-\(dark ? "dark" : "light")")
            h.close()
            model.selectingArchive = false
            XCTAssertTrue(model.pickedArchive.isEmpty, "Done clears the picks")
        }
        let r = AppArchive.shared.restore([ids[0], ids[1]])
        XCTAssertEqual(r.restored, 2); XCTAssertTrue(r.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertEqual(AppArchive.shared.erase(Set([ids[2]])), 1)
        XCTAssertTrue(AppArchive.shared.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.path))
    }

    /// A file on another drive (an export replaced on an external disk) stays on that drive, in a hidden folder at its
    /// root, so it is never copied onto the Mac's disk; Restore and the period work as for the rest.
    func testAFileOnAnotherDriveStaysOnThatDrive() throws {
        let drive = dir.appendingPathComponent("Drive", isDirectory: true)
        let renders = drive.appendingPathComponent("Renders", isDirectory: true)
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
        let real = AppArchive.volumeRoot
        AppArchive.volumeRoot = { $0.path.hasPrefix(drive.path) ? drive : URL(fileURLWithPath: "/") }
        defer { AppArchive.volumeRoot = real }
        XCTAssertEqual(AppArchive.folder(for: try file("Here.mp4")), AppArchive.directory, "same drive: the Archive folder")
        let cut = renders.appendingPathComponent("Final.mov")
        try Data(repeating: 3, count: 500).write(to: cut)
        XCTAssertEqual(AppArchive.shared.keepBeforeReplacing(cut).map { _ in true }, true)
        let e = try XCTUnwrap(AppArchive.shared.entries.last)
        XCTAssertEqual(e.path, drive.appendingPathComponent(".EditMax Archive/Final.mov").path, "kept on its own drive")
        XCTAssertEqual(AppArchive.driveName(of: e), "Drive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppArchive.directory.appendingPathComponent("Final.mov").path), "not copied to the Mac's disk")
        try AppArchive.shared.restore(e.id)
        XCTAssertEqual(try Data(contentsOf: cut).count, 500, "back where it was")
        AppArchive.shared.keepBeforeReplacing(cut)
        XCTAssertEqual(AppArchive.shared.purge(now: Date().addingTimeInterval(86_400 * 400)), 1, "erased when its time is up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive.appendingPathComponent(".EditMax Archive/Final.mov").path))
        // An unplugged drive: the item stays listed (not forgotten, not erased) until the drive is back.
        let offline = AppArchive.Entry(kind: .export, name: "Gone.mov", original: "/Volumes/Unplugged 9c1e/Renders/Gone.mov", path: "/Volumes/Unplugged 9c1e/.EditMax Archive/Gone.mov", archivedAt: .distantPast, bytes: 1)
        XCTAssertTrue(AppArchive.shared.isOffline(offline))
        XCTAssertEqual(AppArchive.driveName(of: offline), "Unplugged 9c1e")
    }

    /// Home in a real titled window (full-size content, see-through title bar): where the window buttons end and where
    /// the logo starts, and the page title beside it.
    func testHomeBrandSitsUnderTheWindowButtons() throws {
        GlassCompat.forceFallback = true
        defer { GlassCompat.forceFallback = false }
        let w = NSWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: 1000, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentViewController = HomeWindow.content(model: HomeModel(), size: NSSize(width: 1000, height: 660))
        defer { w.close() }
        for _ in 0..<6 { w.contentView?.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let close = try XCTUnwrap(w.standardWindowButton(.closeButton))
        let inWindow = close.convert(close.bounds, to: nil)
        let buttonsBottom = w.frame.height - inWindow.minY   // from the window's top edge
        let el = UIRegistry.shared.elements(in: w).visible
        let brand = try XCTUnwrap(el.first { $0.id == "home.brand" }?.rect)
        print("HOME-MEASURE buttonsBottom=\(buttonsBottom) brandTop=\(brand.minY) brandBottom=\(brand.maxY) contentTop=\(w.contentLayoutRect.maxY) frameH=\(w.frame.height)")
        XCTAssertGreaterThan(brand.minY, buttonsBottom, "below the window buttons")
        XCTAssertLessThan(brand.minY - buttonsBottom, 20, "right under them, not far below")
        if let dir = ColorFixtures.previewDir, let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("inspector-fixes/home-window-dark.png"))
        }
    }

    func testTheArchivePageWhenEmpty() throws {
        let h = OffscreenHost(ArchivePane(model: HomeModel()), size: CGSize(width: 760, height: 420), dark: true)
        XCTAssertNotNil(h.frame("archive.reveal")); XCTAssertNotNil(h.frame("archive.kind"))
        h.save("archive-page-empty-dark")
        h.close()
    }

    /// Settings asks before a shorter period erases anything: it needs the count first, and that count erases nothing.
    func testAShorterPeriodSaysHowManyItWouldErase() throws {
        let now = Date()
        try AppArchive.shared.archive(try file("Week old.mp4"), now: now.addingTimeInterval(-86_400 * 8))
        try AppArchive.shared.archive(try file("Yesterday.mp4"), now: now.addingTimeInterval(-86_400 * 1.5))
        try AppArchive.shared.archive(try file("Today.mp4"), now: now.addingTimeInterval(-3_600))
        XCTAssertEqual(AppArchive.shared.wouldErase(days: 30, now: now), 0)
        XCTAssertEqual(AppArchive.shared.wouldErase(days: 7, now: now), 1)
        XCTAssertEqual(AppArchive.shared.wouldErase(days: 1, now: now), 2)
        XCTAssertEqual(AppArchive.shared.entries.count, 3, "counting erases nothing")
    }

    func testSettingsAsksBeforeAShorterPeriod() throws {
        try AppArchive.shared.archive(try file("Old.mp4"), now: Date().addingTimeInterval(-86_400 * 10))
        let h = OffscreenHost(GeneralSettings(), size: CGSize(width: 520, height: 900), dark: true)
        defer { h.close() }
        XCTAssertNotNil(h.frame("settings.general.archiveDays"))
        XCTAssertEqual(AppArchive.shared.entries.count, 1)
    }

    /// Exporting over an earlier render keeps the earlier one in the Archive (the side agent's catch: it was erased).
    func testExportingOverAFileKeepsTheOldOneInTheArchive() async throws {
        let src = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4"))
        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .user)
        try await x.importMedia(paths: [src.path])
        _ = try x.insertClip(asset: "base.mp4")
        let out = dir.appendingPathComponent("Final cut.mp4")
        try Data("earlier render".utf8).write(to: out)
        _ = try await x.exportVideo(to: out.path, preset: .low)
        let kept = try XCTUnwrap(AppArchive.shared.entries.first { $0.kind == .export })
        XCTAssertEqual(kept.original, out.path)
        XCTAssertEqual(try String(contentsOfFile: kept.path, encoding: .utf8), "earlier render", "the earlier file, unchanged")
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0, 1000, "the new export is in its place")
        // A new name replaces nothing, so nothing is archived.
        _ = try await x.exportVideo(to: dir.appendingPathComponent("Other.mp4").path, preset: .low)
        XCTAssertEqual(AppArchive.shared.entries.filter { $0.kind == .export }.count, 1)
    }

    func testPeriodsOnOffer() {
        XCTAssertEqual(AppArchive.periods, [1, 7, 14, 30, 60, 90])
        XCTAssertTrue(AppArchive.periods.contains(AppArchive.defaultDays))
    }
}
