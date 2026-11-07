import XCTest
import SwiftUI
import AppKit
import Sparkle
@testable import EditMax

/// The "new version is ready" popup: Sparkle's hand-off, when it shows, Install Now and Remind Me Later. Every popup
/// here is placed off screen. Its look is written to $EDITMAX_PREVIEW_DIR/update when that is set.
@MainActor
final class UpdatePromptTests: XCTestCase {
    private func prompt(active: Bool = true) -> UpdatePrompt {
        let p = UpdatePrompt()
        p.offscreen = true
        p.appIsActive = { active }
        return p
    }

    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func testSparkleHandsTheDownloadedUpdateToThePopupInsteadOfInstallingSilently() throws {
        let p = prompt()
        let delegate = AppUpdaterDelegate(prompt: { p })
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("updater:willInstallUpdateOnQuit:immediateInstallationBlock:")),
                      "the Swift method must be the one Sparkle calls (an optional requirement fails silently)")
        let item = try XCTUnwrap(SUAppcastItem(dictionary: [
            "title": "EditMax 0.1.2", "sparkle:version": "12", "sparkle:shortVersionString": "0.1.2",
            "sparkle:fullReleaseNotesLink": "https://github.com/SkidGod4444/editmax/releases/tag/v0.1.2",
            "enclosure": ["url": "https://github.com/SkidGod4444/editmax/releases/download/v0.1.2/EditMax-0.1.2.zip", "length": "100", "sparkle:edSignature": "x"],
        ]))
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil)
        var installs = 0
        XCTAssertTrue(delegate.updater(updater, willInstallUpdateOnQuit: item) { installs += 1 }, "EditMax shows it; Sparkle still installs on quit")
        XCTAssertEqual(p.offer, UpdatePrompt.Offer(version: "0.1.2", notes: URL(string: "https://github.com/SkidGod4444/editmax/releases/tag/v0.1.2")))
        XCTAssertTrue(p.isShowing)
        p.installNow()
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(p.isShowing)
    }

    func testThePopupWaitsUntilEditMaxIsInFront() {
        var active = false
        let p = prompt(); p.appIsActive = { active }
        p.offer(version: "0.1.2", notes: nil) {}
        XCTAssertFalse(p.isShowing, "never pops over another app")
        active = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(p.isShowing)
        p.later()
    }

    func testInstallNowSavesEveryOpenProjectFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = EditMaxDocument(), url = dir.appendingPathComponent("Trip.emx")
        doc.fileURL = url
        DocumentRegistry.shared.register(doc)
        defer { DocumentRegistry.shared.unregister(doc) }
        let p = prompt()
        var savedBeforeInstall = false
        p.offer(version: "0.1.2", notes: nil) { savedBeforeInstall = FileManager.default.fileExists(atPath: url.path) }
        p.installNow()
        XCTAssertTrue(savedBeforeInstall, "the project is on disk before EditMax quits to install")
    }

    func testRemindMeLaterClosesItAndAsksAgainLater() {
        let p = prompt()
        p.remindAfter = 0.2
        var installs = 0
        p.offer(version: "0.1.2", notes: nil) { installs += 1 }
        p.later()
        XCTAssertFalse(p.isShowing)
        spin(0.6)
        XCTAssertTrue(p.isShowing, "asks again after the wait")
        XCTAssertEqual(installs, 0, "Later never installs")
        p.remindAfter = 3600; p.later()
    }

    func testCheckForUpdatesShowsTheWaitingUpdateAgain() {
        let p = UpdatePrompt.shared
        p.offscreen = true; p.appIsActive = { true }; p.remindAfter = 3600
        p.offer(version: "0.1.2", notes: nil) {}
        p.later()
        XCTAssertFalse(p.isShowing)
        AppUpdater.shared.checkForUpdates()
        XCTAssertTrue(p.isShowing)
        p.later()
    }

    // MARK: - Look

    /// The popup over the editor (a capture of the real window when $EDITMAX_PREVIEW_BACKDROP points at one).
    func testUpdatePromptLook() throws {
        guard let d = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_DIR"], !d.isEmpty else { throw XCTSkip("set TEST_RUNNER_EDITMAX_PREVIEW_DIR to write previews") }
        let out = URL(fileURLWithPath: d).appendingPathComponent("update", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        GlassCompat.forceFallback = true   // real glass does not draw offscreen; its stand-in does
        defer { GlassCompat.forceFallback = false }
        let backdrop = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_BACKDROP"].flatMap { NSImage(contentsOfFile: $0) }
        let offer = UpdatePrompt.Offer(version: "0.1.2", notes: URL(string: "https://github.com/SkidGod4444/editmax/releases/latest"))
        for dark in [true, false] {
            let size = CGSize(width: 1400, height: 878)
            let card = UpdatePromptView(offer: offer, install: {}, later: {})
            let scene = ZStack(alignment: .top) {
                if let backdrop { Image(nsImage: backdrop).resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height).clipped() }
                else { LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom) }
                card.shadow(color: .black.opacity(0.35), radius: 24, y: 10).padding(.top, size.height / 3 - 110)
            }
            try render(scene, size: size, dark: dark, to: out.appendingPathComponent("update-prompt-\(dark ? "dark" : "light").png"))
            try render(card, size: CGSize(width: 528, height: 190), dark: dark, to: out.appendingPathComponent("update-prompt-card-\(dark ? "dark" : "light").png"))
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // As in the app's key window, so Install Now draws as the blue default button, not the grey of a window behind.
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light).environment(\.controlActiveState, .key))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); spin(0.05) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
