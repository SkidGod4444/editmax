import XCTest
import SwiftUI
import AppKit
@testable import EditMax

/// After typing to the agent, a click on the timeline or the player gives the keyboard back to the editor, so Space plays
/// again; and Play Selection (/) plays the selected clips once and stops.
@MainActor
final class TimelineKeyboardTests: XCTestCase {

    /// A chat-like text field above a timeline-like area, in a window with the editor's key monitor.
    private struct Editor: View {
        @Binding var text: String
        var body: some View {
            VStack(spacing: 0) {
                TextField("Ask the agent", text: $text).frame(height: 30)
                Color.gray.frame(height: 200).takesKeyboardOnClick()
                Color.blue.frame(height: 100)   // not a keyboard area (the inspector, say)
            }
            .background(KeyMonitor { _ in false })
        }
    }

    private func field(in view: NSView) -> NSTextField? {
        if let f = view as? NSTextField, f.isEditable { return f }
        for s in view.subviews { if let f = field(in: s) { return f } }
        return nil
    }

    /// Window points (bottom-left origin) of a point `fromTop` points below the top of the 400 pt tall window.
    private func point(_ x: CGFloat, fromTop: CGFloat) -> NSPoint { NSPoint(x: x, y: 400 - fromTop) }

    private func click(_ p: NSPoint, in w: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.sendEvent(e)
        }
    }

    func testAClickOnTheTimelineEndsTypingInTheChatBox() throws {
        var text = "make it punchier"
        let host = OffscreenHost(Editor(text: Binding(get: { text }, set: { text = $0 })), size: CGSize(width: 400, height: 400), dark: true)
        let w = host.window
        let f = try XCTUnwrap(field(in: host.host))
        XCTAssertTrue(w.makeFirstResponder(f))
        XCTAssertTrue(w.firstResponder is NSTextView, "the chat box has the keyboard")

        XCTAssertFalse(EditorKeyboard.shouldTakeBack(at: point(200, fromTop: 15), in: w), "a click in the text field itself keeps typing")
        XCTAssertFalse(EditorKeyboard.shouldTakeBack(at: point(200, fromTop: 350), in: w), "outside the timeline nothing changes")
        XCTAssertTrue(EditorKeyboard.shouldTakeBack(at: point(200, fromTop: 130), in: w))

        click(point(200, fromTop: 130), in: w)
        host.settle(2)
        XCTAssertFalse(w.firstResponder is NSTextView, "the timeline has the keyboard again, so Space plays")
        XCTAssertEqual(text, "make it punchier", "what was typed stays in the box")
        XCTAssertFalse(EditorKeyboard.shouldTakeBack(at: point(200, fromTop: 130), in: w), "nothing to take back when no field types")
    }

    func testPlaySelectionPlaysTheSelectedClipsOrInToOut() {
        let doc = EditMaxDocument()
        let a = Clip(assetID: UUID(), name: "a", start: 2, duration: 3), b = Clip(assetID: UUID(), name: "b", start: 5, duration: 4)
        doc.project.tracks[0].clips = [a, b]
        let state = EditorState()
        let actions = EditorActions(document: doc, state: state, player: PlayerController())
        XCTAssertNil(actions.selectionRange, "nothing selected, no In and Out: Play Selection plays from the playhead")
        state.selectedClipIDs = [b.id]
        XCTAssertEqual(actions.selectionRange, 5...9)
        state.selectedClipIDs = [a.id, b.id]
        XCTAssertEqual(actions.selectionRange, 2...9, "several clips: the first start to the last end")
        state.selectedClipIDs = []
        state.inPoint = 1; state.outPoint = 4
        XCTAssertEqual(actions.selectionRange, 1...4)
        XCTAssertEqual(ShortcutAction.playSelection.defaults, [KeyCombo("/")])
        XCTAssertEqual(ShortcutStore(defaults: UserDefaults(suiteName: "play-selection-\(UUID().uuidString)")!).action(for: KeyCombo("/")), .playSelection)
    }

    func testPlayFromToStopsAtTheEnd() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("play-selection-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mp4")
        try await EditingTestVideo.write(to: url, seconds: 4, cuts: [])
        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .user)
        _ = try await x.importMedia(paths: [url.path])
        _ = try x.insertClip(asset: "clip.mp4", at: 0)
        let player = PlayerController()
        player.bind(to: doc)
        player.rebuild(doc.project, reason: "play-selection-test")
        for _ in 0..<100 where !(player.lastOutput != nil && player.player.currentItem?.status == .readyToPlay) { try await Task.sleep(for: .milliseconds(50)) }
        player.player.isMuted = true

        player.play(from: 1, to: 2)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.stopTime, 2)
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(player.isPlaying, "it stops at the end of the selection")
        XCTAssertEqual(player.currentTime, 2, accuracy: 0.2)
        XCTAssertNil(player.stopTime)

        // Space after it plays on from there, to the end of the timeline: the stop is gone.
        player.play()
        XCTAssertNil(player.stopTime)
        try await Task.sleep(for: .seconds(0.6))
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(player.currentTime, 2.2)
        player.pause()
    }
}
