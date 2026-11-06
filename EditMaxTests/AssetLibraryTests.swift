import XCTest
import SwiftUI
@testable import EditMax

/// The Assets library: adds referenced or copied files, never twice, and records which projects use what.
@MainActor
final class AssetLibraryTests: XCTestCase {
    private var dir: URL!
    private var savedIndex: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedIndex = AssetLibrary.indexURL
        AssetLibrary.indexURL = dir.appendingPathComponent("library.json")
        AssetLibrary.shared.load()
    }
    override func tearDown() async throws {
        AssetLibrary.indexURL = savedIndex
        AssetLibrary.shared.load()
        try? FileManager.default.removeItem(at: dir)
    }

    func testAddsAFontOnceAndFindsItByKindAndName() async throws {
        let font = dir.appendingPathComponent("Brand Sans.otf")
        try Data([0, 1, 0, 0]).write(to: font)
        let first = await AssetLibrary.shared.add(urls: [font], source: .upload, copy: false)
        let again = await AssetLibrary.shared.add(urls: [font], source: .upload, copy: false)
        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(again.items.first?.id, first.items.first?.id, "the same file is not added twice")
        XCTAssertEqual(AssetLibrary.shared.items(kind: .font, search: "brand").count, 1)
        XCTAssertEqual(AssetLibrary.shared.items(kind: .video).count, 0)
    }

    func testSkipsFilesItCannotUse() async throws {
        let txt = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: txt)
        let r = await AssetLibrary.shared.add(urls: [txt], source: .drawer, copy: false)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.failures.count, 1)
    }

    func testNoteUsedRecordsTheProject() {
        let a = Asset(name: "a.png", path: dir.appendingPathComponent("a.png").path, kind: .image, duration: 5)
        let pid = UUID()
        AssetLibrary.shared.noteUsed([a], projectID: pid, projectName: "Trip")
        XCTAssertEqual(AssetLibrary.shared.items(kind: .image).first?.usedIn[pid.uuidString], "Trip")
        AssetLibrary.shared.load()   // survives a reload from disk
        XCTAssertEqual(AssetLibrary.shared.items(kind: .image).count, 1)
    }
}

/// A font dropped on the drawer or on Assets is installed (in the Font picker), not only stored as a file; Remove on
/// its card uninstalls it. Runs on a temporary library and fonts folder.
@MainActor
final class AssetLibraryFontRoutingTests: LibraryTestCase {
    private var savedFonts: URL!

    override func setUp() async throws {
        try await super.setUp()
        savedFonts = FontLibrary.directory
        FontLibrary.directory = dir.appendingPathComponent("Fonts", isDirectory: true)
    }

    override func tearDown() async throws {
        for f in FontLibrary.fontFiles(in: FontLibrary.directory) { FontLibrary.unregister(f) }
        FontLibrary.directory = savedFonts
        try await super.tearDown()
    }

    func testAFontAddedToBeKeptIsInstalledAsAFontAndRemoveUninstallsIt() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Plaster-Regular", withExtension: "ttf"))
        let dropped = dir.appendingPathComponent("Plaster-Regular.ttf")
        try FileManager.default.copyItem(at: fixture, to: dropped)

        let r = await AssetLibrary.shared.add(urls: [dropped], source: .drawer, copy: true)
        XCTAssertEqual(r.items.count, 1, "\(r.failures)")
        let item = try XCTUnwrap(r.items.first)
        XCTAssertTrue(item.path.hasPrefix(FontLibrary.customDirectory.standardizedFileURL.path + "/"), "in the fonts folder, not the Assets folder: \(item.path)")
        XCTAssertEqual(item.source, .drawer)
        XCTAssertEqual(item.original, dropped.path)
        XCTAssertTrue(TextFont.available("Plaster-Regular"), "registered, so the Font picker and the renderer have it")

        let f = try XCTUnwrap(FontLibrary.shared.installedFamily(ofFile: item.path))
        XCTAssertEqual(f.source, .custom)
        FontLibrary.shared.remove(family: f.family, source: f.source)
        XCTAssertFalse(TextFont.available("Plaster-Regular"))
        XCTAssertFalse(AssetLibrary.shared.all.contains { $0.id == item.id })
    }
}

/// An Assets tile is the size its card gives it, whatever the shape of the picture in it (a 16:9 or portrait video
/// thumbnail once made its tile wider than the card, into the next card).
@MainActor
final class LibraryTileLayoutTests: LibraryTestCase {
    func testAThumbnailOfAnyShapeStaysInsideItsTile() async throws {
        let video = try LibraryFixtures.video(dir, "Wide.mp4")
        let added = await AssetLibrary.shared.add(urls: [video], source: .project, copy: false)
        let item = try XCTUnwrap(added.items.first)
        for (w, h) in [(320, 200), (1920, 1080), (1080, 1920), (3840, 1600)] {
            LibraryThumbnails.shared.set(LibraryFixtures.image(hue: 0.5, width: w, height: h), for: item.id)
            let host = NSHostingController(rootView: LibraryTile(item: item, specimen: 40).aspectRatio(16 / 10, contentMode: .fit))
            let size = host.sizeThatFits(in: CGSize(width: 200, height: 10_000))
            XCTAssertEqual(size.width, 200, accuracy: 0.5, "\(w)×\(h) thumbnail")
            XCTAssertEqual(size.height, 125, accuracy: 0.5, "\(w)×\(h) thumbnail")
        }
    }
}
