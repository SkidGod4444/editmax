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

    /// The H.264 export keeps a frame only up to 3840×2160 (either way round): above that, 4096×2160 and 6K and 8K
    /// included, it scales the picture down without saying so. High quality then writes HEVC, which keeps the project's
    /// size up to 8K and plays on any recent Mac, phone, TV and on YouTube.
    static func fitsH264(width: Int, height: Int) -> Bool { max(width, height) <= 3840 && min(width, height) <= 2160 }

    /// chapters: the sidecar written beside the file, when asked for; estimatedBytes: what the disk check counted on.
    struct Result: Codable { var path: String; var duration: Double; var bytes: Int; var chapters: String? = nil; var estimatedBytes: Int64? = nil }

    // MARK: Disk

    /// Apple's ProRes rates at 1920×1080, 29.97 fps (422 HQ 220, 422 147, 4444 330 Mb/s) as bits per pixel per frame,
    /// so they scale with the project's size and frame rate.
    static func bitsPerPixel(_ preset: Preset) -> Double? {
        let p1080 = 1920.0 * 1080 * 29.97
        switch preset {
        case .prores422hq: return 220e6 / p1080
        case .prores422: return 147e6 / p1080
        case .prores4444: return 330e6 / p1080
        case .hevc10: return 0.25
        default: return nil
        }
    }

    /// About how many bytes a master of `seconds` writes: the codec's rate for the picture plus the sound (24-bit PCM
    /// with ProRes, 192 kb/s AAC with HEVC).
    static func masterBytes(_ preset: Preset, width: Int, height: Int, fps: Double, seconds: Double) -> Int64 {
        let video = (bitsPerPixel(preset) ?? 0.25) * Double(width * height) * fps
        let audio = preset.isProRes ? 48_000.0 * 2 * 24 : 192_000
        return Int64((video + audio) * seconds / 8)
    }

    /// Free bytes of the disk holding a folder (tests put a fake one here).
    nonisolated(unsafe) static var volumeFree: @Sendable (URL) -> Int64? = realVolumeFree
    nonisolated static let realVolumeFree: @Sendable (URL) -> Int64? = { dir in
        try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    /// Free bytes on the disk that will hold `url` (its nearest folder that exists), counting a file it replaces before
    /// the export starts (not while it writes: that file is the export).
    nonisolated static func freeBytes(for url: URL, countingReplaced: Bool = true) -> Int64? {
        var dir = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 { dir = dir.deletingLastPathComponent() }
        guard let free = volumeFree(dir) else { return nil }
        let replaced = countingReplaced ? (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 : 0
        return free + replaced
    }

    /// The estimate, 10 % over, and 0.5 GB to spare. Measured on busy 1080p footage (ExportDiskTests): High, Medium and
    /// HEVC 10-bit land within 1 % of the estimate, ProRes 8 % over its nominal rate. The estimate follows the preset's
    /// rate, not the picture: a mostly still one (a fixed camera, a screen recording) writes far less (a still test clip:
    /// 83 KB against 9.6 MB), hence Export Anyway. An 18-hour 1080p export is some 80 GB.
    static func diskNeeded(estimate: Int64) -> Int64 { Int64(Double(estimate) * 1.1) + 500_000_000 }

    /// The estimate says the disk is too small. The menu's export offers Export Anyway; an agent passes
    /// `ignore_disk_estimate`. Either way the export stops by itself if the disk runs low (`DiskRanLow`).
    struct DiskTooSmall: LocalizedError, Equatable {
        let needed: Int64, free: Int64, folder: String
        var errorDescription: String? {
            String(format: "This export may need up to %.1f GB free on the disk that holds %@; %.1f GB is free. The estimate follows the preset's bitrate, so a mostly still picture (a fixed camera, a screen recording) can need far less. Export anyway (it stops and removes the unfinished file if the disk gets below 0.5 GB free), free some space, export to another disk, or pick a smaller preset.",
                   Double(needed) / 1e9, folder, Double(free) / 1e9)
        }
    }

    /// The disk got below `stopBelow` while the export wrote; the unfinished file was removed.
    struct DiskRanLow: LocalizedError, Equatable {
        let free: Int64, written: Int64, folder: String
        var errorDescription: String? {
            String(format: "Export stopped: the disk that holds %@ got down to %.1f GB free after %.1f GB of the file was written. The unfinished file was removed. Free some space or export to another disk.",
                   folder, Double(free) / 1e9, Double(written) / 1e9)
        }
    }

    static func checkDisk(estimate: Int64, free: Int64?, destination: URL) throws {
        guard let free, estimate > 0 else { return }
        let needed = diskNeeded(estimate: estimate)
        guard free < needed else { return }
        throw DiskTooSmall(needed: needed, free: free, folder: destination.deletingLastPathComponent().path)
    }

    /// While an export writes, the disk is looked at this often; below `stopBelow` free the export stops, so it never
    /// fills the Mac, whatever the estimate said.
    nonisolated(unsafe) static var watchInterval: Duration = .seconds(1)
    nonisolated static let stopBelow: Int64 = 500_000_000

    final class LowDisk: @unchecked Sendable {
        private let lock = NSLock(); private var seen: Int64?
        var free: Int64? { lock.lock(); defer { lock.unlock() }; return seen }
        func trip(_ f: Int64) { lock.lock(); seen = seen ?? f; lock.unlock() }
    }

    /// Calls `stop` once when the disk holding `url` gets below `stopBelow`.
    nonisolated static func watchDisk(_ url: URL, low: LowDisk, stop: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let every = watchInterval
        return Task.detached(priority: .userInitiated) {   // the pumps read `low` under its lock: no lower-QoS holder
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { return }
                if let f = freeBytes(for: url, countingReplaced: false), f < stopBelow { low.trip(f); stop(); return }
            }
        }
    }

    /// Removes the unfinished file and says how far it got.
    static func ranLow(_ url: URL, free: Int64, preset: Preset) -> DiskRanLow {
        let written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        try? FileManager.default.removeItem(at: url)
        DebugLog.event("export-disk-low", ["preset": preset.rawValue, "free": free, "written": written])
        return DiskRanLow(free: free, written: written, folder: url.deletingLastPathComponent().path)
    }

    /// `ignoreDiskEstimate`: export even when the estimate says the disk is too small (it still stops if the disk runs low).
    static func export(_ project: Project, to url: URL, preset: Preset = .high, ignoreDiskEstimate: Bool = false, progress: ((Double) -> Void)? = nil, depth: Int = 0) async throws -> Result {
        guard depth == 0 else { return try await exportNow(project, to: url, preset: preset, ignoreDiskEstimate: ignoreDiskEstimate, progress: progress, depth: depth) }
        // Crash reports and usage (Telemetry): the preset and coarse lengths, never the file.
        let started = Date(), name = preset.rawValue, length = Telemetry.lengthBucket(project.duration)
        do {
            let r = try await exportNow(project, to: url, preset: preset, ignoreDiskEstimate: ignoreDiskEstimate, progress: progress, depth: depth)
            let took = Telemetry.lengthBucket(Date().timeIntervalSince(started))
            await MainActor.run { Telemetry.shared.capture(.exportFinished, ["preset": name, "length": length, "took": took]) }
            return r
        } catch {
            // The person's own limits (a full disk, an offline drive, an empty timeline, Cancel) are counted, not reported.
            let theirs = error is CancellationError || error is DiskTooSmall || error is DiskRanLow || error is EditError
            let reason = theirs ? String(describing: type(of: error)) : (error as NSError).domain
            await MainActor.run {
                Telemetry.shared.capture(.exportFailed, ["preset": name, "length": length, "reason": reason])
                if !theirs { Telemetry.shared.failed(error, at: "export") }
            }
            throw error
        }
    }

    private static func exportNow(_ project: Project, to url: URL, preset: Preset, ignoreDiskEstimate: Bool, progress: ((Double) -> Void)?, depth: Int) async throws -> Result {
        guard project.duration > 0 else { throw EditError.invalid("timeline is empty") }
        BusyWork.begin(BusyWork.export); defer { BusyWork.end(BusyWork.export) }   // the update popup waits for it
        try Relink.requireOnline(project)   // names the drive to plug in, before any render starts
        if preset.isMaster { return try await exportMaster(project, to: url, preset: preset, ignoreDiskEstimate: ignoreDiskEstimate, progress: progress, depth: depth) }
        try await IsolatedAudio.shared.ensureAll(project)   // voice-isolated sound is rendered per asset before the build looks for it
        try await InterpolatedVideo.shared.ensureAll(project)   // smooth slow motion, likewise (FrameInterpolation.swift)
        let out = try await CompositionBuilder.build(project, depth: depth)   // titles, stills, color and transitions all come from the compositor
        defer { withExtendedLifetime(out) {} }   // its source assets must outlive the render (`Output.sources`)

        let presetName: String = {
            switch preset {
            case .high: return Self.fitsH264(width: project.settings.width, height: project.settings.height) ? AVAssetExportPresetHighestQuality : AVAssetExportPresetHEVCHighestQuality
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
        let estimate = (try? await session.estimatedOutputFileLengthInBytes) ?? 0
        if !ignoreDiskEstimate { try checkDisk(estimate: estimate, free: freeBytes(for: url), destination: url) }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let poll = Task {
            while !Task.isCancelled {
                progress?(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poll.cancel() }
        let job = Task { try await session.export(to: url, as: .mp4) }
        let low = LowDisk()
        let watch = Self.watchDisk(url, low: low) { job.cancel() }
        defer { watch.cancel() }
        do { try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() } } catch {
            if let f = low.free { throw Self.ranLow(url, free: f, preset: preset) }
            let ns = error as NSError
            DebugLog.event("export-failed", ["code": ns.code, "domain": ns.domain, "description": ns.localizedDescription, "reason": ns.localizedFailureReason ?? "", "info": "\(ns.userInfo)".prefix(600).description])
            throw EditError.invalid("Export failed (\(ns.domain) \(ns.code)): \(ns.localizedDescription). \(ns.localizedFailureReason ?? "")")
        }
        progress?(1)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        DebugLog.event("export-size", ["preset": preset.rawValue, "estimated": estimate, "bytes": bytes, "seconds": out.duration.seconds])
        return Result(path: url.path, duration: out.duration.seconds, bytes: bytes, estimatedBytes: estimate > 0 ? estimate : nil)
    }

    // MARK: Masters

    /// A master at the project resolution: the composition is read through the 10-bit compositor (16-bit half-float
    /// frames) and encoded by VideoToolbox with Rec.709 tags.
    /// - HEVC Main 10: 10-bit 4:2:0 in an MP4 at about 0.25 bits per pixel per frame (1080p30 ≈ 15 Mb/s), the usual rate
    ///   for an SDR grading master, with AAC sound.
    /// - ProRes 422 HQ / 422 / 4444: 10-bit 4:2:2 (12-bit 4:4:4 for 4444) at Apple's fixed ProRes rates, in a QuickTime
    ///   movie with 24-bit 48 kHz stereo PCM sound, the files Resolve, Final Cut and Premiere edit and grade natively.
    static func exportMaster(_ project: Project, to url: URL, preset: Preset, ignoreDiskEstimate: Bool = false, progress: ((Double) -> Void)? = nil, depth: Int = 0) async throws -> Result {
        BusyWork.begin(BusyWork.export); defer { BusyWork.end(BusyWork.export) }
        try Relink.requireOnline(project)
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

        let w = Int(out.renderSize.width), h = Int(out.renderSize.height), fps = max(1, project.settings.fps)
        let estimate = masterBytes(preset, width: w, height: h, fps: fps, seconds: out.duration.seconds)
        if !ignoreDiskEstimate { try checkDisk(estimate: estimate, free: freeBytes(for: url), destination: url) }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: preset.fileType)
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
        let low = LowDisk()
        let watch = Self.watchDisk(url, low: low) {}   // the pumps below look at `low` between frames
        defer { watch.cancel() }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String, report: Bool) {
                group.enter()
                var finished = false
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "io.openhorizon.editmax.export.\(label)")) {
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData {
                        guard low.free == nil, let sb = output.copyNextSampleBuffer() else { finished = true; input.markAsFinished(); group.leave(); return }
                        if !input.append(sb) { finished = true; input.markAsFinished(); group.leave(); return }
                        if report, total > 0 { progress?(min(0.99, CMSampleBufferGetPresentationTimeStamp(sb).seconds / total)) }
                    }
                }
            }
            pump(vin, vout, label: "video", report: true)
            if let ain, let aout { pump(ain, aout, label: "audio", report: false) }
            group.notify(queue: .global()) { cont.resume() }
        }
        if let f = low.free {
            reader.cancelReading(); writer.cancelWriting()
            throw Self.ranLow(url, free: f, preset: preset)
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
        DebugLog.event("export-size", ["preset": preset.rawValue, "estimated": estimate, "bytes": bytes, "seconds": total])
        return Result(path: url.path, duration: total, bytes: bytes, estimatedBytes: estimate)
    }
}
