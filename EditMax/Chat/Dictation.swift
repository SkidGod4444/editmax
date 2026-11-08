import Foundation
import AVFoundation
import Speech

/// Speaking to the agent instead of typing: the microphone, recognized on this Mac as you talk, written into the chat
/// field. Nothing is sent by itself: the agent edits the project on send, and the last words can still change while
/// the recognizer settles, so the person reads it and sends (Return, or the send button, which stops listening first).
/// macOS 26+: SpeechAnalyzer's DictationTranscriber (punctuation, on device). macOS 15: SFSpeechRecognizer, on device
/// when the Mac has the language.
@MainActor final class Dictation: ObservableObject {
    enum State: Equatable { case idle, preparing, listening, finishing }
    @Published private(set) var state: State = .idle
    /// The field's text: what was there when listening started, then what was heard.
    @Published private(set) var text = ""
    /// Why the last attempt stopped, in plain words (no permission, no microphone, no model for the language).
    @Published var problem: String?
    /// The microphone level for the button's pulse, published apart so the chat does not redraw ten times a second.
    let level = MicLevel()
    /// Gets the field's text each time it changes (ChatSession writes it into the composer).
    var onText: ((String) -> Void)?

    private var base = ""
    private var finalized = ""
    private var volatile = ""
    private var engine: DictationEngine?
    private var startTask: Task<Void, Never>?

    var isActive: Bool { state != .idle }

    /// Starts listening, keeping `current` (what is typed already) in front of what is heard.
    func start(into current: String, hints: [String] = []) {
        guard state == .idle else { return }
        base = current; finalized = ""; volatile = ""; text = current; problem = nil
        state = .preparing
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await Self.microphoneAllowed() else {
                    throw EditError.invalid("EditMax needs the microphone to hear you. Allow it in System Settings → Privacy & Security → Microphone.")
                }
                let e = try await Self.makeEngine()
                self.engine = e
                try await e.start(
                    hints: hints,
                    onText: { [weak self] heard, final in self?.heard(heard, final: final) },
                    onLevel: { [weak self] l in self?.level.value = l })
                guard self.state == .preparing else { await e.stop(); return }   // stopped while the model loaded
                self.state = .listening
                DebugLog.event("dictation-start", ["engine": e.name])
            } catch {
                self.problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DebugLog.event("dictation-failed", ["error": self.problem ?? ""])
                await self.engine?.cancel(); self.engine = nil
                self.state = .idle
            }
        }
    }

    /// Stops listening and waits for the last words to settle. Returns the field's final text.
    @discardableResult
    func finish() async -> String {
        guard state != .idle else { return text }
        // A second Return or click while the last words settle waits for that same finish, never stops the engine twice.
        if state == .finishing { while state == .finishing { try? await Task.sleep(for: .milliseconds(30)) }; return text }
        if state == .preparing { startTask?.cancel(); await engine?.cancel(); engine = nil; level.value = 0; state = .idle; return text }
        state = .finishing
        await engine?.stop()
        engine = nil
        volatile = ""   // anything still unsettled after the final pass is dropped, as Dictation does
        text = Self.merge(base: base, heard: finalized)
        onText?(text)
        level.value = 0
        state = .idle
        DebugLog.event("dictation-stop", ["chars": text.count - base.count])
        return text
    }

    func toggle(current: String, hints: [String] = []) {
        if state == .idle { start(into: current, hints: hints) } else { Task { await finish() } }
    }

    private func heard(_ s: String, final: Bool) {
        guard state == .listening || state == .preparing || state == .finishing else { return }
        if final { finalized = Self.join(finalized, s); volatile = "" } else { volatile = s }
        text = Self.merge(base: base, heard: Self.join(finalized, volatile))
        onText?(text)
    }

    // MARK: Text

    /// Two pieces of speech as one: a space between them unless one side already has it or the next starts with punctuation.
    nonisolated static func join(_ a: String, _ b: String) -> String {
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return a }
        guard !a.isEmpty else { return b }
        if a.last!.isWhitespace || ".,!?;:)…".contains(b.first!) { return a + b }
        return a + " " + b
    }

    /// What was typed before listening, then what was heard, with editing words the recognizer gets wrong put right.
    nonisolated static func merge(base: String, heard: String) -> String { join(base, corrected(heard)) }

    /// Words the recognizer hears as something else in this trade. Narrow on purpose: "YT" only before a word that
    /// says it is the platform ("my Whitey channel" was "my YT channel"), so the same sound elsewhere stays as heard.
    nonisolated static let corrections: [(pattern: String, with: String)] = [
        (#"\b(?:whitey|why ?tee|why t|wide t|y\.? ?t\.?)(?=\s+(?:channel|channels|video|videos|short|shorts|thumbnail|thumbnails|title|upload|uploads|audience|community|studio)\b)"#, "YT"),
        (#"\byou tube\b"#, "YouTube"),
        (#"\btick ?tock\b"#, "TikTok"),
        (#"\bcap cut\b"#, "CapCut"),
        (#"\bb[ -]roll\b"#, "B-roll"),
        (#"\bluts?\b"#, "LUT"),
        (#"\blufs\b"#, "LUFS"),
        (#"\bd[ -]log\b"#, "D-Log"),
    ]

    nonisolated static func corrected(_ s: String) -> String {
        var s = s
        for c in corrections { s = s.replacingOccurrences(of: c.pattern, with: c.with, options: [.regularExpression, .caseInsensitive]) }
        return s
    }

    /// Words to listen for: the trade's (platforms, formats, tools) and this project's own names (files, tracks,
    /// titles), so "YT", a clip called "KL-drone" or "B-roll" come out as written. At most 100, as the recognizers take.
    static func hints(for project: Project?) -> [String] {
        var words = ["YT", "YouTube", "YouTube Shorts", "Shorts", "Reels", "Instagram Reels", "TikTok", "EditMax", "B-roll", "J-cut", "L-cut",
                     "LUT", "LUFS", "D-Log", "D-Log M", "Rec. 709", "ProRes", "HEVC", "H.264", "4K", "9:16", "16:9", "keyframe",
                     "cross dissolve", "lower third", "color grade", "auto-reframe", "jump cut", "speed ramp", "slow motion",
                     "voiceover", "timeline", "playhead", "cinematic", "vlog", "GRWM", "POV", "hook", "captions", "CapCut",
                     "DaVinci Resolve", "Final Cut"]
        if let project {
            words += project.tracks.map(\.name).filter { !$0.isEmpty }
            words += project.assets.prefix(40).map { ($0.name as NSString).deletingPathExtension }
            words += project.texts.map(\.text).filter { $0.split(separator: " ").count <= 4 }.prefix(20)
        }
        var seen = Set<String>()
        return Array(words.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(100))
    }

    // MARK: Engines

    private static func makeEngine() async throws -> DictationEngine {
        if #available(macOS 26, *), ProcessInfo.processInfo.environment["EDITMAX_LEGACY_SPEECH"] != "1",
           let locale = await DictationTranscriber.supportedLocale(equivalentTo: Transcriber.Legacy.defaultLocale()) {
            return AnalyzerDictation(locale: locale)
        }
        return try LegacyDictation()
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// The microphone's level (0–1), smoothed, for the listening button.
@MainActor final class MicLevel: ObservableObject {
    @Published var value: Float = 0
}

/// One way of turning the microphone into text. Callbacks arrive on the main actor.
@MainActor protocol DictationEngine: AnyObject {
    var name: String { get }
    /// `hints`: words likely in the speech (the recognizer leans toward them).
    func start(hints: [String], onText: @escaping @MainActor (String, Bool) -> Void, onLevel: @escaping @MainActor (Float) -> Void) async throws
    /// Stops the microphone and waits for the final words.
    func stop() async
    /// Stops at once; nothing more arrives.
    func cancel() async
}

/// The microphone tap both engines share: the input's own format, a level reading, each buffer handed on.
enum MicTap {
    /// RMS of the first channel as 0–1 on a -50…0 dBFS scale.
    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let d = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += d[i] * d[i] }
        let db = 10 * log10(max(sum / Float(buffer.frameLength), 1e-10))
        return max(0, min(1, (db + 50) / 50))
    }

    static func inputFormat(_ engine: AVAudioEngine) throws -> AVAudioFormat {
        let f = engine.inputNode.outputFormat(forBus: 0)
        guard f.sampleRate > 0, f.channelCount > 0 else { throw EditError.invalid("No microphone is connected.") }
        return f
    }
}

@available(macOS 26, *)
@MainActor final class AnalyzerDictation: DictationEngine {
    let name = "speech-analyzer"
    private let locale: Locale
    private let audio = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    init(locale: Locale) { self.locale = locale }

    func start(hints: [String], onText: @escaping @MainActor (String, Bool) -> Void, onLevel: @escaping @MainActor (Float) -> Void) async throws {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            DebugLog.event("dictation-download", ["locale": locale.identifier])
            try await request.downloadAndInstall()
        }
        let micFormat = try MicTap.inputFormat(audio)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: micFormat) else {
            throw EditError.invalid("Speech recognition has no audio format for this microphone.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        if !hints.isEmpty {   // "YT", the project's clip names: heard as written, not as "Whitey"
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            do { try await analyzer.setContext(context) } catch { DebugLog.event("dictation-hints-failed", ["error": error.localizedDescription]) }
        }
        // Results are read before audio arrives, or the analyzer has nowhere to put them.
        results = Task {
            do { for try await r in transcriber.results { onText(String(r.text.characters), r.isFinal) } }
            catch { DebugLog.event("dictation-results-error", ["error": error.localizedDescription]) }
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        input = continuation
        let converter = micFormat == format ? nil : AVAudioConverter(from: micFormat, to: format)
        audio.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            let l = MicTap.level(buffer)
            Task { @MainActor in onLevel(l) }
            guard let converter else { continuation.yield(AnalyzerInput(buffer: buffer)); return }
            let ratio = format.sampleRate / micFormat.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
        }
        audio.prepare()
        try audio.start()
        try await analyzer.start(inputSequence: stream)
    }

    func stop() async {
        audio.inputNode.removeTap(onBus: 0); audio.stop()
        input?.finish(); input = nil
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() }
        catch { DebugLog.event("dictation-finish-error", ["error": error.localizedDescription]) }
        // The final words arrive within a moment; never leave the composer stuck in "finishing" on them.
        if let results {
            let settled = await withTaskGroup(of: Bool.self) { g in
                g.addTask { await results.value; return true }
                g.addTask { try? await Task.sleep(for: .seconds(2)); return false }
                let first = await g.next() ?? false
                g.cancelAll()
                return first
            }
            if !settled { results.cancel(); DebugLog.event("dictation-finish-timeout") }
        }
        analyzer = nil; results = nil
    }

    func cancel() async {
        audio.inputNode.removeTap(onBus: 0); audio.stop()
        input?.finish(); input = nil
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
        analyzer = nil; results = nil
    }
}

/// macOS 15: SFSpeechRecognizer on the microphone. Its partial results are the whole utterance so far, not pieces.
@MainActor final class LegacyDictation: DictationEngine {
    let name = "legacy"
    private let recognizer: SFSpeechRecognizer
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalWaiter: CheckedContinuation<Void, Never>?

    init() throws {
        guard let r = SFSpeechRecognizer(locale: Transcriber.Legacy.defaultLocale()) ?? SFSpeechRecognizer() else {
            throw EditError.invalid("Speech recognition is not available for this Mac's language.")
        }
        recognizer = r
    }

    func start(hints: [String], onText: @escaping @MainActor (String, Bool) -> Void, onLevel: @escaping @MainActor (Float) -> Void) async throws {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else {
            throw EditError.invalid("EditMax needs permission for speech recognition. Allow it in System Settings → Privacy & Security → Speech Recognition.")
        }
        guard recognizer.isAvailable else { throw EditError.invalid("Speech recognition is not available right now.") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.contextualStrings = hints
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true || error != nil
            Task { @MainActor in
                if let text { onText(text, final) }
                if final, let self, let w = self.finalWaiter { self.finalWaiter = nil; w.resume() }
            }
        }
        let micFormat = try MicTap.inputFormat(audio)
        audio.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            let l = MicTap.level(buffer)
            Task { @MainActor in onLevel(l) }
            request.append(buffer)
        }
        audio.prepare()
        try audio.start()
    }

    func stop() async {
        audio.inputNode.removeTap(onBus: 0); audio.stop()
        request?.endAudio()
        // The final result follows endAudio within a moment; never hang the chat on it.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finalWaiter = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if let w = self?.finalWaiter { self?.finalWaiter = nil; w.resume() }
            }
        }
        task?.cancel(); task = nil; request = nil
    }

    func cancel() async {
        audio.inputNode.removeTap(onBus: 0); audio.stop()
        task?.cancel(); task = nil; request = nil
        if let w = finalWaiter { finalWaiter = nil; w.resume() }
    }
}
