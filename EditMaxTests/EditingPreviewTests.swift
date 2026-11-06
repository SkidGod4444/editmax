import XCTest
import SwiftUI
import AppKit
@testable import EditMax

/// Looks of the editing features, written as PNGs to $EDITMAX_PREVIEW_DIR (set TEST_RUNNER_EDITMAX_PREVIEW_DIR for
/// xcodebuild) in light and dark appearance. ImageRenderer cannot draw AppKit-backed views (buttons, scroll views,
/// the frame probes behind `.uiFrame`), so the timeline is drawn here from the same pieces the lanes use: ClipBody,
/// SplitEditLane and TrimFeedback, placed the way TimelineView and TimelineBar place them.
@MainActor
final class EditingPreviewTests: XCTestCase {
    static var dir: URL? {
        guard let d = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_DIR"], !d.isEmpty else { return nil }
        let u = URL(fileURLWithPath: d); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }

    /// Renders `view` in both appearances as <name>-light.png and <name>-dark.png.
    static func write<V: View>(_ name: String, width: CGFloat, height: CGFloat, darkOnly: Bool = false, @ViewBuilder _ view: () -> V) throws {
        guard let dir else { throw XCTSkip("set TEST_RUNNER_EDITMAX_PREVIEW_DIR to write previews") }
        let saved = NSApp.appearance
        defer { NSApp.appearance = saved }
        for (suffix, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] where !darkOnly || suffix == "dark" {
            NSApp.appearance = NSAppearance(named: appearance)
            let content = view().frame(width: width, height: height).environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.94))   // window background, fixed (dynamic NSColors resolve against the drawing appearance)
            let r = ImageRenderer(content: content)
            r.scale = 2
            var rendered: CGImage?
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { rendered = r.cgImage }
            let img = try XCTUnwrap(rendered, "render \(name)")
            let rep = NSBitmapImageRep(cgImage: img)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    /// Thumbnail frames that change colour over the source, so a slip visibly shows other frames.
    static func strip(seconds: Int, hue0: Double) -> ThumbnailStore.Strip {
        let frames: [CGImage] = (0..<seconds).map { i in
            let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let c = NSColor(hue: (hue0 + Double(i) * 0.045).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.75, alpha: 1)
            ctx.setFillColor(c.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor); ctx.fillEllipse(in: CGRect(x: 8 + (i * 7) % 40, y: 10, width: 16, height: 16))
            return ctx.makeImage()!
        }
        return ThumbnailStore.Strip(interval: 1, frames: frames, aspect: 16 / 9)
    }
    static func peaks(seconds: Double, seed: Double) -> [Float] {
        let n = Int(seconds * Double(WaveformStore.peaksPerSecond))
        return (0..<n).map { i in let t = Double(i) / Double(WaveformStore.peaksPerSecond); return Float(0.25 + 0.55 * abs(sin(t * 2.3 + seed)) * (0.6 + 0.4 * sin(t * 9.1 + seed * 2))) }
    }

    /// One drag in progress on a bar.
    struct Drag { var clip: UUID; var kind: TrimDragKind; var amount: Double; var limited = false; var context: TrimDragContext }

    /// Lanes as TimelineView draws them: a ruler, then per track the bars (ClipBody, offset by start), the split-edit
    /// marks and, for the dragged bar, the width/offset change and TrimFeedback overlay TimelineBar adds.
    struct Lanes: View {
        let project: Project
        let pps: CGFloat
        var drags: [Drag] = []
        var selected: Set<UUID> = []
        let strips: [UUID: ThumbnailStore.Strip]
        let peaks: [UUID: [Float]]
        private let rowHeight: CGFloat = 66
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.18)))
                    var t = 0.0
                    while CGFloat(t) * pps < size.width {
                        let x = CGFloat(t) * pps
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height)); $0.addLine(to: CGPoint(x: x, y: size.height - 9)) }, with: .color(.primary.opacity(0.5)), lineWidth: 1)
                        ctx.draw(Text(Timecode.string(t)).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.secondary), at: CGPoint(x: x + 4, y: 7), anchor: .leading)
                        t += 1
                    }
                }
                .frame(height: 24)
                Divider()
                ForEach(project.tracks.filter { !$0.clips.isEmpty }) { track in
                    ZStack(alignment: .leading) {
                        Color.clear
                        ForEach(track.clips) { clip in bar(clip, track: track) }
                        if track.clips.contains(where: \.hasSplitEdit) {
                            SplitEditLane(clips: track.clips, project: project, pps: pps, rowHeight: rowHeight, barHeight: rowHeight - 10, peaks: peaks)
                        }
                    }
                    .frame(height: rowHeight)
                    Divider()
                }
                Spacer(minLength: 0)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }

        @ViewBuilder private func bar(_ clip: Clip, track: Track) -> some View {
            let h = rowHeight - 10, fullW = CGFloat(clip.duration) * pps
            let d = drags.first { $0.clip == clip.id }
            let px = d.map { CGFloat($0.amount) * pps } ?? 0
            let rollL: CGFloat = d?.kind == .roll(leading: true) ? px : 0, rollR: CGFloat = d?.kind == .roll(leading: false) ? px : 0
            let slide: CGFloat = d?.kind == .slide ? px : 0
            ClipBody(clip: clip, kind: track.kind, selected: selected.contains(clip.id) || d != nil, height: h, pps: pps, peaks: peaks[clip.assetID] ?? [], strip: strips[clip.assetID])
                .frame(width: max(4, fullW - rollL + rollR), height: h)
                .overlay(alignment: .topLeading) {
                    if let d {
                        TrimFeedback(kind: d.kind, amount: d.amount, limited: d.limited, context: d.context, clip: clip, assetDuration: project.asset(clip.assetID)?.duration,
                                     strip: strips[clip.assetID], peaks: peaks[clip.assetID] ?? [], pps: pps, width: fullW, height: h, shift: rollL + slide)
                    }
                }
                .offset(x: CGFloat(clip.start) * pps + rollL + slide)
                .zIndex(d != nil ? 1 : 0)
        }
    }

    private func project() -> (EditMaxDocument, ToolExecutor) {
        let doc = EditMaxDocument()
        doc.project.assets = [Asset(name: "interview.mp4", path: "/tmp/editing-preview-a.mp4", kind: .video, duration: 20, width: 1920, height: 1080),
                              Asset(name: "street.mp4", path: "/tmp/editing-preview-b.mp4", kind: .video, duration: 20, width: 1920, height: 1080)]
        return (doc, ToolExecutor(document: doc, origin: .agent))
    }
    private func media(_ p: Project) -> ([UUID: ThumbnailStore.Strip], [UUID: [Float]]) {
        (Dictionary(uniqueKeysWithValues: p.assets.enumerated().map { ($1.id, Self.strip(seconds: 20, hue0: $0 == 0 ? 0.58 : 0.08)) }),
         Dictionary(uniqueKeysWithValues: p.assets.enumerated().map { ($1.id, Self.peaks(seconds: 20, seed: Double($0) * 1.7)) }))
    }

    func testTimelineShowsJAndLCuts() throws {
        let (doc, x) = project()
        let a = try x.insertClip(asset: "interview.mp4", sourceIn: 3, duration: 4)
        let b = try x.insertClip(asset: "street.mp4", sourceIn: 5, duration: 4)
        let c = try x.insertClip(asset: "interview.mp4", sourceIn: 9, duration: 3.5)
        _ = try x.setSplitEdit(a.id.short, lead: nil, trail: 1.5, neighbour: nil)   // L cut: the interview runs on under the street shot
        _ = try x.setSplitEdit(c.id.short, lead: 1.25, trail: nil, neighbour: nil)  // J cut: we hear the interview before we see it
        // Second lane: a J cut with the neighbour trimmed, so the street's sound stops where the interview's starts.
        let v2 = doc.project.addTrack(kind: .video)
        let d = try x.insertClip(asset: "street.mp4", track: v2.id.uuidString, sourceIn: 2, duration: 5)
        let e = try x.insertClip(asset: "interview.mp4", track: v2.id.uuidString, sourceIn: 12, duration: 5)
        _ = d
        _ = try x.setSplitEdit(e.id.short, lead: 1.5, trail: nil, neighbour: "trim")
        let (strips, peaks) = media(doc.project)
        let p = doc.project
        try Self.write("timeline-split-edits", width: 900, height: 190) {
            Lanes(project: p, pps: 64, selected: [c.id], strips: strips, peaks: peaks)
        }
        _ = b
    }

    func testTimelineShowsTrimsInProgress() throws {
        let (doc, x) = project()
        // Three lanes, one drag each: roll the cut, slip the middle clip, slide the middle clip.
        var ids: [[Clip]] = []
        for i in 0..<3 {
            let t = i == 0 ? doc.project.tracks.first { $0.kind == .video }! : doc.project.addTrack(kind: .video)
            let a = try x.insertClip(asset: "interview.mp4", track: t.id.uuidString, sourceIn: 2, duration: 4)
            let b = try x.insertClip(asset: "street.mp4", track: t.id.uuidString, sourceIn: 6, duration: 4)
            let c = try x.insertClip(asset: "interview.mp4", track: t.id.uuidString, sourceIn: 10, duration: 3)
            for (clip, name) in [(a, "Wide"), (b, "Street"), (c, "Close")] { try x.setClipProperties(clip.id.uuidString, name: name) }
            ids.append([a, b, c].map { doc.project.clip($0.id)!.clip })
        }
        let p = doc.project
        let roll = try p.rollLimits(ids[0][0].id, atEnd: true), pair = try p.rollPair(ids[0][0].id, atEnd: true)
        let slip = try p.slipLimits(ids[1][1].id)
        let slide = try p.slideLimits(ids[2][1].id)
        let drags = [
            Drag(clip: ids[0][0].id, kind: .roll(leading: false), amount: 1.25, context: TrimDragContext(limits: roll, previousName: pair.a.name, nextName: pair.b.name)),
            Drag(clip: ids[1][1].id, kind: .slip, amount: 2.5, context: TrimDragContext(limits: slip)),
            Drag(clip: ids[2][1].id, kind: .slide, amount: -1.0, context: TrimDragContext(limits: slide.limits, previousName: slide.previous?.name, nextName: slide.next?.name)),
        ]
        let (strips, peaks) = media(p)
        try Self.write("timeline-trims", width: 900, height: 250) {
            Lanes(project: p, pps: 64, drags: drags, strips: strips, peaks: peaks)
        }
        // A drag past a limit: the tag turns orange and names the limit.
        let limited = [Drag(clip: ids[0][0].id, kind: .roll(leading: false), amount: roll.later, limited: true, context: TrimDragContext(limits: roll, previousName: pair.a.name, nextName: pair.b.name))]
        try Self.write("timeline-roll-limit", width: 900, height: 120) {
            Lanes(project: { var q = p; q.tracks = [q.tracks.first { $0.clips.contains { $0.id == ids[0][0].id } }!]; return q }(), pps: 64, drags: limited, strips: strips, peaks: peaks)
        }
    }
}
