import Foundation
import AVFoundation
import VideoToolbox

/// Renders a project using the same composition the preview plays: H.264/AAC to an MP4 through an export session, or a
/// master through an asset reader + writer for grading hand-offs: 10-bit HEVC (Main 10) in an MP4, or Apple ProRes in a
/// QuickTime movie with 24-bit PCM sound. Masters carry Rec.709 tags and everything EditMax renders (grades, looks,
/// titles, captions, the mixed and processed sound) baked in.
enum ExportService {
    /// ProRes 422 HQ comes before 422 and 4444 so a bare "prores" picks it.
    enum Preset: String, CaseIterable {
        case high = "High quality", medium = "Medium", low = "Low", hevc10 = "HEVC 10-bit"
        case prores422hq = "ProRes 422 HQ", prores422 = "ProRes 422", prores4444 = "ProRes 4444"

        var isProRes: Bool { self == .prores422hq || self == .prores422 || self == .prores4444 }
        /// Rendered through the reader + writer at the project resolution, not an export session.
        var isMaster: Bool { self == .hevc10 || isProRes }
        var fileExtension: String { isProRes ? "mov" : "mp4" }
        var fileType: AVFileType { isProRes ? .mov : .mp4 }
        var codec: AVVideoCodecType {
            switch self {
            case .prores422hq: return .proRes422HQ
            case .prores422: return .proRes422
            case .prores4444: return .proRes4444
            default: return .hevc
            }
        }
    }

    struct Result: Codable { var path: String; var duration: Double; var bytes: Int; var chapters: String? = nil }   // chapters: the sidecar written beside the file, when asked for

    static func export(_ project: Project, to url: URL, preset: Preset = .high, progress: ((Double) -> Void)? = nil, depth: Int = 0) async throws -> Result {
        guard project.duration > 0 else { throw EditError.invalid("timeline is empty") }
        if preset.isMaster { return try await exportMaster(project, to: url, preset: preset, progress: progress, depth: depth) }
        try await IsolatedAudio.shared.ensureAll(project)   // voice-isolated sound is rendered per asset before the build looks for it
        try await InterpolatedVideo.shared.ensureAll(project)   // smooth slow motion, likewise (FrameInterpolation.swift)
        let out = try await CompositionBuilder.build(project, depth: depth)   // titles, stills, color and transitions all come from the compositor
        defer { withExtendedLifetime(out) {} }   // its source assets must outlive the render (`Output.sources`)

        let presetName: String = {
            switch preset {
            case .high: return AVAssetExportPresetHighestQuality
            case .medium: return AVAssetExportPreset1280x720
            case .low: return AVAssetExportPreset640x480
            default: return AVAssetExportPresetHighestQuality   // masters are handled above
            }
        }()
        guard let session = AVAssetExportSession(asset: out.composition, presetName: presetName) else { throw EditError.invalid("no export session for preset") }
        session.videoComposition = out.videoComposition
        session.audioMix = out.audioMix
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(start: .zero, duration: out.duration)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let poll = Task {
            while !Task.isCancelled {
                progress?(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poll.cancel() }
        do { try await session.export(to: url, as: .mp4) } catch {
            let ns = error as NSError
            DebugLog.event("export-failed", ["code": ns.code, "domain": ns.domain, "description": ns.localizedDescription, "reason": ns.localizedFailureReason ?? "", "info": "\(ns.userInfo)".prefix(600).description])
            throw EditError.invalid("Export failed (\(ns.domain) \(ns.code)): \(ns.localizedDescription). \(ns.localizedFailureReason ?? "")")
        }
        progress?(1)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Result(path: url.path, duration: out.duration.seconds, bytes: bytes)
    }

    // MARK: Masters

    /// A master at the project resolution: the composition is read through the 10-bit compositor (16-bit half-float
    /// frames) and encoded by VideoToolbox with Rec.709 tags.
    /// - HEVC Main 10: 10-bit 4:2:0 in an MP4 at about 0.25 bits per pixel per frame (1080p30 ≈ 15 Mb/s), the usual rate
    ///   for an SDR grading master, with AAC sound.
    /// - ProRes 422 HQ / 422 / 4444: 10-bit 4:2:2 (12-bit 4:4:4 for 4444) at Apple's fixed ProRes rates, in a QuickTime
    ///   movie with 24-bit 48 kHz stereo PCM sound, the files Resolve, Final Cut and Premiere edit and grade natively.
    static func exportMaster(_ project: Project, to url: URL, preset: Preset, progress: ((Double) -> Void)? = nil, depth: Int = 0) async throws -> Result {
        try await IsolatedAudio.shared.ensureAll(project)
        try await InterpolatedVideo.shared.ensureAll(project)
        let out = try await CompositionBuilder.build(project, depth: depth, compositor: EditMaxCompositor10.self)
        defer { withExtendedLifetime(out) {} }   // its source assets must outlive the render (`Output.sources`)
        let reader = try AVAssetReader(asset: out.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: out.duration)
        let videoTracks = try await out.composition.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw EditError.invalid("nothing to render") }
        let vout = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
        vout.videoComposition = out.videoComposition
        vout.alwaysCopiesSampleData = false
        guard reader.canAdd(vout) else { throw EditError.invalid("cannot read the video composition") }
        reader.add(vout)
        // The builder drops empty audio tracks, so a silent timeline has none; the reader rejects an output with no tracks.
        let audioTracks = try await out.composition.loadTracks(withMediaType: .audio)
        var aout: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let a = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                                                                         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
            a.audioMix = out.audioMix
            a.alwaysCopiesSampleData = false
            if reader.canAdd(a) { reader.add(a); aout = a }
        }

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: preset.fileType)
        let w = Int(out.renderSize.width), h = Int(out.renderSize.height), fps = max(1, project.settings.fps)
        var video: [String: Any] = [
            AVVideoCodecKey: preset.codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
        if preset == .hevc10 {   // ProRes takes no compression properties: its rate is fixed per flavour
            video[AVVideoCompressionPropertiesKey] = [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String, AVVideoAverageBitRateKey: Int(Double(w * h) * fps * 0.25),
                                                      AVVideoExpectedSourceFrameRateKey: fps, AVVideoAllowFrameReorderingKey: true]
        }
        ColorManagement.tagMaster(&video, preset: preset, color: project.settings.color, writer: writer)   // HDR projects: Rec.2020 HLG / PQ
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        vin.expectsMediaDataInRealTime = false
        guard writer.canAdd(vin) else { throw EditError.invalid("\(preset.rawValue) is not available on this Mac") }
        writer.add(vin)
        var ain: AVAssetWriterInput?
        if aout != nil {
            let settings: [String: Any] = preset.isProRes
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
                   AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            a.expectsMediaDataInRealTime = false
            guard writer.canAdd(a) else { throw EditError.invalid("cannot add the sound to a \(preset.rawValue) file") }
            writer.add(a); ain = a
        }
        guard reader.startReading() else { throw EditError.invalid("could not start reading: \(reader.error?.localizedDescription ?? "unknown")") }
        guard writer.startWriting() else { reader.cancelReading(); throw EditError.invalid("could not start writing: \(writer.error?.localizedDescription ?? "unknown")") }
        writer.startSession(atSourceTime: .zero)

        let total = out.duration.seconds
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String, report: Bool) {
                group.enter()
                var finished = false
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "io.openhorizon.editmax.export.\(label)")) {
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData {
                        guard let sb = output.copyNextSampleBuffer() else { finished = true; input.markAsFinished(); group.leave(); return }
                        if !input.append(sb) { finished = true; input.markAsFinished(); group.leave(); return }
                        if report, total > 0 { progress?(min(0.99, CMSampleBufferGetPresentationTimeStamp(sb).seconds / total)) }
                    }
                }
            }
            pump(vin, vout, label: "video", report: true)
            if let ain, let aout { pump(ain, aout, label: "audio", report: false) }
            group.notify(queue: .global()) { cont.resume() }
        }
        if reader.status == .failed || writer.status == .failed {
            let e = reader.error ?? writer.error
            reader.cancelReading(); writer.cancelWriting()
            DebugLog.event("export-failed", ["preset": preset.rawValue, "description": e?.localizedDescription ?? "unknown"])
            throw EditError.invalid("\(preset.rawValue) export failed: \(e?.localizedDescription ?? "unknown")")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw EditError.invalid("\(preset.rawValue) export failed: \(writer.error?.localizedDescription ?? "writer did not complete")") }
        progress?(1)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Result(path: url.path, duration: total, bytes: bytes)
    }
}
