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
        /// Builds a fresh overlay layer tree sized to `renderSize`. Call once per consumer (layers can't be shared).
        let makeOverlay: () -> CALayer
    }

    static let timescale: CMTimeScale = 600

    static func build(_ project: Project) async throws -> Output {
        let comp = AVMutableComposition()
        let renderSize = CGSize(width: project.settings.width, height: project.settings.height)
        let total = CMTime(seconds: max(project.duration, 0.1), preferredTimescale: timescale)
        var layerSources: [(track: AVMutableCompositionTrack, clips: [(Clip, CGSize, CGAffineTransform)])] = []
        var audioParams: [AVMutableAudioMixInputParameters] = []
        var assetCache: [UUID: AVURLAsset] = [:]

        for track in project.tracks where !track.isHidden {
            let compVideo = track.kind == .video ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
            let compAudio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            var placed: [(Clip, CGSize, CGAffineTransform)] = []
            let params = compAudio.map { AVMutableAudioMixInputParameters(track: $0) }
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                guard let asset = project.asset(clip.assetID), asset.kind != .image else { continue }
                let av = assetCache[asset.id] ?? AVURLAsset(url: asset.url)
                assetCache[asset.id] = av
                let srcRange = CMTimeRange(start: CMTime(seconds: clip.sourceIn, preferredTimescale: timescale),
                                           duration: CMTime(seconds: clip.duration * clip.speed, preferredTimescale: timescale))
                let at = CMTime(seconds: clip.start, preferredTimescale: timescale)
                let placedRange = CMTimeRange(start: at, duration: srcRange.duration)
                let targetDur = CMTime(seconds: clip.duration, preferredTimescale: timescale)
                if let compVideo, let v = try await av.loadTracks(withMediaType: .video).first {
                    try compVideo.insertTimeRange(srcRange, of: v, at: at)
                    if clip.speed != 1 { compVideo.scaleTimeRange(placedRange, toDuration: targetDur) }
                    let size = try await v.load(.naturalSize)
                    let transform = try await v.load(.preferredTransform)
                    placed.append((clip, size, transform))
                }
                if let compAudio, let a = try await av.loadTracks(withMediaType: .audio).first {
                    try compAudio.insertTimeRange(srcRange, of: a, at: at)
                    if clip.speed != 1 { compAudio.scaleTimeRange(placedRange, toDuration: targetDur) }
                    params?.setVolume(track.isMuted ? 0 : Float(clip.volume), at: at)
                }
            }
            if let compVideo { layerSources.append((compVideo, placed)) }
            if let params { audioParams.append(params) }
        }

        // Video composition: one instruction per segment between clip boundaries, top track first.
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, project.settings.fps.rounded())))
        var boundaries: Set<Double> = [0, total.seconds]
        for (_, clips) in layerSources { for (c, _, _) in clips { boundaries.insert(c.start); boundaries.insert(c.end) } }
        let times = boundaries.sorted()
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (a, b) in zip(times, times.dropFirst()) where b - a > 0.0005 {
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: timescale), end: CMTime(seconds: b, preferredTimescale: timescale))
            var layers: [AVMutableVideoCompositionLayerInstruction] = []
            for (compTrack, clips) in layerSources.reversed() {  // last project track = top of stack
                guard let (clip, size, pref) = clips.first(where: { $0.0.start <= a + 0.0005 && $0.0.end >= b - 0.0005 }) else { continue }
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
                li.setTransform(fitTransform(naturalSize: size, preferred: pref, into: renderSize), at: .zero)
                li.setOpacity(Float(clip.opacity), at: .zero)
                layers.append(li)
            }
            inst.layerInstructions = layers
            inst.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            instructions.append(inst)
        }
        videoComp.instructions = instructions

        let mix = AVMutableAudioMix()
        mix.inputParameters = audioParams

        let overlayProject = project.withoutHistory
        let overlayAssets = assetCache
        return Output(composition: comp, videoComposition: videoComp, audioMix: mix, renderSize: renderSize, duration: total,
                      makeOverlay: { OverlayLayerBuilder.make(project: overlayProject, size: renderSize, total: total.seconds, assets: overlayAssets) })
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
    /// Root overlay layer in render pixels, origin top-left (flipped so y=0 is the top for both preview and export).
    static func make(project: Project, size: CGSize, total: Double, assets: [UUID: AVURLAsset]) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.isGeometryFlipped = true
        root.masksToBounds = true

        // Image clips on video tracks
        for track in project.tracks where track.kind == .video && !track.isHidden {
            for clip in track.clips {
                guard let asset = project.asset(clip.assetID), asset.kind == .image,
                      let src = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                let l = CALayer()
                l.contents = img
                l.contentsGravity = .resizeAspect
                l.frame = root.bounds
                l.opacity = Float(clip.opacity)
                l.isGeometryFlipped = true
                addVisibility(l, start: clip.start, end: clip.end, total: total, peak: Float(clip.opacity))
                root.addSublayer(l)
            }
        }
        for t in project.texts {
            // Pre-render text to a bitmap: CATextLayer draws in the live preview but not reliably in
            // AVVideoCompositionCoreAnimationTool export, while a plain contents layer works in both.
            guard let (img, px) = renderText(t, canvas: size) else { continue }
            let l = CALayer()
            l.contents = img
            l.contentsGravity = .resize
            l.isGeometryFlipped = true
            l.frame = CGRect(x: size.width * t.x - px.width / 2, y: size.height * t.y - px.height / 2, width: px.width, height: px.height)
            addVisibility(l, start: t.start, end: t.end, total: total, peak: 1)
            root.addSublayer(l)
        }
        return root
    }

    /// Opacity keyframes: hidden outside [start, end]. Driven by the player clock (AVSynchronizedLayer) or export timeline.
    private static func addVisibility(_ layer: CALayer, start: Double, end: Double, total: Double, peak: Float) {
        // Linear keyframes with a 1ms ramp give a step function that every CA renderer (preview, export) honours.
        let dur = max(total, end + 0.01, 0.1)
        let eps = 0.001
        let s0 = max(0, start - eps) / dur, s1 = start / dur, e0 = end / dur, e1 = min(dur, end + eps) / dur
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.duration = dur
        anim.calculationMode = .linear
        anim.values = [0, 0, peak, peak, 0, 0]
        anim.keyTimes = [0, NSNumber(value: s0), NSNumber(value: s1), NSNumber(value: e0), NSNumber(value: e1), 1]
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        layer.opacity = 0
        layer.add(anim, forKey: "visibility")
    }

    /// Draws a text overlay at full render resolution. Returns the CGImage and its size in render pixels.
    static func renderText(_ t: TextOverlay, canvas: CGSize, scale: CGFloat = 1) -> (CGImage, CGSize)? {
        let font = NSFont(name: "HelveticaNeue-Bold", size: t.fontSize * scale) ?? NSFont.boldSystemFont(ofSize: t.fontSize * scale)
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.8); shadow.shadowBlurRadius = 4 * scale; shadow.shadowOffset = NSSize(width: 0, height: -2 * scale)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: cgColor(hex: t.colorHex)) ?? .white, .shadow: shadow, .paragraphStyle: para]
        let width = (canvas.width * scale * 0.9).rounded()
        let str = NSAttributedString(string: t.text, attributes: attrs)
        let h = ceil(str.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height) + 12 * scale
        let img = NSImage(size: NSSize(width: width, height: h))
        img.lockFocus()
        str.draw(with: CGRect(x: 0, y: 6 * scale, width: width, height: h), options: [.usesLineFragmentOrigin])
        img.unlockFocus()
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (cg, CGSize(width: width / scale, height: h / scale))
    }

    /// Offline composite of the overlays visible at `time` onto a base frame, scaled to `maxWidth`. Returns PNG data.
    static func composite(base: CGImage, project: Project, size: CGSize, at time: Double, maxWidth: Int) -> Data {
        let scale = min(1, CGFloat(maxWidth) / size.width)
        let outSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let image = NSImage(size: outSize)
        image.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.draw(base, in: CGRect(origin: .zero, size: outSize))
        // Image clips
        for track in project.tracks where track.kind == .video && !track.isHidden {
            for clip in track.clips where clip.start <= time && time < clip.end {
                guard let asset = project.asset(clip.assetID), asset.kind == .image, let img = NSImage(contentsOf: asset.url) else { continue }
                let r = AVMakeRect(aspectRatio: img.size, insideRect: CGRect(origin: .zero, size: outSize))
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: CGFloat(clip.opacity))
            }
        }
        for t in project.texts where t.start <= time && time < t.end {
            guard let (cg, px) = renderText(t, canvas: size, scale: scale) else { continue }
            let w = px.width * scale, h = px.height * scale
            // NSImage drawing is bottom-left origin; model y is top-down.
            let rect = CGRect(x: outSize.width * t.x - w / 2, y: outSize.height * (1 - t.y) - h / 2, width: w, height: h)
            ctx.draw(cg, in: rect)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    static func cgColor(hex: String) -> CGColor {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return CGColor(gray: 1, alpha: 1) }
        return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
