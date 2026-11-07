import XCTest
import MCP
@testable import EditMax

/// The Assets library's hooks into projects (an import registers, open and save keep "Used in" right, a trashed project
/// is forgotten) and the list_library / add_to_library tools. Every test runs on its own index and store folder.
@MainActor
final class LibraryHookTests: XCTestCase {
    private var dir: URL!
    private var savedIndex: URL!
    private var savedStore: URL?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("libhooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The files the tests name: a project only lists media that is on disk.
        for f in ["a.png", "b.wav"] { try Data().write(to: dir.appendingPathComponent(f)) }
        savedIndex = AssetLibrary.indexURL; savedStore = AssetLibrary.storeOverride
        AssetLibrary.indexURL = dir.appendingPathComponent("library.json")
        AssetLibrary.storeOverride = dir.appendingPathComponent("Store", isDirectory: true)
        AssetLibrary.shared.load()
    }
    override func tearDown() async throws {
        AssetLibrary.indexURL = savedIndex; AssetLibrary.storeOverride = savedStore
        AssetLibrary.shared.load()
        try? FileManager.default.removeItem(at: dir)
    }

    /// The 2 s H.264 fixture, copied under a name of our own so the test owns the file.
    private func media(_ name: String = "Beach.mp4") throws -> URL {
        let src = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4"))
        let dst = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }
    private func project(_ name: String) -> (EditMaxDocument, URL) {
        let doc = EditMaxDocument()
        let url = dir.appendingPathComponent("\(name).emx")
        doc.fileURL = url
        return (doc, url)
    }
    // EditMax.LibraryItem: SwiftUI's DeveloperToolsSupport has a LibraryItem too.
    private func item(at url: URL) -> EditMax.LibraryItem? { AssetLibrary.shared.all.first { $0.path == url.standardizedFileURL.path } }

    func testAnImportRegistersTheFileAndTheProject() async throws {
        let file = try media()
        let (doc, url) = project("Trip")
        try await ToolExecutor(document: doc, origin: .user).importMedia(paths: [file.path])
        let it = try XCTUnwrap(item(at: file), "an import into a project puts the file in the library")
        XCTAssertEqual(it.kind, .video)
        XCTAssertEqual(it.source, .project)
        XCTAssertEqual(it.usedIn[AssetLibrary.projectID(for: url).uuidString], "Trip")
        XCTAssertEqual(it.path, file.path, "referenced where it is, not copied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AssetLibrary.storeDirectory.path))
    }

    func testAnImportIntoAProjectWithoutAFileStillRegisters() async throws {
        let file = try media()
        let doc = EditMaxDocument()
        try await ToolExecutor(document: doc, origin: .agent).importMedia(paths: [file.path])
        let it = try XCTUnwrap(item(at: file))
        XCTAssertTrue(it.usedIn.isEmpty, "no file, so no project to name")
    }

    func testSaveRecordsAndDropsWhatTheProjectUses() throws {
        let (doc, url) = project("Trip")
        let key = AssetLibrary.projectID(for: url).uuidString
        let a = Asset(name: "a.png", path: dir.appendingPathComponent("a.png").path, kind: .image, duration: 5)
        let b = Asset(name: "b.wav", path: dir.appendingPathComponent("b.wav").path, kind: .audio, duration: 3)
        doc.project.assets = [a, b]
        doc.autosaveNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(AssetLibrary.shared.all.first { $0.path == a.path }?.usedIn[key], "Trip")
        XCTAssertEqual(AssetLibrary.shared.all.first { $0.path == b.path }?.usedIn[key], "Trip")
        XCTAssertEqual(AssetLibrary.shared.all.first { $0.path == b.path }?.kind, .audio)

        doc.apply("Remove b", origin: .user) { p in _ = p.removeAsset(b.id) }
        doc.autosaveNow()
        XCTAssertEqual(AssetLibrary.shared.all.first { $0.path == a.path }?.usedIn[key], "Trip")
        XCTAssertNil(AssetLibrary.shared.all.first { $0.path == b.path }?.usedIn[key], "a removed asset no longer says it is used there")
        XCTAssertNotNil(AssetLibrary.shared.all.first { $0.path == b.path }, "but it stays in the library")
    }

    func testOpeningAgainKeepsOneEntryPerProject() throws {
        let (doc, url) = project("Trip")
        doc.project.assets = [Asset(name: "a.png", path: dir.appendingPathComponent("a.png").path, kind: .image, duration: 5)]
        doc.noteLibraryUse()
        // The same file, reopened: a new document (new id) under the same path, spelled differently.
        let again = EditMaxDocument()
        again.project = doc.project
        again.fileURL = URL(fileURLWithPath: dir.appendingPathComponent("x/../Trip.emx").path)
        again.noteLibraryUse()
        XCTAssertEqual(AssetLibrary.projectID(for: url), AssetLibrary.projectID(for: again.fileURL!))
        XCTAssertEqual(AssetLibrary.shared.all.first?.usedIn.count, 1)
    }

    func testForgetProjectClearsUsedIn() {
        let pid = UUID()
        AssetLibrary.shared.noteUsed([Asset(name: "a.png", path: dir.appendingPathComponent("a.png").path, kind: .image, duration: 5)], projectID: pid, projectName: "Gone")
        AssetLibrary.shared.forgetProject(pid)
        XCTAssertEqual(AssetLibrary.shared.all.first?.usedIn, [:])
    }

    func testACopyIsMadeOnceAndRemembersItsOriginal() async throws {
        let file = try media("Clip.mp4")
        let first = await AssetLibrary.shared.add(urls: [file], source: .drawer, copy: true)
        let again = await AssetLibrary.shared.add(urls: [file], source: .drawer, copy: true)
        let it = try XCTUnwrap(first.items.first)
        XCTAssertEqual(again.items.first?.id, it.id)
        XCTAssertTrue(it.path.hasPrefix(AssetLibrary.storeDirectory.standardizedFileURL.path + "/"))
        XCTAssertEqual(it.original, file.standardizedFileURL.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: AssetLibrary.storeDirectory.path).count, 1, "one copy")
        XCTAssertEqual(it.duration ?? 0, 2, accuracy: 0.1)
    }

    // MARK: MCP tools

    private func json(_ p: EditMaxTools.Payload) throws -> Any { try JSONSerialization.jsonObject(with: Data(p.text.utf8)) }

    func testAddToLibraryAndListLibraryWorkWithNoProjectOpen() async throws {
        let file = try media("Interview.mp4")
        let png = dir.appendingPathComponent("notes.txt"); try Data("x".utf8).write(to: png)
        let addResult = try await EditMaxTools.call("add_to_library", ["paths": .array([.string(file.path), .string(png.path)])])
        let added = try json(addResult) as? [String: Any]
        let items = try XCTUnwrap(added?["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["path"] as? String, file.path, "referenced by default")
        XCTAssertEqual((added?["skipped"] as? [String])?.count, 1, "the text file is skipped and named")

        let listResult = try await EditMaxTools.call("list_library", ["kind": .string("video"), "search": .string("inter")])
        let listed = try XCTUnwrap(try json(listResult) as? [[String: Any]])
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["kind"] as? String, "video")
        XCTAssertEqual(listed.first?["used_in"] as? [String], [])
        let seconds = listed.first?["duration"] as? Double ?? 0
        XCTAssertEqual(seconds, 2, accuracy: 0.1)
        let audioResult = try await EditMaxTools.call("list_library", ["kind": .string("audio")])
        let none = try XCTUnwrap(try json(audioResult) as? [[String: Any]])
        XCTAssertTrue(none.isEmpty)
    }

    func testAddToLibraryCopiesWhenAsked() async throws {
        let file = try media("Download.mp4")
        let result = try await EditMaxTools.call("add_to_library", ["paths": .array([.string(file.path)]), "copy": .bool(true)])
        let added = try json(result) as? [String: Any]
        let path = try XCTUnwrap((added?["items"] as? [[String: Any]])?.first?["path"] as? String)
        XCTAssertTrue(path.hasPrefix(AssetLibrary.storeDirectory.standardizedFileURL.path + "/"))
    }

    func testLibraryToolsRefuseBadArguments() async throws {
        do { _ = try await EditMaxTools.call("list_library", ["kind": .string("sculpture")]); XCTFail("bad kind accepted") } catch {}
        do { _ = try await EditMaxTools.call("add_to_library", ["paths": .array([])]); XCTFail("no paths accepted") } catch {}
        do { _ = try await EditMaxTools.call("list_library", ["project": .string("x")]); XCTFail("an argument it does not take was accepted") } catch {}
    }
}
