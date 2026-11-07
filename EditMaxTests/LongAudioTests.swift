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

    func testAMixReadInPiecesMeasuresWhatOneReadMeasures() async throws {
        // 12 s, 3 s a level; the −12 dBFS stretch drives the master limiter, and the cut at 8 s falls inside it.
        let levels = [-30.0, -18, -12, -24]
        let sig = S.concat(levels.map { S.sine(1000, seconds: 3, dbfs: $0) })
        let voice = S.voice(seconds: 12, level: 0.05)
        let left = zip(sig, voice).map { $0 + $1 }
        _ = try await x.importMedia(paths: [try S.writeWAV([left, sig], to: S.scratch.appendingPathComponent("steps.wav")).path])
        _ = try x.insertClip(asset: "steps.wav", track: nil)
        doc.project.mix.masterLimiter = LimiterSettings(ceiling: -14, release: 100, lookahead: 1.5)
        let one = try await Loudness.meter(doc.project, nil, parts: 1)
        let three = try await Loudness.meter(doc.project, nil, parts: 3)   // 0–4 s, 4–8 s, 8–12 s, each after 3 s of lead-in
        print("LONG-AUDIO pieces: one \(one) three \(three)")
        XCTAssertEqual(three.duration, one.duration, accuracy: 1e-9)
        XCTAssertEqual(three.integrated, one.integrated, accuracy: 0.01)
        XCTAssertEqual(three.range, one.range, accuracy: 0.05)
        XCTAssertEqual(three.truePeak, one.truePeak, accuracy: 0.01)
        XCTAssertEqual(three.samplePeak, one.samplePeak, accuracy: 0.01)
        XCTAssertEqual(three.momentaryMax, one.momentaryMax, accuracy: 0.01)
        XCTAssertEqual(three.shortTermMax, one.shortTermMax, accuracy: 0.01)
        XCTAssertEqual(three.rms, one.rms, accuracy: 0.01)
        XCTAssertLessThan(one.truePeak, -13.5, "the limiter was on in both")
    }

    /// Times measuring a long file: set TEST_RUNNER_EDITMAX_LONG_FILE to its path, and use an optimized build (the
    /// Debug build meters about 170 times slower).
    func testTimeMeasuringALongFile() async throws {
        guard let path = ProcessInfo.processInfo.environment["EDITMAX_LONG_FILE"] else { throw XCTSkip("no long file given") }
        _ = try await x.importMedia(paths: [path])
        _ = try x.insertClip(asset: URL(fileURLWithPath: path).lastPathComponent, track: nil)
        let p = doc.project
        let hours = p.duration / 3600
        var t = Date()
        let m = LoudnessMeter(channels: 2, sampleRate: 48_000)
        try await Loudness.stream(p, seconds: 3600) { m.feed(interleaved: $0.baseAddress!, frames: $0.count / 2) }
        let oneReadHour = Date().timeIntervalSince(t)
        t = Date()
        let r = try await Loudness.measure(p)
        let whole = Date().timeIntervalSince(t)
        print(String(format: "LONG-AUDIO timing: %.2f h, %d pieces; one read of the first hour %.1f s (x%.1f = %.0f s); measure in pieces %.1f s; %.2f LUFS",
                     hours, Loudness.parts(p.duration), oneReadHour, hours, oneReadHour * hours, whole, r.integrated))
        XCTAssertEqual(r.duration, p.duration, accuracy: p.duration * 0.001, "a looped file is a little short: a gap at each join")
    }

    func testAFileWithDroppedAudioPacketsStillMeasures() async throws {
        // Fixtures/audio-gaps.m4a: twenty copies of a 0.5 s AAC tone joined without re-encoding (ffmpeg -stream_loop 19
        // -c copy), so each join leaves a gap of a few hundred samples. It is 10.4 s long but holds about 10.26 s of sound.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio-gaps", withExtension: "m4a"))
        _ = try await x.importMedia(paths: [url.path])
        _ = try x.insertClip(asset: "audio-gaps.m4a", track: nil)
        var frames = 0
        try await Loudness.stream(doc.project) { frames += $0.count / 2 }
        XCTAssertLessThan(Double(frames) / 48_000, doc.project.duration - 0.1, "the gaps give fewer frames than the length")
        let r = try await Loudness.measure(doc.project)
        XCTAssertEqual(r.integrated, -41.4, accuracy: 0.2, "what ffmpeg's ebur128 filter measures on the file")
    }

    /// Times transcribing a long file and how much memory it takes: set TEST_RUNNER_EDITMAX_SPEECH_FILE to its path.
    func testTimeTranscribingALongFile() async throws {
        guard let path = ProcessInfo.processInfo.environment["EDITMAX_SPEECH_FILE"] else { throw XCTSkip("no speech file given") }
        let url = URL(fileURLWithPath: path)
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        let seen = Seen<Double>()
        var words = 0
        let t = Date()
        let grew = try await Self.peakGrowthMB { words = try await Transcriber.transcribe(url: url, language: "en-US", progress: { seen.add($0) }).words.count }
        let took = Date().timeIntervalSince(t)
        print(String(format: "LONG-AUDIO transcribe: %.0f min of speech in %.1f s (%.0fx real time, 18 h ≈ %.0f min), %d words, peak +%.0f MB, %d progress reports",
                     seconds / 60, took, seconds / took, 18 * 3600 / (seconds / took) / 60, words, grew, seen.values.count))
        XCTAssertGreaterThan(words, Int(seconds / 60 * 100), "about 200 words a minute of speech")
        XCTAssertEqual(seen.values, seen.values.sorted(), "progress only moves forward")
        XCTAssertGreaterThan(seen.values.last ?? 0, 0.95)
    }

    func testTranscribingSaysHowFarAndAboutHowLongIsLeft() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var j = Transcribing.Job(name: "talk.m4a", started: t0)
        XCTAssertEqual(j.detail(now: t0.addingTimeInterval(2)), "0%")
        j.fraction = 0.4
        XCTAssertEqual(j.detail(now: t0.addingTimeInterval(60)), "40%, about 2 min left")   // 90 s to go
        j.fraction = 0.9
        XCTAssertEqual(j.detail(now: t0.addingTimeInterval(90)), "90%, about 10 s left")
        XCTAssertEqual(ProjectInspector.transcribing(j), "Transcribing talk.m4a: " + j.detail())
    }

    func testTranscribingProgressOnlyMovesForwardAndEnds() {
        let t = Transcribing.shared, id = UUID()
        t.begin(id, name: "a.m4a")
        t.report(id, 0.3); t.report(id, 0.2); t.report(id, 0.301)
        XCTAssertEqual(t.jobs[id]?.fraction, 0.3)
        t.report(id, 1)
        XCTAssertEqual(t.jobs[id]?.fraction, 1)
        t.end(id)
        XCTAssertNil(t.jobs[id])
    }

    func testReadingTheMixSaysHowFarItHasGot() async throws {
        let (_, all) = try await twelveMinutes()
        let seen = Seen<Double>()
        try await Loudness.stream(all, progress: { seen.add($0) }) { _ in usleep(250) }   // slowed so it reports along the way
        let v = seen.values
        XCTAssertGreaterThan(v.count, 2)
        XCTAssertEqual(v, v.sorted(), "only forward")
        XCTAssertEqual(v.last, 1)
    }

    func testNormalizeSaysWhichPassItIsOnAndHowFar() async throws {
        let tone = S.sine(1000, seconds: 4, dbfs: -30)
        _ = try await x.importMedia(paths: [try S.writeWAV([tone, tone], to: S.scratch.appendingPathComponent("quiet-tone.wav")).path])
        _ = try x.insertClip(asset: "quiet-tone.wav", track: nil)
        let seen = Seen<Loudness.Progress>()
        let r = try await x.normalizeLoudness(target: "youtube", ceiling: nil, clip: nil, progress: { seen.add($0) })
        let v = seen.values
        let passes = Set(v.map(\.pass)).sorted()
        XCTAssertEqual(passes, Array(1...(1 + r.steps.count)), "the measurement before, then one per step")
        XCTAssertTrue(v.allSatisfy { $0.passes == 7 })
        for p in passes { XCTAssertEqual(v.last { $0.pass == p }?.fraction, 1, "pass \(p) reached its end") }
        XCTAssertEqual(v.first?.text, "pass 1 of up to 7, \(Int(v.first!.fraction * 100))%")
        XCTAssertTrue(Loudness.Progress(pass: 2, passes: 7, fraction: 0.1).isAhead(of: .init(pass: 1, passes: 7, fraction: 0.9)))
        XCTAssertFalse(Loudness.Progress(pass: 2, passes: 7, fraction: 0.3).isAhead(of: .init(pass: 2, passes: 7, fraction: 0.4)), "a late report from another piece")
    }

    func testHumDetectionReadsOnlyTheMinuteItLooksAt() async throws {
        let (_, all) = try await twelveMinutes()
        let st = try await Loudness.render(all, seconds: HumDetector.seconds)
        XCTAssertEqual(Double(st.count) / 2 / 48_000, HumDetector.seconds, accuracy: 0.05)
        let whole = try await Loudness.render(all, seconds: 3600)   // longer than the project: all of it
        XCTAssertEqual(Double(whole.count) / 2 / 48_000, 720, accuracy: 0.05)
    }

    func testALongTranscriptComesInPagesThatEachFitOneReplyAndLoseNoWord() async throws {
        let tone = S.sine(1000, seconds: 2, dbfs: -20)
        _ = try await x.importMedia(paths: [try S.writeWAV([tone, tone], to: S.scratch.appendingPathComponent("talk.wav")).path])
        let id = doc.project.assets[0].id
        // 30 minutes of talk: 4500 words, one every 0.4 s, with millisecond times like real ones.
        doc.project.transcripts = [id.uuidString: Transcript(locale: "en", words: (0..<4500).map {
            TranscriptWord(text: "word\($0)", start: Double($0) * 0.4 + 0.123, end: Double($0) * 0.4 + 0.391)
        })]
        // Every page, in order: together they are every word once.
        var pages: [ToolExecutor.TranscriptInfo] = [], next: Int? = 0
        while let n = next {
            let p = try await x.getTranscript(asset: "talk.wav", clip: nil, language: nil, firstWord: n == 0 ? nil : n)
            XCTAssertEqual(p.firstWord, n); XCTAssertEqual(p.totalWords, 4500)
            let sent = try EditMaxTools.transcriptText(p)
            XCTAssertLessThanOrEqual(sent.utf8.count, ToolExecutor.transcriptPageBytes, "page at \(n)")
            XCTAssertLessThan(sent.count, 100_000, "under Claude Code's cut of a tool reply")
            if p.nextWord != nil { XCTAssertGreaterThan(sent.utf8.count, 70_000, "pages are not much smaller than they need be"); XCTAssertNotNil(p.note) }
            else { XCTAssertNil(p.note) }
            pages.append(p); next = p.nextWord
            XCTAssertLessThan(pages.count, 10)
        }
        print("LONG-AUDIO transcript pages: \(pages.map(\.wordCount)) words")
        XCTAssertEqual(pages.flatMap { $0.words.map(\.text) }, (0..<4500).map { "word\($0)" })
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages[1].firstWord, pages[0].nextWord)
        // The note sorts before the words, so even a reply cut short would still say where the next page starts.
        let first = try EditMaxTools.transcriptText(pages[0])
        XCTAssertLessThan(try XCTUnwrap(first.range(of: "\"nextWord\"")).lowerBound, try XCTUnwrap(first.range(of: "\"words\"")).lowerBound)
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

    /// Values a background callback hands over.
    private final class Seen<T>: @unchecked Sendable {
        private let lock = NSLock(); private var v: [T] = []
        func add(_ x: T) { lock.lock(); v.append(x); lock.unlock() }
        var values: [T] { lock.lock(); defer { lock.unlock() }; return v }
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
