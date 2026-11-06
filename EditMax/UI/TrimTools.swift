import SwiftUI

// MARK: - Timeline trim tools (roll, slip, slide) and split-edit marks
//
// The timeline has one edit tool at a time. Select is today's behaviour (edges trim, body moves). Roll: an edge drag
// moves the cut between the clip and its touching neighbour. Slip: a body drag shows other media in the same place.
// Slide: a body drag moves the clip between its neighbours, which trim. Edges keep trimming under slip and slide, the
// body keeps moving under roll, so every tool still does the plain thing on the other part of the bar.

enum EditTool: String, CaseIterable, Identifiable {
    case select, roll, slip, slide
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// The plain key that picks the tool (EditorActions.handle).
    var key: String { switch self { case .select: "a"; case .roll: "r"; case .slip: "y"; case .slide: "u" } }
    init?(key: String) { guard let t = Self.allCases.first(where: { $0.key == key }) else { return nil }; self = t }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .roll: "arrowtriangle.left.and.line.vertical.and.arrowtriangle.right"
        case .slip: "arrow.left.arrow.right.square"
        case .slide: "rectangle.split.3x1"
        }
    }
    var help: String {
        switch self {
        case .select: "Select (A): drag a clip to move it, its edges to trim"
        case .roll: "Roll (R): drag the edge between two touching clips to move the cut; one gets longer, the other shorter"
        case .slip: "Slip (Y): drag a clip to show an earlier or later part of its media in the same place"
        case .slide: "Slide (U): drag a clip between its neighbours; they get longer or shorter to make room"
        }
    }
}

/// The four tool buttons in the timeline toolbar.
struct TrimToolPicker: View {
    @Binding var tool: EditTool
    var body: some View {
        HStack(spacing: 0) {
            ForEach(EditTool.allCases) { t in
                Button { tool = t } label: {
                    Image(systemName: t.symbol).font(.system(size: 12, weight: .medium)).imageScale(.medium)
                        .frame(width: 24, height: 22)
                        .background(tool == t ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .foregroundStyle(tool == t ? Color.accentColor : Color.primary)
                        .contentShape(Rectangle())
                }
                .focusable(false)
                .help(t.help)
                .pointer()
                .uiFrame("timeline.tool.\(t.rawValue)")
            }
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// What a bar drag does under a trim tool.
enum TrimDragKind: Equatable {
    case roll(leading: Bool), slip, slide
    var title: String { switch self { case .roll: "Roll"; case .slip: "Slip"; case .slide: "Slide" } }
}

/// Facts a trim drag needs, read once when it begins.
struct TrimDragContext {
    var limits: Project.MoveLimits?   // nil with `refusal`
    var refusal: String?              // why the drag does nothing ("no clip touches this edge")
    var previousName: String?
    var nextName: String?
}

/// A trim tool's hooks into one timeline bar (nil for texts: they only move and trim).
struct BarEditing {
    var tool: EditTool
    var clip: Clip
    var assetDuration: Double?      // nil for stills
    var strip: ThumbnailStore.Strip?
    var peaks: [Float]
    var context: (TrimDragKind) -> TrimDragContext
    /// Commits a drag: timeline seconds for roll and slide, source seconds for slip.
    var commit: (TrimDragKind, Double) -> Void

    /// The kind a drag on the body (`edge` nil) or an edge starts under this tool, nil for the plain move/trim.
    func kind(edge leading: Bool?) -> TrimDragKind? {
        switch (tool, leading) {
        case (.roll, let l?): return .roll(leading: l)
        case (.slip, nil): return .slip
        case (.slide, nil): return .slide
        default: return nil
        }
    }

    /// A horizontal drag of `dx` points turned into the edit's amount: roll and slide follow the mouse in timeline
    /// seconds; slip moves the media with the mouse (dragging right shows earlier media), in source seconds.
    func amount(_ kind: TrimDragKind, dx: CGFloat, pps: CGFloat) -> Double {
        let t = Double(dx / max(1, pps))
        return kind == .slip ? -t * clip.speed : t
    }

    /// The amount clamped to the drag's limits, and whether it hit one.
    static func clamp(_ v: Double, _ l: Project.MoveLimits?) -> (value: Double, limited: Bool) {
        guard let l else { return (0, true) }
        if v > l.later { return (l.later, true) }
        if -v > l.earlier { return (-l.earlier, true) }
        return (v, false)
    }

    /// The context a TimelineView bar uses: limits from the project as it is when the drag starts.
    @MainActor
    static func make(clip: Clip, track: Track, document: EditMaxDocument, tool: EditTool, strip: ThumbnailStore.Strip?, peaks: [Float]) -> BarEditing? {
        guard tool != .select else { return nil }
        let asset = document.project.asset(clip.assetID)
        let x = ToolExecutor(document: document, origin: .user)
        return BarEditing(tool: tool, clip: clip, assetDuration: asset?.kind == .image ? nil : asset?.duration, strip: strip, peaks: peaks,
            context: { kind in
                let p = document.project
                do {
                    switch kind {
                    case .roll(let leading):
                        let l = try p.rollLimits(clip.id, atEnd: !leading)
                        let pair = try p.rollPair(clip.id, atEnd: !leading)
                        return TrimDragContext(limits: l, previousName: pair.a.name, nextName: pair.b.name)
                    case .slip:
                        return TrimDragContext(limits: try p.slipLimits(clip.id))
                    case .slide:
                        let s = try p.slideLimits(clip.id)
                        return TrimDragContext(limits: s.limits, previousName: s.previous?.name, nextName: s.next?.name)
                    }
                } catch {
                    let msg = (error as? EditError).map { e -> String in if case .invalid(let s) = e { return s }; return e.localizedDescription } ?? error.localizedDescription
                    return TrimDragContext(limits: nil, refusal: msg)
                }
            },
            commit: { kind, v in
                guard abs(v) > 1e-4 else { return }
                let r = (v * 1000).rounded() / 1000
                switch kind {
                case .roll(let leading): _ = try? x.rollEdit(clip.id.uuidString, edge: leading ? "start" : "end", delta: r, to: nil)
                case .slip: _ = try? x.slipClip(clip.id.uuidString, delta: r, sourceIn: nil)
                case .slide: _ = try? x.slideClip(clip.id.uuidString, delta: r, to: nil)
                }
            })
    }
}

/// Live feedback for a roll, slip or slide in progress, drawn over the dragged bar in the bar's original coordinates
/// (x 0 = where the bar started before the drag, `width` = its length then): the region a neighbour gains, the new
/// cut or edges, the whole source sliding under a slipped clip, and a tag with the amount above the bar.
struct TrimFeedback: View {
    let kind: TrimDragKind
    let amount: Double          // clamped; timeline s (roll, slide) or source s (slip)
    let limited: Bool
    let context: TrimDragContext
    let clip: Clip
    let assetDuration: Double?
    let strip: ThumbnailStore.Strip?
    let peaks: [Float]
    let pps: CGFloat
    let width: CGFloat
    let height: CGFloat
    /// How far the bar's own leading edge has moved in this drag (points), which the overlay undoes.
    var shift: CGFloat = 0

    private let margin: CGFloat = 1600
    private let tagHeight: CGFloat = 20
    private var px: CGFloat { CGFloat(amount) * pps }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(width: width + 2 * margin, height: height + tagHeight + 4)
            if kind == .slip, context.refusal == nil { slipWindow.offset(x: margin, y: tagHeight + 4) }
            tag.fixedSize().offset(x: margin + tagX, y: 0)
        }
        .frame(width: width + 2 * margin, height: height + tagHeight + 4, alignment: .topLeading)
        .offset(x: -margin - shift, y: -tagHeight - 4)
        .allowsHitTesting(false)
    }

    /// The slipped clip's new frames and sound in its unchanged window.
    private var slipWindow: some View {
        let inT = clip.sourceIn + amount, outT = clip.sourceOut + amount
        return VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.35)
                if let strip, !strip.frames.isEmpty { ThumbnailStripView(strip: strip, sourceIn: inT, sourceOut: outT) }
            }
            .frame(height: height - 18)
            ZStack {
                Color.black.opacity(0.45)
                if !peaks.isEmpty { WaveformView(peaks: peaks, sourceIn: inT, sourceOut: outT, color: .white.opacity(0.8)).padding(.vertical, 2) }
            }
            .frame(height: 18)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
    }

    private var tagX: CGFloat {
        switch kind {
        case .roll(let leading): return (leading ? 0 : width) + px - 30
        case .slide: return px
        case .slip: return 0
        }
    }

    private var tagText: String {
        if let r = context.refusal { return r }
        var s = "\(kind.title) \(EditFormat.signed(amount)) s"
        switch kind {
        case .slip:
            s += "   in \(Timecode.string(clip.sourceIn + amount))   out \(Timecode.string(clip.sourceOut + amount))"
        case .roll(let leading):
            _ = leading
            if let a = context.previousName, let b = context.nextName, abs(amount) > 1e-6 {
                s += amount > 0 ? "   \(a) longer, \(b) shorter" : "   \(b) longer, \(a) shorter"
            }
        case .slide:
            if amount > 0 { s += [context.previousName.map { "   \($0) longer" }, context.nextName.map { ", \($0) shorter" }].compactMap { $0 }.joined() }
            else if amount < 0 { s += [context.previousName.map { "   \($0) shorter" }, context.nextName.map { ", \($0) longer" }].compactMap { $0 }.joined() }
        }
        if limited, let l = context.limits { return "\(kind.title) \(EditFormat.signed(amount)) s   limit: \(amount > 0 ? l.laterWhy : l.earlierWhy)" }
        return s
    }

    private var tag: some View {
        Text(tagText).font(.system(size: 10, weight: .semibold)).monospacedDigit().lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 7).frame(height: tagHeight)
            .background((context.refusal != nil || limited ? Color.orange : Color.accentColor).opacity(0.95), in: Capsule())
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard context.refusal == nil else { return }
        let top = tagHeight + 4, h = height, m = margin
        let ghost = Color.white.opacity(0.22), line = Color.accentColor
        func rect(_ x0: CGFloat, _ x1: CGFloat) -> CGRect { CGRect(x: m + min(x0, x1), y: top, width: abs(x1 - x0), height: h) }
        func vline(_ x: CGFloat) { ctx.fill(Path(CGRect(x: m + x - 1, y: top - 3, width: 2, height: h + 6)), with: .color(line)) }
        func dashed(_ r: CGRect) { ctx.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
        func label(_ s: String, at x: CGFloat) {
            ctx.draw(Text(s).font(.system(size: 9, weight: .semibold)).foregroundColor(.white), at: CGPoint(x: m + x, y: top + h / 2), anchor: .center)
        }
        switch kind {
        case .roll(let leading):
            let cut: CGFloat = leading ? 0 : width, to = cut + px
            // The cut's old place, dashed; the stretch that changes hands, tinted.
            let changed = rect(cut, to)
            ctx.fill(Path(roundedRect: changed, cornerRadius: 3), with: .color(ghost))
            dashed(changed)
            if abs(px) > 34 { label(EditFormat.signed(amount) + " s", at: (cut + to) / 2) }
            vline(to)
        case .slide:
            // The bar's old place, and the gap it leaves, which the neighbour on that side fills.
            dashed(rect(0, width))
            let vacated = px > 0 ? rect(0, px) : rect(width + px, width)
            ctx.fill(Path(roundedRect: vacated, cornerRadius: 3), with: .color(ghost))
            if abs(px) > 40, let n = px > 0 ? context.previousName : context.nextName { label(n, at: px > 0 ? px / 2 : width + px / 2) }
            vline(px); vline(width + px)
        case .slip:
            // The whole source as a dim strip that slides under the fixed window.
            let inT = clip.sourceIn + amount, outT = clip.sourceOut + amount
            let speed = max(1e-4, clip.speed)
            let left = -CGFloat(inT / speed) * pps
            let right = assetDuration.map { width + CGFloat(($0 - outT) / speed) * pps } ?? width
            let r = CGRect(x: m + max(-m, left), y: top - 2, width: min(width + m, right) - max(-m, left), height: h + 4)
            ctx.fill(Path(roundedRect: r, cornerRadius: 7), with: .color(.black.opacity(0.35)))
            ctx.stroke(Path(roundedRect: r, cornerRadius: 7), with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if left > -m + 2 { ctx.draw(Text("media start").font(.system(size: 8, weight: .medium)).foregroundColor(.white.opacity(0.8)), at: CGPoint(x: m + left + 4, y: top + h - 7), anchor: .leading) }
            if right < width + m - 2, assetDuration != nil { ctx.draw(Text("media end").font(.system(size: 8, weight: .medium)).foregroundColor(.white.opacity(0.8)), at: CGPoint(x: m + right - 4, y: top + h - 7), anchor: .trailing) }
        }
    }
}

/// J and L cuts on a video lane: the part of a clip's sound that runs before or after its picture, drawn as a sound
/// tongue sticking out of the clip's waveform band (green, with its waveform and a "J 1.00 s" / "L 1.00 s" label),
/// and a hatched band where a negative lead or trail leaves the picture without its sound. Never takes clicks.
struct SplitEditLane: View {
    let clips: [Clip]
    let project: Project
    let pps: CGFloat
    let rowHeight: CGFloat
    let barHeight: CGFloat
    let peaks: [UUID: [Float]]

    private let band: CGFloat = 18

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(clips.filter(\.hasSplitEdit)) { c in marks(c) }
        }
        .frame(height: rowHeight)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func marks(_ c: Clip) -> some View {
        let s = c.soundClip()
        let sid = project.soundAsset(of: c)?.id ?? c.assetID
        let p = peaks[sid] ?? []
        let audioIn = c.audioSourceIn ?? c.sourceIn
        let audioOut = audioIn + c.sourceOffset(at: c.duration)
        let barTop = (rowHeight - barHeight) / 2
        let y = barTop + barHeight - band + 3
        if c.audioLead > 1e-9 {
            tongue(width: CGFloat(c.audioLead) * pps, peaks: p, sourceIn: s.sourceIn, sourceOut: audioIn, label: "J \(EditFormat.s(c.audioLead)) s", leading: true)
                .offset(x: CGFloat(c.soundStart) * pps, y: y)
        } else if c.audioLead < -1e-9 {
            silence(width: CGFloat(-c.audioLead) * pps).offset(x: CGFloat(c.start) * pps, y: y - 3)
        }
        if c.audioTrail > 1e-9 {
            tongue(width: CGFloat(c.audioTrail) * pps, peaks: p, sourceIn: audioOut, sourceOut: s.sourceOut, label: "L \(EditFormat.s(c.audioTrail)) s", leading: false)
                .offset(x: CGFloat(c.end) * pps, y: y)
        } else if c.audioTrail < -1e-9 {
            silence(width: CGFloat(-c.audioTrail) * pps).offset(x: CGFloat(c.soundEnd) * pps, y: y - 3)
        }
    }

    private func tongue(width: CGFloat, peaks: [Float], sourceIn: Double, sourceOut: Double, label: String, leading: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: leading ? 5 : 0, bottomLeadingRadius: leading ? 5 : 0, bottomTrailingRadius: leading ? 0 : 5, topTrailingRadius: leading ? 0 : 5)
        return ZStack(alignment: leading ? .leading : .trailing) {
            shape.fill(Color(red: 0.13, green: 0.5, blue: 0.33).opacity(0.95))
            if !peaks.isEmpty { WaveformView(peaks: peaks, sourceIn: sourceIn, sourceOut: sourceOut, color: .white.opacity(0.75)).padding(.vertical, 2) }
            if width > 34 {
                Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 3).background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3)).padding(.horizontal, 3)
            }
        }
        .frame(width: max(2, width), height: band)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.7), lineWidth: 1))
    }

    private func silence(width: CGFloat) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
            var x: CGFloat = -size.height
            while x < size.width { ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height)); $0.addLine(to: CGPoint(x: x + size.height, y: 0)) }, with: .color(.white.opacity(0.35)), lineWidth: 1); x += 5 }
            if size.width > 40 { ctx.draw(Text("no sound").font(.system(size: 8, weight: .semibold)).foregroundColor(.white), at: CGPoint(x: size.width / 2, y: size.height / 2)) }
        }
        .frame(width: max(1, width), height: band)
        .clipped()
    }
}

/// Trim limits for the plain edge drags: the old formula for a clip without a split edit (unchanged behaviour), the
/// media room for one with a J/L cut, whose sound needs media beyond the picture's edges.
enum TrimLimitsUI {
    static func minStart(_ c: Clip, asset: Asset?, project: Project) -> Double {
        c.hasSplitEdit ? c.start - project.mediaRoom(c).head : c.start - c.sourceIn / c.speed
    }
    static func maxEnd(_ c: Clip, asset: Asset?, project: Project) -> Double {
        c.hasSplitEdit ? c.end + project.mediaRoom(c).tail : c.start + ((asset?.duration ?? c.end) - c.sourceIn) / c.speed
    }
}
