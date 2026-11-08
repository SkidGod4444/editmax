import XCTest
@testable import EditMax

/// The menus reach the editor: speed on the selection, the inspector tabs, the chat.
@MainActor
final class MenuCommandsTests: XCTestCase {
    func testMenuCommandsActOnTheSelectionAndThePanels() async throws {
        let doc = EditMaxDocument(), state = EditorState(), player = PlayerController()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4"))
        let a = try await MediaImporter.probe(url)
        doc.project.assets.append(a)
        let c = try ToolExecutor(document: doc, origin: .user).insertClip(asset: a.id.short, sourceIn: 0, duration: min(2, a.duration))
        let act = EditorActions(document: doc, state: state, player: player)

        act.run(.fast)
        XCTAssertEqual(doc.project.clip(c.id)?.clip.speed, 1, "nothing selected: nothing changes")
        state.selectedClipIDs = [c.id]
        act.run(.fast)
        XCTAssertEqual(doc.project.clip(c.id)?.clip.speed, 2)
        act.run(.slowMotion)
        XCTAssertEqual(doc.project.clip(c.id)?.clip.speed, 0.5)
        act.run(.normalSpeed)
        XCTAssertEqual(doc.project.clip(c.id)?.clip.speed, 1)

        act.run(.marker)
        XCTAssertEqual(doc.project.markers.count, 1)

        act.run(.showHistory)
        XCTAssertEqual(state.inspectorTab, .history)
        state.focusMode = true
        act.run(.showInspector)
        XCTAssertFalse(state.focusMode, "a tab shortcut brings back the full editor")
        XCTAssertEqual(state.inspectorTab, .inspector)

        XCTAssertNil(state.chat)
        act.run(.askAgent)
        XCTAssertNotNil(state.chat, "⌘L opens a chat when the window had none yet")
        XCTAssertEqual(state.inspectorTab, .chat)
    }

    func testEveryShortcutInTheHelpWindowIsListedOnce() {
        let keys = KeyboardShortcutsView.sections.flatMap(\.rows).map(\.keys)
        XCTAssertEqual(keys.count, Set(keys).count, "a key listed twice reads as two meanings")
    }
}
