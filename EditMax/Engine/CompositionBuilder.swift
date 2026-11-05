import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import CoreText
import AppKit

/// Turns a `Project` into AVFoundation objects for preview and export.
/// Video/audio clips become composition tracks; images and text become a Core Animation overlay layer
/// (driven by `AVSynchronizedLayer` in preview and `AVVideoCompositionCoreAnimationTool` on export).
enum CompositionBuilder {
    struct Output {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVMutableAudioMix
        let renderSize: CGSize
        let duration: CMTime
    }

    static let timescale: CMTimeScale = 600

    /// Builds the AVFoundation composition for a project. Every project track gets two video and two audio composition
    /// tracks (A/B): consecutive clips alternate between them, which is what lets a transition overlap the clip before it.
    static func build(_ project: Project) async throws -> Output {
        let comp = AVMutableComposition()
        let renderSize = CGSize(width: project.settings.width, height: project.settings.height)
        let total = CMTime(seconds: max(project.duration, 0.1), preferredTimescale: timescale)
        var layerSources: [[LayerSource]] = []    // per visible video track, top row first
        var audioParams: [AVMutableAudioMixInputParameters] = []
        var assetCache: [UUID: AVURLAsset] = [:]
        var stillCache: [UUID: CIImage] = [:]
        let t = { (s: Double) in CMTime(seconds: s, preferredTimescale: timescale) }

        // Base track: a tiny black movie under everything, so stills and titles render without any video clip.
        if let base = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
           let blankTrack = try? await AVURLAsset(url: BlankVideo.url()).loadTracks(withMediaType: .video).first {
            let one = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
            try base.insertTimeRange(one, of: blankTrack, at: .zero)
            base.scaleTimeRange(CMTimeRange(start: .zero, duration: one.duration), toDuration: total)
        }

        for track in project.tracks where !track.isHidden {
            let video: [AVMutableCompositionTrack?] = track.kind == .video
                ? [comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid), comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)]
                : [nil, nil]
            let audio = [comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid), comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)]
            let params = audio.map { $0.map { AVMutableAudioMixInputParameters(track: $0) } }
            var sources: [LayerSource] = []
            let clips = track.clips.sorted { $0.start < $1.start }
            for (i, clip) in clips.enumerated() {
                guard let asset = project.asset(clip.assetID) else { continue }
                let slot = i % 2
                let volume = track.isMuted ? 0 : Float(clip.volume)

                // Transition into this clip: the previous clip is extended under it by `d` seconds.
                var transitionEnd: Double? = nil, outgoingID: UUID? = nil
                if let tr = clip.transitionIn, tr.duration > 0.01 {
                    var d = min(tr.duration, clip.duration)
                    if i > 0, let prev = Optional(clips[i - 1]), abs(prev.end - clip.start) < 0.02, let prevAsset = project.asset(prev.assetID) {
                        if prevAsset.kind != .image { d = min(d, max(0, (prevAsset.duration - prev.sourceOut) / prev.speed)) }
                        if d > 0.01 {
                            outgoingID = prev.id
                            let pslot = (i - 1) % 2
                            let extra = CMTimeRange(start: t(prev.sourceOut), duration: t(d * prev.speed))
                            let av = assetCache[prevAsset.id] ?? AVURLAsset(url: prevAsset.url)
                            if prevAsset.kind != .image {
                                if let v = video[pslot], let vt = try await av.loadTracks(withMediaType: .video).first {
                                    try v.insertTimeRange(extra, of: vt, at: t(prev.end))
                                    if prev.speed != 1 { v.scaleTimeRange(CMTimeRange(start: t(prev.end), duration: extra.duration), toDuration: t(d)) }
                                }
                                if let a = audio[pslot], let at = try await av.loadTracks(withMediaType: .audio).first {
                                    try a.insertTimeRange(extra, of: at, at: t(prev.end))
                                    if prev.speed != 1 { a.scaleTimeRange(CMTimeRange(start: t(prev.end), duration: extra.duration), toDuration: t(d)) }
                                    params[pslot]?.setVolumeRamp(fromStartVolume: track.isMuted ? 0 : Float(prev.volume), toEndVolume: 0, timeRange: CMTimeRange(start: t(prev.end), duration: t(d)))
                                }
                            }
                            if let si = sources.firstIndex(where: { $0.clip.id == prev.id }) {
                                let o = sources[si]
                                sources[si] = LayerSource(trackID: o.trackID, still: o.still, naturalSize: o.naturalSize, preferredTransform: o.preferredTransform, clip: o.clip, effectiveEnd: prev.end + d, transitionEnd: o.transitionEnd, outgoingID: o.outgoingID)
                            }
                        }
                    }
                    if d > 0.01 { transitionEnd = clip.start + d }
                }

                if asset.kind == .image {
                    guard track.kind == .video else { continue }
                    let still = stillCache[asset.id] ?? StillLoader.load(asset.url)
                    guard let still else { continue }
                    stillCache[asset.id] = still
                    sources.append(LayerSource(trackID: kCMPersistentTrackID_Invalid, still: still, naturalSize: still.extent.size, preferredTransform: .identity, clip: clip, effectiveEnd: clip.end, transitionEnd: transitionEnd, outgoingID: outgoingID))
                    continue
                }
                let av = assetCache[asset.id] ?? AVURLAsset(url: asset.url)
                assetCache[asset.id] = av
                let srcRange = CMTimeRange(start: t(clip.sourceIn), duration: t(clip.duration * clip.speed))
                let at = t(clip.start)
                let placedRange = CMTimeRange(start: at, duration: srcRange.duration)
                let targetDur = t(clip.duration)
                if let v = video[slot], let vt = try await av.loadTracks(withMediaType: .video).first {
                    try v.insertTimeRange(srcRange, of: vt, at: at)
                    if clip.speed != 1 { v.scaleTimeRange(placedRange, toDuration: targetDur) }
                    let size = try await vt.load(.naturalSize)
                    let pref = try await vt.load(.preferredTransform)
                    sources.append(LayerSource(trackID: v.trackID, still: nil, naturalSize: size, preferredTransform: pref, clip: clip, effectiveEnd: clip.end, transitionEnd: transitionEnd, outgoingID: outgoingID))
                }
                if let a = audio[slot], let atr = try await av.loadTracks(withMediaType: .audio).first, let prm = params[slot] {
                    try a.insertTimeRange(srcRange, of: atr, at: at)
                    if clip.speed != 1 { a.scaleTimeRange(placedRange, toDuration: targetDur) }
                    prm.setVolume(volume, at: at)
                    // Fades and the transition's crossfade as ramps; the transition ramp wins at the head.
                    let head = transitionEnd.map { $0 - clip.start } ?? clip.fadeIn
                    if head > 0.01 { prm.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: at, duration: t(min(head, clip.duration)))) }
                    if clip.fadeOut > 0.01 {
                        let fo = min(clip.fadeOut, clip.duration)
                        prm.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: t(clip.end - fo), duration: t(fo)))
                    }
                }
            }
            if track.kind == .video { layerSources.append(sources) }
            audioParams.append(contentsOf: params.compactMap { $0 })
        }

        // Titles, rasterized once per build.
        let texts: [TextLayer] = project.texts.compactMap { tx in
            guard let (img, px) = OverlayLayerBuilder.renderText(tx, canvas: renderSize) else { return nil }
            let ci = CIImage(cgImage: img, options: [.colorSpace: NSNull()])   // rasterized at the screen's backing scale; bring it to render pixels
            let sx = px.width / max(1, ci.extent.width), sy = px.height / max(1, ci.extent.height)
            return TextLayer(text: tx, image: ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), size: px)
        }

        // One instruction per segment between edges (clip starts, ends, transition ends, extended tails), on quantized
        // boundaries: a gap or an empty range makes AVFoundation reject the whole composition ("Operation Stopped").
        let videoComp = AVMutableVideoComposition()
        videoComp.customVideoCompositorClass = EditMaxCompositor.self
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, project.settings.fps.rounded())))
        let q = { (s: Double) -> Int64 in min(total.value, max(0, CMTime(seconds: s, preferredTimescale: timescale).value)) }
        var boundaries: Set<Int64> = [0, total.value]
        for sources in layerSources {
            for src in sources {
                boundaries.insert(q(src.clip.start)); boundaries.insert(q(src.clip.end)); boundaries.insert(q(src.effectiveEnd))
                if let te = src.transitionEnd { boundaries.insert(q(te)) }
            }
        }
        for tx in project.texts { boundaries.insert(q(tx.start)); boundaries.insert(q(tx.end)) }
        let times = boundaries.sorted()
        var instructions: [EditMaxInstruction] = []
        for (a, b) in zip(times, times.dropFirst()) where b > a {
            let range = CMTimeRange(start: CMTime(value: a, timescale: timescale), end: CMTime(value: b, timescale: timescale))
            var layers: [TrackLayer] = []
            var required: [CMPersistentTrackID] = []
            for sources in layerSources {
                guard let cur = sources.first(where: { q($0.clip.start) <= a && q($0.clip.end) >= b }) else { continue }
                var outgoing: LayerSource? = nil
                if let te = cur.transitionEnd, b <= q(te), let oid = cur.outgoingID { outgoing = sources.first { $0.clip.id == oid } }
                layers.append(TrackLayer(current: cur, outgoing: outgoing))
                for s in [cur, outgoing].compactMap({ $0 }) where s.trackID != kCMPersistentTrackID_Invalid { required.append(s.trackID) }
            }
            let visibleTexts = texts.filter { q($0.text.start) < b && q($0.text.end) > a }
            instructions.append(EditMaxInstruction(timeRange: range, layers: layers, texts: visibleTexts, renderSize: renderSize, requiredTrackIDs: required))
        }
        videoComp.instructions = instructions

        let mix = AVMutableAudioMix()
        mix.inputParameters = audioParams
        return Output(composition: comp, videoComposition: videoComp, audioMix: mix, renderSize: renderSize, duration: total)
    }

    /// Aspect-fit a source track into the render size, honouring the source's preferred transform (rotation).
    static func fitTransform(naturalSize: CGSize, preferred: CGAffineTransform, into render: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let w = abs(rect.width), h = abs(rect.height)
        guard w > 0, h > 0 else { return .identity }
        let scale = min(render.width / w, render.height / h)
        let tx = (render.width - w * scale) / 2 - rect.minX * scale
        let ty = (render.height - h * scale) / 2 - rect.minY * scale
        return preferred.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: tx, y: ty))
    }
}

enum OverlayLayerBuilder {
    /// Draws a text overlay at full render resolution in its preset's look (font, case, stroke, background box).
    /// The one place text is rasterized: preview, export and capture_frame all come through here. Returns the CGImage and its size in render pixels.
    static func renderText(_ t: TextOverlay, canvas: CGSize, scale: CGFloat = 1) -> (CGImage, CGSize)? {
        let style = CaptionPresets.style(t.preset)
        let font = NSFont(name: style.fontName, size: t.fontSize * scale) ?? NSFont.boldSystemFont(ofSize: t.fontSize * scale)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: cgColor(hex: t.colorHex)) ?? .white, .paragraphStyle: para]
        if style.shadow {
            let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.8); shadow.shadowBlurRadius = 4 * scale; shadow.shadowOffset = NSSize(width: 0, height: -2 * scale)
            attrs[.shadow] = shadow
        }
        if style.strokeWidth > 0 {   // negative width = fill and stroke
            attrs[.strokeWidth] = -style.strokeWidth
            attrs[.strokeColor] = NSColor(cgColor: cgColor(hex: style.strokeColor)) ?? .black
        }
        let maxWidth = (canvas.width * scale * 0.9).rounded()
        let str = NSAttributedString(string: style.uppercase ? t.text.uppercased() : t.text, attributes: attrs)
        let used = str.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        let padX = (style.box?.padding ?? 0) * scale, padY = (style.box?.padding ?? 0) * scale * 0.5
        // Boxed styles hug the text; the others keep a full-width canvas so the shadow and stroke are never clipped.
        let width = style.box == nil ? maxWidth : min(maxWidth, ceil(used.width) + 2 * padX + 8 * scale)
        let h = ceil(used.height) + (style.box == nil ? 12 * scale : 2 * padY + 4 * scale)
        let img = NSImage(size: NSSize(width: width, height: h))
        img.lockFocus()
        if let box = style.box {
            (NSColor(cgColor: cgColor(hex: box.color)) ?? .black).withAlphaComponent(box.alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: h), xRadius: box.radius * scale, yRadius: box.radius * scale).fill()
        }
        str.draw(with: CGRect(x: (width - min(width, maxWidth)) / 2, y: (h - ceil(used.height)) / 2, width: min(width, maxWidth), height: ceil(used.height)), options: [.usesLineFragmentOrigin])
        img.unlockFocus()
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (cg, CGSize(width: width / scale, height: h / scale))
    }

    static func cgColor(hex: String) -> CGColor {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return CGColor(gray: 1, alpha: 1) }
        return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
