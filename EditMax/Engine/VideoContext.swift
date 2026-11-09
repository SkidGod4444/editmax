import Foundation
import AVFoundation
import Vision
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

// MARK: - Video context (describe_video)
//
// One read-only pass that tells an agent what a video file holds without watching it:
// - the file: size, frame rate, codec, bit depth, HDR, camera, date and place from its metadata;
// - its shots (hard cuts, `SceneDetector`), cut into segments short enough to describe (a long take gets several);
// - for each segment the picture at its middle: brightness, clipping and colour (`ColorScopes`), faces, people, the
//   salient subject, what Vision recognises (labels), readable text, how busy it is (the scene detector's frame
//   differences inside the segment) and which way the camera moves (image registration over a third of a second);
// - the sound: loudness, true peak, range and a level curve;
// - a contact sheet: one tile per segment, labelled with its time, so a model sees the whole video in one image.
// Results are cached per file (path, size and modification date) in Application Support, so asking again is instant.

enum VideoContext {
    /// A box in the picture, 0-1, top-left origin, y down (as the frame is seen).
    struct Box: Codable, Equatable { var x, y, width, height: Double }

    struct Media: Codable, Equatable {
        var width: Int?, height: Int?
        var fps: Double?
        var codec: String?
        var bitDepth: Int?
        var hdr: String?                 // hlg or pq; nil for SDR
        var primaries: String?           // Rec.709, Rec.2020, P3
        var megabitsPerSecond: Double?
        var bytes: Int64?
        var created: String?             // ISO 8601, from the file's metadata
        var camera: String?              // make and model
        var location: String?            // ISO 6709, as the camera wrote it
        var audioChannels: Int?
        var audioSampleRate: Double?
    }

    struct Segment: Codable, Equatable {
        var shot: Int                    // 1-based; a hard cut starts a new shot
        var start: Double, end: Double   // source seconds
        var timeline: [Double]?          // timeline start and end, when described through a clip
        var frame: Double?               // source second of the described picture
        var motion: Double               // mean frame-to-frame change inside the segment, 0-1 (0.01 still, 0.1 busy)
        var camera: String?              // static, pans left/right, tilts up/down (from image registration)
        var brightness: Double?          // mean luma 0-1
        var clipped: Double?             // share of pixels near white
        var crushed: Double?             // share of pixels near black
        var saturation: Double?          // mean 0-1
        var color: String?               // the dominant hue, and the cast when there is one
        var faces: [Box]?
        var people: Int?
        var subject: Box?                // where the eye goes (attention saliency)
        var labels: [String]?            // what Vision recognises, most confident first ("sky 0.92")
        var text: [String]?              // readable text in the picture
    }

    struct Audio: Codable, Equatable {
        var integrated: Double           // LUFS
        var truePeak: Double             // dBTP
        var range: Double                // LU
        var silent: Double               // share of the time below -50 dBFS
        var step: Double                 // seconds per entry in levels
        var levels: [Int]                // RMS dBFS per step, from the start of the range
    }

    struct Speech: Codable, Equatable {
        var words: Int
        var coverage: Double             // share of the range with words being spoken
        var text: String
        var truncated: Bool?
    }

    struct Info: Codable, Equatable {
        var file: String
        var path: String
        var kind: String                 // video or audio
        var duration: Double
        var range: [Double]              // source seconds described
        var summary: String
        var media: Media
        var shots: Int
        var cuts: [Double]               // source seconds where a new shot starts
        var segments: [Segment]
        var audio: Audio?
        var speech: Speech?
        var cached: Bool?
        var notes: [String]?
    }

    static let maxDescribed = 48
    static let frameWidth: CGFloat = 768
    static let defaultSheetWidth = 1600
    static let speechCharacters = 1500
    static let cacheVersion = 3

    static func sheetWidth(_ requested: Int?) throws -> Int {
        let w = requested ?? defaultSheetWidth
        guard (320...4096).contains(w) else { throw EditError.invalid("max_width \(w) must be 320 to 4096 pixels") }
        return w
    }
}

// MARK: - Analysis

extension VideoContext {
    /// Describes source seconds `from`…`to` of a video or audio file, with a contact sheet PNG when `sheet` is true.
    nonisolated static func describe(url: URL, from: Double = 0, to: Double? = nil, sensitivity: Double = SceneDetector.defaultSensitivity,
                                     sheet: Bool = true, sheetWidth: Int = defaultSheetWidth) async throws -> (Info, Data?) {
        let key = Cache.key(url: url, parts: [from, to ?? -1, sensitivity, Double(sheet ? sheetWidth : 0)])
        if let hit = Cache.load(key) { var info = hit.0; info.cached = true; return (info, sheet ? hit.1 : nil) }

        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true else { throw EditError.invalid("\(url.lastPathComponent) cannot be read as a video or audio file") }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw EditError.invalid("\(url.lastPathComponent) has no duration") }
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard videoTrack != nil || !audioTracks.isEmpty else { throw EditError.invalid("\(url.lastPathComponent) has no picture or sound") }
        let start = max(0, min(from, duration)), end = min(to ?? duration, duration)
        guard end - start >= 0.1 else { throw EditError.invalid("the range \(EditFormat.s(start))–\(EditFormat.s(end)) s is too short to describe") }

        var notes: [String] = []
        let media = await mediaFacts(asset: asset, url: url, video: videoTrack, audio: audioTracks.first)
        var segments: [Segment] = [], cuts: [Double] = [], shots = 0, png: Data? = nil
        if videoTrack != nil {
            let scan = try await SceneDetector.detect(url: url, from: start, to: end, sensitivity: sensitivity, minScene: 0.5)
            cuts = scan.cuts.map { r3($0.time) }
            shots = cuts.count + 1
            segments = plan(start: start, end: end, cuts: scan.cuts.map(\.time), times: scan.times, diffs: scan.diffs)
            let chosen = pick(segments.count, max: maxDescribed)
            if chosen.count < segments.count {
                notes.append("\(segments.count) segments; the pictures of \(chosen.count), evenly spread, are described. Give a clip or a shorter asset range for the rest.")
            }
            let tiles = try await describePictures(asset: asset, segments: &segments, chosen: chosen, duration: duration)
            if sheet, !tiles.isEmpty { png = contactSheet(tiles, width: sheetWidth) }
        }
        let audio = audioTracks.isEmpty ? nil : try? await audioFacts(asset: asset, tracks: audioTracks, from: start, to: end)
        if !audioTracks.isEmpty, audio == nil { notes.append("the sound could not be read") }

        var info = Info(file: url.lastPathComponent, path: url.path, kind: videoTrack == nil ? "audio" : "video", duration: r3(duration),
                        range: [r3(start), r3(end)], summary: "", media: media, shots: shots, cuts: cuts, segments: segments,
                        audio: audio, speech: nil, cached: nil, notes: notes.isEmpty ? nil : notes)
        info.summary = summary(info)
        Cache.store(key, info, png)
        return (info, png)
    }

    /// Shots between the cuts, each cut into equal parts no longer than about a 24th of the range (at least 2 s),
    /// with the mean frame difference inside each part (the cut frame itself left out).
    static func plan(start: Double, end: Double, cuts: [Double], times: [Double], diffs: [Double]) -> [Segment] {
        let bounds = [start] + cuts.filter { $0 > start && $0 < end } + [end]
        let target = max(2, (end - start) / 24)
        var out: [Segment] = []
        for s in 0..<(bounds.count - 1) {
            let a = bounds[s], b = bounds[s + 1]
            let parts = max(1, Int(((b - a) / target).rounded()))
            let len = (b - a) / Double(parts)
            for p in 0..<parts {
                let lo = a + Double(p) * len, hi = p == parts - 1 ? b : lo + len
                var sum = 0.0, n = 0
                for (i, t) in times.enumerated() where t > lo + 0.02 && t <= hi && !(p == 0 && abs(t - a) < 0.04) { sum += diffs[i]; n += 1 }
                out.append(Segment(shot: s + 1, start: r3(lo), end: r3(hi), motion: n > 0 ? r3(sum / Double(n)) : 0))
            }
        }
        return out
    }

    /// Up to `max` indices out of `count`, evenly spread, first and last included.
    static func pick(_ count: Int, max m: Int) -> [Int] {
        guard count > m else { return Array(0..<count) }
        return (0..<m).map { Int((Double($0) * Double(count - 1) / Double(m - 1)).rounded()) }
    }

    /// Reads two frames per chosen segment (its middle and a third of a second later) and fills in what is seen.
    /// Returns the middle frames, labelled, for the contact sheet.
    nonisolated private static func describePictures(asset: AVURLAsset, segments: inout [Segment], chosen: [Int], duration: Double) async throws -> [(CGImage, String)] {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: frameWidth, height: frameWidth)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        var times: [CMTime] = []
        for i in chosen {
            let s = segments[i], mid = (s.start + s.end) / 2
            let next = min(duration - 0.05, mid + min(0.33, max(0.05, (s.end - mid) * 0.9)))
            times.append(CMTime(seconds: min(duration - 0.05, mid), preferredTimescale: 600))
            times.append(CMTime(seconds: next, preferredTimescale: 600))
        }
        var frames: [(CGImage, Double)?] = Array(repeating: nil, count: times.count)
        var index = 0
        for await result in gen.images(for: times) {
            try Task.checkCancellation()
            let i = index; index += 1
            guard i < frames.count, let img = try? result.image else { continue }
            let actual = (try? result.actualTime.seconds).flatMap { $0.isFinite ? $0 : nil } ?? times[i].seconds
            frames[i] = (img, actual)
        }
        var tiles: [(CGImage, String)] = []
        for (k, i) in chosen.enumerated() {
            guard let mid = frames[k * 2] else { continue }
            let (img, t) = mid
            let seen = look(img, next: frames[k * 2 + 1].map { ($0.0, $0.1 - t) })
            var s = segments[i]
            s.frame = r3(t); s.camera = seen.camera; s.brightness = seen.brightness; s.clipped = seen.clipped; s.crushed = seen.crushed
            s.saturation = seen.saturation; s.color = seen.color; s.faces = seen.faces.isEmpty ? nil : seen.faces
            s.people = seen.people; s.subject = seen.subject; s.labels = seen.labels.isEmpty ? nil : seen.labels
            s.text = seen.text.isEmpty ? nil : seen.text
            segments[i] = s
            tiles.append((img, "#\(i + 1)  \(clock(t))"))
        }
        return tiles
    }

    struct Look {
        var brightness = 0.0, clipped = 0.0, crushed = 0.0, saturation = 0.0
        var color = "", camera: String? = nil
        var faces: [Box] = [], people = 0, subject: Box? = nil
        var labels: [String] = [], text: [String] = []
    }

    /// What one frame shows; `next` is a frame `dt` seconds later, for the camera move.
    nonisolated static func look(_ img: CGImage, next: (CGImage, Double)?) -> Look {
        var out = Look()
        // Brightness and colour from a small copy (the numbers barely move with size).
        let w = 160, h = max(1, Int((Double(img.height) * 160 / Double(max(1, img.width))).rounded()))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var luma = 0.0, hi = 0, lo = 0
        for i in 0..<(w * h) {
            let y = 0.2126 * Double(px[i * 4]) + 0.7152 * Double(px[i * 4 + 1]) + 0.0722 * Double(px[i * 4 + 2])
            luma += y; if y >= 250 { hi += 1 }; if y <= 6 { lo += 1 }
        }
        let n = Double(w * h)
        out.brightness = r3(luma / n / 255); out.clipped = r3(Double(hi) / n); out.crushed = r3(Double(lo) / n)
        let (_, v) = ColorScopes.stats(rgba: px)
        out.saturation = r3(v.meanSaturation)
        let cast = v.castStrength >= 0.03 ? v.castName : nil
        out.color = v.meanSaturation < 0.04 ? "nearly gray" : cast == v.dominantName ? "\(v.dominantName) cast" : v.dominantName + (cast.map { ", \($0) cast" } ?? "")

        // Vision. Each group runs on its own so one failing request does not take the others with it.
        let handler = VNImageRequestHandler(cgImage: img, orientation: .up, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([faces, people, saliency])
        out.faces = (faces.results ?? []).map { box($0.boundingBox) }.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(8).map { $0 }
        out.people = people.results?.count ?? 0
        if let objects = saliency.results?.first?.salientObjects, !objects.isEmpty {
            let u = objects.dropFirst().reduce(objects[0].boundingBox) { $0.union($1.boundingBox) }
            out.subject = box(u)
        }
        let classify = VNClassifyImageRequest()
        try? handler.perform([classify])
        out.labels = (classify.results ?? []).filter { $0.confidence >= 0.3 }.sorted { $0.confidence > $1.confidence }
            .prefix(6).map { "\($0.identifier.replacingOccurrences(of: "_", with: " ")) \(String(format: "%.2f", $0.confidence))" }
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        text.minimumTextHeight = 0.03
        try? handler.perform([text])
        out.text = (text.results ?? []).compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.5 && $0.string.trimmingCharacters(in: .whitespaces).count >= 2 }.prefix(8).map(\.string)

        if let later = next, later.1 > 0.02 {
            let (other, dt) = later
            let reg = VNTranslationalImageRegistrationRequest(targetedCGImage: other, options: [:])
            try? handler.perform([reg])
            if let t = reg.results?.first?.alignmentTransform {
                // alignmentTransform moves the later frame onto this one (Vision's y is up): the picture itself moved by
                // (-tx, +ty) in screen terms (x right, y down), and the camera the other way.
                let dx = -Double(t.tx) / Double(img.width) / dt, dy = Double(t.ty) / Double(img.height) / dt
                out.camera = cameraMove(dx: dx, dy: dy)
            }
        }
        return out
    }

    /// The camera move behind a picture shift of (dx, dy) frames per second (x right, y down).
    static func cameraMove(dx: Double, dy: Double) -> String {
        let still = 0.04
        let big = max(abs(dx), abs(dy))
        guard big >= still else { return "static" }
        var parts: [String] = []
        if abs(dx) >= max(still, big * 0.5) { parts.append(dx < 0 ? "pans right" : "pans left") }
        if abs(dy) >= max(still, big * 0.5) { parts.append(dy > 0 ? "tilts up" : "tilts down") }
        return parts.joined(separator: ", ")
    }

    /// A Vision box (normalized, y up) as a top-left, y-down box.
    nonisolated static func box(_ b: CGRect) -> Box {
        Box(x: r3(b.minX), y: r3(1 - b.maxY), width: r3(b.width), height: r3(b.height))
    }

    // MARK: File facts

    nonisolated private static func mediaFacts(asset: AVURLAsset, url: URL, video: AVAssetTrack?, audio: AVAssetTrack?) async -> Media {
        var m = Media()
        if let v = video {
            if let size = try? await v.load(.naturalSize), let tf = try? await v.load(.preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(tf)
                m.width = Int(abs(r.width).rounded()); m.height = Int(abs(r.height).rounded())
            }
            if let fps = try? await v.load(.nominalFrameRate), fps > 0 { m.fps = (Double(fps) * 100).rounded() / 100 }
            if let rate = try? await v.load(.estimatedDataRate), rate > 0 { m.megabitsPerSecond = (Double(rate) / 1e5).rounded() / 10 }
            if let fd = (try? await v.load(.formatDescriptions))?.first {
                let sub = CMFormatDescriptionGetMediaSubType(fd)
                m.codec = codecName(sub)
                // ProRes files carry a BitsPerComponent that is not the coded depth (422 HQ said 12): the codec decides.
                if let bits = proResBits(sub) { m.bitDepth = bits }
                else if let bits = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int { m.bitDepth = bits }
                if let tf = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                    if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { m.hdr = "hlg" }
                    if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { m.hdr = "pq" }
                }
                if let p = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String {
                    m.primaries = p.contains("2020") ? "Rec.2020" : p.contains("P3") ? "P3" : p.contains("709") ? "Rec.709" : p
                }
            }
        }
        if let a = audio, let fd = (try? await a.load(.formatDescriptions))?.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            m.audioChannels = Int(asbd.mChannelsPerFrame); m.audioSampleRate = asbd.mSampleRate
        }
        if let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 { m.bytes = bytes }
        let items = (try? await asset.load(.metadata)) ?? []
        func first(_ ids: [AVMetadataIdentifier]) -> AVMetadataItem? {
            for id in ids { if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first { return item } }
            return nil
        }
        if let item = first([.quickTimeMetadataCreationDate, .commonIdentifierCreationDate]) {
            if let d = try? await item.load(.dateValue) { m.created = ISO8601DateFormatter().string(from: d) }
            else if let s = try? await item.load(.stringValue) { m.created = s }
        }
        let make = await first([.quickTimeMetadataMake, .commonIdentifierMake])?.loadString()
        let model = await first([.quickTimeMetadataModel, .commonIdentifierModel])?.loadString()
        let camera = [make, model].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !camera.isEmpty { m.camera = camera.joined(separator: " ") }
        m.location = await first([.quickTimeMetadataLocationISO6709, .commonIdentifierLocation])?.loadString()
        return m
    }

    /// The coded bit depth of a ProRes flavour (422 family 10, 4444 family 12); nil for other codecs and ProRes RAW.
    static func proResBits(_ fourcc: FourCharCode) -> Int? {
        switch fourcc {
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy: return 10
        case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ: return 12
        default: return nil
        }
    }

    static func codecName(_ fourcc: FourCharCode) -> String {
        let names: [FourCharCode: String] = [
            kCMVideoCodecType_H264: "H.264", kCMVideoCodecType_HEVC: "HEVC", kCMVideoCodecType_HEVCWithAlpha: "HEVC with alpha",
            kCMVideoCodecType_AppleProRes422: "ProRes 422", kCMVideoCodecType_AppleProRes422HQ: "ProRes 422 HQ",
            kCMVideoCodecType_AppleProRes422LT: "ProRes 422 LT", kCMVideoCodecType_AppleProRes422Proxy: "ProRes 422 Proxy",
            kCMVideoCodecType_AppleProRes4444: "ProRes 4444", kCMVideoCodecType_AppleProRes4444XQ: "ProRes 4444 XQ",
            kCMVideoCodecType_AppleProResRAW: "ProRes RAW", kCMVideoCodecType_MPEG4Video: "MPEG-4", kCMVideoCodecType_JPEG: "Motion JPEG",
            kCMVideoCodecType_VP9: "VP9", kCMVideoCodecType_AV1: "AV1",
        ]
        if let n = names[fourcc] { return n }
        if fourcc == FourCharCode(0x68657631) { return "HEVC" }   // 'hev1'
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((fourcc >> $0) & 0xFF))) }
        return String(chars).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Sound

    /// Loudness of the range (BS.1770, as measure_loudness reports it) and an RMS level curve of at most 120 steps.
    nonisolated private static func audioFacts(asset: AVURLAsset, tracks: [AVAssetTrack], from: Double, to: Double) async throws -> Audio {
        let rate = 48_000.0, channels = 2
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 48_000), end: CMTime(seconds: to, preferredTimescale: 48_000))
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: channels, AVSampleRateKey: rate,
        ])
        guard reader.canAdd(out) else { throw EditError.invalid("cannot read the sound") }
        reader.add(out)
        guard reader.startReading() else { throw EditError.invalid("cannot read the sound: \(reader.error?.localizedDescription ?? "unknown error")") }
        let meter = LoudnessMeter(channels: channels, sampleRate: rate)
        let step = max(0.5, ((to - from) / 120 * 10).rounded(.up) / 10)
        let perStep = Int(step * rate)
        var levels: [Int] = [], acc = 0.0, fill = 0
        func flush() {
            guard fill > 0 else { return }
            let ms = acc / Double(fill * channels)
            levels.append(ms > 1e-9 ? max(-90, Int((10 * log10(ms)).rounded())) : -90)
            acc = 0; fill = 0
        }
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var buf = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let copied = buf.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard copied == kCMBlockBufferNoErr else { continue }
            let frames = buf.count / channels
            buf.withUnsafeBufferPointer { meter.feed(interleaved: $0.baseAddress!, frames: frames) }
            for f in 0..<frames {
                let l = Double(buf[f * channels]), r = Double(buf[f * channels + 1])
                acc += l * l + r * r; fill += 1
                if fill >= perStep { flush() }
            }
        }
        flush()
        if reader.status == .failed { throw EditError.invalid("reading the sound failed: \(reader.error?.localizedDescription ?? "unknown error")") }
        let res = meter.result
        let quiet = levels.isEmpty ? 0 : Double(levels.filter { $0 < -50 }.count) / Double(levels.count)
        func db(_ v: Double) -> Double { v.isFinite ? (v * 10).rounded() / 10 : -70 }
        return Audio(integrated: db(res.integrated), truePeak: db(res.truePeak), range: db(res.range), silent: r3(quiet), step: step, levels: levels)
    }

    /// The words spoken inside source seconds from…to (an asset transcript is in source seconds).
    static func speech(_ words: [TranscriptWord], from: Double, to: Double) -> Speech {
        let w = words.filter { $0.start >= from && $0.start < to }
        let spoken = w.reduce(0.0) { $0 + max(0, min($1.end, to) - $1.start) }
        var text = w.map(\.text).joined(separator: " ")
        let cut = text.count > speechCharacters
        if cut { text = String(text.prefix(speechCharacters)) + "…" }
        return Speech(words: w.count, coverage: r3(min(1, spoken / max(0.001, to - from))), text: text, truncated: cut ? true : nil)
    }

    // MARK: Summary

    /// One line a model can read before the details.
    static func summary(_ i: Info) -> String {
        var parts: [String] = ["\(EditFormat.s(i.range[1] - i.range[0])) s"]
        let m = i.media
        var fmt: [String] = []
        if let w = m.width, let h = m.height { fmt.append("\(w)×\(h)") }
        if let f = m.fps { fmt.append("\(f.formatted(.number.precision(.fractionLength(0...2)))) fps") }
        if let c = m.codec { fmt.append(c + (m.bitDepth.map { " \($0)-bit" } ?? "") + (m.hdr.map { " " + $0.uppercased() } ?? "")) }
        if !fmt.isEmpty { parts.append(fmt.joined(separator: ", ")) }
        if i.kind == "video" {
            parts.append("\(i.shots) shot\(i.shots == 1 ? "" : "s") in \(i.segments.count) segment\(i.segments.count == 1 ? "" : "s")")
            let faces = i.segments.filter { ($0.faces?.count ?? 0) > 0 }.count
            let people = i.segments.filter { ($0.people ?? 0) > 0 }.count
            let text = i.segments.filter { !($0.text ?? []).isEmpty }.count
            if faces > 0 { parts.append("faces in \(faces)") }
            if people > 0 { parts.append("people in \(people)") }
            if text > 0 { parts.append("text in \(text)") }
            var counts: [String: Int] = [:]
            for s in i.segments { for l in s.labels ?? [] { counts[String(l.split(separator: " ").dropLast().joined(separator: " ")), default: 0] += 1 } }
            let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(6).map(\.key)
            if !top.isEmpty { parts.append("seen: " + top.joined(separator: ", ")) }
            let moving = i.segments.compactMap(\.camera).filter { $0 != "static" }.count
            if moving > 0 { parts.append("camera moves in \(moving)") }
        }
        if let a = i.audio { parts.append("sound \(EditFormat.s(a.integrated)) LUFS" + (a.silent > 0.5 ? ", mostly silent" : "")) } else { parts.append("no sound") }
        if let sp = i.speech, sp.words > 0 { parts.append("\(sp.words) words spoken") }
        if let c = m.camera { parts.append(c) }
        if let d = m.created { parts.append(String(d.prefix(10))) }
        return parts.joined(separator: " · ")
    }

    // MARK: Contact sheet

    /// The tiles in a grid about 4:3 overall, each labelled in its lower-left corner, as JPEG.
    nonisolated static func contactSheet(_ tiles: [(CGImage, String)], width: Int) -> Data? {
        guard let first = tiles.first?.0, first.width > 0 else { return nil }
        let n = tiles.count, aspect = Double(first.height) / Double(first.width)
        let cols = min(n, 8, max(1, Int((Double(n) * aspect * 4 / 3).squareRoot().rounded(.up))))
        let rows = (n + cols - 1) / cols
        let tw = Double(width) / Double(cols), th = (tw * aspect).rounded()
        let height = Int(th) * rows
        guard height > 0, let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        let size = max(11, tw * 0.055)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        for (i, tile) in tiles.enumerated() {
            let col = i % cols, row = i / cols
            let r = CGRect(x: Double(col) * tw, y: Double(height) - Double(row + 1) * th, width: tw, height: th).insetBy(dx: 1, dy: 1)
            // Fit the frame in the tile (a portrait shot in a landscape grid keeps its shape).
            let s = min(r.width / Double(tile.0.width), r.height / Double(tile.0.height))
            let fw = Double(tile.0.width) * s, fh = Double(tile.0.height) * s
            ctx.draw(tile.0, in: CGRect(x: r.midX - fw / 2, y: r.midY - fh / 2, width: fw, height: fh))
            let str = NSAttributedString(string: tile.1, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                       NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(str)
            let bounds = CTLineGetImageBounds(line, ctx)
            let pad = size * 0.35
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: bounds.width + pad * 2, height: size + pad * 1.6))
            ctx.textPosition = CGPoint(x: r.minX + pad, y: r.minY + pad)
            CTLineDraw(line, ctx)
        }
        guard let img = ctx.makeImage() else { return nil }
        // JPEG: a sheet of photos is a tenth of the PNG's size, and stays under model image limits at 4096 px.
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func clock(_ t: Double) -> String {
        let m = Int(t) / 60, s = t - Double(m * 60)
        return m > 0 ? String(format: "%d:%04.1f", m, s) : String(format: "%.1f s", s)
    }

    nonisolated static func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}

private extension AVMetadataItem {
    func loadString() async -> String? { (try? await load(.stringValue)) ?? nil }
}

// MARK: - Cache

extension VideoContext {
    /// Finished descriptions on disk, keyed by the file (path, size, modification date) and the request.
    enum Cache {
        nonisolated(unsafe) static var directoryOverride: URL?
        static let limit = 400

        nonisolated static var directory: URL {
            let dir = directoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EditMax/context")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        nonisolated static func key(url: URL, parts: [Double]) -> String {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? Int) ?? 0, mod = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let text = "v\(cacheVersion)|\(url.path)|\(size)|\(Int(mod))|" + parts.map { String(format: "%.4f", $0) }.joined(separator: "|")
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.prefix(24).joined()
        }

        nonisolated static func load(_ key: String) -> (Info, Data?)? {
            let dir = directory
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(key + ".json")),
                  let info = try? JSONDecoder().decode(Info.self, from: data) else { return nil }
            return (info, try? Data(contentsOf: dir.appendingPathComponent(key + ".jpg")))
        }

        nonisolated static func store(_ key: String, _ info: Info, _ png: Data?) {
            let dir = directory
            guard let data = try? JSONEncoder().encode(info) else { return }
            try? data.write(to: dir.appendingPathComponent(key + ".json"), options: .atomic)
            if let png { try? png.write(to: dir.appendingPathComponent(key + ".jpg"), options: .atomic) }
            prune(dir)
        }

        /// Keeps the newest `limit` descriptions.
        nonisolated private static func prune(_ dir: URL) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
                  files.filter({ $0.pathExtension == "json" }).count > limit else { return }
            let jsons = files.filter { $0.pathExtension == "json" }.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            for old in jsons.dropFirst(limit) {
                try? fm.removeItem(at: old)
                try? fm.removeItem(at: old.deletingPathExtension().appendingPathExtension("jpg"))
            }
        }
    }
}

// MARK: - Tool

extension ToolExecutor {
    /// describe_video for a project asset (the whole file) or a clip (its source range, with timeline times added).
    /// Speech is added when the asset is already transcribed, or transcribed first when `transcript` is true.
    func describeVideo(asset: String?, clip: String?, sensitivity: Double?, sheet: Bool, maxWidth: Int?, transcript: Bool, language: String?) async throws -> (VideoContext.Info, Data?) {
        let s = sensitivity ?? SceneDetector.defaultSensitivity
        guard (0...1).contains(s) else { throw EditError.invalid("sensitivity \(s) is outside 0...1 (0.5 is the default; higher finds more cuts)") }
        let width = try VideoContext.sheetWidth(maxWidth)
        guard (clip == nil) != (asset == nil) else { throw EditError.invalid("give asset, clip or path (one of them)") }
        let a: Asset
        var c: Clip? = nil
        if let clip {
            guard let found = document.project.clip(try resolveClip(clip))?.clip else { throw EditError.notFound("clip '\(clip)'") }
            guard found.multicam == nil else { throw EditError.invalid("\(found.name) is a multicam clip; describe an angle's asset") }
            guard let fa = document.project.asset(found.assetID) else { throw EditError.notFound("the clip's asset") }
            c = found; a = fa
        } else {
            guard let fa = document.project.asset(try resolveAsset(asset!)) else { throw EditError.notFound("asset '\(asset!)'") }
            a = fa
        }
        guard a.kind == .video || a.kind == .audio else {
            throw EditError.invalid("\(a.name) is \(a.kind == .image ? "an image (capture_frame shows it)" : "a nested sequence (describe its clips)"): describe_video reads video and audio files")
        }
        guard !Relink.isMissing(a), FileManager.default.fileExists(atPath: a.path) else { throw EditError.invalid("\(a.name) is missing (not at \(a.path)); relink it first") }
        let range = c.map { Self.sourceRange($0) }
        var (info, png) = try await VideoContext.describe(url: a.url, from: range?.0 ?? 0, to: range?.1, sensitivity: s, sheet: sheet, sheetWidth: width)
        if let c {
            info.segments = info.segments.map { seg in
                var seg = seg
                let lo = c.localTime(ofSource: seg.start) ?? 0, hi = c.localTime(ofSource: seg.end - 0.0005) ?? c.duration
                seg.timeline = [VideoContext.r3(c.start + lo), VideoContext.r3(c.start + hi)]
                return seg
            }
        }
        var notes = info.notes ?? []
        if transcript || document.project.transcript(for: a.id) != nil {
            let t = try await ensureTranscript(assetID: a.id, language: language)
            info.speech = VideoContext.speech(t.words, from: info.range[0], to: info.range[1])
            if info.speech?.truncated == true { notes.append("speech text is the first \(VideoContext.speechCharacters) characters; get_transcript has every word with times") }
        } else if info.audio != nil {
            notes.append("speech is not transcribed yet: transcript true transcribes it on this Mac (cached for get_transcript and captions)")
        }
        info.notes = notes.isEmpty ? nil : notes
        info.summary = VideoContext.summary(info)
        return (info, png)
    }

    /// describe_video for a file on this Mac that is not in a project (no timeline times, transcripts are not kept).
    nonisolated static func describeFile(path: String, sensitivity: Double?, sheet: Bool, maxWidth: Int?, transcript: Bool, language: String?) async throws -> (VideoContext.Info, Data?) {
        let s = sensitivity ?? SceneDetector.defaultSensitivity
        guard (0...1).contains(s) else { throw EditError.invalid("sensitivity \(s) is outside 0...1 (0.5 is the default; higher finds more cuts)") }
        let width = try VideoContext.sheetWidth(maxWidth)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) else { throw EditError.notFound("file \(url.path)") }
        guard !dir.boolValue else { throw EditError.invalid("\(url.path) is a folder: describe its video files one at a time") }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            throw EditError.invalid("\(url.lastPathComponent) is an image: describe_video reads video and audio files")
        }
        var (info, png) = try await VideoContext.describe(url: url, sensitivity: s, sheet: sheet, sheetWidth: width)
        if transcript, info.audio != nil {
            let t = try await Transcriber.transcribe(url: url, language: language)
            info.speech = VideoContext.speech(t.words, from: info.range[0], to: info.range[1])
        }
        info.summary = VideoContext.summary(info)
        return (info, png)
    }
}
