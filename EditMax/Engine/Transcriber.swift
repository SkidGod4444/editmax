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

    static func transcribe(url: URL, language: String?) async throws -> Transcript {
        if !usesLegacyEngine, #available(macOS 26, *) { return try await Engine.transcribe(url: url, language: language) }
        return try await Legacy.transcribe(url: url, language: language)
    }

    /// SFSpeechRecognizer path (macOS 10.15+). Needs the speech-recognition permission (asked once). On-device recognition has no
    /// length limit; server recognition is capped at one minute per request, so the file is cut into chunks either way.
    enum Legacy {
        static func defaultLocale() -> Locale {
            let c = Locale.current
            return Locale(identifier: [c.language.languageCode?.identifier, c.region?.identifier].compactMap { $0 }.joined(separator: "_"))
        }

        static func transcribe(url: URL, language: String?) async throws -> Transcript {
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

        static func transcribe(url: URL, language: String?) async throws -> Transcript {
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
            // Results are collected before the audio is fed, or the analyzer has nowhere to put them.
            let collect = Task { () -> [TranscriptWord] in
                var words: [TranscriptWord] = []
                for try await result in transcriber.results {
                    for run in result.text.runs {
                        let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty, let range = run.audioTimeRange else { continue }
                        words.append(TranscriptWord(text: text, start: range.start.seconds, end: range.end.seconds))
                    }
                }
                return words.sorted { $0.start < $1.start }
            }
            do { try await analyzer.start(inputAudioFile: file, finishAfterFile: true) }
            catch { collect.cancel(); throw EditError.invalid("Transcription failed: \(error.localizedDescription)") }
            let words = try await collect.value
            DebugLog.event("transcribe", ["file": url.lastPathComponent, "locale": locale.identifier, "words": words.count, "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
            return Transcript(locale: locale.identifier, words: words)
        }
    }
}
