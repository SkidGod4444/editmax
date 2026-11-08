import XCTest
import CoreGraphics
@testable import EditMax

/// A strip fills in stages from a slow drive: the seconds the timeline shows first, gaps showing the nearest frame, and
/// a finished strip kept on disk so the next open reads nothing from the drive.
final class ThumbnailStripTests: XCTestCase {
    private func image(_ gray: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        return ctx.makeImage()!
    }

    func testTheSecondsAClipShowsComeFirst() {
        // A 2-minute file, one frame every 0.5 s; a clip shows 45-46 s.
        let (first, rest) = ThumbnailStore.order(count: 240, interval: 0.5, used: [45...46])
        XCTAssertEqual(first, Array(89...93), "45-46 s and one frame either side")
        XCTAssertEqual(first.count + rest.count, 240)
        XCTAssertFalse(rest.contains(90))
    }

    func testGapsShowTheNearestFrameMadeSoFar() {
        let q0 = image(0.1), q1 = image(0.2), made = image(0.9)
        let quick = ThumbnailStore.Strip(interval: 60, frames: [q0, q1], aspect: 16 / 9)
        let frames = ThumbnailStore.compose(made: [90: made], count: 240, interval: 0.5, quick: quick)
        XCTAssertEqual(frames.count, 240, "full length, so a clip can look up any second")
        XCTAssertTrue(frames[90] === made)
        XCTAssertTrue(frames[91] === made, "0.5 s away beats a quick frame 15 s away")
        XCTAssertTrue(frames[0] === q0, "a quick frame at the very second beats one 45 s away")
        XCTAssertTrue(frames[239] === q1)
    }

    func testAFinishedStripIsReadBackFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("strip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let strip = ThumbnailStore.Strip(interval: 0.5, frames: [image(0.2), image(0.5), image(0.8)], aspect: 16 / 9)
        StripCache.save(strip, key: "k", in: dir)
        let back = try XCTUnwrap(StripCache.load("k", in: dir))
        XCTAssertEqual(back.frames.count, 3)
        XCTAssertEqual(back.interval, 0.5)
        XCTAssertEqual(back.aspect, 16 / 9, accuracy: 0.001)
        XCTAssertEqual(back.frames[1].width, 16)
        XCTAssertNil(StripCache.load("missing", in: dir))
    }

    func testTheCacheKeyChangesWithTheFile() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: f) }
        try Data([1, 2, 3]).write(to: f)
        let a = try XCTUnwrap(StripCache.key(for: f))
        try Data([1, 2, 3, 4]).write(to: f)
        XCTAssertNotEqual(a, StripCache.key(for: f), "a different file at the same path makes new frames")
        XCTAssertNil(StripCache.key(for: URL(fileURLWithPath: "/Volumes/Gone/a.mp4")), "an offline file has no key")
    }
}
