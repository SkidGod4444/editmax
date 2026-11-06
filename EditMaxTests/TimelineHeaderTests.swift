import XCTest
import SwiftUI
import AppKit
@testable import EditMax

/// The timeline as the editor shows it (the real TimelineView, in an offscreen window): the ruler held at the top
/// while the lanes scroll down, marker pins clear of the timecodes, hidden / muted / soloed tracks in clips and headers.
@MainActor
final class TimelineHeaderTests: XCTestCase {
    /// V1 with clips, V2 hidden, A1 muted, A2 soloed (so A3 is silenced), named markers near ruler labels.
    private func project() throws -> EditMaxDocument {
        let doc = EditMaxDocument()
        doc.project.assets = [Asset(name: "surf.mp4", path: "/tmp/timeline-header-a.mp4", kind: .video, duration: 20, width: 1920, height: 1080),
                              Asset(name: "music.wav", path: "/tmp/timeline-header-b.wav", kind: .audio, duration: 20)]
        let surf = doc.project.assets[0].id, music = doc.project.assets[1].id
        _ = doc.project.addTrack(kind: .video); _ = doc.project.addTrack(kind: .audio); _ = doc.project.addTrack(kind: .audio)
        doc.apply("Set up", origin: .agent) { p in
            func put(_ track: String, _ clips: [Clip]) { if let i = p.tracks.firstIndex(where: { $0.name == track }) { p.tracks[i].clips = clips } }
            put("V1", [Clip(assetID: surf, name: "Ridge", start: 0, duration: 5), Clip(assetID: surf, name: "Interview", start: 5, duration: 4)])
            put("V2", [Clip(assetID: surf, name: "Overlay", start: 2, duration: 6)])
            put("A1", [Clip(assetID: music, name: "Music", start: 0, duration: 9)])
            put("A2", [Clip(assetID: music, name: "Voice", start: 1, duration: 7)])
            put("A3", [Clip(assetID: music, name: "Room tone", start: 3, duration: 6)])
            for i in p.tracks.indices {
                switch p.tracks[i].name {
                case "V2": p.tracks[i].isHidden = true
                case "A1": p.tracks[i].isMuted = true
                case "A2": p.tracks[i].mix.solo = true
                default: break
                }
            }
            p.markers.append(Marker(time: 1.95, name: "", colorHex: "#3B82F6"))
            p.markers.append(Marker(time: 6.9, name: "Jump", colorHex: "#3B82F6"))
        }
        return doc
    }

    /// The timeline in a borderless window that is never shown; `scrollDown` scrolls the lanes before drawing.
    private func render(_ doc: EditMaxDocument, size: CGSize, dark: Bool, scrollDown: CGFloat = 0) throws -> (CGImage, ruler: CGRect?, lane: CGRect?) {
        let player = PlayerController()
        player.seek(to: 3.2)
        let state = EditorState()
        state.pixelsPerSecond = 80
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: TimelineView(document: doc, player: player).environmentObject(state)
            .frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        func settle() { for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) } }
        settle()
        if scrollDown > 0 {
            let outer = try XCTUnwrap(Self.scrollViews(in: host).first, "the timeline's vertical scroll view")
            outer.contentView.scroll(to: NSPoint(x: 0, y: scrollDown))
            outer.reflectScrolledClipView(outer.contentView)
            settle()
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let frames = (UIRegistry.shared.frame("ruler"), UIRegistry.shared.frame("lane.V1"))
        window.contentView = nil
        return (try XCTUnwrap(rep.cgImage), frames.0, frames.1)
    }

    /// Scroll views from the outside in.
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = view as? NSScrollView { out.append(s) }
        for v in view.subviews { out += scrollViews(in: v) }
        return out
    }

    private func save(_ cg: CGImage, _ name: String) {
        guard let dir = ColorFixtures.previewDir else { return }
        ColorFixtures.savePNG(cg, dir.appendingPathComponent("\(name).png"))
    }

    /// M11: scrolled down, the lanes move up and the ruler stays where it was.
    func testRulerStaysAtTheTopWhenTheLanesScrollDown() throws {
        let doc = try project()
        let size = CGSize(width: 1000, height: 300)
        let top = try render(doc, size: size, dark: true)
        let down = try render(doc, size: size, dark: true, scrollDown: 120)
        save(top.0, "timeline-top-dark"); save(down.0, "timeline-scrolled-dark")
        let r0 = try XCTUnwrap(top.ruler), r1 = try XCTUnwrap(down.ruler)
        let l0 = try XCTUnwrap(top.lane), l1 = try XCTUnwrap(down.lane)
        XCTAssertEqual(l1.minY, l0.minY - 120, accuracy: 1, "the lanes scrolled")
        XCTAssertEqual(r1.minY, r0.minY, accuracy: 1, "the ruler stayed at the top")
        for dark in [false] {   // light, for the record
            save(try render(doc, size: size, dark: dark, scrollDown: 120).0, "timeline-scrolled-light")
        }
    }

    /// L6 + L7: dimmed clips on hidden / muted / solo-silenced tracks, the solo in the header, markers below the times.
    func testPreviewHeadersAndMarkers() throws {
        guard ColorFixtures.previewDir != nil else { throw XCTSkip("set TEST_RUNNER_EDITMAX_PREVIEW_DIR to write previews") }
        let doc = try project()
        for dark in [false, true] {
            save(try render(doc, size: CGSize(width: 1000, height: 560), dark: dark).0, "timeline-tracks-\(dark ? "dark" : "light")")
        }
    }

    /// L6: what each track leaves out of the program, as the clip bars show it.
    func testClipsSayWhatTheirTrackLeavesOut() throws {
        let p = try project().project
        func off(_ name: String) -> ClipBody.Off { ClipBody.Off(track: p.tracks.first { $0.name == name }!, in: p) }
        XCTAssertEqual(off("V1"), .init(picture: false, sound: true), "V1's sound is silenced by A2's solo; its picture plays")
        XCTAssertEqual(off("V2"), .init(picture: true, sound: true), "hidden: left out entirely")
        XCTAssertTrue(off("V2").whole(.video))
        XCTAssertFalse(off("V1").whole(.video), "a video clip whose sound is off keeps its picture: only the sound band dims")
        XCTAssertEqual(off("A1"), .init(picture: false, sound: true), "muted")
        XCTAssertEqual(off("A2"), .init(picture: false, sound: false), "soloed: heard")
        XCTAssertEqual(off("A3"), .init(picture: false, sound: true), "silenced by the solo")
        XCTAssertTrue(off("A3").whole(.audio))
    }
}
