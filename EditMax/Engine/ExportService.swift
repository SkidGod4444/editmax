import Foundation
import AVFoundation
import VideoToolbox

/// Renders a project to an MP4 using the same composition the preview plays: H.264/AAC through an export session, or
/// 10-bit HEVC (Main 10, Rec.709 tags) through an asset reader + writer for grading hand-offs.
enum ExportService {
    enum Preset: String, CaseIterable { case high = "High quality", medium = "Medium", low = "Low", hevc10 = "HEVC 10-bit" }

    struct Result: Codable { var path: String; var duration: Double; var bytes: Int; var chapters: String? = nil }   // chapters: the sidecar written beside the MP4, when asked for

    static func export(_ project: Project, to url: URL, preset: Preset = .high, progress: ((Double) -> Void)? = nil, depth: Int = 0) async throws -> Result {
        guard project.duration > 0 else { throw EditError.invalid("timeline is empty") }
        if preset == .hevc10 { return try await exportHEVC10(project, to: url, progress: progress, depth: depth) }
        try await IsolatedAudio.shared.ensureAll(project)   // voice-isolated sound is rendered per asset before the build looks for it
        let out = try await CompositionBuilder.build(project, depth: depth)   // titles, stills, color and transitions all come from the compositor

        let presetName: String = {
            switch preset {
            case .high: return AVAssetExportPresetHighestQuality
            case .medium: return AVAssetExportPreset1280x720
            case .low: return AVAssetExportPreset640x480
            case .hevc10: return AVAssetExportPresetHighestQuality   // handled above
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

    // MARK: 10-bit HEVC

    /// HEVC Main 10 at the project resolution: the composition is read through the 10-bit compositor (16-bit half-float
    /// frames), encoded by VideoToolbox as 10-bit 4:2:0 with Rec.709 tags, with the audio mix rendered to AAC.
    /// About 0.25 bits per pixel per frame (1080p30 ≈ 15 Mb/s), the usual rate for an SDR grading master.
    static func exportHEVC10(_ project: Project, to url: URL, progress: ((Double) -> Void)? = nil, depth: Int = 0) async throws -> Result {
        try await IsolatedAudio.shared.ensureAll(project)
        let out = try await CompositionBuilder.build(project, depth: depth, compositor: EditMaxCompositor10.self)
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
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let w = Int(out.renderSize.width), h = Int(out.renderSize.height), fps = max(1, project.settings.fps)
        let bitrate = Int(Double(w * h) * fps * 0.25)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String, AVVideoAverageBitRateKey: bitrate,
                                              AVVideoExpectedSourceFrameRateKey: fps, AVVideoAllowFrameReorderingKey: true],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        vin.expectsMediaDataInRealTime = false
        guard writer.canAdd(vin) else { throw EditError.invalid("HEVC Main 10 is not available on this Mac") }
        writer.add(vin)
        var ain: AVAssetWriterInput?
        if aout != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            a.expectsMediaDataInRealTime = false
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
            DebugLog.event("export-failed", ["preset": "hevc10", "description": e?.localizedDescription ?? "unknown"])
            throw EditError.invalid("10-bit export failed: \(e?.localizedDescription ?? "unknown")")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw EditError.invalid("10-bit export failed: \(writer.error?.localizedDescription ?? "writer did not complete")") }
        progress?(1)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Result(path: url.path, duration: total, bytes: bytes)
    }
}
