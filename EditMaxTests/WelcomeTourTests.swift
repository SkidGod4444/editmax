import XCTest
import SwiftUI
@testable import EditMax

/// The welcome demo (WelcomeTour.swift): the script, the cursor's flight, its size and ring, and a run in a window from
/// the first beat to the end and to a skip. Nothing here makes a sound or clicks EditMax: a performer stands in.
@MainActor
final class WelcomeTourTests: XCTestCase {
    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func testTheScriptShowsAFirstEdit() {
        let actions = DemoBeat.script.map(\.action)
        XCTAssertEqual(actions.first, DemoBeat.Action.none, "it says hello first")
        XCTAssertEqual(actions.last, .outro)
        let order: [DemoBeat.Action] = [.importMedia, .addClips, .cut, .pointAtExport]
        let at = order.compactMap { a in actions.firstIndex(of: a) }
        XCTAssertEqual(at.count, order.count)
        XCTAssertEqual(at, at.sorted(), "media comes in, goes on the timeline, gets cut, then export")
        XCTAssertTrue(actions.contains { if case .play = $0 { return true }; return false })
        XCTAssertTrue(actions.contains { if case .askChat = $0 { return true }; return false })
        XCTAssertEqual(Set(DemoBeat.script.map(\.voice)).count, DemoBeat.script.count, "one recording per line")
        for b in DemoBeat.script {
            XCTAssertLessThanOrEqual(b.caption.count, 28, "'\(b.caption)' fits one short row")
            XCTAssertGreaterThan(b.line.count, b.caption.count, "the voice says more than the row")
            XCTAssertGreaterThanOrEqual(b.readingTime, 1.8)
        }
        for b in DemoBeat.script { XCTAssertNotNil(DemoVoice.url(b.voice), "the '\(b.voice)' line is recorded (scripts/demo-voice.py)") }
        for name in DemoBeat.media {
            XCTAssertNotNil(Bundle.main.path(forResource: (name as NSString).deletingPathExtension, ofType: "mp4"), "\(name) is in the app")
        }
    }

    func testTheCursorArcsAndLands() {
        let start = Date()
        let f = TourFlight(from: CGPoint(x: 100, y: 400), to: CGPoint(x: 900, y: 400), start: start)
        XCTAssertEqual(f.duration, 0.89, accuracy: 0.01, "longer trips take longer, within 0.55 to 1.2 s")
        XCTAssertEqual(f.sample(at: start).point, CGPoint(x: 100, y: 400))
        let mid = f.sample(at: start.addingTimeInterval(f.duration / 2))
        XCTAssertEqual(mid.point.y, 400 - 45, accuracy: 1, "it bows upward on the way (half the 90 pt arc height at the middle)")
        XCTAssertGreaterThan(mid.scale, 1.2, "and grows a little mid-flight")
        XCTAssertEqual(mid.angle, -TourPointer.restingHeading, accuracy: 1, "its tip leads along the path (rightward here)")
        let end = f.sample(at: start.addingTimeInterval(f.duration + 0.01))
        XCTAssertTrue(end.landed)
        XCTAssertEqual(end.point, CGPoint(x: 900, y: 400))
        XCTAssertEqual(end.angle, 0, "it lands in its resting pose")
        XCTAssertEqual(TourFlight(from: .zero, to: CGPoint(x: 10, y: 0), start: start).duration, 0.55, "a short hop is still visible")
        XCTAssertTrue(TourFlight.resting(at: CGPoint(x: 5, y: 5)).sample(at: Date()).landed)
    }

    func testAGlideAlongTheRulerIsStraight() {
        let start = Date()
        let g = TourFlight(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 400, y: 50), start: start, duration: 0.9, arc: false)
        let mid = g.sample(at: start.addingTimeInterval(0.45))
        XCTAssertEqual(mid.point.y, 50, "no bow: the playhead is dragged along the ruler")
        XCTAssertEqual(mid.point.x, 250, accuracy: 1)
        XCTAssertEqual(mid.angle, 0)
        XCTAssertEqual(mid.scale, 1)
    }

    func testTheRingIsIconSized() {
        let tab = CGRect(x: 1058, y: 63, width: 105, height: 27)
        let r = WelcomeTour.ring(around: CGPoint(x: tab.midX, y: tab.midY), in: tab)
        XCTAssertLessThanOrEqual(r.width, 38, "a wide tab still gets an icon-sized box")
        XCTAssertLessThanOrEqual(r.height, 34)
        XCTAssertEqual(r.midX, tab.midX); XCTAssertEqual(r.midY, tab.midY)
        let plus = CGRect(x: 343, y: 62, width: 22, height: 22)
        XCTAssertEqual(WelcomeTour.ring(around: CGPoint(x: plus.midX, y: plus.midY), in: plus).size, CGSize(width: 30, height: 30), "a small icon: just around it")
    }

    func testTheChatTabIsFoundInItsStrip() {
        // The strip in the backdrop: 1046…1400 × 52…94, four tabs.
        let chat = WelcomeTour.tab(.chat, in: CGRect(x: 1046, y: 52, width: 354, height: 42))
        XCTAssertEqual(chat.minX, 1058 + 80.5 + 4, accuracy: 1, "the second of four")
        XCTAssertEqual(chat.width, 80.5, accuracy: 1)
        XCTAssertEqual(chat.height, 26)
    }

    func testThePointerIsThePersonsSize() {
        let system = NSCursor.arrow.image.size
        let p = WelcomeTour.pointerSize
        XCTAssertLessThanOrEqual(p.height, max(system.height, 20) * 4)
        XCTAssertGreaterThanOrEqual(p.height, max(system.height, 20) - 3, "never smaller than the Mac's own arrow")
        XCTAssertEqual(p.width / p.height, 0.65, accuracy: 0.08, "an arrow's proportions")
    }

    func testNothingMakesASoundInTests() {
        XCTAssertFalse(WelcomeTour.shared.voice.enabled)
        XCTAssertNil(DemoVoice.url("no-such-line"))
        XCTAssertNil(WelcomeTour.shared.voice.say("no-such-line"), "no recording: the line runs for its reading time")
        XCTAssertFalse(WelcomeTour.shared.wantsFirstRun, "the unit tests never start the demo")
    }

    private func window() -> NSWindow {
        let w = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    private func useTestDefaults() throws -> () -> Void {
        let suite = "tour-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tour = WelcomeTour.shared
        let saved = tour.defaults
        tour.defaults = defaults; tour.offscreen = true; tour.pace = 0.01
        return { tour.performer = nil; tour.defaults = saved; tour.offscreen = false; tour.pace = 1; defaults.removePersistentDomain(forName: suite) }
    }

    func testTheDemoPlaysEveryBeatAndEnds() async throws {
        let restore = try useTestDefaults()
        defer { restore() }
        let tour = WelcomeTour.shared
        var seen: [String] = []
        var captions: [String] = []
        tour.performer = { beat in seen.append(beat.voice); captions.append(tour.caption) }
        XCTAssertFalse(tour.completed)
        try await tour.run(DemoBeat.script, doc: nil, in: window())
        XCTAssertEqual(seen, DemoBeat.script.map(\.voice), "every beat, in order")
        XCTAssertEqual(captions, DemoBeat.script.map(\.caption), "each with its own line beside the cursor")
        XCTAssertTrue(tour.isRunning)
        XCTAssertTrue(tour.cursorWindow?.isVisible ?? false)
        XCTAssertFalse(tour.cursorWindow?.ignoresMouseEvents ?? true, "the layer keeps stray clicks off the project while it drives")
        XCTAssertFalse(tour.cursorWindow?.canBecomeKey ?? true)
        tour.finish(skipped: false)
        XCTAssertFalse(tour.isRunning)
        XCTAssertFalse(tour.cursorWindow?.isVisible ?? false)
        XCTAssertTrue(tour.completed, "seen: it does not come back by itself")
        XCTAssertEqual(tour.caption, "")
    }

    func testSkipEndsTheDemoAtOnce() async throws {
        let restore = try useTestDefaults()
        defer { restore() }
        let tour = WelcomeTour.shared
        var seen: [String] = []
        tour.performer = { beat in
            seen.append(beat.voice)
            if beat.voice == "import" { try await Task.sleep(for: .seconds(30)) }   // a long beat, cut short
        }
        let run = Task { try await tour.run(DemoBeat.script, doc: nil, in: window()) }
        for _ in 0..<100 where !seen.contains("import") { try await Task.sleep(for: .milliseconds(20)) }
        tour.skip()
        XCTAssertFalse(tour.isRunning, "Esc or Skip stops it there")
        XCTAssertTrue(tour.completed)
        XCTAssertFalse(tour.cursorWindow?.isVisible ?? false)
        run.cancel()
        let result = await run.result
        XCTAssertThrowsError(try result.get(), "the run stops instead of going on to the next beat")
        XCTAssertEqual(seen, ["intro", "import"])
    }

    // MARK: - Look

    func testWelcomeDemoLook() throws {
        guard let d = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_DIR"], !d.isEmpty else { throw XCTSkip("set TEST_RUNNER_EDITMAX_PREVIEW_DIR to write previews") }
        let out = URL(fileURLWithPath: d).appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let backdrop = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_BACKDROP"].flatMap { NSImage(contentsOfFile: $0) }
        let size = CGSize(width: 1400, height: 878)
        // Where things sit in the editor screenshot used as the backdrop (points).
        let plus = CGRect(x: 343, y: 62, width: 22, height: 22), row = CGRect(x: 8, y: 101, width: 362, height: 44)
        let play = CGRect(x: 38, y: 501, width: 28, height: 22), chat = CGRect(x: 1058, y: 63, width: 105, height: 27)
        let export = CGRect(x: 1357, y: 13, width: 28, height: 28)
        func c(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
        let thumb = CGPoint(x: row.minX + 27, y: row.midY)
        let cutX: CGFloat = 155 + 3.3 * 60
        let moments: [(String, DemoCursorView)] = [
            ("1-import", DemoCursorView(tip: c(plus), ring: WelcomeTour.ring(around: c(plus), in: plus), caption: "Bring in your footage")),
            ("2-add", DemoCursorView(tip: thumb, ring: WelcomeTour.ring(around: thumb, in: row), caption: "Double-click to add a clip", pressing: true,
                                     ripples: [TourRipple(point: thumb)])),
            ("3-play", DemoCursorView(tip: c(play), ring: WelcomeTour.ring(around: c(play), in: play), caption: "Space plays it", keys: ["Space"], pressed: ["Space"])),
            ("4-cut", DemoCursorView(tip: CGPoint(x: cutX, y: 540), ring: WelcomeTour.ring(around: CGPoint(x: cutX, y: 595), in: CGRect(x: cutX - 13, y: 568, width: 26, height: 54)),
                                     caption: "Press S to cut", keys: ["S"])),
            ("5-flight", DemoCursorView(tip: CGPoint(x: 820, y: 210), angle: 30, scale: 1.1, caption: "Or just ask Chat")),
            ("6-chat", DemoCursorView(tip: c(chat), ring: WelcomeTour.ring(around: c(chat), in: chat), caption: "Or just ask Chat")),
            ("7-export", DemoCursorView(tip: c(export), ring: WelcomeTour.ring(around: c(export), in: export), caption: "Export with ⌘E", keys: ["⌘", "E"], pressed: ["⌘"])),
        ]
        for (name, cursor) in moments {
            let scene = ZStack(alignment: .bottom) {
                if let backdrop { Image(nsImage: backdrop).resizable().frame(width: size.width, height: size.height) } else { Color(white: 0.12) }
                cursor
                DemoSkipPill(muted: .constant(false), skip: {}).padding(.bottom, 18)
            }
            try render(scene, size: size, dark: true, to: out.appendingPathComponent("demo-\(name).png"))
        }
        for dark in [true, false] {
            let line = HStack(spacing: 20) { DemoBubble(caption: "Press S to cut", keys: ["S"]); DemoBubble(caption: "Your turn!") }.padding(30)
            try render(line, size: CGSize(width: 420, height: 90), dark: dark, to: out.appendingPathComponent("demo-line-\(dark ? "dark" : "light").png"))
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
