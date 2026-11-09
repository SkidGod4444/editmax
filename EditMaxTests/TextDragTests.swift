import XCTest
import SwiftUI
import AppKit
import CoreImage
import AVFoundation
@testable import EditMax

/// Titles are moved by dragging them on the viewer: the title follows the pointer in the picture, snaps to the centre
/// lines, captions move as a set, and letting go is one undoable edit.
@MainActor
final class TextDragTests: XCTestCase {
    override func tearDown() { LiveTextPositions.shared.clear() }

    func testDragMathSnapsToTheCentreAndStaysInTheFrame() {
        let pic = CGSize(width: 640, height: 360)
        // 64 pt right and 36 pt up from (0.5, 0.85): a tenth of the width and of the height.
        var r = TextDragOverlay.dragged(from: CGPoint(x: 0.5, y: 0.85), by: CGSize(width: 64, height: -36), pic: pic)
        XCTAssertEqual(r.point.x, 0.6, accuracy: 1e-9); XCTAssertEqual(r.point.y, 0.75, accuracy: 1e-9)
        XCTAssertFalse(r.snapX); XCTAssertFalse(r.snapY)
        // Within 6 pt of the middle: on it, and the guides show.
        r = TextDragOverlay.dragged(from: CGPoint(x: 0.3, y: 0.3), by: CGSize(width: 0.2 * 640 + 4, height: 0.2 * 360 - 5), pic: pic)
        XCTAssertEqual(r.point, CGPoint(x: 0.5, y: 0.5)); XCTAssertTrue(r.snapX); XCTAssertTrue(r.snapY)
        // Never off the frame.
        r = TextDragOverlay.dragged(from: CGPoint(x: 0.9, y: 0.9), by: CGSize(width: 500, height: 500), pic: pic)
        XCTAssertEqual(r.point, CGPoint(x: 1, y: 1))
        // A box maps into the aspect-fit picture.
        let box = TextDragOverlay.rect(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.1), in: CGRect(x: 100, y: 20, width: 640, height: 360))
        XCTAssertEqual(box, CGRect(x: 260, y: 200, width: 320, height: 36))
    }

    func testACaptionMovesWithItsSet() {
        let g = UUID()
        let a = TextOverlay(text: "one", start: 0, duration: 1, group: g), b = TextOverlay(text: "two", start: 1, duration: 1, group: g)
        let title = TextOverlay(text: "Flight to KL", start: 0, duration: 3)
        XCTAssertEqual(TextDragOverlay.moving(with: a, in: [a, b, title]).map(\.id), [a.id, b.id])
        XCTAssertEqual(TextDragOverlay.moving(with: title, in: [a, b, title]).map(\.id), [title.id])
    }

    /// The preview draws a dragged title where the pointer has it, before any edit; a build that has the new position
    /// takes over (the live position is dropped), and one that does not keeps it (no flash back).
    func testTheLivePositionIsDrawnAndSettles() throws {
        let canvas = CGSize(width: 640, height: 360)
        let text = TextOverlay(text: "MOVE ME", start: 0, duration: 5, fontSize: 40, x: 0.5, y: 0.5)
        let (cg, px) = try XCTUnwrap(OverlayLayerBuilder.renderText(text, canvas: canvas))
        let ci = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        let layer = TextLayer(text: text, image: ci.transformed(by: CGAffineTransform(scaleX: px.width / ci.extent.width, y: px.height / ci.extent.height)), size: px)
        let inst = EditMaxInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600)),
                                      layers: [], texts: [layer], renderSize: canvas, requiredTrackIDs: [])

        func centre(_ image: CIImage) throws -> CGPoint {
            let w = Int(canvas.width), h = Int(canvas.height)
            var px = [UInt8](repeating: 0, count: w * h * 4)
            EditMaxCompositor.context.render(image, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(origin: .zero, size: canvas), format: .RGBA8, colorSpace: nil)
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4] > 200 { sx += Double(x); sy += Double(y); n += 1 } }
            XCTAssertGreaterThan(n, 50, "the title is drawn")
            // Core Image rows run bottom-up: row 0 of the bitmap is the top of the picture.
            return CGPoint(x: sx / n / canvas.width, y: sy / n / canvas.height)
        }
        let still = try centre(FrameRenderer.frame(inst, at: 1) { _ in nil })
        XCTAssertEqual(still.x, 0.5, accuracy: 0.03); XCTAssertEqual(still.y, 0.5, accuracy: 0.05)
        let moved = try centre(FrameRenderer.frame(inst, at: 1, moved: [text.id: CGPoint(x: 0.25, y: 0.2)]) { _ in nil })
        XCTAssertEqual(moved.x, 0.25, accuracy: 0.03); XCTAssertEqual(moved.y, 0.2, accuracy: 0.05)

        LiveTextPositions.shared.set([text.id: CGPoint(x: 0.25, y: 0.2)])
        LiveTextPositions.shared.settle([text])
        XCTAssertEqual(LiveTextPositions.shared.moves.count, 1, "a build from before the move keeps the live position")
        var there = text; there.x = 0.25; there.y = 0.2
        LiveTextPositions.shared.settle([there])
        XCTAssertTrue(LiveTextPositions.shared.moves.isEmpty, "the build with the move takes over")
    }

    /// On the viewer: the title's box sits on the title, and a drag (the code the gesture runs) moves it, captions as a
    /// set, in one undoable edit. SwiftUI drag gestures take no posted events in an off-screen test window, so the drag
    /// is driven through the same functions.
    func testDraggingATitleOnTheViewerMovesIt() throws {
        let doc = EditMaxDocument()
        doc.project.settings.width = 1920; doc.project.settings.height = 1080
        let title = TextOverlay(text: "Flight to KL", start: 0, duration: 5, fontSize: 96, x: 0.5, y: 0.85)
        let g = UUID()
        let cap1 = TextOverlay(text: "we took off", start: 5, duration: 2, x: 0.5, y: 0.9, group: g)
        let cap2 = TextOverlay(text: "and landed", start: 7, duration: 2, x: 0.5, y: 0.9, group: g)
        doc.project.texts = [title, cap1, cap2]
        let state = EditorState(), player = PlayerController()
        let size = CGSize(width: 640, height: 360)
        let host = OffscreenHost(TextDragOverlay(document: doc, player: player, state: state, aspect: 16.0 / 9), size: size, dark: true)
        let box = try XCTUnwrap(host.frame("preview.text.\(title.id.short)"), "the title on screen has a box on the viewer")
        XCTAssertEqual(box.midX, 320, accuracy: 2); XCTAssertEqual(box.midY, 0.85 * 360, accuracy: 3)
        XCTAssertLessThan(box.width, 640, "the box is the title's, not the whole viewer")
        XCTAssertNil(host.frame("preview.text.\(cap1.id.short)"), "a caption not on screen at the playhead has no box")

        // 128 pt left and 144 pt up: to (0.3, 0.45).
        var d = TextDragOverlay.begin(title, in: doc.project.texts)
        for i in 1...8 { TextDragOverlay.update(&d, by: CGSize(width: -16 * CGFloat(i), height: -18 * CGFloat(i)), pic: size) }
        XCTAssertEqual(doc.project.texts[0].x, 0.5, "no edit until the mouse goes up")
        XCTAssertTrue(TextDragOverlay.commit(d, to: doc))
        XCTAssertEqual(doc.project.texts[0].x, 0.3, accuracy: 0.001)
        XCTAssertEqual(doc.project.texts[0].y, 0.45, accuracy: 0.001)
        doc.undo()
        XCTAssertEqual(doc.project.texts[0].x, 0.5, "one undo puts it back")
        XCTAssertEqual(doc.project.texts[0].y, 0.85)

        // A click is not a move.
        XCTAssertFalse(TextDragOverlay.commit(TextDragOverlay.begin(title, in: doc.project.texts), to: doc))

        // A caption brings its set: both move up by the same amount, in one edit.
        var c = TextDragOverlay.begin(cap1, in: doc.project.texts)
        TextDragOverlay.update(&c, by: CGSize(width: 0, height: -72), pic: size)
        TextDragOverlay.commit(c, to: doc)
        XCTAssertEqual(doc.project.texts[1].y, 0.7, accuracy: 0.001)
        XCTAssertEqual(doc.project.texts[2].y, 0.7, accuracy: 0.001)
        XCTAssertEqual(doc.project.texts[0].y, 0.85, "the title stays")
        doc.undo()
        XCTAssertEqual(doc.project.texts.map(\.y), [0.85, 0.9, 0.9])
    }
}
