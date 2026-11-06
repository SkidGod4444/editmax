import XCTest
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
