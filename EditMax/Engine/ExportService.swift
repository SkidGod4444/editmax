import Foundation
import AVFoundation

/// Renders a project to an MP4 (H.264/AAC) using the same composition the preview plays.
enum ExportService {
    enum Preset: String, CaseIterable { case high = "High quality", medium = "Medium", low = "Low" }

    struct Result: Codable { var path: String; var duration: Double; var bytes: Int }

    static func export(_ project: Project, to url: URL, preset: Preset = .high, progress: ((Double) -> Void)? = nil, depth: Int = 0) async throws -> Result {
        guard project.duration > 0 else { throw EditError.invalid("timeline is empty") }
        let out = try await CompositionBuilder.build(project, depth: depth)   // titles, stills, color and transitions all come from the compositor

        let presetName: String = {
            switch preset {
            case .high: return AVAssetExportPresetHighestQuality
            case .medium: return AVAssetExportPreset1280x720
            case .low: return AVAssetExportPreset640x480
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
}
