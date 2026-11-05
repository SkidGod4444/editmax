import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text with word timings, through Apple's SpeechAnalyzer (macOS 26 and newer). Nothing leaves the Mac.
/// The first run for a language may download its model; after that an 8-second clip takes well under a second.
enum Transcriber {
    static var isAvailable: Bool { if #available(macOS 26, *) { return true } else { return false } }

    static func transcribe(url: URL, language: String?) async throws -> Transcript {
        guard #available(macOS 26, *) else { throw EditError.invalid("Transcription needs macOS 26 or newer") }
        return try await Engine.transcribe(url: url, language: language)
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
