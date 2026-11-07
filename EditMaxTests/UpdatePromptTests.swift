import XCTest
import SwiftUI
import AppKit
import Sparkle
@testable import EditMax

/// The "new version is ready" popup: Sparkle's hand-off, when it shows, Install Now, Remind Me Later's reminders and
/// the "installed" card after the relaunch. Every popup here is placed off screen; nothing is posted to Notification
/// Center (the poster is stubbed). Its look is written to $EDITMAX_PREVIEW_DIR/update when that is set.
@MainActor
final class UpdatePromptTests: XCTestCase {
    private static let suite = "editmax.tests.updateprompt"
    private var defaults: UserDefaults { UserDefaults(suiteName: Self.suite)! }
    private var notified: [String] = []

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    private func prompt(active: Bool = true) -> UpdatePrompt {
        let p = UpdatePrompt()
        p.offscreen = true
        p.appIsActive = { active }
        p.busy = { nil }
        p.idleCheck = 0.05
        p.tickEvery = 0.05
        p.defaults = defaults
        p.askNotificationPermission = {}
        p.notify = { [weak self] in self?.notified.append($0.version) }
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

    /// Remind Me Later while EditMax stays in front: the popup again every 2 hours, never sooner, never a notification.
    func testLaterRemindsEveryTwoHoursWhileEditMaxIsInFront() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let p = prompt(); p.clock = { now }
        var installs = 0, asked = 0
        p.askNotificationPermission = { asked += 1 }
        p.offer(version: "0.1.2", notes: nil) { installs += 1 }
        p.later()
        XCTAssertFalse(p.isShowing)
        now += 2 * 3600 - 60; spin(0.2)
        XCTAssertFalse(p.isShowing, "not before 2 hours")
        now += 60; spin(0.2)
        XCTAssertTrue(p.isShowing, "2 hours on: the popup again")
        p.later()
        now += 3600; spin(0.2)
        XCTAssertFalse(p.isShowing)
        now += 3600; spin(0.2)
        XCTAssertTrue(p.isShowing, "and every 2 hours after")
        XCTAssertEqual(notified, [], "no notification while EditMax is in front")
        XCTAssertEqual(installs, 0, "Later never installs")
        XCTAssertEqual(asked, 1, "notification permission is asked once, at the first Later")
        p.later()
    }

    /// In the background: a notification every 6 hours, no popup; back in front after that, the popup.
    func testInTheBackgroundANotificationEverySixHours() {
        var now = Date(timeIntervalSince1970: 1_000_000), active = true
        let p = prompt(); p.clock = { now }; p.appIsActive = { active }
        p.offer(version: "0.1.2", notes: nil) {}
        p.later()
        active = false
        now += 5 * 3600; spin(0.2)
        XCTAssertEqual(notified, [], "not before 6 hours")
        now += 3600; spin(0.2)
        XCTAssertEqual(notified, ["0.1.2"], "6 hours in the background: one notification")
        XCTAssertFalse(p.isShowing, "no popup while EditMax is in the background")
        now += 3 * 3600; spin(0.2)
        XCTAssertEqual(notified.count, 1, "once per 6 hours")
        now += 3 * 3600; spin(0.2)
        XCTAssertEqual(notified.count, 2)
        active = true; spin(0.2)
        XCTAssertTrue(p.isShowing, "back in front, more than 2 hours on: the popup")
        p.later()
    }

    /// Reminders start only after Remind Me Later: an unanswered popup just waits for EditMax to be in front again.
    func testNoRemindersBeforeTheUserAnswers() {
        var now = Date(timeIntervalSince1970: 1_000_000), active = true
        let p = prompt(); p.clock = { now }; p.appIsActive = { active }
        p.offer(version: "0.1.2", notes: nil) {}
        active = false
        now += 7 * 3600; spin(0.2)
        XCTAssertEqual(notified, [])
    }

    /// The relaunch onto the offered version (Install Now, or a quit and reopen) says it is installed, once.
    func testAfterTheUpdateTheNextOpenSaysItIsInstalled() {
        let before = prompt(); before.currentVersion = { "0.1.1" }
        before.offer(version: "0.1.2", notes: URL(string: "https://github.com/SkidGod4444/editmax/releases/tag/v0.1.2")) {}
        before.showInstalledNoteIfUpdated()
        XCTAssertNotEqual(before.showing?.name, "installed", "still on 0.1.1: nothing installed yet")
        before.later()

        let after = prompt(); after.currentVersion = { "0.1.2" }; after.installedNoteFor = 0.2
        after.showInstalledNoteIfUpdated()
        XCTAssertTrue(after.isShowing)
        XCTAssertEqual(after.showing, .installed(UpdatePrompt.Offer(version: "0.1.2", notes: URL(string: "https://github.com/SkidGod4444/editmax/releases/tag/v0.1.2"))))
        spin(0.4)
        XCTAssertFalse(after.isShowing, "goes by itself")
        let again = prompt(); again.currentVersion = { "0.1.2" }
        again.showInstalledNoteIfUpdated()
        XCTAssertFalse(again.isShowing, "only once")
    }

    /// The side agent's catch: the popup took the keyboard and Return meant Install Now, so a Return typed into a title
    /// could restart EditMax. Now the panel never becomes key, and Install Now has no key equivalent.
    func testThePopupNeverTakesTheKeyboard() throws {
        let p = prompt()
        p.offer(version: "0.1.2", notes: nil) {}
        let panel = try XCTUnwrap(p.window)
        XCTAssertTrue(p.isShowing)
        XCTAssertFalse(panel.canBecomeKey, "typing stays where it was")
        XCTAssertFalse(panel.isKeyWindow)
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "EditMaxTests/UpdatePromptTests.swift", with: "EditMax/App/UpdatePrompt.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains(".keyboardShortcut("), "no Return / Esc shortcuts in the popup")
        p.later()
    }

    func testThePopupWaitsWhileAnExportRuns() {
        var running: String? = BusyWork.export
        let p = prompt(); p.busy = { running }
        p.offer(version: "0.1.2", notes: nil) {}
        XCTAssertFalse(p.isShowing, "never pops up mid-export")
        spin(0.2)
        XCTAssertFalse(p.isShowing)
        running = nil
        spin(0.3)
        XCTAssertTrue(p.isShowing, "shows once the export is done")
        p.later()
    }

    func testInstallNowWaitsForAnExportThatStartedMeanwhile() {
        var running: String?
        let p = prompt(); p.busy = { running }
        var installs = 0
        p.offer(version: "0.1.2", notes: nil) { installs += 1 }
        XCTAssertTrue(p.isShowing)
        running = BusyWork.agentReply
        p.installNow()
        XCTAssertEqual(installs, 0, "an agent reply is never cut short")
        XCTAssertFalse(p.isShowing)
        running = nil
        spin(0.3)
        XCTAssertTrue(p.isShowing, "asks again when it is done")
        XCTAssertEqual(installs, 0, "and still waits for the click")
        p.installNow()
        XCTAssertEqual(installs, 1)
    }

    /// Exports really count as busy while they render, and stop counting when they end.
    func testAnExportIsBusyWhileItRenders() async throws {
        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
        let fixture = Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4")!
        _ = try await x.importMedia(paths: [fixture.path])
        _ = try x.insertClip(asset: "base.mp4")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("busy-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertNil(BusyWork.current)
        var seen: String?
        _ = try await ExportService.export(doc.project, to: out, preset: .low) { _ in if seen == nil { seen = BusyWork.current } }
        XCTAssertEqual(seen, BusyWork.export)
        XCTAssertNil(BusyWork.current, "done: nothing holds the popup back")
    }

    func testCheckForUpdatesShowsTheWaitingUpdateAgain() {
        let p = UpdatePrompt.shared
        p.offscreen = true; p.appIsActive = { true }; p.busy = { nil }
        p.defaults = defaults; p.askNotificationPermission = {}; p.notify = { _ in }
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
            let card = UpdatePromptView(mode: .ready(offer), install: {}, later: {}, dismiss: {})
            let installed = UpdatePromptView(mode: .installed(offer), install: {}, later: {}, dismiss: {})
            let scene = ZStack(alignment: .top) {
                if let backdrop { Image(nsImage: backdrop).resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height).clipped() }
                else { LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom) }
                card.shadow(color: .black.opacity(0.35), radius: 24, y: 10).padding(.top, size.height / 3 - 110)
            }
            try render(scene, size: size, dark: dark, to: out.appendingPathComponent("update-prompt-\(dark ? "dark" : "light").png"))
            try render(card, size: CGSize(width: 528, height: 190), dark: dark, to: out.appendingPathComponent("update-prompt-card-\(dark ? "dark" : "light").png"))
            try render(installed, size: CGSize(width: 528, height: 190), dark: dark, to: out.appendingPathComponent("update-installed-card-\(dark ? "dark" : "light").png"))
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
