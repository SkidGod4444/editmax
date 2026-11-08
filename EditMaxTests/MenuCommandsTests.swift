import XCTest
import SwiftUI
import AppKit
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

    func testNoTwoActionsShareADefaultKey() {
        var seen: [KeyCombo: ShortcutAction] = [:]
        for a in ShortcutAction.allCases {
            for c in a.defaults {
                XCTAssertNil(seen[c], "\(c.display) is both \(seen[c]?.rawValue ?? "") and \(a.rawValue)")
                XCTAssertNil(ShortcutConflicts.reserved[c], "\(c.display) is macOS's \(ShortcutConflicts.reserved[c] ?? "")")
                seen[c] = a
            }
            if a.menuOnly { XCTAssertTrue(a.defaults.allSatisfy(\.worksWhileTyping)) }
        }
    }
}

/// Settings ▸ Shortcuts: a changed key is saved, runs its action, shows in the menu; the old key stops.
@MainActor
final class ShortcutStoreTests: XCTestCase {
    private func store() -> ShortcutStore {
        let d = UserDefaults(suiteName: "ShortcutStoreTests-\(UUID().uuidString)")!
        return ShortcutStore(defaults: d)
    }

    func testAChangedKeyReplacesTheDefaultAndIsSaved() {
        let d = UserDefaults(suiteName: "ShortcutStoreTests-\(UUID().uuidString)")!
        let s = ShortcutStore(defaults: d)
        XCTAssertEqual(s.action(for: KeyCombo("s")), .split)
        s.set(.split, [KeyCombo("c"), KeyCombo("k", .command)])
        XCTAssertEqual(s.action(for: KeyCombo("c")), .split)
        XCTAssertNil(s.action(for: KeyCombo("s")), "the old key is free")
        XCTAssertEqual(s.menuShortcut(.split), KeyboardShortcut("k", modifiers: .command), "the menu shows the chord")
        XCTAssertEqual(ShortcutStore(defaults: d).combos(.split), [KeyCombo("c"), KeyCombo("k", .command)], "saved")
        s.reset(.split)
        XCTAssertEqual(s.combos(.split), ShortcutAction.split.defaults)
        XCTAssertNil(d.data(forKey: ShortcutStore.defaultsKey), "nothing saved when all are defaults")
    }

    func testABareKeyNeverBecomesAMenuShortcut() {
        let s = store()
        s.set(.exportVideo, [KeyCombo("e")])
        XCTAssertNil(s.menuShortcut(.exportVideo), "a menu item with a bare E would take it from the chat field")
        XCTAssertEqual(s.action(for: KeyCombo("e")), .exportVideo, "the editor still runs it")
    }

    func testKeysReadTheWayTheMenusShowThem() {
        XCTAssertEqual(KeyCombo("r", [.command, .option]).display, "⌥⌘R")
        XCTAssertEqual(KeyCombo("left", .shift).display, "⇧←")
        XCTAssertEqual(KeyCombo("space").display, "Space")
        XCTAssertEqual(KeyCombo(keyCode: 49, carbon: 256), KeyCombo("space", .command), "macOS's table: ⌘Space")
    }

    func testMacOSKeysAreRefusedAndAppDefaultsWarn() {
        let spotlight = [KeyCombo("space", .command): "Spotlight"]
        let c1 = ShortcutConflicts.clashes(KeyCombo("space", .command), system: spotlight, installed: { _ in false })
        XCTAssertEqual(c1.first, .system("Spotlight")); XCTAssertTrue(c1.first!.blocks)
        let c2 = ShortcutConflicts.clashes(KeyCombo("q", .command), system: [:], installed: { _ in false })
        XCTAssertEqual(c2.first, .reserved("Quit"))
        let c3 = ShortcutConflicts.clashes(KeyCombo("space", .option), system: [:], installed: { $0 == "com.raycast.macos" })
        XCTAssertTrue(c3.contains(.appDefault("Raycast")))
        XCTAssertFalse(c3.contains(where: \.blocks) && !c3.contains(.otherApp), "an app default only warns")
    }

    func testGlobeChordsInMacOSsTableAreNotPlainKeys() {
        XCTAssertNil(ShortcutConflicts.systemCombo(code: 3, carbon: 0x20000), "🌐F is not F")
        XCTAssertNil(ShortcutConflicts.systemCombo(code: 123, carbon: 0x20000), "an arrow's own fn bit alone is not a shortcut")
        XCTAssertEqual(ShortcutConflicts.systemCombo(code: 123, carbon: 0x21000), KeyCombo("left", .control), "⌃←: moving between Spaces")
        XCTAssertEqual(ShortcutConflicts.systemCombo(code: 3, carbon: 0x300), KeyCombo("f", [.command, .shift]))
        let listed = ShortcutConflicts.clashes(KeyCombo("f", [.command, .shift]), system: [KeyCombo("f", [.command, .shift]): ""], installed: { _ in false })
        XCTAssertEqual(listed.first, .systemListed); XCTAssertFalse(listed.first!.blocks, "unnamed: a warning, not a refusal")
    }

    func testTheDefaultsMeetNothingMacOSTakesHere() {
        let system = ShortcutConflicts.systemShortcuts()
        XCTAssertNil(system[KeyCombo("f", [.command, .shift])], "⇧⌘F is Recents in Open and Save panels, not system-wide")
        for a in ShortcutAction.allCases {
            for c in a.defaults {
                let named = ShortcutConflicts.clashes(c, system: system, installed: { _ in false }).filter { if case .otherApp = $0 { return false }; return true }
                XCTAssertTrue(named.isEmpty, "\(c.display) (\(a.rawValue)): \(named.map(\.message))")
            }
        }
    }

    func testTheToolTipsNameTheKeyInUse() {
        XCTAssertTrue(EditTool.roll.help.hasPrefix("Roll (R): "))
        ShortcutStore.shared.set(.toolRoll, [KeyCombo("e")])
        defer { ShortcutStore.shared.reset(.toolRoll) }
        XCTAssertTrue(EditTool.roll.help.hasPrefix("Roll (E): "))
    }

    func testRecordedKeysComeFromRealKeyPresses() throws {
        let e = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                               context: nil, characters: "+", charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 24))
        XCTAssertEqual(KeyCombo(event: e), KeyCombo("=", [.command, .shift]), "⇧⌘= is the = key with shift, as the menu shows it")
        XCTAssertEqual(store().action(matching: e), .zoomIn)
    }
}
