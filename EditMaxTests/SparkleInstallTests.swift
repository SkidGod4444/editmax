import XCTest
import CryptoKit
import Sparkle
@testable import EditMax

/// Install Now for real, end to end, without a release: a stand-in app (UpdateDummy 1.0, a background-only AppKit app
/// compiled here, running, as EditMax is) in a temp folder, a 2.0 build zipped and EdDSA-signed with a key made here
/// (never the release key), served from a local HTTP feed. Sparkle checks, downloads and verifies it in the
/// background; because the app is running it takes the install-on-quit route and hands the update to
/// `AppUpdaterDelegate` → the popup; Install Now runs Sparkle's own installer, which quits the app, replaces it on disk
/// and relaunches it. (With the app not running, Sparkle installs at once and never asks.)
///
/// Off by default (it compiles and runs a stand-in, starts Sparkle's installer and a local server):
/// TEST_RUNNER_EDITMAX_SPARKLE_TEST=1, with a derived-data folder outside ~/Desktop (macOS keeps launchd's installer
/// from reading there, so it hangs at launch).
@MainActor
final class SparkleInstallTests: XCTestCase {
    private let bundleID = "com.editmax.tests.updatedummy"

    func testInstallNowReallyInstallsTheDownloadedUpdate() throws {
        guard ProcessInfo.processInfo.environment["EDITMAX_SPARKLE_TEST"] == "1" else { throw XCTSkip("set TEST_RUNNER_EDITMAX_SPARKLE_TEST=1") }
        guard !Bundle(for: SPUUpdater.self).bundlePath.contains("/Desktop/") else {
            throw XCTSkip("build outside ~/Desktop (-derivedDataPath): launchd's Autoupdate cannot read Sparkle.framework there")
        }
        let started = Date()
        func mark(_ s: String) { print("SPARKLE-TEST +\(Int(Date().timeIntervalSince(started)))s \(s)") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sparkle-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        cleanSparkleState()
        defer { cleanSparkleState(); try? fm.removeItem(at: root) }

        // The stand-in's executable: a background-only AppKit app that quits when asked (Sparkle asks).
        let src = root.appendingPathComponent("main.swift")
        try "import AppKit\nlet app = NSApplication.shared\napp.setActivationPolicy(.prohibited)\napp.run()\n".write(to: src, atomically: true, encoding: .utf8)
        let exe = root.appendingPathComponent("UpdateDummy")
        try run("/usr/bin/xcrun", ["swiftc", src.path, "-o", exe.path])
        mark("compiled the stand-in")
        let key = Curve25519.Signing.PrivateKey()
        let port = Int.random(in: 50_000..<60_000)
        let base = "http://127.0.0.1:\(port)"

        // 1.0 installed, 2.0 published.
        let installed = root.appendingPathComponent("Applications/UpdateDummy.app")
        try makeApp(at: installed, version: "1.0", build: "1", feed: "\(base)/appcast.xml", key: key, exe: exe)
        let built = root.appendingPathComponent("build/UpdateDummy.app")
        try makeApp(at: built, version: "2.0", build: "2", feed: "\(base)/appcast.xml", key: key, exe: exe)
        defer { _ = try? run("/usr/bin/pkill", ["-f", installed.path], check: false) }   // the relaunched 2.0
        let site = root.appendingPathComponent("site", isDirectory: true)
        try fm.createDirectory(at: site, withIntermediateDirectories: true)
        let zip = site.appendingPathComponent("UpdateDummy-2.0.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", built.path, zip.path])
        let zipData = try Data(contentsOf: zip)
        let signature = try key.signature(for: zipData).base64EncodedString()
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>UpdateDummy</title>
            <item>
              <title>UpdateDummy 2.0</title>
              <sparkle:version>2</sparkle:version>
              <sparkle:shortVersionString>2.0</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
              <sparkle:fullReleaseNotesLink>\(base)/notes.html</sparkle:fullReleaseNotesLink>
              <enclosure url="\(base)/UpdateDummy-2.0.zip" length="\(zipData.count)" type="application/octet-stream" sparkle:edSignature="\(signature)"/>
            </item>
          </channel>
        </rss>
        """.write(to: site.appendingPathComponent("appcast.xml"), atomically: true, encoding: .utf8)

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-I", "-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", site.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        XCTAssertTrue(wait(10) { (try? Data(contentsOf: URL(string: "\(base)/appcast.xml")!)) != nil }, "the local feed is up")
        mark("feed up")

        // 1.0 running, as EditMax is when its update arrives.
        let running = Process()
        running.executableURL = installed.appendingPathComponent("Contents/MacOS/UpdateDummy")
        try running.run()
        XCTAssertTrue(wait(10) { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }, "1.0 is running")
        mark("1.0 running")

        // The real updater, pointed at the stand-in, with EditMax's delegate and popup.
        let prompt = UpdatePrompt()
        prompt.offscreen = true; prompt.appIsActive = { true }; prompt.busy = { nil }
        prompt.defaults = UserDefaults(suiteName: "editmax.tests.sparkle")!
        prompt.askNotificationPermission = {}; prompt.notify = { _ in }
        defer { UserDefaults().removePersistentDomain(forName: "editmax.tests.sparkle") }
        let host = try XCTUnwrap(Bundle(url: installed))
        let delegate = AppUpdaterDelegate(prompt: { prompt })
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: SPUStandardUserDriver(hostBundle: host, delegate: nil), delegate: delegate)
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        try updater.start()
        updater.checkForUpdatesInBackground()

        XCTAssertTrue(wait(60) { prompt.offer != nil }, "Sparkle downloaded and verified 2.0 and handed it to the popup")
        mark("offered: \(prompt.offer?.version ?? "nothing")")
        XCTAssertEqual(prompt.offer?.version, "2.0")
        XCTAssertEqual(prompt.offer?.notes?.absoluteString, "\(base)/notes.html")
        XCTAssertTrue(prompt.isShowing)
        XCTAssertEqual(version(of: installed), "1.0", "nothing installed before the click")

        prompt.installNow()   // what the Install Now button does
        XCTAssertTrue(wait(90) { version(of: installed) == "2.0" }, "Install Now replaced the app with 2.0")
        mark("installed: \(version(of: installed) ?? "?")")
        XCTAssertTrue(wait(10) { !running.isRunning }, "1.0 was asked to quit and did")
        XCTAssertTrue(wait(20) {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { $0.processIdentifier != running.processIdentifier }
        }, "and 2.0 was relaunched")
        mark("relaunched")
        XCTAssertFalse(prompt.isShowing)
    }

    // MARK: - Helpers

    private func makeApp(at url: URL, version: String, build: String, feed: String, key: Curve25519.Signing.PrivateKey, exe: URL) throws {
        let fm = FileManager.default
        let macos = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.copyItem(at: exe, to: macos.appendingPathComponent("UpdateDummy"))
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleName": "UpdateDummy", "CFBundleExecutable": "UpdateDummy",
            "CFBundlePackageType": "APPL", "CFBundleVersion": build, "CFBundleShortVersionString": version,
            "CFBundleInfoDictionaryVersion": "6.0", "LSMinimumSystemVersion": "15.0",
            "SUFeedURL": feed, "SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString(),
            "SUEnableAutomaticChecks": true, "SUAutomaticallyUpdate": true, "LSBackgroundOnly": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])   // a whole, valid (ad-hoc) signature
    }

    /// Read from disk each time (Bundle caches its Info.plist).
    private func version(of app: URL) -> String? {
        guard let d = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return p["CFBundleShortVersionString"] as? String
    }

    private func run(_ tool: String, _ args: [String], check: Bool = true) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        try p.run(); p.waitUntilExit()
        if check { XCTAssertEqual(p.terminationStatus, 0, "\(tool) \(args.joined(separator: " "))") }
    }

    private func wait(_ seconds: TimeInterval, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return done()
    }

    /// Sparkle keeps the stand-in's settings and downloads under its bundle id.
    private func cleanSparkleState() {
        UserDefaults().removePersistentDomain(forName: bundleID)
        let lib = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        for sub in ["Caches/\(bundleID)", "Application Support/\(bundleID)", "HTTPStorages/\(bundleID)"] {
            try? FileManager.default.removeItem(at: lib.appendingPathComponent(sub))
        }
    }
}
