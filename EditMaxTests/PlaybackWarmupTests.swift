import XCTest
@testable import EditMax

/// The warm-up reads what the first play needs from a slow drive: each clip's seconds plus the keyframe run-up, files
/// on the Mac's own disk left alone, the clips after the playhead first.
final class PlaybackWarmupTests: XCTestCase {
    private func asset(_ path: String) -> Asset { Asset(name: (path as NSString).lastPathComponent, path: path, kind: .video, duration: 120) }

    func testEachClipsSecondsFromThePlayheadOn() {
        let t7 = asset("/Volumes/T7 Shield/DJI/a.mp4"), mac = asset("/Users/me/Movies/b.mp4"), t7b = asset("/Volumes/T7 Shield/DJI/c.mp4")
        var p = Project()
        p.assets = [t7, mac, t7b]
        p.tracks[0].clips = [
            Clip(assetID: t7.id, name: "a", start: 0, duration: 2, sourceIn: 45),
            Clip(assetID: mac.id, name: "b", start: 2, duration: 2, sourceIn: 10),
            Clip(assetID: t7b.id, name: "c", start: 4, duration: 1, sourceIn: 30),
        ]
        let spans = PlaybackWarmup.spans(p, from: 3)
        XCTAssertEqual(spans.map(\.url.lastPathComponent), ["c.mp4", "a.mp4"], "after the playhead first; the Mac's disk is fast enough")
        XCTAssertEqual(spans[0].range.lowerBound, 30 - PlaybackWarmup.preroll, accuracy: 0.001, "from just before the in-point")
        XCTAssertEqual(spans[0].range.upperBound, 31.2, accuracy: 0.001)
    }

    func testCutsFromTheSameStretchAreReadOnce() {
        let t7 = asset("/Volumes/T7 Shield/DJI/a.mp4")
        var p = Project()
        p.assets = [t7]
        p.tracks[0].clips = [Clip(assetID: t7.id, name: "a", start: 0, duration: 1, sourceIn: 7), Clip(assetID: t7.id, name: "a", start: 1, duration: 1, sourceIn: 8.1)]
        let spans = PlaybackWarmup.spans(p, from: 0)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].range.lowerBound, 6.9, accuracy: 0.001)
        XCTAssertEqual(spans[0].range.upperBound, 9.3, accuracy: 0.001)
    }
}
