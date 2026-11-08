import XCTest
import AVFoundation
@testable import EditMax

/// Relink and consolidate, on copies of the test fixture in a temporary folder (never the user's media).
@MainActor
final class EditingMediaTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }
    private var p: Project { doc.project }
    private var root: URL!

    override func setUp() async throws {
        doc = EditMaxDocument()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("editing-media-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func fixture() throws -> URL { try XCTUnwrap(Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4")) }
    private func message(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }

    /// Copies the fixture to `dir/name` and returns it probed as an asset.
    private func media(_ name: String, in dir: String) async throws -> Asset {
        let folder = root.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: try fixture(), to: url)
        return try await MediaImporter.probe(url)
    }

    /// An asset whose file is moved away (inside the temp folder) after import, so it is missing.
    private func missingAsset(_ name: String, movedTo dir: String, newName: String? = nil) async throws -> Asset {
        var a = try await media(name, in: "original")
        a.bookmark = nil   // the bookmark would find it; these tests exercise the folder search
        doc.project.assets.append(a)
        let dest = root.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a.url, to: dest.appendingPathComponent(newName ?? name))
        return a
    }

    func testMissingFilesAreMarkedInListAssets() async throws {
        let a = try await missingAsset("interview.mp4", movedTo: "moved")
        let ok = try await media("broll.mp4", in: "original"); doc.project.assets.append(ok)
        let list = x.listAssets()
        XCTAssertEqual(list.first { $0.id == a.id.short }?.missing, true)
        XCTAssertNil(list.first { $0.id == ok.id.short }?.missing)
        XCTAssertEqual(Relink.missing(p).map(\.id), [a.id])
    }

    func testRelinkByFolderMatchesFileNameAndKeepsClips() async throws {
        let a = try await missingAsset("interview.mp4", movedTo: "moved/deeper")
        let clip = try x.insertClip(asset: a.id.short, sourceIn: 0, duration: min(1, a.duration))
        let dry = try await x.relinkMedia(asset: nil, path: nil, folder: root.appendingPathComponent("moved").path, recursive: true, dryRun: true)
        XCTAssertEqual(dry.relinked.count, 1); XCTAssertTrue(dry.dryRun)
        XCTAssertTrue(Relink.isMissing(p.asset(a.id)!), "dry run changes nothing")
        let r = try await x.relinkMedia(asset: nil, path: nil, folder: root.appendingPathComponent("moved").path, recursive: true, dryRun: false)
        XCTAssertEqual(r.relinked.first.map { URL(fileURLWithPath: $0.to).resolvingSymlinksInPath().path }, root.appendingPathComponent("moved/deeper/interview.mp4").resolvingSymlinksInPath().path)
        XCTAssertTrue(r.stillMissing.isEmpty)
        XCTAssertFalse(Relink.isMissing(p.asset(a.id)!))
        XCTAssertEqual(p.clip(clip.id)?.clip.assetID, a.id, "clips follow the asset id")
        doc.undo()
        XCTAssertTrue(Relink.isMissing(p.asset(a.id)!), "one undo step")
    }

    func testRelinkFindsARenamedFileByDurationAndSize() async throws {
        let a = try await missingAsset("interview.mp4", movedTo: "renamed", newName: "A001_C003.mp4")
        let r = try await x.relinkMedia(asset: nil, path: nil, folder: root.appendingPathComponent("renamed").path, recursive: true, dryRun: false)
        XCTAssertEqual(r.relinked.count, 1)
        XCTAssertTrue(r.relinked[0].reason.contains("renamed"), r.relinked[0].reason)
        XCTAssertEqual(p.asset(a.id)?.name, "A001_C003.mp4", "the name follows the file when it was the file name")
    }

    func testAMissFromARenameInPlaceNamesTheFolderToSearch() async throws {
        let a = try await missingAsset("C0001.MP4", movedTo: "original", newName: "C0001-renamed.MP4")
        let r = try await x.relinkMedia(asset: nil, path: nil, folder: nil, recursive: false, dryRun: true)
        let reason = try XCTUnwrap(r.stillMissing.first { $0.asset == a.id.short }?.reason)
        XCTAssertTrue(reason.contains("its folder is still there"), reason)
        XCTAssertTrue(reason.contains(root.appendingPathComponent("original").lastPathComponent), reason)
        let gone = try await missingAsset("B.mp4", movedTo: "elsewhere")
        try FileManager.default.removeItem(at: root.appendingPathComponent("original"))   // its folder is gone too
        let r2 = try await x.relinkMedia(asset: gone.id.short, path: nil, folder: nil, recursive: false, dryRun: true)
        XCTAssertTrue(r2.stillMissing.first?.reason.contains("choose a folder to search") == true, r2.stillMissing.first?.reason ?? "")
    }

    func testRelinkRefusesAShorterOrDifferentFile() async throws {
        let a = try await missingAsset("interview.mp4", movedTo: "moved")
        // The timeline plays further into the asset than a replacement has.
        doc.project.assets[doc.project.assets.firstIndex { $0.id == a.id }!].duration = a.duration + 5
        _ = try x.insertClip(asset: a.id.short, sourceIn: a.duration, duration: 4)
        do {
            _ = try await x.relinkMedia(asset: a.id.short, path: root.appendingPathComponent("moved/interview.mp4").path, folder: nil, recursive: false, dryRun: false)
            XCTFail("a file shorter than the timeline uses must be refused")
        } catch { XCTAssertTrue(message(error).contains("plays"), message(error)) }
        let png = root.appendingPathComponent("still.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        do {
            _ = try await x.relinkMedia(asset: a.id.short, path: png.path, folder: nil, recursive: false, dryRun: false)
            XCTFail("another kind of media must be refused")
        } catch { }
        XCTAssertTrue(Relink.isMissing(p.asset(a.id)!))
        // A folder with nothing that fits reports why instead of guessing.
        let none = try await x.relinkMedia(asset: nil, path: nil, folder: root.appendingPathComponent("original").path, recursive: true, dryRun: false)
        XCTAssertEqual(none.relinked.count, 0); XCTAssertEqual(none.stillMissing.count, 1)
    }

    func testConsolidateCopiesUsedFilesAndRepoints() async throws {
        let a = try await media("interview.mp4", in: "card1"), b = try await media("interview.mp4", in: "card2")   // same name, two files
        let unused = try await media("unused.mp4", in: "card1")
        doc.project.assets += [a, b, unused]
        _ = try x.insertClip(asset: a.id.short, sourceIn: 0, duration: 0.5)
        _ = try x.insertClip(asset: b.id.short, sourceIn: 0, duration: 0.5)
        let dest = root.appendingPathComponent("Project Media")
        let plan = try await x.consolidateMedia(folder: dest.path, dryRun: true)
        XCTAssertEqual(plan.copied, 2); XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "dry run copies nothing")
        let r = try await x.consolidateMedia(folder: dest.path, dryRun: false)
        let size = Int64(try Data(contentsOf: try fixture()).count)
        XCTAssertEqual(r.bytesCopied, 2 * size)
        XCTAssertEqual(Set(r.files.map { URL(fileURLWithPath: $0.to).lastPathComponent }), ["interview.mp4", "interview 2.mp4"])
        XCTAssertTrue(p.asset(a.id)!.path.hasPrefix(dest.path)); XCTAssertTrue(p.asset(b.id)!.path.hasPrefix(dest.path))
        XCTAssertNotEqual(p.asset(a.id)!.path, p.asset(b.id)!.path)
        XCTAssertEqual(p.asset(unused.id)!.path, unused.path, "unused media stays where it is")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path), "originals are only read")
        // Again: everything is already there, nothing is copied.
        let again = try await x.consolidateMedia(folder: dest.path, dryRun: false)
        XCTAssertEqual(again.copied, 0); XCTAssertEqual(again.bytesCopied, 0)
    }
}
