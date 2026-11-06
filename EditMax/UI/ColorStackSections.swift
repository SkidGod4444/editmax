import SwiftUI
import Combine

/// The clip inspector's color sections after the look: shot match, grade layers (with the selected layer's own
/// controls and mask) and finishing. One line in `ClipInspector` shows them for video clips.
struct ColorStackSections: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    @State private var selected: UUID?
    @Environment(\.reveal) private var reveal

    var body: some View {
        ShotMatchCard(document: document, clip: clip).revealAnchor(.shotMatch)
        GradeLayersCard(document: document, clip: clip, selected: $selected).revealAnchor(.gradeLayers)
            // The agent is working on a layer: open its cards, as a click on its row would.
            .onReceive(reveal?.$layer.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { id in
                // Only a reveal that has just happened: an old one must not reopen a layer when the clip is clicked later.
                if let id, let at = reveal?.at, Date().timeIntervalSince(at) < 1.5, clip.grades.contains(where: { $0.id == id }) { selected = id }
            }
        if let id = selected, let i = clip.grades.firstIndex(where: { $0.id == id }) {
            let layer = clip.grades[i]
            let info = ColorTargetInfo(target: .layer(id), idPrefix: "layer.\(i + 1).")
            LayerBasicsCard(document: document, clip: clip, layer: layer, info: info)
            ColorWheelsCard(document: document, clip: clip, info: info, title: "\(layer.name): wheels")
            CurvesCard(document: document, clip: clip, info: info, title: "\(layer.name): curves")
            LayerMaskCard(document: document, clip: clip, layer: layer, info: info)
        }
        FinishCard(document: document, clip: clip).revealAnchor(.finish)
    }
}

/// Match this clip's colour to another clip (`match_color`). Ids: `inspector.color.match.reference`, `.run`.
struct ShotMatchCard: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    @State private var reference: UUID?
    @State private var running = false
    @State private var status: String?

    private var candidates: [Clip] {
        document.project.tracks.filter { $0.kind == .video }.flatMap(\.clips).filter { $0.id != clip.id }.sorted { $0.start < $1.start }
    }

    var body: some View {
        let others = candidates
        InspectorCard("Shot match", footer: status ?? "Grades this clip to look like another: black level, middle, white level and saturation, on a \"Shot match\" layer you can mix or remove.") {
            HStack(spacing: 8) {
                Picker("Match to", selection: $reference) {
                    Text("Choose a clip").tag(UUID?.none)
                    ForEach(others) { c in Text("\(c.name) at \(Self.time(c.start))").tag(UUID?.some(c.id)) }
                }
                .labelsHidden().controlSize(.small).pointer().uiFrame("inspector.color.match.reference")
                Button(running ? "Matching…" : "Match") { run() }
                    .controlSize(.small).focusable(false).pointer().disabled(reference == nil || running)
                    .uiFrame("inspector.color.match.run").uiTap("inspector.color.match.run") { run() }
            }
        }
    }

    static func time(_ s: Double) -> String { String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }

    private func run() {
        guard let ref = reference, !running else { return }
        running = true; status = nil
        let x = ToolExecutor(document: document, origin: .user)
        let target = clip.id.uuidString, refText = ref.uuidString
        Task { @MainActor in
            do {
                let r = try await x.matchColor(target, reference: refText, clipSeconds: nil, referenceSeconds: nil, mix: nil)
                status = "Matched: colour distance \(ProjectDiff.fmt(r.distanceBefore)) → \(ProjectDiff.fmt(r.distanceAfter)) (under 5 is close)."
            } catch { status = "Could not match: \(error.localizedDescription)" }
            running = false
        }
    }
}

/// The clip's grade layers: on/off, name, mix, order, remove; click a row to edit that layer below.
/// Ids: `inspector.color.layers.add`, and per row n (1-based) `inspector.color.layer.<n>.select|enabled|mix.slider|up|down|remove`.
struct GradeLayersCard: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    @Binding var selected: UUID?

    private var plain: ToolExecutor { ToolExecutor(document: document, origin: .user) }
    private var sliding: ToolExecutor { ToolExecutor(document: document, origin: .user, coalesce: true) }

    var body: some View {
        InspectorCard("Grade layers", footer: clip.grades.isEmpty ? "Layers add grades on top of this one, each inside an optional mask (a shape, a colour range or the subject)." : "Applied top to bottom after the clip's grade. Click a layer to grade it and set its mask.", trailing: {
            Button { add() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).focusable(false).help("Add a grade layer").pointer().disabled(clip.grades.count >= ToolExecutor.maxGradeLayers)
                .uiFrame("inspector.color.layers.add").uiTap("inspector.color.layers.add") { add() }
        }) {
            if clip.grades.isEmpty {
                Text("No layers").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Array(clip.grades.enumerated()), id: \.element.id) { i, layer in row(i, layer) }
        }
    }

    private func add() {
        guard let r = try? plain.addGradeLayer(clip.id.uuidString, name: nil, index: nil, mix: nil, enabled: nil), let last = r.layers.last,
              let id = Project.resolve(last.id, in: document.project.clip(clip.id)?.clip.grades.map(\.id) ?? []) else { return }
        selected = id
    }

    private func row(_ i: Int, _ layer: GradeLayer) -> some View {
        let n = i + 1, pre = "inspector.color.layer.\(n)"
        let isSel = selected == layer.id
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Toggle("", isOn: .init(get: { layer.enabled }, set: { v in _ = try? plain.updateGradeLayer(clip.id.uuidString, layer: layer.id.uuidString, name: nil, enabled: v, mix: nil, color: .init()) }))
                    .labelsHidden().toggleStyle(.checkbox).controlSize(.small).focusable(false).pointer().uiFrame("\(pre).enabled")
                Text(layer.name).font(.system(size: 11, weight: isSel ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(layer.enabled ? .primary : .secondary)
                if layer.mask.map({ !$0.isEmpty }) ?? false { Image(systemName: "circle.dashed").font(.system(size: 9)).foregroundStyle(.secondary).help("Masked") }
                Spacer(minLength: 4)
                Group {
                    Button { move(layer, i - 1) } label: { Image(systemName: "chevron.up") }.pointer().disabled(i == 0).uiFrame("\(pre).up").uiTap("\(pre).up") { move(layer, i - 1) }
                    Button { move(layer, i + 1) } label: { Image(systemName: "chevron.down") }.pointer().disabled(i == clip.grades.count - 1).uiFrame("\(pre).down").uiTap("\(pre).down") { move(layer, i + 1) }
                    Button { remove(layer) } label: { Image(systemName: "trash") }.pointer().uiFrame("\(pre).remove").uiTap("\(pre).remove") { remove(layer) }
                }
                .buttonStyle(.plain).font(.system(size: 10)).focusable(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { selected = isSel ? nil : layer.id }
            .pointer()
            .uiFrame("\(pre).select").uiTap("\(pre).select") { selected = isSel ? nil : layer.id }
            ColorSliderRow(title: "Mix", id: "layer.\(n).mix", value: layer.mix, range: 0...1, format: { String(format: "%.0f%%", $0 * 100) }, reset: 1) { v in
                _ = try? sliding.updateGradeLayer(clip.id.uuidString, layer: layer.id.uuidString, name: nil, enabled: nil, mix: v, color: .init())
            }
        }
        .padding(.vertical, 1)
        .background(isSel ? Color.accentColor.opacity(0.08) : .clear)
    }

    private func move(_ layer: GradeLayer, _ to: Int) {
        guard to >= 0, to < clip.grades.count else { return }
        _ = try? plain.moveGradeLayer(clip.id.uuidString, layer: layer.id.uuidString, to: to)
    }
    private func remove(_ layer: GradeLayer) {
        if selected == layer.id { selected = nil }
        _ = try? plain.removeGradeLayer(clip.id.uuidString, layer: layer.id.uuidString)
    }
}

/// Exposure, contrast, saturation, temperature and tint of one grade layer. Ids: `inspector.color.layer.<n>.<name>.slider|reset`.
struct LayerBasicsCard: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    let layer: GradeLayer
    let info: ColorTargetInfo

    private func set(_ ch: ToolExecutor.LayerColorChange) {
        _ = try? ToolExecutor(document: document, origin: .user, coalesce: true).updateGradeLayer(clip.id.uuidString, layer: layer.id.uuidString, name: nil, enabled: nil, mix: nil, color: ch)
    }

    var body: some View {
        let c = layer.color
        InspectorCard("\(layer.name): basics") {
            ColorSliderRow(title: "Exposure", id: "\(info.idPrefix)exposure", value: c.exposure, range: -2...2) { set(.init(exposure: $0)) }
            ColorSliderRow(title: "Contrast", id: "\(info.idPrefix)contrast", value: c.contrast, range: 0.5...2, format: { String(format: "%.2f", $0) }, reset: 1) { set(.init(contrast: $0)) }
            ColorSliderRow(title: "Saturation", id: "\(info.idPrefix)saturation", value: c.saturation, range: 0...2, format: { String(format: "%.2f", $0) }, reset: 1) { set(.init(saturation: $0)) }
            ColorSliderRow(title: "Temperature", id: "\(info.idPrefix)temperature", value: c.temperature, range: -100...100, format: { String(format: "%+.0f", $0) }) { set(.init(temperature: $0)) }
            ColorSliderRow(title: "Tint", id: "\(info.idPrefix)tint", value: c.tint, range: -100...100, format: { String(format: "%+.0f", $0) }) { set(.init(tint: $0)) }
        }
    }
}

/// Where a grade layer applies: a shape, a colour selection and/or the AI subject, multiplied; invert flips it.
/// Ids: `inspector.color.layer.<n>.mask.shape|qualifier|subject|invert` and `.mask.<value>.slider|reset`.
struct LayerMaskCard: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    let layer: GradeLayer
    let info: ColorTargetInfo

    private func set(_ ch: ToolExecutor.MaskChange, coalesce: Bool = true) {
        _ = try? ToolExecutor(document: document, origin: .user, coalesce: coalesce).setLayerMask(clip.id.uuidString, layer: layer.id.uuidString, ch)
    }

    var body: some View {
        let m = layer.mask ?? GradeMask()
        let id = "\(info.idPrefix)mask"
        InspectorCard("\(layer.name): mask", footer: "The parts multiply: the layer applies inside the shape, on the selected colours and on the subject. Subject uses Apple's Vision, analysed once per frame.") {
            HStack {
                Text("Shape").inspectorLabel()
                Picker("", selection: .init(get: { m.shape?.kind.rawValue ?? "none" }, set: { v in set(.init(shape: v), coalesce: false) })) {
                    Text("None").tag("none"); Text("Ellipse").tag("ellipse"); Text("Rectangle").tag("rectangle")
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small).pointer().uiFrame("inspector.color.\(id).shape")
            }
            if let s = m.shape {
                ColorSliderRow(title: "Centre x", id: "\(id).centerX", value: s.centerX, range: 0...1, format: { String(format: "%.2f", $0) }, reset: 0.5) { set(.init(shapeValues: ["center_x": $0])) }
                ColorSliderRow(title: "Centre y", id: "\(id).centerY", value: s.centerY, range: 0...1, format: { String(format: "%.2f", $0) }, reset: 0.5) { set(.init(shapeValues: ["center_y": $0])) }
                ColorSliderRow(title: "Width", id: "\(id).width", value: s.width, range: 0.02...1.5, format: { String(format: "%.2f", $0) }, reset: 0.5) { set(.init(shapeValues: ["width": $0])) }
                ColorSliderRow(title: "Height", id: "\(id).height", value: s.height, range: 0.02...1.5, format: { String(format: "%.2f", $0) }, reset: 0.5) { set(.init(shapeValues: ["height": $0])) }
                ColorSliderRow(title: "Rotation", id: "\(id).rotation", value: s.rotation, range: -180...180, format: { String(format: "%+.0f°", $0) }) { set(.init(shapeValues: ["rotation": $0])) }
                ColorSliderRow(title: "Feather", id: "\(id).feather", value: s.feather, range: 0...0.5, format: { String(format: "%.2f", $0) }, reset: 0.05) { set(.init(shapeValues: ["feather": $0])) }
            }
            Toggle("Colour selection", isOn: .init(get: { m.qualifier != nil }, set: { on in set(on ? .init(qualifierValues: ["hue_center": 25, "hue_width": 40]) : .init(qualifierOff: true), coalesce: false) }))
                .toggleStyle(.checkbox).controlSize(.small).focusable(false).pointer().uiFrame("inspector.color.\(id).qualifier")
            if let q = m.qualifier {
                ColorSliderRow(title: "Hue", id: "\(id).hueCenter", value: q.hueCenter, range: 0...360, format: { String(format: "%.0f° %@", $0, ColorBalance.name(ofHue: $0)) }, reset: 0) { set(.init(qualifierValues: ["hue_center": $0])) }
                ColorSliderRow(title: "Hue range", id: "\(id).hueWidth", value: q.hueWidth, range: 0...360, format: { String(format: "%.0f°", $0) }, reset: 360) { set(.init(qualifierValues: ["hue_width": $0])) }
                ColorSliderRow(title: "Min sat", id: "\(id).satLow", value: q.satLow, range: 0...1, format: { String(format: "%.2f", $0) }) { set(.init(qualifierValues: ["sat_low": $0])) }
                ColorSliderRow(title: "Min luma", id: "\(id).lumaLow", value: q.lumaLow, range: 0...1, format: { String(format: "%.2f", $0) }) { set(.init(qualifierValues: ["luma_low": $0])) }
                ColorSliderRow(title: "Max luma", id: "\(id).lumaHigh", value: q.lumaHigh, range: 0...1, format: { String(format: "%.2f", $0) }, reset: 1) { set(.init(qualifierValues: ["luma_high": $0])) }
            }
            HStack {
                Text("Subject").inspectorLabel()
                Picker("", selection: .init(get: { m.subject?.kind.rawValue ?? "none" }, set: { v in set(.init(subject: v), coalesce: false) })) {
                    Text("None").tag("none"); Text("Person").tag("person"); Text("Objects").tag("foreground")
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small).pointer().uiFrame("inspector.color.\(id).subject")
            }
            Toggle("Invert", isOn: .init(get: { m.invert }, set: { v in set(.init(invert: v), coalesce: false) }))
                .toggleStyle(.checkbox).controlSize(.small).focusable(false).pointer().uiFrame("inspector.color.\(id).invert")
        }
    }
}

/// Finishing: noise reduction, sharpen, glow, vignette, grain. Ids: `inspector.color.finish.<name>.slider|reset`, `inspector.color.finish.reset`.
struct FinishCard: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip

    private func set(_ body: (inout ClipFinish) -> Void) {
        var f = clip.finish ?? ClipFinish()
        body(&f)
        try? ToolExecutor(document: document, origin: .user, coalesce: true).setFinish(clip.id, f)
    }

    var body: some View {
        let f = clip.finish ?? ClipFinish()
        let pct = { (v: Double) in String(format: "%.0f%%", v * 100) }
        InspectorCard("Finishing", footer: "After the grade: noise reduction, sharpen, glow on highlights, vignette (left lightens the edges), film grain.", trailing: {
            if !f.isIdentity {
                Button("Reset") { try? ToolExecutor(document: document, origin: .user).setFinish(clip.id, ClipFinish()) }
                    .controlSize(.mini).focusable(false).pointer().uiFrame("inspector.color.finish.reset")
            }
        }) {
            ColorSliderRow(title: "Noise", id: "finish.noise", value: f.noiseReduction, range: 0...1, format: pct) { v in set { $0.noiseReduction = v } }
            ColorSliderRow(title: "Sharpen", id: "finish.sharpen", value: f.sharpen, range: 0...1, format: pct) { v in set { $0.sharpen = v } }
            ColorSliderRow(title: "Glow", id: "finish.glow", value: f.glow, range: 0...1, format: pct) { v in set { $0.glow = v } }
            ColorSliderRow(title: "Vignette", id: "finish.vignette", value: f.vignette, range: -1...1) { v in set { $0.vignette = v } }
            ColorSliderRow(title: "Grain", id: "finish.grain", value: f.grain, range: 0...1, format: pct) { v in set { $0.grain = v } }
            if f.grain > 0 {
                ColorSliderRow(title: "Grain size", id: "finish.grainSize", value: f.grainSize, range: 0.5...4, format: { String(format: "%.1f px", $0) }, reset: 1) { v in set { $0.grainSize = v } }
            }
        }
    }
}
