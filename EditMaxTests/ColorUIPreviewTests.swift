import XCTest
import SwiftUI
import AppKit
@testable import EditMax

/// Renders inspector sections off screen (a window that is never shown, so AppKit-backed sliders and pickers draw too;
/// `ImageRenderer` leaves them blank) for the light and dark previews.
@MainActor
enum UIPreview {
    static func render<V: View>(_ view: V, width: CGFloat = 300, dark: Bool) -> CGImage? {
        let root = view.padding(12).frame(width: width).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return rep.cgImage
    }

    /// Light and dark renders of a section, saved as `<name>-light.png` and `<name>-dark.png`.
    static func save<V: View>(_ view: V, _ name: String, width: CGFloat = 300) {
        guard let dir = ColorFixtures.previewDir else { return }
        for dark in [false, true] {
            if let cg = render(view, width: width, dark: dark) { ColorFixtures.savePNG(cg, dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")) }
        }
    }
}

@MainActor
final class ColorInspectorPreviewTests: XCTestCase {
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }

    override func setUp() async throws {
        doc = EditMaxDocument()
        doc.project.assets.append(Asset(name: "a.mp4", path: "/tmp/a.mp4", kind: .video, duration: 10, width: 1920, height: 1080))
        doc.project.assets.append(Asset(name: "b.mp4", path: "/tmp/b.mp4", kind: .video, duration: 10, width: 1920, height: 1080))
    }

    func testPreviewWheelsAndCurvesSections() throws {
        let c = try x.insertClip(asset: "a.mp4")
        _ = try x.setColorWheels(c.id.short, layer: nil, wheel: "lift", r: nil, g: nil, b: nil, master: -0.05, toward: "blue", amount: 0.06, reset: false)
        _ = try x.setColorWheels(c.id.short, layer: nil, wheel: "gain", r: nil, g: nil, b: nil, master: 0.1, toward: "orange", amount: 0.05, reset: false)
        _ = try x.setColorCurve(c.id.short, layer: nil, curve: "master", points: [[0.25, 0.2], [0.75, 0.82]])
        _ = try x.setColorCurve(c.id.short, layer: nil, curve: "blue", points: [[0.5, 0.55]])
        let clip = doc.project.clip(c.id)!.clip
        UIPreview.save(ColorWheelsCard(document: doc, clip: clip), "ui-wheels")
        UIPreview.save(CurvesCard(document: doc, clip: clip), "ui-curves")
        XCTAssertNotNil(UIPreview.render(ColorWheelsCard(document: doc, clip: clip), dark: true))
    }

    /// Shot match, grade layers (with the selected layer's basics and mask) and finishing, dark appearance.
    func testPreviewStackSections() throws {
        let c = try x.insertClip(asset: "a.mp4")
        _ = try x.insertClip(asset: "b.mp4")
        _ = try x.addGradeLayer(c.id.short, name: "Skin", index: nil, mix: 0.8, enabled: nil)
        _ = try x.addGradeLayer(c.id.short, name: "Sky", index: nil, mix: nil, enabled: false)
        _ = try x.updateGradeLayer(c.id.short, layer: "Skin", name: nil, enabled: nil, mix: nil, color: .init(saturation: 1.15, temperature: 8))
        _ = try x.setLayerMask(c.id.short, layer: "Skin", .init(shape: "ellipse", qualifierValues: ["hue_center": 25, "hue_width": 40], subject: "person"))
        _ = try x.setClipFinish(c.id.short, values: ["grain": 0.25, "vignette": 0.3, "glow": 0.2], reset: false)
        let clip = doc.project.clip(c.id)!.clip
        let layer = clip.grades[0], info = ColorTargetInfo(target: .layer(layer.id), idPrefix: "layer.1.")
        func save<V: View>(_ v: V, _ n: String) {
            guard let dir = ColorFixtures.previewDir, let cg = UIPreview.render(v, dark: true) else { return }
            ColorFixtures.savePNG(cg, dir.appendingPathComponent("\(n)-dark.png"))
        }
        save(ShotMatchCard(document: doc, clip: clip), "ui-shot-match")
        save(GradeLayersCard(document: doc, clip: clip, selected: .constant(layer.id)), "ui-grade-layers")
        save(LayerBasicsCard(document: doc, clip: clip, layer: layer, info: info), "ui-layer-basics")
        save(LayerMaskCard(document: doc, clip: clip, layer: layer, info: info), "ui-layer-mask")
        save(FinishCard(document: doc, clip: clip), "ui-finishing")
        XCTAssertNotNil(UIPreview.render(FinishCard(document: doc, clip: clip), dark: true))
    }
}
