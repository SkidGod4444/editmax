import SwiftUI

/// The clip inspector's editing cards: the J/L cut (sound before / after the picture) and, for clips slower than 1×,
/// smooth slow motion. One line in ClipInspector adds them.
struct EditingInspectorCards: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    let track: Track
    @State private var trimNeighbour = false
    @State private var note: String?

    private var asset: Asset? { document.project.asset(clip.assetID) }
    /// Slider drags make one undo step.
    private var x: ToolExecutor { ToolExecutor(document: document, origin: .user, coalesce: true) }

    var body: some View {
        if track.kind == .video, asset?.kind == .video { splitEditCard.revealAnchor(.splitEdit) }
        if track.kind == .video, asset?.kind == .video, clip.multicam == nil, InterpolatedVideo.slowest(clip) < 0.999 || clip.smoothSlowMotion != .off { SlowMotionCard(document: document, clip: clip).revealAnchor(.slowMotion) }
        if track.kind == .video, asset?.kind == .video || asset?.kind == .sequence, clip.multicam == nil { SceneCutsCard(document: document, clip: clip).revealAnchor(.scenes) }
    }

    // MARK: J / L cut

    private var splitEditCard: some View {
        let p = document.project
        var plain = clip; plain.audioLead = 0; plain.audioTrail = 0
        let room = p.mediaRoom(plain), minLen = p.minClipLength
        let maxLead = max(0, min(5, room.head, clip.start)), maxTrail = max(0, min(5, room.tail))
        let maxInside = max(0, min(5, clip.duration - minLen) / 2)
        let footer = note ?? "A J cut starts the sound before the picture, an L cut lets it run on after; the extra sound is the clip's own media past its in and out (\(EditFormat.s(room.head)) s before, \(EditFormat.s(room.tail)) s after). Under a neighbour both sounds play, unless Neighbour is set to trim."
        return InspectorCard("Split edit", footer: footer, trailing: {
            if clip.hasSplitEdit {
                Button("Reset") { set(lead: 0, trail: 0, coalesce: false) }.controlSize(.mini).pointer().uiFrame("inspector.splitEdit.reset")
            }
        }) {
            InspectorValueRow("Kind", ToolExecutor.splitEditKind(clip) == "none" ? "Sound with picture" : ToolExecutor.splitEditKind(clip))
            row("Lead", key: "lead", value: clip.audioLead, range: -maxInside...max(maxLead, 0.01)) { set(lead: $0, trail: nil, coalesce: true) }
            row("Trail", key: "trail", value: clip.audioTrail, range: -maxInside...max(maxTrail, 0.01)) { set(lead: nil, trail: $0, coalesce: true) }
            InspectorRow("Neighbour") {
                Picker("Neighbour", selection: $trimNeighbour) {
                    Text("Overlap").tag(false)
                    Text("Trim").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 130).pointer().uiFrame("inspector.splitEdit.neighbour")
                .help("Overlap: both sounds play where they meet. Trim: the touching neighbour's sound stops (or starts) where this one starts (or stops).")
            }
        }
    }

    private func row(_ title: String, key: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).inspectorLabel()
            Slider(value: .init(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { v in set(abs(v) < 0.02 ? 0 : (v * 100).rounded() / 100) }), in: range)
                .controlSize(.small).pointer().uiFrame("inspector.splitEdit.\(key).slider")
                .help(title == "Lead" ? "Seconds the sound starts before the picture (left of 0: after it)" : "Seconds the sound runs on after the picture (left of 0: stops before it)")
            Text(abs(value) < 0.005 ? "0" : String(format: "%+.2f s", value)).inspectorValue()
                .onTapGesture(count: 2) { set(0) }.help("Double-click to put the sound back with the picture").pointer()
                .uiFrame("inspector.splitEdit.\(key).reset").uiTap("inspector.splitEdit.\(key).reset", count: 2) { set(0) }
        }
    }

    private func set(lead: Double?, trail: Double?, coalesce: Bool) {
        let ex = ToolExecutor(document: document, origin: .user, coalesce: coalesce)
        do {
            let r = try ex.setSplitEdit(clip.id.uuidString, lead: lead, trail: trail, neighbour: trimNeighbour ? "trim" : "overlap")
            note = r.overlaps?.first
        } catch {
            note = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

/// "Scenes": find the hard cuts in the clip's media, show them over the difference curve, then split the clip at
/// them or mark them. The sensitivity slider re-picks the cuts from the same scan (no second read).
struct SceneCutsCard: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    @State var scan: (clip: UUID, range: ClosedRange<Double>, result: SceneDetector.Result)? = nil
    @State var sensitivity = SceneDetector.defaultSensitivity
    @State private var busy = false
    @State var note: String?

    private var picked: SceneDetector.Result? {
        guard let scan, scan.clip == clip.id else { return nil }
        return SceneDetector.pick(times: scan.result.times, diffs: scan.result.diffs, sensitivity: sensitivity, minScene: 0.5)
    }

    var body: some View {
        let found = picked
        let footer = note ?? Self.summary(found)
        return InspectorCard("Scenes", footer: footer, trailing: { EmptyView() }) {
            if let found, let scan {
                SceneCurve(result: found, range: scan.range).frame(height: 44)
                HStack(spacing: 8) {
                    Text("Sensitivity").inspectorLabel()
                    Slider(value: $sensitivity, in: 0...1).controlSize(.small).pointer().editFrame("inspector.scenes.sensitivity")
                        .help("Higher finds smaller jumps")
                    Text(String(format: "%.2f", sensitivity)).inspectorValue()
                }
                HStack(spacing: 8) {
                    Button("Split at Scene Cuts") { apply("split", found) }.controlSize(.small).focusable(false).pointer().disabled(found.cuts.isEmpty).editFrame("inspector.scenes.split")
                    Button("Add Markers") { apply("markers", found) }.controlSize(.small).focusable(false).pointer().disabled(found.cuts.isEmpty).editFrame("inspector.scenes.markers")
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    Button(busy ? "Looking…" : "Find Scene Cuts") { find() }.controlSize(.small).focusable(false).pointer().disabled(busy).editFrame("inspector.scenes.find")
                    if busy { ProgressView().controlSize(.mini) }
                    Spacer()
                }
            }
        }
    }

    static func summary(_ found: SceneDetector.Result?) -> String {
        guard let found else { return "Looks for hard cuts (shot changes) in this clip's media. Dissolves and fades are not cuts." }
        let n = found.cuts.count
        if n == 0 { return "No hard cuts at this sensitivity." }
        let times: [String] = found.cuts.prefix(6).map { EditFormat.s($0.time) + " s" }
        let more = n > 6 ? "…" : ""
        return "\(n) cut\(n == 1 ? "" : "s") at \(times.joined(separator: ", "))\(more) (source time)."
    }

    private func find() {
        guard let a = document.project.asset(clip.assetID) else { return }
        guard !Relink.isMissing(a) else { note = "\(a.name) is missing; relink it first."; return }
        let (from, to) = ToolExecutor.sourceRange(clip)
        let id = clip.id, url = a.url
        busy = true; note = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let r = try await SceneDetector.detect(url: url, from: from, to: to, sensitivity: sensitivity, minScene: 0.5)
                scan = (id, from...to, r)
            } catch { note = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }

    private func apply(_ action: String, _ found: SceneDetector.Result) {
        do {
            let r = try ToolExecutor(document: document, origin: .user).applySceneCuts(clip.id, sourceTimes: found.cuts.map(\.time), action: action)
            note = action == "split" ? "Split into \(r.clips?.count ?? 1) clips." : "Added \(r.markers?.count ?? 0) markers."
            scan = nil
        } catch { note = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }
}

/// The frame-difference curve (grey), the adaptive threshold (dashed) and the picked cuts (accent ticks).
struct SceneCurve: View {
    let result: SceneDetector.Result
    let range: ClosedRange<Double>
    var body: some View {
        Canvas { ctx, size in
            let span = max(1e-6, range.upperBound - range.lowerBound)
            func x(_ t: Double) -> CGFloat { CGFloat((t - range.lowerBound) / span) * size.width }
            func y(_ v: Double) -> CGFloat { size.height - 2 - CGFloat(min(1, v)) * (size.height - 4) }
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 5), with: .color(.primary.opacity(0.05)))
            var curve = Path(), th = Path()
            for (i, t) in result.times.enumerated() {
                let pd = CGPoint(x: x(t), y: y(result.diffs[i])), pt = CGPoint(x: x(t), y: y(result.threshold[i]))
                if i == 0 { curve.move(to: pd); th.move(to: pt) } else { curve.addLine(to: pd); th.addLine(to: pt) }
            }
            ctx.stroke(th, with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            ctx.stroke(curve, with: .color(.secondary), lineWidth: 1)
            for c in result.cuts {
                var tick = Path(); tick.move(to: CGPoint(x: x(c.time), y: 0)); tick.addLine(to: CGPoint(x: x(c.time), y: size.height))
                ctx.stroke(tick, with: .color(.accentColor), lineWidth: 2)
            }
        }
        .accessibilityLabel("\(result.cuts.count) scene cuts")
    }
}

/// "Smooth slow motion" for a clip slower than 1×: Off / Blend / Optical flow, with the render's progress.
struct SlowMotionCard: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    @ObservedObject private var cache = InterpolatedVideo.shared
    @State private var note: String?

    var body: some View {
        let a = document.project.asset(clip.assetID)
        let job = a.flatMap { InterpolatedVideo.job(clip, $0, fps: document.project.settings.fps) }
        return InspectorCard("Smooth slow motion", footer: note ?? footer(job), trailing: { EmptyView() }) {
            InspectorRow("Frames") {
                Picker("Frames", selection: .init(get: { clip.smoothSlowMotion }, set: { set($0) })) {
                    Text("Repeat").tag(SlowMotionMode.off)
                    Text("Blend").tag(SlowMotionMode.blend)
                    Text("Optical flow").tag(SlowMotionMode.opticalFlow)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 210).pointer().editFrame("inspector.slowMotion.mode")
                .help("How the in-between frames of this slow clip are made: repeated, blended from the two neighbours, or drawn along the motion")
            }
        }
    }

    private func footer(_ job: InterpolatedVideo.Job?) -> String {
        guard clip.smoothSlowMotion != .off else { return "At \(String(format: "%.2g", InterpolatedVideo.slowest(clip)))× each source frame shows several times. Blend or optical flow renders the in-between frames once, in the background." }
        guard let job else { return "Takes effect while the clip is slower than 1×." }
        let how = job.method == .opticalFlow ? "optical flow" : "blend" + (clip.smoothSlowMotion == .opticalFlow ? " (optical flow is not available on this Mac)" : "")
        if let f = cache.progress[job.key] { return "Rendering \(Int(f * 100)) % · \(Int(job.fps)) frames per source second, \(how)" }
        if let e = cache.failed[job.key] { return "Render failed: \(e)" }
        if FileManager.default.fileExists(atPath: job.url.path) { return "Ready: \(Int(job.fps)) frames per source second, \(how). The export uses it too." }
        return "Waiting to render (\(how))."
    }

    private func set(_ m: SlowMotionMode) {
        let x = ToolExecutor(document: document, origin: .user)
        let id = clip.id.uuidString
        Task { @MainActor in
            do { let r = try await x.setSmoothSlowMotion(id, mode: m.rawValue, wait: false); note = r.note }
            catch { note = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }
}
