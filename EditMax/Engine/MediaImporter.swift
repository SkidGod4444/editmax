import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Probes media files and turns them into `Asset` records. No UI, no copying: assets reference the original file.
enum MediaImporter {
    static let imageDuration = 5.0

    static func probe(_ url: URL) async throws -> Asset {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) {
            var a = Asset(name: url.lastPathComponent, path: url.path, kind: .image, duration: imageDuration)
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                a.width = props[kCGImagePropertyPixelWidth] as? Int
                a.height = props[kCGImagePropertyPixelHeight] as? Int
            }
            a.bookmark = try? url.bookmarkData()
            return a
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw EditError.invalid("\(url.lastPathComponent) has no duration") }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { throw EditError.invalid("\(url.lastPathComponent) has no playable tracks") }
        var a = Asset(name: url.lastPathComponent, path: url.path,
                      kind: videoTracks.isEmpty ? .audio : .video, duration: duration)
        if let v = videoTracks.first {
            let size = try await v.load(.naturalSize)
            let transform = try await v.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            a.width = Int(abs(rect.width).rounded()); a.height = Int(abs(rect.height).rounded())
        }
        a.bookmark = try? url.bookmarkData()
        return a
    }
}
