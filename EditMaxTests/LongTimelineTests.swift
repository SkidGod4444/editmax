import XCTest
import SwiftUI
import AppKit
@testable import EditMax

/// An 18-hour clip on the timeline. The ruler, the grid and the clip's frames and waveform are drawn only around what
/// is on screen (an 18-hour lane at 60 pt/s is 3.9 million points wide; drawing it all took 1.7 s per playhead tick),
/// and the timeline no longer re-renders for every tick. Synthetic peaks and frames: no 18-hour file, nothing written to
/// the waveform cache.
@MainActor
final class LongTimelineTests: XCTestCase {
    private let long = 18.0 * 3600

    // MARK: The span

    func testTheDrawnSpanCoversTheScreenAndAScreenEitherSideInWholeTiles() {
        XCTAssertEqual(TimelineViewport.span(around: 0...0), 0...4096, "before the scroll view reports: the first two tiles")
        XCTAssertEqual(TimelineViewport.span(around: 1000...2250), 0...4096)
        XCTAssertEqual(TimelineViewport.span(around: 3_870_000...3_871_250), 3_868_672...3_872_768)
        let v = TimelineViewport()
        v.scrolled(to: 10_000...11_250)
        XCTAssertEqual(v.drawn, 8192...14336)
        v.scrolled(to: 10_400...11_650)
        XCTAssertEqual(v.drawn, 8192...14336, "a small scroll stays in the same tiles (no redraw)")
        // A bar's own slice: clamped to the bar; the whole bar when it all fits; nothing when it is off the span.
        XCTAssertEqual(v.local(start: 0, pps: 60, width: 3_888_000), 8192...14336)
        XCTAssertEqual(v.local(start: 150, pps: 60, width: 600), 0...600)
        XCTAssertEqual(v.local(start: 0, pps: 60, width: 600), 0...0)
    }

    /// A slice is the same pixels as the whole drawing over the same columns: the waveform's 3-column average reads one
    /// column past each end, and frame tiles stay on the grid they have from 0.
    func testASliceDrawsTheSamePixelsAsTheWhole() throws {
        let peaks: [Float] = (0..<6000).map { Float(abs(sin(Double($0) * 0.37))) }
        let frames = [NSColor.systemRed, .systemGreen, .systemBlue, .systemOrange].map { Self.solid($0) }
        let strip = ThumbnailStore.Strip(interval: 15, frames: frames, aspect: 16 / 9)
        func band(_ visible: ClosedRange<CGFloat>?) -> some View {
            VStack(spacing: 0) {
                ThumbnailStripView(strip: strip, sourceIn: 3, sourceOut: 57, visible: visible).frame(height: 36)
                WaveformView(peaks: peaks, sourceIn: 3, sourceOut: 57, color: .white, visible: visible).frame(height: 30)
            }
            .frame(width: 1200, height: 66).background(Color.black)
        }
        let whole = try Self.bitmap(band(nil), size: CGSize(width: 1200, height: 66))
        let slice = try Self.bitmap(band(301.5...777), size: CGSize(width: 1200, height: 66))
        let scale = CGFloat(whole.pixelsWide) / 1200
        var compared = 0, differ: [String] = [], worst: CGFloat = 0
        for x in Int(310 * scale)..<Int(770 * scale) {
            for y in 0..<whole.pixelsHigh {
                compared += 1
                let (a, b) = (Self.rgb(whole.colorAt(x: x, y: y)), Self.rgb(slice.colorAt(x: x, y: y)))
                let d = max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
                worst = max(worst, d)
                if d > 8.0 / 255 { differ.append("\(x),\(y):\(Int(d * 255))") }
            }
        }
        // The same columns and tiles; the waveform's edge antialiasing may differ by a few levels (seen: 5/255) because
        // the slice is a shorter path. A slice off by even one column differs by far more.
        XCTAssertGreaterThan(compared, 10_000)
        XCTAssertEqual(differ.count, 0, "pixels that differ by more than 8/255 (worst \(Int(worst * 255))): \(differ.prefix(8))")
        // And outside the slice nothing is drawn (the black ground shows).
        XCTAssertEqual(slice.colorAt(x: Int(1000 * scale), y: Int(50 * scale))?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1, 0, accuracy: 0.02)
    }

    // MARK: The timeline at hour 17.9

    /// Seeked to 17:55:00, the timeline follows: the playhead, the frame for that time, the waveform's one loud second
    /// (17:55:05) and the ruler's timecodes are all where they belong.
    func testFarIntoAnEighteenHourClipEverythingIsDrawnWhereItBelongs() throws {
        let (doc, _) = project(seconds: long, loud: 64_505)
        let t = Timeline(doc, pps: 60)
        _ = try t.draw(passes: 2)   // laid out once, so the follow knows what is on screen
        t.player.seek(to: 64_500)
        let rep = try t.draw(passes: 5)
        let s = CGFloat(rep.pixelsWide) / Timeline.size.width
        // The follow put the playhead 80 pt in from the lanes' left edge (150 pt of headers).
        let lane = try XCTUnwrap(t.frame("lane.V1"), "V1 is on screen")
        let playX = 150 + 80.0
        // Frame 239 of 240 (64,500 s / 270 s a frame) is blue in this strip.
        let frameY = lane.minY + 5 + 18
        XCTAssertTrue(Self.isBlue(rep.colorAt(x: Int(700 * s), y: Int(frameY * s))), "the frame for 17:55 is drawn there")
        // The loud second, 5 s after the playhead: a tall white shape in the waveform band; quiet a few seconds away.
        let bandTop = lane.minY + 5 + 56 - 18, bandBottom = lane.minY + 5 + 56
        func white(atX x: CGFloat) -> Int {
            (Int(bandTop * s)..<Int(bandBottom * s)).filter { y in Self.isWhite(rep.colorAt(x: Int(x * s), y: y)) }.count
        }
        let loudX = playX + 5.5 * 60
        XCTAssertGreaterThan(white(atX: loudX), Int(8 * s), "17:55:05 is loud")
        XCTAssertLessThan(white(atX: loudX + 4 * 60), Int(3 * s), "17:55:09 is quiet")
        // The ruler has its timecodes across the screen (not blank past the first screen of a 3.9-million-point lane).
        let ruler = try XCTUnwrap(t.frame("ruler"))
        let labelled = stride(from: 160.0, to: 1390.0, by: 10).filter { x in
            (Int((ruler.minY + 3) * s)..<Int((ruler.minY + 13) * s)).contains { y in Self.brightness(rep.colorAt(x: Int(x * s), y: y)) > 0.45 }
        }
        XCTAssertGreaterThan(labelled.count, 30, "timecodes along the ruler at 17:55")
        save(rep, "long-timeline-17h55")
    }

    /// A playhead tick, a selection and a scroll on an 18-hour clip cost what they cost on a 1-minute clip (within 3×:
    /// the CI machine is slow and noisy; before, the 18-hour tick was ~45× the 1-minute one).
    func testAPlayheadTickOnAnEighteenHourClipCostsWhatItDoesOnAOneMinuteClip() throws {
        func perTick(_ seconds: Double) throws -> Double {
            let (doc, _) = project(seconds: seconds, loud: 10)
            let t = Timeline(doc, pps: 60)
            _ = try t.draw(passes: 3)
            let start = Date()
            for i in 0..<8 { t.player.seek(to: 5 + Double(i) / 30); _ = try t.draw(passes: 1) }
            return Date().timeIntervalSince(start) / 8
        }
        _ = try perTick(60)   // warm-up
        let short = try perTick(60), long = try perTick(long)
        print("LONG-TIMELINE per tick: 1 min \(Int(short * 1000)) ms, 18 h \(Int(long * 1000)) ms")
        XCTAssertLessThan(long, max(short * 3, 0.05), "18 h: \(Int(long * 1000)) ms a tick, 1 min: \(Int(short * 1000)) ms")
    }

    /// Real edits cut a long recording up (silence removal on an 18-hour stream leaves thousands of pieces).
    func testAPlayheadTickWithTwoThousandClipsCostsWhatItDoesWithOne() throws {
        func perTick(clips: Int) throws -> Double {
            let (doc, _) = project(seconds: long, loud: 10, clips: clips)
            let t = Timeline(doc, pps: 60)
            t.player.seek(to: 32_400)
            _ = try t.draw(passes: 3)
            let start = Date()
            for i in 0..<8 { t.player.seek(to: 32_405 + Double(i) / 30); _ = try t.draw(passes: 1) }
            return Date().timeIntervalSince(start) / 8
        }
        _ = try perTick(clips: 1)   // warm-up
        let one = try perTick(clips: 1), many = try perTick(clips: 2000)
        print("LONG-TIMELINE per tick at 9 h: 1 clip \(Int(one * 1000)) ms, 2000 clips \(Int(many * 1000)) ms")
        XCTAssertLessThan(many, max(one * 3, 0.05), "2000 clips: \(Int(many * 1000)) ms a tick, 1 clip: \(Int(one * 1000)) ms")
    }

    // MARK: Helpers

    /// `seconds` of one file on V1, as one clip or cut into `clips` back-to-back pieces. Its waveform is quiet except one
    /// loud second at `loud`; its 240 frames are solid red, green, blue in turn, so a tile shows which frame it drew.
    private func project(seconds: Double, loud: Double, clips: Int = 1) -> (EditMaxDocument, Asset) {
        let doc = EditMaxDocument()
        let asset = Asset(name: "stream.mp4", path: "/tmp/long-timeline-\(UUID().uuidString).mp4", kind: .video, duration: seconds, width: 1920, height: 1080)
        doc.project.assets = [asset]
        doc.apply("Set up", origin: .agent) { p in
            let len = seconds / Double(clips)
            if let i = p.tracks.firstIndex(where: { $0.name == "V1" }) {
                p.tracks[i].clips = (0..<clips).map { k in
                    var c = Clip(assetID: asset.id, name: clips == 1 ? "Stream" : "Part \(k + 1)", start: Double(k) * len, duration: len)
                    c.sourceIn = Double(k) * len
                    return c
                }
            }
        }
        var peaks = [Float](repeating: 0.06, count: Int(seconds) * WaveformStore.peaksPerSecond)
        let l = Int(loud) * WaveformStore.peaksPerSecond
        for i in l..<min(peaks.count, l + WaveformStore.peaksPerSecond) { peaks[i] = 1 }
        WaveformStore.shared.install(peaks, for: asset.id)
        let colors: [NSColor] = [.systemRed, .systemGreen, .systemBlue]
        let frames = (0..<240).map { Self.solid(colors[$0 % 3]) }
        ThumbnailStore.shared.install(ThumbnailStore.Strip(interval: seconds / 240, frames: frames, aspect: 16 / 9), for: asset.id)
        return (doc, asset)
    }

    /// The real timeline in a borderless window that is never shown.
    @MainActor private final class Timeline {
        static let size = CGSize(width: 1400, height: 360)
        let player = PlayerController()
        let state = EditorState()
        let host: NSHostingView<AnyView>
        let window: NSWindow
        init(_ doc: EditMaxDocument, pps: Double) {
            state.pixelsPerSecond = pps
            host = NSHostingView(rootView: AnyView(TimelineView(document: doc, player: player).environmentObject(state)
                .frame(width: Self.size.width, height: Self.size.height).environment(\.colorScheme, .dark)))
            window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: Self.size)
        }
        deinit { MainActor.assumeIsolated { window.contentView = nil } }
        func draw(passes: Int) throws -> NSBitmapImageRep {
            for _ in 0..<passes { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        /// An element's on-screen rect, top-left origin in the host's points.
        func frame(_ id: String) -> CGRect? { UIRegistry.shared.elements(in: window).visible.first { $0.id == id }?.rect }
    }

    private static func solid(_ c: NSColor) -> CGImage {
        let ctx = CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(c.usingColorSpace(.deviceRGB)!.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        return ctx.makeImage()!
    }

    private static func bitmap(_ view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func rgb(_ c: NSColor?) -> (CGFloat, CGFloat, CGFloat) {
        guard let c = c?.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }
    private static func brightness(_ c: NSColor?) -> CGFloat { let (r, g, b) = rgb(c); return max(r, g, b) }
    /// By how the channels compare, not exact values: a 1 pt line blends with what is under it, system colours vary.
    private static func isRed(_ c: NSColor?) -> Bool { let (r, g, b) = rgb(c); return r > 0.8 && r - g > 0.35 && r - b > 0.35 }
    private static func isBlue(_ c: NSColor?) -> Bool { let (r, g, b) = rgb(c); return b > 0.8 && b - r > 0.4 && b - g > 0.2 }
    private static func isWhite(_ c: NSColor?) -> Bool { let (r, g, b) = rgb(c); return min(r, g, b) > 0.6 }

    private func save(_ rep: NSBitmapImageRep, _ name: String) {
        guard let dir = ColorFixtures.previewDir, let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
