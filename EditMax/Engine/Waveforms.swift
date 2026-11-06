import Foundation
import AVFoundation
import CryptoKit
import SwiftUI

/// Audio peaks for the timeline, 100 per second of source audio (max absolute sample per 10 ms, 0...1).
/// Extracted once per file in the background and cached in memory and on disk, keyed by path, size and modification date.
@MainActor
final class WaveformStore: ObservableObject {
    static let shared = WaveformStore()
    static let peaksPerSecond = 100

    @Published private(set) var peaks: [UUID: [Float]] = [:]
    private var inFlight: Set<UUID> = []

    func request(_ asset: Asset) {
        guard asset.kind != .image, peaks[asset.id] == nil, !inFlight.contains(asset.id) else { return }
        inFlight.insert(asset.id)
        let url = asset.url, id = asset.id
        Task.detached(priority: .utility) {
            let result = (try? await WaveformExtractor.peaks(for: url)) ?? []
            await MainActor.run { self.peaks[id] = result; self.inFlight.remove(id) }
        }
    }
    /// Reads the asset's file again (after a relink pointed it at another file).
    func refresh(_ asset: Asset) { peaks[asset.id] = nil; request(asset) }
}

enum WaveformExtractor {
    private static let rate = 8000.0
    private static var cacheDirectory: URL { CodemaxInstaller.supportDirectory.appendingPathComponent("waveforms") }

    static func peaks(for url: URL) async throws -> [Float] {
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let stamp = "\(url.path)|\(attrs[.size] ?? 0)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let key = SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined()
        let cacheFile = cacheDirectory.appendingPathComponent("\(key).f32")
        if let data = try? Data(contentsOf: cacheFile), !data.isEmpty {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let started = Date()
        let result = try await extract(url)
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? result.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: cacheFile)
        DebugLog.event("waveform", ["file": url.lastPathComponent, "peaks": result.count, "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
        return result
    }

    /// Decodes the first audio track as 8 kHz mono 16-bit PCM and keeps the loudest sample of every 10 ms.
    private static func extract(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError.invalid("cannot read audio") }
        let bucket = Int(rate) / WaveformStore.peaksPerSecond
        var peaks: [Float] = []
        var current: Int16 = 0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0, pointer: UnsafeMutablePointer<CChar>? = nil
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for i in 0..<(length / 2) {
                    let v = samples[i] == Int16.min ? Int16.max : abs(samples[i])
                    if v > current { current = v }
                    count += 1
                    if count == bucket { peaks.append(Float(current) / 32767); current = 0; count = 0 }
                }
            }
        }
        if count > 0 { peaks.append(Float(current) / 32767) }
        if reader.status == .failed { throw reader.error ?? EditError.invalid("audio read failed") }
        // Quiet recordings still get a visible shape: scale so the loudest peak reaches the top, but never boost noise past 4x.
        let top = peaks.max() ?? 1
        if top > 0, top < 1 { let gain = min(4, 1 / top); return peaks.map { min(1, $0 * gain) } }
        return peaks
    }
}

/// Peaks of one clip's source range as a filled envelope, mirrored around the middle and lightly smoothed.
/// Draws nothing while the peaks are still being extracted.
struct WaveformView: View, Equatable {
    let peaks: [Float]
    let sourceIn: Double
    let sourceOut: Double
    var color: Color = .white.opacity(0.7)
    static func == (a: WaveformView, b: WaveformView) -> Bool { a.peaks.count == b.peaks.count && a.sourceIn == b.sourceIn && a.sourceOut == b.sourceOut && a.color == b.color }

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty, size.width > 0, sourceOut > sourceIn else { return }
            let pps = Double(WaveformStore.peaksPerSecond)
            let step: CGFloat = 1
            let columns = Int(size.width / step)
            guard columns > 1 else { return }
            // Loudest peak under each column, then a 3-column average so the shape reads as audio, not noise.
            var raw = [CGFloat](repeating: 0, count: columns)
            for c in 0..<columns {
                let t0 = sourceIn + Double(c) / Double(columns) * (sourceOut - sourceIn)
                let t1 = sourceIn + Double(c + 1) / Double(columns) * (sourceOut - sourceIn)
                let i0 = max(0, Int(t0 * pps)), i1 = min(peaks.count, max(i0 + 1, Int(t1 * pps)))
                if i0 < peaks.count { raw[c] = CGFloat(peaks[i0..<i1].max() ?? 0) }
            }
            let mid = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: 0, y: mid))
            for c in 0..<columns {
                let v = (raw[max(0, c - 1)] + raw[c] + raw[min(columns - 1, c + 1)]) / 3
                path.addLine(to: CGPoint(x: CGFloat(c) * step, y: mid - max(0.5, v * mid)))
            }
            for c in stride(from: columns - 1, through: 0, by: -1) {
                let v = (raw[max(0, c - 1)] + raw[c] + raw[min(columns - 1, c + 1)]) / 3
                path.addLine(to: CGPoint(x: CGFloat(c) * step, y: mid + max(0.5, v * mid)))
            }
            path.closeSubpath()
            ctx.fill(path, with: .color(color))
        }
    }
}
