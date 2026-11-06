import SwiftUI

/// The clip inspector's audio processing beyond EQ: compressor, limiter, de-esser, hum removal, gain and pan,
/// the clip's loudness, and the crossfade from the clip before. Every control goes through `ToolExecutor`.
struct ClipAudioSections: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    let track: Track
    @State private var channels: Int?
    @State private var humNote: String?
    @State private var detecting = false
    @State private var crossfadeNote: String?
    @State private var loudness: String?
    @State private var measuring = false

    /// Slider drags make one undo step.
    private var x: ToolExecutor { ToolExecutor(document: document, origin: .user, coalesce: true) }
    private var plain: ToolExecutor { ToolExecutor(document: document, origin: .user) }
    private var id: String { clip.id.uuidString }
    private var au: ClipAudio { clip.audio }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.gap) {
            compressorCard.revealAnchor(.compressor)
            limiterCard.revealAnchor(.limiter)
            deEsserCard.revealAnchor(.deEsser)
            humCard.revealAnchor(.hum)
            mixCard.revealAnchor(.gainPan)
            if track.kind == .audio { crossfadeCard.revealAnchor(.crossfade) }
        }
        .task(id: clip.assetID) { channels = await AudioChannels.count(of: clip, in: document.project) }
    }

    // MARK: Cards

    private var compressorCard: some View {
        InspectorCard("Compressor", footer: au.compressor == nil ? "Evens out loud and quiet words. Runs after EQ, gate, hum removal and de-esser." : nil, trailing: {
            toggle("compressor", on: au.compressor != nil) { on in _ = try? plain.setClipCompressor(id, enabled: on, threshold: nil, ratio: nil, attack: nil, release: nil, knee: nil, makeup: nil) }
        }) {
            if let c = au.compressor {
                slider("Threshold", key: "compressor.threshold", value: c.threshold, range: -60...0, format: { String(format: "%.0f dB", $0) }, reset: -18) { v in _ = try? x.setClipCompressor(id, enabled: nil, threshold: v.rounded(), ratio: nil, attack: nil, release: nil, knee: nil, makeup: nil) }
                slider("Ratio", key: "compressor.ratio", value: c.ratio, range: 1...20, format: { String(format: "%.1f:1", $0) }, reset: 3) { v in _ = try? x.setClipCompressor(id, enabled: nil, threshold: nil, ratio: (v * 10).rounded() / 10, attack: nil, release: nil, knee: nil, makeup: nil) }
                slider("Attack", key: "compressor.attack", value: c.attack, range: 0.5...100, format: { String(format: $0 < 10 ? "%.1f ms" : "%.0f ms", $0) }, reset: 10) { v in _ = try? x.setClipCompressor(id, enabled: nil, threshold: nil, ratio: nil, attack: (v * 10).rounded() / 10, release: nil, knee: nil, makeup: nil) }
                slider("Release", key: "compressor.release", value: c.release, range: 20...1000, format: { String(format: "%.0f ms", $0) }, reset: 150) { v in _ = try? x.setClipCompressor(id, enabled: nil, threshold: nil, ratio: nil, attack: nil, release: v.rounded(), knee: nil, makeup: nil) }
                slider("Knee", key: "compressor.knee", value: c.knee, range: 0...24, format: { String(format: "%.0f dB", $0) }, reset: 6) { v in _ = try? x.setClipCompressor(id, enabled: nil, threshold: nil, ratio: nil, attack: nil, release: nil, knee: v.rounded(), makeup: nil) }
                slider("Makeup", key: "compressor.makeup", value: c.makeup, range: -12...24, format: { String(format: "%+.1f dB", $0) }, reset: 0) { v in _ = try? x.setClipCompressor(id, enabled: nil, threshold: nil, ratio: nil, attack: nil, release: nil, knee: nil, makeup: (v * 2).rounded() / 2) }
            }
        }
    }

    private var limiterCard: some View {
        InspectorCard("Limiter", footer: au.limiter == nil ? "Nothing in the clip goes over the ceiling, measured between samples too. Last in the clip's chain." : "Every clip on \(track.name) is delayed by the same look-ahead, so nothing shifts between clips.", trailing: {
            toggle("limiter", on: au.limiter != nil) { on in _ = try? plain.setClipLimiter(id, enabled: on, ceiling: nil, release: nil, lookahead: nil) }
        }) {
            if let l = au.limiter {
                slider("Ceiling", key: "limiter.ceiling", value: l.ceiling, range: -24...0, format: { String(format: "%.1f dBTP", $0) }, reset: -1) { v in _ = try? x.setClipLimiter(id, enabled: nil, ceiling: (v * 10).rounded() / 10, release: nil, lookahead: nil) }
                slider("Release", key: "limiter.release", value: l.release, range: 1...1000, format: { String(format: "%.0f ms", $0) }, reset: 100) { v in _ = try? x.setClipLimiter(id, enabled: nil, ceiling: nil, release: v.rounded(), lookahead: nil) }
                slider("Look-ahead", key: "limiter.lookahead", value: l.lookahead, range: 0...5, format: { String(format: "%.1f ms", $0) }, reset: 1.5) { v in _ = try? x.setClipLimiter(id, enabled: nil, ceiling: nil, release: nil, lookahead: (v * 10).rounded() / 10) }
            }
        }
    }

    private var deEsserCard: some View {
        InspectorCard("De-esser", footer: au.deEsser == nil ? "Softens harsh s and sh sounds in a voice." : "Above the frequency, the band is turned down while it stands out from the voice (up to 18 dB).", trailing: {
            toggle("deesser", on: au.deEsser != nil) { on in _ = try? plain.setClipDeEsser(id, enabled: on, amount: nil, frequency: nil) }
        }) {
            if let d = au.deEsser {
                slider("Amount", key: "deesser.amount", value: d.amount, range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" }, reset: 0.5) { v in _ = try? x.setClipDeEsser(id, enabled: nil, amount: (v * 100).rounded() / 100, frequency: nil) }
                slider("Frequency", key: "deesser.frequency", value: d.frequency, range: 3000...12000, format: { String(format: "%.1f kHz", $0 / 1000) }, reset: 6000) { v in _ = try? x.setClipDeEsser(id, enabled: nil, amount: nil, frequency: (v / 100).rounded() * 100) }
            }
        }
    }

    private var humCard: some View {
        InspectorCard("Hum removal", footer: humNote ?? (au.hum == nil ? "Notches out 50 or 60 Hz mains hum and its harmonics. Turning it on listens to the clip to pick the frequency." : nil), trailing: {
            HStack(spacing: 6) {
                if detecting { ProgressView().controlSize(.mini) }
                toggle("hum", on: au.hum != nil) { on in
                    if on { detectHum(nil) } else { humNote = nil; Task { _ = try? await plain.setClipHumRemoval(id, enabled: false, frequency: nil, amount: nil, harmonics: nil) } }
                }
            }
        }) {
            if let h = au.hum {
                InspectorRow("Mains") {
                    Picker("Mains", selection: Binding(get: { Int(h.frequency) }, set: { f in Task { _ = try? await plain.setClipHumRemoval(id, enabled: nil, frequency: String(f), amount: nil, harmonics: nil) } })) {
                        Text("50 Hz").tag(50); Text("60 Hz").tag(60)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 120).pointer().disabled(detecting).uiFrame("inspector.audio.hum.frequency")
                    Button("Detect") { detectHum("auto") }.controlSize(.small).pointer().disabled(detecting).uiFrame("inspector.audio.hum.detect")
                }
                slider("Amount", key: "hum.amount", value: h.amount, range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" }, reset: 1) { v in Task { _ = try? await x.setClipHumRemoval(id, enabled: nil, frequency: nil, amount: (v * 100).rounded() / 100, harmonics: nil) } }
                slider("Harmonics", key: "hum.harmonics", value: Double(h.harmonics), range: 1...8, format: { "\(Int($0))" }, reset: 4) { v in Task { _ = try? await x.setClipHumRemoval(id, enabled: nil, frequency: nil, amount: nil, harmonics: Int(v.rounded())) } }
            }
        }
    }

    private var mixCard: some View {
        let mono = (channels ?? 2) < 2
        return InspectorCard("Gain & pan", footer: loudness ?? (mono ? "Mono sound: it plays in both speakers and cannot be panned." : nil), trailing: {
            HStack(spacing: 6) {
                if measuring { ProgressView().controlSize(.mini) }
                Button("Measure") { measure() }.controlSize(.mini).pointer().disabled(measuring).uiFrame("inspector.audio.loudness.measure")
                Menu("Normalize") {
                    Button("YouTube, −14 LUFS") { normalize("youtube") }
                    Button("Apple and podcasts, −16 LUFS") { normalize("apple") }
                    Button("EBU R128, −23 LUFS") { normalize("ebu") }
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.mini).pointer().disabled(measuring).uiFrame("inspector.audio.loudness.normalize")
            }
        }) {
            slider("Gain", key: "gain", value: au.gain, range: -24...24, format: { String(format: "%+.1f dB", $0) }, reset: 0) { v in Task { _ = try? await x.setClipMix(id, gain: (v * 10).rounded() / 10, pan: nil) } }
            slider("Pan", key: "pan", value: au.pan, range: -1...1, format: Self.panText, reset: 0) { v in Task { _ = try? await x.setClipMix(id, gain: nil, pan: (v * 100).rounded() / 100) } }
                .disabled(mono)
        }
    }

    private var crossfadeCard: some View {
        let prev = document.project.clipBefore(clip, on: track)
        let footer = crossfadeNote ?? (prev == nil ? "No clip ends where this one starts." : clip.transitionIn != nil ? "The transition already crossfades the sound." : "Fades \(prev!.name) out under this clip's start; needs that much sound past its out point.")
        return InspectorCard("Crossfade in", footer: footer, trailing: {
            toggle("crossfade", on: clip.audioCrossfade != nil) { on in
                crossfadeNote = on ? (try? plain.setAudioCrossfade(id, duration: nil, curve: nil, remove: false))?.note : nil
                if !on { _ = try? plain.setAudioCrossfade(id, duration: nil, curve: nil, remove: true) }
            }
            .disabled(prev == nil || clip.transitionIn != nil)
        }) {
            if let xf = clip.audioCrossfade {
                slider("Duration", key: "crossfade.duration", value: xf.duration, range: 0.05...min(5, max(0.06, clip.duration)), format: { String(format: "%.2f s", $0) }, reset: 0.5) { v in
                    crossfadeNote = (try? x.setAudioCrossfade(id, duration: (v * 100).rounded() / 100, curve: nil, remove: false))?.note
                }
                InspectorRow("Curve") {
                    Picker("Curve", selection: Binding(get: { xf.curve.rawValue }, set: { c in _ = try? plain.setAudioCrossfade(id, duration: nil, curve: c == "linear" ? "linear" : "equal_power", remove: false) })) {
                        Text("Equal power").tag(AudioCrossfade.Curve.equalPower.rawValue); Text("Linear").tag(AudioCrossfade.Curve.linear.rawValue)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize().pointer().uiFrame("inspector.audio.crossfade.curve")
                }
            }
        }
    }

    // MARK: Actions

    private func detectHum(_ frequency: String?) {
        detecting = true
        Task {
            defer { detecting = false }
            do { humNote = try await plain.setClipHumRemoval(id, enabled: true, frequency: frequency, amount: nil, harmonics: nil).note }
            catch { humNote = "\(error)" }
        }
    }

    private func measure() {
        measuring = true
        Task {
            defer { measuring = false }
            do { loudness = Self.describe(try await plain.measureLoudness(clip: id)) } catch { loudness = "\(error)" }
        }
    }

    private func normalize(_ target: String) {
        measuring = true
        Task {
            defer { measuring = false }
            do {
                let r = try await plain.normalizeLoudness(target: target, ceiling: nil, clip: id)
                loudness = "Now " + Self.describe(r.after) + (r.note.map { " " + $0 } ?? "")
            } catch { loudness = "\(error)" }
        }
    }

    static func describe(_ r: ToolExecutor.LoudnessReport) -> String {
        let i = r.integrated.map { String(format: "%.1f LUFS", $0) } ?? "silent"
        let tp = r.truePeak.map { String(format: "%.1f dBTP", $0) } ?? "–"
        return "\(i), true peak \(tp), range \(String(format: "%.1f", r.range)) LU."
    }

    static func panText(_ p: Double) -> String {
        abs(p) < 0.005 ? "C" : p < 0 ? "L\(Int((-p * 100).rounded()))" : "R\(Int((p * 100).rounded()))"
    }

    // MARK: Controls

    private func toggle(_ key: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: set)) { EmptyView() }
            .toggleStyle(.switch).controlSize(.mini).labelsHidden().pointer().uiFrame("inspector.audio.\(key).toggle")
    }

    /// A labeled slider with its value on the right; double-click the value to reset.
    private func slider(_ title: String, key: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String, reset: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).inspectorLabel()
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: set), in: range).controlSize(.small).pointer().uiFrame("inspector.audio.\(key).slider")
            Text(format(value)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize().frame(width: 66, alignment: .trailing)
                .onTapGesture(count: 2) { set(reset) }.help("Double-click to reset").pointer()
                .uiFrame("inspector.audio.\(key).reset").uiTap("inspector.audio.\(key).reset", count: 2) { set(reset) }
        }
    }
}
