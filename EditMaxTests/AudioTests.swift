import XCTest
import AVFoundation
import SwiftUI
@testable import EditMax

// MARK: - Signals and files

/// Deterministic test sounds and small helpers shared by the audio tests.
enum TestSignal {
    static let fs = 48_000.0

    struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) * 2 - 1 } }

    static func sine(_ f: Double, seconds: Double, dbfs: Double, phase: Double = 0) -> [Float] {
        let a = pow(10, dbfs / 20), n = Int(seconds * fs)
        return (0..<n).map { Float(a * sin(2 * .pi * f * Double($0) / fs + phase)) }
    }
    static func concat(_ parts: [[Float]]) -> [Float] { parts.flatMap { $0 } }

    /// A voice-like sound: a 140 Hz buzz with falling harmonics, in syllables (about 4 a second) with pauses, plus
    /// "s" bursts (noise high-passed around 6 kHz) and a loud phrase every few seconds.
    static func voice(seconds: Double, level: Double = 0.25, sibilance: Double = 0.3, seed: UInt64 = 7) -> [Float] {
        var rng = RNG(s: seed)
        let n = Int(seconds * fs)
        var out = [Float](repeating: 0, count: n)
        var hp = Biquad.highPass(fs, f: 5500), hp2 = Biquad.highPass(fs, f: 5500)
        for i in 0..<n {
            let t = Double(i) / fs
            let syl = max(0, sin(2 * .pi * 4.1 * t)) * (0.5 + 0.5 * sin(2 * .pi * 0.23 * t + 1))
            let phrase = (Int(t / 1.7) % 4 == 3) ? 0.05 : 1.0           // a pause every fourth 1.7 s
            let loud = (Int(t / 2.9) % 3 == 1) ? 2.2 : 1.0               // some phrases much louder
            var v = 0.0
            for h in 1...12 { v += sin(2 * .pi * 140 * Double(h) * t * (1 + 0.01 * sin(2 * .pi * 3 * t))) / Double(h) }
            var x = level * v * 0.35 * syl * phrase * loud
            let sPhase = t.truncatingRemainder(dividingBy: 0.83)
            if sPhase > 0.6 && sPhase < 0.75 && phrase > 0.5 { x += sibilance * hp2.process(hp.process(rng.next())) * sin(.pi * (sPhase - 0.6) / 0.15) }
            out[i] = Float(x)
        }
        return out
    }

    static func peakDB(_ x: [Float]) -> Double { 20 * log10(Double(x.map { abs($0) }.max() ?? 0) + 1e-12) }
    static func rmsDB(_ x: [Float]) -> Double { 10 * log10(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count)) + 1e-20) }
    /// Power of a frequency over the whole signal (Goertzel), in dB.
    static func toneDB(_ x: [Float], _ f: Double) -> Double {
        let w = 2 * cos(2 * .pi * f / fs)
        var s1 = 0.0, s2 = 0.0
        for v in x { let s = Double(v) + w * s1 - s2; s2 = s1; s1 = s }
        return 10 * log10((s1 * s1 + s2 * s2 - w * s1 * s2) / Double(x.count * x.count) + 1e-30)
    }
    static func meter(_ chans: [[Float]], rate: Double = fs) -> LoudnessMeter.Result {
        let m = LoudnessMeter(channels: chans.count, sampleRate: rate); m.feed(planar: chans); return m.result
    }

    /// Writes planar float channels as a 32-bit float WAV.
    @discardableResult
    static func writeWAV(_ chans: [[Float]], to url: URL, rate: Double = fs) throws -> URL {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(chans.count))!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: chans.count,
                                                                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = chans[0].count
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for (c, ch) in chans.enumerated() { ch.withUnsafeBufferPointer { buf.floatChannelData![c].update(from: $0.baseAddress!, count: n) } }
        try file.write(from: buf)
        return url
    }
    static func deinterleave(_ x: [Float]) -> [[Float]] {
        let n = x.count / 2
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n { l[i] = x[2 * i]; r[i] = x[2 * i + 1] }
        return [l, r]
    }

    static var previewDir: URL {
        let env = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_DIR"]
        let u = env.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("editmax-audio-previews")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var scratch: URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("editmax-audio-tests")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

// MARK: - DSP on buffers

final class AudioDSPTests: XCTestCase {
    typealias S = TestSignal

    func testKWeightingMatchesTheStandardAt48k() {
        let (a, b) = LoudnessMeter.kWeighting(48_000)
        XCTAssertEqual(a.b0, 1.53512485958697, accuracy: 1e-6); XCTAssertEqual(a.b1, -2.69169618940638, accuracy: 1e-6); XCTAssertEqual(a.b2, 1.19839281085285, accuracy: 1e-6)
        XCTAssertEqual(a.a1, -1.69065929318241, accuracy: 1e-6); XCTAssertEqual(a.a2, 0.73248077421585, accuracy: 1e-6)
        XCTAssertEqual(b.a1, -1.99004745483398, accuracy: 1e-6); XCTAssertEqual(b.a2, 0.99007225036621, accuracy: 1e-6)
        XCTAssertEqual(b.b0, 1); XCTAssertEqual(b.b1, -2); XCTAssertEqual(b.b2, 1)
    }

    func testReferenceSineLevels() {
        // BS.1770: a 997 Hz sine at -20 dBFS in one channel of a stereo pair reads -23.0 LUFS, in both -20.0.
        let s = S.sine(997, seconds: 5, dbfs: -20), z = [Float](repeating: 0, count: s.count)
        XCTAssertEqual(S.meter([s, z]).integrated, -23.0, accuracy: 0.05)
        XCTAssertEqual(S.meter([s, s]).integrated, -20.0, accuracy: 0.05)
        // At 44.1 kHz the filters are redesigned for the rate.
        let s44 = (0..<Int(5 * 44_100.0)).map { Float(0.1 * sin(2 * .pi * 997 * Double($0) / 44_100)) }
        XCTAssertEqual(S.meter([s44, s44], rate: 44_100).integrated, -20.0, accuracy: 0.05)
    }

    func testEBUTech3341Case3AndGates() {
        // -36 / -23 / -36 dBFS (1 kHz, both channels): the relative gate drops the quiet parts. EBU's 10/60/10 s reads
        // -23.0; at 3/12/3 s the six 400 ms blocks straddling the steps weigh in: -23.1 (ffmpeg's ebur128: -23.1).
        let x = S.concat([S.sine(1000, seconds: 3, dbfs: -36), S.sine(1000, seconds: 12, dbfs: -23), S.sine(1000, seconds: 3, dbfs: -36)])
        let r = S.meter([x, x])
        XCTAssertEqual(r.integrated, -23.1, accuracy: 0.05)
        // -72 dBFS is under the absolute gate: the same as silence there.
        let loud = S.sine(1000, seconds: 6, dbfs: -23), quiet = [Float](repeating: 0, count: 48_000 * 3)
        let y = S.concat([S.sine(1000, seconds: 3, dbfs: -72), loud, quiet]), z = S.concat([quiet, loud, quiet])
        XCTAssertEqual(S.meter([y, y]).integrated, S.meter([z, z]).integrated, accuracy: 0.01)
        XCTAssertEqual(S.meter([loud, loud]).integrated, -23.0, accuracy: 0.02)
        XCTAssertFalse(S.meter([[Float](repeating: 0, count: 48_000)]).integrated.isFinite)
        // Loudness range of a 10 dB step (EBU Tech 3342 case 1: -20 then -30 LUFS) is 10 LU.
        let lra = S.concat([S.sine(1000, seconds: 20, dbfs: -20), S.sine(1000, seconds: 20, dbfs: -30)])
        XCTAssertEqual(S.meter([lra, lra]).range, 10, accuracy: 0.3)
    }

    func testTruePeakSeesBetweenSamples() {
        // fs/4 at 45°: every sample is at ±0.707 of the wave's peak; the true peak is the full peak.
        let x = S.sine(12_000, seconds: 1, dbfs: 0, phase: .pi / 4)
        let r = S.meter([x, x])
        XCTAssertEqual(r.samplePeak, -3.01, accuracy: 0.02)
        XCTAssertEqual(r.truePeak, 0, accuracy: 0.2)
    }

    func testCompressorSteadyState() {
        // A -6 dBFS tone into threshold -18, ratio 3, hard knee comes out 12/3 = 4 dB over the threshold: -14 dBFS.
        var a = ClipAudio(); a.compressor = CompressorSettings(threshold: -18, ratio: 3, attack: 5, release: 200, knee: 0, makeup: 0)
        let x = S.sine(1000, seconds: 2, dbfs: -6)
        let y = OfflineDSP.run([x, x], sampleRate: S.fs, audio: a)[0]
        XCTAssertEqual(S.peakDB(Array(y.suffix(24_000))), -14, accuracy: 0.3)
        // Below the threshold (and the knee) nothing changes.
        let q = S.sine(1000, seconds: 1, dbfs: -30)
        let yq = OfflineDSP.run([q], sampleRate: S.fs, audio: a)[0]
        XCTAssertEqual(S.peakDB(Array(yq.suffix(12_000))), -30, accuracy: 0.01)
        // Makeup adds after the compression.
        a.compressor?.makeup = 4
        XCTAssertEqual(S.peakDB(Array(OfflineDSP.run([x], sampleRate: S.fs, audio: a)[0].suffix(24_000))), -10, accuracy: 0.3)
        XCTAssertEqual(CompressorDSP.curve(-6, threshold: -18, ratio: 3, knee: 6), -14, accuracy: 1e-9)
        XCTAssertEqual(CompressorDSP.curve(-18, threshold: -18, ratio: 3, knee: 6), -18 + (1.0 / 3 - 1) * 9 / 12, accuracy: 1e-9)
    }

    func testLimiterHoldsTheTruePeakCeiling() {
        // Hot material: a voice pushed 14 dB, peaking well over 0 dBFS, plus inter-sample-heavy fs/4 bursts.
        var v = S.voice(seconds: 6).map { $0 * 5 }
        let burst = S.sine(12_000, seconds: 0.05, dbfs: 3, phase: .pi / 4)
        for k in 0..<10 { for (i, b) in burst.enumerated() { v[k * 24_000 + i] += b } }
        XCTAssertGreaterThan(S.meter([v, v]).truePeak, 6)
        for ceiling in [-1.0, -3.0, -0.1] {
            var a = ClipAudio(); a.limiter = LimiterSettings(ceiling: ceiling, release: 80, lookahead: 1.5)
            let y = OfflineDSP.run([v, v], sampleRate: S.fs, audio: a)
            let r = S.meter(y)
            XCTAssertLessThanOrEqual(r.truePeak, ceiling + 0.05, "ceiling \(ceiling)")
            XCTAssertLessThanOrEqual(r.samplePeak, ceiling + 0.01)
        }
    }

    func testLimiterIsTransparentUnderTheCeiling() {
        // Under the ceiling the limiter only delays (look-ahead + 8 frames), sample for sample.
        let x = S.voice(seconds: 2, level: 0.1)
        var a = ClipAudio(); a.limiter = LimiterSettings(ceiling: -1, release: 100, lookahead: 1.5)
        let y = OfflineDSP.run([x], sampleRate: S.fs, audio: a)[0]
        let delay = Int((1.5 / 1000 * S.fs).rounded()) + TruePeak.delay
        var maxErr: Float = 0
        for i in 0..<(x.count - delay) { maxErr = max(maxErr, abs(y[i + delay] - x[i])) }
        XCTAssertLessThan(maxErr, 1e-6)
        XCTAssertEqual(TrackStrip(clipLimiterLookahead: 1.5).latencyMs(fs: S.fs), Double(delay) / S.fs * 1000, accuracy: 1e-9)
    }

    func testDeEsserTurnsDownSibilanceNotTheVoice() {
        let x = S.voice(seconds: 4, sibilance: 0.5)
        var a = ClipAudio(); a.deEsser = DeEsserSettings(amount: 1, frequency: 6000)
        let y = OfflineDSP.run([x], sampleRate: S.fs, audio: a)[0]
        // Energy above 6 kHz (the s bursts) drops; the 140 Hz voice is untouched.
        var hx = Biquad.highPass(S.fs, f: 6000), hy = Biquad.highPass(S.fs, f: 6000), hx2 = hx, hy2 = hy
        let highX = x.map { Float(hx2.process(hx.process(Double($0)))) }, highY = y.map { Float(hy2.process(hy.process(Double($0)))) }
        XCTAssertLessThan(S.rmsDB(highY), S.rmsDB(highX) - 6)
        XCTAssertEqual(S.toneDB(y, 140), S.toneDB(x, 140), accuracy: 0.5)
        // Without sibilance, the LR4 bands sum back to the voice (allpass): same level.
        let clean = S.voice(seconds: 2, sibilance: 0)
        XCTAssertEqual(S.rmsDB(OfflineDSP.run([clean], sampleRate: S.fs, audio: a)[0]), S.rmsDB(clean), accuracy: 0.3)
    }

    func testHumRemovalNotchesMainsAndItsHarmonics() {
        let n = Int(3 * S.fs)
        let hum = (0..<n).map { i -> Float in let t = Double(i) / S.fs; return Float(0.05 * sin(2 * .pi * 60 * t) + 0.03 * sin(2 * .pi * 120 * t) + 0.02 * sin(2 * .pi * 180 * t)) }
        let tone = S.sine(1000, seconds: 3, dbfs: -20)
        let x = zip(hum, tone).map { $0 + $1 }
        var a = ClipAudio(); a.hum = HumSettings(amount: 1, frequency: 60, harmonics: 4)
        let y = Array(OfflineDSP.run([x], sampleRate: S.fs, audio: a)[0].dropFirst(48_000))
        let x1 = Array(x.dropFirst(48_000))
        for f in [60.0, 120, 180] { XCTAssertLessThan(S.toneDB(y, f), S.toneDB(x1, f) - 25, "\(f) Hz") }
        XCTAssertEqual(S.toneDB(y, 1000), S.toneDB(x1, 1000), accuracy: 0.2)
        // Detection picks the right mains frequency.
        var rng = S.RNG(s: 3)
        let noise = (0..<n).map { _ in Float(0.02 * rng.next()) }
        let h50 = (0..<n).map { i -> Float in let t = Double(i) / S.fs; return Float(0.02 * sin(2 * .pi * 50 * t) + 0.01 * sin(2 * .pi * 150 * t)) }
        XCTAssertEqual(HumDetector.detect(zip(noise, h50).map { $0 + $1 }, sampleRate: S.fs).frequency, 50)
        XCTAssertEqual(HumDetector.detect(zip(noise, hum).map { $0 + $1 }, sampleRate: S.fs).frequency, 60)
        XCTAssertFalse(HumDetector.detect(noise, sampleRate: S.fs).clear, "plain noise has no hum to speak of")
    }

    func testPanAndGain() {
        let x = S.sine(500, seconds: 0.5, dbfs: -12)
        var a = ClipAudio(); a.pan = -1
        let y = OfflineDSP.run([x, x], sampleRate: S.fs, audio: a)
        XCTAssertEqual(S.peakDB(y[0]), -12, accuracy: 0.01); XCTAssertLessThan(S.peakDB(y[1]), -100)
        a.pan = 0.5
        let z = OfflineDSP.run([x, x], sampleRate: S.fs, audio: a)
        XCTAssertEqual(S.peakDB(z[0]), -12 + 20 * log10(2.0.squareRoot() * cos(1.5 * .pi / 4)), accuracy: 0.01)
        XCTAssertEqual(S.peakDB(z[1]), -12, accuracy: 0.01)
        a.pan = 0; a.gain = 6
        XCTAssertEqual(S.peakDB(OfflineDSP.run([x], sampleRate: S.fs, audio: a)[0]), -6, accuracy: 0.01)
        // A mono tap cannot pan: the one channel passes untouched.
        a.gain = 0; a.pan = 1
        XCTAssertEqual(S.peakDB(OfflineDSP.run([x], sampleRate: S.fs, audio: a)[0]), -12, accuracy: 0.01)
    }

    func testCrossfadeCurves() {
        for u in stride(from: 0.0, through: 1, by: 0.05) {
            let i = AudioCrossfade.gainIn(u, .equalPower), o = AudioCrossfade.gainIn(1 - u, .equalPower)
            XCTAssertEqual(i * i + o * o, 1, accuracy: 1e-9)
            XCTAssertEqual(AudioCrossfade.gainIn(u, .linear) + AudioCrossfade.gainIn(1 - u, .linear), 1, accuracy: 1e-9)
        }
    }

    func testStripAppliesTrackBusAndMasterGain() {
        let x = S.sine(500, seconds: 0.5, dbfs: -20)
        let strip = TrackStrip(gain: DSP.dbToGain(-3), pan: 0, busGain: DSP.dbToGain(-2), masterGain: DSP.dbToGain(4))
        XCTAssertEqual(S.peakDB(OfflineDSP.run([x], sampleRate: S.fs, audio: ClipAudio(), strip: strip)[0]), -21, accuracy: 0.01)
    }

    func testOldProjectsDecodeWithEverythingOff() throws {
        let json = #"{"name":"Old","tracks":[{"name":"A1","kind":"audio","clips":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","assetID":"6F9619FF-8B86-D011-B42D-00C04FC964FE","name":"c","start":0,"duration":2,"audio":{"lowGain":3}}]}]}"#
        let p = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        let c = p.tracks[0].clips[0]
        XCTAssertEqual(c.audio.lowGain, 3)
        XCTAssertNil(c.audio.compressor); XCTAssertNil(c.audio.limiter); XCTAssertNil(c.audio.deEsser); XCTAssertNil(c.audio.hum)
        XCTAssertEqual(c.audio.gain, 0); XCTAssertEqual(c.audio.pan, 0); XCTAssertNil(c.audioCrossfade)
        XCTAssertTrue(p.tracks[0].mix.isDefault); XCTAssertTrue(p.mix.isDefault)
        XCTAssertTrue(c.audio.hasCleanup); XCTAssertFalse(c.audio.hasDynamics)
        XCTAssertTrue(Mixer.strip(for: p.tracks[0], in: p).isIdentity, "an old project gets no strip: its taps are what they were")
        // Round trip with everything set.
        var q = p
        q.mix.masterGain = -2; q.mix.masterLimiter = LimiterSettings(); q.mix.buses = [Bus(name: "Dialogue")]
        q.tracks[0].mix = TrackMix(); q.tracks[0].mix.pan = 0.3; q.tracks[0].mix.bus = q.mix.buses[0].id
        q.tracks[0].clips[0].audio.compressor = CompressorSettings(); q.tracks[0].clips[0].audioCrossfade = AudioCrossfade(duration: 1, curve: .linear)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(q))
        XCTAssertEqual(back.mix, q.mix); XCTAssertEqual(back.tracks[0].mix, q.tracks[0].mix); XCTAssertEqual(back.tracks[0].clips[0], q.tracks[0].clips[0])
        XCTAssertEqual(Project.currentFormat, 2)
    }

    func testTargetsParse() throws {
        XCTAssertEqual(try Loudness.parseTarget("youtube"), -14); XCTAssertEqual(try Loudness.parseTarget(nil), -14)
        XCTAssertEqual(try Loudness.parseTarget("Apple"), -16); XCTAssertEqual(try Loudness.parseTarget("podcast"), -16)
        XCTAssertEqual(try Loudness.parseTarget("EBU R128"), -23); XCTAssertEqual(try Loudness.parseTarget("-18 LUFS"), -18)
        XCTAssertThrowsError(try Loudness.parseTarget("loud")); XCTAssertThrowsError(try Loudness.parseTarget("3"))
    }
}

// MARK: - Through AVFoundation, on a document

@MainActor
final class AudioMixTests: XCTestCase {
    typealias S = TestSignal
    private var doc: EditMaxDocument!
    private var x: ToolExecutor { ToolExecutor(document: doc, origin: .agent) }

    override func setUp() async throws { doc = EditMaxDocument() }

    private func file(_ name: String, _ chans: [[Float]]) throws -> String { try S.writeWAV(chans, to: S.scratch.appendingPathComponent(name)).path }
    private func add(_ name: String, _ chans: [[Float]], track: String? = nil, start: Double? = nil) async throws -> Clip {
        let path = try file(name, chans)
        _ = try await x.importMedia(paths: [path])
        let c = try x.insertClip(asset: name, track: track)
        // insert_clip with a time is a ripple insert across tracks; place the clip directly instead.
        if let start { try doc.apply("Place", origin: .agent) { p in try p.updateClip(c.id) { $0.start = start } } }
        return doc.project.clip(c.id)!.clip
    }
    private func mix() async throws -> [[Float]] { S.deinterleave(try await Loudness.render(doc.project)) }

    func testRenderingTheSameProjectRepeatedlyNeverFails() async throws {
        // The -11800/-12780 render failures came from the base black-video asset being freed after the build
        // (the composition does not keep its sources alive). `Output.sources` keeps them; ten reads in a row must work.
        let tone = S.sine(1000, seconds: 2, dbfs: -20)
        _ = try await add("repeat.wav", [tone, tone])
        for _ in 0..<10 { let m = try await mix(); XCTAssertEqual(S.peakDB(m[0]), -20, accuracy: 0.01) }
    }

    func testTapSeesTheSourceFormatAndGainAppliesThroughTheMix() async throws {
        let tone = S.sine(1000, seconds: 2, dbfs: -20)
        let c = try await add("tone.wav", [tone, tone])
        _ = try await x.setClipMix(c.id.short, gain: 6, pan: nil)
        let boosted = try await mix()[0]; XCTAssertEqual(S.peakDB(boosted), -14, accuracy: 0.1)
        _ = try await x.setClipMix(c.id.short, gain: 0, pan: -1)
        let m = try await mix()
        XCTAssertEqual(S.peakDB(m[0]), -20, accuracy: 0.1)
        XCTAssertLessThan(S.peakDB(m[1]), -80)
    }

    func testMonoClipsCannotBePanned() async throws {
        let c = try await add("mono.wav", [S.sine(440, seconds: 1, dbfs: -20)])
        do { _ = try await x.setClipMix(c.id.short, gain: nil, pan: 0.5); XCTFail("expected a refusal") }
        catch { XCTAssertTrue("\(error)".contains("mono"), "\(error)") }
        _ = try await x.setClipMix(c.id.short, gain: -3, pan: nil)
        XCTAssertEqual(doc.project.clip(c.id)!.clip.audio.gain, -3)
    }

    func testToolsRefuseOutOfRangeValues() async throws {
        let c = try await add("v.wav", [S.voice(seconds: 1)])
        XCTAssertThrowsError(try x.setClipCompressor(c.id.short, enabled: nil, threshold: 10, ratio: nil, attack: nil, release: nil, knee: nil, makeup: nil))
        XCTAssertThrowsError(try x.setClipCompressor(c.id.short, enabled: nil, threshold: nil, ratio: nil, attack: nil, release: nil, knee: nil, makeup: nil), "nothing to change")
        XCTAssertThrowsError(try x.setClipCompressor(c.id.short, enabled: false, threshold: -20, ratio: nil, attack: nil, release: nil, knee: nil, makeup: nil))
        XCTAssertThrowsError(try x.setClipLimiter(c.id.short, enabled: true, ceiling: 1, release: nil, lookahead: nil))
        XCTAssertThrowsError(try x.setClipLimiter(c.id.short, enabled: true, ceiling: nil, release: nil, lookahead: 9))
        XCTAssertThrowsError(try x.setClipDeEsser(c.id.short, enabled: nil, amount: 2, frequency: nil))
        XCTAssertThrowsError(try x.setMaster(gain: 40, limiter: nil, removeLimiter: false))
        XCTAssertThrowsError(try x.setBus("FX", rename: nil, gain: nil, mute: nil, compressor: ["ratoi": 3], removeCompressor: false, limiter: nil, removeLimiter: false, remove: false))
        let r = try x.setClipCompressor(c.id.short, enabled: true, threshold: -24, ratio: nil, attack: nil, release: nil, knee: nil, makeup: nil)
        XCTAssertEqual(r.changed, ["compressor on", "threshold -24 dBFS"])
        XCTAssertEqual(r.audio.compressor?.ratio, 3)
        XCTAssertEqual(try x.setClipCompressor(c.id.short, enabled: false, threshold: nil, ratio: nil, attack: nil, release: nil, knee: nil, makeup: nil).audio.compressor, nil)
        // The EQ card's Reset leaves the dynamics alone.
        _ = try x.setClipLimiter(c.id.short, enabled: true, ceiling: nil, release: nil, lookahead: nil)
        try x.setClipAudio(c.id.short, low: 3, mid: nil, high: nil, highPass: nil, gate: nil, reset: false)
        try x.setClipAudio(c.id.short, low: nil, mid: nil, high: nil, highPass: nil, gate: nil, reset: true)
        XCTAssertEqual(doc.project.clip(c.id)!.clip.audio.lowGain, 0)
        XCTAssertNotNil(doc.project.clip(c.id)!.clip.audio.limiter)
    }

    func testNormalizeToYouTubeInOneCall() async throws {
        let v = S.voice(seconds: 10, level: 0.04)
        let v2 = S.voice(seconds: 10, level: 0.04, seed: 9)
        _ = try await add("speech.wav", [v, v2])
        let before = try await x.measureLoudness(clip: nil)
        XCTAssertLessThan(before.integrated!, -17, "starts well under the target")
        let r = try await x.normalizeLoudness(target: "youtube", ceiling: nil, clip: nil)
        XCTAssertEqual(r.after.integrated!, -14, accuracy: 0.2)
        XCTAssertLessThanOrEqual(r.after.truePeak!, -1 + 0.05)
        XCTAssertEqual(doc.project.mix.masterLimiter?.ceiling, -1)
        // Measured again from scratch, the project is where the tool said.
        let again = try await x.measureLoudness(clip: nil)
        XCTAssertEqual(again.integrated!, r.after.integrated!, accuracy: 0.05)
        // One undo step brings the master back.
        doc.undo()
        XCTAssertEqual(doc.project.mix.masterGain, 0)
        doc.redo()
        // The rendered mix, for ffmpeg's ebur128, and the numbers next to it.
        try S.writeWAV(try await mix(), to: S.previewDir.appendingPathComponent("normalize-youtube-mix.wav"))
        try S.writeWAV([v, v2], to: S.previewDir.appendingPathComponent("normalize-youtube-source.wav"))
        try JSONEncoder.pretty.encode(r).write(to: S.previewDir.appendingPathComponent("normalize-youtube.json"))
        // And a real ProRes master (24-bit PCM sound) at a small size, to check the export carries the same sound.
        doc.project.settings.width = 320; doc.project.settings.height = 180
        _ = try await ExportService.exportMaster(doc.project, to: S.previewDir.appendingPathComponent("normalize-youtube-master.mov"), preset: .prores422)
    }

    func testSummedPeaksOfTwoLimitedTracksStayUnderTheCeiling() async throws {
        // Two tracks peaking together: each one's own limiter cannot see the sum; normalize lowers the gain until it holds.
        let a = S.voice(seconds: 4, level: 0.2), b = S.voice(seconds: 4, level: 0.2, seed: 11)
        _ = try await add("a.wav", [a, a], track: "A1", start: 0)
        _ = try x.addTrack(kind: "audio", name: "A2")
        _ = try await add("b.wav", [zip(a, b).map { $0 * 0.9 + $1 * 0.1 }, a], track: "A2", start: 0)
        let r = try await x.normalizeLoudness(target: "-9", ceiling: -1, clip: nil)
        XCTAssertLessThanOrEqual(r.after.truePeak!, -1 + 0.05)
        XCTAssertLessThanOrEqual(r.after.integrated!, -9 + 0.2)
        XCTAssertGreaterThan(r.steps.count, 1)
        try JSONEncoder.pretty.encode(r).write(to: S.previewDir.appendingPathComponent("normalize-two-tracks.json"))
    }

    func testNormalizeOneClip() async throws {
        let c = try await add("quiet.wav", [S.voice(seconds: 6, level: 0.05), S.voice(seconds: 6, level: 0.05, seed: 2)])
        let r = try await x.normalizeLoudness(target: "podcast", ceiling: -2, clip: c.id.short)
        XCTAssertEqual(r.after.integrated!, -16, accuracy: 0.2)
        XCTAssertLessThanOrEqual(r.after.truePeak!, -2 + 0.05)
        XCTAssertEqual(doc.project.clip(c.id)!.clip.audio.limiter?.ceiling, -2)
        XCTAssertTrue(doc.project.mix.isDefault, "a clip normalize leaves the master alone")
    }

    func testSoloMutesTheOtherTracksAndBusGainIsExact() async throws {
        let tone = S.sine(1000, seconds: 2, dbfs: -20), other = S.sine(300, seconds: 2, dbfs: -20)
        _ = try await add("t1.wav", [tone, tone], track: "A1", start: 0)
        _ = try x.addTrack(kind: "audio", name: "A2")
        _ = try await add("t2.wav", [other, other], track: "A2", start: 0)
        let both = try await mix()[0]
        XCTAssertEqual(S.toneDB(both, 1000), S.toneDB(tone, 1000), accuracy: 0.05, "tracks add up, nothing scales the sum")
        _ = try await x.setTrackMix("A2", gain: nil, pan: nil, solo: true, mute: nil, bus: nil)
        let solo = try await mix()[0]
        XCTAssertLessThan(S.toneDB(solo, 1000), S.toneDB(tone, 1000) - 40, "A1 is silent while A2 is soloed")
        XCTAssertEqual(S.toneDB(solo, 300), S.toneDB(other, 300), accuracy: 0.05)
        do { _ = try await x.normalizeLoudness(target: nil, ceiling: nil, clip: nil); XCTFail("refused while soloed") } catch { XCTAssertTrue("\(error)".contains("solo")) }
        _ = try await x.setTrackMix("A2", gain: nil, pan: nil, solo: false, mute: nil, bus: nil)
        let bus = try x.setBus("Music", rename: nil, gain: -6, mute: nil, compressor: nil, removeCompressor: false, limiter: nil, removeLimiter: false, remove: false)
        XCTAssertTrue(bus.created)
        _ = try await x.setTrackMix("A1", gain: -2, pan: nil, solo: nil, mute: nil, bus: "Music")
        let m = try await mix()[0]
        XCTAssertEqual(S.toneDB(m, 1000) - S.toneDB(tone, 1000), -8, accuracy: 0.1, "track -2 dB, bus -6 dB")
        XCTAssertEqual(S.toneDB(m, 300) - S.toneDB(other, 300), 0, accuracy: 0.1)
        _ = try x.setBus("Music", rename: nil, gain: nil, mute: true, compressor: nil, removeCompressor: false, limiter: nil, removeLimiter: false, remove: false)
        let silenced = try await mix()[0]; XCTAssertLessThan(S.toneDB(silenced, 1000), S.toneDB(tone, 1000) - 40)
        XCTAssertEqual(x.inspectMix().buses.first?.tracks, ["A1"])
        _ = try x.setBus("Music", rename: nil, gain: nil, mute: nil, compressor: nil, removeCompressor: false, limiter: nil, removeLimiter: false, remove: true)
        XCTAssertNil(doc.project.tracks.first { $0.name == "A1" }!.mix.bus)
    }

    func testEqualPowerCrossfadeKeepsTheLevel() async throws {
        // Two different noises cut together: with an equal-power crossfade the level through the cut stays put.
        var rng = S.RNG(s: 5)
        let n1 = (0..<Int(6 * S.fs)).map { _ in Float(0.1 * rng.next()) }, n2 = (0..<Int(6 * S.fs)).map { _ in Float(0.1 * rng.next()) }
        let p1 = try file("n1.wav", [n1, n1]), p2 = try file("n2.wav", [n2, n2])
        _ = try await x.importMedia(paths: [p1, p2])
        let a = try x.insertClip(asset: "n1.wav", duration: 3)        // leaves 3 s of media after its out point
        let b = try x.insertClip(asset: "n2.wav", at: 3, duration: 3)
        XCTAssertEqual(a.end, b.start, accuracy: 0.001)
        let r = try x.setAudioCrossfade(b.id.short, duration: 1, curve: nil, remove: false)
        XCTAssertEqual(r.duration, 1); XCTAssertEqual(r.curve, "equal_power"); XCTAssertNil(r.note)
        let m = try await mix()[0]
        let win = { (m: [Float], t: Double) in S.rmsDB(Array(m[Int((t - 0.05) * S.fs)..<Int((t + 0.05) * S.fs)])) }
        let ref = win(m, 1.5)
        for t in [3.1, 3.3, 3.5, 3.7, 3.9] { XCTAssertEqual(win(m, t), ref, accuracy: 1.0, "at \(t) s") }
        // A linear crossfade of two unrelated noises dips about 3 dB in the middle.
        _ = try x.setAudioCrossfade(b.id.short, duration: nil, curve: "linear", remove: false)
        let lin = try await mix()[0]
        XCTAssertEqual(win(lin, 3.5) - ref, -3, accuracy: 1.0)
        XCTAssertThrowsError(try x.setAudioCrossfade(b.id.short, duration: nil, curve: "s-curve", remove: false))
        XCTAssertThrowsError(try x.setAudioCrossfade(a.id.short, duration: 1, curve: nil, remove: false), "nothing ends where the first clip starts")
        // Asking for more than the outgoing media allows is shortened, with a note.
        let long = try x.setAudioCrossfade(b.id.short, duration: 5, curve: nil, remove: false)
        XCTAssertEqual(long.duration, 3, accuracy: 0.01); XCTAssertNotNil(long.note)
    }

    func testEditListReportNamesEveryAudioSettingItLeavesBehind() async throws {
        let c = try await add("r.wav", [S.voice(seconds: 2), S.voice(seconds: 2, seed: 3)])
        XCTAssertEqual(Mixer.notTransferred(doc.project), [])
        _ = try x.setClipCompressor(c.id.short, enabled: true, threshold: nil, ratio: nil, attack: nil, release: nil, knee: nil, makeup: nil)
        _ = try x.setClipLimiter(c.id.short, enabled: true, ceiling: nil, release: nil, lookahead: nil)
        _ = try x.setClipDeEsser(c.id.short, enabled: true, amount: nil, frequency: nil)
        _ = try await x.setClipHumRemoval(c.id.short, enabled: true, frequency: "60", amount: nil, harmonics: nil)
        _ = try await x.setClipMix(c.id.short, gain: 2, pan: nil)
        _ = try x.setBus("Dialogue", rename: nil, gain: -2, mute: nil, compressor: nil, removeCompressor: false, limiter: nil, removeLimiter: false, remove: false)
        _ = try await x.setTrackMix("A1", gain: -1, pan: nil, solo: true, mute: nil, bus: "Dialogue")
        _ = try x.setMaster(gain: 3, limiter: nil, removeLimiter: false)
        let lines = Mixer.notTransferred(doc.project)
        for word in ["Compressor", "Limiter", "De-esser", "Hum removal", "Clip gain", "Track gain", "Solo", "bus", "Master gain"] {
            XCTAssertTrue(lines.contains { $0.contains(word) }, "\(word) missing from \(lines)")
        }
        // The EQ line counts EQ only, not the new settings.
        let out = S.scratch.appendingPathComponent("report.fcpxml")
        let r = try await x.exportTimeline(to: out.path, format: .fcpxml)
        XCTAssertFalse(r.notTransferred.contains { $0.hasPrefix("EQ, high-pass") }, "\(r.notTransferred)")
        XCTAssertTrue(r.notTransferred.contains { $0.hasPrefix("Compressor on 1 clip") }, "\(r.notTransferred)")
    }

    func testCompressedClipKeepsItsProcessingThroughATransitionTail() async throws {
        // A clip with +12 dB of clip gain and a transition out: its tail under the transition keeps the gain.
        let t1 = S.sine(1000, seconds: 6, dbfs: -30), t2 = S.sine(300, seconds: 6, dbfs: -30)
        let p1 = try file("g1.wav", [t1, t1]), p2 = try file("g2.wav", [t2, t2])
        _ = try await x.importMedia(paths: [p1, p2])
        let a = try x.insertClip(asset: "g1.wav", duration: 3)
        let b = try x.insertClip(asset: "g2.wav", at: 3, duration: 3)
        _ = try await x.setClipMix(a.id.short, gain: 12, pan: nil)
        _ = try x.setTransition(b.id.short, kind: "crossDissolve", duration: 1)
        let m = try await mix()[0]
        // 0.25 s into the 1 s tail the outgoing clip is at 75% volume: -18 dBFS + 20·log10(0.75).
        let seg = Array(m[Int(3.2 * S.fs)..<Int(3.3 * S.fs)])
        XCTAssertEqual(S.toneDB(seg, 1000) - S.toneDB(Array(m[Int(1 * S.fs)..<Int(1.1 * S.fs)]), 1000), 20 * log10(0.75), accuracy: 0.6)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}

// MARK: - Previews: before/after sounds, their numbers, and pictures of the new UI

@MainActor
final class AudioPreviewTests: XCTestCase {
    typealias S = TestSignal

    func testBeforeAndAfterSounds() throws {
        let dir = S.previewDir
        var numbers: [String: [String: Double]] = [:]
        func r2(_ x: Double) -> Double { x.isFinite ? (x * 100).rounded() / 100 : -999 }
        func record(_ name: String, _ before: [[Float]], _ after: [[Float]], extra: [String: Double] = [:]) throws {
            try S.writeWAV(before, to: dir.appendingPathComponent("\(name)-before.wav"))
            try S.writeWAV(after, to: dir.appendingPathComponent("\(name)-after.wav"))
            let b = S.meter(before), a = S.meter(after)
            var n: [String: Double] = ["before_peak_dbfs": b.samplePeak, "after_peak_dbfs": a.samplePeak, "before_true_peak_dbtp": b.truePeak, "after_true_peak_dbtp": a.truePeak,
                                       "before_rms_dbfs": b.rms, "after_rms_dbfs": a.rms, "before_lufs": b.integrated, "after_lufs": a.integrated,
                                       "before_lra_lu": b.range, "after_lra_lu": a.range]
            n.merge(extra) { $1 }
            numbers[name] = n.mapValues(r2)
        }
        // Compressor: a voice with loud and quiet phrases, threshold -24, 4:1, 6 dB makeup.
        let v = S.voice(seconds: 8, level: 0.3)
        var comp = ClipAudio(); comp.compressor = CompressorSettings(threshold: -24, ratio: 4, attack: 5, release: 120, knee: 6, makeup: 6)
        try record("compressor", [v, v], OfflineDSP.run([v, v], sampleRate: S.fs, audio: comp))
        // Limiter: the same voice pushed 12 dB over full scale in places, limited to -1 dBTP.
        let hot = v.map { $0 * 4 }
        var lim = ClipAudio(); lim.limiter = LimiterSettings(ceiling: -1, release: 80, lookahead: 1.5)
        let limited = OfflineDSP.run([hot, hot], sampleRate: S.fs, audio: lim)
        try record("limiter", [hot, hot], limited)
        XCTAssertLessThanOrEqual(S.meter(limited).truePeak, -0.95)
        // De-esser: a voice with loud s sounds, amount 0.8 at 6 kHz.
        let sib = S.voice(seconds: 8, level: 0.2, sibilance: 0.6)
        var de = ClipAudio(); de.deEsser = DeEsserSettings(amount: 0.8, frequency: 6000)
        let deessed = OfflineDSP.run([sib, sib], sampleRate: S.fs, audio: de)
        var h1 = Biquad.highPass(S.fs, f: 6000), h2 = h1, h3 = h1, h4 = h1
        let bandB = sib.map { Float(h2.process(h1.process(Double($0)))) }, bandA = deessed[0].map { Float(h4.process(h3.process(Double($0)))) }
        try record("deesser", [sib, sib], deessed, extra: ["before_above_6k_rms_dbfs": S.rmsDB(bandB), "after_above_6k_rms_dbfs": S.rmsDB(bandA),
                                                         "before_140hz_db": S.toneDB(sib, 140), "after_140hz_db": S.toneDB(deessed[0], 140)])
        // Hum: the voice over 60 Hz mains hum (with 120 and 180 Hz), removed at full amount.
        let n = Int(8 * S.fs)
        let humSig = (0..<n).map { i -> Float in let t = Double(i) / S.fs; return Float(0.04 * sin(2 * .pi * 60 * t) + 0.025 * sin(2 * .pi * 120 * t) + 0.015 * sin(2 * .pi * 180 * t)) }
        let voiceHum = zip(S.voice(seconds: 8, level: 0.15), humSig).map { $0 + $1 }
        let detected = HumDetector.detect(voiceHum, sampleRate: S.fs)
        var hum = ClipAudio(); hum.hum = HumSettings(amount: 1, frequency: detected.frequency, harmonics: 4)
        let dehummed = OfflineDSP.run([voiceHum, voiceHum], sampleRate: S.fs, audio: hum)
        XCTAssertEqual(detected.frequency, 60)
        try record("hum", [voiceHum, voiceHum], dehummed, extra: ["detected_hz": detected.frequency, "prominence_50_db": detected.prominence50, "prominence_60_db": detected.prominence60,
                                                                 "before_60hz_db": S.toneDB(voiceHum, 60), "after_60hz_db": S.toneDB(dehummed[0], 60),
                                                                 "before_120hz_db": S.toneDB(voiceHum, 120), "after_120hz_db": S.toneDB(dehummed[0], 120),
                                                                 "before_180hz_db": S.toneDB(voiceHum, 180), "after_180hz_db": S.toneDB(dehummed[0], 180)])
        // Two reference signals for ffmpeg's meter: EBU Tech 3341-style steps and a voice.
        let steps = S.concat([S.sine(1000, seconds: 3, dbfs: -36), S.sine(1000, seconds: 12, dbfs: -23), S.sine(1000, seconds: 3, dbfs: -36)])
        try S.writeWAV([steps, steps], to: dir.appendingPathComponent("reference-3341-steps.wav"))
        let ref = S.meter([steps, steps]); numbers["reference-3341-steps"] = ["lufs": ref.integrated, "true_peak_dbtp": ref.truePeak, "lra_lu": ref.range].mapValues(r2)
        let vm = S.meter([v, v]); numbers["reference-voice (compressor-before.wav)"] = ["lufs": vm.integrated, "true_peak_dbtp": vm.truePeak, "lra_lu": vm.range].mapValues(r2)
        try JSONEncoder.pretty.encode(numbers).write(to: dir.appendingPathComponent("audio-numbers.json"))
    }

    /// Draws a view the way the window would (AppKit controls included), in a window that is never shown.
    private func snapshot<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width).fixedSize(horizontal: false, vertical: true))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        let fit = host.fittingSize
        window.setContentSize(NSSize(width: size.width, height: min(max(fit.height, 100), 2400)))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            png = rep.representation(using: .png, properties: [:])
        }
        try XCTUnwrap(png).write(to: S.previewDir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        window.contentView = nil
    }

    func testPicturesOfTheAudioUI() async throws {
        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .agent)
        let a = S.voice(seconds: 6), b = S.voice(seconds: 6, seed: 4)
        let p1 = try S.writeWAV([a, b], to: S.scratch.appendingPathComponent("ui-voice.wav")).path
        let p2 = try S.writeWAV([b, a], to: S.scratch.appendingPathComponent("ui-music.wav")).path
        _ = try await x.importMedia(paths: [p1, p2])
        _ = try x.insertClip(asset: "ui-voice.wav", duration: 3)
        let c = try x.insertClip(asset: "ui-voice.wav", at: 3, duration: 3)
        _ = try x.setClipCompressor(c.id.short, enabled: true, threshold: -22, ratio: 4, attack: nil, release: nil, knee: nil, makeup: 3)
        _ = try x.setClipLimiter(c.id.short, enabled: true, ceiling: -1, release: nil, lookahead: nil)
        _ = try x.setClipDeEsser(c.id.short, enabled: true, amount: 0.6, frequency: nil)
        _ = try await x.setClipHumRemoval(c.id.short, enabled: true, frequency: "50", amount: 0.8, harmonics: nil)
        _ = try await x.setClipMix(c.id.short, gain: 2.5, pan: -0.3)
        _ = try x.setAudioCrossfade(c.id.short, duration: 0.8, curve: nil, remove: false)
        _ = try x.addTrack(kind: "audio", name: "Music")
        _ = try x.setBus("Dialogue", rename: nil, gain: -1.5, mute: nil, compressor: [:], removeCompressor: false, limiter: nil, removeLimiter: false, remove: false)
        _ = try await x.setTrackMix("A1", gain: -3, pan: 0.2, solo: nil, mute: nil, bus: "Dialogue")
        _ = try await x.setTrackMix("Music", gain: -12, pan: nil, solo: nil, mute: true, bus: nil)
        _ = try x.setMaster(gain: 4.2, limiter: [:], removeLimiter: false)
        let found = doc.project.clip(c.id)!
        for dark in [false, true] {
            let sections = ClipAudioSections(document: doc, clip: found.clip, track: found.track).padding(12).background(Color(nsColor: .windowBackgroundColor))
            try snapshot(sections, size: CGSize(width: 360, height: 900), dark: dark, name: "inspector-audio")
            try snapshot(MixerPane(document: doc, player: nil), size: CGSize(width: 460, height: 600), dark: dark, name: "mixer")
        }
        // The empty states: a clip with nothing on, a project with no buses.
        let plainDoc = EditMaxDocument()
        let px = ToolExecutor(document: plainDoc, origin: .agent)
        _ = try await px.importMedia(paths: [p2])
        let pc = try px.insertClip(asset: "ui-music.wav")
        let pf = plainDoc.project.clip(pc.id)!
        for dark in [false, true] {
            try snapshot(ClipAudioSections(document: plainDoc, clip: pf.clip, track: pf.track).padding(12).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 360, height: 600), dark: dark, name: "inspector-audio-off")
            try snapshot(MixerPane(document: plainDoc, player: nil), size: CGSize(width: 460, height: 500), dark: dark, name: "mixer-empty")
        }
    }
}
