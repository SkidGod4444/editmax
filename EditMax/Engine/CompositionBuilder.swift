import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import CoreText
import AppKit

/// Turns a `Project` into AVFoundation objects for preview and export.
/// Video/audio clips become composition tracks; stills, titles, color and transitions are drawn by `EditMaxCompositor`
/// (a custom video compositor, so the same code runs in preview, export and `AVAssetReader`).
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
    /// `forPreview` swaps in proxy files where the project asks for them and they exist; the export never does.
    static func build(_ project: Project, forPreview: Bool = false, depth: Int = 0, compositor: AVVideoCompositing.Type = EditMaxCompositor.self) async throws -> Output {
        var proxies: [UUID: URL] = (forPreview && project.settings.useProxies) ? await MainActor.run { Dictionary(uniqueKeysWithValues: project.assets.compactMap { a in ProxyStore.shared.ready(for: a).map { (a.id, $0) } }) } : [:]
        // Nested sequences play their cached render (rendered now when the cache has none for the current content).
        for a in project.assets where a.sequenceID != nil {
            guard let seq = a.sequenceID.flatMap(project.sequence) else { continue }
            proxies[a.id] = try await SequenceRenderer.shared.ensure(seq, depth: depth + 1)
        }
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

        // Ducking: where the tracks being ducked under have sound.
        var duckCurves: [UUID: DuckCurve] = [:]
        for track in project.tracks {
            guard let duck = track.duck, let src = project.track(duck.sourceTrackID), !src.isMuted, !src.isHidden else { continue }
            let intervals = src.clips.filter { project.asset($0.assetID)?.kind != .image }.map { ($0.start, $0.end) }
            if !intervals.isEmpty { duckCurves[track.id] = DuckCurve(intervals: intervals, duck: duck) }
        }

        for track in project.tracks where !track.isHidden {
            let video: [AVMutableCompositionTrack?] = track.kind == .video
                ? [comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid), comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)]
                : [nil, nil]
            let audio = [comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid), comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)]
            let params = audio.map { $0.map { AVMutableAudioMixInputParameters(track: $0) } }
            var sources: [LayerSource] = []
            // Multicam clips play as one plain piece per angle interval.
            let clips = track.clips.flatMap { $0.multicamPieces(in: project) }.map { project.hydrated($0) }.sorted { $0.start < $1.start }
            // EQ/gate: one tap per slot, only when a clip on it asks for processing (plain projects never touch a tap).
            for slot in 0..<2 {
                let spans = clips.enumerated().filter { $0.offset % 2 == slot && !$0.element.audio.isIdentity }.map { AudioTapContext.Span(start: $0.element.start, end: $0.element.end, audio: $0.element.audio) }
                if !spans.isEmpty, let tap = AudioTap.make(spans: spans) { params[slot]?.audioTapProcessor = tap }
            }
            for (i, clip) in clips.enumerated() {
                guard let asset = project.asset(clip.assetID) else { continue }
                let slot = i % 2
                let volume = track.isMuted ? 0 : Float(clip.volume)

                // Transition into this clip: the previous clip is extended under it by `d` seconds.
                var transitionEnd: Double? = nil, outgoingID: UUID? = nil
                if let tr = clip.transitionIn, tr.duration > 0.01 {
                    var d = min(tr.duration, clip.duration)
                    if i > 0, let prev = Optional(clips[i - 1]), abs(prev.end - clip.start) < 0.02, let prevAsset = project.asset(prev.assetID) {
                        let tailSpeed = max(0.05, prev.speed(at: prev.duration))
                        if prevAsset.kind != .image { d = min(d, max(0, (prevAsset.duration - prev.sourceOut) / tailSpeed)) }
                        if d > 0.01 {
                            outgoingID = prev.id
                            let pslot = (i - 1) % 2
                            let extra = CMTimeRange(start: t(prev.sourceOut), duration: t(d * tailSpeed))
                            let av = assetCache[prevAsset.id] ?? AVURLAsset(url: prevAsset.url)
                            if prevAsset.kind != .image {
                                if let v = video[pslot], let vt = try await av.loadTracks(withMediaType: .video).first {
                                    try v.insertTimeRange(extra, of: vt, at: t(prev.end))
                                    if tailSpeed != 1 { v.scaleTimeRange(CMTimeRange(start: t(prev.end), duration: extra.duration), toDuration: t(d)) }
                                }
                                let prevAudioAsset = prev.audioAssetID.flatMap { project.asset($0) } ?? prevAsset
                                let pav = prevAudioAsset.id == prevAsset.id ? av : AVURLAsset(url: prevAudioAsset.url)
                                let audioExtra = CMTimeRange(start: t((prev.audioSourceIn ?? prev.sourceIn) + prev.sourceOffset(at: prev.duration)), duration: extra.duration)
                                if let a = audio[pslot], let at = try await pav.loadTracks(withMediaType: .audio).first, audioExtra.end.seconds <= prevAudioAsset.duration + 0.01 {
                                    try a.insertTimeRange(audioExtra, of: at, at: t(prev.end))
                                    if tailSpeed != 1 { a.scaleTimeRange(CMTimeRange(start: t(prev.end), duration: extra.duration), toDuration: t(d)) }
                                    params[pslot]?.setVolumeRamp(fromStartVolume: track.isMuted ? 0 : Float(prev.volume(at: prev.duration)), toEndVolume: 0, timeRange: CMTimeRange(start: t(prev.end), duration: t(d)))
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
                let av = assetCache[asset.id] ?? AVURLAsset(url: proxies[asset.id] ?? asset.url)
                assetCache[asset.id] = av
                let segments = TimeMap.segments(clip, assetDuration: asset.duration)
                if let v = video[slot], let vt = try await av.loadTracks(withMediaType: .video).first {
                    try TimeMap.insert(segments, of: vt, into: v)
                    let size = try await vt.load(.naturalSize)
                    let pref = try await vt.load(.preferredTransform)
                    sources.append(LayerSource(trackID: v.trackID, still: nil, naturalSize: size, preferredTransform: pref, clip: clip, effectiveEnd: clip.end, transitionEnd: transitionEnd, outgoingID: outgoingID))
                }
                // Sound may come from another asset (a multicam piece's audio angle); same time map, its own source offset.
                let audioAsset = clip.audioAssetID.flatMap { project.asset($0) } ?? asset
                // Voice isolation: the pre-rendered isolated copy of the sound when the cache has one (same timeline, never cached as the asset).
                let isolated = clip.audio.needsIsolation ? IsolatedAudio.readyURL(for: audioAsset, amount: clip.audio.voiceIsolation) : nil
                let aav = isolated.map { AVURLAsset(url: $0) } ?? (audioAsset.id == asset.id ? av : (assetCache[audioAsset.id] ?? AVURLAsset(url: proxies[audioAsset.id] ?? audioAsset.url)))
                if isolated == nil { assetCache[audioAsset.id] = aav }
                if clip.audio.needsIsolation { DebugLog.event("audio-source", ["preview": forPreview, "clip": clip.name, "isolation": clip.audio.voiceIsolation, "isolated": isolated != nil, "file": (isolated ?? proxies[audioAsset.id] ?? audioAsset.url).lastPathComponent]) }
                var aclip = clip; if let s = clip.audioSourceIn { aclip.sourceIn = s }
                let asegments = audioAsset.id == asset.id && clip.audioSourceIn == nil ? segments : TimeMap.segments(aclip, assetDuration: audioAsset.duration)
                if let a = audio[slot], let atr = try await aav.loadTracks(withMediaType: .audio).first, let prm = params[slot] {
                    try TimeMap.insert(asegments, of: atr, into: a)
                    // One volume envelope per clip: keyframes × fades × the transition's crossfade, as back-to-back ramps.
                    let head = transitionEnd.map { $0 - clip.start } ?? clip.fadeIn
                    let env = VolumeEnvelope.points(clip, muted: track.isMuted, headFade: head, duck: duckCurves[track.id])
                    prm.setVolume(env.first?.1 ?? volume, at: t(clip.start))
                    for (p0, p1) in zip(env, env.dropFirst()) where p1.0 > p0.0 + 0.0005 {
                        prm.setVolumeRamp(fromStartVolume: p0.1, toEndVolume: p1.1, timeRange: CMTimeRange(start: t(clip.start + p0.0), end: t(clip.start + p1.0)))
                    }
                }
            }
            if track.kind == .video { layerSources.append(sources) }
            audioParams.append(contentsOf: params.compactMap { $0 })
        }

        // Composition tracks that got no media (an empty V1, a stills-only track's audio slots) make the export session
        // fail with "Operation Stopped"; drop them and the mix parameters that point at them.
        let empty = comp.tracks.filter { $0.segments.isEmpty }
        let emptyIDs = Set(empty.map(\.trackID))
        for t in empty { comp.removeTrack(t) }
        audioParams.removeAll { emptyIDs.contains($0.trackID) }

        // Titles, rasterized once per build.
        let texts: [TextLayer] = project.texts.compactMap { tx in
            if let animated = TitleRasterizer.layer(tx, canvas: renderSize) { return animated }   // animated titles, lower thirds (TitleAnimation.swift)
            guard let (img, px) = OverlayLayerBuilder.renderText(tx, canvas: renderSize) else { return nil }
            let ci = CIImage(cgImage: img, options: [.colorSpace: NSNull()])   // rasterized at the screen's backing scale; bring it to render pixels
            let sx = px.width / max(1, ci.extent.width), sy = px.height / max(1, ci.extent.height)
            return TextLayer(text: tx, image: ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), size: px)
        }

        // One instruction per segment between edges (clip starts, ends, transition ends, extended tails), on quantized
        // boundaries: a gap or an empty range makes AVFoundation reject the whole composition ("Operation Stopped").
        let videoComp = AVMutableVideoComposition()
        videoComp.customVideoCompositorClass = compositor
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
        ColorManagement.configure(videoComp, compositor: compositor, color: project.settings.color)   // HDR projects only

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

/// Maps a clip's timeline span onto its media, one constant-rate piece at a time (a speed ramp is many short pieces).
enum TimeMap {
    struct Segment { let sourceStart: Double, sourceEnd: Double, timelineStart: Double, timelineEnd: Double }

    static func segments(_ clip: Clip, assetDuration: Double) -> [Segment] {
        var cuts: [Double] = [0, clip.duration]
        let ks = clip.keyframes(.speed)
        for k in ks where k.time > 0 && k.time < clip.duration { cuts.append(k.time) }
        // Ramped spans (speed changing) get subdivided so each piece can play at one rate.
        for (a, b) in zip(ks, ks.dropFirst()) where a.ease != .hold && abs(a.value - b.value) > 1e-6 {
            var x = max(0, a.time) + 0.1
            while x < min(clip.duration, b.time) { cuts.append(x); x += 0.1 }
        }
        cuts = Array(Set(cuts.map { ($0 * 1000).rounded() / 1000 })).sorted()
        var out: [Segment] = []
        for (t0, t1) in zip(cuts, cuts.dropFirst()) where t1 > t0 {
            let s0 = min(assetDuration, clip.sourceIn + clip.sourceOffset(at: t0))
            let s1 = min(assetDuration, clip.sourceIn + clip.sourceOffset(at: t1))
            out.append(Segment(sourceStart: s0, sourceEnd: s1, timelineStart: clip.start + t0, timelineEnd: clip.start + t1))
        }
        return out
    }

    /// Inserts each piece and stretches it to its timeline length. Ranges are quantized so the pieces tile exactly:
    /// a gap or an empty range makes AVFoundation reject the whole composition.
    static func insert(_ segments: [Segment], of source: AVAssetTrack, into track: AVMutableCompositionTrack) throws {
        let ts = CompositionBuilder.timescale
        let q = { (s: Double) in CMTime(value: CMTimeValue((s * Double(ts)).rounded()), timescale: ts) }
        for seg in segments {
            let at = q(seg.timelineStart), target = q(seg.timelineEnd) - at
            guard target.value > 0 else { continue }
            var src = CMTimeRange(start: q(seg.sourceStart), end: q(seg.sourceEnd))
            if src.duration.value < 1 { src = CMTimeRange(start: src.start, duration: CMTime(value: 1, timescale: ts)) }   // a freeze frame: one tick, held
            try track.insertTimeRange(src, of: source, at: at)
            if src.duration != target { track.scaleTimeRange(CMTimeRange(start: at, duration: src.duration), toDuration: target) }
        }
    }
}

/// A clip's volume over time as (clip-local seconds, volume) breakpoints, for `setVolumeRamp` piece by piece.
enum VolumeEnvelope {
    static func points(_ clip: Clip, muted: Bool, headFade: Double, duck: DuckCurve? = nil) -> [(Double, Float)] {
        if muted { return [(0, 0), (clip.duration, 0)] }
        var times: Set<Double> = [0, clip.duration]
        for t in duck?.times ?? [] where t > clip.start && t < clip.end { times.insert(t - clip.start) }
        let head = min(max(0, headFade), clip.duration), tail = min(max(0, clip.fadeOut), clip.duration)
        if head > 0.01 { times.insert(head) }
        if tail > 0.01 { times.insert(clip.duration - tail) }
        let ks = clip.keyframes(.volume)
        for k in ks where k.time > 0 && k.time < clip.duration { times.insert(k.time) }
        for (a, b) in zip(ks, ks.dropFirst()) where a.ease == .smooth {   // sample the curve so straight ramps follow it
            var x = max(0, a.time) + 0.1
            while x < min(clip.duration, b.time) { times.insert(x); x += 0.1 }
        }
        for (a, b) in zip(ks, ks.dropFirst()) where a.ease == .hold && b.time > 0 && b.time < clip.duration { times.insert(b.time - 0.001) }
        let sorted = times.sorted()
        return sorted.map { lt in
            var f = 1.0
            if head > 0.01, lt < head { f = min(f, max(0, lt / head)) }
            if tail > 0.01, lt > clip.duration - tail { f = min(f, max(0, (clip.duration - lt) / tail)) }
            let d = duck?.factor(at: clip.start + lt) ?? 1
            return (lt, Float(max(0, clip.volume(at: lt) * f * d)))
        }
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
