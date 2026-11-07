import XCTest
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
            let h = OffscreenHost(ArchiveView(), size: CGSize(width: 560, height: 300), dark: dark)
            for e in AppArchive.shared.entries {
                XCTAssertNotNil(h.frame("archive.\(e.id.short).restore"), e.name)
                XCTAssertNotNil(h.frame("archive.\(e.id.short).erase"), e.name)
            }
            h.save("archive-window-\(dark ? "dark" : "light")")
            h.close()
        }
        XCTAssertEqual(AppArchive.shared.entries.first { $0.name == "Inter" }?.bytes, 300, "a folder counts what is in it")
    }

    func testPeriodsOnOffer() {
        XCTAssertEqual(AppArchive.periods, [1, 7, 14, 30, 60, 90])
        XCTAssertTrue(AppArchive.periods.contains(AppArchive.defaultDays))
    }
}
