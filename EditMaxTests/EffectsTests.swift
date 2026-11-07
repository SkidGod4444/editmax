import XCTest
import AVFoundation
import CoreImage
import AppKit
import SwiftUI
import Vision
import VideoToolbox   // kVTProfileLevel_*: newer SDKs re-export it through AVFoundation, Xcode 26.6 does not
@testable import EditMax

/// Green-screen key, blend modes, face / region blur, animated titles and lower thirds, the newer transitions and HDR
/// output. Rendering tests draw through `FrameRenderer` on CIImages (no AVFoundation composition) where they can; the
/// export tests write small generated clips. With `EDITMAX_PREVIEW_DIR` set (TEST_RUNNER_EDITMAX_PREVIEW_DIR for
/// xcodebuild), every look is also written there as a PNG contact sheet to check by eye.
/// No real faces anywhere: the face content is drawn cartoons and the face boxes are injected.
@MainActor
final class EffectsTests: XCTestCase {
    static let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    static let W: CGFloat = 960, H: CGFloat = 540
    private var size: CGSize { CGSize(width: Self.W, height: Self.H) }
    private var frameRect: CGRect { CGRect(origin: .zero, size: size) }
    private var previewDir: URL? {
        guard let p = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_DIR"], !p.isEmpty else { return nil }
        let u = URL(fileURLWithPath: p); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    private var workDir: URL {
        let u = previewDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("EditMaxEffectsTests")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }

    // MARK: Drawing helpers

    private func draw(_ size: CGSize, _ body: (CGContext) -> Void) -> CIImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return CIImage(cgImage: ctx.makeImage()!, options: [.colorSpace: NSNull()])
    }
    private func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a) }
    private func label(_ s: String, at p: CGPoint, size: CGFloat = 13, color: NSColor = .white, weight: NSFont.Weight = .semibold) {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: p)
    }

    private func cg(_ img: CIImage, _ rect: CGRect? = nil) -> CGImage {
        Self.ctx.createCGImage(img, from: rect ?? frameRect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }
    /// One pixel (Core Image coordinates, y up), unpremultiplied 0-1.
    private func px(_ img: CIImage, _ x: CGFloat, _ y: CGFloat) -> (r: Double, g: Double, b: Double, a: Double) {
        var v = [Float](repeating: 0, count: 4)
        Self.ctx.render(img, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let a = Double(v[3])
        guard a > 1e-5 else { return (0, 0, 0, 0) }
        return (Double(v[0]) / a, Double(v[1]) / a, Double(v[2]) / a, a)
    }
    /// Premultiplied pixel (what a composite shows over black).
    private func pm(_ img: CIImage, _ x: CGFloat, _ y: CGFloat) -> (r: Double, g: Double, b: Double) {
        var v = [Float](repeating: 0, count: 4)
        Self.ctx.render(img, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return (Double(v[0]), Double(v[1]), Double(v[2]))
    }
    private func maxDiff(_ a: CIImage, _ b: CIImage, _ rect: CGRect) -> Double {
        let d = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: rect)
            .applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var v = [Float](repeating: 0, count: 4)
        Self.ctx.render(d, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(max(v[0], v[1], v[2]))
    }

    private func save(_ image: CGImage, _ name: String) {
        guard let dir = previewDir, let d = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? d.write(to: dir.appendingPathComponent(name))
    }

    /// A grid of tiles: one labelled row per entry, optional column titles.
    private func sheet(_ rows: [(String, [CIImage])], tile: CGSize, columns: [String] = [], source: CGRect? = nil, labelWidth: CGFloat = 150, checker: Bool = false) -> CGImage {
        let gap: CGFloat = 8, head: CGFloat = columns.isEmpty ? gap : 26
        let cols = rows.map(\.1.count).max() ?? 1
        let w = labelWidth + CGFloat(cols) * (tile.width + gap) + gap, h = head + CGFloat(rows.count) * (tile.height + gap)
        let out = draw(CGSize(width: w, height: h)) { c in
            c.setFillColor(rgb(0x1C1C1E)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for (i, t) in columns.enumerated() { label(t, at: CGPoint(x: labelWidth + CGFloat(i) * (tile.width + gap) + 4, y: h - 20), color: .lightGray) }
            for (ri, row) in rows.enumerated() {
                let y = h - head - CGFloat(ri + 1) * (tile.height + gap) + gap
                label(row.0, at: CGPoint(x: 8, y: y + tile.height / 2 - 8))
                for (ci, img) in row.1.enumerated() {
                    let r = CGRect(x: labelWidth + CGFloat(ci) * (tile.width + gap), y: y, width: tile.width, height: tile.height)
                    if checker {
                        let s: CGFloat = 12
                        for yy in stride(from: 0, to: tile.height, by: s) { for xx in stride(from: 0, to: tile.width, by: s) {
                            c.setFillColor(((Int(xx / s) + Int(yy / s)) % 2 == 0) ? rgb(0x9A9A9A) : rgb(0x6A6A6A))
                            c.fill(CGRect(x: r.minX + xx, y: r.minY + yy, width: min(s, tile.width - xx), height: min(s, tile.height - yy)))
                        } }
                    }
                    c.interpolationQuality = .high
                    c.draw(cg(img, source ?? frameRect), in: r)
                }
            }
        }
        return cg(out, out.extent)
    }

    // MARK: Compositor helpers

    private func source(_ img: CIImage, _ clip: Clip, transitionEnd: Double? = nil, outgoing: UUID? = nil) -> LayerSource {
        LayerSource(trackID: kCMPersistentTrackID_Invalid, still: img, naturalSize: img.extent.size, preferredTransform: .identity, clip: clip, effectiveEnd: clip.end, transitionEnd: transitionEnd, outgoingID: outgoing)
    }
    private func clip(_ name: String, start: Double = 0, duration: Double = 4) -> Clip { Clip(assetID: UUID(), name: name, start: start, duration: duration) }
    /// The compositor's frame for these layers (top row first) and texts.
    private func frame(_ layers: [TrackLayer], texts: [TextLayer] = [], at t: Double) -> CIImage {
        let inst = EditMaxInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)), layers: layers, texts: texts, renderSize: size, requiredTrackIDs: [])
        return FrameRenderer.frame(inst, at: t) { _ in nil }
    }

    // MARK: Synthetic pictures

    /// A green-screen frame: lit screen with a floor shadow, a person shape (hair, face, shirt) with a green fringe of
    /// spill on the hair, and a yellow mug (a colour next to green that must stay).
    private func greenScreen() -> CIImage {
        draw(size) { c in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let grad = CGGradient(colorsSpace: space, colors: [rgb(0x19B84E), rgb(0x0E9A40)] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(grad, start: CGPoint(x: 0, y: Self.H), end: CGPoint(x: 0, y: 0), options: [])
            for i in 0..<6 { c.setFillColor(rgb(0x2BC860, 0.18)); c.fill(CGRect(x: 60 + CGFloat(i) * 150, y: 0, width: 26, height: Self.H)) }   // fabric folds
            c.setFillColor(rgb(0x0A6E2E, 0.85)); c.fillEllipse(in: CGRect(x: 300, y: 10, width: 380, height: 60))                             // floor shadow
            c.setFillColor(rgb(0x2A3F66)); c.addPath(CGPath(roundedRect: CGRect(x: 360, y: 30, width: 240, height: 230), cornerWidth: 60, cornerHeight: 60, transform: nil)); c.fillPath()
            c.setFillColor(rgb(0xD9D9D9)); c.fill(CGRect(x: 455, y: 200, width: 50, height: 60))                                                    // collar
            c.setFillColor(rgb(0xE0AC85)); c.fillEllipse(in: CGRect(x: 410, y: 250, width: 140, height: 170))                                       // face
            c.setFillColor(rgb(0x3E2A1C)); c.fillEllipse(in: CGRect(x: 400, y: 340, width: 160, height: 100))                                       // hair
            c.setStrokeColor(rgb(0x5FAE58, 0.75)); c.setLineWidth(7); c.strokeEllipse(in: CGRect(x: 398, y: 338, width: 164, height: 104))         // green spill on hair edge
            c.setFillColor(rgb(0x1A1A1A)); c.fillEllipse(in: CGRect(x: 445, y: 320, width: 14, height: 10)); c.fillEllipse(in: CGRect(x: 500, y: 320, width: 14, height: 10))
            c.setFillColor(rgb(0xE6C640)); c.fill(CGRect(x: 700, y: 60, width: 70, height: 90))                                                     // yellow mug
            c.setFillColor(rgb(0x3FA9D6)); c.fill(CGRect(x: 200, y: 60, width: 70, height: 90))                                                     // cyan box
        }
    }
    /// A background plate: dusk sky over a skyline.
    private func plate() -> CIImage {
        draw(size) { c in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let grad = CGGradient(colorsSpace: space, colors: [rgb(0x203A6B), rgb(0xE38B4F)] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(grad, start: CGPoint(x: 0, y: Self.H), end: CGPoint(x: 0, y: 0), options: [])
            var x: CGFloat = 0, i = 0
            while x < Self.W { let w = CGFloat(50 + (i * 37) % 70), h = CGFloat(80 + (i * 53) % 180); c.setFillColor(rgb(0x1B1F2A)); c.fill(CGRect(x: x, y: 0, width: w, height: h)); x += w + 6; i += 1 }
        }
    }
    private func letterCard(_ s: String, _ bg: UInt32, _ fg: UInt32) -> CIImage {
        draw(size) { c in
            c.setFillColor(rgb(bg)); c.fill(CGRect(origin: .zero, size: size))
            c.setStrokeColor(rgb(fg, 0.35)); c.setLineWidth(2)
            for x in stride(from: CGFloat(0), through: Self.W, by: 80) { c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: Self.H)) }
            for y in stride(from: CGFloat(0), through: Self.H, by: 80) { c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: Self.W, y: y)) }
            c.strokePath()
            NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 300, weight: .heavy), .foregroundColor: NSColor(cgColor: rgb(fg))!]).draw(at: CGPoint(x: Self.W / 2 - 100, y: 90))
        }
    }
    /// Three cartoon faces (drawn shapes, no photographs) in a room.
    private func cartoonFaces() -> CIImage {
        draw(size) { c in
            c.setFillColor(rgb(0xC9B79C)); c.fill(CGRect(origin: .zero, size: size))
            c.setFillColor(rgb(0x8C6E54)); c.fill(CGRect(x: 0, y: 0, width: Self.W, height: 150))
            for (i, cx) in [200.0, 480.0, 760.0].enumerated() {
                let skin = [0xF1C27D, 0xC68642, 0xE0AC69][i]
                c.setFillColor(rgb(UInt32([0x335C81, 0x7A3E48, 0x3F6B3F][i]))); c.fill(CGRect(x: cx - 110, y: 0, width: 220, height: 170))
                c.setFillColor(rgb(UInt32(skin))); c.fillEllipse(in: CGRect(x: cx - 75, y: 170, width: 150, height: 190))
                c.setFillColor(rgb(0x2B1B10)); c.fillEllipse(in: CGRect(x: cx - 80, y: 300, width: 160, height: 80))
                c.setFillColor(.white); c.fillEllipse(in: CGRect(x: cx - 45, y: 270, width: 32, height: 20)); c.fillEllipse(in: CGRect(x: cx + 13, y: 270, width: 32, height: 20))
                c.setFillColor(rgb(0x1E1E1E)); c.fillEllipse(in: CGRect(x: cx - 36, y: 273, width: 14, height: 14)); c.fillEllipse(in: CGRect(x: cx + 22, y: 273, width: 14, height: 14))
                c.setStrokeColor(rgb(0x2B1B10)); c.setLineWidth(5)
                c.move(to: CGPoint(x: cx - 48, y: 302)); c.addLine(to: CGPoint(x: cx - 12, y: 306)); c.move(to: CGPoint(x: cx + 12, y: 306)); c.addLine(to: CGPoint(x: cx + 48, y: 302)); c.strokePath()
                c.setFillColor(rgb(0x9E3B3B)); c.fillEllipse(in: CGRect(x: cx - 28, y: 205, width: 56, height: 18))
                c.setFillColor(rgb(UInt32(skin) &- 0x101010)); c.fillEllipse(in: CGRect(x: cx - 9, y: 235, width: 18, height: 26))
            }
        }
    }
    /// Face boxes (normalized, top-left, y down) for `cartoonFaces`, from Vision-like brows-to-chin rectangles.
    private func cartoonBoxes(t: Double, shift: Double = 0) -> [BlurBox] {
        [200.0, 480.0, 760.0].enumerated().map { i, cx in
            let dx = i == 1 ? shift : 0
            return BlurBox(t: t, x: (cx - 70) / Self.W + dx, y: 1 - 330 / Self.H, w: 140 / Self.W, h: 150 / Self.H)
        }
    }

    // MARK: - 1. Green-screen key

    func testChromaKeyMatteAndComposite() throws {
        let src = greenScreen()
        let det = try XCTUnwrap(Keyer.detect(cg(src)))
        let (dr, dg, db) = try XCTUnwrap(Keyer.rgb(det.hex))
        XCTAssertGreaterThan(dg, dr + 0.3, "auto-detect picks the green screen, got \(det.hex)"); XCTAssertGreaterThan(dg, db + 0.3)
        XCTAssertGreaterThan(det.confidence, 0.6)

        var key = ChromaKey(); key.colorHex = det.hex
        let keyed = Keyer.apply(src, key)
        XCTAssertLessThan(px(keyed, 20, 500).a, 0.02, "screen corner keyed")
        XCTAssertLessThan(px(keyed, 330, 40).a, 0.15, "floor shadow keyed (the darker screen counts as screen)")
        XCTAssertGreaterThan(px(keyed, 480, 300).a, 0.98, "face kept")
        XCTAssertGreaterThan(px(keyed, 480, 120).a, 0.98, "shirt kept")
        XCTAssertGreaterThan(px(keyed, 735, 100).a, 0.95, "yellow mug kept")
        XCTAssertGreaterThan(px(keyed, 235, 100).a, 0.95, "cyan box kept")
        // Spill: the green fringe on the hair loses its green cast where it stays.
        let before = px(src, 480, 441), after = px(keyed, 480, 441)
        if after.a > 0.2 { XCTAssertLessThan(after.g - max(after.r, after.b), before.g - max(before.r, before.b) - 0.05, "spill suppressed on the hair edge") }

        // Cleanup: shrinking eats into the subject edge; the matte stays white inside.
        var clean = key; clean.shrink = 4; clean.edgeBlur = 3
        let m0 = Keyer.matte(src, key), m1 = Keyer.matte(src, clean)
        XCTAssertGreaterThan(px(m1, 480, 300).r, 0.98)
        XCTAssertLessThan(px(m1, 362, 150).r, px(m0, 362, 150).r + 0.001, "shrink takes edge pixels away")

        // Through the compositor: keyed clip on the top row over a background on the row below.
        var fg = clip("talent"); fg.effects.chromaKey = key
        let bg = plate()
        let out = frame([TrackLayer(current: source(src, fg), outgoing: nil), TrackLayer(current: source(bg, clip("plate")), outgoing: nil)], at: 1)
        let corner = pm(out, 20, 500), plateCorner = pm(bg, 20, 500)
        XCTAssertEqual(corner.r, plateCorner.r, accuracy: 0.02); XCTAssertEqual(corner.b, plateCorner.b, accuracy: 0.02)
        let face = pm(out, 480, 300), faceSrc = pm(src, 480, 300)
        XCTAssertEqual(face.r, faceSrc.r, accuracy: 0.03)
        let keyedOverChecker = keyed
        let sheetRows: [(String, [CIImage])] = [
            ("Default key", [src, m0, keyedOverChecker, out]),
            ("Shrink 4, blur 3", [src, m1, Keyer.apply(src, clean), frame([TrackLayer(current: source(src, { var c = clip("t"); c.effects.chromaKey = clean; return c }()), outgoing: nil), TrackLayer(current: source(bg, clip("p")), outgoing: nil)], at: 1)]),
        ]
        save(sheet(sheetRows, tile: CGSize(width: 384, height: 216), columns: ["Green-screen frame", "Matte", "Keyed (over checker)", "Composite over plate"], checker: true), "key_before_after.png")
    }

    func testChromaKeyToolValidates() async throws {
        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
        let url = workDir.appendingPathComponent("greenscreen.png")
        try writePNG(cg(greenScreen()), url)
        _ = try await x.importMedia(paths: [url.path])
        let c = try x.insertClip(asset: "greenscreen.png", duration: 2)
        do { _ = try await x.setChromaKey(c.id.short, color: nil, tolerance: 1.4, softness: nil, spill: nil, shrink: nil, edgeBlur: nil, time: nil, remove: false); XCTFail("tolerance 1.4 accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("tolerance"), error.localizedDescription) }
        do { _ = try await x.setChromaKey(c.id.short, color: "#808080", tolerance: nil, softness: nil, spill: nil, shrink: nil, edgeBlur: nil, time: nil, remove: false); XCTFail("grey accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("grey"), error.localizedDescription) }
        do { _ = try await x.setChromaKey(c.id.short, color: nil, tolerance: nil, softness: nil, spill: nil, shrink: nil, edgeBlur: nil, time: nil, remove: true); XCTFail("removed a key that is not there") } catch {}
        XCTAssertNil(doc.project.clip(c.id)?.clip.effects.chromaKey, "refused edits change nothing")

        let r = try await x.setChromaKey(c.id.short, color: "auto", tolerance: 0.5, softness: nil, spill: nil, shrink: nil, edgeBlur: nil, time: 0.5, remove: false)
        XCTAssertNotNil(r.detected); XCTAssertEqual(r.key?.tolerance, 0.5); XCTAssertEqual(r.key?.autoPicked, true)
        XCTAssertGreaterThan(r.matte?.keyedPercent ?? 0, 40); XCTAssertGreaterThan(r.matte?.keptPercent ?? 0, 10)
        XCTAssertNotNil(r.note, "says nothing plays under the clip")
        XCTAssertEqual(doc.project.history.last?.label, "Key greenscreen.png")
        let (m, png) = try await x.keyMatte(c.id.short, time: 0.5, maxWidth: 480)
        XCTAssertEqual(m.width, 480); XCTAssertGreaterThan(png.count, 1000)
        if let dir = previewDir { try png.write(to: dir.appendingPathComponent("key_matte_tool.png")) }
        XCTAssertEqual(x.inspectTimeline().clips.first?.effects?["key"]?.hasPrefix(r.key!.colorHex), true)
        _ = try await x.setChromaKey(c.id.short, color: nil, tolerance: nil, softness: nil, spill: nil, shrink: nil, edgeBlur: nil, time: nil, remove: true)
        XCTAssertNil(doc.project.clip(c.id)?.clip.effects.chromaKey)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 2. Blend modes

    private func blendBase() -> CIImage {
        draw(size) { c in
            for i in 0..<48 {
                let hue = CGFloat(i) / 48
                c.setFillColor(NSColor(hue: hue, saturation: 0.75, brightness: 0.85, alpha: 1).cgColor)
                c.fill(CGRect(x: CGFloat(i) * Self.W / 48, y: 0, width: Self.W / 48 + 1, height: Self.H))
            }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let shade = CGGradient(colorsSpace: space, colors: [rgb(0x000000, 0), rgb(0x000000, 0.7)] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(shade, start: CGPoint(x: 0, y: Self.H), end: CGPoint(x: 0, y: 0), options: [])
        }
    }
    private func blendTop() -> CIImage {
        draw(size) { c in
            for i in 0..<16 { let v = CGFloat(i) / 15; c.setFillColor(CGColor(gray: v, alpha: 1)); c.fill(CGRect(x: CGFloat(i) * Self.W / 16, y: Self.H / 2, width: Self.W / 16 + 1, height: Self.H / 2)) }
            c.setFillColor(rgb(0x808080)); c.fill(CGRect(x: 0, y: 0, width: Self.W, height: Self.H / 2))
            for (i, col) in [0xE53935, 0x43A047, 0x1E88E5, 0xFFFFFF].enumerated() { c.setFillColor(rgb(UInt32(col))); c.fillEllipse(in: CGRect(x: 60 + CGFloat(i) * 230, y: 40, width: 190, height: 190)) }
        }
    }

    func testBlendModesAndOpacity() throws {
        let base = blendBase(), top = blendTop()
        let under = TrackLayer(current: source(base, clip("base")), outgoing: nil)
        func blended(_ m: ClipBlendMode, opacity: Double = 1) -> CIImage {
            var c = clip("top"); c.effects.blend = m; c.opacity = opacity
            return frame([TrackLayer(current: source(top, c), outgoing: nil), under], at: 1)
        }
        // Normal at 100 % is the top picture, as before.
        XCTAssertLessThan(maxDiff(blended(.normal), top, frameRect), 0.003)
        // Formulas at a grey-ramp pixel: x 200 (ramp step 3 = 0.2), y 400.
        let b = pm(base, 200, 400), t = pm(top, 200, 400)
        let mul = pm(blended(.multiply), 200, 400), scr = pm(blended(.screen), 200, 400), add = pm(blended(.add), 200, 400)
        XCTAssertEqual(mul.r, b.r * t.r, accuracy: 0.02); XCTAssertEqual(scr.g, 1 - (1 - b.g) * (1 - t.g), accuracy: 0.02); XCTAssertEqual(add.b, min(1, b.b + t.b), accuracy: 0.02)
        XCTAssertEqual(pm(blended(.darken), 200, 400).r, min(b.r, t.r), accuracy: 0.02)
        XCTAssertEqual(pm(blended(.lighten), 200, 400).r, max(b.r, t.r), accuracy: 0.02)
        XCTAssertEqual(pm(blended(.difference), 200, 400).g, abs(b.g - t.g), accuracy: 0.02)
        // Opacity mixes the blended result with what is below, linearly (a true premultiplied alpha, not the squared one).
        let half = pm(blended(.multiply, opacity: 0.5), 200, 400)
        XCTAssertEqual(half.r, b.r + 0.5 * (mul.r - b.r), accuracy: 0.02)
        XCTAssertLessThan(maxDiff(blended(.screen, opacity: 0), base, frameRect), 0.003, "opacity 0 leaves the rows below")
        // Outside a scaled-down picture the rows below are untouched.
        var small = clip("small"); small.effects.blend = .multiply; small.transform.scale = 0.4
        let shrunk = frame([TrackLayer(current: source(top, small), outgoing: nil), under], at: 1)
        XCTAssertLessThan(maxDiff(shrunk, base, CGRect(x: 0, y: 0, width: 100, height: 100)), 0.003)
        XCTAssertEqual(ClipBlendMode.parse("Soft Light"), .softLight); XCTAssertEqual(ClipBlendMode.parse("linear_dodge"), .add); XCTAssertNil(ClipBlendMode.parse("glow"))

        let tile = CGSize(width: 288, height: 162)
        let modes = ClipBlendMode.allCases
        save(labelledGrid(modes.map { ($0.title, blended($0)) } + [("Base", base), ("Top", top)], tile: tile, title: "Blend modes at 100 % (top: grey ramp and discs; base: hue sweep)"), "blend_modes.png")
        save(labelledGrid(modes.map { ($0.title, blended($0, opacity: 0.5)) }, tile: tile, title: "Blend modes at 50 % opacity"), "blend_modes_50.png")
    }

    /// Tiles with a caption under each, 5 across.
    private func labelledGrid(_ items: [(String, CIImage)], tile: CGSize, title: String) -> CGImage {
        let cols = 5, gap: CGFloat = 8, cap: CGFloat = 20, head: CGFloat = 30
        let rowsN = (items.count + cols - 1) / cols
        let w = CGFloat(cols) * (tile.width + gap) + gap, h = head + CGFloat(rowsN) * (tile.height + cap + gap)
        let out = draw(CGSize(width: w, height: h)) { c in
            c.setFillColor(rgb(0x1C1C1E)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            label(title, at: CGPoint(x: gap, y: h - 22), size: 14)
            for (i, item) in items.enumerated() {
                let col = i % cols, row = i / cols
                let x = gap + CGFloat(col) * (tile.width + gap), y = h - head - CGFloat(row + 1) * (tile.height + cap + gap) + cap
                c.interpolationQuality = .high
                c.draw(cg(item.1), in: CGRect(x: x, y: y, width: tile.width, height: tile.height))
                label(item.0, at: CGPoint(x: x + 2, y: y - 17), size: 12, color: .lightGray, weight: .medium)
            }
        }
        return cg(out, out.extent)
    }

    // MARK: - 3. Face blur

    func testFaceBlurRendersInjectedTracks() throws {
        let src = cartoonFaces()
        // Face 2 moves 10 % right over 2 s (the box interpolates between samples).
        let tracks = (0..<3).map { i in FaceTrack(id: i + 1, boxes: [cartoonBoxes(t: 0)[i], cartoonBoxes(t: 2, shift: i == 1 ? 0.1 : 0)[i]]) }
        func blurred(_ style: FaceBlur.Style, exclude: [Int] = [], expand: Double = 0.25, feather: Double = 0.4, at t: Double = 0) -> CIImage {
            var fb = FaceBlur(); fb.style = style; fb.tracks = tracks; fb.exclude = exclude; fb.expand = expand; fb.feather = feather; fb.pathKey = "test"; fb.faceCount = 3
            return FaceBlurRenderer.apply(src, fb, at: t)
        }
        let b = blurred(.blur, exclude: [2])
        // Excluded face untouched; blurred faces lose their eyes; the wall far from any face untouched.
        XCTAssertLessThan(maxDiff(b, src, CGRect(x: 430, y: 180, width: 100, height: 160)), 0.002, "face 2 stays sharp")
        let eye = pm(src, 200 - 29, 280), eyeBlur = pm(b, 200 - 29, 280)
        XCTAssertGreaterThan(eyeBlur.r - eye.r, 0.2, "the pupil of face 1 is blurred away")
        XCTAssertLessThan(maxDiff(b, src, CGRect(x: 0, y: 470, width: 960, height: 70)), 0.002, "wall above the faces untouched")
        let p = blurred(.pixelate), s = blurred(.solid)
        XCTAssertLessThan(pm(s, 760, 260).r, 0.02, "solid covers face 3 in black")
        XCTAssertGreaterThan(maxDiff(p, src, CGRect(x: 700, y: 200, width: 120, height: 120)), 0.1)
        // Tracking: at t = 2 face 2's box has moved right by 96 px; its old place is sharp again.
        let moved = blurred(.solid, at: 2)
        XCTAssertLessThan(pm(moved, 480 + 96, 260).r, 0.02); XCTAssertGreaterThan(pm(moved, 480 - 60, 260).r, 0.2)

        // Through the compositor, with the clip scaled down: the blur follows the picture.
        var c = clip("faces"); c.transform.scale = 0.5
        var fb = FaceBlur(); fb.tracks = tracks; fb.pathKey = "k"; fb.faceCount = 3; fb.style = .solid; c.effects.blur = fb
        let comp = frame([TrackLayer(current: source(src, c), outgoing: nil)], at: 0)
        XCTAssertLessThan(pm(comp, 480 + (760 - 480) * 0.5, 270 + (260 - 270) * 0.5).r, 0.02, "face 3 blacked out at half size")

        // Vision on the drawn faces: a smoke test only; detection of real faces is not exercised by these tests.
        let req = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: cg(src), options: [:]).perform([req])
        print("EFFECTS-NOTE: Vision found \(req.results?.count ?? 0) of 3 drawn cartoon faces")

        save(labelledGrid([("Drawn faces (source)", src), ("Blur, face 2 left sharp", b), ("Pixelate", p), ("Black box", s),
                           ("Blur, expand 0.6, feather 0", blurred(.blur, expand: 0.6, feather: 0)), ("Solid at t = 2 (face 2 moved)", moved),
                           ("Clip at 50 % scale", comp)], tile: CGSize(width: 384, height: 216), title: "Face blur on injected face tracks (no real faces)"), "face_blur.png")
    }

    func testFaceAssociationAndTrackLookup() {
        // Two faces 1 s apart in appearance, face A missing for 0.5 s, a one-frame false hit, then both moving.
        var dets: [(t: Double, boxes: [BlurBox])] = []
        for k in 0...30 {
            let t = Double(k) * 0.1
            var boxes: [BlurBox] = []
            if !(1.0...1.45).contains(t) { boxes.append(BlurBox(t: t, x: 0.1 + 0.01 * Double(k), y: 0.2, w: 0.12, h: 0.18)) }
            if t >= 1.0 { boxes.append(BlurBox(t: t, x: 0.7 - 0.005 * Double(k), y: 0.25, w: 0.1, h: 0.15)) }
            if k == 20 { boxes.append(BlurBox(t: t, x: 0.45, y: 0.8, w: 0.05, h: 0.05)) }   // false hit
            dets.append((t, boxes.shuffled()))
        }
        let tracks = FaceAnalyzer.associate(dets)
        XCTAssertEqual(tracks.count, 2, "the one-frame hit is dropped, the gap bridged")
        XCTAssertEqual(tracks.map(\.id), [1, 2])
        XCTAssertEqual(tracks[0].boxes.first?.t ?? -1, 0, accuracy: 0.001, "face 1 is the first to appear")
        XCTAssertEqual(tracks[1].boxes.first?.t ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(tracks[0].boxes.count, 31 - 5)
        XCTAssertTrue(tracks[0].boxes.allSatisfy { $0.x < 0.5 }, "face 1 never swaps with face 2")
        // Lookup: interpolated across the 0.5 s gap, held briefly at the ends, nil far outside.
        let mid = tracks[0].box(at: 1.2)
        XCTAssertNotNil(mid); XCTAssertEqual(mid?.x ?? 0, 0.22, accuracy: 0.015)
        XCTAssertNotNil(tracks[1].box(at: 0.8)); XCTAssertNil(tracks[1].box(at: 0.5))
        let gappy = FaceTrack(id: 1, boxes: [BlurBox(t: 0, x: 0, y: 0, w: 0.1, h: 0.1), BlurBox(t: 3, x: 0.5, y: 0, w: 0.1, h: 0.1)])
        XCTAssertNil(gappy.box(at: 1.5), "a gap over a second is not bridged"); XCTAssertNotNil(gappy.box(at: 0.2))
    }

    func testFaceTracksCacheSkipsHistoryAndSurvivesUndo() async throws {
        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
        let fixture = Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4")!
        _ = try await x.importMedia(paths: [fixture.path])
        let c = try x.insertClip(asset: "base.mp4")
        let tracks = [FaceTrack(id: 1, boxes: [BlurBox(t: 0, x: 0.1, y: 0.1, w: 0.2, h: 0.2), BlurBox(t: 1, x: 0.2, y: 0.1, w: 0.2, h: 0.2)])]
        try doc.apply("Blur faces", origin: .agent) { p in
            p.faceTracks = ["k": tracks]
            try p.updateClip(c.id) { var fb = FaceBlur(); fb.pathKey = "k"; fb.faceCount = 1; $0.effects.blur = fb }
        }
        XCTAssertEqual(doc.project.clip(c.id)?.clip.effects.blur?.tracks.count, 0, "the clip carries only the key")
        XCTAssertEqual(doc.project.hydrated(doc.project.clip(c.id)!.clip).effects.blur?.tracks, tracks)
        XCTAssertNil(doc.project.withoutHistory.faceTracks, "history snapshots skip the cache")
        try x.setClipProperties(c.id.short, opacity: 0.5)
        doc.undo()
        XCTAssertEqual(doc.project.faceTracks?["k"], tracks, "undo keeps the cache")
        doc.redo()
        XCTAssertEqual(doc.project.faceTracks?["k"], tracks, "redo keeps the cache")
        // Look edits re-use the analysis; validation refuses out-of-range values and unknown faces.
        let r = try x.adjustBlur(c.id.short, style: "pixelate", strength: 0.8)
        XCTAssertEqual(r.style, .pixelate)
        XCTAssertThrowsError(try x.adjustBlur(c.id.short, strength: 2))
        XCTAssertThrowsError(try x.adjustBlur(c.id.short, exclude: [4]))
        XCTAssertEqual(x.inspectTimeline().clips.first?.effects?["faceBlur"], "pixelate, 1 face")
    }

    func testBlurRegionFollowsAMovingSquare() async throws {
        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
        let url = workDir.appendingPathComponent("moving_square.mp4")
        let vw = 640, vh = 360
        try writeSDRVideo(url, width: vw, height: vh, frames: 40, fps: 20) { i, c in
            c.setFillColor(self.rgb(0x6B7A8F)); c.fill(CGRect(x: 0, y: 0, width: vw, height: vh))
            for k in 0..<60 { c.setFillColor(self.rgb(UInt32((k * 2654435761) & 0xFFFFFF), 0.25)); c.fill(CGRect(x: (k * 97) % vw, y: (k * 61) % vh, width: 18, height: 12)) }
            let x0 = 100 + CGFloat(i) * 8
            for yy in 0..<4 { for xx in 0..<4 { c.setFillColor((xx + yy) % 2 == 0 ? .white : self.rgb(0xD62828)); c.fill(CGRect(x: x0 + CGFloat(xx) * 20, y: 140 + CGFloat(yy) * 20, width: 20, height: 20)) } }
        }
        _ = try await x.importMedia(paths: [url.path])
        let c = try x.insertClip(asset: "moving_square.mp4")
        do { _ = try await x.blurRegion(c.id.short, x: 0.9, y: 0.1, width: 0.2, height: 0.2, start: nil, end: nil, track: false, style: nil, strength: nil, feather: nil, remove: nil); XCTFail("off-picture rectangle accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("runs off"), error.localizedDescription) }
        // Square drawn at y 140-220 (y-up) → top 1 - 220/360.
        let r = try await x.blurRegion(c.id.short, x: 100.0 / 640, y: 1 - 220.0 / 360, width: 80.0 / 640, height: 80.0 / 360, start: 0, end: nil, track: true, style: "solid", strength: nil, feather: 0, remove: nil)
        XCTAssertEqual(r.regions.count, 1); XCTAssertTrue(r.regions[0].tracked)
        let path = doc.project.hydrated(doc.project.clip(c.id)!.clip).effects.blur!.regions[0].path
        XCTAssertGreaterThan(path.count, 20)
        let last = try XCTUnwrap(path.last)
        let expected = (100 + 8 * Double(39)) / 640   // where the square is in the last frame
        XCTAssertEqual(last.x, expected, accuracy: 0.06, "the region followed the square (last x \(last.x), expected \(expected))")
        print("EFFECTS-NOTE: region path \(path.count) samples, first x \(String(format: "%.3f", path[0].x)), last x \(String(format: "%.3f", last.x)) (square at \(String(format: "%.3f", expected)))\(r.note.map { ", note: \($0)" } ?? "")")
        let removed = try await x.blurRegion(c.id.short, x: nil, y: nil, width: nil, height: nil, start: nil, end: nil, track: false, style: nil, strength: nil, feather: nil, remove: "all")
        XCTAssertTrue(removed.regions.isEmpty); XCTAssertNil(doc.project.clip(c.id)?.clip.effects.blur)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 4. Titles and lower thirds

    private func titleBackground() -> CIImage {
        draw(size) { c in
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [rgb(0x3A506B), rgb(0x1C2541)] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(grad, start: CGPoint(x: 0, y: Self.H), end: CGPoint(x: Self.W, y: 0), options: [])
            c.setFillColor(rgb(0x5BC0BE, 0.25)); c.fillEllipse(in: CGRect(x: 600, y: 250, width: 420, height: 420))
        }
    }

    func testTitleAnimationsContactSheet() throws {
        let bg = titleBackground(), under = TrackLayer(current: source(bg, clip("bg", duration: 10)), outgoing: nil)
        let kinds: [TextAnimation.Kind] = [.fade, .slideUp, .slideDown, .pop, .typewriter, .words, .wipe]
        let ps = [0.0, 0.25, 0.5, 0.75, 1.0]
        var rows: [(String, [CIImage])] = []
        for (preset, k) in kinds.map({ ("title", $0) }) + [("boxed", .typewriter), ("boxed", .words)] {
            var t = TextOverlay(text: "Animated titles look sharp", start: 1, duration: 4, fontSize: 72, colorHex: "#FFFFFF", x: 0.5, y: 0.5, preset: preset)
            t.animation = TextAnimation(inKind: k, inDuration: 1, outKind: .none)
            let layer = try XCTUnwrap(TitleRasterizer.layer(t, canvas: size))
            let frames = ps.map { frame([under], texts: [layer], at: 1 + $0 * 0.999) }
            // Hidden at the start, the plain title at the end of the in animation.
            XCTAssertLessThan(maxDiff(frames[0], frame([under], at: 1), frameRect), 0.004, "\(k) shows nothing at 0 %")
            XCTAssertLessThan(maxDiff(frame([under], texts: [layer], at: 2.5), frame([under], texts: [restLayer(t)], at: 2.5), frameRect), 0.004, "\(k) at rest is the plain title")
            rows.append(("\(k.title)\(preset == "boxed" ? " (boxed)" : "")", frames))
        }
        // Typewriter at 50 %: the right part of the line is still empty.
        var tw = TextOverlay(text: "Typewriter reveals letters", start: 0, duration: 4, fontSize: 72, colorHex: "#FFFFFF", x: 0.5, y: 0.5)
        tw.animation = TextAnimation(inKind: .typewriter, inDuration: 2)
        let twl = try XCTUnwrap(TitleRasterizer.layer(tw, canvas: size)), bare = frame([under], at: 1)
        let half = frame([under], texts: [twl], at: 1), full = frame([under], texts: [twl], at: 3)
        let band = CGRect(x: Self.W * 0.62, y: Self.H / 2 - 30, width: Self.W * 0.25, height: 60), leftBand = CGRect(x: Self.W * 0.12, y: Self.H / 2 - 30, width: Self.W * 0.25, height: 60)
        XCTAssertLessThan(maxDiff(half, bare, band), 0.004, "right of the cut is empty at 50 %")
        XCTAssertGreaterThan(maxDiff(half, bare, leftBand), 0.3, "left of the cut is typed")
        XCTAssertGreaterThan(maxDiff(full, bare, band), 0.3)
        // An animated title is the same size as the plain one; a plain title keeps the old rasterizer.
        let plain = TextOverlay(text: "Animated titles look sharp", start: 0, duration: 2, fontSize: 72, x: 0.5, y: 0.5)
        XCTAssertNil(TitleRasterizer.layer(plain, canvas: size))
        XCTAssertEqual(TitleRasterizer.title(plain, canvas: size)!.size, OverlayLayerBuilder.renderText(plain, canvas: size)!.1)
        save(sheet(rows, tile: CGSize(width: 384, height: 216), columns: ps.map { "\(Int($0 * 100)) %" }), "titles_in_animations.png")

        // Out animations too (the mirror moves), on one row each.
        var outRows: [(String, [CIImage])] = []
        for k in kinds {
            var t = TextOverlay(text: "Goes off with \(k.title.lowercased())", start: 0, duration: 4, fontSize: 64, colorHex: "#FFE066", x: 0.5, y: 0.5)
            t.animation = TextAnimation(inKind: .none, outKind: k, outDuration: 1)
            let layer = try XCTUnwrap(TitleRasterizer.layer(t, canvas: size))
            outRows.append((k.title, ps.map { frame([under], texts: [layer], at: 3 + $0 * 0.999) }))
        }
        save(sheet(outRows, tile: CGSize(width: 320, height: 180), columns: ps.map { "out \(Int($0 * 100)) %" }), "titles_out_animations.png")
    }

    /// The same text, not animated, rasterized like an animated one (its resting frame).
    private func restLayer(_ t: TextOverlay) -> TextLayer {
        var still = t; still.animation = TextAnimation(inKind: .fade, inDuration: 0.05)
        return TitleRasterizer.layer(still, canvas: size)!
    }

    func testLowerThirdsContactSheet() throws {
        let bg = plate(), under = TrackLayer(current: source(bg, clip("bg", duration: 10)), outgoing: nil)
        let ps = [0.0, 0.25, 0.5, 0.75, 1.0]
        var rows: [(String, [CIImage])] = []
        for tpl in LowerThird.Template.allCases {
            for k in [TextAnimation.Kind.wipe, .typewriter] {
                var t = TextOverlay(text: "Asha Rao", start: 0, duration: 4, fontSize: 52, colorHex: "#FFFFFF")
                t.lowerThird = LowerThird(template: tpl, role: "Field engineer, Pune", accentHex: tpl == .box ? "#E63946" : "#FF9F0A")
                t.animation = TextAnimation(inKind: k, inDuration: 1, outKind: .fade, outDuration: 0.4)
                let s = TitleRasterizer.lowerThirdLayout(t, canvas: size).size
                t.x = 0.06 + s.width / Self.W / 2; t.y = 0.88 - s.height / Self.H / 2
                let layer = try XCTUnwrap(TitleRasterizer.layer(t, canvas: size))
                XCTAssertEqual(layer.size, s)
                let box = TextLayout.box(t, canvas: size)
                XCTAssertEqual(box.width * Self.W, s.width, accuracy: 0.5, "TextLayout measures the lower third as drawn")
                XCTAssertGreaterThan(box.minX, 0.0); XCTAssertLessThan(box.maxY, 1.0)
                rows.append(("\(tpl.title), \(k.title.lowercased())", ps.map { frame([under], texts: [layer], at: $0 * 0.999) }))
                XCTAssertLessThan(maxDiff(rows.last!.1[0], bg, frameRect), 0.004)
            }
        }
        save(sheet(rows, tile: CGSize(width: 384, height: 216), columns: ps.map { "in \(Int($0 * 100)) %" }), "lower_thirds.png")
        // A close-up of the three templates at rest.
        let rest = LowerThird.Template.allCases.map { tpl -> CIImage in
            var t = TextOverlay(text: "Asha Rao", start: 0, duration: 4, fontSize: 52, colorHex: "#FFFFFF", x: 0.3, y: 0.5)
            t.lowerThird = LowerThird(template: tpl, role: "Field engineer, Pune"); t.animation = TextAnimation(inKind: .fade, inDuration: 0.1)
            return frame([under], texts: [TitleRasterizer.layer(t, canvas: size)!], at: 2)
        }
        save(sheet(zip(LowerThird.Template.allCases.map(\.title), rest).map { ($0, [$1]) }, tile: CGSize(width: 960, height: 540)), "lower_thirds_rest.png")
    }

    func testTitleToolsValidate() throws {
        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
        let t = try x.addText("Hello there", start: 0, duration: 2, fontSize: nil, colorHex: nil, x: nil, y: nil)
        XCTAssertThrowsError(try x.setTextAnimation(t.id.short, inKind: "zoomy", inDuration: nil, outKind: nil, outDuration: nil))
        XCTAssertThrowsError(try x.setTextAnimation(t.id.short, inKind: "fade", inDuration: 1.5, outKind: "fade", outDuration: 1)) { e in XCTAssertTrue(e.localizedDescription.contains("longer than the text")) }
        XCTAssertThrowsError(try x.setTextAnimation(t.id.short, inKind: "fade", inDuration: 9, outKind: nil, outDuration: nil))
        XCTAssertNil(doc.project.texts[0].animation)
        let r = try x.setTextAnimation(t.id.short, inKind: "word by word", inDuration: 0.8, outKind: "pop", outDuration: nil)
        XCTAssertEqual(r.animation?.inKind, .words); XCTAssertEqual(r.animation?.outKind, .pop)
        _ = try x.setTextAnimation(t.id.short, inKind: "none", inDuration: nil, outKind: "none", outDuration: nil)
        XCTAssertNil(doc.project.texts[0].animation, "none + none is stored as no animation")

        XCTAssertThrowsError(try x.addLowerThird(name: "Asha Rao", role: "Engineer", template: "fancy", start: 0, duration: 4, x: nil, y: nil, accent: nil, color: nil, fontSize: nil, inKind: nil, outKind: nil, text: nil))
        XCTAssertThrowsError(try x.addLowerThird(name: "Asha Rao", role: nil, template: nil, start: 0, duration: 4, x: nil, y: nil, accent: "orange", color: nil, fontSize: nil, inKind: nil, outKind: nil, text: nil))
        let lt = try x.addLowerThird(name: "Asha Rao", role: "Field engineer", template: "box", start: 0.5, duration: 4, x: nil, y: nil, accent: nil, color: nil, fontSize: nil, inKind: nil, outKind: nil, text: nil)
        XCTAssertEqual(lt.lowerThird?.template, .box); XCTAssertEqual(lt.animation?.inKind, .wipe); XCTAssertEqual(lt.animation?.outKind, .fade)
        let added = try XCTUnwrap(doc.project.texts.first { $0.id.short == lt.text })
        let box = TextLayout.box(added, canvas: doc.project.settings.canvas)
        XCTAssertEqual(box.minX, 0.06, accuracy: 0.002); XCTAssertEqual(box.maxY, 0.88, accuracy: 0.002)
        let edited = try x.addLowerThird(name: "Asha Rao", role: "Lead engineer", template: "line", start: nil, duration: nil, x: nil, y: nil, accent: nil, color: nil, fontSize: nil, inKind: nil, outKind: nil, text: lt.text)
        XCTAssertEqual(edited.text, lt.text); XCTAssertEqual(doc.project.texts.count, 2)
        let info = x.inspectTimeline().texts.first { $0.id == lt.text }
        XCTAssertEqual(info?.lowerThird?.role, "Lead engineer"); XCTAssertEqual(info?.lowerThird?.template, .line)
        try x.removeLowerThird(lt.text)
        XCTAssertNil(doc.project.texts.first { $0.id.short == lt.text }?.lowerThird)
    }

    // MARK: - 5. Transitions

    func testTransitionsContactSheets() throws {
        let a = letterCard("A", 0x264653, 0xE9C46A), b = letterCard("B", 0xE76F51, 0xFFFFFF)
        let ps = [0.0, 0.25, 0.5, 0.75, 1.0]
        var rows: [(String, [CIImage])] = []
        for kind in Transition.Kind.allCases {
            let out = clip("A", start: 0, duration: 2)
            var inc = clip("B", start: 2, duration: 2); inc.transitionIn = Transition(kind: kind, duration: 1)
            let layer = TrackLayer(current: source(b, inc, transitionEnd: 3, outgoing: out.id), outgoing: source(a, out))
            let frames = ps.map { frame([layer], at: 2 + $0 * 0.9999) }
            XCTAssertLessThan(maxDiff(frames[0], a, frameRect), 0.02, "\(kind) starts on the outgoing picture")
            XCTAssertLessThan(maxDiff(frame([layer], at: 3), b, frameRect), 0.003, "\(kind) ends on the incoming picture")
            if kind != .iris, kind != .blurDissolve { XCTAssertLessThan(maxDiff(frames[4], b, frameRect), [.zoom, .wipeLeft, .wipeRight, .wipeUp, .wipeDown].contains(kind) ? 0.08 : 0.03, "\(kind) arrives at the incoming picture") }
            rows.append((kind.title, frames))
        }
        // Push left at 50 %: the outgoing picture's right half on the left, the incoming one's left half on the right.
        var inc = clip("B", start: 2, duration: 2); inc.transitionIn = Transition(kind: .pushLeft, duration: 1)
        let mid = frame([TrackLayer(current: source(b, inc, transitionEnd: 3, outgoing: UUID()), outgoing: source(a, clip("A", duration: 2)))], at: 2.5)
        XCTAssertEqual(pm(mid, 100, 20).r, pm(a, 580, 20).r, accuracy: 0.02); XCTAssertEqual(pm(mid, 580, 20).r, pm(b, 100, 20).r, accuracy: 0.02)
        let half = rows.count / 2
        save(sheet(Array(rows[..<half]), tile: CGSize(width: 288, height: 162), columns: ps.map { "\(Int($0 * 100)) %" }), "transitions_1.png")
        save(sheet(Array(rows[half...]), tile: CGSize(width: 288, height: 162), columns: ps.map { "\(Int($0 * 100)) %" }), "transitions_2.png")
    }

    // MARK: - Model, history, interchange

    func testNewFieldsDecodeWithDefaults() throws {
        var p = Project()
        var c = Clip(assetID: UUID(), name: "c", start: 0, duration: 2)
        c.effects.chromaKey = ChromaKey(); c.effects.blend = .screen
        p.tracks[0].clips.append(c)
        var t = TextOverlay(text: "x", start: 0, duration: 1); t.animation = TextAnimation(inKind: .fade); t.lowerThird = LowerThird()
        p.texts.append(t); p.settings.color = .hlg; p.faceTracks = ["k": []]
        let data = try JSONEncoder().encode(p)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["faceTracks"] = nil
        var settings = json["settings"] as! [String: Any]; settings["color"] = nil; json["settings"] = settings
        var texts = json["texts"] as! [[String: Any]]; texts[0]["animation"] = nil; texts[0]["lowerThird"] = nil; json["texts"] = texts
        var tracks = json["tracks"] as! [[String: Any]]; var clips = tracks[0]["clips"] as! [[String: Any]]; clips[0]["effects"] = nil; tracks[0]["clips"] = clips; json["tracks"] = tracks
        let old = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.tracks[0].clips[0].effects.isDefault)
        XCTAssertEqual(old.settings.color, .sdr)
        XCTAssertNil(old.texts[0].animation); XCTAssertNil(old.texts[0].lowerThird); XCTAssertNil(old.faceTracks)
        // Values a newer build might write fall back instead of failing the project.
        clips[0]["effects"] = ["blend": "sparkle", "chromaKey": ["colorHex": "#0000FF"]]; tracks[0]["clips"] = clips; json["tracks"] = tracks
        settings["color"] = "dolbyVision"; json["settings"] = settings
        let odd = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(odd.tracks[0].clips[0].effects.blend, .normal); XCTAssertEqual(odd.tracks[0].clips[0].effects.chromaKey?.tolerance, 0.4)
        XCTAssertEqual(odd.settings.color, .sdr)
        // Round trip keeps everything.
        let back = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back.tracks[0].clips[0].effects, c.effects); XCTAssertEqual(back.texts[0], t); XCTAssertEqual(back.settings.color, .hlg)
    }

    func testInterchangeSaysWhatStaysBehind() {
        var p = Project()
        var c = Clip(assetID: UUID(), name: "c", start: 0, duration: 2); c.effects.chromaKey = ChromaKey(); c.effects.blend = .multiply
        var fb = FaceBlur(); fb.pathKey = "k"; c.effects.blur = fb; c.transitionIn = Transition(kind: .pushLeft, duration: 0.5)
        p.tracks[0].clips.append(c)
        var t = TextOverlay(text: "x", start: 0, duration: 1); t.animation = TextAnimation(inKind: .fade); t.lowerThird = LowerThird(); p.texts.append(t)
        p.settings.color = .pq
        let lines = Effects.notTransferred(p, clips: p.allClips, edl: false)
        for needle in ["push left", "Green-screen", "Blend modes", "Face and region blur", "Title animations", "Lower thirds", "HDR PQ"] {
            XCTAssertTrue(lines.contains { $0.contains(needle) }, "missing a line about \(needle): \(lines)")
        }
        XCTAssertTrue(Effects.notTransferred(Project(), clips: [], edl: false).isEmpty, "a plain project gets no extra lines")
    }

    // MARK: - 6. HDR

    /// A small HLG HEVC Main 10 clip: top half HLG 0.95 (well above SDR white), bottom left HLG 0.75 (SDR white),
    /// bottom right HLG 0.5. Written straight as 10-bit video-range luma codes, neutral chroma.
    private func writeHLGClip(_ url: URL, width: Int = 640, height: Int = 360, frames: Int = 20) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020],
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String, AVVideoAverageBitRateKey: 20_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &buf)
        let b = try XCTUnwrap(buf)
        CVBufferSetAttachment(b, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(b, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        CVPixelBufferLockBaseAddress(b, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt16.self), yRow = CVPixelBufferGetBytesPerRowOfPlane(b, 0) / 2
        let uv = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt16.self), uvRow = CVPixelBufferGetBytesPerRowOfPlane(b, 1) / 2
        let code = { (v: Double) -> UInt16 in UInt16((64 + 876 * v).rounded()) << 6 }
        for row in 0..<height { for col in 0..<width {
            let v = row < height / 2 ? 0.95 : (col < width / 2 ? 0.75 : 0.5)
            y[row * yRow + col] = code(v)
        } }
        for row in 0..<(height / 2) { for col in 0..<width { uv[row * uvRow + col] = 512 << 6 } }
        CVPixelBufferUnlockBaseAddress(b, [])
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 20))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    private func writeSDRVideo(_ url: URL, width: Int, height: Int, frames: Int, fps: Int32, draw: (Int, CGContext) -> Void) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                                                                         AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            var buf: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buf)
            let b = try XCTUnwrap(buf)
            CVPixelBufferLockBaseAddress(b, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            draw(i, ctx)
            CVPixelBufferUnlockBaseAddress(b, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    private func writePNG(_ image: CGImage, _ url: URL) throws {
        let d = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try d.write(to: url)
    }

    /// 10-bit luma codes of the decoded frame at `t` at the given points (fractions of width / height, y down).
    private func lumaCodes(_ url: URL, at t: Double, points: [(Double, Double)]) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        reader.add(out)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))
        XCTAssertTrue(reader.startReading())
        guard let sb = out.copyNextSampleBuffer(), let b = CMSampleBufferGetImageBuffer(sb) else { throw EditError.invalid("no frame at \(t)") }
        reader.cancelReading()
        CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(b, 0), h = CVPixelBufferGetHeightOfPlane(b, 0)
        let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt16.self), row = CVPixelBufferGetBytesPerRowOfPlane(b, 0) / 2
        return points.map { p in Int(y[Int(p.1 * Double(h - 1)) * row + Int(p.0 * Double(w - 1))] >> 6) }
    }
    private func XCTUnwrapAsync<T>(_ v: T?) async throws -> T { try XCTUnwrap(v) }

    private func colorTags(_ url: URL) async throws -> (String, String, String) {
        let track = try await XCTUnwrapAsync(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let fd = try await XCTUnwrapAsync(try await track.load(.formatDescriptions).first)
        let ext = { (k: CFString) in (CMFormatDescriptionGetExtension(fd, extensionKey: k) as? String) ?? "-" }
        return (ext(kCMFormatDescriptionExtension_ColorPrimaries), ext(kCMFormatDescriptionExtension_TransferFunction), ext(kCMFormatDescriptionExtension_YCbCrMatrix))
    }

    /// `exportVideo`, retried on the pre-existing -11800 / -12780 flake: inserting the shared blank base movie
    /// (Application Support/EditMax/blank.mp4) into the composition fails at random in the test host, on main too.
    private func exportRetrying(_ x: ToolExecutor, to path: String, preset: ExportService.Preset) async throws -> ExportService.Result {
        var last: Error?
        for _ in 0..<60 {
            do { return try await x.exportVideo(to: path, preset: preset) } catch {
                last = error
                guard "\(error)".contains("-12780") else { throw error }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        throw last!
    }

    func testHDRMastersCarryHLGAndPQ() async throws {
        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
        let hlg = workDir.appendingPathComponent("hdr_source_hlg.mov"), still = workDir.appendingPathComponent("sdr_still.png")
        try writeHLGClip(hlg)
        try writePNG(cg(draw(CGSize(width: 640, height: 360)) { c in
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 320, height: 360))
            c.setFillColor(CGColor(gray: 0.5, alpha: 1)); c.fill(CGRect(x: 320, y: 0, width: 320, height: 360))
        }, CGRect(x: 0, y: 0, width: 640, height: 360)), still)
        let srcTags = try await colorTags(hlg); XCTAssertEqual(srcTags.1, AVVideoTransferFunction_ITU_R_2100_HLG)
        _ = try await x.importMedia(paths: [hlg.path, still.path])
        _ = try x.insertClip(asset: "hdr_source_hlg.mov")            // 0-1 s
        _ = try x.insertClip(asset: "sdr_still.png", at: 1, duration: 1)
        try x.setProjectSettings(width: 640, height: 360, fps: 20, name: nil)
        let points = [(0.5, 0.25), (0.25, 0.75), (0.75, 0.75)]

        // SDR project first: the master keeps its Rec.709 tags (unchanged behaviour).
        let sdrOut = workDir.appendingPathComponent("hdr_check_sdr_master.mp4")
        _ = try await exportRetrying(x, to: sdrOut.path, preset: .hevc10)
        let sdrTags = try await colorTags(sdrOut)
        XCTAssertEqual(sdrTags.0, AVVideoColorPrimaries_ITU_R_709_2); XCTAssertEqual(sdrTags.1, AVVideoTransferFunction_ITU_R_709_2)

        let sdrStill = sample8(try await renderRetrying(x, 1.5).0, points)
        print("EFFECTS-NOTE: SDR project capture_frame of the SDR still: \(sdrStill)")
        // HLG: an HLG source keeps its codes, SDR white lands at HLG 0.75 (luma code 721).
        let r = try x.setProjectColor("hlg")
        XCTAssertEqual(r.previous, "sdr"); XCTAssertEqual(x.inspectTimeline().color, "hlg")
        let hlgOut = workDir.appendingPathComponent("hdr_hlg_master.mp4")
        _ = try await exportRetrying(x, to: hlgOut.path, preset: .hevc10)
        let tags = try await colorTags(hlgOut)
        XCTAssertEqual(tags.0, AVVideoColorPrimaries_ITU_R_2020); XCTAssertEqual(tags.1, AVVideoTransferFunction_ITU_R_2100_HLG); XCTAssertEqual(tags.2, AVVideoYCbCrMatrix_ITU_R_2020)
        let hdrCodes = try await lumaCodes(hlgOut, at: 0.5, points: points), sdrCodes = try await lumaCodes(hlgOut, at: 1.5, points: points)
        print("EFFECTS-NOTE: HLG master luma codes: HLG source [0.95, 0.75, 0.5] → \(hdrCodes) (expected ≈ [896, 721, 502]); SDR still [white, 50 % grey] → \(sdrCodes[1]), \(sdrCodes[2]) (SDR white expected ≈ 721)")
        XCTAssertEqual(Double(hdrCodes[0]), 896, accuracy: 14, "HLG highlight above SDR white survives")
        XCTAssertEqual(Double(hdrCodes[1]), 721, accuracy: 14)
        XCTAssertEqual(Double(sdrCodes[1]), 721, accuracy: 16, "SDR white sits at HLG reference white (203 nits)")

        // capture_frame stays SDR: the still's white is 255, the HLG highlight is tone-mapped below clipping but brighter than its 0.75 patch.
        let (f0, _) = try await renderRetrying(x, 0.5), (f1, _) = try await renderRetrying(x, 1.5)
        let s0 = sample8(f0, points), s1 = sample8(f1, points)
        print("EFFECTS-NOTE: HLG project capture_frame (tone-mapped SDR) 8-bit: HLG source \(s0); SDR still \(s1)")
        XCTAssertGreaterThan(s0[0], s0[1]); XCTAssertGreaterThan(s1[1], 250)
        XCTAssertEqual(Double(s1[2]), Double(sdrStill[2]), accuracy: 2, "SDR sources look the same in an HDR project's SDR outputs")

        // PQ ProRes: SDR white at PQ 0.58 (code 572), with the colour tags.
        _ = try x.setProjectColor("pq")
        let pqOut = workDir.appendingPathComponent("hdr_pq_master.mov")
        _ = try await exportRetrying(x, to: pqOut.path, preset: .prores422hq)
        let pqTags = try await colorTags(pqOut)
        XCTAssertEqual(pqTags.0, AVVideoColorPrimaries_ITU_R_2020); XCTAssertEqual(pqTags.1, AVVideoTransferFunction_SMPTE_ST_2084_PQ)
        let pqHDR = try await lumaCodes(pqOut, at: 0.5, points: points), pqSDR = try await lumaCodes(pqOut, at: 1.5, points: points)
        print("EFFECTS-NOTE: PQ ProRes luma codes: HLG source → \(pqHDR); SDR still → \(pqSDR) (SDR white expected ≈ 572)")
        XCTAssertEqual(Double(pqSDR[1]), 572, accuracy: 18)
        XCTAssertGreaterThan(pqHDR[0], pqSDR[1] + 60, "the HLG highlight stays well above SDR white in PQ")
        let pqHevc = workDir.appendingPathComponent("hdr_pq_master.mp4")
        _ = try await exportRetrying(x, to: pqHevc.path, preset: .hevc10)
        let pqHevcTags = try await colorTags(pqHevc); XCTAssertEqual(pqHevcTags.1, AVVideoTransferFunction_SMPTE_ST_2084_PQ)
        try? FileManager.default.removeItem(at: still)
        if previewDir == nil { for u in [hlg, sdrOut, hlgOut, pqOut, pqHevc] { try? FileManager.default.removeItem(at: u) } }
    }

    private func renderRetrying(_ x: ToolExecutor, _ t: Double) async throws -> (CGImage, CGSize) {
        var last: Error?
        for _ in 0..<60 {
            do { return try await x.renderFrame(at: t) } catch { last = error; guard "\(error)".contains("-12780") else { throw error }; try await Task.sleep(nanoseconds: 50_000_000) }
        }
        throw last!
    }

    private func sample8(_ img: CGImage, _ points: [(Double, Double)]) -> [Int] {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return points.map { p in Int(px[(Int(p.1 * Double(h - 1)) * w + Int(p.0 * Double(w - 1))) * 4 + 1]) }
    }

    func testHDRMappingIsExactForSDRProjects() throws {
        // The SDR path never touches colour management: instructions default to pass-through.
        let inst = EditMaxInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)), layers: [], texts: [], renderSize: size, requiredTrackIDs: [])
        XCTAssertEqual(inst.output, .passthrough)
        let vc = AVMutableVideoComposition(); vc.customVideoCompositorClass = EditMaxCompositor.self
        ColorManagement.configure(vc, compositor: EditMaxCompositor.self, color: .sdr)
        XCTAssertTrue(vc.customVideoCompositorClass == EditMaxCompositor.self); XCTAssertNil(vc.colorPrimaries)
        ColorManagement.configure(vc, compositor: EditMaxCompositor10.self, color: .hlg)
        XCTAssertTrue(vc.customVideoCompositorClass == EditMaxCompositorHDR.self); XCTAssertEqual(vc.colorTransferFunction, AVVideoTransferFunction_ITU_R_2100_HLG)
        let pvc = AVMutableVideoComposition(); pvc.customVideoCompositorClass = EditMaxPreviewCompositor.self
        ColorManagement.configure(pvc, compositor: EditMaxPreviewCompositor.self, color: .pq)
        XCTAssertTrue(pvc.customVideoCompositorClass == EditMaxPreviewCompositor.self, "the preview of an HDR project is drawn as in SDR")
        XCTAssertNil(pvc.colorTransferFunction)
        let svc = AVMutableVideoComposition()
        ColorManagement.configure(svc, compositor: EditMaxCompositor.self, color: .pq)
        XCTAssertTrue(svc.customVideoCompositorClass == EditMaxCompositorToneMapped.self); XCTAssertEqual(svc.colorPrimaries, AVVideoColorPrimaries_ITU_R_709_2, "SDR outputs of an HDR project say Rec.709")
        XCTAssertEqual(ColorManagement.masteringDisplay.count, 24); XCTAssertEqual(ColorManagement.contentLightLevel.count, 4)
        XCTAssertEqual(ProjectColor.parse("HDR10"), .pq); XCTAssertEqual(ProjectColor.parse("Rec.709"), .sdr); XCTAssertNil(ProjectColor.parse("rec2020"))
    }

    /// The user's report: picking HLG or PQ changed the paused preview frame, and playing put it back. The preview of an
    /// HDR project is now drawn in SDR, so normal footage looks exactly as in an SDR project, paused or playing.
    func testPickingHDRDoesNotChangeThePreviewOfNormalFootage() async throws {
        let fixture = Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4")!
        func previewFrame(_ color: ProjectColor) async throws -> [UInt8] {
            let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
            _ = try await x.importMedia(paths: [fixture.path])
            _ = try x.insertClip(asset: "base.mp4")
            _ = try x.setProjectColor(color.rawValue)
            let out = try await CompositionBuilder.build(doc.project, forPreview: true, compositor: EditMaxPreviewCompositor.self)
            let gen = AVAssetImageGenerator(asset: out.composition)
            gen.videoComposition = out.videoComposition
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            gen.maximumSize = CGSize(width: 160, height: 90)
            let img = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            var px = [UInt8](repeating: 0, count: 160 * 90 * 4)
            let ctx = CGContext(data: &px, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 160 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 160, height: 90))
            return px
        }
        let sdr = try await previewFrame(.sdr)
        for c in [ProjectColor.hlg, .pq] {
            let hdr = try await previewFrame(c)
            let worst = zip(sdr, hdr).map { abs(Int($0) - Int($1)) }.max() ?? 255
            XCTAssertEqual(worst, 0, "\(c.rawValue): the preview of SDR footage is the SDR project's, pixel for pixel")
        }
    }

    // MARK: - Inspector sections

    func testInspectorSectionsRender() async throws {
        let doc = EditMaxDocument(), x = ToolExecutor(document: doc, origin: .agent)
        let fixture = Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4")!
        _ = try await x.importMedia(paths: [fixture.path])
        let c = try x.insertClip(asset: "base.mp4")
        try x.adjustChromaKey(c.id.short, color: "#1DB954", tolerance: 0.45)
        _ = try x.setBlendMode(c.id.short, mode: "screen")
        try doc.apply("Blur faces", origin: .agent) { p in
            p.faceTracks = ["k": [FaceTrack(id: 1, boxes: [BlurBox(t: 0, x: 0.1, y: 0.1, w: 0.2, h: 0.2), BlurBox(t: 1.5, x: 0.1, y: 0.1, w: 0.2, h: 0.2)]),
                                  FaceTrack(id: 2, boxes: [BlurBox(t: 0.4, x: 0.6, y: 0.1, w: 0.2, h: 0.2), BlurBox(t: 2, x: 0.6, y: 0.1, w: 0.2, h: 0.2)])]]
            try p.updateClip(c.id) { var fb = FaceBlur(); fb.pathKey = "k"; fb.faceCount = 2; fb.exclude = [2]; $0.effects.blur = fb }
        }
        let lt = try x.addLowerThird(name: "Asha Rao", role: "Field engineer", template: "bar", start: 0, duration: 2, x: nil, y: nil, accent: nil, color: nil, fontSize: nil, inKind: nil, outKind: nil, text: nil)
        _ = try x.setProjectColor("hlg")
        let clipNow = try XCTUnwrap(doc.project.clip(c.id)?.clip)
        let text = try XCTUnwrap(doc.project.texts.first { $0.id.short == lt.text })
        let views: [(String, AnyView)] = [
            ("inspector_clip_effects", AnyView(ClipEffectsSection(document: doc, clip: clipNow))),
            ("inspector_text_effects", AnyView(TextEffectsSection(document: doc, text: text))),
            ("inspector_project_color", AnyView(InspectorCard("Project") { InspectorValueRow("Resolution", "1920×1080"); ProjectColorRow(document: doc) })),
        ]
        for (name, view) in views {
            for dark in [false, true] {
                let image = try snapshot(view, dark: dark)
                XCTAssertGreaterThan(image.height, 40)
                save(image, "\(name)_\(dark ? "dark" : "light").png")
            }
        }
    }

    /// The view drawn by AppKit in an off-screen window (never shown): NSHostingView + cacheDisplay, which draws the
    /// AppKit-backed controls (pickers, sliders, switches) that ImageRenderer leaves blank.
    private func snapshot(_ view: AnyView, dark: Bool) throws -> CGImage {
        let root = view.frame(width: 320).padding(12).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let fit = host.fittingSize
        host.frame = CGRect(origin: .zero, size: CGSize(width: max(344, fit.width), height: max(40, fit.height)))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.cgImage)
    }
}
