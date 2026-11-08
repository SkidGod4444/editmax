import XCTest
@testable import EditMax

/// Auto-reframe frames people the way an editor would: a selfie of two stays two, a distant crowd is not "the subject",
/// the pan does not hop between people, and there is headroom where the frame can move vertically.
final class AutoReframeFacesTests: XCTestCase {
    /// 16:9 footage in a 9:16 frame at the cover scale shows about 32 % of the source width and all of its height.
    private let vertical = CGSize(width: 0.316, height: 1)

    private func face(_ cx: Double, _ cy: Double, _ h: Double) -> CGRect {
        let w = h * 9 / 16   // a face box is about square in pixels: in 16:9 normalized units it is narrower than tall
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    func testASelfieOfTwoStaysTwo() throws {
        // Two friends side by side, close to the lens.
        let a = face(0.43, 0.45, 0.22), b = face(0.55, 0.47, 0.21)
        let aim = try XCTUnwrap(AutoReframe.faceAim([a, b], window: vertical))
        XCTAssertEqual(aim.x, 0.49, accuracy: 0.02, "between the two, not on the bigger one")
    }

    func testPeopleTooFarApartFollowTheMainFace() throws {
        let big = face(0.25, 0.4, 0.3), other = face(0.8, 0.4, 0.2)
        let aim = try XCTUnwrap(AutoReframe.faceAim([big, other], window: vertical))
        XCTAssertEqual(aim.x, 0.25, accuracy: 0.01, "they cannot both fit: the main face")
    }

    func testTheAimDoesNotHopToASimilarFace() throws {
        let left = face(0.25, 0.4, 0.30), right = face(0.8, 0.4, 0.31)   // right is a hair bigger in this frame
        let aim = try XCTUnwrap(AutoReframe.faceAim([left, right], window: vertical, previous: CGPoint(x: 0.25, y: 0.46)))
        XCTAssertEqual(aim.x, 0.25, accuracy: 0.01, "stays on the person it was following")
    }

    func testADistantCrowdIsNotTheSubject() {
        let crowd = (0..<12).map { face(0.05 + Double($0) * 0.08, 0.5, 0.03) }
        XCTAssertNil(AutoReframe.faceAim(crowd, window: vertical), "falls back to the person or saliency path")
    }

    func testBackgroundFacesMayBeCut() throws {
        let host = face(0.5, 0.4, 0.35), passerby = face(0.95, 0.5, 0.06)
        let aim = try XCTUnwrap(AutoReframe.faceAim([host, passerby], window: vertical))
        XCTAssertEqual(aim.x, 0.5, accuracy: 0.01)
    }

    func testHeadroomPutsTheEyesAboveTheCentre() throws {
        // A 9:16 phone clip in a 16:9 frame shows the full width and about a third of the height: the frame pans up/down.
        let wide = CGSize(width: 1, height: 0.316)
        let f = face(0.5, 0.3, 0.1)
        let aim = try XCTUnwrap(AutoReframe.faceAim([f], window: wide))
        XCTAssertGreaterThan(aim.y, f.midY, "aiming below the face puts the face above the frame centre")
        XCTAssertEqual(aim.y - f.midY, 0.316 * 0.12, accuracy: 0.001)
    }

    func testFacesWinOverABodyAndSaliency() {
        let s = { (t: Double, faces: [CGRect]) in
            AutoReframe.Sample(local: t, person: CGPoint(x: 0.7, y: 0.5), salient: CGPoint(x: 0.2, y: 0.5), faces: faces)
        }
        let selfie = [face(0.43, 0.45, 0.22), face(0.55, 0.47, 0.21)]
        let analysis = AutoReframe.Analysis(samples: (0..<6).map { s(Double($0) * 0.33, selfie) }, orientedSize: CGSize(width: 3840, height: 2160))
        let r = AutoReframe.path(analysis, mode: .auto, window: vertical)
        XCTAssertEqual(r.mode, "face")
        XCTAssertEqual(r.points[0].x, 0.49, accuracy: 0.02)
        XCTAssertEqual(AutoReframe.path(analysis, mode: .saliency, window: vertical).mode, "saliency", "saliency mode ignores faces")
    }
}
