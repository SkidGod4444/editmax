import Foundation
import MCP

/// Where each tool's edit lands in the window (see `AgentFollow`). Every tool is either here or in `FollowPlans.none`
/// (`FollowPlansTests` fails on a tool that is in neither, so a new tool cannot be forgotten).
struct FollowPlan {
    typealias Args = [String: Value]
    /// The argument naming the clip the edit is on.
    var clip: String? = nil
    /// An argument listing clips: the playhead goes to the first; nothing is selected (they may be gone).
    var clips: String? = nil
    var text: String? = nil
    /// Select what the call made (a clip, a text, a grade layer) once it returns.
    var created = false
    var project = false
    var anchor: InspectorAnchor? = nil
    /// Picks the card from the arguments (overrides `anchor`).
    var anchorFor: ((Args) -> InspectorAnchor?)? = nil
    /// An argument holding a timeline time to show.
    var time: String? = nil
    /// The argument naming a grade layer of the clip.
    var layer: String? = nil
    var mixer = false
}

enum FollowPlans {
    typealias P = FollowPlan

    static let plans: [String: FollowPlan] = [
        // Timeline
        "insert_clip": P(created: true, anchor: .header),
        "split_clip": P(clip: "clip", time: "at"),
        "move_clip": P(clip: "clip", anchor: .timing),
        "trim_clip": P(clip: "clip", anchor: .timing),
        "remove_clips": P(clips: "clips"),
        "set_clip_properties": P(clip: "clip", anchorFor: { a in
            a["speed"] != nil ? .speed : a["volume"] != nil ? .audio : a["opacity"] != nil ? .transform : .header }),
        "close_gaps": P(),
        "ripple_delete": P(time: "start"),
        "add_track": P(), "move_track": P(), "rename_track": P(),
        "restore_snapshot": P(),
        "roll_edit": P(clip: "clip", anchor: .timing),
        "slip_clip": P(clip: "clip", anchor: .timing),
        "slide_clip": P(clip: "clip", anchor: .timing),
        "set_split_edit": P(clip: "clip", anchor: .splitEdit),
        "insert_edit": P(created: true, anchor: .header, time: "timeline_in"),
        "overwrite_edit": P(created: true, anchor: .header, time: "timeline_in"),
        "match_frame": P(clip: "clip"),
        "detect_scenes": P(clip: "clip", anchor: .scenes),
        "relink_media": P(),
        "nest_clips": P(created: true, anchor: .header),
        "unnest_clip": P(),
        "make_multicam": P(created: true, anchor: .multicam),
        "cut_angle": P(clip: "clip", anchor: .multicam, time: "at"),
        "set_multicam": P(clip: "clip", anchor: .multicam),
        "sync_angles": P(clip: "clip", anchor: .multicam),
        // Picture
        "set_clip_transform": P(clip: "clip", anchor: .transform),
        "auto_reframe": P(clip: "clip", anchor: .transform),
        "stabilize_clip": P(clip: "clip", anchor: .transform),
        "set_clip_fades": P(clip: "clip", anchor: .audio),
        "set_transition": P(clip: "clip", anchor: .transition),
        "set_keyframe": P(clip: "clip", anchorFor: FollowPlans.keyframeCard),
        "remove_keyframe": P(clip: "clip", anchorFor: FollowPlans.keyframeCard),
        "set_smooth_slow_motion": P(clip: "clip", anchor: .slowMotion),
        // Color
        "set_clip_color": P(clip: "clip", anchorFor: { a in a["look"] != nil || a["input_lut"] != nil || a["look_mix"] != nil ? .look : .color }),
        "set_color_wheels": P(clip: "clip", anchorFor: { a in a["layer"] != nil ? .gradeLayers : .wheels }, layer: "layer"),
        "set_color_curve": P(clip: "clip", anchorFor: { a in a["layer"] != nil ? .gradeLayers : .curves }, layer: "layer"),
        "add_grade_layer": P(clip: "clip", created: true, anchor: .gradeLayers),
        "update_grade_layer": P(clip: "clip", anchor: .gradeLayers, layer: "layer"),
        "remove_grade_layer": P(clip: "clip", anchor: .gradeLayers),
        "move_grade_layer": P(clip: "clip", anchor: .gradeLayers, layer: "layer"),
        "set_layer_mask": P(clip: "clip", anchor: .gradeLayers, layer: "layer"),
        "match_color": P(clip: "clip", anchor: .shotMatch),
        "set_clip_finish": P(clip: "clip", anchor: .finish),
        "set_project_color": P(project: true, anchor: .project),
        // Effects
        "set_chroma_key": P(clip: "clip", anchor: .key),
        "set_blend_mode": P(clip: "clip", anchor: .blend),
        "blur_faces": P(clip: "clip", anchor: .faceBlur),
        "blur_region": P(clip: "clip", anchor: .faceBlur),
        // Text
        "add_text": P(created: true, anchor: .title),
        "add_lower_third": P(text: "text", created: true, anchor: .lowerThird),
        "set_text_animation": P(text: "text", anchor: .textAnimation),
        "set_text_style": P(text: "text", anchor: .title),
        "remove_texts": P(), "remove_captions": P(),
        "add_captions": P(clip: "clip"),
        // Speech
        "remove_silence": P(clip: "clip"),
        "remove_words": P(clip: "clip"),
        "cut_transcript": P(clip: "clip"),
        // Sound
        "set_clip_audio": P(clip: "clip", anchor: .eq),
        "set_clip_compressor": P(clip: "clip", anchor: .compressor),
        "set_clip_limiter": P(clip: "clip", anchor: .limiter),
        "set_clip_deesser": P(clip: "clip", anchor: .deEsser),
        "set_clip_hum_removal": P(clip: "clip", anchor: .hum),
        "set_clip_mix": P(clip: "clip", anchor: .gainPan),
        "set_audio_crossfade": P(clip: "clip", anchor: .crossfade),
        "set_track_mix": P(mixer: true),
        "set_bus": P(mixer: true),
        "set_master": P(mixer: true),
        "normalize_loudness": P(clip: "clip", anchorFor: { a in a["clip"] != nil ? .gainPan : nil }, mixer: true),
        "set_ducking": P(project: true, anchor: .ducking),
        // Project
        // The markers card appears with the first marker: `created` reveals it again once the call has made it.
        "add_marker": P(created: true, project: true, anchor: .markers, time: "at"),
        "remove_marker": P(project: true, anchor: .markers),
        "apply_template": P(project: true, anchor: .project),
        "set_project_settings": P(project: true, anchor: .project),
    ]

    /// Tools that change nothing on screen worth following: reads, captures, exports, the UI driver itself (it already
    /// works the window), background jobs, and `set_playhead`, which moves the playhead on its own.
    static let none: Set<String> = [
        "list_projects", "inspect_timeline", "list_assets", "list_history", "list_templates", "inspect_sequence", "inspect_mix",
        "get_transcript", "search_transcript", "detect_silence", "measure_loudness", "frame_stats",
        "capture_frame", "capture_scopes", "capture_matte", "key_matte",
        "export_video", "export_batch", "export_chapters", "export_timeline", "save_template",
        "import_media", "make_proxies", "consolidate_media", "set_playhead",
        "list_library", "add_to_library",   // the Assets library is not in the project window
        "ui_layout", "ui_drag", "ui_key", "ui_click", "ui_select", "ui_scroll", "ui_screenshot",
        // Fonts belong to the app, not to a project: nothing in the window to show.
        "list_fonts", "install_font", "add_font_files",
    ]

    static func keyframeCard(_ a: FollowPlan.Args) -> InspectorAnchor? {
        switch a["param"]?.stringValue?.lowercased() ?? "" {
        case "speed": return .speed
        case "volume": return .audio
        case "scale", "x", "y", "rotation", "opacity", "crop_left", "crop_right", "crop_top", "crop_bottom": return .transform
        default: return .color
        }
    }
}

/// Runs one tool call with the window following it: reveal, a short pause so the eye lands there, the edit (animated),
/// then whatever the call created is selected.
@MainActor
enum AgentFollowDriver {
    static func run(_ name: String, _ a: [String: Value], _ body: () async throws -> EditMaxTools.Payload) async throws -> EditMaxTools.Payload {
        guard let plan = FollowPlans.plans[name], let doc = DocumentRegistry.shared.document(for: a["project"]?.stringValue),
              AgentFollow.shared.isFollowing(doc.id) else { return try await body() }
        let p0 = doc.project
        // The executor's own lookups, so the window follows exactly the clip, text or layer the edit changes.
        let x = ToolExecutor(document: doc, origin: .agent)
        let clipsBefore = Set(p0.allClips.map(\.id)), textsBefore = Set(p0.texts.map(\.id))
        let clipID = plan.clip.flatMap { a[$0]?.stringValue }.flatMap { try? x.resolveClip($0) }
        let gradesBefore = clipID.flatMap { p0.clip($0)?.clip.grades.map(\.id) } ?? []

        var target = FollowTarget(project: plan.project, anchor: plan.anchorFor?(a) ?? plan.anchor, mixer: plan.mixer)
        if let id = clipID, let c = p0.clip(id)?.clip { target.clip = id; target.time = c.start + min(0.5, c.duration / 2); target.range = c.start...c.end }
        if let list = plan.clips.flatMap({ a[$0]?.arrayValue }), let first = list.first?.stringValue, let id = try? x.resolveClip(first), let c = p0.clip(id)?.clip {
            target.time = c.start; target.range = c.start...c.end
        }
        if let s = plan.text.flatMap({ a[$0]?.stringValue }), let t = Project.resolve(s, in: p0.texts.map(\.id)),
           let tx = p0.texts.first(where: { $0.id == t }) {
            target.text = t; target.time = tx.start + min(0.5, tx.duration / 2); target.range = tx.start...tx.end
        }
        if let k = plan.time, let s = a[k]?.doubleValue ?? a[k]?.intValue.map(Double.init) { target.time = s; target.range = nil }
        if let id = clipID, let name = plan.layer.flatMap({ a[$0]?.stringValue }), let c = p0.clip(id)?.clip {
            target.layer = try? x.resolveLayer(name, in: c)
        }
        // A tool that only creates something has nothing to show before it runs.
        let before = plan.created && clipID == nil && target.text == nil ? FollowTarget(time: target.time) : target
        if AgentFollow.shared.reveal(doc.id, before), AgentFollow.shared.windowIsVisible {
            try? await Task.sleep(for: .milliseconds(280))
        }

        EditMaxDocument.animateAgentEdits = true
        defer { EditMaxDocument.animateAgentEdits = false }
        let result = try await body()
        AgentFollow.shared.lastAnimatedEdit = Date()

        if plan.created {
            let p1 = doc.project
            var made = target
            let newClips = p1.allClips.filter { !clipsBefore.contains($0.id) }
            let assetArg = a["asset"]?.stringValue
            if let c = newClips.first(where: { c in assetArg.map { matchesAsset(c.assetID, $0, p1) } ?? false }) ?? newClips.first {
                made.clip = c.id; made.text = nil; made.time = c.start + min(0.5, c.duration / 2); made.range = c.start...c.end
            } else if let t = p1.texts.first(where: { !textsBefore.contains($0.id) }) {
                made.text = t.id; made.clip = nil; made.time = t.start + min(0.5, t.duration / 2); made.range = t.start...t.end
            } else if let id = clipID, let layer = p1.clip(id)?.clip.grades.first(where: { !gradesBefore.contains($0.id) }) {
                made.layer = layer.id
            }
            AgentFollow.shared.reveal(doc.id, made)
        }
        return result
    }

    private static func matchesAsset(_ id: UUID, _ s: String, _ p: Project) -> Bool {
        guard let asset = p.asset(id) else { return false }
        return asset.name == s || asset.id.uuidString.lowercased().hasPrefix(s.lowercased())
    }
}
