import XCTest
import SwiftUI
@testable import EditMax

/// The media panel's Library: every row can be removed from this project or deleted from Assets, and a drop on the
/// notch drawer switches the panel to Library and points at what went in. Files are referenced in place (copy: false),
/// so nothing a test makes ends up in the user's Trash.
@MainActor
final class LibraryPanelActionsTests: LibraryTestCase {
    private func setUpItem(clips: Int) async throws -> (EditMaxDocument, EditMax.LibraryItem) {
        let video = try LibraryFixtures.video(dir, "Beach day.mp4")
        _ = await AssetLibrary.shared.add(urls: [video], source: .drawer, copy: false)
        let item = try XCTUnwrap(AssetLibrary.shared.all.first { $0.name == "Beach day.mp4" })
        let doc = EditMaxDocument()
        doc.project.assets = [Asset(name: item.name, path: item.path, kind: .video, duration: 2, width: 1920, height: 1080)]
        for _ in 0..<clips { _ = try ToolExecutor(document: doc, origin: .user).insertClip(asset: item.name) }
        return (doc, item)
    }

    func testRemoveFromProjectKeepsItInAssets() async throws {
        let (doc, item) = try await setUpItem(clips: 2)
        XCTAssertEqual(LibraryActions.clipCount(item, in: doc), 2)
        XCTAssertTrue(LibraryActions.removeNote(item, from: doc).contains("2 clips"))
        LibraryActions.removeFromProject(item, document: doc)
        XCTAssertTrue(doc.project.assets.isEmpty); XCTAssertTrue(doc.project.allClips.isEmpty)
        XCTAssertNotNil(AssetLibrary.shared.all.first { $0.id == item.id }, "still in Assets")
        doc.undo()
        XCTAssertEqual(doc.project.allClips.count, 2, "one undo step brings the media and its clips back")
    }

    func testDeleteFromAssetsTakesItOutOfThisProjectToo() async throws {
        let (doc, item) = try await setUpItem(clips: 1)
        XCTAssertTrue(LibraryActions.deleteNote(item, from: doc).contains("removed from this project too, with the 1 clip"))
        LibraryActions.deleteFromAssets(item, document: doc)
        XCTAssertTrue(doc.project.assets.isEmpty, "or saving the project would put it straight back")
        XCTAssertNil(AssetLibrary.shared.all.first { $0.id == item.id }, "gone from Assets")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path), "a file referenced in place stays where it is")
    }

    func testDeleteNoteNamesTheProjectsThatKeepTheFile() async throws {
        let (doc, item) = try await setUpItem(clips: 0)
        AssetLibrary.shared.noteUsed(doc.project.assets, projectID: UUID(), projectName: "Launch video")
        let fresh = try XCTUnwrap(AssetLibrary.shared.all.first { $0.id == item.id })
        let note = LibraryActions.deleteNote(fresh, from: doc)
        XCTAssertTrue(note.contains("stays where it is on your Mac; Launch video keeps using it"), note)
    }

    /// The user's choice: deleted means deleted. Another project opening (or saving) with the file does not bring it
    /// back; importing it again on purpose does.
    func testADeletedItemStaysDeletedUntilImportedAgain() async throws {
        let (doc, item) = try await setUpItem(clips: 0)
        let other = UUID()
        AssetLibrary.shared.noteUsed(doc.project.assets, projectID: other, projectName: "Launch video")
        LibraryActions.deleteFromAssets(item, document: doc)
        let asset = Asset(name: item.name, path: item.path, kind: .video, duration: 2, width: 1920, height: 1080)
        AssetLibrary.shared.syncUse([asset], projectID: other, projectName: "Launch video")   // that project opens
        XCTAssertNil(AssetLibrary.shared.all.first { $0.path == item.path }, "an open does not bring it back")
        AssetLibrary.shared.load()
        AssetLibrary.shared.syncUse([asset], projectID: other, projectName: "Launch video")
        XCTAssertNil(AssetLibrary.shared.all.first { $0.path == item.path }, "nor after a relaunch (the list is saved)")
        AssetLibrary.shared.noteUsed([asset], projectID: other, projectName: "Launch video", explicit: true)   // imported again
        XCTAssertNotNil(AssetLibrary.shared.all.first { $0.path == item.path })
    }

    /// EditMax's own copy goes to the Archive even though a project still uses it (the user's choice), never to the
    /// Mac's Trash.
    func testDeletingACopyMovesItToTheArchive() async throws {
        let archiveDir = dir.appendingPathComponent("Archive", isDirectory: true)
        AppArchive.directoryOverride = archiveDir; AppArchive.shared.load()
        defer { AppArchive.directoryOverride = nil; AppArchive.shared.load() }
        let video = try LibraryFixtures.video(dir, "Copied.mp4")
        _ = await AssetLibrary.shared.add(urls: [video], source: .drawer, copy: true)
        let item = try XCTUnwrap(AssetLibrary.shared.all.first { $0.name == "Copied.mp4" })
        XCTAssertTrue(AssetLibrary.shared.isCopy(item))
        AssetLibrary.shared.noteUsed([Asset(name: item.name, path: item.path, kind: .video, duration: 2)], projectID: UUID(), projectName: "Launch video")
        AssetLibrary.shared.remove([item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path), "deleted even though a project uses it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent("Copied.mp4").path), "in the Archive")
        XCTAssertEqual(AppArchive.shared.entries.last?.original, item.path)
        // Restore: the file goes back where it was and the item is in Assets again, as it was.
        let entry = try XCTUnwrap(AppArchive.shared.entries.last)
        XCTAssertEqual(entry.kind, .asset)
        try AppArchive.shared.restore(entry.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
        let back = try XCTUnwrap(AssetLibrary.shared.all.first { $0.path == item.path })
        XCTAssertEqual(back.id, item.id); XCTAssertEqual(back.usedIn.values.first, "Launch video")
    }

    func testArchiveToolsOverMCP() async throws {
        let archiveDir = dir.appendingPathComponent("Archive", isDirectory: true)
        AppArchive.directoryOverride = archiveDir; AppArchive.shared.load()
        defer { AppArchive.directoryOverride = nil; AppArchive.shared.load() }
        let video = try LibraryFixtures.video(dir, "Agent.mp4")
        _ = await AssetLibrary.shared.add(urls: [video], source: .drawer, copy: true)
        let item = try XCTUnwrap(AssetLibrary.shared.all.first { $0.name == "Agent.mp4" })
        AssetLibrary.shared.remove([item.id])
        let listed = try await EditMaxTools.call("list_archive", [:])
        XCTAssertTrue("\(listed)".contains("Agent.mp4"), "\(listed)")
        _ = try await EditMaxTools.call("restore_from_archive", ["item": .string("Agent.mp4")])
        XCTAssertNotNil(AssetLibrary.shared.all.first { $0.path == item.path }, "back in Assets with no project open")
    }

    func testRowsAlwaysOfferRemoveAndDelete() async throws {
        let (doc, item) = try await setUpItem(clips: 0)
        for dark in [true, false] {
            let h = OffscreenHost(LibraryPanelList(document: doc, onError: { _ in }), size: CGSize(width: 280, height: 160), dark: dark)
            for id in ["media.library.\(item.name).remove", "media.library.\(item.name).delete"] {
                let f = try XCTUnwrap(h.frame(id), id)
                XCTAssertGreaterThanOrEqual(f.width, 20); XCTAssertGreaterThanOrEqual(f.height, 20)
            }
            h.save("library-row-buttons-\(dark ? "dark" : "light")")
            h.close()
        }
    }

    func testANotchDropShowsTheLibrary() async throws {
        let (doc, item) = try await setUpItem(clips: 0)
        let h = OffscreenHost(AssetsSidebar(document: doc).environmentObject(EditorState()), size: CGSize(width: 280, height: 220), dark: true)
        defer { h.close() }
        XCTAssertNil(h.frame("media.library.search"), "starts on Project")
        NotchDrawer.showInLibrary(LibraryAddResult(added: [item], existing: [], failures: []))
        h.settle(8)
        XCTAssertNotNil(h.frame("media.library.search"), "switched to Library")
        h.save("library-after-notch-drop")
    }
}

/// A file deleted outside EditMax leaves the Assets list, and a project that still names it does not put it back.
@MainActor
final class LibraryMissingFileTests: LibraryTestCase {
    func testGoneFilesLeaveTheListAndProjectsDoNotBringThemBack() async throws {
        let video = try LibraryFixtures.video(dir, "Gone.mp4")
        _ = await AssetLibrary.shared.add(urls: [video], source: .drawer, copy: false)
        XCTAssertNotNil(AssetLibrary.shared.all.first { $0.name == "Gone.mp4" })
        try FileManager.default.removeItem(at: video)
        XCTAssertEqual(AssetLibrary.shared.pruneMissing(), 1)
        XCTAssertNil(AssetLibrary.shared.all.first { $0.name == "Gone.mp4" })
        AssetLibrary.shared.syncUse([Asset(name: "Gone.mp4", path: video.path, kind: .video, duration: 2)], projectID: UUID(), projectName: "Old")
        XCTAssertNil(AssetLibrary.shared.all.first { $0.name == "Gone.mp4" }, "a project opening with it does not list it again")
    }

    func testAFileOnADisconnectedDriveStays() {
        XCTAssertTrue(AssetLibrary.onDisconnectedDrive("/Volumes/No Such Drive 7f3a/clip.mov"))
        XCTAssertFalse(AssetLibrary.onDisconnectedDrive("/Users/someone/Movies/clip.mov"))
        XCTAssertFalse(AssetLibrary.onDisconnectedDrive("/Volumes"))
    }

    func testTheMediaPanelTabSaysAssets() {
        XCTAssertEqual(AssetsSidebar.Mode.library.rawValue, "Assets")
    }
}
