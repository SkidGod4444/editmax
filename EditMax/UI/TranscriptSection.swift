import SwiftUI

/// The clip's spoken words in the inspector: click a word, then another, to select a span and cut it from the
/// timeline (ripple), like deleting text. Lives inside ClipInspector's Form.
struct TranscriptSection: View {
    @ObservedObject var document: EditMaxDocument
    let clip: Clip
    @State private var busy = false
    @State private var status: String?
    @State private var anchor: Int?                  // the first click of a span, until the second click closes it
    @State private var selection: ClosedRange<Int>?

    var body: some View {
        let x = ToolExecutor(document: document, origin: .user)   // plain, not coalesced: every cut is its own undo step
        let words = document.project.transcript(for: clip.assetID).map { x.timelineWords($0, clip: clip) } ?? []
        let hasTranscript = document.project.transcript(for: clip.assetID) != nil
        Section("Transcript") {
            if !hasTranscript {
                HStack {
                    Button(busy ? "Transcribing…" : "Transcribe", systemImage: "text.quote") { transcribe(x) }
                        .pointer().disabled(busy).uiTap("transcript.transcribe", key: "\(busy)") { if !busy { transcribe(x) } }.uiFrame("transcript.transcribe")
                    Spacer()
                }.controlSize(.small)
            } else if words.isEmpty {
                Text("No speech was recognized in this clip.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    FlowLayout(spacing: 2) {
                        ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                            let selected = selection?.contains(i) ?? false
                            Text(w.text)
                                .font(.system(size: 12))
                                .padding(.horizontal, 2).padding(.vertical, 1)
                                .background(selected ? Color.accentColor.opacity(0.35) : (anchor == i ? Color.accentColor.opacity(0.15) : .clear))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .contentShape(Rectangle())
                                .onTapGesture { tap(i) }
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 220)
                // One frame for the whole block: hundreds of per-word ids would flood the driver. The hand cursor sits
                // on the block for the same reason.
                .pointer().uiFrame("transcript.words")
                .uiTap("transcript.selectAll", key: "\(words.count)") { anchor = nil; selection = 0...(words.count - 1) }
                HStack(spacing: 8) {
                    let count = selection.map { $0.count } ?? 0
                    Button(busy ? "Cutting…" : count > 0 ? "Cut \(count) word\(count == 1 ? "" : "s")" : "Cut selection", systemImage: "scissors") { cut(x, words: words) }
                        .pointer().disabled(busy || selection == nil)
                        .uiTap("transcript.cut", key: "\(words.count)-\(selection.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "none")-\(busy)") { if !busy, selection != nil { cut(x, words: words) } }
                        .uiFrame("transcript.cut")
                    Button("Clear") { anchor = nil; selection = nil }.pointer().disabled(selection == nil && anchor == nil).uiFrame("transcript.clear")
                    Spacer()
                }.controlSize(.small)
            }
            Text(status ?? (hasTranscript ? "Click a word, then another, to select what to cut. The cut ripples every track." : Transcriber.privacyNote))
                .font(.caption).foregroundStyle(.secondary)
                // On this row, not the Section: a modifier on a Section can collapse it into one row of the Form.
                // The section keeps its state when the inspector moves to another clip, so a selection made on one
                // clip must not cut words of the next.
                .onChange(of: clip.id) { _, _ in anchor = nil; selection = nil; status = nil }
                .onChange(of: words.count) { _, _ in anchor = nil; selection = nil }
        }
    }

    private func tap(_ i: Int) {
        let shift = UIRegistry.shared.currentModifiers.contains(.shift)
        if let a = anchor { selection = min(a, i)...max(a, i); anchor = nil }                 // second click closes the span
        else if shift, let s = selection { selection = min(s.lowerBound, i)...max(s.upperBound, i) }   // ⇧ grows an existing one
        else { anchor = i; selection = i...i }                                               // first click starts one
    }

    private func transcribe(_ x: ToolExecutor) {
        busy = true; status = "Transcribing…"
        Task { @MainActor in
            defer { busy = false }
            do { _ = try await x.ensureTranscript(assetID: clip.assetID, language: nil); status = nil } catch { status = error.localizedDescription }
        }
    }

    private func cut(_ x: ToolExecutor, words: [TranscriptWord]) {
        guard let sel = selection, !words.isEmpty else { return }
        let from = max(0, min(sel.lowerBound, words.count - 1)), to = max(from, min(sel.upperBound, words.count - 1))
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let r = try await x.cutTranscript(clip: clip.id.uuidString, asset: nil, phrase: nil, occurrence: nil, fromWord: from, toWord: to,
                                                  startTime: nil, endTime: nil, padding: 0.03, language: nil)
                anchor = nil; selection = nil
                let n = r.words?.count ?? 0
                status = "Cut \(n) word\(n == 1 ? "" : "s"), \(String(format: "%.2f", r.removedSeconds)) s. Timeline is now \(Timecode.string(r.duration))."
            } catch { status = error.localizedDescription }
        }
    }
}

/// Lays its children out like words in a paragraph: left to right, wrapping at the available width. Child sizes are
/// cached between the measure and place passes, which keeps a few thousand words cheap.
struct FlowLayout: Layout {
    var spacing: CGFloat = 2

    struct Cache { var sizes: [CGSize] = [] }
    func makeCache(subviews: Subviews) -> Cache { Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) }) }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) } }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in cache.sizes {
            if x > 0, x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing; rowHeight = max(rowHeight, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for (i, s) in cache.sizes.enumerated() {
            if x > 0, x + s.width > bounds.width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowHeight = max(rowHeight, s.height)
        }
    }
}
