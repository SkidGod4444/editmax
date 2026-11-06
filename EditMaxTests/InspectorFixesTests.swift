import XCTest
import SwiftUI
import AppKit
import AVFoundation
@testable import EditMax

/// A view laid out in a window that is never shown: AppKit-backed controls draw, and `.uiFrame` probes register their
/// frames (window points, top-left origin), so a test can check sizes and positions as well as write the picture.
@MainActor
final class OffscreenHost {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let size: CGSize

    init<V: View>(_ view: V, size: CGSize, dark: Bool) {
        // Frames left by an earlier render would answer for views that are not there now.
        for id in Array(UIRegistry.shared.frames.keys) { UIRegistry.shared.remove(id) }
        self.size = size
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)))
        host.appearance = appearance
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        settle()
    }

    /// Lets onAppear, tasks and the frame probes run.
    func settle(_ rounds: Int = 5) {
        for _ in 0..<rounds { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    func frame(_ id: String) -> CGRect? { UIRegistry.shared.frame(id) }

    /// Writes the whole view, or the band `rows` (window points) of it, as a PNG under $EDITMAX_PREVIEW_DIR/inspector-fixes.
    func save(_ name: String, rows: ClosedRange<CGFloat>? = nil) {
        guard Self.previewDir != nil, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard var image = rep.cgImage else { return }
        if let rows {
            let k = CGFloat(image.height) / host.bounds.height
            let top = max(0, rows.lowerBound), bottom = min(host.bounds.height, rows.upperBound)
            if let c = image.cropping(to: CGRect(x: 0, y: top * k, width: CGFloat(image.width), height: (bottom - top) * k)) { image = c }
        }
        Self.write(image, name)
    }

    static var previewDir: URL? {
        guard let d = ProcessInfo.processInfo.environment["EDITMAX_PREVIEW_DIR"], !d.isEmpty else { return nil }
        let dir = URL(fileURLWithPath: d).appendingPathComponent("inspector-fixes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ image: CGImage, _ name: String) {
        guard let dir = previewDir else { return }
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try? png?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    func close() { window.contentView = nil; settle(1) }
}

// MARK: - Logic

@MainActor
final class InspectorFixesTests: XCTestCase {

    /// M6: a clip shows the cards for what it has. Sound cards need sound in the file; the picture transition needs a
    /// picture track; an unread or missing file keeps the sound cards (nothing set on them is hidden).
    func testCardsFollowWhatTheClipHas() {
        let silentVideo = ClipCards(track: .video, asset: .video, sound: .none)
        XCTAssertTrue(silentVideo.picture); XCTAssertTrue(silentVideo.transition)
        XCTAssertFalse(silentVideo.sound); XCTAssertFalse(silentVideo.splitEdit)
        XCTAssertTrue(silentVideo.fadesOnly, "a picture without sound still fades to black")

        let video = ClipCards(track: .video, asset: .video, sound: .some)
        XCTAssertTrue(video.sound); XCTAssertTrue(video.splitEdit); XCTAssertTrue(video.transition); XCTAssertFalse(video.fadesOnly)

        let music = ClipCards(track: .audio, asset: .audio, sound: .some)
        XCTAssertTrue(music.sound)
        XCTAssertFalse(music.picture); XCTAssertFalse(music.transition, "sound alone gets no picture transition"); XCTAssertFalse(music.splitEdit)

        let still = ClipCards(track: .video, asset: .image, sound: .unknown)
        XCTAssertFalse(still.sound); XCTAssertTrue(still.fadesOnly)

        let unread = ClipCards(track: .video, asset: .video, sound: .unknown)
        XCTAssertTrue(unread.sound); XCTAssertTrue(unread.splitEdit)
        let nested = ClipCards(track: .video, asset: .sequence, sound: .some)
        XCTAssertTrue(nested.sound); XCTAssertFalse(nested.splitEdit)
    }

    /// M13: Show parks where the title is fully on screen: after the in animation (a typewriter has every letter),
    /// before the out animation, inside the title, with the frame on screen at that time already past the animation.
    func testShowParksWhereTheTitleIsFullyOnScreen() {
        func title(start: Double, duration: Double, _ a: TextAnimation?) -> TextOverlay {
            var t = TextOverlay(text: "Asha Rao", start: start, duration: duration)
            t.animation = a
            return t
        }
        for fps in [24.0, 30, 60] {
            let typed = title(start: 0.8, duration: 4.2, TextAnimation(inKind: .typewriter, inDuration: 1, outKind: .fade, outDuration: 0.4))
            let t = TextInspector.showTime(for: typed, fps: fps)
            XCTAssertEqual(t, 0.8 + 1 + max(0.05, 1 / fps), accuracy: 1e-9)
            // The picture at t is the frame that starts at or before it.
            let frame = (t * fps).rounded(.down) / fps
            let p = TitleAnimator.phases(typed, at: frame)
            XCTAssertEqual(p.inP, 1, "every letter is on screen at \(fps) fps"); XCTAssertEqual(p.outP, 1)
        }
        // No animation: just inside the start, as before.
        XCTAssertEqual(TextInspector.showTime(for: title(start: 2, duration: 3, nil), fps: 30), 2.05, accuracy: 1e-9)
        // In and out overlap on a short title: where both are furthest along, inside the title.
        let short = title(start: 1, duration: 0.6, TextAnimation(inKind: .typewriter, inDuration: 0.5, outKind: .fade, outDuration: 0.4))
        let s = TextInspector.showTime(for: short, fps: 30)
        let ps = TitleAnimator.phases(short, at: s)
        XCTAssertEqual(ps.inP, ps.outP, accuracy: 1e-9)
        XCTAssertGreaterThan(s, 1); XCTAssertLessThan(s, 1.6)
        // An in animation longer than the title: its last moment, still inside.
        let long = title(start: 0, duration: 0.5, TextAnimation(inKind: .words, inDuration: 2))
        let l = TextInspector.showTime(for: long, fps: 30)
        XCTAssertLessThan(l, 0.5); XCTAssertGreaterThan(l, 0.49)
    }

    /// M5: errors read as sentences: no Swift enum text, no "Invalid:" prefix, no tool names, no framework names; and
    /// for a clip, the reason is about the clip.
    func testErrorsReadAsPlainEnglish() {
        let nothing = EditError.invalid("nothing to measure: no clip with sound on an unmuted track")
        XCTAssertEqual(InspectorMessage.text(nothing), "There is no sound to measure: no clip with sound plays on an unmuted track.")
        XCTAssertEqual(InspectorMessage.text(nothing, scope: .clip), "This clip has no sound to measure.")
        XCTAssertEqual(InspectorMessage.text(EditError.invalid("'Ridge' has a transition, which already crossfades its sound; remove it first (set_transition kind none)")),
                       "'Ridge' has a transition, which already crossfades its sound; remove it first.")
        XCTAssertEqual(InspectorMessage.text(EditError.notFound("clip 'abc'")), "Could not find clip 'abc'.")
        XCTAssertEqual(InspectorMessage.text(EditError.invalid("Transcription failed: Invalid: no speech")), "Transcription failed: no speech.")
        XCTAssertEqual(InspectorMessage.text(EditError.invalid("'Voice' has mono sound: AVFoundation hands its processing one channel and spreads it to both speakers afterwards, so it cannot be panned")),
                       "'Voice' has mono sound: it plays in both speakers and cannot be panned.")
        XCTAssertEqual(InspectorMessage.text(EditError.invalid("the clip is under a second long: too short to tell 50 from 60 Hz hum; give frequency 50 or 60")),
                       "The clip is under a second long: too short to tell 50 from 60 Hz hum. Choose 50 Hz or 60 Hz instead.")
        XCTAssertEqual(InspectorMessage.text(EditError.invalid("solo is on (A1): the mix would be measured without the other tracks. Turn solo off first")),
                       "Solo is on (A1): the mix would be measured without the other tracks. Turn solo off first.")
        // A file name with an underscore in brackets is not a tool hint.
        XCTAssertEqual(InspectorMessage.text(EditError.invalid("cannot open the file ('my_clip.mp4')")), "Cannot open the file ('my_clip.mp4').")
        let ns = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [NSLocalizedDescriptionKey: "The file couldn’t be opened."])
        XCTAssertEqual(InspectorMessage.text(ns), "The file couldn’t be opened.")
        for e in [nothing, EditError.invalid("cannot read the mixed sound")] {
            let s = InspectorMessage.text(e)
            XCTAssertFalse(s.contains("invalid(") || s.contains("Invalid") || s.contains("AVFoundation"), s)
        }
    }

    /// L2: the J/L Kind row is in sentence case like the other labels.
    func testSplitEditKindIsSentenceCase() {
        var c = Clip(assetID: UUID(), name: "Ridge", start: 2, duration: 3)
        XCTAssertEqual(EditingInspectorCards.kindTitle(c), "Sound with picture")
        c.audioLead = 0.5
        XCTAssertEqual(EditingInspectorCards.kindTitle(c), "J cut")
        c.audioTrail = 0.4
        XCTAssertEqual(EditingInspectorCards.kindTitle(c), "J and L cut")
        c.audioLead = -0.3; c.audioTrail = -0.2
        XCTAssertEqual(EditingInspectorCards.kindTitle(c), "Sound inside the picture")
    }

    /// L2: the noise gate is off at the left end of its slider (like high-pass and voice isolation), stronger to the right.
    func testNoiseGateIsOffAtTheLeft() {
        XCTAssertEqual(ClipInspector.gateSlider(0), ClipInspector.gateOff, "off sits at the left end")
        XCTAssertEqual(ClipInspector.gateValue(fromSlider: ClipInspector.gateOff), 0)
        XCTAssertEqual(ClipInspector.gateText(ClipInspector.gateOff), "off")
        XCTAssertEqual(ClipInspector.gateValue(fromSlider: -40.4), -40)
        XCTAssertEqual(ClipInspector.gateSlider(-40), -40)
        XCTAssertEqual(ClipInspector.gateText(-40), "-40 dB")
        XCTAssertEqual(ClipInspector.gateSlider(-90), -90, "the quietest threshold the tool takes is still a threshold, not off")
        XCTAssertEqual(ClipInspector.gateValue(fromSlider: -1), -1, "the right end gates hardest")
        XCTAssertLessThan(ClipInspector.gateSlider(-60), ClipInspector.gateSlider(-20), "a higher threshold is further right")
    }

    /// L2/L5: sliders that run both ways from zero fill from zero and snap onto it; the others do not.
    func testBipolarSlidersRestAtZero() {
        XCTAssertEqual(InspectorSlider.neutral(range: -1...1, reset: 0), 0)            // pan, position
        XCTAssertEqual(InspectorSlider.neutral(range: -60...12, reset: 0), 0)          // track gain
        XCTAssertEqual(InspectorSlider.neutral(range: -0.5...1, reset: 0), 0)          // the gain wheel's master
        XCTAssertNil(InspectorSlider.neutral(range: 0...1, reset: 0))                  // an amount
        XCTAssertNil(InspectorSlider.neutral(range: 0.1...4, reset: 1))                // scale
        XCTAssertNil(InspectorSlider.neutral(range: -24...0, reset: -1))               // a ceiling
        XCTAssertEqual(InspectorSlider.snapped(0.015, to: 0, in: -1...1), 0)
        XCTAssertEqual(InspectorSlider.snapped(-0.4, to: 0, in: -60...12), 0)
        XCTAssertEqual(InspectorSlider.snapped(0.03, to: 0, in: -1...1), 0.03)
        XCTAssertEqual(InspectorSlider.snapped(0.001, to: nil, in: -1...1), 0.001)
    }

    /// M6: the sound probe tells a video file without sound from one with sound, and keeps unknown for a missing file.
    func testSoundProbe() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-fixes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let silent = dir.appendingPathComponent("hero.mp4")
        try await EditingTestVideo.write(to: silent, seconds: 1, cuts: [])
        let wav = try TestSignal.writeWAV([TestSignal.voice(seconds: 1), TestSignal.voice(seconds: 1)], to: dir.appendingPathComponent("music.wav"))
        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .agent)
        _ = try await x.importMedia(paths: [silent.path, wav.path])
        let v = try x.insertClip(asset: "hero.mp4"), a = try x.insertClip(asset: "music.wav")
        let p = doc.project
        let silentRead = await ClipSound.probe(p.clip(v.id)!.clip, in: p)
        XCTAssertEqual(silentRead, .none)
        XCTAssertEqual(ClipSound.cached(p.clip(v.id)!.clip, in: p), .none, "read once, then cached")
        let soundRead = await ClipSound.probe(p.clip(a.id)!.clip, in: p)
        XCTAssertEqual(soundRead, .some)
        var missing = p
        missing.assets = missing.assets.map { var m = $0; if m.kind == .video { m.path = dir.appendingPathComponent("gone.mp4").path }; return m }
        let missingRead = await ClipSound.probe(missing.clip(v.id)!.clip, in: missing)
        XCTAssertEqual(missingRead, .unknown)
        if let base = Bundle(for: Self.self).url(forResource: "base", withExtension: "mp4") {
            let hasAudio = !((try? await AVURLAsset(url: base).loadTracks(withMediaType: .audio)) ?? []).isEmpty
            let d2 = EditMaxDocument()
            d2.project.assets.append(Asset(name: "base.mp4", path: base.path, kind: .video, duration: 2, width: 1920, height: 1080))
            let c = try ToolExecutor(document: d2, origin: .agent).insertClip(asset: "base.mp4")
            let baseRead = await ClipSound.probe(d2.project.clip(c.id)!.clip, in: d2.project)
            XCTAssertEqual(baseRead, hasAudio ? .some : .none)
        }
    }
}

// MARK: - Pictures, sizes and positions

@MainActor
final class InspectorFixesPreviewTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-fixes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func inspector(_ doc: EditMaxDocument, _ id: UUID) -> some View {
        let f = doc.project.clip(id)!
        return ClipInspector(document: doc, clip: f.clip, track: f.track).environmentObject(EditorState()).environmentObject(PlayerController())
    }

    /// M6 and L5 on a video with no sound (the audit's Ridge, hero.mp4): picture cards, fades and the picture transition;
    /// none of the sound cards; the crops line up with the keyframed transform rows.
    func testVideoWithoutSoundShowsNoSoundCards() async throws {
        let file = dir.appendingPathComponent("hero.mp4")
        try await EditingTestVideo.write(to: file, seconds: 2, cuts: [])
        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .agent)
        _ = try await x.importMedia(paths: [file.path])
        let c = try x.insertClip(asset: "hero.mp4")
        _ = await ClipSound.probe(doc.project.clip(c.id)!.clip, in: doc.project)
        let h = OffscreenHost(inspector(doc, c.id), size: CGSize(width: 360, height: 4200), dark: true)
        defer { h.close() }
        for gone in ["inspector.volume.slider", "inspector.noiseGate.slider", "inspector.audio.compressor.toggle", "inspector.audio.hum.toggle",
                     "inspector.audio.loudness.measure", "inspector.audio.gain.slider", "inspector.splitEdit.lead.slider"] {
            XCTAssertNil(h.frame(gone), "\(gone) shows for a clip without sound")
        }
        let fadeIn = try XCTUnwrap(h.frame("inspector.fadeIn.slider"), "fades stay")
        XCTAssertNotNil(h.frame("inspector.transition.kind"))
        let scale = try XCTUnwrap(h.frame("inspector.scale.slider")), crop = try XCTUnwrap(h.frame("inspector.cropLeft.slider"))
        XCTAssertEqual(crop.minX, scale.minX, accuracy: 0.5, "crop sliders start where the keyframed transform sliders start")
        XCTAssertEqual(crop.width, scale.width, accuracy: 0.5)
        h.save("m6-video-without-sound-transform", rows: (scale.minY - 60)...(crop.maxY + 150))
        h.save("m6-video-without-sound-bottom", rows: (fadeIn.minY - 60)...(fadeIn.minY + 420))
    }

    /// M6, L8: sound alone on an audio track: no picture transition; the crossfade switch with no clip before it is
    /// drawn disabled. L2: the noise gate's off at the left; L5: fades line up with Volume.
    func testAudioClipHasNoPictureTransition() async throws {
        let wav = try TestSignal.writeWAV([TestSignal.voice(seconds: 4), TestSignal.voice(seconds: 4, seed: 3)], to: dir.appendingPathComponent("music.wav"))
        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .agent)
        _ = try await x.importMedia(paths: [wav.path])
        let c = try x.insertClip(asset: "music.wav")
        XCTAssertEqual(doc.project.clip(c.id)?.track.kind, .audio)
        for dark in [true, false] {
            let h = OffscreenHost(inspector(doc, c.id), size: CGSize(width: 360, height: 2000), dark: dark)
            XCTAssertNil(h.frame("inspector.transition.kind"), "no picture transition on sound alone")
            let toggle = try XCTUnwrap(h.frame("inspector.audio.crossfade.toggle"))
            let volume = try XCTUnwrap(h.frame("inspector.volume.slider")), fade = try XCTUnwrap(h.frame("inspector.fadeOut.slider"))
            XCTAssertEqual(fade.minX, volume.minX, accuracy: 0.5, "fade sliders line up with Volume")
            let gate = try XCTUnwrap(h.frame("inspector.noiseGate.slider"))
            h.save("m6-audio-clip-top-\(dark ? "dark" : "light")", rows: (volume.minY - 70)...(gate.maxY + 80))
            h.save("m6-audio-clip-bottom-\(dark ? "dark" : "light")", rows: (toggle.minY - 330)...(toggle.maxY + 80))
            h.close()
        }
    }

    /// M6 (sound kept for a file not read yet), L2 (Lead/Trail fill from zero with a tick; Kind in sentence case),
    /// L4 (header Reset buttons and the keyframe diamonds are real targets).
    func testVideoWithSoundAndAJCut() throws {
        let doc = EditMaxDocument()
        doc.project.assets.append(Asset(name: "interview.mp4", path: dir.appendingPathComponent("not-read-yet.mp4").path, kind: .video, duration: 10, width: 1280, height: 720))
        let x = ToolExecutor(document: doc, origin: .agent)
        let c = try x.insertClip(asset: "interview.mp4", at: 2, duration: 4)
        doc.project.tracks[0].clips[0].sourceIn = 2
        _ = try x.setSplitEdit(c.id.uuidString, lead: 0.6, trail: nil, neighbour: "overlap")
        _ = try x.setClipTransform(c.id.uuidString, scale: 1.2, x: nil, y: nil, rotation: nil, cropLeft: nil, cropRight: nil, cropTop: nil, cropBottom: nil, reset: false)
        _ = try x.setClipAudio(c.id.uuidString, low: 3, mid: nil, high: nil, highPass: nil, gate: -45, reset: false)
        let h = OffscreenHost(inspector(doc, c.id), size: CGSize(width: 360, height: 4600), dark: true)
        defer { h.close() }
        let lead = try XCTUnwrap(h.frame("inspector.splitEdit.lead.slider"), "the J/L card stays for a file not read yet")
        XCTAssertNotNil(h.frame("inspector.audio.compressor.toggle"))
        let gate = try XCTUnwrap(h.frame("inspector.noiseGate.slider"))
        for id in ["inspector.transform.reset", "inspector.audio.reset", "inspector.splitEdit.reset", "inspector.key.scale", "inspector.audio.loudness.measure", "inspector.audio.loudness.normalize"] {
            let f = try XCTUnwrap(h.frame(id), id)
            XCTAssertGreaterThanOrEqual(f.height, 20, "\(id) is \(f.size)"); XCTAssertGreaterThanOrEqual(f.width, 20, "\(id) is \(f.size)")
        }
        h.save("l2-split-edit", rows: (lead.minY - 90)...(lead.maxY + 120))
        h.save("l2-eq-gate", rows: (gate.minY - 200)...(gate.maxY + 100))
        let scale = try XCTUnwrap(h.frame("inspector.scale.slider"))
        h.save("l5-transform", rows: (scale.minY - 40)...(scale.minY + 330))
    }

    /// L4: every small control in the color sections and the markers list is at least 20 × 20 points.
    func testSmallControlsAreAtLeast20Points() throws {
        let doc = EditMaxDocument()
        doc.project.assets.append(Asset(name: "a.mp4", path: dir.appendingPathComponent("a.mp4").path, kind: .video, duration: 10, width: 1920, height: 1080))
        let x = ToolExecutor(document: doc, origin: .agent)
        let c = try x.insertClip(asset: "a.mp4")
        _ = try x.addGradeLayer(c.id.short, name: "Spotlight", index: nil, mix: nil, enabled: nil)
        _ = try x.addGradeLayer(c.id.short, name: "Layer 2", index: nil, mix: nil, enabled: nil)
        _ = try x.setColorCurve(c.id.short, layer: nil, curve: "master", points: [[0.25, 0.2], [0.75, 0.82]])
        _ = try x.setColorWheels(c.id.short, layer: nil, wheel: "gain", r: nil, g: nil, b: nil, master: 0.2, toward: nil, amount: nil, reset: false)
        _ = try x.setClipFinish(c.id.short, values: ["grain": 0.25], reset: false)
        let clip = doc.project.clip(c.id)!.clip
        let cards = VStack(spacing: 16) {
            GradeLayersCard(document: doc, clip: clip, selected: .constant(clip.grades[1].id))
            CurvesCard(document: doc, clip: clip)
            ColorWheelsCard(document: doc, clip: clip)
            FinishCard(document: doc, clip: clip)
        }.padding(12)
        let h = OffscreenHost(cards, size: CGSize(width: 360, height: 1100), dark: true)
        var ids = ["inspector.color.layers.add", "inspector.color.curves.reset", "inspector.color.wheels.reset", "inspector.color.finish.reset"]
        for n in 1...2 { ids += ["up", "down", "remove"].map { "inspector.color.layer.\(n).\($0)" } }
        for id in ids {
            let f = try XCTUnwrap(h.frame(id), id)
            XCTAssertGreaterThanOrEqual(f.width, 20, "\(id) is \(f.size)"); XCTAssertGreaterThanOrEqual(f.height, 20, "\(id) is \(f.size)")
        }
        // L5: the gain wheel's master fills from 0, which sits a third of the way along its −0.5…1 range.
        let master = try XCTUnwrap(h.frame("inspector.color.wheel.gain.master.slider"))
        h.save("l4-grade-layers-curves-wheels", rows: 0...(master.maxY + 40))
        h.close()

        doc.project.markers = [Marker(time: 9.5, name: "Jump")]
        let state = EditorState()
        let p = OffscreenHost(ProjectInspector(document: doc).environmentObject(state).environmentObject(PlayerController()), size: CGSize(width: 360, height: 1200), dark: true)
        defer { p.close() }
        let m = doc.project.markers[0].id.short
        for id in ["inspector.marker.\(m).go", "inspector.marker.\(m).remove"] {
            let f = try XCTUnwrap(p.frame(id), id)
            XCTAssertGreaterThanOrEqual(f.width, 20, "\(id) is \(f.size)"); XCTAssertGreaterThanOrEqual(f.height, 20, "\(id) is \(f.size)")
        }
        let go = try XCTUnwrap(p.frame("inspector.marker.\(m).go"))
        p.save("l4-markers", rows: (go.minY - 50)...(go.maxY + 60))
    }

    /// L9 and L4 for the mixer: at the default window (1352 × 848 leaves a 380 × 383 pt mixer under the timeline split)
    /// Measure and Normalize are on screen without scrolling, and a track's gain and pan sliders are wide enough to use.
    func testMixerFitsTheDefaultWindow() throws {
        let doc = EditMaxDocument()
        let x = ToolExecutor(document: doc, origin: .agent)
        _ = try x.addTrack(kind: "audio", name: nil)
        _ = try x.setBus("Music", rename: nil, gain: -2, mute: nil, compressor: nil, removeCompressor: false, limiter: nil, removeLimiter: false, remove: false)
        _ = try x.setBus("Dialogue", rename: nil, gain: 0, mute: nil, compressor: nil, removeCompressor: false, limiter: nil, removeLimiter: false, remove: false)
        _ = try x.setMaster(gain: 11.1, limiter: [:], removeLimiter: false)
        let size = CGSize(width: 380, height: 383)
        let names = doc.project.tracks.map(\.name)
        for dark in [true, false] {
            let h = OffscreenHost(MixerPane(document: doc, player: nil), size: size, dark: dark)
            for id in ["mixer.master.measure", "mixer.master.normalize"] {
                let f = try XCTUnwrap(h.frame(id), id)
                XCTAssertGreaterThanOrEqual(f.minY, 0); XCTAssertLessThanOrEqual(f.maxY, size.height, "\(id) is below the pane: \(f)")
                XCTAssertGreaterThanOrEqual(f.height, 20, "\(id) is \(f.size)")
            }
            for t in names {
                let g = try XCTUnwrap(h.frame("mixer.\(t).gain.slider")), pan = try XCTUnwrap(h.frame("mixer.\(t).pan.slider"))
                XCTAssertGreaterThanOrEqual(g.width, 180, "\(t) gain slider is \(g.width) pt"); XCTAssertGreaterThanOrEqual(pan.width, 180)
                let m = try XCTUnwrap(h.frame("mixer.\(t).mute"))
                XCTAssertGreaterThanOrEqual(m.height, 20); XCTAssertGreaterThanOrEqual(m.width, 20)
            }
            let trash = try XCTUnwrap(h.frame("mixer.bus.Music.remove"))
            XCTAssertGreaterThanOrEqual(trash.width, 20); XCTAssertGreaterThanOrEqual(trash.height, 20)
            h.save("l9-mixer-380x383-\(dark ? "dark" : "light")")
            h.close()
        }
        // The pane scrolled to the end, so the buses' footer (no framework names) is in the picture too.
        let tall = OffscreenHost(MixerPane(document: doc, player: nil), size: CGSize(width: 380, height: 760), dark: true)
        tall.save("l9-mixer-380x760-dark")
        tall.close()
        // What the pane shows while a measurement runs.
        let job = OffscreenHost(MixerJobLine(title: MixerPane.measuring, started: Date().addingTimeInterval(-7)).padding(10), size: CGSize(width: 380, height: 40), dark: true)
        job.save("l9-mixer-measuring")
        job.close()
    }

    /// M13: the frame Show parks on, for a typewriter title, drawn the way the export draws titles: left where Show used
    /// to park (0.05 s in: one letter), right where it parks now (the whole line).
    func testShowFramesTheWholeTitle() throws {
        var t = TextOverlay(text: "Asha Rao, field engineer", start: 0.8, duration: 4.2, y: 0.5)
        t.animation = TextAnimation(inKind: .typewriter, inDuration: 1, outKind: .fade, outDuration: 0.4)
        let size = CGSize(width: 960, height: 540), rect = CGRect(origin: .zero, size: CGSize(width: 960, height: 540))
        let layer = try XCTUnwrap(TitleRasterizer.layer(t, canvas: size))
        let fps = 30.0
        let parked = (TextInspector.showTime(for: t, fps: fps) * fps).rounded(.down) / fps   // the frame on screen there
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        let gap = 16
        let out = try XCTUnwrap(CGContext(data: nil, width: 960 * 2 + gap, height: 540, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        out.setFillColor(CGColor(gray: 1, alpha: 1)); out.fill(CGRect(x: 0, y: 0, width: 960 * 2 + gap, height: 540))
        for (i, time) in [t.start + 0.05, parked].enumerated() {
            let bg = CIImage(color: CIColor(red: 0.13, green: 0.16, blue: 0.22)).cropped(to: rect)
            let frame = try XCTUnwrap(ctx.createCGImage(TitleAnimator.draw(layer, at: time, size: size, over: bg) ?? bg, from: rect))
            out.draw(frame, in: CGRect(x: i * (960 + gap), y: 0, width: 960, height: 540))
        }
        OffscreenHost.write(try XCTUnwrap(out.makeImage()), "m13-show-before-after")
    }

    /// L8: a disabled switch looks disabled. The first row is the native mini switch enabled and disabled, the second
    /// the same with the inspector's dimming.
    func testDisabledSwitchLooksDisabled() throws {
        let row = { (dim: Bool) in
            HStack(spacing: 24) {
                Toggle("", isOn: .constant(false)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                Toggle("", isOn: .constant(false)).toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(true).inspectorDisabledLook(dim)
                Toggle("", isOn: .constant(true)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                Toggle("", isOn: .constant(true)).toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(true).inspectorDisabledLook(dim)
            }
        }
        for dark in [true, false] {
            let h = OffscreenHost(VStack(alignment: .leading, spacing: 12) { row(false); row(true) }.padding(12), size: CGSize(width: 260, height: 80), dark: dark)
            h.save("l8-switches-\(dark ? "dark" : "light")")
            h.close()
        }
    }
}

/// L10: a double-click on a Library item that is already in the project says so on its row instead of doing nothing.
@MainActor
final class LibraryDoubleClickTests: LibraryTestCase {
    func testDoubleClickOnAnItemAlreadyInTheProjectSaysSo() async throws {
        let video = try LibraryFixtures.video(dir, "Beach day.mp4")
        _ = await AssetLibrary.shared.add(urls: [video], source: .project, copy: false)
        let item = try XCTUnwrap(AssetLibrary.shared.all.first { $0.name == "Beach day.mp4" })
        let doc = EditMaxDocument()
        doc.project.assets = [Asset(name: item.name, path: item.path, kind: .video, duration: 2, width: 1920, height: 1080)]
        let h = OffscreenHost(LibraryPanelList(document: doc) { _ in }, size: CGSize(width: 260, height: 160), dark: true)
        defer { h.close() }
        let tap = try XCTUnwrap(UIRegistry.shared.tapHandlers["media.library.\(item.name)"]?[2], "the row takes a double-click")
        tap()
        h.settle()
        XCTAssertEqual(doc.project.assets.count, 1, "nothing is added twice")
        h.save("l10-library-already-in-project")
    }
}
