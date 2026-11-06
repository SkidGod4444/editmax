import SwiftUI
import Combine

/// The timeline with the mixer beside it when the mixer is open (toolbar button or `mixerOpen`).
struct MixerSplit<Content: View>: View {
    @ObservedObject var document: EditMaxDocument
    let player: PlayerController
    @ViewBuilder let content: () -> Content
    @AppStorage("mixerOpen") private var open = false

    var body: some View {
        HSplitView {
            content().frame(minWidth: 400)
            if open { MixerPane(document: document, player: player).frame(minWidth: 380, idealWidth: 460, maxWidth: 720) }
        }
    }
}

/// The timeline toolbar's button that shows and hides the mixer.
struct MixerToggleButton: View {
    @AppStorage("mixerOpen") private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "slider.vertical.3").font(.system(size: 12, weight: .medium)).imageScale(.medium)
                .frame(width: 24, height: 22).contentShape(Rectangle())
                .foregroundStyle(open ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless).focusable(false).help(open ? "Hide the mixer" : "Show the mixer: track faders, pan, solo, buses and the master")
        .pointer().uiFrame("toolbar.mixer")
    }
}

/// Peak levels from the taps (`MeterBank`), polled 15 times a second, falling 24 dB a second.
@MainActor
final class MixerMeters: ObservableObject {
    @Published private(set) var levels: [UUID: Float] = [:]     // dBFS
    @Published private(set) var reduction: [UUID: Float] = [:]  // dB
    private var timer: AnyCancellable?
    func start(_ tracks: @escaping () -> [UUID]) {
        timer = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            for id in tracks() {
                guard let slot = MeterBank.shared.existing(id) else { continue }
                let (p, r) = slot.take()
                let db = p > 0 ? 20 * log10(p) : -90
                levels[id] = max(db, (levels[id] ?? -90) - 24.0 / 15)
                reduction[id] = max(r, (reduction[id] ?? 0) - 12.0 / 15)
            }
        }
    }
    func stop() { timer = nil }
}

struct MixerPane: View {
    @ObservedObject var document: EditMaxDocument
    /// nil: a still picture of the pane (tests), with no meters and no player rebuilds.
    let player: PlayerController?
    @StateObject private var meters = MixerMeters()
    @State private var loudness: String?
    @State private var working = false
    @State private var newBus = ""

    /// Slider drags make one undo step.
    private var x: ToolExecutor { ToolExecutor(document: document, origin: .user, coalesce: true) }
    private var plain: ToolExecutor { ToolExecutor(document: document, origin: .user) }
    private var p: Project { document.project }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mixer").font(.system(size: 13, weight: .semibold))
                Spacer()
                if working { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("Tracks") { ForEach(p.tracks.filter { !$0.isHidden }) { trackRow($0) } }
                    section("Buses", trailing: { addBus }) {
                        if p.mix.buses.isEmpty { InspectorFootnote("Route tracks to a bus to set their level together, with one compressor and limiter.") }
                        ForEach(p.mix.buses) { busRow($0) }
                    }
                    section("Master") { masterRows }
                    InspectorFootnote("Bus compressors and limiters, and the master limiter, run once per track: AVFoundation adds the tracks together itself, after every stage. Normalize measures the real mix and keeps its summed peak under the ceiling.")
                        .padding(.horizontal, 4)
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard let player else { return }
            MeterBank.shared.isEnabled = true   // preview builds attach a metering tap to every track
            player.rebuild(document.project, reason: "meters-on")
            meters.start { [weak d = document] in d?.project.tracks.map(\.id) ?? [] }
        }
        .onDisappear {
            guard let player else { return }
            meters.stop()
            MeterBank.shared.isEnabled = false
            player.rebuild(document.project, reason: "meters-off")
        }
    }

    // MARK: Rows

    private func trackRow(_ t: Track) -> some View {
        let silenced = Mixer.isSilencedBySolo(t, in: p)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(t.name).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 64, alignment: .leading)
                    .foregroundStyle(silenced || t.isMuted ? .secondary : .primary)
                pill("M", on: t.isMuted, color: .orange, help: t.isMuted ? "Unmute" : "Mute", id: "mixer.\(t.name).mute") { Task { _ = try? await plain.setTrackMix(t.id.uuidString, gain: nil, pan: nil, solo: nil, mute: !t.isMuted, bus: nil) } }
                pill("S", on: t.mix.solo, color: .yellow, help: t.mix.solo ? "Unsolo" : "Solo: hear only soloed tracks", id: "mixer.\(t.name).solo") { Task { _ = try? await plain.setTrackMix(t.id.uuidString, gain: nil, pan: nil, solo: !t.mix.solo, mute: nil, bus: nil) } }
                meter(t.id)
                Picker("Bus", selection: Binding(get: { t.mix.bus?.uuidString ?? "none" }, set: { v in Task { _ = try? await plain.setTrackMix(t.id.uuidString, gain: nil, pan: nil, solo: nil, mute: nil, bus: v) } })) {
                    Text("Master").tag("none")
                    ForEach(p.mix.buses) { Text($0.name).tag($0.id.uuidString) }
                }
                .labelsHidden().controlSize(.small).frame(width: 92).pointer().uiFrame("mixer.\(t.name).bus")
            }
            HStack(spacing: 8) {
                fader("Gain", id: "mixer.\(t.name).gain", value: t.mix.gain, range: -60...12, format: { String(format: "%+.1f dB", $0) }, reset: 0) { v in Task { _ = try? await x.setTrackMix(t.id.uuidString, gain: (v * 10).rounded() / 10, pan: nil, solo: nil, mute: nil, bus: nil) } }
                fader("Pan", id: "mixer.\(t.name).pan", value: t.mix.pan, range: -1...1, format: ClipAudioSections.panText, reset: 0, width: 72) { v in Task { _ = try? await x.setTrackMix(t.id.uuidString, gain: nil, pan: (v * 100).rounded() / 100, solo: nil, mute: nil, bus: nil) } }
            }
        }
        .opacity(silenced ? 0.55 : 1)
    }

    private func busRow(_ b: Bus) -> some View {
        let members = p.tracks.filter { $0.mix.bus == b.id }.map(\.name)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(b.name).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 64, alignment: .leading)
                pill("M", on: b.isMuted, color: .orange, help: b.isMuted ? "Unmute the bus" : "Mute the bus", id: "mixer.bus.\(b.name).mute") { _ = try? plain.setBus(b.id.uuidString, rename: nil, gain: nil, mute: !b.isMuted, compressor: nil, removeCompressor: false, limiter: nil, removeLimiter: false, remove: false) }
                Text(members.isEmpty ? "no tracks" : members.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                pill("Comp", on: b.compressor != nil, color: .accentColor, width: 38, help: b.compressor == nil ? "Compressor (threshold −18 dB, 3:1) on each track of the bus" : "Turn the bus compressor off", id: "mixer.bus.\(b.name).compressor") {
                    let on = b.compressor == nil
                    _ = try? plain.setBus(b.id.uuidString, rename: nil, gain: nil, mute: nil, compressor: on ? [:] : nil, removeCompressor: !on, limiter: nil, removeLimiter: false, remove: false)
                }
                pill("Limit", on: b.limiter != nil, color: .accentColor, width: 38, help: b.limiter == nil ? "True-peak limiter at −1 dBTP on each track of the bus" : "Turn the bus limiter off", id: "mixer.bus.\(b.name).limiter") {
                    let on = b.limiter == nil
                    _ = try? plain.setBus(b.id.uuidString, rename: nil, gain: nil, mute: nil, compressor: nil, removeCompressor: false, limiter: on ? [:] : nil, removeLimiter: !on, remove: false)
                }
                Button { _ = try? plain.setBus(b.id.uuidString, rename: nil, gain: nil, mute: nil, compressor: nil, removeCompressor: false, limiter: nil, removeLimiter: false, remove: true) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.borderless).focusable(false).help("Delete the bus; its tracks go straight to the master").pointer().uiFrame("mixer.bus.\(b.name).remove")
            }
            fader("Gain", id: "mixer.bus.\(b.name).gain", value: b.gain, range: -60...12, format: { String(format: "%+.1f dB", $0) }, reset: 0) { v in _ = try? x.setBus(b.id.uuidString, rename: nil, gain: (v * 10).rounded() / 10, mute: nil, compressor: nil, removeCompressor: false, limiter: nil, removeLimiter: false, remove: false) }
            if let c = b.compressor {
                fader("Threshold", id: "mixer.bus.\(b.name).threshold", value: c.threshold, range: -60...0, format: { String(format: "%.0f dB", $0) }, reset: -18) { v in _ = try? x.setBus(b.id.uuidString, rename: nil, gain: nil, mute: nil, compressor: ["threshold": v.rounded()], removeCompressor: false, limiter: nil, removeLimiter: false, remove: false) }
            }
            if let l = b.limiter {
                fader("Ceiling", id: "mixer.bus.\(b.name).ceiling", value: l.ceiling, range: -24...0, format: { String(format: "%.1f dBTP", $0) }, reset: -1) { v in _ = try? x.setBus(b.id.uuidString, rename: nil, gain: nil, mute: nil, compressor: nil, removeCompressor: false, limiter: ["ceiling": (v * 10).rounded() / 10], removeLimiter: false, remove: false) }
            }
        }
    }

    @ViewBuilder private var masterRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            fader("Gain", id: "mixer.master.gain", value: p.mix.masterGain, range: -24...24, format: { String(format: "%+.1f dB", $0) }, reset: 0) { v in _ = try? x.setMaster(gain: (v * 10).rounded() / 10, limiter: nil, removeLimiter: false) }
            HStack(spacing: 8) {
                Toggle("Limiter", isOn: Binding(get: { p.mix.masterLimiter != nil }, set: { on in _ = try? plain.setMaster(gain: nil, limiter: on ? [:] : nil, removeLimiter: !on) }))
                    .toggleStyle(.checkbox).controlSize(.small).pointer().uiFrame("mixer.master.limiter")
                if let l = p.mix.masterLimiter {
                    Slider(value: Binding(get: { l.ceiling }, set: { v in _ = try? x.setMaster(gain: nil, limiter: ["ceiling": (v * 10).rounded() / 10], removeLimiter: false) }), in: -9...0)
                        .controlSize(.small).pointer().uiFrame("mixer.master.ceiling.slider")
                    Text(String(format: "%.1f dBTP", l.ceiling)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
                } else { Spacer() }
            }
            HStack(spacing: 8) {
                Button("Measure") { run { Self.text(try await plain.measureLoudness(clip: nil)) } }
                    .controlSize(.small).pointer().disabled(working).uiFrame("mixer.master.measure")
                Menu("Normalize") {
                    Button("YouTube, −14 LUFS") { normalize("youtube") }
                    Button("Apple and podcasts, −16 LUFS") { normalize("apple") }
                    Button("EBU R128, −23 LUFS") { normalize("ebu") }
                }
                .controlSize(.small).fixedSize().pointer().disabled(working).uiFrame("mixer.master.normalize")
                Spacer()
            }
            if let loudness { InspectorFootnote(loudness) }
        }
    }

    private var addBus: some View {
        HStack(spacing: 4) {
            TextField("New bus", text: $newBus).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 96).uiFrame("mixer.bus.new.name")
                .onSubmit(createBus)
            Button { createBus() } label: { Image(systemName: "plus").font(.system(size: 11, weight: .medium)) }
                .buttonStyle(.borderless).focusable(false).help("Add a bus").pointer().disabled(newBus.trimmingCharacters(in: .whitespaces).isEmpty).uiFrame("mixer.bus.add")
        }
    }

    // MARK: Actions

    private func createBus() {
        let n = newBus.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        do { _ = try plain.setBus(n, rename: nil, gain: 0, mute: nil, compressor: nil, removeCompressor: false, limiter: nil, removeLimiter: false, remove: false); newBus = "" }
        catch { loudness = "\(error)" }
    }

    private func normalize(_ target: String) {
        run {
            let r = try await plain.normalizeLoudness(target: target, ceiling: nil, clip: nil)
            return "Now " + Self.text(r.after) + String(format: " Master gain %+.1f dB.", r.gain) + (r.note.map { " " + $0 } ?? "")
        }
    }

    private func run(_ work: @escaping () async throws -> String) {
        working = true
        Task {
            defer { working = false }
            do { loudness = try await work() } catch { loudness = "\(error)" }
        }
    }

    static func text(_ r: ToolExecutor.LoudnessReport) -> String { ClipAudioSections.describe(r) }

    // MARK: Controls

    private func section<Content: View, Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) -> some View {
        InspectorCard(title, trailing: trailing, content: content)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        InspectorCard(title, content: content)
    }

    private func pill(_ label: String, on: Bool, color: Color, width: CGFloat = 18, help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10, weight: .bold)).frame(width: width, height: 16)
                .foregroundStyle(on ? (color == .accentColor ? Color.white : Color.black) : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(on ? color : Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false).help(help).pointer().uiFrame(id)
    }

    private func meter(_ id: UUID) -> some View {
        let db = Double(meters.levels[id] ?? -90)
        let frac = max(0, min(1, (db + 60) / 60))
        let gr = Double(meters.reduction[id] ?? 0)
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 2).fill(db > -1 ? Color.red : db > -9 ? Color.yellow : Color.green).frame(width: g.size.width * frac)
            }
        }
        .frame(height: 6).frame(minWidth: 40)
        .help(db <= -89 ? "No signal (meters show while playing)" : String(format: "Peak %.1f dBFS", db) + (gr > 0.1 ? String(format: ", %.1f dB of compression", gr) : ""))
        .uiFrame("mixer.\(id.short).meter")
    }

    private func fader(_ title: String, id: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String, reset: Double, width: CGFloat? = nil, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: set), in: range).controlSize(.small)
                .frame(maxWidth: width ?? .infinity).pointer().uiFrame("\(id).slider")
            Text(format(value)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                .onTapGesture(count: 2) { set(reset) }.help("Double-click to reset").pointer()
                .uiFrame("\(id).reset").uiTap("\(id).reset", count: 2) { set(reset) }
        }
    }
}
