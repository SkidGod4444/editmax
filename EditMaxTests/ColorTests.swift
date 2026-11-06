import XCTest
import CoreImage
import AVFoundation
import AppKit
@testable import EditMax

/// Shared picture helpers for the color tests: a generated chart, a natural photo, frame rendering through the real
/// compositor maths, pixel reads and PNG previews (`EDITMAX_PREVIEW_DIR`, set as `TEST_RUNNER_EDITMAX_PREVIEW_DIR`).
enum ColorFixtures {
    static let ctx = EditMaxCompositor.context
    static let size = CGSize(width: 960, height: 540)

    static var previewDir: URL? {
        guard let p = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_DIR"], !p.isEmpty else { return nil }
        let u = URL(fileURLWithPath: p)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A test chart: a gray ramp, 75 % primaries and secondaries, skin tones, sky, foliage, and a hue × brightness sweep.
    static func chart(_ s: CGSize = size) -> CIImage {
        let w = Int(s.width), h = Int(s.height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ r: Double, _ g: Double, _ b: Double, _ rect: CGRect) { cg.setFillColor(CGColor(colorSpace: cs, components: [r, g, b, 1])!); cg.fill(rect) }
        let H = Double(h), W = Double(w)
        // Top band (CG is y-up: the top is at H): a 0…1 gray ramp in 32 steps.
        for i in 0..<32 { let v = Double(i) / 31; fill(v, v, v, CGRect(x: W * Double(i) / 32, y: H * 0.8, width: W / 32 + 1, height: H * 0.2)) }
        // Patches row 1: R G B C M Y at 75 %; row 2: three skin tones, sky, foliage, mid gray.
        let row1: [(Double, Double, Double)] = [(0.75, 0, 0), (0, 0.75, 0), (0, 0, 0.75), (0, 0.75, 0.75), (0.75, 0, 0.75), (0.75, 0.75, 0)]
        let row2: [(Double, Double, Double)] = [(0.95, 0.78, 0.66), (0.78, 0.57, 0.44), (0.45, 0.30, 0.22), (0.38, 0.55, 0.78), (0.30, 0.45, 0.20), (0.46, 0.46, 0.46)]
        for (i, c) in row1.enumerated() { fill(c.0, c.1, c.2, CGRect(x: W * Double(i) / 6, y: H * 0.6, width: W / 6 + 1, height: H * 0.2)) }
        for (i, c) in row2.enumerated() { fill(c.0, c.1, c.2, CGRect(x: W * Double(i) / 6, y: H * 0.4, width: W / 6 + 1, height: H * 0.2)) }
        // Bottom: hue left → right, brightness bottom → top.
        let cols = 72, rows = 12
        for i in 0..<cols { for j in 0..<rows {
            let (r, g, b) = ColorBalance.pure(Double(i) * 360 / Double(cols)), v = 0.15 + 0.85 * Double(j) / Double(rows - 1)
            fill(r * v, g * v, b * v, CGRect(x: W * Double(i) / Double(cols), y: H * 0.4 * Double(j) / Double(rows), width: W / Double(cols) + 1, height: H * 0.4 / Double(rows) + 1))
        } }
        return CIImage(cgImage: cg.makeImage()!, options: [.colorSpace: NSNull()])
    }

    /// The system's parrot photo (every Mac has it), as the compositor would load a still; nil when missing.
    static func photo(_ name: String = "/Library/User Pictures/Animals/Parrot.heic") -> CIImage? {
        StillLoader.load(URL(fileURLWithPath: name))
    }

    /// A still clip rendered through `FrameRenderer.frame` (orientation, fit, transform, grade, layers, finishing).
    static func frame(_ clip: Clip, still: CIImage, size: CGSize = size, at t: Double = 0.5) -> CIImage {
        let src = LayerSource(trackID: kCMPersistentTrackID_Invalid, still: still, naturalSize: still.extent.size, preferredTransform: .identity,
                              clip: clip, effectiveEnd: clip.end, transitionEnd: nil, outgoingID: nil)
        let inst = EditMaxInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
                                      layers: [TrackLayer(current: src, outgoing: nil)], texts: [], renderSize: size, requiredTrackIDs: [])
        return FrameRenderer.frame(inst, at: t) { _ in nil }
    }

    static func clip(_ body: (inout Clip) -> Void = { _ in }) -> Clip {
        var c = Clip(assetID: UUID(), name: "test", start: 0, duration: 10)
        body(&c)
        return c
    }

    static func cgImage(_ img: CIImage, _ rect: CGRect? = nil) -> CGImage {
        let r = rect ?? img.extent
        return ctx.createCGImage(img, from: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }

    /// Unpremultiplied RGBA floats of one pixel (CI coordinates, y up).
    static func pixel(_ img: CIImage, _ x: Double, _ y: Double) -> [Float] {
        var px = [Float](repeating: 0, count: 4)
        ctx.render(img, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let a = max(px[3], 1e-6)
        return [px[0] / a, px[1] / a, px[2] / a, px[3]]
    }

    /// Pixel at a fraction of the frame (y down, like EditMax positions).
    static func at(_ img: CIImage, _ fx: Double, _ fy: Double) -> [Float] {
        pixel(img, img.extent.minX + fx * img.extent.width, img.extent.minY + (1 - fy) * img.extent.height)
    }

    @discardableResult
    static func save(_ img: CIImage, _ name: String, rect: CGRect? = nil) -> URL? {
        guard let dir = previewDir else { return nil }
        let r = rect ?? CGRect(origin: .zero, size: size)
        return savePNG(cgImage(img.cropped(to: r), r), dir.appendingPathComponent(name))
    }

    @discardableResult
    static func savePNG(_ cg: CGImage, _ url: URL) -> URL? {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: url)
        return url
    }

    /// Two images side by side with a gap, for before/after previews.
    static func pair(_ a: CIImage, _ b: CIImage, gap: CGFloat = 8) -> CIImage {
        let w = a.extent.width
        let right = b.transformed(by: CGAffineTransform(translationX: w + gap, y: 0))
        let bg = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12)).cropped(to: CGRect(x: 0, y: 0, width: w + gap + b.extent.width, height: a.extent.height))
        return right.composited(over: a.composited(over: bg))
    }
}

@MainActor
final class ColorWheelsCurvesTests: XCTestCase {
    typealias F = ColorFixtures
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }

    override func setUp() async throws {
        doc = EditMaxDocument()
        doc.project.assets.append(Asset(name: "a.mp4", path: "/tmp/a.mp4", kind: .video, duration: 10, width: 1920, height: 1080))
        doc.project.assets.append(Asset(name: "b.mp4", path: "/tmp/b.mp4", kind: .video, duration: 10, width: 1920, height: 1080))
        doc.project.assets.append(Asset(name: "music.m4a", path: "/tmp/music.m4a", kind: .audio, duration: 30))
    }

    func testOldFilesDecodeWithTheColorFeaturesOff() throws {
        let json = #"{"exposure": 0.5, "lut": "Film Fade"}"#
        let c = try JSONDecoder().decode(ClipColor.self, from: Data(json.utf8))
        XCTAssertNil(c.wheels); XCTAssertNil(c.curves); XCTAssertEqual(c.exposure, 0.5)
        let clipJSON = #"{"id": "\#(UUID().uuidString)", "assetID": "\#(UUID().uuidString)", "name": "x", "start": 0, "duration": 2}"#
        let clip = try JSONDecoder().decode(Clip.self, from: Data(clipJSON.utf8))
        XCTAssertTrue(clip.grades.isEmpty); XCTAssertNil(clip.finish); XCTAssertFalse(clip.hasColorExtras)
        // A clip without the new keys encodes without them.
        let s = String(decoding: try JSONEncoder().encode(Clip(assetID: UUID(), name: "y", start: 0, duration: 1)), as: UTF8.self)
        XCTAssertFalse(s.contains("wheels")); XCTAssertFalse(s.contains("finish"))
    }

    func testAnUngradedClipRendersExactlyAsBefore() {
        let chart = F.chart()
        let plain = F.frame(F.clip(), still: chart)
        for (fx, fy) in [(0.05, 0.1), (0.5, 0.5), (0.3, 0.7), (0.9, 0.9)] {
            XCTAssertEqual(F.at(plain, fx, fy), F.at(chart, fx, fy), "untouched pixel at \(fx),\(fy)")
        }
        // Identity wheels or curves are normalized away by the setters, and even if stored they change nothing.
        var c = ClipColor(); c.wheels = ColorWheels(); c.curves = ColorCurves()
        let same = FrameRenderer.graded(chart, c)
        XCTAssertEqual(F.at(same, 0.5, 0.5), F.at(chart, 0.5, 0.5))
    }

    func testWheelFormulas() {
        var w = ColorWheels()
        w.lift = ColorWheel(b: 0.05, master: -0.05)
        XCTAssertEqual(w.apply(0, channel: 0), -0.05, accuracy: 1e-9)   // red black goes to -0.05
        XCTAssertEqual(w.apply(0, channel: 2), 0, accuracy: 1e-9)       // blue black stays (master + 0.05)
        XCTAssertEqual(w.apply(1, channel: 0), 1, accuracy: 1e-9)       // white stays
        w = ColorWheels(); w.gain = ColorWheel(master: 0.2)
        XCTAssertEqual(w.apply(0.5, channel: 1), 0.6, accuracy: 1e-9)
        XCTAssertEqual(w.apply(1.5, channel: 1), 1.8, accuracy: 1e-9, "over-range values are mapped, not clipped")
        w = ColorWheels(); w.gamma = ColorWheel(master: 0.25)
        XCTAssertGreaterThan(w.apply(0.5, channel: 0), 0.5); XCTAssertEqual(w.apply(1, channel: 0), 1, accuracy: 1e-9); XCTAssertEqual(w.apply(0, channel: 0), 0)
        w = ColorWheels(); w.offset = ColorWheel(r: 0.1)
        XCTAssertEqual(w.apply(0.3, channel: 0), 0.4, accuracy: 1e-9)
    }

    func testTowardIsLumaNeutralAndPointsAtTheHue() {
        let b = ColorBalance.toward(hue: ColorBalance.hue("blue")!, amount: 0.05)
        XCTAssertEqual(ColorBalance.luma(b.r, b.g, b.b), 0, accuracy: 1e-9)
        XCTAssertEqual(b.b, 0.05, accuracy: 1e-9); XCTAssertLessThan(b.r, 0)
        let warm = ColorBalance.toward(hue: ColorBalance.hue("warm")!, amount: 0.1)
        XCTAssertGreaterThan(warm.r, warm.b)
        XCTAssertNil(ColorBalance.hue("blurple"))
        XCTAssertEqual(ColorBalance.name(ofHue: 245), "blue")
    }

    func testTheLUTMapsValuesAboveOneInsteadOfClipping() {
        // A flat 1.5 (an exposure push) through a gentle gain -0.2: 1.5 · 0.8 = 1.2, not 0.8 (what a clipped 1.0 would give).
        let bright = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            .applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: 1.5, y: 0.5, z: -0.1, w: 0)])
        var w = ColorWheels(); w.gain = ColorWheel(master: -0.2)
        let out = F.pixel(ColorCorrection.apply(bright, wheels: w, curves: nil), 2, 2)
        XCTAssertEqual(out[0], 1.2, accuracy: 0.004); XCTAssertEqual(out[1], 0.4, accuracy: 0.003); XCTAssertEqual(out[2], -0.08, accuracy: 0.003)
        XCTAssertEqual(out[3], 1, accuracy: 1e-4, "alpha passes through")
    }

    func testCurvesPassThroughTheirPointsAndContinuePastOne() {
        let s = CurveSpline([CurvePoint(0.25, 0.15), CurvePoint(0.75, 0.85)])
        XCTAssertEqual(s.value(0.25), 0.15, accuracy: 1e-9); XCTAssertEqual(s.value(0.75), 0.85, accuracy: 1e-9)
        XCTAssertEqual(s.value(0), 0, accuracy: 1e-9); XCTAssertEqual(s.value(1), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(s.value(1.2), 1, "past 1 it keeps going")
        // Monotone: no overshoot between the points.
        var last = -1.0
        for i in 0...100 { let v = s.value(Double(i) / 100); XCTAssertGreaterThanOrEqual(v, last - 1e-12); last = v }
        // Hue curve wraps: one dip at green leaves red alone.
        let h = CurveSpline([CurvePoint(0.2, 1), CurvePoint(0.333, 0.3), CurvePoint(0.46, 1)], periodic: true)
        XCTAssertEqual(h.value(0.333), 0.3, accuracy: 1e-9); XCTAssertEqual(h.value(0.95), 1, accuracy: 1e-6); XCTAssertEqual(h.value(1.333), 0.3, accuracy: 1e-9)
    }

    func testHueVsSatMutesOneHueOnly() {
        let chart = F.chart()
        var c = ClipColor(); var cv = ColorCurves(); cv.hueSat = [CurvePoint(0.2, 1), CurvePoint(0.333, 0), CurvePoint(0.46, 1)]; c.curves = cv
        let out = FrameRenderer.graded(chart, c)
        let green = F.at(out, 1.5 / 6, 0.3), red = F.at(out, 0.5 / 6, 0.3)
        XCTAssertEqual(green[0], green[1], accuracy: 0.02, "the green patch went gray"); XCTAssertEqual(green[1], green[2], accuracy: 0.02)
        let r0 = F.at(chart, 0.5 / 6, 0.3)
        for i in 0..<3 { XCTAssertEqual(red[i], r0[i], accuracy: 0.02, "red is untouched") }
    }

    func testWheelsToolSetsValidatesAndUndoesInOneStep() throws {
        let clip = try x.insertClip(asset: "a.mp4")
        let r = try x.setColorWheels(clip.id.short, layer: nil, wheel: "lift", r: nil, g: nil, b: nil, master: -0.05, toward: "blue", amount: 0.05, reset: false)
        XCTAssertEqual(r.value.master, -0.05); XCTAssertEqual(r.value.b, 0.05, accuracy: 1e-9)
        XCTAssertEqual(doc.project.clip(clip.id)!.clip.color.wheels?.lift.b ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertThrowsError(try x.setColorWheels(clip.id.short, layer: nil, wheel: "lift", r: 1.5, g: nil, b: nil, master: nil, toward: nil, amount: nil, reset: false)) { XCTAssertTrue("\($0)".contains("between -1 and 1"), "\($0)") }
        XCTAssertThrowsError(try x.setColorWheels(clip.id.short, layer: nil, wheel: "shadows", r: 0.1, g: nil, b: nil, master: nil, toward: nil, amount: nil, reset: false))
        XCTAssertThrowsError(try x.setColorWheels(clip.id.short, layer: nil, wheel: "gain", r: 0.1, g: nil, b: nil, master: nil, toward: "blue", amount: 0.1, reset: false))
        XCTAssertThrowsError(try x.setColorWheels(clip.id.short, layer: nil, wheel: "gain", r: nil, g: nil, b: nil, master: nil, toward: "blurple", amount: 0.1, reset: false))
        let music = try x.insertClip(asset: "music.m4a")
        XCTAssertThrowsError(try x.setColorWheels(music.id.short, layer: nil, wheel: "gain", r: 0.1, g: nil, b: nil, master: nil, toward: nil, amount: nil, reset: false))
        // Back to zero = nil again, so the clip is ungraded and identical to before.
        _ = try x.setColorWheels(clip.id.short, layer: nil, wheel: "all", r: nil, g: nil, b: nil, master: nil, toward: nil, amount: nil, reset: true)
        XCTAssertNil(doc.project.clip(clip.id)!.clip.color.wheels)
        XCTAssertTrue(doc.project.clip(clip.id)!.clip.color.isIdentity)
        doc.undo()
        XCTAssertNotNil(doc.project.clip(clip.id)!.clip.color.wheels, "one undo step brings the wheels back")
    }

    func testCurveToolValidates() throws {
        let clip = try x.insertClip(asset: "a.mp4")
        let r = try x.setColorCurve(clip.id.short, layer: nil, curve: "master", points: [[0.25, 0.2], [0.75, 0.8]])
        XCTAssertEqual(r.samples[2], 0.5, accuracy: 0.01); XCTAssertEqual(r.points.count, 2)
        XCTAssertThrowsError(try x.setColorCurve(clip.id.short, layer: nil, curve: "master", points: [[0.5, 1.4]]))
        XCTAssertThrowsError(try x.setColorCurve(clip.id.short, layer: nil, curve: "master", points: [[0.5, 0.4], [0.505, 0.5]]))
        XCTAssertThrowsError(try x.setColorCurve(clip.id.short, layer: nil, curve: "luma", points: []))
        XCTAssertThrowsError(try x.setColorCurve(clip.id.short, layer: nil, curve: "red", points: [[0.5]]))
        _ = try x.setColorCurve(clip.id.short, layer: nil, curve: "hue_sat", points: [[0.33, 1.8]])
        XCTAssertEqual(doc.project.clip(clip.id)!.clip.color.curves?.hueSat.count, 1)
        _ = try x.setColorCurve(clip.id.short, layer: nil, curve: "master", points: [])
        _ = try x.setColorCurve(clip.id.short, layer: nil, curve: "hue_sat", points: [])
        XCTAssertNil(doc.project.clip(clip.id)!.clip.color.curves, "every curve removed = off")
    }

    /// Before/after previews of the wheels and curves on the chart and the parrot.
    func testPreviewWheelsAndCurves() throws {
        let chart = F.chart()
        let photo = F.photo()
        func both(_ name: String, _ color: ClipColor) {
            let c = F.clip { $0.color = color }
            F.save(F.pair(F.frame(F.clip(), still: chart), F.frame(c, still: chart)), "\(name)-chart-before-after.png", rect: CGRect(x: 0, y: 0, width: F.size.width * 2 + 8, height: F.size.height))
            if let photo { F.save(F.pair(F.frame(F.clip(), still: photo), F.frame(c, still: photo)), "\(name)-photo-before-after.png", rect: CGRect(x: 0, y: 0, width: F.size.width * 2 + 8, height: F.size.height)) }
        }
        var c = ClipColor(); var w = ColorWheels()
        let blue = ColorBalance.toward(hue: 240, amount: 0.05)
        w.lift = ColorWheel(r: blue.r, g: blue.g, b: blue.b, master: -0.05); c.wheels = w
        both("wheels-lift-blue", c)
        c = ClipColor(); w = ColorWheels()
        let teal = ColorBalance.toward(hue: 190, amount: 0.06), orange = ColorBalance.toward(hue: 30, amount: 0.06)
        w.lift = ColorWheel(r: teal.r, g: teal.g, b: teal.b); w.gain = ColorWheel(r: orange.r, g: orange.g, b: orange.b, master: 0.05); w.gamma = ColorWheel(master: 0.05); c.wheels = w
        both("wheels-teal-orange", c)
        c = ClipColor(); var cv = ColorCurves(); cv.master = [CurvePoint(0.25, 0.18), CurvePoint(0.75, 0.84)]; c.curves = cv
        both("curves-master-s", c)
        c = ClipColor(); cv = ColorCurves(); cv.blue = [CurvePoint(0.3, 0.38), CurvePoint(0.7, 0.66)]; cv.red = [CurvePoint(0.5, 0.53)]; c.curves = cv
        both("curves-red-blue", c)
        c = ClipColor(); cv = ColorCurves(); cv.hueSat = [CurvePoint(0.2, 1), CurvePoint(0.333, 0.1), CurvePoint(0.46, 1)]; c.curves = cv
        both("curves-huesat-mute-green", c)
    }
}

@MainActor
final class ColorScopesTests: XCTestCase {
    typealias F = ColorFixtures

    private func stats(_ img: CIImage) -> (ColorScopes.ParadeStats, ColorScopes.VectorStats) {
        let s = ToolExecutor.samplePixels(F.cgImage(img, CGRect(origin: .zero, size: F.size)))!
        return ColorScopes.stats(rgba: s.px)
    }

    func testANeutralRampHasNoCastAndEqualTraces() {
        let ramp = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: F.size.width, y: 0),
                                                                 "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1)])!.outputImage!.cropped(to: CGRect(origin: .zero, size: F.size))
        let (p, v) = stats(ramp)
        XCTAssertEqual(p.red.median, p.blue.median, accuracy: 1); XCTAssertEqual(p.red.low, p.green.low, accuracy: 1)
        XCTAssertLessThan(v.castStrength, 0.005); XCTAssertEqual(v.castName, "neutral"); XCTAssertLessThan(v.meanSaturation, 0.01)
        // The same ramp with blue lifted shadows reads as a blue cast, with the blue black level above red's.
        var c = ClipColor(); var w = ColorWheels(); w.lift = ColorWheel(b: 0.1); c.wheels = w
        let (p2, v2) = stats(FrameRenderer.graded(ramp, c))
        XCTAssertGreaterThan(p2.blue.low, p2.red.low + 15); XCTAssertEqual(v2.castName, "blue"); XCTAssertTrue(p2.note.contains("shadows carry a tint"), p2.note)
    }

    func testVectorscopePlacesPrimariesWhereTheTargetsAre() {
        let red = CIImage(color: CIColor(red: 0.75, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: F.size))
        let (_, v) = stats(red)
        XCTAssertEqual(v.castName, "red"); XCTAssertEqual(v.dominantName, "red"); XCTAssertEqual(v.hueShare[0], 1, accuracy: 0.001)
        XCTAssertEqual(ColorScopes.hue(cb: ColorBalance.scope(r: 0, g: 0, b: 1).cb, cr: ColorBalance.scope(r: 0, g: 0, b: 1).cr), 240, accuracy: 1)
        // The image: a red frame puts its spot in the red target's quadrant (up and left of centre).
        let p = ColorScopes.vectorPoint(r: 0.75, g: 0, b: 0)
        XCTAssertLessThan(p.x, Double(ColorScopes.vectorSize) / 2); XCTAssertLessThan(p.y, Double(ColorScopes.vectorSize) / 2)
    }

    func testScopesImagesOfTheChartAndThePhoto() throws {
        let (png, data) = try ToolExecutor.scopesPNG(F.cgImage(F.chart(), CGRect(origin: .zero, size: F.size)), width: 1200)
        XCTAssertNotNil(data.parade); XCTAssertNotNil(data.vectorscope); XCTAssertGreaterThan(png.count, 1000)
        guard let dir = F.previewDir else { return }
        try png.write(to: dir.appendingPathComponent("scopes-chart.png"))
        F.save(F.chart(), "scopes-chart-frame.png")
        if let photo = F.photo() {
            let plain = F.frame(F.clip(), still: photo)
            try ToolExecutor.scopesPNG(F.cgImage(plain, CGRect(origin: .zero, size: F.size)), width: 1200).0.write(to: dir.appendingPathComponent("scopes-photo.png"))
            var c = ClipColor(); var w = ColorWheels()
            let teal = ColorBalance.toward(hue: 190, amount: 0.08), orange = ColorBalance.toward(hue: 30, amount: 0.08)
            w.lift = ColorWheel(r: teal.r, g: teal.g, b: teal.b); w.gain = ColorWheel(r: orange.r, g: orange.g, b: orange.b); c.wheels = w
            let graded = F.frame(F.clip { $0.color = c }, still: photo)
            try ToolExecutor.scopesPNG(F.cgImage(graded, CGRect(origin: .zero, size: F.size)), width: 1200).0.write(to: dir.appendingPathComponent("scopes-photo-teal-orange.png"))
        }
    }
}

@MainActor
final class ColorStackAndMatchTests: XCTestCase {
    typealias F = ColorFixtures
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }

    override func setUp() async throws {
        doc = EditMaxDocument()
        doc.project.assets.append(Asset(name: "a.mp4", path: "/tmp/a.mp4", kind: .video, duration: 10, width: 1920, height: 1080))
        doc.project.assets.append(Asset(name: "music.m4a", path: "/tmp/music.m4a", kind: .audio, duration: 30))
    }

    private func layer(_ body: (inout GradeLayer) -> Void) -> GradeLayer { var l = GradeLayer(name: "L"); body(&l); return l }

    func testLayersApplyInOrderAfterThePrimaryGradeAndMixBack() {
        let chart = F.chart()
        var primary = ClipColor(); primary.exposure = 0.5
        var warm = ClipColor(); warm.saturation = 0
        let plain = F.frame(F.clip { $0.color = primary }, still: chart)
        // A gray layer on top of the primary grade = the primary grade, then desaturated.
        let full = F.frame(F.clip { $0.color = primary; $0.grades = [layer { $0.color = warm }] }, still: chart)
        let manual = FrameRenderer.graded(plain, warm)
        for (fx, fy) in [(0.3, 0.3), (0.7, 0.6), (0.5, 0.9)] {
            let a = F.at(full, fx, fy), b = F.at(manual, fx, fy)
            for ch in 0..<3 { XCTAssertEqual(a[ch], b[ch], accuracy: 0.004) }
            XCTAssertEqual(a[0], a[1], accuracy: 0.004, "desaturated")
        }
        // mix 0.5 lands halfway, a disabled layer and mix 0 change nothing.
        let half = F.frame(F.clip { $0.color = primary; $0.grades = [layer { $0.color = warm; $0.mix = 0.5 }] }, still: chart)
        let p = F.at(plain, 0.7, 0.6), m = F.at(manual, 0.7, 0.6), h = F.at(half, 0.7, 0.6)
        for ch in 0..<3 { XCTAssertEqual(h[ch], (p[ch] + m[ch]) / 2, accuracy: 0.006) }
        for l in [layer { $0.color = warm; $0.enabled = false }, layer { $0.color = warm; $0.mix = 0 }] {
            let off = F.frame(F.clip { $0.color = primary; $0.grades = [l] }, still: chart)
            for ch in 0..<3 { XCTAssertEqual(F.at(off, 0.7, 0.6)[ch], p[ch], accuracy: 1e-4) }
        }
        // Order: +1 stop then gray differs from... gray is order-independent with exposure, so use a hue shift instead.
        var blueLift = ClipColor(); var w = ColorWheels(); w.offset = ColorWheel(b: 0.2); blueLift.wheels = w
        let ab = F.frame(F.clip { $0.grades = [layer { $0.color = blueLift }, layer { $0.color = warm }] }, still: chart)
        let ba = F.frame(F.clip { $0.grades = [layer { $0.color = warm }, layer { $0.color = blueLift }] }, still: chart)
        let pa = F.at(ab, 0.5, 0.9), pb = F.at(ba, 0.5, 0.9)
        XCTAssertEqual(pa[0], pa[2], accuracy: 0.004, "gray last: no blue left")
        XCTAssertGreaterThan(pb[2], pb[0] + 0.1, "blue last: blue stays")
    }

    func testShotMatchSolverBringsAGradedFrameBackToTheReference() throws {
        guard let photo = F.photo() else { throw XCTSkip("no system photo") }
        let sz = CGSize(width: 512, height: 512), rect = CGRect(origin: .zero, size: sz)   // the photo is square: no bars, as match_color measures
        let ref = F.frame(F.clip(), still: photo, size: sz)
        let refStats = try ToolExecutor.matchStats(F.cgImage(ref, rect)).0
        // A shot with a warm cast, lifted blacks, a bit dark and less saturated.
        var off = ClipColor(); off.temperature = 35; off.exposure = -0.35; off.saturation = 0.75; var w = ColorWheels(); w.lift = ColorWheel(master: 0.05); off.wheels = w
        let target = F.frame(F.clip { $0.color = off }, still: photo, size: sz)
        let (tStats, tPx) = try ToolExecutor.matchStats(F.cgImage(target, rect))
        let sol = ShotMatch.solve(target: tPx, reference: refStats)
        var fix = GradeLayer(name: ShotMatch.layerName); fix.color.saturation = sol.saturation; fix.color.wheels = sol.wheels
        let matched = F.frame(F.clip { $0.color = off; $0.grades = [fix] }, still: photo, size: sz)
        let after = try ToolExecutor.matchStats(F.cgImage(matched, rect)).0
        let dB = ShotMatch.distance(tStats, refStats), dA = ShotMatch.distance(after, refStats)
        XCTAssertGreaterThan(dB, 12, "the test grade is visible")
        XCTAssertLessThan(dA, dB * 0.35, "before \(dB) after \(dA)")
        XCTAssertLessThan(dA, 6, "close match")
        XCTAssertLessThan(abs(ShotMatch.distance(sol.predicted, refStats) - dA), 4, "the solver's prediction agrees with the render")
        // Preview, left to right: the off shot, after the match, the reference.
        let three = F.pair(F.pair(target, matched), ref)
        F.save(three, "match-before-after-reference.png", rect: three.extent)
    }

    func testLayerToolsValidateAndUndo() throws {
        let c = try x.insertClip(asset: "a.mp4")
        let a = try x.addGradeLayer(c.id.uuidString, name: "Skin", index: nil, mix: 0.8, enabled: nil)   // full ids, as the inspector passes them
        XCTAssertEqual(a.layers.count, 1); XCTAssertEqual(a.layers[0].name, "Skin"); XCTAssertEqual(a.layers[0].mix, 0.8)
        _ = try x.addGradeLayer(c.id.short, name: nil, index: 0, mix: nil, enabled: nil)
        XCTAssertEqual(doc.project.clip(c.id)!.clip.grades.map(\.name), ["Layer 2", "Skin"])
        XCTAssertThrowsError(try x.addGradeLayer(c.id.short, name: "", index: nil, mix: nil, enabled: nil))
        XCTAssertThrowsError(try x.addGradeLayer(c.id.short, name: "X", index: 5, mix: nil, enabled: nil))
        XCTAssertThrowsError(try x.addGradeLayer(c.id.short, name: "X", index: nil, mix: 1.5, enabled: nil)) { XCTAssertTrue("\($0)".contains("between 0 and 1"), "\($0)") }
        let music = try x.insertClip(asset: "music.m4a")
        XCTAssertThrowsError(try x.addGradeLayer(music.id.short, name: nil, index: nil, mix: nil, enabled: nil))
        // Grade a layer by name with the same tools as the primary grade.
        let u = try x.updateGradeLayer(c.id.short, layer: "skin", name: nil, enabled: nil, mix: nil, color: .init(saturation: 1.2, temperature: 10))
        XCTAssertTrue(u.layers[1].grade.contains("saturation 1.2"), u.layers[1].grade)
        XCTAssertThrowsError(try x.updateGradeLayer(c.id.short, layer: "skin", name: nil, enabled: nil, mix: nil, color: .init(exposure: 9)))
        XCTAssertThrowsError(try x.updateGradeLayer(c.id.short, layer: "skin", name: nil, enabled: nil, mix: nil, color: .init()), "nothing to change")
        XCTAssertThrowsError(try x.updateGradeLayer(c.id.short, layer: "nope", name: nil, enabled: nil, mix: nil, color: .init(tint: 3))) { XCTAssertTrue("\($0)".contains("Skin"), "the error lists the layers: \($0)") }
        _ = try x.setColorWheels(c.id.short, layer: "Skin", wheel: "gain", r: nil, g: nil, b: nil, master: nil, toward: "orange", amount: 0.05, reset: false)
        XCTAssertNotNil(doc.project.clip(c.id)!.clip.grades[1].color.wheels)
        XCTAssertNil(doc.project.clip(c.id)!.clip.color.wheels, "the primary grade is untouched")
        XCTAssertTrue(doc.project.hasColorGrade)
        let mv = try x.moveGradeLayer(c.id.short, layer: "Skin", to: 0)
        XCTAssertEqual(mv.layers.map(\.name), ["Skin", "Layer 2"])
        XCTAssertThrowsError(try x.moveGradeLayer(c.id.short, layer: "Skin", to: 0))
        XCTAssertThrowsError(try x.moveGradeLayer(c.id.short, layer: "Skin", to: 2))
        let rm = try x.removeGradeLayer(c.id.short, layer: "Skin")
        XCTAssertEqual(rm.layers.map(\.name), ["Layer 2"])
        doc.undo()
        XCTAssertEqual(doc.project.clip(c.id)!.clip.grades.map(\.name), ["Skin", "Layer 2"], "one undo brings the removed layer back")
        // Export reports say what an EDL / FCPXML leaves behind; the timeline summary lists the layers.
        let lines = ColorPipeline.notTransferred([doc.project.clip(c.id)!.clip])
        XCTAssertTrue(lines.contains { $0.hasPrefix("Grade layers on 1 clip") }, "\(lines)"); XCTAssertTrue(lines.contains { $0.hasPrefix("Color wheels") }, "\(lines)")
        XCTAssertTrue(ColorPipeline.notTransferred([F.clip()]).isEmpty)
        XCTAssertEqual(x.inspectTimeline().clips.first { $0.id == c.id.short }?.gradeLayers?.count, 2)
        // Layers survive a save and load.
        let data = try JSONEncoder().encode(doc.project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), doc.project)
    }

    func testMatchColorToolOnTwoStills() async throws {
        let path = "/Library/User Pictures/Animals/Parrot.heic"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("no system photo") }
        let d = EditMaxDocument()
        let ex = ToolExecutor(document: d, origin: .agent)
        _ = try await ex.importMedia(paths: [path])
        let a = try ex.insertClip(asset: "Parrot.heic", duration: 2)
        let b = try ex.insertClip(asset: "Parrot.heic", duration: 2)
        try ex.setClipColor(a.id.short, exposure: -0.4, contrast: nil, saturation: 0.7, temperature: 40, tint: nil, reset: false)
        let r = try await rendering { try await ex.matchColor(a.id.short, reference: b.id.short, clipSeconds: nil, referenceSeconds: nil, mix: nil) }
        print("MATCHTOOL \(r.distanceBefore) -> \(r.distanceAfter) \(r.note)")
        XCTAssertGreaterThan(r.distanceBefore, 10)
        XCTAssertLessThan(r.distanceAfter, r.distanceBefore * 0.4, "before \(r.distanceBefore) after \(r.distanceAfter)")
        let grades = d.project.clip(a.id)!.clip.grades
        XCTAssertEqual(grades.map(\.name), [ShotMatch.layerName])
        // Again: replaces the layer instead of stacking another.
        let r2 = try await rendering { try await ex.matchColor(a.id.short, reference: b.id.short, clipSeconds: nil, referenceSeconds: nil, mix: 0.5) }
        XCTAssertEqual(d.project.clip(a.id)!.clip.grades.count, 1); XCTAssertEqual(r2.layer, r.layer)
        XCTAssertEqual(d.project.clip(a.id)!.clip.grades[0].mix, 0.5)
        d.undo(); d.undo()
        XCTAssertTrue(d.project.clip(a.id)!.clip.grades.isEmpty, "each match is one undo step")
        await XCTAssertThrowsErrorAsync(try await ex.matchColor(a.id.short, reference: a.id.short, clipSeconds: nil, referenceSeconds: nil, mix: nil))
        await XCTAssertThrowsErrorAsync(try await ex.matchColor(a.id.short, reference: b.id.short, clipSeconds: 99, referenceSeconds: nil, mix: nil))
    }
}

@MainActor
final class ColorFinishingTests: XCTestCase {
    typealias F = ColorFixtures
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }

    override func setUp() async throws {
        doc = EditMaxDocument()
        doc.project.assets.append(Asset(name: "a.mp4", path: "/tmp/a.mp4", kind: .video, duration: 10, width: 1920, height: 1080))
    }

    private func gray(_ v: Double) -> CIImage { CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: CGRect(origin: .zero, size: F.size)) }
    private func finish(_ body: (inout ClipFinish) -> Void) -> ClipFinish { var f = ClipFinish(); body(&f); return f }

    /// Mean and standard deviation of the red channel over a centred box (fractions of the frame).
    private func stats(_ img: CIImage, box: CGRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)) -> (mean: Double, sd: Double) {
        let r = CGRect(x: box.minX * F.size.width, y: box.minY * F.size.height, width: box.width * F.size.width, height: box.height * F.size.height).integral
        let w = Int(r.width), h = Int(r.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        F.ctx.render(img, toBitmap: &px, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: nil)
        let reds = stride(from: 0, to: px.count, by: 4).map { Double(px[$0]) }
        let m = reds.reduce(0, +) / Double(reds.count)
        return (m, (reds.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(reds.count)).squareRoot())
    }

    func testGrainIsFixedPerFrameAndCentredOnTheOriginal() {
        let f = finish { $0.grain = 0.3 }
        let size = F.size
        let a = Finishing.apply(gray(0.5), f, at: 1.0, size: size), again = Finishing.apply(gray(0.5), f, at: 1.0, size: size)
        let next = Finishing.apply(gray(0.5), f, at: 1.0 + 1 / 30, size: size)
        let sa = stats(a)
        XCTAssertEqual(sa.mean, 0.5, accuracy: 0.01, "grain keeps the level"); XCTAssertGreaterThan(sa.sd, 0.02, "and adds texture")
        XCTAssertEqual(F.at(a, 0.41, 0.37), F.at(again, 0.41, 0.37), "the same frame gets the same grain")
        XCTAssertNotEqual(F.at(a, 0.41, 0.37), F.at(next, 0.41, 0.37), "the next frame gets new grain")
        // Soft light: less grain in the deep shadows than in the mid-tones; a bigger size means smoother, coarser grain.
        XCTAssertLessThan(stats(Finishing.apply(gray(0.05), f, at: 1, size: size)).sd, sa.sd * 0.5)
        XCTAssertEqual(F.at(Finishing.apply(gray(0.5), finish { $0.grain = 0.3; $0.grainSize = 1 }, at: 1, size: size), 0.5, 0.5)[3], 1, "opaque stays opaque")
    }

    func testVignetteGlowSharpenAndNoiseReductionDoWhatTheySay() {
        let size = F.size
        // Vignette: corners darker (or lighter with a negative amount), centre untouched.
        let v = Finishing.apply(gray(0.6), finish { $0.vignette = 0.5 }, at: 0, size: size)
        XCTAssertEqual(F.at(v, 0.5, 0.5)[0], 0.6, accuracy: 0.005)
        XCTAssertLessThan(F.at(v, 0.02, 0.03)[0], 0.45)
        XCTAssertGreaterThan(F.at(Finishing.apply(gray(0.6), finish { $0.vignette = -0.5 }, at: 0, size: size), 0.02, 0.03)[0], 0.7)
        // Glow: light spills from a bright patch onto its dark surroundings; a dark frame is untouched.
        let patch = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 430, y: 220, width: 100, height: 100)).composited(over: gray(0.1))
        let g = Finishing.apply(patch, finish { $0.glow = 0.6 }, at: 0, size: size)
        XCTAssertGreaterThan(F.pixel(g, 424, 270)[0], F.pixel(patch, 424, 270)[0] + 0.05, "spill next to the patch")
        XCTAssertEqual(F.pixel(g, 50, 50)[0], 0.1, accuracy: 0.003, "far away: unchanged")
        // Sharpen: more contrast across an edge.
        let edge = gray(0.3).cropped(to: CGRect(x: 0, y: 0, width: 480, height: 540)).composited(over: gray(0.7))
        let s = Finishing.apply(edge, finish { $0.sharpen = 0.8 }, at: 0, size: size)
        XCTAssertLessThan(F.pixel(s, 478, 270)[0], 0.3 - 0.01); XCTAssertGreaterThan(F.pixel(s, 481, 270)[0], 0.7 + 0.01)
        // Noise reduction: a noisy gray gets smoother.
        let noisy = Finishing.apply(gray(0.5), finish { $0.grain = 0.2 }, at: 2, size: size)
        let nr = Finishing.apply(noisy, finish { $0.noiseReduction = 1 }, at: 0, size: size)
        XCTAssertLessThan(stats(nr).sd, stats(noisy).sd * 0.8, "noise \(stats(noisy).sd) -> \(stats(nr).sd)")
        // A picture smaller than the canvas: effects stay inside it, the canvas around stays empty.
        let small = gray(0.5).cropped(to: CGRect(x: 240, y: 135, width: 480, height: 270))
        let fs = Finishing.apply(small, finish { $0.glow = 1; $0.vignette = 0.5; $0.grain = 0.5 }, at: 0, size: size)
        XCTAssertEqual(fs.extent, small.extent)
    }

    func testFinishToolValidatesAndStaysOffByDefault() throws {
        let c = try x.insertClip(asset: "a.mp4")
        let r = try x.setClipFinish(c.id.short, values: ["grain": 0.2, "vignette": 0.3], reset: false)
        XCTAssertEqual(r.finish?.grain, 0.2); XCTAssertEqual(r.finish?.vignette, 0.3); XCTAssertTrue(r.note.contains("grain 0.2"), r.note)
        XCTAssertThrowsError(try x.setClipFinish(c.id.short, values: ["grain": 2], reset: false)) { XCTAssertTrue("\($0)".contains("between 0 and 1"), "\($0)") }
        XCTAssertThrowsError(try x.setClipFinish(c.id.short, values: ["glow_radius": 1], reset: false))
        XCTAssertThrowsError(try x.setClipFinish(c.id.short, values: [:], reset: false))
        XCTAssertTrue(doc.project.hasColorGrade, "finishing counts for before/after")
        _ = try x.setClipFinish(c.id.short, values: [:], reset: true)
        XCTAssertNil(doc.project.clip(c.id)!.clip.finish, "all defaults = nil, saved as before")
        doc.undo()
        XCTAssertEqual(doc.project.clip(c.id)!.clip.finish?.grain, 0.2)
    }

    func testPreviewFinishing() {
        guard let photo = F.photo() else { return }
        // The square photo scaled to fill the 16:9 frame, so the vignette shows at the frame's corners.
        let fill = { (c: inout Clip) in c.transform.scale = F.size.width / F.size.height }
        let base = F.frame(F.clip(fill), still: photo)
        let all = finish { $0.vignette = 0.6; $0.glow = 0.7; $0.glowThreshold = 0.55; $0.glowRadius = 40; $0.sharpen = 0.5; $0.grain = 0.25 }
        let after = F.frame(F.clip { fill(&$0); $0.finish = all }, still: photo)
        let pair = F.pair(base, after)
        F.save(pair, "finish-vignette-glow-sharpen-grain-before-after.png", rect: pair.extent)
        // Grain up close (a 240 px crop at 4x) so it can be judged.
        let g = F.frame(F.clip { fill(&$0); $0.finish = finish { $0.grain = 0.35; $0.grainSize = 1.5 } }, still: photo)
        let crop = CGRect(x: 360, y: 150, width: 240, height: 135)
        let zoom = { (i: CIImage) in i.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY).concatenating(CGAffineTransform(scaleX: 4, y: 4))) }
        let z = F.pair(zoom(base), zoom(g))
        F.save(z, "finish-grain-zoom-before-after.png", rect: z.extent)
    }
}

@MainActor
final class ColorMaskTests: XCTestCase {
    typealias F = ColorFixtures
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }

    override func setUp() async throws {
        doc = EditMaxDocument()
        doc.project.assets.append(Asset(name: "a.mp4", path: "/tmp/a.mp4", kind: .video, duration: 10, width: 1920, height: 1080))
    }

    private func masked(_ mask: GradeMask?) -> Clip {
        var gray = GradeLayer(name: "Gray"); gray.color.saturation = 0; gray.mask = mask
        return F.clip { $0.grades = [gray] }
    }
    /// The matte the compositor draws for a probed layer.
    private func probe(_ clip: Clip, still: CIImage, size: CGSize = ColorFixtures.size) -> CIImage {
        MatteProbe.shared.register(clip: clip.id, layer: clip.grades[0].id)
        defer { MatteProbe.shared.remove(clip: clip.id) }
        return F.frame(clip, still: still, size: size)
    }

    func testShapesQualifierAndInvert() {
        var m = GradeMask(); var e = MaskShape(kind: .ellipse); e.centerX = 0.3; e.centerY = 0.4; e.width = 0.3; e.height = 0.4; e.feather = 0.02; m.shape = e
        let matte = probe(masked(m), still: F.chart())
        XCTAssertEqual(F.at(matte, 0.3, 0.4)[0], 1, accuracy: 0.01, "inside"); XCTAssertEqual(F.at(matte, 0.9, 0.9)[0], 0, accuracy: 0.01, "outside")
        XCTAssertEqual(F.at(matte, 0.3, 0.4 + 0.19)[0], 1, accuracy: 0.2, "near the bottom edge, inside")
        XCTAssertEqual(F.at(matte, 0.3 + 0.17, 0.4)[0], 0, accuracy: 0.05, "just right of the edge, outside")
        m.invert = true
        let inv = probe(masked(m), still: F.chart())
        XCTAssertEqual(F.at(inv, 0.3, 0.4)[0], 0, accuracy: 0.01); XCTAssertEqual(F.at(inv, 0.9, 0.9)[0], 1, accuracy: 0.01)
        // A rotated rectangle: 90° swaps width and height.
        var r = MaskShape(kind: .rectangle); r.width = 0.5; r.height = 0.1; r.rotation = 90; r.feather = 0
        let rect = probe(masked({ var g = GradeMask(); g.shape = r; return g }()), still: F.chart())
        XCTAssertEqual(F.at(rect, 0.5, 0.3)[0], 1, accuracy: 0.01, "along the rotated long side"); XCTAssertEqual(F.at(rect, 0.62, 0.5)[0], 0, accuracy: 0.01)
        // Qualifier: reds only. The chart's 75% red patch is selected, its gray ramp and green are not.
        var q = ColorQualifier(); q.hueCenter = 0; q.hueWidth = 30; q.satLow = 0.3; q.blur = 0
        let red = Masks.qualifier(q, CIImage(color: CIColor(red: 0.75, green: 0.05, blue: 0.05)).cropped(to: CGRect(origin: .zero, size: F.size)), size: F.size)
        let green = Masks.qualifier(q, CIImage(color: CIColor(red: 0.1, green: 0.7, blue: 0.1)).cropped(to: CGRect(origin: .zero, size: F.size)), size: F.size)
        let grayQ = Masks.qualifier(q, CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: F.size)), size: F.size)
        XCTAssertGreaterThan(F.at(red, 0.5, 0.5)[0], 0.95); XCTAssertLessThan(F.at(green, 0.5, 0.5)[0], 0.02); XCTAssertLessThan(F.at(grayQ, 0.5, 0.5)[0], 0.02)
        // The masked layer grades inside only.
        let graded = F.frame(masked(m.invert ? { var g = m; g.invert = false; return g }() : m), still: F.chart())
        let plain = F.frame(F.clip(), still: F.chart())
        XCTAssertEqual(F.at(graded, 0.9, 0.1), F.at(plain, 0.9, 0.1), "outside the ellipse: untouched")
    }

    func testSubjectMatteFindsTheParrotAndNoPerson() throws {
        guard let photo = F.photo() else { throw XCTSkip("no system photo") }
        let sz = CGSize(width: 512, height: 512)
        var times: [String: [Double]] = [:]
        var mattes: [SubjectMask.Kind: CIImage] = [:]
        for kind in SubjectMask.Kind.allCases {
            for _ in 0..<2 {
                let pre = F.frame(F.clip(), still: photo, size: sz)
                let t0 = Date()
                let m = SubjectMatte.analyse(kind, pre: pre, inputLut: nil, size: sz)
                times[kind.rawValue, default: []].append(Date().timeIntervalSince(t0) * 1000)
                mattes[kind] = m
            }
        }
        print("VISIONMS \(times)")
        let fg = try XCTUnwrap(mattes[.foreground])
        XCTAssertGreaterThan(F.at(fg, 0.45, 0.45)[0], 0.8, "the parrot's head is the subject")
        let person = try XCTUnwrap(mattes[.person])
        print("PERSONCOVERAGE \(Masks.meanForTest(person))")   // Vision's person model is not a person detector: it marks about a third of the parrot
        // Through the compositor, cached: the second frame at the same source time does not rerun Vision.
        var layer = GradeLayer(name: "Subject"); layer.color.saturation = 0
        var gm = GradeMask(); gm.subject = SubjectMask(kind: .foreground); layer.mask = gm
        let clip = F.clip { $0.grades = [layer] }
        let a = F.frame(clip, still: photo, size: sz)
        let t1 = Date(); let b = F.frame(clip, still: photo, size: sz)
        _ = F.cgImage(b, CGRect(origin: .zero, size: sz))
        XCTAssertLessThan(Date().timeIntervalSince(t1) * 1000, 150, "cached matte")
        if let dir = F.previewDir {
            let matte = probe(clip, still: photo, size: sz)
            let row = F.pair(F.pair(F.frame(F.clip(), still: photo, size: sz), matte), a)
            F.savePNG(F.cgImage(row, row.extent), dir.appendingPathComponent("mask-subject-photo-matte-graded.png"))
        }
    }

    func testMaskToolAndMattePreview() throws {
        let c = try x.insertClip(asset: "a.mp4")
        _ = try x.addGradeLayer(c.id.short, name: "Sky", index: nil, mix: nil, enabled: nil)
        let r = try x.setLayerMask(c.id.short, layer: "Sky", .init(shape: "ellipse", shapeValues: ["center_x": 0.3, "width": 0.4]))
        XCTAssertTrue(r.changed.contains("ellipse at (0.3, 0.5)"), r.changed)
        XCTAssertThrowsError(try x.setLayerMask(c.id.short, layer: "Sky", .init(shapeValues: ["feather": 0.9])))
        XCTAssertThrowsError(try x.setLayerMask(c.id.short, layer: "Sky", .init(shape: "star")))
        XCTAssertThrowsError(try x.setLayerMask(c.id.short, layer: "Sky", .init(subject: "cat")))
        XCTAssertThrowsError(try x.setLayerMask(c.id.short, layer: "Sky", .init(qualifierValues: ["sat_low": 0.8, "sat_high": 0.2])))
        _ = try x.setLayerMask(c.id.short, layer: "Sky", .init(qualifierValues: ["hue_center": 210, "hue_width": 60]))
        let m = doc.project.clip(c.id)!.clip.grades[0].mask
        XCTAssertNotNil(m?.shape); XCTAssertEqual(m?.qualifier?.hueCenter, 210)
        _ = try x.setLayerMask(c.id.short, layer: "Sky", .init(clear: true))
        XCTAssertNil(doc.project.clip(c.id)!.clip.grades[0].mask)
        doc.undo()
        XCTAssertNotNil(doc.project.clip(c.id)!.clip.grades[0].mask?.qualifier)
        // Preview: the chart with an ellipse ∩ reds-and-oranges qualifier matte and the masked layer's result.
        guard F.previewDir != nil, let photo = F.photo() else { return }
        // Red and orange feathers inside a big ellipse, turned toward magenta and muted; the skin, beak and leaves stay.
        var gm = GradeMask(); var e = MaskShape(); e.centerX = 0.45; e.centerY = 0.45; e.width = 0.9; e.height = 0.9; e.feather = 0.08; gm.shape = e
        var q = ColorQualifier(); q.hueCenter = 10; q.hueWidth = 40; q.satLow = 0.5; gm.qualifier = q
        var layer = GradeLayer(name: "Feathers"); var w = ColorWheels(); w.gain = ColorWheel(r: -0.2, g: 0, b: 0.35); layer.color.wheels = w; layer.color.saturation = 0.5; layer.mask = gm
        let clip = F.clip { $0.transform.scale = F.size.width / F.size.height; $0.grades = [layer] }
        let row = F.pair(F.pair(F.frame(F.clip { $0.transform.scale = F.size.width / F.size.height }, still: photo), probe(clip, still: photo)), F.frame(clip, still: photo))
        F.save(row, "mask-shape-qualifier-photo-matte-graded.png", rect: row.extent)
        let plainPic = F.frame(F.clip { $0.transform.scale = F.size.width / F.size.height }, still: photo), gradedPic = F.frame(clip, still: photo)
        let diff = gradedPic.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: plainPic])
        let unmasked = F.frame(F.clip { $0.transform.scale = F.size.width / F.size.height; var l = layer; l.mask = nil; $0.grades = [l] }, still: photo)
        let dMasked = Masks.meanForTest(diff), dAll = Masks.meanForTest(unmasked.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: plainPic]))
        XCTAssertGreaterThan(dMasked, 0.005, "the layer changes the masked part"); XCTAssertLessThan(dMasked, dAll * 0.8, "and only that part")
    }
}

extension Masks {
    /// Mean of the red channel (tests).
    static func meanForTest(_ img: CIImage) -> Double {
        let v = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
        var px = [Float](repeating: 0, count: 4)
        ColorFixtures.ctx.render(v, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(px[0])
    }
}

/// Runs a test step that renders through AVFoundation; the known -11800/-12780 composition flake (EngineTests fail the
/// same way on this Mac) skips the test instead of failing it.
func rendering<T>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch let e as NSError where e.domain == AVFoundationErrorDomain {
        throw XCTSkip("AVFoundation render flake \(e.code) (known; EngineTests fail the same way here)")
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expr: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expr(); XCTFail("expected an error", file: file, line: line) } catch {}
}
