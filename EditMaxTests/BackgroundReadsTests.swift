import XCTest
@testable import EditMax

/// Thumbnails, waveforms and proxies of a big import take turns on each drive instead of all reading at once.
final class BackgroundReadsTests: XCTestCase {
    private let t7 = URL(fileURLWithPath: "/Volumes/T7 Shield/DJI OSMO/a.mp4")
    private let t7b = URL(fileURLWithPath: "/Volumes/T7 Shield/DJI OSMO/b.mp4")
    private let mac = URL(fileURLWithPath: "/Users/me/Movies/c.mp4")

    func testTheThirdReadOnADriveWaitsForATurn() async {
        let gate = BackgroundReads(perDrive: 2)
        await gate.acquire(t7)
        await gate.acquire(t7b)
        let third = Task { await gate.acquire(self.t7); return true }
        try? await Task.sleep(for: .milliseconds(50))
        var load = await gate.load(t7)
        XCTAssertEqual(load.running, 2)
        XCTAssertEqual(load.waiting, 1, "the third read on the T7 waits")

        await gate.release(t7)
        let started = await third.value
        XCTAssertTrue(started, "a release hands the turn to the waiting read")
        load = await gate.load(t7)
        XCTAssertEqual(load.running, 2)
        XCTAssertEqual(load.waiting, 0)

        await gate.release(t7); await gate.release(t7b)
        load = await gate.load(t7)
        XCTAssertEqual(load.running, 0)
    }

    func testASlowDriveDoesNotHoldUpTheMacsDisk() async {
        let gate = BackgroundReads(perDrive: 1)
        await gate.acquire(t7)
        let waiting = Task { await gate.acquire(self.t7b) }
        let onMac = Task { await gate.acquire(self.mac); return true }
        let macStarted = await onMac.value
        XCTAssertTrue(macStarted, "a file on the Mac's disk has its own turns")
        try? await Task.sleep(for: .milliseconds(50))
        let load = await gate.load(t7)
        XCTAssertEqual(load.waiting, 1)
        await gate.release(t7)
        await waiting.value
        await gate.release(t7b); await gate.release(mac)
    }

    func testPicturesGoBeforeWaveformsAndTheRestOfAStrip() async {
        let gate = BackgroundReads(perDrive: 1)
        await gate.acquire(t7)
        var order: [String] = []
        let lock = NSLock()
        func note(_ s: String) { lock.lock(); order.append(s); lock.unlock() }
        let rest = Task { await gate.acquire(self.t7, priority: .low); note("rest"); await gate.release(self.t7) }
        try? await Task.sleep(for: .milliseconds(30))
        let wave = Task { await gate.acquire(self.t7, priority: .normal); note("wave"); await gate.release(self.t7) }
        try? await Task.sleep(for: .milliseconds(30))
        let pic = Task { await gate.acquire(self.t7, priority: .high); note("picture"); await gate.release(self.t7) }
        try? await Task.sleep(for: .milliseconds(30))
        await gate.release(t7)
        _ = await (rest.value, wave.value, pic.value)
        XCTAssertEqual(order, ["picture", "wave", "rest"], "the latest request with the highest priority still goes first")
    }

    func testWhilePlayingOnlyTheWarmUpStarts() async {
        let gate = BackgroundReads(perDrive: 2)
        await gate.setPaused(true)
        let thumbnail = Task { await gate.acquire(self.t7, priority: .high); return true }
        await gate.acquire(t7, priority: .urgent)   // the warm-up still gets its turn
        try? await Task.sleep(for: .milliseconds(50))
        var load = await gate.load(t7)
        XCTAssertEqual(load.running, 1)
        XCTAssertEqual(load.waiting, 1, "a thumbnail waits while the player plays")
        await gate.setPaused(false)
        let started = await thumbnail.value
        XCTAssertTrue(started)
        load = await gate.load(t7)
        XCTAssertEqual(load.running, 2)
        await gate.release(t7); await gate.release(t7)
    }

    func testTheTurnKeyIsTheDrive() {
        XCTAssertEqual(BackgroundReads.drive(of: t7), "T7 Shield")
        XCTAssertEqual(BackgroundReads.drive(of: mac), "")
    }
}
