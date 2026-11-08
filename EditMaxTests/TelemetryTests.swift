import XCTest
import SwiftUI
@testable import EditMax

/// Crash reports and usage (Support/Telemetry.swift): when anything may be sent, what an event may carry, and the
/// first-launch card. The card's look is written to $EDITMAX_PREVIEW_DIR/telemetry when that is set.
@MainActor
final class TelemetryTests: XCTestCase {
    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func testNothingIsSentFromTestsCIOrADevelopmentBuild() {
        XCTAssertFalse(Telemetry.isAvailable(), "the unit tests never start PostHog")
        XCTAssertFalse(Telemetry.isAvailable(environment: [:], debugBuild: false, testHost: true))
        XCTAssertFalse(Telemetry.isAvailable(environment: ["XCTestConfigurationFilePath": "x"], debugBuild: false, testHost: false))
        XCTAssertFalse(Telemetry.isAvailable(environment: ["CI": "1"], debugBuild: false, testHost: false))
        XCTAssertFalse(Telemetry.isAvailable(environment: [:], debugBuild: true, testHost: false), "a development build sends nothing")
        XCTAssertTrue(Telemetry.isAvailable(environment: ["EDITMAX_POSTHOG": "1"], debugBuild: true, testHost: false), "unless asked to")
        XCTAssertTrue(Telemetry.isAvailable(environment: [:], debugBuild: false, testHost: false), "a release build sends")
    }

    func testAgreeIsRememberedAndStartsNothingHere() throws {
        let suite = "telemetry-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = Telemetry.shared
        let saved = t.defaults
        t.defaults = defaults
        defer { t.defaults = saved }
        XCTAssertFalse(t.agreed)
        t.agree()
        XCTAssertTrue(t.agreed)
        XCTAssertFalse(t.started, "agreed, but the test host never sends")
        t.capture(.exportFinished, ["preset": "1080p"])   // not started: a no-op, not a crash
        t.failed(NSError(domain: "x", code: 1), at: "test")
        defaults.set(Telemetry.terms - 1, forKey: Telemetry.agreedKey)
        XCTAssertFalse(t.agreed, "new terms ask again")
    }

    func testEventsCarryNoPathsTextOrTheUsersName() {
        let clean = Telemetry.Sanitizer.clean([
            "preset": "1080p",
            "file": "/Users/dev/Movies/Wedding.mov",
            "note": String(repeating: "a", count: 65),
            "count": 3,
            "$exception_list": [["value": "NSCocoaErrorDomain 260", "stacktrace": ["frames": [["filename": "/Users/dev/Applications/EditMax.app/Contents/MacOS/EditMax"]]]]],
            "$app_version": "0.1.1",
        ])
        XCTAssertEqual(clean["preset"] as? String, "1080p")
        XCTAssertEqual(clean["count"] as? Int, 3)
        XCTAssertNil(clean["file"], "a path of ours is dropped")
        XCTAssertNil(clean["note"], "long text of ours is dropped")
        XCTAssertEqual(clean["$app_version"] as? String, "0.1.1")
        let frames = (((clean["$exception_list"] as? [[String: Any]])?.first?["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])
        XCTAssertEqual(frames?.first?["filename"] as? String, "/Users/~/Applications/EditMax.app/Contents/MacOS/EditMax", "the user's name is blanked at any depth")
        XCTAssertEqual(Telemetry.Sanitizer.scrubHome("/Users/a.b-c/x and /Users/d/y"), "/Users/~/x and /Users/~/y")
        XCTAssertEqual(Telemetry.Sanitizer.scrubHome("no paths"), "no paths")
    }

    func testCountsGoInCoarseBuckets() {
        XCTAssertEqual(Telemetry.lengthBucket(30), "<1m")
        XCTAssertEqual(Telemetry.lengthBucket(600), "10-60m")
        XCTAssertEqual(Telemetry.lengthBucket(18 * 3600), "3h+")
        XCTAssertEqual(Telemetry.bucket(0, [1, 10, 100]), "<1")
        XCTAssertEqual(Telemetry.bucket(5, [1, 10, 100]), "1-10")
        XCTAssertEqual(Telemetry.bucket(100, [1, 10, 100]), "100+")
    }

    func testTheCardIsNeverAskedForInTests() {
        TelemetryPrompt.shared.offscreen = true
        defer { TelemetryPrompt.shared.offscreen = false }
        TelemetryPrompt.shared.askIfNeeded()
        XCTAssertFalse(TelemetryPrompt.shared.isShowing)
    }

    func testAgreeOnTheCardClosesItAndRemembers() throws {
        let suite = "telemetry-card-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = Telemetry.shared.defaults
        Telemetry.shared.defaults = defaults
        defer { Telemetry.shared.defaults = saved }
        let p = TelemetryPrompt.shared
        p.offscreen = true
        defer { p.offscreen = false }
        p.show()
        XCTAssertTrue(p.isShowing)
        XCTAssertFalse(p.window?.isKeyWindow ?? true, "it never takes the keyboard")
        p.agree()
        XCTAssertFalse(p.isShowing)
        XCTAssertTrue(Telemetry.shared.agreed)
    }

    // MARK: - Look

    func testTelemetryCardAndSettingsLook() throws {
        guard let d = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_DIR"], !d.isEmpty else { throw XCTSkip("set TEST_RUNNER_EDITMAX_PREVIEW_DIR to write previews") }
        let out = URL(fileURLWithPath: d).appendingPathComponent("telemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        GlassCompat.forceFallback = true   // real glass does not draw offscreen; its stand-in does
        defer { GlassCompat.forceFallback = false }
        let backdrop = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_BACKDROP"].flatMap { NSImage(contentsOfFile: $0) }
        for dark in [true, false] {
            let size = CGSize(width: 1400, height: 878)
            let card = TelemetryPromptView(agree: {})
            let scene = ZStack(alignment: .top) {
                if let backdrop { Image(nsImage: backdrop).resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height).clipped() }
                else { LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom) }
                card.shadow(color: .black.opacity(0.35), radius: 24, y: 10).padding(.top, size.height / 3 - 110)
            }
            let tag = dark ? "dark" : "light"
            try render(scene, size: size, dark: dark, to: out.appendingPathComponent("telemetry-prompt-\(tag).png"))
            try render(card, size: CGSize(width: 528, height: 210), dark: dark, to: out.appendingPathComponent("telemetry-card-\(tag).png"))
            try render(GeneralSettings(), size: CGSize(width: 620, height: 760), dark: dark, to: out.appendingPathComponent("settings-general-\(tag).png"))
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
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
