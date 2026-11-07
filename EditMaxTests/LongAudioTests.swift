import XCTest
import AVFoundation
@testable import EditMax

/// Long projects: measuring loudness reads the mix a buffer at a time instead of holding it (an 18-hour mix held whole is
/// about 25 GB), hum detection reads only the minute it looks at, and a long transcript comes in pages.
@MainActor
final class LongAudioTests: XCTestCase {
    typealias S = TestSignal
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }

    override func setUp() async throws { doc = EditMaxDocument() }

    /// Twelve minutes: one 30 s clip of a steady tone, 24 times on one track.
    private func twelveMinutes() async throws -> (one: Project, all: Project) {
        let tone = S.sine(1000, seconds: 30, dbfs: -20)   // 30 000 whole cycles: the joins are seamless
        let path = try S.writeWAV([tone, tone], to: S.scratch.appendingPathComponent("long-tone.wav")).path
        _ = try await x.importMedia(paths: [path])
        _ = try x.insertClip(asset: "long-tone.wav", track: nil)
        let one = doc.project
        for _ in 1..<24 { _ = try x.insertClip(asset: "long-tone.wav", track: nil) }
        XCTAssertEqual(doc.project.duration, 720, accuracy: 0.01)
        return (one, doc.project)
    }

    func testReadingATwelveMinuteMixKeepsNoCopyOfIt() async throws {
        let (_, all) = try await twelveMinutes()
        _ = try await Loudness.render(all, seconds: 1)   // warms up AVFoundation, so it is not counted below
        var frames = 0
        let grew = try await Self.peakGrowthMB { try await Loudness.stream(all) { frames += $0.count / 2 } }
        print("LONG-AUDIO stream 12 min: peak +\(Int(grew)) MB")
        XCTAssertEqual(Double(frames) / 48_000, 720, accuracy: 0.05)
        // Held whole, the mix alone is 12 min × 48 000 × 2 channels × 4 bytes = 276 MB.
        XCTAssertLessThan(grew, 100, "the mix is handed over a buffer at a time, not collected")
    }

    func testMeasuringAsItReadsGivesExactlyWhatMeteringTheWholeMixGives() async throws {
        // `measure` meters each buffer as it arrives (the Debug build meters about 13 µs a frame, so this stays short).
        let tone = S.sine(1000, seconds: 8, dbfs: -20)
        _ = try await x.importMedia(paths: [try S.writeWAV([tone, tone], to: S.scratch.appendingPathComponent("short-tone.wav")).path])
        _ = try x.insertClip(asset: "short-tone.wav", track: nil)
        let one = doc.project
        let streamed = try await Loudness.measure(one)
        let m = LoudnessMeter(channels: 2, sampleRate: 48_000)
        let whole = try await Loudness.render(one)
        whole.withUnsafeBufferPointer { m.feed(interleaved: $0.baseAddress!, frames: $0.count / 2) }
        XCTAssertEqual(streamed, m.result)
        XCTAssertEqual(streamed.integrated, -20, accuracy: 0.1, "BS.1770: a 1 kHz tone peaking at −20 dBFS in both channels")
    }

    func testHumDetectionReadsOnlyTheMinuteItLooksAt() async throws {
        let (_, all) = try await twelveMinutes()
        let st = try await Loudness.render(all, seconds: HumDetector.seconds)
        XCTAssertEqual(Double(st.count) / 2 / 48_000, HumDetector.seconds, accuracy: 0.05)
        let whole = try await Loudness.render(all, seconds: 3600)   // longer than the project: all of it
        XCTAssertEqual(Double(whole.count) / 2 / 48_000, 720, accuracy: 0.05)
    }

    func testALongTranscriptComesInPagesWithIndicesThatCutTranscriptTakes() async throws {
        let tone = S.sine(1000, seconds: 2, dbfs: -20)
        _ = try await x.importMedia(paths: [try S.writeWAV([tone, tone], to: S.scratch.appendingPathComponent("talk.wav")).path])
        let id = doc.project.assets[0].id
        // 30 minutes of talk: 4500 words, one every 0.4 s.
        doc.project.transcripts = [id.uuidString: Transcript(locale: "en", words: (0..<4500).map {
            TranscriptWord(text: "w\($0)", start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.3)
        })]
        let p1 = try await x.getTranscript(asset: "talk.wav", clip: nil, language: nil)
        XCTAssertEqual([p1.totalWords, p1.firstWord, p1.wordCount, p1.nextWord], [4500, 0, 2000, 2000])
        XCTAssertEqual(p1.words.first?.text, "w0"); XCTAssertEqual(p1.words.last?.text, "w1999")
        XCTAssertNotNil(p1.note)
        XCTAssertLessThan(try JSONEncoder().encode(p1).count, 150_000, "a page fits an agent's context")
        let p2 = try await x.getTranscript(asset: "talk.wav", clip: nil, language: nil, firstWord: p1.nextWord)
        XCTAssertEqual([p2.firstWord, p2.wordCount, p2.nextWord], [2000, 2000, 4000])
        XCTAssertEqual(p2.words.first?.text, "w2000")
        let p3 = try await x.getTranscript(asset: "talk.wav", clip: nil, language: nil, firstWord: p2.nextWord)
        XCTAssertEqual([p3.firstWord, p3.wordCount], [4000, 500])
        XCTAssertNil(p3.nextWord); XCTAssertNil(p3.note)
        // A stretch of time: 10:00 to 10:40 is words 1500 to 1599.
        let span = try await x.getTranscript(asset: "talk.wav", clip: nil, language: nil, from: 600, to: 640)
        XCTAssertEqual([span.firstWord, span.wordCount], [1500, 100])
        XCTAssertNil(span.nextWord)
        let small = try await x.getTranscript(asset: "talk.wav", clip: nil, language: nil, from: 600, to: 640, maxWords: 30)
        XCTAssertEqual([small.firstWord, small.wordCount, small.nextWord], [1500, 30, 1530])
        let past = try await x.getTranscript(asset: "talk.wav", clip: nil, language: nil, from: 5000)
        XCTAssertEqual(past.wordCount, 0); XCTAssertNotNil(past.note)
        do { _ = try await x.getTranscript(asset: "talk.wav", clip: nil, language: nil, maxWords: 0); XCTFail("max_words 0") } catch {}
        do { _ = try await x.getTranscript(asset: "talk.wav", clip: nil, language: nil, from: 10, to: 5); XCTFail("to before from") } catch {}
    }

    /// The highest memory footprint while `work` runs, sampled every 5 ms, in MB above where it started.
    private static func peakGrowthMB(_ work: () async throws -> Void) async throws -> Double {
        final class Sampler: @unchecked Sendable {
            let lock = NSLock(); var peak = 0.0, running = true
        }
        let s = Sampler(), base = footprintMB()
        Thread.detachNewThread {
            while true {
                let v = footprintMB()
                s.lock.lock(); s.peak = max(s.peak, v); let go = s.running; s.lock.unlock()
                if !go { return }
                usleep(5_000)
            }
        }
        defer { s.lock.lock(); s.running = false; s.lock.unlock() }
        try await work()
        s.lock.lock(); let peak = max(s.peak, footprintMB()); s.lock.unlock()
        return peak - base
    }

    nonisolated private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
