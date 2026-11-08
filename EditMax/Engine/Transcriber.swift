import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text with word timings, through Apple's SpeechAnalyzer (macOS 26 and newer). Nothing leaves the Mac.
/// The first run for a language may download its model; after that an 8-second clip takes well under a second.
enum Transcriber {
    /// macOS 26+: SpeechAnalyzer. Older: SFSpeechRecognizer, on-device when the Mac supports it. `EDITMAX_LEGACY_SPEECH=1` forces the older path.
    static var usesLegacyEngine: Bool {
        if ProcessInfo.processInfo.environment["EDITMAX_LEGACY_SPEECH"] == "1" { return true }
        if #available(macOS 26, *) { return false } else { return true }
    }
    static var isAvailable: Bool { true }

    /// What happens to the audio, for the inspector: on this Mac, or on Apple's servers (older Macs without on-device models).
    static var privacyNote: String {
        if !usesLegacyEngine { return "Speech is recognized on this Mac; nothing is uploaded." }
        let r = SFSpeechRecognizer(locale: Legacy.defaultLocale())
        if r?.supportsOnDeviceRecognition == true { return "Speech is recognized on this Mac; nothing is uploaded." }
        return "This Mac has no on-device speech model for \(Legacy.defaultLocale().identifier); audio is sent to Apple's speech servers, one minute at a time."
    }

    /// `progress` gets how far through the file it has heard (0–1), from whatever thread the recognizer runs on.
    static func transcribe(url: URL, language: String?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        let started = Date()
        let t: Transcript
        if !usesLegacyEngine, #available(macOS 26, *) { t = try await Engine.transcribe(url: url, language: language, progress: progress) }
        else { t = try await Legacy.transcribe(url: url, language: language, progress: progress) }
        let length = Telemetry.lengthBucket(t.words.last?.end ?? 0), took = Telemetry.lengthBucket(Date().timeIntervalSince(started))
        let engine = usesLegacyEngine ? "legacy" : "speech-analyzer"
        await MainActor.run { Telemetry.shared.capture(.transcribeFinished, ["length": length, "took": took, "engine": engine]) }
        return t
    }

    /// SFSpeechRecognizer path (macOS 10.15+). Needs the speech-recognition permission (asked once). On-device recognition has no
    /// length limit; server recognition is capped at one minute per request, so the file is cut into chunks either way.
    enum Legacy {
        static func defaultLocale() -> Locale {
            let c = Locale.current
            return Locale(identifier: [c.language.languageCode?.identifier, c.region?.identifier].compactMap { $0 }.joined(separator: "_"))
        }

        static func transcribe(url: URL, language: String?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
            let wanted = (language?.isEmpty == false && language!.lowercased() != "auto") ? Locale(identifier: language!.replacingOccurrences(of: "-", with: "_")) : defaultLocale()
            guard let recognizer = SFSpeechRecognizer(locale: wanted) ?? SFSpeechRecognizer(locale: Locale(identifier: String(wanted.identifier.prefix(2)))) else {
                let names = SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted().joined(separator: ", ")
                throw EditError.invalid("Language '\(wanted.identifier)' is not available for transcription. Available: \(names)")
            }
            guard recognizer.isAvailable else { throw EditError.invalid("Speech recognition is not available right now (no network for a server-based language, or the service is busy)") }
            let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            guard status == .authorized else {
                throw EditError.invalid("EditMax needs permission for speech recognition. Allow it in System Settings → Privacy & Security → Speech Recognition.")
            }
            let onDevice = recognizer.supportsOnDeviceRecognition
            let asset = AVURLAsset(url: url)
            let total = try await asset.load(.duration).seconds
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw EditError.invalid("'\(url.lastPathComponent)' has no audio track") }
            let started = Date()
            let chunk = 55.0
            var words: [TranscriptWord] = []
            var offset = 0.0
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("editmax-speech-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            while offset < total {
                let length = min(chunk, total - offset)
                let piece = tmp.appendingPathComponent("\(Int(offset)).m4a")
                try await exportAudio(asset, from: offset, length: length, to: piece)
                let request = SFSpeechURLRecognitionRequest(url: piece)
                request.shouldReportPartialResults = false
                request.requiresOnDeviceRecognition = onDevice
                let result = try await recognize(recognizer, request)
                for seg in result.bestTranscription.segments where !seg.substring.isEmpty {
                    words.append(TranscriptWord(text: seg.substring, start: offset + seg.timestamp, end: offset + seg.timestamp + max(0.05, seg.duration)))
                }
                offset += length
                progress?(min(1, offset / max(total, 0.001)))
            }
            DebugLog.event("transcribe", ["file": url.lastPathComponent, "locale": recognizer.locale.identifier, "engine": onDevice ? "legacy-on-device" : "legacy-server", "words": words.count, "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
            return Transcript(locale: recognizer.locale.identifier, words: words)
        }

        private static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechURLRecognitionRequest) async throws -> SFSpeechRecognitionResult {
            try await withCheckedThrowingContinuation { c in
                var done = false
                recognizer.recognitionTask(with: request) { result, error in
                    guard !done else { return }
                    if let error { done = true; c.resume(throwing: EditError.invalid("Transcription failed: \(error.localizedDescription)")); return }
                    if let result, result.isFinal { done = true; c.resume(returning: result) }
                }
            }
        }

        /// One stretch of the asset's audio as an .m4a file.
        private static func exportAudio(_ asset: AVURLAsset, from start: Double, length: Double, to url: URL) async throws {
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw EditError.invalid("cannot export audio") }
            session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
            try await session.export(to: url, as: .m4a)
        }
    }

    @available(macOS 26, *)
    private enum Engine {
        /// `language` is a BCP-47 or POSIX tag ("en", "en-IN", "hi_IN"); nil or "auto" means the Mac's language.
        static func resolveLocale(_ language: String?) async throws -> Locale {
            let wanted: Locale
            if let language, !language.isEmpty, language.lowercased() != "auto" {
                wanted = Locale(identifier: language.replacingOccurrences(of: "-", with: "_"))
            } else {
                let c = Locale.current
                wanted = Locale(identifier: [c.language.languageCode?.identifier, c.region?.identifier].compactMap { $0 }.joined(separator: "_"))
            }
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) { return locale }
            let names = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted().joined(separator: ", ")
            throw EditError.invalid("Language '\(wanted.identifier)' is not available for transcription. Available: \(names)")
        }

        static func transcribe(url: URL, language: String?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
            let locale = try await resolveLocale(language)
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            if await AssetInventory.status(forModules: [transcriber]) != .installed,
               let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                DebugLog.event("transcribe-download", ["locale": locale.identifier])
                try await request.downloadAndInstall()
            }
            let file: AVAudioFile
            do { file = try AVAudioFile(forReading: url) }
            catch { throw EditError.invalid("'\(url.lastPathComponent)' has no readable audio track (\(error.localizedDescription))") }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let started = Date()
            let seconds = Double(file.length) / max(1, file.fileFormat.sampleRate)
            // Results are collected before the audio is fed, or the analyzer has nowhere to put them.
            let collect = Task { () -> [TranscriptWord] in
                var words: [TranscriptWord] = []
                var heard = 0.0
                for try await result in transcriber.results {
                    for run in result.text.runs {
                        let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty, let range = run.audioTimeRange else { continue }
                        words.append(TranscriptWord(text: text, start: range.start.seconds, end: range.end.seconds))
                        heard = max(heard, range.end.seconds)
                    }
                    if seconds > 0 { progress?(min(0.99, heard / seconds)) }   // the last words can end before the file does
                }
                progress?(1)
                return words.sorted { $0.start < $1.start }
            }
            do { try await analyzer.start(inputAudioFile: file, finishAfterFile: true) }
            catch { collect.cancel(); throw EditError.invalid("Transcription failed: \(error.localizedDescription)") }
            let words = try await collect.value
            DebugLog.event("transcribe", ["file": url.lastPathComponent, "locale": locale.identifier, "words": words.count, "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100, "audioSeconds": seconds.rounded()])
            return Transcript(locale: locale.identifier, words: words)
        }
    }
}

/// Transcriptions running now, one per asset, and how far each has got: the inspector shows it, since a long file
/// takes minutes (an hour of speech, about 2–4 min on this kind of Mac).
@MainActor final class Transcribing: ObservableObject {
    static let shared = Transcribing()
    struct Job: Equatable {
        var name: String
        var started: Date
        var fraction: Double = 0
        /// "40%, about 2 min left": the time left once a twentieth is done, when the rate has settled.
        func detail(now: Date = Date()) -> String {
            let pct = "\(Int((fraction * 100).rounded(.down)))%"
            let spent = now.timeIntervalSince(started)
            guard fraction >= 0.05, fraction < 1, spent >= 5 else { return pct }
            let left = spent / fraction * (1 - fraction)
            return pct + ", about " + (left < 60 ? "\(max(5, Int((left / 5).rounded()) * 5)) s" : "\(Int((left / 60).rounded(.up))) min") + " left"
        }
    }
    @Published private(set) var jobs: [UUID: Job] = [:]
    func begin(_ id: UUID, name: String) { jobs[id] = Job(name: name, started: Date()) }
    /// Only forward, and only by a visible step (a long file reports thousands of times).
    func report(_ id: UUID, _ f: Double) {
        guard var j = jobs[id], f >= j.fraction + 0.005 || (f >= 1 && j.fraction < 1) else { return }
        j.fraction = min(1, f); jobs[id] = j
    }
    func end(_ id: UUID) { jobs[id] = nil }
    /// The longest-running one, for a footer that covers every clip.
    var first: Job? { jobs.values.min { $0.started < $1.started } }
}
