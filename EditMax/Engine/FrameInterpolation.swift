import Foundation
import AVFoundation
import CoreImage
import VideoToolbox

/// How a clip slower than 1× makes its in-between frames. Off: each source frame is shown several times (today's
/// behaviour). Blend: a cross-fade of the two neighbouring frames. Optical flow: frames synthesized along the motion
/// (VideoToolbox frame-rate conversion, macOS 15.4+ on supported Macs; blend where it is not available).
enum SlowMotionMode: String, Codable, CaseIterable { case off, blend, opticalFlow = "optical_flow" }

// MARK: - Smooth slow motion
//
// A slow clip is rendered once into the cache (Application Support/EditMax/interpolated): its source range, at
// `timeline fps / speed` frames per source second, so that playing it at the clip's speed shows a new frame every
// timeline frame. File time 0 is the clip's source in. The builder uses the file in place of the asset's picture when
// it is ready (the sound always comes from the original); until then the clip plays as before and the render is
// started in the background. Keys include the asset's content hash, the range, the frame rate and the mode, so a trim
// or speed change asks for a new render and never plays a stale one.

@MainActor
final class InterpolatedVideo: ObservableObject {
    static let shared = InterpolatedVideo()
    @Published private(set) var rendering: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var failed: [String: String] = [:]
    /// Bumped when a render becomes ready, so the preview rebuilds with it.
    @Published private(set) var version = 0
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var scheduled: [UUID: Task<Void, Never>] = [:]

    nonisolated static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax/interpolated")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Optical flow can run here: VTFrameRateConversion exists, this Mac supports it, and it has not failed here.
    nonisolated static var flowAvailable: Bool {
        guard flowFailure == nil else { return false }
        if #available(macOS 15.4, *) { return VTFrameRateConversionConfiguration.isSupported }
        return false
    }
    /// Why optical flow failed on this Mac although it says it supports it (a virtual Mac: VTFrameProcessorErrorDomain
    /// -19730). Renders blend from then on, until EditMax quits.
    nonisolated(unsafe) static var flowFailure: String?
    /// Tests: optical flow fails the way it does on a virtual Mac.
    nonisolated(unsafe) static var failFlowForTesting = false

    /// Optical flow itself failed (not the source or the disk): the render is done again with blend.
    struct FlowFailed: LocalizedError {
        let reason: String
        var errorDescription: String? { "optical flow failed on this Mac (\(reason))" }
        init(_ error: Error) {
            let ns = error as NSError
            reason = ns.domain.hasPrefix("VTFrameProcessor") ? "\(ns.domain) \(ns.code)" : error.localizedDescription
        }
    }
    /// The method a mode really renders with on this Mac.
    nonisolated static func method(_ mode: SlowMotionMode) -> SlowMotionMode { mode == .opticalFlow && !flowAvailable ? .blend : mode }

    struct Job: Sendable, Equatable {
        var source: URL, sourceIn: Double, sourceOut: Double, fps: Double, method: SlowMotionMode, key: String
        var url: URL { InterpolatedVideo.directory.appendingPathComponent(key + ".mov") }
    }

    /// The slowest speed the clip plays at (keyframed ramps included).
    nonisolated static func slowest(_ c: Clip) -> Double {
        let ks = c.keyframes(.speed)
        return ks.isEmpty ? c.speed : min(c.speed, ks.map(\.value).min() ?? c.speed)
    }

    /// The render a clip needs, or nil when it needs none (mode off, not slower than 1×, not a video file).
    nonisolated static func job(_ c: Clip, _ a: Asset, fps: Double) -> Job? {
        guard c.smoothSlowMotion != .off, a.kind == .video, a.sequenceID == nil, c.multicam == nil else { return nil }
        let s = slowest(c)
        guard s > 0.01, s < 0.999 else { return nil }
        let out = min(240, (fps / s).rounded())
        let sIn = c.sourceIn, sOut = min(a.duration, c.sourceIn + c.sourceOffset(at: c.duration))
        guard sOut - sIn > 0.02 else { return nil }
        let m = method(c.smoothSlowMotion)
        let key = "\(ProxyStore.key(for: a))-\(Int((sIn * 1000).rounded()))-\(Int((sOut * 1000).rounded()))-\(Int(out))-\(m.rawValue)"
        return Job(source: a.url, sourceIn: sIn, sourceOut: sOut, fps: out, method: m, key: key)
    }

    /// The rendered file for a clip when the cache has it, and the source second its time 0 is.
    nonisolated static func ready(_ c: Clip, _ a: Asset, fps: Double) -> (url: URL, offset: Double)? {
        guard let j = job(c, a, fps: fps), FileManager.default.fileExists(atPath: j.url.path) else { return nil }
        return (j.url, j.sourceIn)
    }

    func isRendering(_ j: Job) -> Bool { rendering.contains(j.key) }

    func ensure(_ j: Job) async throws -> URL {
        if FileManager.default.fileExists(atPath: j.url.path) { return j.url }
        if let t = inFlight[j.key] { return try await t.value }
        rendering.insert(j.key); progress[j.key] = 0; failed[j.key] = nil
        let k = j.key
        let task = Task<URL, Error>.detached(priority: .userInitiated) {
            let started = Date()
            let tmp = j.url.deletingPathExtension().appendingPathExtension("part.mov")
            try await Self.render(j, to: tmp) { f in Task { @MainActor in InterpolatedVideo.shared.progress[k] = f } }
            try? FileManager.default.removeItem(at: j.url)
            try FileManager.default.moveItem(at: tmp, to: j.url)
            DebugLog.event("smooth-slow-motion", ["key": k, "method": j.method.rawValue, "fps": j.fps, "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
            return j.url
        }
        inFlight[k] = task
        defer { inFlight[k] = nil; rendering.remove(k); progress[k] = nil }
        do { let u = try await task.value; version += 1; return u }
        catch let e as FlowFailed where j.method == .opticalFlow {
            Self.flowFailure = e.reason
            try? FileManager.default.removeItem(at: j.url.deletingPathExtension().appendingPathExtension("part.mov"))
            DebugLog.error("smooth-slow-motion-flow-failed", e, ["key": k])
            return try await ensure(Self.blending(j))
        } catch { failed[k] = error.localizedDescription; DebugLog.error("smooth-slow-motion-failed", error, ["key": k]); throw error }
    }

    /// The same render with blend: the key `job` gives it once flow is not available.
    nonisolated static func blending(_ j: Job) -> Job {
        var b = j
        b.method = .blend
        b.key = String(j.key.dropLast(SlowMotionMode.opticalFlow.rawValue.count)) + SlowMotionMode.blend.rawValue
        return b
    }

    /// Renders after a quiet period, so a trim or speed drag ends in one render.
    func schedule(_ c: Clip, _ a: Asset, fps: Double, delay: Duration = .milliseconds(600)) {
        scheduled[c.id]?.cancel()
        guard let j = Self.job(c, a, fps: fps), !FileManager.default.fileExists(atPath: j.url.path) else { return }
        scheduled[c.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            _ = try? await self.ensure(j)
        }
    }

    /// Every render the project needs (the export calls this before building, so it never exports the stutter).
    func ensureAll(_ p: Project) async throws {
        for c in p.allClips {
            guard let a = p.asset(c.assetID), let j = Self.job(c, a, fps: p.settings.fps) else { continue }
            _ = try await ensure(j)
        }
    }

    // MARK: Rendering

    nonisolated static func render(_ j: Job, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let asset = AVURLAsset(url: j.source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditError.invalid("\(j.source.lastPathComponent) has no picture") }
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        // The source's colour tags go on the render, so the encoder converts with the same matrix and transfer.
        var color: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        if let fd = try await track.load(.formatDescriptions).first {
            if let v = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String { color[AVVideoColorPrimariesKey] = v }
            if let v = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String { color[AVVideoTransferFunctionKey] = v }
            if let v = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String { color[AVVideoYCbCrMatrixKey] = v }
        }
        let srcFPS = Double(try await track.load(.nominalFrameRate))
        let w = Int(size.width), h = Int(size.height)
        let frame = 1 / max(1, srcFPS > 0 ? srcFPS : 30)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, j.sourceIn - 2 * frame), preferredTimescale: 6000),
                                       end: CMTime(seconds: j.sourceOut + 3 * frame, preferredTimescale: 6000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                          kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? EditError.invalid("cannot read \(j.source.lastPathComponent)") }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let bitrate = max(4_000_000, Double(w * h) * j.fps * 0.12)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                                                           AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate], AVVideoColorPropertiesKey: color])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EditError.invalid("cannot write the interpolated file") }
        writer.startSession(atSourceTime: .zero)

        // No colour management: the file must carry the source pixels unchanged (a managed context shifted them ~4 dB).
        let ci = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var flow: Any? = nil
        if j.method == .opticalFlow, #available(macOS 15.4, *) {
            do { flow = try FlowInterpolator(width: w, height: h, context: ci) } catch { throw FlowFailed(error) }
        }

        func next() -> (CVPixelBuffer, Double)? {
            while let s = out.copyNextSampleBuffer() {
                if let px = CMSampleBufferGetImageBuffer(s) { return (px, CMSampleBufferGetPresentationTimeStamp(s).seconds) }
            }
            return nil
        }
        func emit(_ image: CIImage, at t: Double, like src: CVPixelBuffer) async throws {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? EditError.invalid("writer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let dst = pb else { throw EditError.invalid("no pixel buffer") }
            ci.render(image, to: dst)
            CVBufferPropagateAttachments(src, dst)
            if !adaptor.append(dst, withPresentationTime: CMTime(seconds: t, preferredTimescale: 60000)) { throw writer.error ?? EditError.invalid("append failed") }
        }

        let n = max(1, Int(((j.sourceOut - j.sourceIn) * j.fps).rounded(.up)))
        var a = next(), b = next()
        for k in 0..<n {
            try Task.checkCancellation()
            let t = j.sourceIn + Double(k) / j.fps
            while let bb = b, bb.1 <= t + 1e-4 { a = bb; b = next() }
            guard let aa = a else { break }
            let phase = b.map { (t - aa.1) / max(1e-6, $0.1 - aa.1) } ?? 0
            let image: CIImage
            if phase < 0.002 || b == nil {
                image = CIImage(cvPixelBuffer: aa.0)
            } else if let bb = b, #available(macOS 15.4, *), let f = flow as? FlowInterpolator {
                do {
                    if failFlowForTesting { throw NSError(domain: "VTFrameProcessorErrorDomain", code: -19730) }
                    image = try await f.interpolate(aa.0, at: aa.1, bb.0, at: bb.1, phase: Float(phase))
                }
                catch { f.end(); reader.cancelReading(); writer.cancelWriting(); throw FlowFailed(error) }
            } else {
                let fade = CIFilter(name: "CIDissolveTransition")!
                fade.setValue(CIImage(cvPixelBuffer: aa.0), forKey: kCIInputImageKey)
                fade.setValue(CIImage(cvPixelBuffer: b!.0), forKey: kCIInputTargetImageKey)
                fade.setValue(phase, forKey: kCIInputTimeKey)
                image = fade.outputImage!
            }
            try await emit(image, at: Double(k) / j.fps, like: aa.0)
            if k % 10 == 0 { progress(Double(k) / Double(n)) }
        }
        reader.cancelReading()
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? EditError.invalid("writing the interpolated file failed") }
        if #available(macOS 15.4, *) { (flow as? FlowInterpolator)?.end() }
    }
}

/// VideoToolbox frame-rate conversion: one synthesized frame between two source frames at a phase 0...1.
@available(macOS 15.4, *)
final class FlowInterpolator {
    private let processor = VTFrameProcessor()
    private let srcPool: CVPixelBufferPool, dstPool: CVPixelBufferPool
    private let ci: CIContext

    init(width: Int, height: Int, context: CIContext) throws {
        guard VTFrameRateConversionConfiguration.isSupported,
              let c = VTFrameRateConversionConfiguration(frameWidth: width, frameHeight: height, usePrecomputedFlow: false,
                                                         qualityPrioritization: .quality, revision: VTFrameRateConversionConfiguration.defaultRevision)
        else { throw EditError.invalid("optical flow frame-rate conversion is not supported on this Mac") }
        try processor.startSession(configuration: c)
        func pool(_ attrs: [String: Any]) throws -> CVPixelBufferPool {
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            guard let p else { throw EditError.invalid("cannot make optical-flow buffers") }
            return p
        }
        srcPool = try pool(c.sourcePixelBufferAttributes); dstPool = try pool(c.destinationPixelBufferAttributes)
        ci = context
    }

    private func buffer(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { throw EditError.invalid("optical-flow buffer pool is empty") }
        return pb
    }

    /// The source frame converted to the processor's format.
    private func frame(_ px: CVPixelBuffer, _ t: Double) throws -> VTFrameProcessorFrame {
        let b = try buffer(srcPool)
        ci.render(CIImage(cvPixelBuffer: px), to: b)
        guard let f = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 60000)) else { throw EditError.invalid("optical-flow frame") }
        return f
    }

    func interpolate(_ a: CVPixelBuffer, at ta: Double, _ b: CVPixelBuffer, at tb: Double, phase: Float) async throws -> CIImage {
        let fa = try frame(a, ta), fb = try frame(b, tb)
        let dst = try buffer(dstPool)
        guard let fd = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: CMTime(seconds: ta + Double(phase) * (tb - ta), preferredTimescale: 60000)),
              let params = VTFrameRateConversionParameters(sourceFrame: fa, nextFrame: fb, opticalFlow: nil, interpolationPhase: [phase],
                                                           submissionMode: .sequential, destinationFrames: [fd])
        else { throw EditError.invalid("optical-flow parameters") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            processor.process(parameters: params) { _, err in if let err { cont.resume(throwing: err) } else { cont.resume() } }
        }
        return CIImage(cvPixelBuffer: dst)
    }

    func end() { processor.endSession() }
}

extension TimeMap.Segment {
    /// The same piece read from a file whose time 0 is source second `offset`.
    func reading(from offset: Double) -> Self {
        .init(sourceStart: sourceStart - offset, sourceEnd: sourceEnd - offset, timelineStart: timelineStart, timelineEnd: timelineEnd)
    }
}
