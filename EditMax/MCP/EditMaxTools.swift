import Foundation
import MCP

/// Tool catalog exposed over MCP. Every tool resolves a document, builds a `ToolExecutor` with `origin: .agent`
/// and returns JSON both as text (for models) and as structuredContent (for clients that read it).
enum EditMaxTools {
    // MARK: Schema helpers
    private static func str(_ d: String) -> Value { .object(["type": "string", "description": .string(d)]) }
    private static func num(_ d: String) -> Value { .object(["type": "number", "description": .string(d)]) }
    private static func int(_ d: String) -> Value { .object(["type": "integer", "description": .string(d)]) }
    private static func strs(_ d: String) -> Value { .object(["type": "array", "items": .object(["type": "string"]), "description": .string(d)]) }
    private static func schema(_ props: [String: Value], required: [String] = []) -> Value {
        var s: [String: Value] = ["type": "object", "properties": .object(props), "additionalProperties": false]
        if !required.isEmpty { s["required"] = .array(required.map { .string($0) }) }
        return .object(s)
    }
    private static let projectArg = str("Project id prefix or window name. Omit for the active (front-most) project.")

    static let tools: [Tool] = [
        Tool(name: "list_projects", description: "List open EditMax projects (windows) with their ids. Use when more than one project is open.",
             inputSchema: schema([:]), annotations: .init(readOnlyHint: true)),
        Tool(name: "inspect_timeline", description: "Full state of a project's timeline: settings, tracks, every clip with times and ids, text overlays, history count. Call this before and after editing.",
             inputSchema: schema(["project": projectArg]), annotations: .init(readOnlyHint: true)),
        Tool(name: "list_assets", description: "Media files imported into the project, with ids, kind, duration and dimensions.",
             inputSchema: schema(["project": projectArg]), annotations: .init(readOnlyHint: true)),
        Tool(name: "import_media", description: "Import video, audio or image files from absolute paths on this Mac into the project's asset list. Files are referenced, not copied.",
             inputSchema: schema(["paths": strs("Absolute file paths (~ is expanded)"), "project": projectArg], required: ["paths"])),
        Tool(name: "insert_clip", description: "Place an asset on the timeline as a new clip. By default it is appended after the last clip on the first matching track.",
             inputSchema: schema(["asset": str("Asset id prefix or file name"), "track": str("Track id or name such as V1 or A1 (optional)"),
                                  "at": num("Timeline start in seconds (optional; default = end of track)"),
                                  "source_in": num("Seconds into the source file to start from (default 0)"),
                                  "duration": num("Length in seconds (default = remaining source length)"), "project": projectArg], required: ["asset"])),
        Tool(name: "split_clip", description: "Cut a clip into two at a timeline time.",
             inputSchema: schema(["clip": str("Clip id prefix"), "at": num("Timeline time in seconds, strictly inside the clip"), "project": projectArg], required: ["clip", "at"])),
        Tool(name: "move_clip", description: "Move a clip to a new timeline start, optionally onto another track of the same kind.",
             inputSchema: schema(["clip": str("Clip id prefix"), "start": num("New timeline start in seconds"), "track": str("Target track id or name (optional)"), "project": projectArg], required: ["clip", "start"])),
        Tool(name: "trim_clip", description: "Set a clip's timeline in and/or out point in seconds. Trimming the start keeps the content aligned (source offset moves with it).",
             inputSchema: schema(["clip": str("Clip id prefix"), "start": num("New start in seconds (optional)"), "end": num("New end in seconds (optional)"), "project": projectArg], required: ["clip"])),
        Tool(name: "remove_clips", description: "Delete clips from the timeline. Gaps are left; call close_gaps to ripple.",
             inputSchema: schema(["clips": strs("Clip id prefixes"), "project": projectArg], required: ["clips"]), annotations: .init(destructiveHint: true)),
        Tool(name: "set_clip_properties", description: "Change a clip's speed (1 = normal), volume (0-2), opacity (0-1) or display name.",
             inputSchema: schema(["clip": str("Clip id prefix"), "speed": num("Playback speed multiplier"), "volume": num("0 to 2"), "opacity": num("0 to 1"), "name": str("Display name"), "project": projectArg], required: ["clip"])),
        Tool(name: "close_gaps", description: "Ripple a track so its clips play back to back with no gaps.",
             inputSchema: schema(["track": str("Track id or name"), "project": projectArg], required: ["track"])),
        Tool(name: "add_text", description: "Add a text overlay (title, lower third, one caption) for a time range.",
             inputSchema: schema(["text": str("The text to show"), "start": num("Start in seconds"), "duration": num("Seconds on screen"),
                                  "preset": str("Look: title (default), subtitle, boxed, bold, outline, minimal"),
                                  "font_size": num("Points at project resolution (default from the preset)"), "color": str("Hex color like #FFFFFF"),
                                  "x": num("Horizontal center 0-1 (default 0.5)"), "y": num("Vertical center 0-1, 0 = top (default from the preset)"), "project": projectArg], required: ["text", "start", "duration"])),
        Tool(name: "get_transcript", description: "Speech in an asset or clip as timed words (on-device recognition, cached per asset; the first call on a long file takes a while). Clip times are timeline seconds, asset times are source seconds.",
             inputSchema: schema(["clip": str("Clip id prefix (timeline times)"), "asset": str("Asset id prefix or file name (source times)"),
                                  "language": str("Language tag such as en, en-IN, hi (default: the Mac's language)"), "project": projectArg])),
        Tool(name: "add_captions", description: "Transcribe the speech in a clip (or every clip with audio) and add timed caption lines as text overlays in one edit. Returns the caption group id.",
             inputSchema: schema(["clip": str("Clip id prefix (default: all clips with audio)"), "preset": str("Look: subtitle (default), boxed, bold, outline, minimal, title"),
                                  "max_words": int("Words per line (default from the preset)"), "language": str("Language tag (default: the Mac's language)"), "project": projectArg])),
        Tool(name: "detect_silence", description: "Find quiet stretches without changing anything: moments where no audible clip has sound (a music bed keeps the pauses under it), or with `clip` one clip's own pauses. Returns timeline ranges in seconds.",
             inputSchema: schema(["clip": str("Clip id prefix (default: all clips with audio)"), "threshold_db": num("Quiet below this many dB under the loudest peak (default -38)"),
                                  "min_duration": num("Shortest silence to report, seconds (default 0.6)"), "padding": num("Seconds of silence kept on each side (default 0.15)"), "project": projectArg]),
             annotations: .init(readOnlyHint: true)),
        Tool(name: "remove_silence", description: "Cut the quiet stretches out of the timeline (ripple: every track shifts, captions move with the content). Hidden and muted tracks are not listened to but are still cut; the result lists them as ignoredTracks. Do this before adding captions. Same parameters as detect_silence.",
             inputSchema: schema(["clip": str("Clip id prefix (default: all clips with audio)"), "threshold_db": num("Default -38"), "min_duration": num("Default 0.6 s"), "padding": num("Default 0.15 s"), "project": projectArg]),
             annotations: .init(destructiveHint: true)),
        Tool(name: "remove_words", description: "Cut the moments where filler words are spoken (um, uh, hmm, er… by default), using the transcript's word timings; ripple delete across all tracks. Do this before adding captions.",
             inputSchema: schema(["clip": str("Clip id prefix (default: all clips with audio)"), "words": strs("Words to cut (default: common fillers)"), "language": str("Language tag for transcription (default: the Mac's language)"), "project": projectArg]),
             annotations: .init(destructiveHint: true)),
        Tool(name: "ripple_delete", description: "Remove a time range from every track and close the gap; text overlays inside it go, later ones shift.",
             inputSchema: schema(["start": num("Timeline start in seconds"), "end": num("Timeline end in seconds"), "project": projectArg], required: ["start", "end"]), annotations: .init(destructiveHint: true)),
        Tool(name: "remove_captions", description: "Delete the captions of one group, or every caption when no group is given. Titles added with add_text stay.",
             inputSchema: schema(["group": str("Caption group id prefix from add_captions or inspect_timeline (optional)"), "project": projectArg]), annotations: .init(destructiveHint: true)),
        Tool(name: "remove_texts", description: "Delete text overlays by id.",
             inputSchema: schema(["ids": strs("Text overlay id prefixes"), "project": projectArg], required: ["ids"]), annotations: .init(destructiveHint: true)),
        Tool(name: "list_history", description: "Named snapshots recorded before each edit (newest first), by user, agent or system, each with a line saying what that edit changed. To get back to how things looked AFTER an edit, restore the entry just above it (the next edit's snapshot).",
             inputSchema: schema(["limit": int("Max entries (default 50)"), "project": projectArg]), annotations: .init(readOnlyHint: true)),
        Tool(name: "restore_snapshot", description: "Restore the project to the state captured by a history snapshot. The current state is snapshotted first, so this is always reversible.",
             inputSchema: schema(["snapshot": str("Snapshot id prefix from list_history"), "project": projectArg], required: ["snapshot"])),
        Tool(name: "set_playhead", description: "Move the playhead in the user's window to a time, optionally start playback. Use it to show the user a moment you are talking about.",
             inputSchema: schema(["seconds": num("Timeline time"), "play": .object(["type": "boolean", "description": "Start playing from there (default false)"]), "project": projectArg], required: ["seconds"])),
        Tool(name: "capture_frame", description: "Render the frame at a timeline time as a PNG image so you can see what the viewer sees (video, images and text).",
             inputSchema: schema(["seconds": num("Timeline time"), "max_width": int("Image width in pixels (default 960)"), "project": projectArg], required: ["seconds"]), annotations: .init(readOnlyHint: true)),
        Tool(name: "export_video", description: "Render the whole timeline to an MP4 at the project resolution: H.264/AAC 8-bit by default, or hevc10 for a 10-bit HEVC Main 10 master (4:2:0, Rec.709 tags, about 0.25 bits per pixel) to hand to a colorist. Blocks until done; expect roughly real time or faster.",
             inputSchema: schema(["path": str("Absolute output path ending in .mp4"), "preset": str("high (default, H.264), medium (720p), low (480p) or hevc10 (10-bit HEVC, project resolution)"), "chapters": .object(["type": "boolean", "description": "Also write the markers as a YouTube chapter list to <basename>.chapters.txt beside the MP4 (default false)"]), "project": projectArg], required: ["path"])),
        Tool(name: "add_track", description: "Add a video or audio track. New tracks go to the bottom row; the top row covers the rows below it in the picture.",
             inputSchema: schema(["kind": str("video or audio"), "name": str("Optional name (default V2, A2…)"), "project": projectArg], required: ["kind"])),
        Tool(name: "move_track", description: "Move a track to another row (0 = top). The top row covers the rows below it in the picture.",
             inputSchema: schema(["track": str("Track name or id prefix"), "row": int("Target row, 0 = top"), "project": projectArg], required: ["track", "row"])),
        Tool(name: "ui_layout", description: "Where things are in the EditMax window, in window points (origin top-left): media rows (media.<file>), track headers (header.<name>, header.Text, header.<name>.mute/.hide), lanes (lane.<name>, lane.Text), clip and text bars (clip.<id>, text.<id>, with .left/.right trim handles), toolbar buttons, addtrack.video/audio, ruler, inspector buttons. Use the ids with ui_drag and ui_click to drive the real UI.",
             inputSchema: schema(["prefix": str("Only ids starting with this (e.g. 'clip.')")]), annotations: .init(readOnlyHint: true)),
        Tool(name: "ui_drag", description: "Drag with the mouse inside the EditMax window, from one element (or point) to another: move or trim a bar, drop a media row onto a lane, reorder track headers, scrub the ruler. Events are posted to EditMax's own window only. Check the result with inspect_timeline or ui_screenshot.",
             inputSchema: schema(["from": .object(["description": .string("Element id from ui_layout, or {x, y} in window points")]), "to": .object(["description": .string("Element id or {x, y}")]),
                                  "from_dx": num("Offset from the source centre, points (e.g. -40 to grab near a clip's left part)"), "from_dy": num("Offset, points"), "to_dx": num("Offset from the target centre"), "to_dy": num("Offset"),
                                  "steps": int("Intermediate mouse moves (default 12)"), "modifiers": strs("shift, command, option, control (option = no snapping)"), "hold_ms": int("Pause after mouse-down before moving (default 80)")], required: ["from", "to"])),
        Tool(name: "ui_key", description: "Press a key in the EditMax window, as the user would: space (play/pause), j/k/l (shuttle), left/right (frame step, shift = 10), home/end, i/o/x (in, out, clear), m (marker), s (split), delete, or with modifiers such as [\"command\"] for ⌘T (transition), ⌘= / ⌘- (zoom), ⌘Z.",
             inputSchema: schema(["key": str("One character, or space, left, right, up, down, home, end, delete, forwarddelete, return, escape, tab"), "modifiers": strs("shift, command, option, control")], required: ["key"])),
        Tool(name: "ui_click", description: "Click an element (or point) in the EditMax window: buttons, a bar to select it, a header toggle. count 2 = double-click (e.g. a media row appends it). modifiers [\"shift\"] adds a bar to the selection.",
             inputSchema: schema(["target": .object(["description": .string("Element id from ui_layout, or {x, y}")]), "dx": num("Offset, points"), "dy": num("Offset, points"), "count": int("Clicks (default 1)"), "modifiers": strs("shift, command, option, control")], required: ["target"])),
        Tool(name: "ui_scroll", description: "Scroll the scrollable area under an element or point (the inspector, the media list, the timeline) by dy points; positive = down. Returns the new offset and how far it can go.",
             inputSchema: schema(["target": .object(["description": .string("Element id from ui_layout, or {x, y}")]), "dy": num("Points to scroll (positive = down)"), "dx": num("Points to scroll right")], required: ["target"])),
        Tool(name: "ui_screenshot", description: "The EditMax window as it looks now (this window's pixels only), as a PNG image.",
             inputSchema: schema(["max_width": int("Image width in pixels (default 1400)")]), annotations: .init(readOnlyHint: true)),
        Tool(name: "set_clip_transform", description: "Position a clip's picture in the frame: scale (1 = fit), x/y offset as a fraction of the frame (0.5 = half a frame right/down), rotation in clockwise degrees, crops as fractions of the picture cut from each edge. reset=true clears everything first.",
             inputSchema: schema(["clip": str("Clip id prefix"), "scale": num("0.05 to 10"), "x": num("-2 to 2"), "y": num("-2 to 2"), "rotation": num("Degrees"),
                                  "crop_left": num("0 to 0.95"), "crop_right": num("0 to 0.95"), "crop_top": num("0 to 0.95"), "crop_bottom": num("0 to 0.95"),
                                  "reset": .object(["type": "boolean", "description": "Clear the transform first"]), "project": projectArg], required: ["clip"])),
        Tool(name: "set_clip_color", description: "Color-correct a clip: exposure in stops (-4 to 4), contrast and saturation as multipliers (1 = untouched), temperature (-100 cool to 100 warm), tint (-100 green to 100 magenta), shadows/midtones/highlights tone-curve lifts (-1 to 1), vibrance (-1 to 1), and a look: a built-in name (Teal & Orange, Black & White, Film Fade, Cool Blue, Warm Vintage, High Contrast) or the path of a .cube LUT file, blended by look_mix (0 to 1). look \"none\" removes it. input_lut is a conversion LUT (.cube) applied before all other controls at full strength, for log footage; \"none\" removes it. reset=true clears everything first. Use frame_stats to check the result.",
             inputSchema: schema(["clip": str("Clip id prefix"), "exposure": num("-4 to 4 stops"), "contrast": num("0.25 to 3"), "saturation": num("0 to 3"), "temperature": num("-100 to 100"), "tint": num("-100 to 100"),
                                  "shadows": num("-1 to 1"), "midtones": num("-1 to 1"), "highlights": num("-1 to 1"), "vibrance": num("-1 to 1"), "input_lut": str("Path of a .cube conversion LUT applied first at full strength (log footage such as DJI D-Log to Rec.709), or none"), "look": str("Built-in look name, a .cube path, or none"), "look_mix": num("0 to 1 (default 1)"),
                                  "reset": .object(["type": "boolean", "description": "Clear the color correction first"]), "project": projectArg], required: ["clip"])),
        Tool(name: "set_clip_audio", description: "Shape a clip's sound: three-band EQ gains in dB (low shelf 200 Hz, mid peak 1 kHz, high shelf 6 kHz; -18 to 18), a high-pass filter in Hz (0 = off; 80-120 removes rumble and hum), and a noise gate threshold in dBFS (0 = off; e.g. -45 closes the gate by 26 dB between words), and voice_isolation (0 = off, 1 = speech only: strips room noise and background with Apple's on-device voice isolator; rendered once per asset and amount, the preview plays the original until it is ready, the export waits for it). reset=true clears all.",
             inputSchema: schema(["clip": str("Clip id prefix"), "low": num("dB"), "mid": num("dB"), "high": num("dB"), "high_pass": num("Hz, 0 = off"), "gate": num("dBFS threshold, 0 = off"), "voice_isolation": num("0 = off, 1 = speech only; renders once per asset on this Mac"),
                                  "reset": .object(["type": "boolean", "description": "Clear the audio settings first"]), "project": projectArg], required: ["clip"])),
        Tool(name: "set_ducking", description: "Auto-duck a track (music) under another track's clips (voice): its volume drops to level while clips play on the other track, with attack and release ramps. under \"none\" stops ducking.",
             inputSchema: schema(["track": str("Track name or id to duck (e.g. A2)"), "under": str("Track whose clips cause the duck (e.g. A1), or none"), "level": num("Volume while ducked, 0 to 1 (default 0.25)"), "attack": num("Seconds to drop (default 0.15)"), "release": num("Seconds to come back (default 0.4)"), "project": projectArg], required: ["track"])),
        Tool(name: "frame_stats", description: "Measure the composed frame at a time (default: the playhead): mean RGB, luma mean and median, fraction of crushed-black and clipped-white pixels, and a 16-bin luma histogram. The numbers behind the scopes; use them to judge exposure and color before and after a correction.",
             inputSchema: schema(["seconds": num("Timeline time"), "project": projectArg]), annotations: .init(readOnlyHint: true)),
        Tool(name: "set_clip_fades", description: "Fade a clip in from black and silence and/or out to them, in seconds.",
             inputSchema: schema(["clip": str("Clip id prefix"), "fade_in": num("Seconds"), "fade_out": num("Seconds"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_transition", description: "Put a transition on the start of a clip, from the clip that ends where it starts (or from black): crossDissolve, dipToBlack, wipeLeft, wipeRight, or none to remove. It takes the first `duration` seconds of the clip; the outgoing clip needs that much media past its out point.",
             inputSchema: schema(["clip": str("Incoming clip id prefix"), "kind": str("crossDissolve | dipToBlack | wipeLeft | wipeRight | none"), "duration": num("Seconds, default 0.5"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_keyframe", description: "Animate a clip parameter: set its value at a time (keyframe). Two or more keyframes on a parameter interpolate between them (linear, smooth = ease in/out, hold = jump). The first keyframe replaces the plain value. speed keyframes make a speed ramp (0 = freeze frame).",
             inputSchema: schema(["clip": str("Clip id prefix"), "param": str("scale, x, y, rotation, opacity, exposure, contrast, saturation, temperature, tint, volume, speed"), "time": num("Timeline seconds (default: the playhead); clamped to the clip"), "value": num("The value at that time"), "ease": str("linear (default), smooth, hold: how it moves to the next keyframe"), "project": projectArg], required: ["clip", "param", "value"])),
        Tool(name: "remove_keyframe", description: "Remove one keyframe (at time, default the playhead) or, with all=true, every keyframe of the parameter, which freezes it at its current value.",
             inputSchema: schema(["clip": str("Clip id prefix"), "param": str("Parameter name"), "time": num("Timeline seconds"), "all": .object(["type": "boolean", "description": "Remove every keyframe of the parameter"]), "project": projectArg], required: ["clip", "param"])),
        Tool(name: "add_marker", description: "Add a named marker at a timeline time.",
             inputSchema: schema(["at": num("Seconds"), "name": str("Label"), "color": str("Hex color like #3B82F6"), "project": projectArg], required: ["at"])),
        Tool(name: "remove_marker", description: "Remove a marker by id.",
             inputSchema: schema(["marker": str("Marker id prefix"), "project": projectArg], required: ["marker"]), annotations: .init(destructiveHint: true)),
        Tool(name: "nest_clips", description: "Fold clips into one nested sequence (a compound clip): they leave the timeline and one clip playing the whole group takes their place, so you can speed, grade, fade, transition or keyframe the group as a unit. The sequence is rendered before the call returns.",
             inputSchema: schema(["clips": strs("Clip ids or names"), "name": str("Sequence name (default: Sequence N)"), "project": projectArg], required: ["clips"])),
        Tool(name: "unnest_clip", description: "Expand a nested-sequence clip back into its clips on the timeline (the whole sequence from the clip's start; tracks matched by name).",
             inputSchema: schema(["clip": str("Clip id or name that plays a nested sequence"), "project": projectArg], required: ["clip"])),
        Tool(name: "inspect_sequence", description: "The contents of a nested sequence: its tracks and clips (times inside the sequence) and whether its render is cached. Without a name, lists every sequence.",
             inputSchema: schema(["sequence": str("Sequence name or id, or a clip that plays it"), "project": projectArg]), annotations: .init(readOnlyHint: true)),
        Tool(name: "make_multicam", description: "Fold two or more clips (the same moment shot from several cameras) into one multicam clip: the earliest clip stays as angle 1, the others become its angles and leave the timeline. sync audio lines the angles up by their sound; start keeps the timeline placement; none sets offsets to 0. Then cut_angle switches the picture.",
             inputSchema: schema(["clips": strs("Clip ids or names (two or more)"), "sync": str("audio (default), start or none"), "project": projectArg], required: ["clips"])),
        Tool(name: "cut_angle", description: "Switch a multicam clip's picture to an angle from a timeline time on (a cut at the clip start sets the opening angle). remove true deletes the cut at that time instead.",
             inputSchema: schema(["clip": str("Multicam clip id or name"), "at": num("Timeline time in seconds"), "angle": num("Angle number, 1-based"), "remove": .object(["type": "boolean"]), "project": projectArg], required: ["clip", "at"])),
        Tool(name: "set_multicam", description: "Multicam settings: which angle's sound plays (audio_angle), explicit per-angle offsets in seconds, or flatten true to turn the clip back into plain clips (one per cut).",
             inputSchema: schema(["clip": str("Multicam clip id or name"), "audio_angle": num("1-based"), "offsets": .object(["type": "array", "items": .object(["type": "number"]), "description": "Seconds to add to angle 1's time to reach the same moment in each angle (one value per angle, first is 0)"]), "flatten": .object(["type": "boolean"]), "project": projectArg], required: ["clip"])),
        Tool(name: "sync_angles", description: "Recompute a multicam clip's angle offsets from the audio (cross-correlation of loudness envelopes; reports a confidence per angle).",
             inputSchema: schema(["clip": str("Multicam clip id or name"), "project": projectArg], required: ["clip"])),
        Tool(name: "make_proxies", description: "Build low-resolution proxy files (960×540) for the project's video assets and switch the preview to them for smooth playback; the export always uses the originals. Returns each asset's proxy status; call again to poll progress.",
             inputSchema: schema(["project": projectArg])),
        Tool(name: "list_templates", description: "Project templates: built-in formats (YouTube 16:9, Shorts 9:16, Square, 4K, Cinema, 4:5) and templates saved from projects.",
             inputSchema: schema(["project": projectArg]), annotations: .init(readOnlyHint: true)),
        Tool(name: "apply_template", description: "Apply a template (undoable). A built-in (YouTube 16:9, Shorts / Reels 9:16, Square 1:1…) only sets the frame size and fps: clips, titles and markers stay (then auto_reframe each clip for the new aspect); on an empty timeline it starts a fresh project at that size. A saved template replaces the project with its tracks, clips and titles.",
             inputSchema: schema(["name": str("Template name from list_templates"), "project": projectArg], required: ["name"])),
        Tool(name: "save_template", description: "Save the current project (without history) as a named template for later apply_template calls.",
             inputSchema: schema(["name": str("Template name"), "project": projectArg], required: ["name"])),
        Tool(name: "set_project_settings", description: "Change output resolution, frame rate or project name.",
             inputSchema: schema(["width": int("Pixels"), "height": int("Pixels"), "fps": num("Frames per second"), "name": str("Project name"), "project": projectArg, "use_proxies": .object(["type": "boolean", "description": "Preview from proxy files when they exist (see make_proxies)"])])),
        Tool(name: "search_transcript", description: "Find a phrase in the spoken words of a clip, an asset's clips, or every clip with audio (case and punctuation ignored). Each match gives its occurrence number, clip, timeline start/end, 0-based word indices (as in get_transcript for that clip) and a few words of context. Transcribes on first use.",
             inputSchema: schema(["query": str("Words to find, e.g. \"let me start again\""), "clip": str("Clip id prefix (default: all clips with audio)"), "asset": str("Asset id prefix or file name: only that asset's clips"),
                                  "language": str("Language tag for transcription (default: the Mac's language)"), "project": projectArg], required: ["query"]),
             annotations: .init(readOnlyHint: true)),
        Tool(name: "cut_transcript", description: "Cut a span of speech out of the timeline by its words, like deleting text (ripple: every track shifts, captions move). Choose the span by phrase (+ occurrence when it is said more than once; the error lists them), by from_word/to_word (0-based indices into get_transcript's words for one clip), or by start/end (the words whose middle falls in that range, one clip). The cut runs from the first word's start to the last word's end, padded by `padding` but never into the neighbouring words. Returns the removed words and range.",
             inputSchema: schema(["phrase": str("Words to cut, as spoken"), "occurrence": int("Which occurrence of the phrase, 1-based (default 1 when it occurs once)"),
                                  "from_word": int("First word index (0-based) in the clip's transcript"), "to_word": int("Last word index, inclusive (default: from_word)"),
                                  "start": num("Timeline seconds: cut the words inside start…end"), "end": num("Timeline seconds"),
                                  "padding": num("Seconds of silence taken on each side, capped at the neighbouring words (default 0.03)"),
                                  "clip": str("Clip id prefix (default: all clips with audio; required for from_word)"), "asset": str("Asset id prefix or file name: only that asset's clips"),
                                  "language": str("Language tag for transcription (default: the Mac's language)"), "project": projectArg]),
             annotations: .init(destructiveHint: true)),
        Tool(name: "export_chapters", description: "The project's markers as a YouTube chapter list (\"mm:ss Name\" per line, sorted, with a 00:00 Intro added when no marker sits at 0; unnamed markers become Chapter N). Without path it only returns the text, to paste into a video description; with path it is also written to that .txt file, or to <basename>.chapters.txt beside the given .mp4.",
             inputSchema: schema(["path": str("Optional: a .txt file to write, or an exported .mp4 to put <basename>.chapters.txt beside"), "project": projectArg])),
        Tool(name: "export_batch", description: "Render the timeline to several formats in one go: one MP4 per template (built-in or saved), each named <project>-<template slug>.mp4 in the directory, exported one after another with the template's width, height and fps; for a template with another aspect every video clip is auto-reframed to follow its subject (reframe false keeps letter-/pillarboxing). The project itself is not changed. Blocks until every file is done; expect roughly real time per template.",
             inputSchema: schema(["directory": str("Absolute directory to write into (created if missing)"), "templates": strs("Template names from list_templates (default: every built-in)"), "preset": str("high (default, H.264), medium, low or hevc10"),
                                  "chapters": .object(["type": "boolean", "description": "Also write the markers as <project>.chapters.txt in the directory (default false)"]),
                                  "reframe": .object(["type": "boolean", "description": "Auto-reframe every video clip for templates with another aspect than the project (default true); false letter- or pillarboxes instead"]), "project": projectArg], required: ["directory"])),
        Tool(name: "auto_reframe", description: "Make a clip follow its subject when the project frame has a different aspect than the source (16:9 footage in a 9:16 or 1:1 project): scales the picture to cover the frame and keyframes its position (smooth ease) so the subject stays in view, replacing any x/y animation. Finds the subject with Vision (largest person, else the salient object, else the frame centre). When the user asks for a vertical / Shorts / Reels version, set the frame FIRST: apply_template \"Shorts / Reels 9:16\" on an empty project before inserting clips (a built-in template empties the timeline), or set_project_settings width 1080 height 1920 when clips are already placed; then call this per clip. One undoable edit; inspect_timeline shows the keyframes.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "mode": str("auto (default: person, else saliency), person, saliency"), "sample_interval": num("Seconds of timeline between analysed frames (default 0.33; smaller = finer, slower)"),
                                  "strength": num("0-1: how much of the subject's displacement from the centre the pan follows (default 1 = keep it centred)"), "project": projectArg], required: ["clip"])),
        Tool(name: "stabilize_clip", description: "Smooth camera shake on a video clip: analyses its motion frame by frame (on-device image registration, a few seconds per minute of footage), smooths the camera path over `strength` seconds and counter-shifts the picture every frame, zooming in slightly (up to 1.25×) to hide the borders. Keyed to source time, so later trims and speed changes keep working; call again to re-analyse. Returns samples, zoom, crop percentage and the largest shift; remove true clears it.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "strength": num("Smoothing window in seconds (default 0.6; larger = steadier but more zoom, 0.1-3)"),
                                  "remove": .object(["type": "boolean", "description": "Remove the stabilization instead"]), "project": projectArg], required: ["clip"])),
    ]

    static func register(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let payload = try await call(params.name, params.arguments ?? [:])
                var content: [Tool.Content] = [.text(payload.text)]
                if let img = payload.image { content.append(.image(data: img.base64EncodedString(), mimeType: "image/png")) }
                // structuredContent must be a JSON object; list results are wrapped so strict clients (Claude Code) accept them.
                var structured = payload.value
                if case .array(let items)? = structured { structured = .object(["items": .array(items)]) }
                return .init(content: content, structuredContent: structured, isError: false)
            } catch {
                return .init(content: [.text("Error: \(error.localizedDescription)")], isError: true)
            }
        }
        await server.withMethodHandler(ListResources.self) { _ in
            let docs = await MainActor.run { DocumentRegistry.shared.documents.map { ($0.id.short, $0.displayName) } }
            return .init(resources: docs.map { Resource(name: "Timeline: \($0.1)", uri: "editmax://project/\($0.0)/timeline", description: "Live timeline JSON for project \($0.1)", mimeType: "application/json") }, nextCursor: nil)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            let parts = params.uri.replacingOccurrences(of: "editmax://project/", with: "").split(separator: "/")
            guard parts.count == 2, parts[1] == "timeline" else { throw MCPError.invalidParams("Unknown resource \(params.uri)") }
            let text = try await MainActor.run { () -> String in
                guard let doc = DocumentRegistry.shared.document(for: String(parts[0])) else { throw MCPError.invalidParams("No project \(parts[0])") }
                return try encodeText(ToolExecutor(document: doc, origin: .agent).inspectTimeline())
            }
            return .init(contents: [.text(text, uri: params.uri, mimeType: "application/json")])
        }
    }

    struct Payload { var text: String; var value: Value?; var image: Data? = nil }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
    private static func encodeText<T: Encodable>(_ v: T) throws -> String { String(decoding: try encoder.encode(v), as: UTF8.self) }
    private static func payload<T: Codable>(_ v: T) throws -> Payload { Payload(text: try encodeText(v), value: try? Value(v)) }
    private static func message(_ s: String) -> Payload { Payload(text: s, value: .object(["message": .string(s)])) }

    @MainActor
    static func call(_ name: String, _ a: [String: Value]) async throws -> Payload {
        let s = { (k: String) -> String? in a[k]?.stringValue }
        let d = { (k: String) -> Double? in a[k]?.doubleValue ?? a[k]?.intValue.map(Double.init) }
        let i = { (k: String) -> Int? in a[k]?.intValue ?? a[k]?.doubleValue.map { Int($0) } }
        let list = { (k: String) -> [String] in a[k]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        let b = { (k: String) -> Bool in a[k]?.boolValue ?? false }
        func req(_ k: String) throws -> String { guard let v = s(k), !v.isEmpty else { throw MCPError.invalidParams("'\(k)' is required") }; return v }
        func reqNum(_ k: String) throws -> Double { guard let v = d(k) else { throw MCPError.invalidParams("'\(k)' is required") }; return v }

        if name == "list_projects" {
            struct P: Codable { var id: String, name: String, active: Bool, duration: Double, clips: Int }
            let reg = DocumentRegistry.shared
            return try payload(reg.documents.map { P(id: $0.id.short, name: $0.displayName, active: $0.id == reg.activeID, duration: $0.project.duration, clips: $0.project.allClips.count) })
        }
        guard let doc = DocumentRegistry.shared.document(for: s("project")) else {
            throw MCPError.invalidParams(s("project") == nil ? "No project is open. Ask the user to open or create one in EditMax." : "No project matches '\(s("project")!)'")
        }
        let x = ToolExecutor(document: doc, origin: .agent)
        switch name {
        case "inspect_timeline": return try payload(x.inspectTimeline())
        case "list_assets": return try payload(x.listAssets())
        case "import_media":
            let paths = list("paths"); guard !paths.isEmpty else { throw MCPError.invalidParams("'paths' must list at least one file") }
            return try payload(try await x.importMedia(paths: paths))
        case "insert_clip":
            let c = try x.insertClip(asset: try req("asset"), track: s("track"), at: d("at"), sourceIn: d("source_in") ?? 0, duration: d("duration"))
            return message("Inserted clip \(c.id.short) '\(c.name)' at \(c.start)s for \(c.duration)s")
        case "split_clip":
            let (l, r) = try x.splitClip(try req("clip"), at: try reqNum("at"))
            return message("Split into \(l.id.short) (\(l.start)-\(l.end)s) and \(r.id.short) (\(r.start)-\(r.end)s)")
        case "move_clip":
            try x.moveClip(try req("clip"), to: try reqNum("start"), track: s("track")); return message("Moved")
        case "trim_clip":
            try x.trimClip(try req("clip"), start: d("start"), end: d("end")); return message("Trimmed")
        case "remove_clips":
            return message("Removed \(try x.removeClips(list("clips"))) clip(s)")
        case "set_clip_properties":
            try x.setClipProperties(try req("clip"), speed: d("speed"), volume: d("volume"), opacity: d("opacity"), name: s("name")); return message("Updated")
        case "close_gaps":
            try x.rippleTrack(try req("track")); return message("Gaps closed")
        case "add_text":
            let t = try x.addText(try req("text"), start: try reqNum("start"), duration: try reqNum("duration"), fontSize: d("font_size"), colorHex: s("color"), x: d("x"), y: d("y"), preset: s("preset"))
            return message("Added text \(t.id.short) from \(t.start)s to \(t.end)s")
        case "get_transcript":
            return try payload(try await x.getTranscript(asset: s("asset"), clip: s("clip"), language: s("language")))
        case "add_captions":
            return try payload(try await x.addCaptions(clip: s("clip"), preset: s("preset"), maxWords: i("max_words"), language: s("language")))
        case "detect_silence":
            return try payload(try await x.detectSilence(clip: s("clip"), thresholdDb: d("threshold_db") ?? -38, minDuration: d("min_duration") ?? 0.6, padding: d("padding") ?? 0.15))
        case "remove_silence":
            return try payload(try await x.removeSilence(clip: s("clip"), thresholdDb: d("threshold_db") ?? -38, minDuration: d("min_duration") ?? 0.6, padding: d("padding") ?? 0.15))
        case "remove_words":
            return try payload(try await x.removeWords(clip: s("clip"), words: list("words").isEmpty ? nil : list("words"), language: s("language")))
        case "ripple_delete":
            return try payload(try x.rippleDelete(start: try reqNum("start"), end: try reqNum("end")))
        case "remove_captions":
            return message("Removed \(try x.removeCaptions(group: s("group"))) caption(s)")
        case "remove_texts":
            return message("Removed \(try x.removeTexts(list("ids"))) text overlay(s)")
        case "list_history": return try payload(x.listHistory(limit: i("limit") ?? 50))
        case "restore_snapshot":
            try x.restore(try req("snapshot")); return message("Restored")
        case "set_playhead":
            x.setPlayhead(try reqNum("seconds"), play: a["play"]?.boolValue ?? false); return message("Playhead at \(d("seconds")!)s")
        case "capture_frame":
            let png = try await x.captureFrame(at: try reqNum("seconds"), maxWidth: i("max_width") ?? 960)
            return Payload(text: "Frame at \(d("seconds")!)s (\(png.count) bytes PNG)", value: nil, image: png)
        case "export_video":
            let want = (s("preset") ?? "high").lowercased().filter { $0.isLetter || $0.isNumber }   // "hevc10", "hevc", "high", "med"…
            let preset = ExportService.Preset.allCases.first { $0.rawValue.lowercased().filter { $0.isLetter || $0.isNumber }.hasPrefix(want) } ?? .high
            return try payload(try await x.exportVideo(to: try req("path"), preset: preset, chapters: b("chapters")))
        case "ui_layout":
            return try payload(try UIDriver.layout(prefix: s("prefix")))
        case "ui_drag":
            let from = try UIDriver.resolve(a["from"], dx: d("from_dx") ?? 0, dy: d("from_dy") ?? 0)
            let to = try UIDriver.resolve(a["to"], dx: d("to_dx") ?? 0, dy: d("to_dy") ?? 0)
            UIDriver.modifiers = UIDriver.flags(list("modifiers")); defer { UIDriver.modifiers = [] }
            let how = try await UIDriver.drag(from: from, fromID: s("from"), to: to, steps: i("steps") ?? 12, holdMs: i("hold_ms") ?? 80)
            let path = "from (\(Int(from.x)), \(Int(from.y))) to (\(Int(to.x)), \(Int(to.y)))"
            switch how {
            case .events(let n): return message("Dragged \(path) with \(n) mouse events")
            case .handler(let id): return message("Dragged \(path) by calling \(id)'s own move/trim code: macOS would not make EditMax the active app, which SwiftUI gestures need. Media drops, header reorders and clicks always use real events.")
            }
        case "ui_click":
            let p = try UIDriver.resolve(a["target"], dx: d("dx") ?? 0, dy: d("dy") ?? 0)
            UIDriver.modifiers = UIDriver.flags(list("modifiers")); defer { UIDriver.modifiers = [] }
            switch try await UIDriver.click(at: p, id: s("target"), count: i("count") ?? 1) {
            case .events: return message("Clicked (\(Int(p.x)), \(Int(p.y)))")
            case .handler(let id): return message("Clicked \(id) by calling its own tap code: macOS would not make EditMax the active app, which SwiftUI gestures need.")
            }
        case "ui_key":
            let how = try await UIDriver.key(try req("key"), modifiers: list("modifiers"))
            return message("Pressed \(try req("key"))" + (how == "events" ? "" : " (through the editor's key \(how): EditMax is not the active app)"))
        case "ui_scroll":
            let p = try UIDriver.resolve(a["target"], dx: 0, dy: 0)
            let r = try await UIDriver.scroll(at: p, dx: d("dx") ?? 0, dy: d("dy") ?? 0)
            return message("Scrolled to (\(Int(r.x)), \(Int(r.y))) of (\(Int(r.maxX)), \(Int(r.maxY)))")
        case "ui_screenshot":
            let shot = try await UIDriver.screenshot(maxWidth: i("max_width") ?? 1400)
            return Payload(text: "Window (\(shot.png.count) bytes PNG, \(shot.method))", value: nil, image: shot.png)
        case "add_track":
            return try payload(try x.addTrack(kind: try req("kind"), name: s("name")))
        case "move_track":
            return try payload(try x.moveTrack(try req("track"), toRow: Int(try reqNum("row"))))
        case "set_project_settings":
            try x.setProjectSettings(width: i("width"), height: i("height"), fps: d("fps"), name: s("name"), useProxies: a["use_proxies"]?.boolValue); return message("Settings updated")
        case "set_clip_transform":
            try x.setClipTransform(try req("clip"), scale: d("scale"), x: d("x"), y: d("y"), rotation: d("rotation"), cropLeft: d("crop_left"), cropRight: d("crop_right"), cropTop: d("crop_top"), cropBottom: d("crop_bottom"), reset: b("reset")); return message("Transform updated")
        case "set_clip_color":
            try x.setClipColor(try req("clip"), exposure: d("exposure"), contrast: d("contrast"), saturation: d("saturation"), temperature: d("temperature"), tint: d("tint"), reset: b("reset"),
                               shadows: d("shadows"), midtones: d("midtones"), highlights: d("highlights"), vibrance: d("vibrance"), lut: s("look"), lutMix: d("look_mix"), inputLut: s("input_lut")); return message("Color updated")
        case "set_clip_audio":
            try x.setClipAudio(try req("clip"), low: d("low"), mid: d("mid"), high: d("high"), highPass: d("high_pass"), gate: d("gate"), voiceIsolation: d("voice_isolation"), reset: b("reset")); return message("Audio updated")
        case "set_ducking":
            return try payload(try x.setDucking(try req("track"), under: s("under"), level: d("level"), attack: d("attack"), release: d("release")))
        case "nest_clips":
            return try payload(try await x.nestClips(list("clips"), name: s("name")))
        case "unnest_clip":
            return message("Unnested \(try x.unnestClip(try req("clip"))) clip(s) onto the timeline")
        case "inspect_sequence":
            if let name = s("sequence"), !name.isEmpty { return try payload(x.sequenceInfo(try x.resolveSequence(name))) }
            return try payload(x.listSequences())
        case "make_multicam":
            return try payload(try await x.makeMulticam(list("clips"), sync: s("sync") ?? "audio"))
        case "cut_angle":
            guard let at = d("at") else { throw MCPError.invalidParams("'at' is required") }
            if b("remove") { return try payload(try x.cutAngle(try req("clip"), at: at, angle: 0, remove: true)) }
            guard let angle = i("angle") else { throw MCPError.invalidParams("'angle' is required unless remove is true") }
            return try payload(try x.cutAngle(try req("clip"), at: at, angle: angle))
        case "set_multicam":
            let offsets = a["offsets"]?.arrayValue?.compactMap { $0.doubleValue ?? $0.intValue.map(Double.init) }
            return try payload(try x.setMulticam(try req("clip"), audioAngle: i("audio_angle"), offsets: offsets, flatten: b("flatten")))
        case "sync_angles":
            return try payload(try await x.syncAngles(try req("clip")))
        case "make_proxies":
            return try payload(await x.makeProxies(enable: true))
        case "list_templates":
            return try payload(x.listTemplates())
        case "apply_template":
            return try payload(try x.applyTemplate(try req("name")))
        case "save_template":
            return message("Saved template to \(try x.saveTemplate(try req("name")))")
        case "frame_stats":
            return try payload(try await x.frameStats(at: d("seconds") ?? UIRegistry.shared.playheads[x.document.id]?() ?? 0))
        case "set_clip_fades":
            try x.setClipFades(try req("clip"), fadeIn: d("fade_in"), fadeOut: d("fade_out")); return message("Fades updated")
        case "set_keyframe":
            return try payload(try x.setKeyframe(try req("clip"), param: try req("param"), time: d("time"), value: try reqNum("value"), ease: s("ease")))
        case "remove_keyframe":
            let n = try x.removeKeyframe(try req("clip"), param: try req("param"), time: d("time"), all: b("all")); return message("Removed \(n) keyframe\(n == 1 ? "" : "s")")
        case "set_transition":
            return try payload(try x.setTransition(try req("clip"), kind: s("kind"), duration: d("duration")))
        case "add_marker":
            return try payload(x.addMarker(at: try reqNum("at"), name: s("name"), colorHex: s("color")))
        case "remove_marker":
            try x.removeMarker(try req("marker")); return message("Marker removed")
        case "search_transcript":
            return try payload(try await x.searchTranscript(clip: s("clip"), asset: s("asset"), query: try req("query"), language: s("language")))
        case "cut_transcript":
            return try payload(try await x.cutTranscript(clip: s("clip"), asset: s("asset"), phrase: s("phrase"), occurrence: i("occurrence"), fromWord: i("from_word"), toWord: i("to_word"),
                                                         startTime: d("start"), endTime: d("end"), padding: d("padding") ?? 0.03, language: s("language")))
        case "export_chapters":
            return try payload(try x.exportChapters(path: s("path")))
        case "export_batch":
            return try payload(try await x.exportBatch(directory: try req("directory"), templates: list("templates"), preset: ExportService.Preset.parse(s("preset")), chapters: b("chapters"), reframe: a["reframe"]?.boolValue ?? true))
        case "auto_reframe":
            return try payload(try await x.autoReframe(try req("clip"), mode: s("mode"), sampleInterval: d("sample_interval"), strength: d("strength")))
        case "stabilize_clip":
            return try payload(try await x.stabilizeClip(try req("clip"), strength: d("strength"), remove: b("remove")))
        default: throw MCPError.methodNotFound("Unknown tool \(name)")
        }
    }
}
