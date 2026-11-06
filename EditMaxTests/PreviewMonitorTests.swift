import XCTest
import SwiftUI
import AppKit
import AVFoundation
@testable import EditMax

/// The program monitor: scopes, before/after and the chrome over the picture.
@MainActor
final class PreviewMonitorTests: XCTestCase {
    private var url: URL!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-monitor-\(UUID().uuidString.prefix(8)).mp4")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: url) }

    /// A document with one generated clip, bound to a player that has built its composition and is paused at 0.5 s.
    private func pausedPlayer() async throws -> (EditMaxDocument, PlayerController) {
        try await EditingTestVideo.write(to: url, seconds: 2, cuts: [])
        let doc = EditMaxDocument()
        doc.project.assets.append(try await MediaImporter.probe(url))
        _ = try ToolExecutor(document: doc, origin: .agent).insertClip(asset: doc.project.assets[0].id.uuidString)
        let player = PlayerController()
        player.bind(to: doc)
        try await waitFor("the player to build the composition") { player.lastOutput != nil && player.player.currentItem?.status == .readyToPlay }
        player.seek(to: 0.5)
        try await Task.sleep(for: .milliseconds(600))   // settled: nothing moves from here on
        return (doc, player)
    }

    private func waitFor(_ what: String, seconds: Double = 5, _ done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > end { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// M10: turning the scopes on while paused draws them for the frame on screen, without moving the playhead.
    func testScopesShowTheFrameOnScreenAsSoonAsTheyOpen() async throws {
        let (_, player) = try await pausedPlayer()
        XCTAssertFalse(player.isPlaying)
        let at = player.currentTime
        player.scopesEnabled = true
        try await waitFor("the scopes of the paused frame", seconds: 3) { player.scopes != nil }
        XCTAssertNotNil(player.scopes?.parade)
        XCTAssertEqual(player.currentTime, at, "opening the scopes must not move the playhead")
        player.scopesEnabled = false
        XCTAssertNil(player.scopes)
    }

    /// L3: before/after is two states. A click turns it on the way it was last shown, or off; the menu picks the way.
    func testCompareIsOnOrOffInTheLastStyleShown() {
        let p = PlayerController()
        XCTAssertEqual(p.compareMode, .off)
        XCTAssertEqual(p.compareStyle, .split)
        p.toggleCompare(); XCTAssertEqual(p.compareMode, .split)
        p.toggleCompare(); XCTAssertEqual(p.compareMode, .off, "the second click turns it off; it no longer goes to a hidden third state")
        p.showCompare(.before); XCTAssertEqual(p.compareMode, .before, "choosing a way in the menu shows it")
        p.toggleCompare(); XCTAssertEqual(p.compareMode, .off)
        p.toggleCompare(); XCTAssertEqual(p.compareMode, .before, "on again the way it was last shown")
        p.showCompare(.split); XCTAssertEqual(p.compareMode, .split, "switching while on stays on")
        p.compareMode = .before   // set from elsewhere (an agent tool): the button follows
        XCTAssertEqual(p.compareStyle, .before)
        p.compareMode = .off
        XCTAssertEqual(p.compareStyle, .before)
    }

    /// H4 / L7: the chrome stays in the letterbox when it fits there, and the picture steps down when it would not.
    func testMonitorKeepsTheChromeOffThePicture() {
        let buttons = CGRect(x: 760 - 10 - 160, y: 10, width: 160, height: 26)   // the button group, top right
        // 16:9 in a tall monitor: 427 pt picture, 21 pt letterbox above... too thin for the buttons, so a strip.
        XCTAssertEqual(MonitorLayout.topInset(size: CGSize(width: 760, height: 470), aspect: 16 / 9, chrome: [buttons]), 46)
        // Taller monitor (no scopes): the letterbox holds the buttons, the picture keeps the whole monitor.
        XCTAssertEqual(MonitorLayout.topInset(size: CGSize(width: 760, height: 560), aspect: 16 / 9, chrome: [buttons]), 0)
        // 9:16 in a wide monitor: the buttons sit beside the picture, in the side bars.
        XCTAssertEqual(MonitorLayout.topInset(size: CGSize(width: 760, height: 470), aspect: 9 / 16, chrome: [buttons]), 0)
        // The version banner under the buttons reaches the picture: the strip goes down to under the banner.
        let banner = CGRect(x: 180, y: 44, width: 400, height: 30)
        XCTAssertEqual(MonitorLayout.topInset(size: CGSize(width: 760, height: 560), aspect: 16 / 9, chrome: [buttons, banner]), 84)
        // With the strip, the picture starts below the chrome and is still centred sideways.
        let pic = MonitorLayout.picture(in: CGSize(width: 760, height: 470), aspect: 16 / 9, top: 46)
        XCTAssertGreaterThanOrEqual(pic.minY, buttons.maxY + MonitorLayout.gap)
        XCTAssertEqual(pic.midX, 380, accuracy: 0.5)
        XCTAssertEqual(pic.width / pic.height, 16 / 9, accuracy: 0.001)
        // Nothing to place (no chrome measured yet): no strip.
        XCTAssertEqual(MonitorLayout.topInset(size: CGSize(width: 760, height: 470), aspect: 16 / 9, chrome: [.zero]), 0)
    }

    // MARK: previews

    /// A landscape still for the picture: the colour chart, so a covered corner shows.
    private func still() -> CGImage {
        let ci = ColorFixtures.chart(CGSize(width: 960, height: 540))
        return ColorFixtures.ctx.createCGImage(ci, from: ci.extent)!
    }

    /// A graded document with two clips (fake media) and its player and editor state.
    private func monitorDocument() throws -> (EditMaxDocument, PlayerController, EditorState) {
        let doc = EditMaxDocument()
        doc.project.assets.append(Asset(name: "surf.mp4", path: "/tmp/preview-monitor-a.mp4", kind: .video, duration: 10, width: 1920, height: 1080))
        let x = ToolExecutor(document: doc, origin: .agent)
        let c = try x.insertClip(asset: "surf.mp4")
        _ = try x.setColorWheels(c.id.short, layer: nil, wheel: "gain", r: nil, g: nil, b: nil, master: 0.1, toward: "orange", amount: 0.05, reset: false)
        return (doc, PlayerController(), EditorState())
    }

    /// Renders the monitor at `size` in an offscreen window (AppKit buttons and menus draw too) as <name>-light/-dark.png.
    /// Glass is drawn with its material fallback: real glass is composited by the window server and comes out blank.
    private func save<V: View>(_ name: String, size: CGSize, _ make: () -> V) throws {
        guard let dir = ColorFixtures.previewDir else { throw XCTSkip("set TEST_RUNNER_EDITMAX_PREVIEW_DIR to write previews") }
        let glass = GlassCompat.forceFallback
        GlassCompat.forceFallback = true
        defer { GlassCompat.forceFallback = glass }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: make().frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = appearance
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            // Two passes: the chrome's measured frames feed the picture's strip on the next layout.
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            window.contentView = nil
            ColorFixtures.savePNG(try XCTUnwrap(rep.cgImage), dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    func testPreviewMonitorChrome() throws {
        let (doc, player, state) = try monitorDocument()
        let still = still()
        // No scopes, room above the picture: the buttons sit in the letterbox.
        try save("monitor-plain", size: CGSize(width: 760, height: 520)) { ProgramMonitor(document: doc, player: player, state: state, toggleFullScreen: {}, still: still) }
        // Scopes on (L7): the picture fills the width, so it steps down below the buttons instead of under them.
        player.scopesEnabled = true
        try save("monitor-scopes", size: CGSize(width: 760, height: 520)) { ProgramMonitor(document: doc, player: player, state: state, toggleFullScreen: {}, still: still) }
        // Before/after on, split (L3): the button is tinted and shows the split.
        player.showCompare(.split)
        try save("monitor-compare-split", size: CGSize(width: 760, height: 520)) { ProgramMonitor(document: doc, player: player, state: state, toggleFullScreen: {}, still: still) }
        player.showCompare(.before)
        try save("monitor-compare-before", size: CGSize(width: 760, height: 520)) { ProgramMonitor(document: doc, player: player, state: state, toggleFullScreen: {}, still: still) }
        player.compareMode = .off
        try save("monitor-compare-off", size: CGSize(width: 760, height: 520)) { ProgramMonitor(document: doc, player: player, state: state, toggleFullScreen: {}, still: still) }
        // An older version shown (H4), narrow monitor with scopes: the banner sits under the buttons, Restore clear.
        state.viewingVersion = ProjectVersion(id: "v1", label: "Edit text", date: Date(timeIntervalSince1970: 1_762_400_000), project: doc.project, isCurrent: false)
        try save("monitor-version-narrow", size: CGSize(width: 480, height: 470)) { ProgramMonitor(document: doc, player: player, state: state, toggleFullScreen: {}, still: still) }
        player.scopesEnabled = false
        try save("monitor-version", size: CGSize(width: 760, height: 520)) { ProgramMonitor(document: doc, player: player, state: state, toggleFullScreen: {}, still: still) }
    }

    /// M8: the focus layout's transport and the full-screen controls read the editor's frame timecode (minutes:seconds.
    /// frames, as under the timeline), not decimal seconds.
    func testPreviewTransportTimecode() async throws {
        guard ColorFixtures.previewDir != nil else { throw XCTSkip("set TEST_RUNNER_EDITMAX_PREVIEW_DIR to write previews") }
        let (doc, player) = try await pausedPlayer()
        let fps = doc.project.settings.fps
        try save("transport-focus", size: CGSize(width: 560, height: 64)) {
            TransportBar(player: player, fps: fps).padding(.horizontal, 12).frame(maxHeight: .infinity).background(Color.black.opacity(0.85))
        }
        try save("transport-fullscreen", size: CGSize(width: 760, height: 160)) {
            FullScreenControls(controller: player, state: FullScreenControlsState(), fps: fps, leave: {}).background(Color.black)
        }
    }
}
