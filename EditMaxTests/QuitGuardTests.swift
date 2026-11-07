import XCTest
import SwiftUI
import AppKit
@testable import EditMax

/// ⌘Q during an export asks first. The question is stubbed; the export pill's look is written to
/// $EDITMAX_PREVIEW_DIR/quit.
@MainActor
final class QuitGuardTests: XCTestCase {
    private func guardWith(exporting: @escaping () -> Bool, choice: QuitGuard.Choice) -> (QuitGuard, () -> Int, () -> Int) {
        let g = QuitGuard()
        var asked = 0, quits = 0
        g.exporting = exporting
        g.ask = { asked += 1; return choice }
        g.terminate = { quits += 1 }
        g.pollEvery = 0.05
        return (g, { asked }, { quits })
    }

    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func testNoExportQuitsAtOnceWithoutAsking() {
        let (g, asked, _) = guardWith(exporting: { false }, choice: .keepWorking)
        XCTAssertEqual(g.shouldTerminate(), .terminateNow)
        XCTAssertEqual(asked(), 0)
    }

    func testKeepWorkingCancelsTheQuit() {
        let (g, asked, quits) = guardWith(exporting: { true }, choice: .keepWorking)
        XCTAssertEqual(g.shouldTerminate(), .terminateCancel)
        XCTAssertEqual(asked(), 1)
        spin(0.2)
        XCTAssertEqual(quits(), 0)
        XCTAssertFalse(g.quitWhenDone)
    }

    func testQuitNowQuits() {
        let (g, _, _) = guardWith(exporting: { true }, choice: .quitNow)
        XCTAssertEqual(g.shouldTerminate(), .terminateNow)
    }

    func testQuitWhenDoneQuitsOnceTheExportEnds() {
        var exporting = true
        let (g, _, quits) = guardWith(exporting: { exporting }, choice: .quitWhenDone)
        XCTAssertEqual(g.shouldTerminate(), .terminateCancel, "the export keeps going")
        XCTAssertTrue(g.quitWhenDone)
        spin(0.2)
        XCTAssertEqual(quits(), 0, "not while it renders")
        exporting = false
        spin(0.2)
        XCTAssertEqual(quits(), 1, "quits by itself when it is done")
        XCTAssertFalse(g.quitWhenDone)
    }

    func testDontQuitTakesItBack() {
        var exporting = true
        let (g, _, quits) = guardWith(exporting: { exporting }, choice: .quitWhenDone)
        _ = g.shouldTerminate()
        g.dontQuit()
        exporting = false
        spin(0.2)
        XCTAssertEqual(quits(), 0)
        XCTAssertFalse(g.quitWhenDone)
    }

    /// The app delegate really asks the guard, and the guard really sees a running export.
    func testTheAppAsksDuringARealExport() async throws {
        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
        let fixture = Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4")!
        _ = try await x.importMedia(paths: [fixture.path])
        _ = try x.insertClip(asset: "base.mp4")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("quit-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let shared = QuitGuard.shared, keepAsk = shared.ask
        defer { shared.ask = keepAsk }
        var asked = 0
        shared.ask = { asked += 1; return .keepWorking }
        let project = doc.project
        let export = Task.detached { try await ExportService.export(project, to: out, preset: .low) }
        let deadline = Date().addingTimeInterval(10)
        while !BusyWork.isRunning(BusyWork.export), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let reply = AppDelegate().applicationShouldTerminate(NSApp)   // ⌘Q while it renders
        _ = try await export.value
        XCTAssertEqual(reply, .terminateCancel, "asked mid-export; Keep Working cancels the quit")
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(AppDelegate().applicationShouldTerminate(NSApp), .terminateNow, "after the export: quits as before")
    }

    func testTheQuestionsButtons() {
        let a = QuitGuard.makeAlert()
        XCTAssertEqual(a.buttons.map(\.title), ["Quit When Done", "Keep Working", "Quit Now"])
        XCTAssertEqual(a.buttons[0].keyEquivalent, "\r", "Return keeps the export and quits after it")
        XCTAssertEqual(a.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertEqual(a.buttons[2].keyEquivalent, "", "stopping an export takes a click")
    }

    // MARK: - Look

    func testQuitGuardLooks() throws {
        guard let d = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_DIR"], !d.isEmpty else { throw XCTSkip("set TEST_RUNNER_EDITMAX_PREVIEW_DIR to write previews") }
        let dir = URL(fileURLWithPath: d).appendingPathComponent("quit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for dark in [true, false] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            // The alert itself is a standard NSAlert: an off-screen render draws only its icon on this macOS, so its
            // buttons and words are checked in testTheQuestionsButtons instead.
            // The export pill after Quit When Done.
            GlassCompat.forceFallback = true
            defer { GlassCompat.forceFallback = false }
            let g = QuitGuard.shared, keepExporting = g.exporting, keepAsk = g.ask
            g.exporting = { true }; g.ask = { .quitWhenDone }
            _ = g.shouldTerminate()
            defer { g.dontQuit(); g.exporting = keepExporting; g.ask = keepAsk }
            let size = CGSize(width: 520, height: 64)
            let pill = ZStack { Color(white: dark ? 0.12 : 0.92); ExportStatusPill(status: "Exporting 42%") }
                .frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: pill)
            host.appearance = appearance
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance; window.isReleasedWhenClosed = false
            window.contentView = host; host.frame = CGRect(origin: .zero, size: size)
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); spin(0.05) }
            try write(host, to: dir.appendingPathComponent("quit-pill-\(dark ? "dark" : "light").png"))
            window.contentView = nil
        }
    }

    private func write(_ view: NSView, to url: URL) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
