import SwiftUI
import AppKit

// The inspector's effects sections: green screen, blend and face blur for a clip, animation and lower third for a
// text, the color setting for the project. Every edit goes through `ToolExecutor` (the same methods as the MCP tools);
// slider drags coalesce into one undo step.

/// A slider row in the inspector's look: label, slider, value (double-click the value to reset).
struct EffectsSlider: View {
    let title: String
    let id: String
    let value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let reset: Double
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).inspectorLabel()
            InspectorSlider(value: value, range: range, neutral: InspectorSlider.neutral(range: range, reset: reset), set: set).controlSize(.small).pointer().uiFrame("inspector.effects.\(id)")
            Text(format(value)).inspectorValue()
                .onTapGesture(count: 2) { set(reset) }.help("Double-click to reset").pointer()
                .uiFrame("inspector.effects.\(id).reset").uiTap("inspector.effects.\(id).reset", count: 2) { set(reset) }
        }
    }
}

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

// MARK: - Clip

/// Green screen, blend mode and face blur for a clip on a video track.
struct ClipEffectsSection: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    @State private var keyNote: String?
    @State private var keyBusy = false
    @State private var blurProgress: Double?
    @State private var blurNote: String?
    @State private var blurTask: Task<Void, Never>?

    private var slide: ToolExecutor { ToolExecutor(document: document, origin: .user, coalesce: true) }
    private var plain: ToolExecutor { ToolExecutor(document: document, origin: .user) }
    private var id: String { clip.id.uuidString }
    private var isVideo: Bool { document.project.asset(clip.assetID)?.kind == .video }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.gap) {
            keyCard.revealAnchor(.key)
            blendCard.revealAnchor(.blend)
            blurCard.revealAnchor(.faceBlur)
        }
        .onChange(of: clip.id) { _, _ in blurTask?.cancel(); blurTask = nil; blurProgress = nil; blurNote = nil; keyNote = nil }
    }

    // MARK: Green screen

    private var keyCard: some View {
        let key = clip.effects.chromaKey
        return InspectorCard("Green screen", footer: keyNote ?? (key == nil ? "Makes the screen color transparent so the video track below shows through. Put the background on a lower track." : "Tolerance takes more of the screen, softness smooths the edge, spill takes the screen's color off hair and skin.")) {
            InspectorRow("Key") {
                Toggle("Key", isOn: Binding(get: { key != nil }, set: { on in on ? autoKey() : removeKey() }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().pointer().disabled(keyBusy).uiFrame("inspector.effects.key.toggle")
            }
            if let key {
                InspectorRow("Screen color") {
                    HStack(spacing: 8) {
                        if key.autoPicked { Text("picked").inspectorSecondary() }
                        Button("Pick from edges") { autoKey() }.controlSize(.small).focusable(false).pointer().disabled(keyBusy)
                            .uiTap("inspector.effects.key.auto") { autoKey() }.uiFrame("inspector.effects.key.auto")
                            .help("Find the screen color at the edges of the frame at the playhead")
                        ColorPicker("Screen color", selection: Binding(get: { Color(hex: key.colorHex) }, set: { c in
                            let hex = c.hexString
                            guard hex != key.colorHex else { return }
                            do { try slide.adjustChromaKey(id, color: hex); keyNote = nil } catch { keyNote = InspectorMessage.text(error) }
                        }), supportsOpacity: false).labelsHidden().pointer().uiFrame("inspector.effects.key.color")
                    }
                }
                EffectsSlider(title: "Tolerance", id: "key.tolerance", value: key.tolerance, range: ChromaKey.toleranceRange, format: percent, reset: 0.4) { v in _ = try? slide.adjustChromaKey(id, tolerance: v) }
                EffectsSlider(title: "Softness", id: "key.softness", value: key.softness, range: ChromaKey.softnessRange, format: percent, reset: 0.3) { v in _ = try? slide.adjustChromaKey(id, softness: v) }
                EffectsSlider(title: "Spill", id: "key.spill", value: key.spill, range: ChromaKey.spillRange, format: percent, reset: 0.6) { v in _ = try? slide.adjustChromaKey(id, spill: v) }
                EffectsSlider(title: "Shrink / grow", id: "key.shrink", value: key.shrink, range: ChromaKey.shrinkRange, format: { String(format: "%+.0f px", $0) }, reset: 0) { v in _ = try? slide.adjustChromaKey(id, shrink: v.rounded()) }
                EffectsSlider(title: "Edge blur", id: "key.edgeBlur", value: key.edgeBlur, range: ChromaKey.edgeBlurRange, format: { String(format: "%.0f px", $0) }, reset: 0) { v in _ = try? slide.adjustChromaKey(id, edgeBlur: v.rounded()) }
            }
        }
    }

    private func autoKey() {
        guard !keyBusy else { return }
        keyBusy = true; keyNote = "Looking for the screen color…"
        Task { @MainActor in
            defer { keyBusy = false }
            do {
                let r = try await plain.setChromaKey(id, color: "auto", tolerance: nil, softness: nil, spill: nil, shrink: nil, edgeBlur: nil, time: nil, remove: false)
                keyNote = "Screen \(r.key?.colorHex ?? "") · \(r.matte.map { "\($0.keyedPercent) % keyed" } ?? "")" + (r.note.map { " — \($0)" } ?? "")
            } catch {
                // No clear color at the edges: start from a standard green the user can change.
                if clip.effects.chromaKey == nil, (try? plain.adjustChromaKey(id, color: "#00B140")) != nil { keyNote = "\(InspectorMessage.text(error)) Started from standard green; pick the color." }
                else { keyNote = InspectorMessage.text(error) }
            }
        }
    }
    private func removeKey() {
        Task { @MainActor in _ = try? await plain.setChromaKey(id, color: nil, tolerance: nil, softness: nil, spill: nil, shrink: nil, edgeBlur: nil, time: nil, remove: true); keyNote = nil }
    }

    // MARK: Blend

    private var blendCard: some View {
        InspectorCard("Blend", footer: clip.effects.blend == .normal ? nil : "Mixes the clip with the video tracks below it. The opacity under Transform sets how much.") {
            InspectorRow("Mode") {
                Picker("Mode", selection: Binding(get: { clip.effects.blend.rawValue }, set: { v in _ = try? plain.setBlendMode(id, mode: v) })) {
                    ForEach(ClipBlendMode.allCases, id: \.rawValue) { m in
                        Text(m.title).tag(m.rawValue)
                        if m == .normal || m == .subtract || m == .lighten || m == .linearBurn { Divider() }
                    }
                }.labelsHidden().fixedSize().pointer().uiFrame("inspector.effects.blend.mode")
            }
        }
    }

    // MARK: Face blur

    private var blurCard: some View {
        let fb = document.project.hydrated(clip).effects.blur
        let hasFaces = !(fb?.pathKey.isEmpty ?? true)
        let busy = blurProgress != nil
        return InspectorCard("Face blur", footer: blurFooter(fb)) {
            HStack(spacing: 8) {
                Button(hasFaces ? "Find again" : "Find faces", systemImage: "face.dashed") { findFaces(again: hasFaces) }
                    .controlSize(.small).focusable(false).pointer().disabled(busy || !isVideo)
                    .uiTap("inspector.effects.blur.find") { findFaces(again: hasFaces) }.uiFrame("inspector.effects.blur.find")
                    .help("Find every face in the clip and blur it in every frame")
                if hasFaces {
                    Button("Remove") { removeFaces() }.controlSize(.small).focusable(false).pointer().disabled(busy)
                        .uiTap("inspector.effects.blur.remove") { removeFaces() }.uiFrame("inspector.effects.blur.remove")
                }
                if busy { ProgressView().controlSize(.mini) }
                Spacer(minLength: 8)
                Text(blurStatus(fb)).inspectorSecondary().monospacedDigit().lineLimit(1).truncationMode(.tail)
            }
            if let fb {
                InspectorRow("Look") {
                    Picker("Look", selection: Binding(get: { fb.style.rawValue }, set: { v in _ = try? plain.adjustBlur(id, style: v) })) {
                        ForEach(FaceBlur.Style.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().fixedSize().pointer().uiFrame("inspector.effects.blur.style")
                }
                EffectsSlider(title: "Strength", id: "blur.strength", value: fb.strength, range: FaceBlur.strengthRange, format: percent, reset: 0.6) { v in _ = try? slide.adjustBlur(id, strength: v) }
                if hasFaces {
                    EffectsSlider(title: "Expand", id: "blur.expand", value: fb.expand, range: FaceBlur.expandRange, format: percent, reset: 0.25) { v in _ = try? slide.adjustBlur(id, expand: v) }
                }
                EffectsSlider(title: "Feather", id: "blur.feather", value: fb.feather, range: FaceBlur.featherRange, format: percent, reset: 0.4) { v in _ = try? slide.adjustBlur(id, feather: v) }
                ForEach(fb.tracks, id: \.id) { face in
                    InspectorRow("Face \(face.id)") {
                        HStack(spacing: 8) {
                            Text(span(face)).inspectorSecondary().monospacedDigit()
                            Toggle("Blur face \(face.id)", isOn: Binding(get: { !fb.exclude.contains(face.id) }, set: { on in
                                var ex = Set(fb.exclude); if on { ex.remove(face.id) } else { ex.insert(face.id) }
                                _ = try? plain.adjustBlur(id, exclude: Array(ex))
                            })).toggleStyle(.switch).controlSize(.mini).labelsHidden().pointer().uiFrame("inspector.effects.blur.face.\(face.id)")
                        }
                    }
                }
                if !fb.regions.isEmpty {
                    InspectorRow("Rectangles") {
                        HStack(spacing: 8) {
                            Text("\(fb.regions.count)").inspectorSecondary().monospacedDigit()
                            Button("Remove") { _ = Task { @MainActor in _ = try? await plain.blurRegion(id, x: nil, y: nil, width: nil, height: nil, start: nil, end: nil, track: false, style: nil, strength: nil, feather: nil, remove: "all") } }
                                .controlSize(.small).focusable(false).pointer().uiFrame("inspector.effects.blur.regions.remove")
                        }
                    }
                }
            }
        }
    }

    private func span(_ f: FaceTrack) -> String {
        let total = max(1e-6, clip.sourceOut - clip.sourceIn)
        let t = { (s: Double) in Timecode.string(clip.start + (s - clip.sourceIn) / total * clip.duration) }
        return "\(t(max(clip.sourceIn, f.start)))–\(t(min(clip.sourceOut, f.end)))"
    }
    private func blurStatus(_ fb: FaceBlur?) -> String {
        if let blurProgress { return "Looking… \(Int((blurProgress * 100).rounded())) %" }
        guard let fb, !fb.pathKey.isEmpty else { return isVideo ? "No faces blurred" : "Video clips only" }
        let sharp = fb.exclude.count
        return "\(fb.faceCount) face\(fb.faceCount == 1 ? "" : "s")" + (sharp > 0 ? ", \(sharp) left sharp" : "")
    }
    private func blurFooter(_ fb: FaceBlur?) -> String {
        if let blurNote { return blurNote }
        if fb == nil { return "Finds faces with on-device detection and follows them through the clip. Faces turned away or very small can be missed: check the frames. The agent can also blur and track a rectangle." }
        return "Switch a face off to leave it sharp. The blur follows the picture through crop and transform."
    }

    private func findFaces(again: Bool) {
        guard blurProgress == nil else { return }
        blurProgress = 0; blurNote = nil
        blurTask = Task { @MainActor in
            do {
                let r = try await plain.blurFaces(id, style: nil, strength: nil, expand: nil, feather: nil, exclude: nil, only: nil, reanalyse: again, remove: false) { p in
                    Task { @MainActor in if blurProgress != nil { blurProgress = p } }
                }
                blurNote = r.note
            } catch is CancellationError {
            } catch { blurNote = InspectorMessage.text(error) }
            blurProgress = nil
        }
    }
    private func removeFaces() {
        Task { @MainActor in _ = try? await plain.blurFaces(id, style: nil, strength: nil, expand: nil, feather: nil, exclude: nil, only: nil, reanalyse: false, remove: true); blurNote = nil }
    }
}

// MARK: - Text

/// How a title comes on and goes off, and the lower-third template.
struct TextEffectsSection: View {
    @ObservedObject var document: EditMaxDocument
    let text: TextOverlay
    @State private var note: String?
    @State private var roleDraft = ""

    private var slide: ToolExecutor { ToolExecutor(document: document, origin: .user, coalesce: true) }
    private var plain: ToolExecutor { ToolExecutor(document: document, origin: .user) }
    private var id: String { text.id.uuidString }

    var body: some View {
        let a = text.animation ?? TextAnimation()
        let maxLen = max(0.05, min(TextAnimation.durationRange.upperBound, text.duration))
        VStack(alignment: .leading, spacing: InspectorStyle.gap) {
            InspectorCard("Animation", footer: note ?? "How the text comes on and goes off. Typewriter and word by word reveal it piece by piece; on a lower third, wipe builds it up.") {
                kindRow("In", id: "title.in", value: a.inKind) { k in apply { try plain.setTextAnimation(id, inKind: k.rawValue, inDuration: nil, outKind: nil, outDuration: nil) } }
                if a.inKind != .none {
                    EffectsSlider(title: "In length", id: "title.inDuration", value: min(a.inDuration, maxLen), range: 0.05...maxLen, format: { String(format: "%.2f s", $0) }, reset: min(0.5, maxLen)) { v in
                        apply { try slide.setTextAnimation(id, inKind: nil, inDuration: (v * 100).rounded() / 100, outKind: nil, outDuration: nil) }
                    }
                }
                kindRow("Out", id: "title.out", value: a.outKind) { k in apply { try plain.setTextAnimation(id, inKind: nil, inDuration: nil, outKind: k.rawValue, outDuration: nil) } }
                if a.outKind != .none {
                    EffectsSlider(title: "Out length", id: "title.outDuration", value: min(a.outDuration, maxLen), range: 0.05...maxLen, format: { String(format: "%.2f s", $0) }, reset: min(0.4, maxLen)) { v in
                        apply { try slide.setTextAnimation(id, inKind: nil, inDuration: nil, outKind: nil, outDuration: (v * 100).rounded() / 100) }
                    }
                }
            }.revealAnchor(.textAnimation)
            if !text.isCaption { lowerThirdCard.revealAnchor(.lowerThird) }
        }
        .onAppear { roleDraft = text.lowerThird?.role ?? "" }
        .onChange(of: text.id) { _, _ in roleDraft = text.lowerThird?.role ?? ""; note = nil }
    }

    private func kindRow(_ title: String, id: String, value: TextAnimation.Kind, set: @escaping (TextAnimation.Kind) -> Void) -> some View {
        InspectorRow(title) {
            Picker(title, selection: Binding(get: { value }, set: set)) {
                ForEach(TextAnimation.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().fixedSize().pointer().uiFrame("inspector.effects.\(id)")
        }
    }

    private func apply(_ body: () throws -> Any) {
        do { _ = try body(); note = nil } catch { note = InspectorMessage.text(error) }
    }

    private var lowerThirdCard: some View {
        let lt = text.lowerThird
        return InspectorCard("Lower third", footer: lt == nil ? "Shows the text as a name with a role line under it, on a bar or box." : "The text above is the name.") {
            InspectorRow("Lower third") {
                Toggle("Lower third", isOn: Binding(get: { lt != nil }, set: { on in
                    apply {
                        if on { return try plain.addLowerThird(name: text.text, role: roleDraft, template: nil, start: nil, duration: nil, x: nil, y: nil, accent: nil, color: nil, fontSize: nil, inKind: nil, outKind: nil, text: id) }
                        try plain.removeLowerThird(id); return true
                    }
                })).toggleStyle(.switch).controlSize(.mini).labelsHidden().pointer().uiFrame("inspector.effects.lowerThird")
            }
            if let lt {
                InspectorRow("Template") {
                    Picker("Template", selection: Binding(get: { lt.template }, set: { v in
                        apply { try plain.addLowerThird(name: text.text, role: nil, template: v.rawValue, start: nil, duration: nil, x: nil, y: nil, accent: nil, color: nil, fontSize: nil, inKind: nil, outKind: nil, text: id) }
                    })) { ForEach(LowerThird.Template.allCases, id: \.self) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().pointer().uiFrame("inspector.effects.lowerThird.template")
                }
                InspectorRow("Role") {
                    TextField("Job title or place", text: $roleDraft).textFieldStyle(.roundedBorder).frame(maxWidth: 170).pointer()
                        .onSubmit { commitRole() }.uiFrame("inspector.effects.lowerThird.role")
                }
                InspectorRow("Accent") {
                    ColorPicker("Accent", selection: Binding(get: { Color(hex: lt.accentHex) }, set: { c in
                        let hex = c.hexString
                        guard hex != lt.accentHex else { return }
                        apply { try slide.addLowerThird(name: text.text, role: nil, template: nil, start: nil, duration: nil, x: nil, y: nil, accent: hex, color: nil, fontSize: nil, inKind: nil, outKind: nil, text: id) }
                    }), supportsOpacity: false).labelsHidden().pointer().uiFrame("inspector.effects.lowerThird.accent")
                }
            }
        }
    }

    private func commitRole() {
        guard roleDraft != text.lowerThird?.role else { return }
        apply { try plain.addLowerThird(name: text.text, role: roleDraft, template: nil, start: nil, duration: nil, x: nil, y: nil, accent: nil, color: nil, fontSize: nil, inKind: nil, outKind: nil, text: id) }
    }
}

// MARK: - Project

/// The project's color setting, as a row of the Project card.
struct ProjectColorRow: View {
    @ObservedObject var document: EditMaxDocument
    var body: some View {
        InspectorRow("Color") {
            Picker("Color", selection: Binding(get: { document.project.settings.color }, set: { v in _ = try? ToolExecutor(document: document, origin: .user).setProjectColor(v.rawValue) })) {
                ForEach(ProjectColor.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().fixedSize().pointer().uiFrame("inspector.effects.projectColor")
            .help("SDR Rec.709 passes every frame through as it is. HDR makes the preview and the HEVC 10-bit and ProRes masters Rec.2020 HLG or PQ; H.264 exports stay SDR.")
        }
    }
}
