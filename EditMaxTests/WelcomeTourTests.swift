import XCTest
import SwiftUI
@testable import EditMax

/// The welcome tour (WelcomeTour.swift): steps finish on what the person does, the cursor's flight, where the card goes,
/// and a run in a window from start to close. Nothing here plays a sound.
@MainActor
final class WelcomeTourTests: XCTestCase {
    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func testStepsFinishOnWhatThePersonDoes() {
        var s = TourSnapshot()
        var p = TourProgress(s)
        XCTAssertEqual(p.step, .media)
        XCTAssertFalse(p.observe(s), "nothing done yet")
        s.assets = 1; s.firstAsset = "hero.mp4"
        XCTAssertTrue(p.observe(s), "a file in Media finishes the media step")
        XCTAssertFalse(p.observe(s), "only once")
        XCTAssertTrue(p.next(s))
        XCTAssertEqual(p.step, .timeline)
        XCTAssertEqual(p.step.target(s), "media.hero.mp4", "the cursor points at the file to double-click")
        s.clips = 1
        XCTAssertTrue(p.observe(s))
        XCTAssertTrue(p.next(s))
        s.playing = true
        XCTAssertTrue(p.observe(s), "playback finishes the play step")
        XCTAssertTrue(p.next(s))
        XCTAssertEqual(p.step, .split)
        XCTAssertFalse(p.observe(s), "the clips already there are not a cut")
        s.clips = 2
        XCTAssertTrue(p.observe(s), "one more clip than when the step began is a cut")
        XCTAssertTrue(p.next(s))
        s.chatOpen = true
        XCTAssertTrue(p.observe(s))
        XCTAssertTrue(p.next(s))
        XCTAssertTrue(p.isLast)
        s.exporting = true
        XCTAssertTrue(p.observe(s))
        XCTAssertFalse(p.next(s), "past the last step the tour is over")
    }

    func testStepsAlreadyDoneWaitForNext() {
        // A project that already has media and clips, playing: the first three steps are done before they show.
        var s = TourSnapshot(assets: 3, clips: 2, playing: true, firstAsset: "a.mov")
        var p = TourProgress(s)
        XCTAssertTrue(p.isDone)
        XCTAssertTrue(p.wasFoundDone, "shown as already done")
        XCTAssertFalse(p.observe(s), "and it does not move the tour on by itself")
        XCTAssertTrue(p.next(s))
        XCTAssertTrue(p.wasFoundDone)
        XCTAssertFalse(p.observe(s))
        XCTAssertTrue(p.next(s))
        XCTAssertTrue(p.wasFoundDone, "playing already")
        XCTAssertTrue(p.next(s))
        XCTAssertEqual(p.step, .split)
        XCTAssertFalse(p.isDone, "a cut is never done before its step")
        s.clips = 3
        XCTAssertTrue(p.observe(s))
        XCTAssertFalse(p.wasFoundDone, "done while showing: this one moves on")
    }

    func testDotsGoOnlyToStepsAlreadyReached() {
        let s = TourSnapshot()
        var p = TourProgress(s)
        p.go(3, s)
        XCTAssertEqual(p.step, .media, "a step not reached yet stays shut")
        _ = p.next(s); _ = p.next(s)
        XCTAssertEqual(p.reached, 2)
        p.go(0, s)
        XCTAssertEqual(p.step, .media)
        p.go(2, s)
        XCTAssertEqual(p.step, .play)
        p.back(s); p.back(s); p.back(s)
        XCTAssertEqual(p.step, .media, "Back stops at the first step")
    }

    func testTheCursorArcsAndLands() {
        let start = Date()
        let f = TourFlight(from: CGPoint(x: 100, y: 400), to: CGPoint(x: 900, y: 400), start: start)
        XCTAssertEqual(f.duration, 0.89, accuracy: 0.01, "longer trips take longer, within 0.55 to 1.2 s")
        let a = f.sample(at: start)
        XCTAssertEqual(a.point, CGPoint(x: 100, y: 400))
        let mid = f.sample(at: start.addingTimeInterval(f.duration / 2))
        XCTAssertEqual(mid.point.y, 400 - 45, accuracy: 1, "it bows upward on the way (half the 90 pt arc height at the middle)")
        XCTAssertGreaterThan(mid.scale, 1.2, "and grows a little mid-flight")
        XCTAssertEqual(mid.angle, -TourPointer.restingHeading, accuracy: 1, "its tip leads along the path (rightward here)")
        let end = f.sample(at: start.addingTimeInterval(f.duration + 0.01))
        XCTAssertTrue(end.landed)
        XCTAssertEqual(end.point, CGPoint(x: 900, y: 400))
        XCTAssertEqual(end.angle, 0, "it lands in its resting pose")
        XCTAssertEqual(TourFlight(from: .zero, to: CGPoint(x: 10, y: 0), start: start).duration, 0.55, "a short hop is still visible")
    }

    func testTheCardKeepsClearOfWhatTheCursorPointsAt() {
        let bounds = CGRect(x: 0, y: 0, width: 1400, height: 878)
        let size = CGSize(width: 488, height: 260)
        let top = WelcomeTour.cardPlace(size: size, in: bounds, avoiding: nil)
        XCTAssertEqual(top, CGPoint(x: 456, y: 878 * 0.12), "over the picture, near the top")
        let split = WelcomeTour.cardPlace(size: size, in: bounds, avoiding: CGRect(x: 355, y: 501, width: 24, height: 22))
        XCTAssertEqual(split, top, "a target low in the window leaves the card where it was")
        let media = WelcomeTour.cardPlace(size: size, in: bounds, avoiding: CGRect(x: 343, y: 62, width: 22, height: 22))
        XCTAssertEqual(media.y, top.y, "a target up top moves the card sideways, not down over the timeline")
        for target in [CGRect(x: 343, y: 62, width: 22, height: 22), CGRect(x: 38, y: 501, width: 28, height: 22),
                       CGRect(x: 1058, y: 63, width: 105, height: 27), CGRect(x: 600, y: 120, width: 200, height: 40)] {
            let card = CGRect(origin: WelcomeTour.cardPlace(size: size, in: bounds, avoiding: target), size: size)
            XCTAssertFalse(card.intersects(target.insetBy(dx: -20, dy: -20)), "card \(card) covers \(target)")
        }
    }

    func testATourRunsInAWindowAndCloses() throws {
        let suite = "tour-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tour = WelcomeTour.shared
        let savedDefaults = tour.defaults, savedAdvance = tour.advanceAfter
        tour.defaults = defaults; tour.offscreen = true; tour.advanceAfter = 0.05
        defer { tour.close(finished: false); tour.defaults = savedDefaults; tour.offscreen = false; tour.advanceAfter = savedAdvance }
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let doc = UUID()
        var snap = TourSnapshot()
        tour.register(doc) { snap }
        defer { tour.unregister(doc) }

        XCTAssertFalse(tour.completed)
        tour.start(doc, in: window)
        XCTAssertTrue(tour.isRunning)
        XCTAssertEqual(tour.progress?.step, .media)
        XCTAssertTrue(tour.cardWindow?.isVisible ?? false)
        XCTAssertTrue(tour.cursorWindow?.ignoresMouseEvents ?? false, "the cursor layer lets every click through")
        XCTAssertFalse(tour.cardWindow?.canBecomeKey ?? true, "the keyboard stays in the project window")

        snap.assets = 1
        spin(0.6)   // the 4 Hz check sees it, then the step moves on by itself
        XCTAssertEqual(tour.progress?.step, .timeline, "adding a file moved the tour on")
        snap.clips = 1
        tour.close(finished: false)
        tour.start(doc, in: window)
        spin(0.6)
        XCTAssertEqual(tour.progress?.step, .media, "a project that has media already: the step waits for Next")
        tour.next()
        spin(0.6)
        XCTAssertEqual(tour.progress?.step, .timeline, "so does one with clips")
        tour.next()
        XCTAssertEqual(tour.progress?.step, .play)
        tour.back()
        tour.back()
        XCTAssertEqual(tour.progress?.step, .media)
        tour.next()
        XCTAssertEqual(tour.progress?.step, .timeline)

        tour.close(finished: false)
        XCTAssertFalse(tour.isRunning)
        XCTAssertFalse(tour.cardWindow?.isVisible ?? false)
        XCTAssertTrue(tour.completed, "closed is seen: it does not come back by itself")
    }

    func testClosingTheProjectEndsTheTour() throws {
        let suite = "tour-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tour = WelcomeTour.shared
        let saved = tour.defaults
        tour.defaults = defaults; tour.offscreen = true
        defer { tour.close(finished: false); tour.defaults = saved; tour.offscreen = false }
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let doc = UUID()
        tour.register(doc) { TourSnapshot() }
        tour.start(doc, in: window)
        XCTAssertTrue(tour.isRunning)
        tour.unregister(doc)
        XCTAssertFalse(tour.isRunning)
    }

    // MARK: - Look

    /// Where the tour's targets sit in the editor screenshot used as the backdrop (1400×878 points).
    private static let backdropTargets: [TourStep: CGRect] = [
        .media: CGRect(x: 343, y: 62, width: 22, height: 22), .timeline: CGRect(x: 8, y: 101, width: 362, height: 44),
        .play: CGRect(x: 38, y: 501, width: 28, height: 22), .split: CGRect(x: 355, y: 501, width: 24, height: 22),
        .chat: CGRect(x: 1058, y: 63, width: 105, height: 27), .export: CGRect(x: 1357, y: 13, width: 28, height: 28),
    ]

    func testWelcomeTourLook() throws {
        guard let d = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_DIR"], !d.isEmpty else { throw XCTSkip("set TEST_RUNNER_EDITMAX_PREVIEW_DIR to write previews") }
        let out = URL(fileURLWithPath: d).appendingPathComponent("tour", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        GlassCompat.forceFallback = true
        defer { GlassCompat.forceFallback = false }
        let backdrop = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_BACKDROP"].flatMap { NSImage(contentsOfFile: $0) }
        let size = CGSize(width: 1400, height: 878)
        var snap = TourSnapshot(assets: 5, clips: 4, firstAsset: "hero.mp4")
        var progress = TourProgress(snap)
        for step in TourStep.allCases {
            if step.rawValue > 0 { _ = progress.next(snap) }
            let target = try XCTUnwrap(Self.backdropTargets[step])
            if step == .split { snap.clips = 4 }
            let card = TourCardView(progress: progress, pressed: step == .export ? ["⌘"] : [])
            let cardSize = NSHostingView(rootView: card).fittingSize
            let place = WelcomeTour.cardPlace(size: cardSize, in: CGRect(origin: .zero, size: size), avoiding: target)
            let tip = WelcomeTour.tip(on: target)
            // The play step is drawn mid-flight, the others landed.
            let flying = step == .play
            let flight = TourFlight(from: CGPoint(x: place.x + 64, y: place.y + cardSize.height / 2), to: tip, start: Date())
            let s = flight.sample(at: flight.start.addingTimeInterval(flight.duration * 0.55))
            let scene = ZStack(alignment: .topLeading) {
                if let backdrop { Image(nsImage: backdrop).resizable().frame(width: size.width, height: size.height) }
                else { Color(white: 0.12) }
                card.shadow(color: .black.opacity(0.35), radius: 24, y: 10).offset(x: place.x, y: place.y)
                TourCursorView(tip: flying ? s.point : tip, angle: flying ? s.angle : 0, scale: flying ? s.scale : 1,
                               target: flying ? nil : target, bubble: flying ? nil : step.bubble)
            }
            try render(scene, size: size, dark: true, to: out.appendingPathComponent("tour-\(step.rawValue + 1)-\(step).png"))
        }
        var done = TourProgress(snap)
        _ = done.next(snap); _ = done.next(snap)
        snap.playing = true
        _ = done.observe(snap)
        for dark in [true, false] {
            let card = TourCardView(progress: done, pressed: ["Space"])
            try render(card, size: NSHostingView(rootView: card).fittingSize, dark: dark, to: out.appendingPathComponent("tour-card-done-\(dark ? "dark" : "light").png"))
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.controlActiveState, .key))
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
