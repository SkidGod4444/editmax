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
        Tool(name: "list_assets", description: "Media files imported into the project, with ids, kind, duration and dimensions; missing true marks a file that is not at its path any more (relink_media finds it).",
             inputSchema: schema(["project": projectArg]), annotations: .init(readOnlyHint: true)),
        Tool(name: "import_media", description: "Import video, audio or image files from absolute paths on this Mac into the project's asset list. Files are referenced, not copied.",
             inputSchema: schema(["paths": strs("Absolute file paths (~ is expanded)"), "project": projectArg], required: ["paths"])),
        Tool(name: "list_library", description: "The user's Assets library: every file brought into EditMax across all projects (imports, files dropped on the notch drawer or the Assets section, added downloads, fonts), newest first. Each item has id, name, path, kind (video, audio, image, font), duration (seconds, none for images and fonts), used_in (names of the projects that use it) and missing true when the file is not at its path. Works with no project open; pass a path to import_media to use an item in a project.",
             inputSchema: schema(["kind": str("video, audio, image or font (default: all)"), "search": str("Only names containing this, any case"), "limit": int("Max items (default 100)")]),
             annotations: .init(readOnlyHint: true)),
        Tool(name: "add_to_library", description: "Add files on this Mac to the user's Assets library without putting them in a project. By default the files are referenced where they are; copy true copies them into EditMax's Assets folder first (for files in Downloads or other places that get cleaned). A file already in the library is returned, not added twice. Returns the items and any files that were skipped and why.",
             inputSchema: schema(["paths": strs("Absolute file paths (~ is expanded)"), "copy": .object(["type": "boolean", "description": "Copy into EditMax's Assets folder (default false)"])], required: ["paths"])),
        Tool(name: "insert_clip", description: "Place an asset on the timeline as a new clip. By default it is appended after the last clip on V1 (the bottom video track) or A1 (the top audio track).",
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
        Tool(name: "set_clip_properties", description: "Change a clip's speed (1 = normal, kept to hundredths: 0.01×), volume (0-2), opacity (0-1) or display name.",
             inputSchema: schema(["clip": str("Clip id prefix"), "speed": num("Playback speed multiplier"), "volume": num("0 to 2"), "opacity": num("0 to 1"), "name": str("Display name"), "project": projectArg], required: ["clip"])),
        Tool(name: "close_gaps", description: "Ripple a track so its clips play back to back with no gaps.",
             inputSchema: schema(["track": str("Track id or name"), "project": projectArg], required: ["track"])),
        Tool(name: "add_text", description: "Add a text overlay (title, lower third, one caption) for a time range.",
             inputSchema: schema(["text": str("The text to show"), "start": num("Start in seconds"), "duration": num("Seconds on screen"),
                                  "preset": str("Look: title (default), subtitle, boxed, bold, outline, minimal"),
                                  "font": str("Font family (any case) or PostScript name, from list_fonts; a Google font not on this Mac is downloaded first. Default: the preset's font"),
                                  "font_size": num("Points at project resolution (default from the preset)"), "color": str("Hex color like #FFFFFF"),
                                  "x": num("Horizontal center 0-1 (default 0.5)"), "y": num("Vertical center 0-1, 0 = top (default from the preset)"), "project": projectArg], required: ["text", "start", "duration"])),
        Tool(name: "get_transcript", description: "Speech in an asset or clip as timed words (on-device recognition, cached per asset; the first call on a long file takes a while). Clip times are timeline seconds, asset times are source seconds. Long speech comes in pages that each fit one reply (about 80 000 characters: some 1600 words, 10 to 12 minutes of talk): the result gives totalWords, firstWord (the index of its first word, as cut_transcript's from_word counts) and nextWord to pass as first_word for the next page; ask until nextWord is absent to read it all. from/to pick a stretch of time; search_transcript finds a phrase anywhere.",
             inputSchema: schema(["clip": str("Clip id prefix (timeline times)"), "asset": str("Asset id prefix or file name (source times)"),
                                  "language": str("Language tag such as en, en-IN, hi (default: the Mac's language)"),
                                  "from": num("Seconds: start at the first word starting here"), "to": num("Seconds: stop before the first word starting here"),
                                  "first_word": int("0-based index of the first word (nextWord of the previous page)"),
                                  "max_words": int("At most this many words in the page, 1 to 10000 (a page also ends at about 80000 characters)"), "project": projectArg])),
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
        Tool(name: "ripple_delete", description: "Remove a time range from every track and close the gap. A clip spanning the range is cut as two splits would cut it (no fade at the new cut); a clip losing only its head or tail keeps the fade on its other edge. Texts and markers inside it go (a marker lands on the cut), later ones shift; a text spanning the range keeps its parts on both sides.",
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
        Tool(name: "export_video", description: "Render the whole timeline at the project resolution with everything EditMax does baked in (grades, looks, titles, captions, the mixed and processed sound). Presets: high (default), an H.264/AAC 8-bit MP4 (HEVC above 3840×2160, which H.264 would shrink); medium (720p) and low (480p); hevc10, a 10-bit HEVC Main 10 MP4 master (4:2:0, Rec.709 tags, about 0.25 bits per pixel); prores422hq (a bare \"prores\" picks it), prores422 or prores4444, an Apple ProRes QuickTime .mov with 24-bit PCM sound, the master DaVinci Resolve, Final Cut and Premiere edit and grade natively (large: 422 HQ at 1080p30 runs up to about 220 Mb/s, 1.6 GB a minute). The file extension is set to match the preset. To hand over the edit itself rather than a rendered file, use export_timeline. Blocks until done; expect roughly real time or faster.",
             inputSchema: schema(["path": str("Absolute output path (.mp4, or .mov for ProRes; the extension is set to match the preset)"), "preset": str("high (default, H.264; HEVC above 4K), medium (720p), low (480p), hevc10 (10-bit HEVC), prores422hq, prores422 or prores4444 (ProRes .mov); all masters at the project resolution"), "chapters": .object(["type": "boolean", "description": "Also write the markers as a YouTube chapter list to <basename>.chapters.txt beside the file (default false)"]), "project": projectArg], required: ["path"])),
        Tool(name: "add_track", description: "Add a video or audio track. A new video track goes on top of the video tracks (V2 above V1), so its picture covers theirs, as in other editors; a new audio track goes below the audio tracks. The top row covers the rows below it in the picture; move_track changes the order.",
             inputSchema: schema(["kind": str("video or audio"), "name": str("Optional name (default V2, A2…)"), "project": projectArg], required: ["kind"])),
        Tool(name: "rename_track", description: "Rename a track (the name shown in its timeline header and the mixer). Names are unique, at most 32 characters, and \"Text\" is reserved for the titles row.",
             inputSchema: schema(["track": str("Track name or id prefix"), "name": str("The new name"), "project": projectArg], required: ["track", "name"])),
        Tool(name: "move_track", description: "Move a track to another row (0 = top). The top row covers the rows below it in the picture.",
             inputSchema: schema(["track": str("Track name or id prefix"), "row": int("Target row, 0 = top"), "project": projectArg], required: ["track", "row"])),
        Tool(name: "ui_layout", description: "Where things are in the EditMax window, in window points (origin top-left): media rows (media.<file>), track headers (header.<name>, header.Text, header.<name>.mute/.hide), lanes (lane.<name>, lane.Text), clip and text bars (clip.<id>, text.<id>, with .left/.right trim handles), toolbar buttons, addtrack.video/audio, ruler, inspector buttons. Only what a user can see now is listed, with the visible part of each element (clipped by its scroll view and the window); elements in a popover or sheet over the window carry \"window\": \"popover\" or \"sheet\" and are given in the same window points. \"hidden\" lists ids that exist but cannot be seen now (scrolled out of view, outside the window or hidden); ui_scroll {target: id} brings one into view. Use the ids with ui_click, ui_select and ui_drag to drive the real UI.",
             inputSchema: schema(["prefix": str("Only ids starting with this (e.g. 'clip.')")]), annotations: .init(readOnlyHint: true)),
        Tool(name: "ui_drag", description: "Drag with the mouse inside the EditMax window, from one element (or point) to another: move or trim a bar, drop a media row onto a lane, reorder track headers, scrub the ruler. Events are posted to EditMax's own window only. Check the result with inspect_timeline or ui_screenshot.",
             inputSchema: schema(["from": .object(["description": .string("Element id from ui_layout, or {x, y} in window points")]), "to": .object(["description": .string("Element id or {x, y}")]),
                                  "from_dx": num("Offset from the source centre, points (e.g. -40 to grab near a clip's left part)"), "from_dy": num("Offset, points"), "to_dx": num("Offset from the target centre"), "to_dy": num("Offset"),
                                  "steps": int("Intermediate mouse moves (default 12)"), "modifiers": strs("shift, command, option, control (option = no snapping)"), "hold_ms": int("Pause after mouse-down before moving (default 80)")], required: ["from", "to"])),
        Tool(name: "ui_key", description: "Press a key in the EditMax window, as the user would: space (play/pause), j/k/l (shuttle), left/right (frame step, shift = 10), home/end, i/o/x (in, out, clear), m (marker), s (split), delete, or with modifiers such as [\"command\"] for ⌘T (transition), ⌘= / ⌘- (zoom), ⌘Z. While a text field has the focus (after a ui_click on a search or name field), keys without ⌘ are typed into the field, one character per call, and never act on the timeline. A key without ⌘, ⌃ or ⌥ never runs a menu command. The answer says where the key went.",
             inputSchema: schema(["key": str("One character, or space, left, right, up, down, home, end, delete, forwarddelete, return, escape, tab"), "modifiers": strs("shift, command, option, control")], required: ["key"])),
        Tool(name: "ui_click", description: "Click an element (or point) in the EditMax window or a popover or sheet over it: buttons, a bar to select it, a header toggle, a text field to type into. count 2 = double-click (e.g. a media row appends it). modifiers [\"shift\"] adds a bar to the selection. Fails, saying why, when the click could not land: an element scrolled out of view (ui_scroll it into view first) or a point outside the window. A pop-up menu or menu button is not clicked while EditMax is in the background (an open menu would bring it to the front): use ui_select.",
             inputSchema: schema(["target": .object(["description": .string("Element id from ui_layout, or {x, y}")]), "dx": num("Offset, points"), "dy": num("Offset, points"), "count": int("Clicks (default 1)"), "modifiers": strs("shift, command, option, control")], required: ["target"])),
        Tool(name: "ui_select", description: "Choose a value in a pop-up menu (a picker such as inspector.template), a menu button or a segmented control, as a user picking it would, without opening the menu or bringing EditMax to the front. option is the item's title as shown (any case; a unique start of it is enough; submenu items as \"Parent › Item\"). Leave option out to get the list of options.",
             inputSchema: schema(["target": .object(["description": .string("Element id from ui_layout, or {x, y}")]), "option": str("Title of the item to choose; omit to list the options")], required: ["target"])),
        Tool(name: "ui_scroll", description: "Scroll the scrollable area that holds an element, or the one under a point (the inspector, the media list, the timeline), by dy points; positive = down. Returns the new offset and how far it can go. With an element id and no dx/dy, scrolls that element into view (works for ids ui_layout lists as hidden).",
             inputSchema: schema(["target": .object(["description": .string("Element id from ui_layout, or {x, y}")]), "dy": num("Points to scroll (positive = down)"), "dx": num("Points to scroll right")], required: ["target"])),
        Tool(name: "ui_screenshot", description: "The EditMax window as it looks now, with a popover or sheet that is open over it, as a PNG image. Only EditMax's own windows are ever in the picture. An open menu is not shown; on another Space a popover is left out. The answer says how the picture was made and, if it is not true pixels, why.",
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
        Tool(name: "frame_stats", description: "Measure the composed frame at a time (default: the playhead): mean RGB, luma mean and median, fraction of crushed-black and clipped-white pixels, a 16-bin luma histogram, the RGB parade per channel (black level, median, white level, mean) and a vectorscope summary (mean saturation, colour cast hue and strength, dominant hue, share of colour per 30° sector). The numbers behind the scopes; use them to judge exposure and color before and after a correction.",
             inputSchema: schema(["seconds": num("Timeline time"), "project": projectArg]), annotations: .init(readOnlyHint: true)),
        Tool(name: "set_clip_fades", description: "Fade a clip in from black and silence and/or out to them, in seconds.",
             inputSchema: schema(["clip": str("Clip id prefix"), "fade_in": num("Seconds"), "fade_out": num("Seconds"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_transition", description: "Put a transition on the start of a clip, from the clip that ends where it starts (or from black): \(Transition.Kind.allCases.map(\.rawValue).joined(separator: ", ")), or none to remove. Leave kind out to keep the transition already there (its kind and duration); a cross dissolve goes in only where there is none. push* move both pictures, slide* bring the new one in over the old, wipe* reveal it behind an edge, iris opens a circle from the centre. It takes the first `duration` seconds of the clip; the outgoing clip needs that much media past its out point.",
             inputSchema: schema(["clip": str("Incoming clip id prefix"), "kind": str(Transition.Kind.allCases.map(\.rawValue).joined(separator: " | ") + " | none"), "duration": num("Seconds, default 0.5"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_keyframe", description: "Animate a clip parameter: set its value at a time (keyframe). Two or more keyframes on a parameter interpolate between them (linear, smooth = ease in/out, hold = jump). The first keyframe replaces the plain value. speed keyframes make a speed ramp (0 = freeze frame).",
             inputSchema: schema(["clip": str("Clip id prefix"), "param": str("scale, x, y, rotation, opacity, exposure, contrast, saturation, temperature, tint, volume, speed"), "time": num("Timeline seconds (default: the playhead); clamped to the clip"), "value": num("The value at that time"), "ease": str("linear (default), smooth, hold: how it moves to the next keyframe"), "project": projectArg], required: ["clip", "param", "value"])),
        Tool(name: "remove_keyframe", description: "Remove one keyframe (at time, default the playhead) or, with all=true, every keyframe of the parameter, which freezes it at its current value.",
             inputSchema: schema(["clip": str("Clip id prefix"), "param": str("Parameter name"), "time": num("Timeline seconds"), "all": .object(["type": "boolean", "description": "Remove every keyframe of the parameter"]), "project": projectArg], required: ["clip", "param"])),
        Tool(name: "add_marker", description: "Add a named marker at a timeline time.",
             inputSchema: schema(["at": num("Seconds"), "name": str("Label"), "color": str("Hex color like #3B82F6"), "project": projectArg], required: ["at"])),
        Tool(name: "remove_marker", description: "Remove a marker by id.",
             inputSchema: schema(["marker": str("Marker id prefix"), "project": projectArg], required: ["marker"]), annotations: .init(destructiveHint: true)),
        Tool(name: "nest_clips", description: "Fold clips into one nested sequence (a compound clip): they leave the timeline and one clip playing the whole group takes their place (nothing else moves; if a clip that is not nested sits between them on that track, the group goes on a new track just under it), so you can speed, grade, fade, transition or keyframe the group as a unit. The sequence is rendered before the call returns.",
             inputSchema: schema(["clips": strs("Clip ids or names"), "name": str("Sequence name (default: Sequence N)"), "project": projectArg], required: ["clips"])),
        Tool(name: "unnest_clip", description: "Expand a nested-sequence clip back into its clips on the timeline (the whole sequence from the clip's start; tracks matched by name; the clips keep their ids).",
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
        Tool(name: "list_archive", description: "Files deleted in EditMax that can still be restored: EditMax's copies of Assets items, projects deleted from Home, fonts, templates. Each has an id, kind, name, where it was, when it was deleted and the days left before it is erased for good (Settings ▸ Files sets the period).",
             inputSchema: schema([:]), annotations: .init(readOnlyHint: true)),
        Tool(name: "restore_from_archive", description: "Put a deleted file back where it was (\"name 2\" beside it if the name was taken since) and back where it is used: an Assets item in Assets, a project on Home, a font in the Font picker. Then import_media or open it as usual.",
             inputSchema: schema(["item": str("Archive id (prefix) from list_archive, or the item's name")], required: ["item"])),
        Tool(name: "list_templates", description: "Project templates: built-in formats (YouTube 16:9, Shorts 9:16, Square, 4K, Cinema, 4:5) and templates saved from projects.",
             inputSchema: schema(["project": projectArg]), annotations: .init(readOnlyHint: true)),
        Tool(name: "apply_template", description: "Apply a template (undoable). A built-in (YouTube 16:9, Shorts / Reels 9:16, Square 1:1…) only sets the frame size and fps: clips, titles and markers stay (then auto_reframe each clip for the new aspect); on an empty timeline it starts a fresh project at that size. A saved template replaces the project with its tracks, clips and titles.",
             inputSchema: schema(["name": str("Template name from list_templates"), "project": projectArg], required: ["name"])),
        Tool(name: "save_template", description: "Save the current project (without history) as a named template for later apply_template calls.",
             inputSchema: schema(["name": str("Template name"), "project": projectArg], required: ["name"])),
        Tool(name: "set_project_settings", description: "Change output resolution, frame rate or project name. Clips keep their times in seconds when the frame rate changes; frame steps and timecodes follow the new rate.",
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
        Tool(name: "export_batch", description: "Render the timeline to several formats in one go: one file per template (built-in or saved), each named <project>-<template slug>.mp4 (.mov for a ProRes preset) in the directory, exported one after another with the template's width, height and fps; for a template with another aspect every video clip is auto-reframed to follow its subject (reframe false keeps letter-/pillarboxing). The project itself is not changed. Blocks until every file is done; expect roughly real time per template.",
             inputSchema: schema(["directory": str("Absolute directory to write into (created if missing)"), "templates": strs("Template names from list_templates (default: every built-in)"), "preset": str("high (default, H.264), medium, low, hevc10, prores422hq, prores422 or prores4444"),
                                  "chapters": .object(["type": "boolean", "description": "Also write the markers as <project>.chapters.txt in the directory (default false)"]),
                                  "reframe": .object(["type": "boolean", "description": "Auto-reframe every video clip for templates with another aspect than the project (default true); false letter- or pillarboxes instead"]), "project": projectArg], required: ["directory"])),
        Tool(name: "export_timeline", description: "Write the edit itself for another editor, as a file that points at the original media (nothing is rendered; the project is not changed). format fcpxml (default): FCPXML 1.10 for DaVinci Resolve and Final Cut Pro with every track: clip order, trims and gaps, cross dissolves, constant speed and speed ramps, volume and fades, scale, position, rotation and opacity, markers, titles as plain text, and the captions as an .srt beside it. format edl: a CMX 3600 EDL of the bottom video track's picture only, for a conform in Resolve, Premiere or Avid. Neither carries EditMax's processing: color grades, looks and LUTs, title and caption styles, EQ, high-pass, gate and voice isolation, ducking, stabilization, crops and other keyframes stay behind. The result lists, for this project, what went over (transferred) and what did not (notTransferred): tell the user both, and never promise more. To keep the grade and sound baked in, render a ProRes master with export_video instead (or send both).",
             inputSchema: schema(["path": str("Absolute output path; the extension is set to .fcpxml or .edl"), "format": str("fcpxml (default; Resolve, Final Cut Pro) or edl (CMX 3600, bottom video track only)"), "project": projectArg], required: ["path"])),
        Tool(name: "auto_reframe", description: "Make a clip follow its subject when the project frame has a different aspect than the source (16:9 footage in a 9:16 or 1:1 project): scales the picture to cover the frame and keyframes its position (smooth ease) so the subject stays in view, replacing any x/y animation. Finds the subject with Vision (largest person, else the salient object, else the frame centre). When the user asks for a vertical / Shorts / Reels version, set the frame FIRST: apply_template \"Shorts / Reels 9:16\" on an empty project before inserting clips (a built-in template empties the timeline), or set_project_settings width 1080 height 1920 when clips are already placed; then call this per clip. One undoable edit; inspect_timeline shows the keyframes.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "mode": str("auto (default: person, else saliency), person, saliency"), "sample_interval": num("Seconds of timeline between analysed frames (default 0.33; smaller = finer, slower)"),
                                  "strength": num("0-1: how much of the subject's displacement from the centre the pan follows (default 1 = keep it centred)"), "project": projectArg], required: ["clip"])),
        Tool(name: "stabilize_clip", description: "Smooth camera shake on a video clip: analyses its motion frame by frame (on-device image registration, a few seconds per minute of footage), smooths the camera path over `strength` seconds and counter-shifts the picture every frame, zooming in slightly (up to 1.25×) to hide the borders. Keyed to source time, so later trims and speed changes keep working; call again to re-analyse. Returns samples, zoom, crop percentage and the largest shift; remove true clears it.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "strength": num("Smoothing window in seconds (default 0.6; larger = steadier but more zoom, 0.1-3)"),
                                  "remove": .object(["type": "boolean", "description": "Remove the stabilization instead"]), "project": projectArg], required: ["clip"])),
        // MARK: Effects
        Tool(name: "set_chroma_key", description: "Green-screen (chroma) key a video or still clip on a video track: the screen colour turns transparent and the rows below show through (put the background on a lower video track). color \"auto\" (the default for a clip without a key) picks the screen colour from the edges of the frame at `time` and refuses when no saturated colour dominates them; or give #RRGGBB. tolerance widens what counts as screen, softness the ramp at the edge, spill takes the screen's colour cast off hair and skin; shrink (+) / grow (-) and edge_blur clean the matte, in pixels of a 1080-line picture. Values out of range are refused, not clamped. Omitted values keep the clip's current ones (or the defaults: tolerance 0.4, softness 0.3, spill 0.6, shrink 0, edge_blur 0). One undoable edit; the result gives the key and how much of the frame at `time` is keyed, edge and kept. Check with key_matte and capture_frame.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "color": str("auto (detect from the frame's edges) or #RRGGBB"), "tolerance": num("0-1 (default 0.4)"), "softness": num("0-1 (default 0.3)"),
                                  "spill": num("0-1: spill suppression (default 0.6)"), "shrink": num("-20 to 20 px: + shrinks the kept area, - grows it (default 0)"), "edge_blur": num("0-20 px blur of the matte edge (default 0)"),
                                  "time": num("Timeline seconds of the frame to detect and measure on (default: the playhead, inside the clip)"),
                                  "remove": .object(["type": "boolean", "description": "Remove the key instead"]), "project": projectArg], required: ["clip"])),
        Tool(name: "key_matte", description: "Show a keyed clip's matte at a time as a PNG (white = kept, black = keyed out, grey = partly transparent), with the share of each. Reads the clip's own picture, before crop, transform and grade. Use it to judge set_chroma_key: holes in the subject = lower tolerance; screen left grey = raise it.",
             inputSchema: schema(["clip": str("Clip id prefix or name (it must have a key)"), "time": num("Timeline seconds inside the clip (default: the playhead)"), "max_width": int("PNG width in pixels, 64-4096 (default 960)"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_blend_mode", description: "How a clip's picture combines with the video rows below it: \(ClipBlendMode.allCases.map(\.rawValue).joined(separator: ", ")). normal covers them, as always. Opacity, fades and keyframed opacity mix the blended result with what is below. Transparent areas (outside a scaled-down picture, a keyed-out screen) leave the rows below untouched. Unknown modes are refused.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "mode": str(ClipBlendMode.allCases.map(\.rawValue).joined(separator: " | ")), "project": projectArg], required: ["clip", "mode"])),
        Tool(name: "blur_faces", description: "Find and follow every face in a video clip with on-device face detection (about 10 frames a second over the clip's source range, faces numbered 1, 2, ... in order of appearance) and blur, pixelate or black them out in every frame, following them through crop, transform and trims. The result lists each face with the timeline seconds it is seen. Leave chosen faces sharp with exclude [numbers] (or blur only some with only [numbers]). A second call with only look settings re-uses the analysis; reanalyse true runs it again. remove true takes the face blur off (blur regions stay). Detection can miss faces in profile, very small or blurred: check with capture_frame, and use blur_region for what it misses.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "style": str("blur (default), pixelate or solid (black)"), "strength": num("0-1: blur radius or pixel size relative to the face (default 0.6)"),
                                  "expand": num("0-1: grow each face box by this fraction (default 0.25)"), "feather": num("0-1: softness of the edge (default 0.4)"),
                                  "exclude": .object(["type": "array", "items": .object(["type": "integer"]), "description": "Face numbers to leave sharp"]),
                                  "only": .object(["type": "array", "items": .object(["type": "integer"]), "description": "Blur only these face numbers"]),
                                  "reanalyse": .object(["type": "boolean", "description": "Run the face analysis again"]), "remove": .object(["type": "boolean", "description": "Remove the face blur"]), "project": projectArg], required: ["clip"])),
        Tool(name: "blur_region", description: "Blur a rectangle of a clip (a licence plate, a screen, a logo): x, y, width, height normalized 0-1 to the clip's own picture (top-left corner, y down, before crop and transform), from start to end (timeline seconds, default the whole clip). track true follows it through the video from `start` with on-device object tracking and holds it where tracking is lost (the result says when). Uses the clip's blur look (style, strength, feather; shared with blur_faces). remove takes a region number or all.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "x": num("Left edge, 0-1"), "y": num("Top edge, 0-1"), "width": num("0.01-1"), "height": num("0.01-1"),
                                  "start": num("Timeline seconds (default: clip start)"), "end": num("Timeline seconds (default: clip end)"),
                                  "track": .object(["type": "boolean", "description": "Follow the rectangle through the video from start"]),
                                  "style": str("blur, pixelate or solid"), "strength": num("0-1"), "feather": num("0-1"), "remove": str("A region number, or all"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_text_animation", description: "Animate how a title or lower third comes on and goes off: in and out each take \(TextAnimation.Kind.allCases.map(\.rawValue).joined(separator: ", ")) (none = it cuts). fade, slideUp / slideDown (a short move with a fade), pop (scales up with a small overshoot), typewriter (letter by letter), words (word by word), wipe (left to right; on a lower third it builds piece by piece). Durations 0.05-5 s; in + out may not exceed the text's length. Omitted values keep the current ones. Preview, export and capture_frame show the same frames.",
             inputSchema: schema(["text": str("Text id prefix (from inspect_timeline)"), "in": str("How it comes on"), "in_duration": num("Seconds (default 0.5)"), "out": str("How it goes off"), "out_duration": num("Seconds (default 0.4)"), "project": projectArg], required: ["text"])),
        Tool(name: "add_lower_third", description: "Add a lower third: a name with a role under it, drawn by a template (bar: an accent bar beside a dark box; box: the name on an accent box, the role on a dark one; line: the name over an accent rule, no box), placed lower left unless x / y say otherwise, coming on with a wipe and going off with a fade unless in / out say otherwise. With `text` it edits that lower third instead. It is a text overlay: move, retime and remove it like any text. Returns its id and settings, and says when it leaves the frame or overlaps another text.",
             inputSchema: schema(["name": str("The name (the big line)"), "role": str("The line under it (job title, place); empty for none"), "template": str("bar (default), box or line"),
                                  "start": num("Timeline seconds (default: the playhead)"), "duration": num("Seconds, 0.5-600 (default 4)"), "x": num("Centre x, 0-1 (default: lower left)"), "y": num("Centre y, 0-1, down (default: lower left)"),
                                  "accent": str("#RRGGBB of the bar / box / rule (default #FF9F0A)"), "color": str("#RRGGBB of the name (default white)"), "font_size": num("Name size in points at the project size, 16-200 (default 56); the role is 55 % of it"),
                                  "in": str("In animation (default wipe)"), "out": str("Out animation (default fade)"), "text": str("Id prefix of a lower third to edit instead of adding one"), "project": projectArg], required: ["name"])),
        Tool(name: "set_project_color", description: "The project's output colour: sdr (Rec.709, the default; frames pass through unmanaged, exactly as before), hlg or pq (HDR in Rec.2020). In an HDR project the hevc10 / ProRes masters are HDR (HLG or PQ tags; PQ also carries mastering-display metadata), SDR sources sit at reference white (203 nits) and HLG / PQ sources (iPhone HDR video) keep their highlights; The preview, H.264 exports and capture_frame stay SDR with HDR sources tone-mapped. Grades, LUTs and the key work in 0-1 and clip HDR highlights in the clips that use them.",
             inputSchema: schema(["color": str("sdr | hlg | pq"), "project": projectArg], required: ["color"])),
        // MARK: Audio
        Tool(name: "set_clip_compressor", description: "Compress a clip's sound: above `threshold` dBFS the level rises only 1/`ratio` as fast, with a soft knee, attack and release times and makeup gain. Stereo-linked peak detection, runs after EQ, high-pass, gate, hum removal and de-esser, before clip gain and the limiter. Turning it on without settings uses threshold -18, ratio 3, attack 10 ms, release 150 ms, knee 6 dB, makeup 0. Out-of-range values are refused. enabled false removes it. Returns the clip's whole audio settings and what changed.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "enabled": .object(["type": "boolean", "description": "true turns it on (defaults for anything not given), false removes it"]),
                                  "threshold": num("dBFS, -60 to 0"), "ratio": num("1 to 20 (e.g. 3 = 3:1)"), "attack": num("ms, 0.1 to 200"), "release": num("ms, 10 to 2000"),
                                  "knee": num("dB, 0 (hard) to 24"), "makeup": num("dB added after compression, -12 to 24"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_clip_limiter", description: "True-peak look-ahead limiter on a clip, last in the clip's chain (after compressor and clip gain): nothing in the clip passes `ceiling` dBTP, measured 4× oversampled, after the clip's volume and fades. `lookahead` ms of delay lets the gain come down before a peak arrives; every clip on the track is delayed by the same amount so nothing shifts between clips. Defaults: ceiling -1 dBTP, release 100 ms, look-ahead 1.5 ms. enabled false removes it.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "enabled": .object(["type": "boolean", "description": "true turns it on, false removes it"]),
                                  "ceiling": num("dBTP, -24 to 0 (default -1)"), "release": num("ms, 1 to 1000 (default 100)"), "lookahead": num("ms, 0 to 5 (default 1.5)"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_clip_deesser", description: "Tame harsh s and sh sounds in a voice: the band above `frequency` Hz (Linkwitz-Riley crossover) is turned down while it stands out from the whole voice (more than 15 dB under it is left alone), by up to 18 dB at amount 1. Runs after the gate and before the compressor. Defaults: amount 0.5, frequency 6000 Hz (try 4500-5500 for a low voice, 7000-8000 for a bright one). enabled false removes it.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "enabled": .object(["type": "boolean", "description": "true turns it on, false removes it"]),
                                  "amount": num("0 to 1 (default 0.5)"), "frequency": num("Hz, 3000 to 12000 (default 6000)"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_clip_hum_removal", description: "Remove mains hum: narrow notches (Q 30) at 50 or 60 Hz and its harmonics, run with the EQ. frequency auto (the default when first turned on) listens to the clip's own sound, compares 50/100/150/200 Hz with 60/120/180/240 Hz against the spectrum beside them, and stores the stronger; the numbers come back in the note. amount 1 = full notch, 0.5 = -6 dB at each centre. enabled false removes it.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "enabled": .object(["type": "boolean", "description": "true turns it on, false removes it"]),
                                  "frequency": str("auto, 50 or 60"), "amount": num("0 to 1 (default 1)"), "harmonics": int("Notches including the fundamental, 1 to 8 (default 4)"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_clip_mix", description: "A clip's gain in dB (after its compressor, before its limiter; -24 to 24) and pan (-1 left, 0 centre, 1 right; balance law: the far side fades, the near side stays at full level). Panning a clip whose file has mono sound is refused: AVFoundation spreads one channel to both speakers after the clip's processing.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "gain": num("dB, -24 to 24"), "pan": num("-1 to 1"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_audio_crossfade", description: "Crossfade the sound into a clip on an audio track from the clip that ends where it starts: the outgoing clip plays on past the cut for `duration` seconds while it fades out and this one fades in. equal_power (sin/cos, constant loudness, the default) suits unrelated sounds; linear (constant amplitude) suits two parts of the same recording. Needs media past the outgoing clip's out point; a longer duration is shortened to what is there, with a note. Video tracks use set_transition. remove true takes it off.",
             inputSchema: schema(["clip": str("The incoming clip: id prefix or name"), "duration": num("Seconds, 0.02 to 10 (default 0.5)"), "curve": str("equal_power (default) or linear"),
                                  "remove": .object(["type": "boolean", "description": "Remove the crossfade"]), "project": projectArg], required: ["clip"])),
        Tool(name: "set_track_mix", description: "A track's fader: gain in dB (-60 to 12), pan (-1 to 1; mono clips are not panned, listed in the note), solo (while any track is soloed every other track is silent), mute, and bus (a bus name or id, or none for straight to the master). Returns the track's mix after the change.",
             inputSchema: schema(["track": str("Track name or id"), "gain": num("dB, -60 to 12"), "pan": num("-1 to 1"), "solo": .object(["type": "boolean", "description": "Solo on or off"]),
                                  "mute": .object(["type": "boolean", "description": "Mute on or off"]), "bus": str("Bus name or id, or none"), "project": projectArg], required: ["track"])),
        Tool(name: "set_bus", description: "Create or change a bus (a group of tracks: dialogue, music…): gain in dB, mute, a compressor and a limiter. A name no bus has creates the bus; route tracks to it with set_track_mix. The gain is exact; the compressor and limiter run once per member track on that track alone (AVFoundation sums the tracks itself, with no stage after the sum), so they react to each track's level, not the bus total. compressor/limiter are objects of settings, e.g. {\"threshold\": -20, \"ratio\": 4} or {} for the defaults.",
             inputSchema: schema(["bus": str("Bus name or id (a new name creates it)"), "rename": str("New name"), "gain": num("dB, -60 to 12"), "mute": .object(["type": "boolean", "description": "Mute the bus (its tracks fall silent)"]),
                                  "compressor": .object(["type": "object", "description": "threshold, ratio, attack, release, knee, makeup (same ranges as set_clip_compressor)"]),
                                  "remove_compressor": .object(["type": "boolean", "description": "Remove the bus compressor"]),
                                  "limiter": .object(["type": "object", "description": "ceiling, release, lookahead (same ranges as set_clip_limiter)"]),
                                  "remove_limiter": .object(["type": "boolean", "description": "Remove the bus limiter"]),
                                  "remove": .object(["type": "boolean", "description": "Delete the bus; its tracks go straight to the master"]), "project": projectArg], required: ["bus"])),
        Tool(name: "set_master", description: "The master: gain in dB (-24 to 24) and a true-peak limiter ({ceiling, release, lookahead}, {} for -1 dBTP). The limiter runs once per track (no stage after AVFoundation's sum), so tracks peaking together can pass it; normalize_loudness sets both and checks the summed true peak of the real mix.",
             inputSchema: schema(["gain": num("dB, -24 to 24"), "limiter": .object(["type": "object", "description": "ceiling (dBTP, -24 to 0), release (ms), lookahead (ms)"]),
                                  "remove_limiter": .object(["type": "boolean", "description": "Remove the master limiter"]), "project": projectArg])),
        Tool(name: "inspect_mix", description: "The mixer: every track's gain, pan, mute, solo, bus and how many clips have processing; the buses with their settings and tracks; the master gain and limiter; and how buses and the master are run.",
             inputSchema: schema(["project": projectArg])),
        Tool(name: "measure_loudness", description: "Measure loudness offline the way the export renders the sound (48 kHz stereo, every clip setting, fader, bus and master): integrated loudness in LUFS (ITU-R BS.1770-4: K-weighting, 400 ms blocks, gates at -70 LUFS and -10 LU), true peak in dBTP (4× oversampled), sample peak and RMS in dBFS, loudness range in LU, loudest momentary and short-term loudness, and how far it is from -14 (YouTube), -16 (Apple, podcasts) and -23 (EBU R128). clip measures that clip alone (no track fader, bus or master).",
             inputSchema: schema(["clip": str("Clip id prefix or name (default: the whole mix)"), "project": projectArg])),
        Tool(name: "normalize_loudness", description: "Make the sound a target loudness in one call: measures, sets the master gain and a master true-peak limiter (or, with clip, that clip's gain and limiter), measures again until it is within 0.1 LU, and lowers the gain if the mixed true peak passes the ceiling. Returns before and after measurements, the gain and every measuring step. One undo step. Refused while a track is soloed. target: youtube (-14, default), apple or podcast (-16), ebu (-23), or a number of LUFS.",
             inputSchema: schema(["target": str("youtube, apple, podcast, ebu or a number such as -14"), "ceiling": num("True-peak ceiling in dBTP, -9 to 0 (default -1)"),
                                  "clip": str("Clip id prefix or name: normalize that clip alone (default: the whole mix)"), "project": projectArg])),
        // MARK: Editing
        Tool(name: "roll_edit", description: "Roll the cut between two touching clips on one track: the cut moves by `delta` seconds (or `to` a timeline time), the clip on one side gets longer and the other shorter by the same amount, so nothing else on the timeline moves. `edge` end (default) rolls the cut after `clip`, start the cut before it. Refused (with how far it could go) when the growing clip has no more media or the shrinking one would go under one frame; never clamped. A J/L cut moves with the edit. Returns the cut before/after and both clips.",
             inputSchema: schema(["clip": str("Clip id prefix or name on one side of the cut"), "edge": str("end (default: the cut after the clip) or start (the cut before it)"),
                                  "delta": num("Seconds to move the cut (+ later, - earlier)"), "to": num("Timeline time to move the cut to (instead of delta)"), "project": projectArg], required: ["clip"])),
        Tool(name: "slip_clip", description: "Slip a clip: show an earlier or later part of its source in the same place and length (source in and out both move by `delta` source seconds, or the in point goes `source_in`). Nothing on the timeline moves; keyframes stay where they are on the timeline; sound, multicam angles and J/L cuts slip with it. Refused when the source would run out at either end (the message says how far it can go) and for still images.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "delta": num("Source seconds to slip (+ shows later media, - earlier)"), "source_in": num("New source in point in seconds (instead of delta)"), "project": projectArg], required: ["clip"])),
        Tool(name: "slide_clip", description: "Slide a clip between its neighbours: it moves by `delta` seconds (or `to` a new start) keeping its own source in/out, the touching clip before it is extended or trimmed at its end and the touching clip after it at its start, so the track keeps its length and nothing else moves. An edge with no touching neighbour can move into a gap but not over another clip. Refused (never clamped) when a neighbour would run out of media or go under one frame.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "delta": num("Seconds to slide (+ later, - earlier)"), "to": num("New timeline start in seconds (instead of delta)"), "project": projectArg], required: ["clip"])),
        Tool(name: "set_split_edit", description: "J and L cuts: let a video clip's sound start before its picture (`lead` seconds: a J cut, you hear the next shot first) and/or run on after it (`trail` seconds: an L cut). The extra sound is the clip's own source media beyond its in/out, so it needs that much media (refused otherwise, with the maximum). Negative values start the sound later / end it earlier than the picture; 0 puts it back. Where the sound runs under a neighbour both sounds play (neighbour overlap, the default); neighbour trim instead moves the touching neighbour's sound edge so the sounds meet at the new audio cut; setting an edge to 0 (a reset) only gives back sound a trim took from the neighbour and never removes the neighbour's own J or L cut. Fades sit at the sound's own edges. Split, ripple delete, trims and slips keep the split edit at its edge. Returns lead, trail, sound start/end, the maximums and any sounds now overlapping.",
             inputSchema: schema(["clip": str("Clip id prefix or name (a video clip with sound, on a video track)"), "lead": num("Seconds the sound starts before the picture (J cut); 0 = with the picture"),
                                  "trail": num("Seconds the sound runs after the picture (L cut); 0 = with the picture"), "neighbour": str("overlap (default: both sounds play where they meet) or trim (the touching neighbour's sound is trimmed/extended to meet this one)"), "project": projectArg], required: ["clip"])),
        Tool(name: "relink_media", description: "Point the project at media files that moved: list_assets marks a file that is not at its path with missing true (its clips play black and silent). With no arguments every missing file is looked up through the bookmark made at import (finds files moved or renamed on the same disk). folder: also search that folder (and its subfolders unless recursive false), matching by file name and checking duration (within a frame) and picture size, then files of the same type, duration and size under another name. asset + path: use exactly that file for that asset (also for a file that is not missing). A replacement of another kind or shorter than what the timeline plays is refused. Files are only read, never moved. One undoable edit; returns what was relinked (with why) and what is still missing (with candidates). dry_run true only reports.",
             inputSchema: schema(["asset": str("Asset id prefix or name (omit: every missing file)"), "path": str("Absolute path of the file to use for asset"), "folder": str("Absolute folder to search"),
                                  "recursive": .object(["type": "boolean", "description": "Search subfolders too (default true)"]), "dry_run": .object(["type": "boolean", "description": "Report matches without changing the project (default false)"]), "project": projectArg])),
        Tool(name: "consolidate_media", description: "Copy every media file the timeline uses (clips, multicam angles and their sound, media inside nested sequences, .cube LUT files given by path) into one folder and point the project at the copies, so the project and its media can be moved together. Default folder: '<project name> Media' next to the project file. Copies only: the originals are never moved or changed; a file of the same name and size already in the folder is reused, another file with the same name gets a numbered name. Missing files are listed, not copied. Returns the folder, files copied and reused, and bytes copied. Blocks until the copies are done; dry_run true only plans.",
             inputSchema: schema(["folder": str("Absolute folder to copy into (created if missing; default next to the project file)"), "dry_run": .object(["type": "boolean", "description": "Plan the copies without copying (default false)"]), "project": projectArg])),
        Tool(name: "detect_scenes", description: "Find hard cuts (shot changes) in a clip's media or a whole video asset, from a colour-histogram and brightness-grid difference between frames with an adaptive threshold (a cut must stand out from the second before it, so busy shots need a bigger jump). Dissolves and fades are not reported. Returns each cut's source time, timeline time (for a clip) and score 0...1. action split: split the clip at every cut (one undoable edit; J/L cuts and keyframes follow the pieces); markers: a marker named 'Scene N' at each cut; none (default): only report. Reads the file once at low resolution: about real time / 10 for HD.",
             inputSchema: schema(["clip": str("Clip id prefix or name (give clip or asset)"), "asset": str("Asset id prefix or name: scan the whole file (action none only)"),
                                  "sensitivity": num("0...1 (default 0.5); higher finds smaller jumps"), "min_scene": num("Shortest shot in seconds (default 0.5); cuts closer than this to the previous one are dropped"),
                                  "action": str("none (default), split or markers"), "project": projectArg])),
        Tool(name: "insert_edit", description: "Three/four-point insert: put a range of an asset on the timeline and push everything after it right (on every track, so sync holds; a clip under timeline in is split). Give three of source_in, source_out, timeline_in, timeline_out and the fourth follows from the length; give all four to fit the source range into the timeline range by changing the clip's speed (fit to fill, 0.1–10×). Timeline in defaults to the playhead. A range past the media, shorter than a frame, or before 0 is refused. One undoable edit; returns the placed clip, its points and speed.",
             inputSchema: schema(["asset": str("Asset id prefix or name"), "source_in": num("Source in, seconds of the asset"), "source_out": num("Source out, seconds of the asset"),
                                  "timeline_in": num("Timeline in, seconds (default: the playhead when the app shows one)"), "timeline_out": num("Timeline out, seconds"),
                                  "track": str("Track id prefix or name (default: the first track of the asset's kind)"), "project": projectArg], required: ["asset"])),
        Tool(name: "overwrite_edit", description: "Three/four-point overwrite: put a range of an asset on the timeline over whatever is between timeline in and out on ONE track (clips there are removed, or trimmed/split at the range edges; other tracks and later clips do not move). Points as insert_edit: three fix the fourth, four = fit to fill (speed). One undoable edit; returns the placed clip and the names of the clips it replaced or cut.",
             inputSchema: schema(["asset": str("Asset id prefix or name"), "source_in": num("Source in, seconds of the asset"), "source_out": num("Source out, seconds of the asset"),
                                  "timeline_in": num("Timeline in, seconds (default: the playhead when the app shows one)"), "timeline_out": num("Timeline out, seconds"),
                                  "track": str("Track id prefix or name (default: the first track of the asset's kind)"), "project": projectArg], required: ["asset"])),
        Tool(name: "set_smooth_slow_motion", description: "How a clip slower than 1× makes its in-between frames: off (each source frame repeats, as before), blend (cross-fade of the two neighbouring frames), optical_flow (frames drawn along the motion with VideoToolbox frame-rate conversion; macOS 15.4+ on supported Macs, else blend, said in note). The clip's range is rendered once at timeline fps / speed into a cache and used by the preview and the export; the sound is untouched. Refused for clips at 1× or faster, stills, sound, nested sequences, multicam and missing media. wait true renders before returning (about real time for blend at HD); otherwise it renders in the background and status says rendering.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "mode": str("off, blend or optical_flow"), "wait": .object(["type": "boolean", "description": "Render before returning (default false)"]), "project": projectArg], required: ["clip", "mode"])),
        Tool(name: "match_frame", description: "The source frame under a timeline time: which asset plays there (top-most visible video track, or the given clip) and the second of the asset that plays, with the clip's source in/out. In the app this also opens the source viewer on that frame (F).",
             inputSchema: schema(["time": num("Timeline seconds (default: the playhead)"), "clip": str("Clip id prefix or name (default: the top-most picture at time)"), "project": projectArg])),
        // MARK: Color
    ] + colorTools

    private static let layerArg = str("Grade layer name or id prefix (from add_grade_layer or inspect_timeline); omit for the clip's primary grade")
    private static let pointsArg: Value = .object(["type": "array", "items": .object(["type": "array", "items": .object(["type": "number"]), "minItems": 2, "maxItems": 2]),
                                                   "description": "Curve points [[x, y], ...]; [] removes the curve"])
    static let colorTools: [Tool] = [
        Tool(name: "set_color_wheels", description: "Primary color wheels on a video clip (or on one of its grade layers), like DaVinci Resolve's: lift (shadows: moves black, white stays), gamma (midtones: + brightens the middle, black and white stay), gain (highlights: scales toward white, black stays), offset (shifts every level). Each wheel is an RGB balance (r, g, b) plus a master amount; each channel uses master + its balance. Values -1 to 1; real grades are small (0.02 to 0.2). Instead of r/g/b you can give toward + amount: a balance that pushes the wheel toward a hue without changing brightness (amount is the largest channel's shift). toward is a hue in degrees (0 red, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta) or a word: red, orange, warm, amber, yellow, lime, green, cyan, teal, cool, blue, purple, violet, magenta, pink. Example, 'lift the shadows -0.05 toward blue': wheel lift, master -0.05, toward blue, amount 0.05. Only the values you pass change; reset true zeroes this wheel first; wheel all with reset true clears all four (set_clip_color reset clears them too). Order in the grade: input LUT, exposure, contrast, saturation, temperature/tint, shadows/midtones/highlights, vibrance, then these wheels, then custom curves, then the look. Out-of-range values are refused, not clamped. Returns the wheel, its effective per-channel values and what they do; check with frame_stats or capture_scopes.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "layer": layerArg, "wheel": str("lift, gamma, gain, offset, or all (only with reset true)"),
                                  "r": num("Red balance, -1 to 1"), "g": num("Green balance, -1 to 1"), "b": num("Blue balance, -1 to 1"), "master": num("All channels, -1 to 1"),
                                  "toward": str("Hue to push toward instead of r/g/b: degrees or a colour word (blue, teal, warm…)"), "amount": num("How far toward the hue, -1 to 1 (negative = the opposite hue)"),
                                  "reset": .object(["type": "boolean", "description": "Zero this wheel before applying the values"]), "project": projectArg], required: ["clip", "wheel"])),
        Tool(name: "set_color_curve", description: "Custom curve on a video clip (or one of its grade layers). master (applied to R, G and B alike, so it also shifts saturation a little), red, green or blue map input to output with points [[x, y], ...], x and y from 0 to 1; (0,0) and (1,1) are implied unless you give a point at x 0 or 1. The curve is a smooth spline through the points that never overshoots between them, and continues straight past 1 so bright values are not clipped. Example S-curve: master [[0.25,0.2],[0.75,0.8]]. hue_sat maps hue (x as a fraction of the colour circle: 0 red, 0.167 yellow, 0.333 green, 0.5 cyan, 0.667 blue, 0.833 magenta; it wraps at red) to a saturation gain y from 0 (gray) to 2 (double), 1 = unchanged; to change one hue only, anchor its neighbours at 1, e.g. mute greens: [[0.2,1],[0.333,0.4],[0.46,1]]. points [] removes that curve. At most 32 points, x at least 0.01 apart. Applied after the color wheels and before the look; the 5-point shadows/midtones/highlights controls of set_clip_color are separate and keep working. Returns the points and the curve sampled at x 0, 0.25, 0.5, 0.75, 1 (hue_sat: the gain at red, yellow, green, cyan, blue, magenta).",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "layer": layerArg, "curve": str("master, red, green, blue or hue_sat"), "points": pointsArg, "project": projectArg], required: ["clip", "curve", "points"])),
        Tool(name: "capture_scopes", description: "The video scopes of the composed frame at a timeline time, as a PNG image plus their numbers, to grade the way a colorist reads scopes: luma waveform, RGB parade (each channel's levels across the frame: equal traces on a neutral subject mean no cast), vectorscope (Rec.709: distance from the centre is saturation, the angle is hue; boxes mark 75% R, Mg, B, Cy, G, Yl; the faint orange line is where skin tones should sit) and RGB histogram. The numbers: per channel black level (1st percentile), median, white level (99th) and mean in 0-255, mean saturation, the frame's colour cast (hue in HSV degrees and strength), the dominant hue, and the share of colour per 30-degree sector. frame_stats returns the same numbers without the image.",
             inputSchema: schema(["seconds": num("Timeline time"), "max_width": int("Image width in pixels, 400 to 2400 (default 1200)"), "project": projectArg], required: ["seconds"]), annotations: .init(readOnlyHint: true)),
        Tool(name: "add_grade_layer", description: "Add a grade layer to a video clip: a second grade (like a node in DaVinci Resolve) applied after the clip's own grade, in order with its other layers, each on the result of the one before. A layer has a name, enabled, a mix (0 to 1, how much of it shows) and its own colour settings, and optionally a mask (set_layer_mask: a shape, a colour qualifier or an AI subject matte) so it applies only to part of the frame. A new layer changes nothing until you grade it: set_color_wheels or set_color_curve with layer = its id, or update_grade_layer for exposure, contrast, saturation, temperature, tint, shadows/midtones/highlights, vibrance and a look. At most 12 layers per clip. Returns the clip's layers.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "name": str("Layer name, 1 to 40 characters (default Layer N)"), "index": int("Position in the stack, 0 = first (default: last)"),
                                  "mix": num("0 to 1 (default 1)"), "enabled": .object(["type": "boolean", "description": "Default true"]), "project": projectArg], required: ["clip"])),
        Tool(name: "update_grade_layer", description: "Change a grade layer of a video clip: its name, enabled, mix (0 to 1), and its colour settings with the same meaning and ranges as set_clip_color: exposure (-4 to 4 stops), contrast (0.25 to 3), saturation (0 to 3, 1 = untouched), temperature and tint (-100 to 100), shadows, midtones, highlights and vibrance (-1 to 1), look (a built-in name or a .cube path; none removes it) with look_mix (0 to 1). reset true clears the layer's colour first (wheels and curves too). Only what you pass changes; out-of-range values are refused. The layer's wheels and curves are set with set_color_wheels / set_color_curve and its mask with set_layer_mask. Returns the clip's layers.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "layer": str("Layer name or id prefix"), "name": str("New name"), "enabled": .object(["type": "boolean", "description": "Turn the layer on or off"]),
                                  "mix": num("0 to 1"), "exposure": num("Stops, -4 to 4"), "contrast": num("0.25 to 3"), "saturation": num("0 to 3"), "temperature": num("-100 to 100"), "tint": num("-100 to 100"),
                                  "shadows": num("-1 to 1"), "midtones": num("-1 to 1"), "highlights": num("-1 to 1"), "vibrance": num("-1 to 1"), "look": str("Built-in look name, .cube path, or none"),
                                  "look_mix": num("0 to 1"), "reset": .object(["type": "boolean", "description": "Clear the layer's colour first"]), "project": projectArg], required: ["clip", "layer"])),
        Tool(name: "remove_grade_layer", description: "Remove a grade layer (and its mask) from a video clip. Returns the remaining layers.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "layer": str("Layer name or id prefix"), "project": projectArg], required: ["clip", "layer"])),
        Tool(name: "move_grade_layer", description: "Move a grade layer to another position in its clip's stack (0 = first, applied right after the clip's own grade). Order matters: each layer grades the result of the ones before it, and a colour qualifier keys the picture its layer receives. Returns the layers in their new order.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "layer": str("Layer name or id prefix"), "index": int("New position, 0 to count - 1"), "project": projectArg], required: ["clip", "layer", "index"])),
        Tool(name: "match_color", description: "Shot match: grade a video clip so it looks like a reference clip. Renders a frame of each on its own (clip_seconds and reference_seconds are timeline times inside each clip; default the middle of each), measures per-channel black level, median and white level and the saturation, solves lift, gamma and gain per channel plus a saturation factor, and puts them on a grade layer named 'Shot match' after the clip's own grade (replacing the previous match if there is one), as one undoable edit. Then renders again and returns the colour distance to the reference before and after (RMS of per-channel percentile differences in 0-255 levels: under about 5 is a close match), the medians and the solved values. Works best when both frames show similar content and light; it matches overall colour and contrast, not individual objects. Lower the result with update_grade_layer mix.",
             inputSchema: schema(["clip": str("Clip to change: id prefix or name"), "reference": str("Clip to match: id prefix or name"), "clip_seconds": num("Timeline time inside the clip to measure (default its middle)"),
                                  "reference_seconds": num("Timeline time inside the reference (default its middle)"), "mix": num("Strength of the match, 0 to 1 (default 1)"), "project": projectArg], required: ["clip", "reference"])),
        Tool(name: "set_clip_finish", description: "Finishing effects on a video clip, applied after its grade and grade layers in this order: noise_reduction (0 to 1), sharpen (0 to 1, luminance only) with sharpen_radius (0.5 to 10 px), glow (0 to 1: what is brighter than glow_threshold, 0 to 1, is blurred by glow_radius, 2 to 200 px, and screened back: bloom on highlights), vignette (-1 to 1: + darkens the edges, - lightens them) with vignette_size (0.1 to 1.5: where the falloff is centred, 1 = the corners) and vignette_softness (0.05 to 1: how wide the falloff is), grain (0 to 1, monochrome film grain, strongest in the mid-tones, a fixed pattern per frame) with grain_size (0.5 to 4 px). Sizes are pixels of a 1080-line frame and scale with the project. 0 turns an effect off; only what you pass changes; reset true clears all first. Subtle values read as film: grain 0.15 to 0.3, vignette 0.2 to 0.4, glow 0.2 to 0.4. Out-of-range values are refused. Returns the clip's finishing.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "noise_reduction": num("0 to 1"), "sharpen": num("0 to 1"), "sharpen_radius": num("0.5 to 10 px (default 1.5)"),
                                  "glow": num("0 to 1"), "glow_radius": num("2 to 200 px (default 24)"), "glow_threshold": num("0 to 1 (default 0.75)"),
                                  "vignette": num("-1 to 1"), "vignette_size": num("0.1 to 1.5 (default 0.8)"), "vignette_softness": num("0.05 to 1 (default 0.5)"),
                                  "grain": num("0 to 1"), "grain_size": num("0.5 to 4 px (default 1)"), "reset": .object(["type": "boolean", "description": "Clear all finishing first"]), "project": projectArg], required: ["clip"])),
        Tool(name: "set_layer_mask", description: "Limit a grade layer to part of the frame. A mask has up to three parts that multiply, plus invert: (1) shape ellipse or rectangle placed on the frame: center_x, center_y (fractions of the frame, 0,0 = top left; default 0.5), width, height (fractions of the frame; default 0.5), rotation (degrees clockwise), feather (soft edge as a fraction of the frame height, 0 to 0.5; default 0.05), shape_invert; shape none removes it. (2) a colour qualifier (HSL key) on the picture entering the layer: hue_center (HSV degrees: 0 red, 30 orange, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta) with hue_width (degrees, 360 = all hues) and hue_softness, sat_low/sat_high (saturation 0 gray to 1 pure colour), luma_low/luma_high (brightness 0 to 1), their softness values, and blur (px of a 1080-line frame); any of these creates the qualifier, qualifier none removes it. Example, skin tones: hue_center 25, hue_width 40, sat_low 0.1, sat_high 0.6. (3) subject person or foreground: an AI matte from Apple Vision of the people (person) or the main objects (foreground) in the clip's own picture, with subject_feather (px); subject none removes it. invert flips the whole mask; clear true removes everything first. Only what you pass changes; out-of-range values are refused. Check the result with capture_matte. Returns the clip's layers with a description of the mask.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "layer": str("Layer name or id prefix"), "shape": str("ellipse, rectangle or none"),
                                  "center_x": num("-0.5 to 1.5"), "center_y": num("-0.5 to 1.5"), "width": num("0.01 to 3"), "height": num("0.01 to 3"), "rotation": num("Degrees, -360 to 360"),
                                  "feather": num("0 to 0.5"), "shape_invert": .object(["type": "boolean", "description": "Select outside the shape"]),
                                  "qualifier": str("none removes the colour selection"), "hue_center": num("0 to 360"), "hue_width": num("0 to 360"), "hue_softness": num("0 to 180 degrees"),
                                  "sat_low": num("0 to 1"), "sat_high": num("0 to 1"), "sat_softness": num("0 to 1"), "luma_low": num("0 to 1"), "luma_high": num("0 to 1"), "luma_softness": num("0 to 1"),
                                  "blur": num("0 to 50 px"), "subject": str("person, foreground or none"), "subject_feather": num("0 to 50 px (default 4)"),
                                  "invert": .object(["type": "boolean", "description": "Flip the whole mask"]), "clear": .object(["type": "boolean", "description": "Remove the mask first"]), "project": projectArg], required: ["clip", "layer"])),
        Tool(name: "capture_matte", description: "The matte of a grade layer's mask at a timeline time, as a grayscale PNG: white where the layer applies, black where it does not, gray in between. Rendered from the clip on its own (its picture, transform and grade, nothing else). Returns the coverage (share of the frame the layer applies to) and a note when the matte is empty, for example when Vision finds no person in the frame.",
             inputSchema: schema(["clip": str("Clip id prefix or name"), "layer": str("Layer name or id prefix"), "seconds": num("Timeline time inside the clip (default its middle)"),
                                  "max_width": int("Image width, 160 to 1920 (default 640)"), "project": projectArg], required: ["clip", "layer"]), annotations: .init(readOnlyHint: true)),
        // Fonts (FontLibrary.swift, FontTools.swift)
        Tool(name: "list_fonts", description: "Fonts for titles: the families on this Mac, fonts the user added, and the Google Fonts catalogue (about 1,900 free families, downloaded on first use). Filter by search (part of the name), category and source; sort by trending (Google's trending rank, which favours fast-growing and often new families), popular (Google's use rank), newest (date added to Google Fonts) or name. Installed families list their faces (PostScript names). Use a family name with add_text font or set_text_style font.",
             inputSchema: schema(["search": str("Part of a family name, any case"), "category": str("sans-serif, serif, display, handwriting or monospace"),
                                  "sort": str("trending (default), popular, newest or name"), "source": str("installed (everything on this Mac), google, custom (added by the user) or system; default all"),
                                  "limit": int("Max families, 1 to 500 (default 50)")]), annotations: .init(readOnlyHint: true)),
        Tool(name: "install_font", description: "Download a Google Fonts family to this Mac (TTF files from Google, free licences) and make it available to every project, preview and export. By default every style the family has; weights narrows it (e.g. [\"400\", \"700\", \"400i\"], i = italic). Styles already here are not fetched again. Returns the faces (PostScript names) now on this Mac.",
             inputSchema: schema(["family": str("Google Fonts family name, any case (list_fonts source google)"),
                                  "weights": .object(["type": "array", "items": .object(["type": "string"]), "description": "Styles to get: 400, 700, \"400i\" (italic), regular, bold, italic. Default: all"])], required: ["family"])),
        Tool(name: "add_font_files", description: "Add font files from this Mac (.ttf, .otf, .ttc, .otc, .woff, .woff2) to EditMax: they are copied into EditMax's fonts folder, available to every project at once and on every launch, and listed under My fonts. Returns the families and faces added and any file that could not be read.",
             inputSchema: schema(["paths": strs("Absolute paths of font files (~ is expanded)")], required: ["paths"])),
        Tool(name: "set_text_style", description: "Change a text overlay's font, size and color in one undoable edit. font is a family (any case) or a PostScript name from list_fonts; a Google family not on this Mac is downloaded first; a family picks the face nearest the text's preset weight (Title → bold); font \"default\" goes back to the preset's font. Works on titles, captions and lower thirds (the role line uses a lighter weight of the same family).",
             inputSchema: schema(["text": str("Text overlay id prefix from inspect_timeline"), "font": str("Family or PostScript name, or default"), "font_size": num("Points at project resolution, 8 to 500"),
                                  "color": str("Hex color like #FFFFFF"), "project": projectArg], required: ["text"])),
    ]

    /// Tools whose results carry what is said or shown in the footage.
    private static let contentTools: Set<String> = ["get_transcript", "search_transcript", "cut_transcript", "remove_words", "add_captions"]
    /// Free-text arguments (titles, searched phrases, words to remove) are the user's or the footage's content:
    /// the log records how long they were, never what they said.
    private static let textArgs: Set<String> = ["text", "phrase", "query", "words", "from_word", "to_word", "lines", "names", "role"]
    private static func loggableArgs(_ args: [String: Value]) -> String {
        var out: [String: Value] = [:]
        for (k, v) in args {
            if textArgs.contains(k) {
                switch v {
                case .string(let s): out[k] = .string("<\(s.count) chars>")
                case .array(let a): out[k] = .string("<\(a.count) items>")
                default: out[k] = v
                }
            } else { out[k] = v }
        }
        return (try? JSONEncoder().encode(out)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func register(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            let t0 = Date()
            let args = loggableArgs(params.arguments ?? [:])
            do {
                // The window follows the agent's edit (FollowPlans.swift); reads and the UI driver run as they are.
                let payload = try await AgentFollowDriver.run(params.name, params.arguments ?? [:]) { try await call(params.name, params.arguments ?? [:]) }
                var f: [String: Any] = ["tool": params.name, "args": String(args.prefix(500)), "ms": Int(Date().timeIntervalSince(t0) * 1000), "image": payload.image != nil]
                // Transcript and caption results are the footage's dialogue: the log keeps their length, not their words.
                if contentTools.contains(params.name) { f["resultChars"] = payload.text.count } else { f["result"] = String(payload.text.prefix(200)) }
                // The redactor blanks any JSON field named "key" (API keys); a keyboard key is not a secret.
                if params.name == "ui_key", let k = params.arguments?["key"]?.stringValue { f["pressed"] = k }
                DebugLog.event("mcp-call", f)
                var content: [Tool.Content] = [.text(payload.text)]
                if let img = payload.image { content.append(.image(data: img.base64EncodedString(), mimeType: "image/png")) }
                // structuredContent must be a JSON object; list results are wrapped so strict clients (Claude Code) accept them.
                var structured = payload.value
                if case .array(let items)? = structured { structured = .object(["items": .array(items)]) }
                return .init(content: content, structuredContent: structured, isError: false)
            } catch {
                DebugLog.error("mcp-call", error, ["tool": params.name, "args": String(args.prefix(500)), "ms": Int(Date().timeIntervalSince(t0) * 1000)])
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

    /// One Assets library item as list_library and add_to_library return it.
    struct LibraryInfo: Codable {
        var id: String, name: String, path: String, kind: String
        var duration: Double?
        var used_in: [String]
        var missing: Bool?
        @MainActor init(_ item: LibraryItem) {
            id = item.id.short; name = item.name; path = item.path; kind = item.kind.rawValue
            duration = item.duration.map { ($0 * 1000).rounded() / 1000 }
            used_in = item.usedIn.values.sorted()
            missing = item.exists ? nil : true
        }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
    private static func encodeText<T: Encodable>(_ v: T) throws -> String { String(decoding: try encoder.encode(v), as: UTF8.self) }
    private static func payload<T: Codable>(_ v: T) throws -> Payload { Payload(text: try encodeText(v), value: try? Value(v)) }
    /// A transcript page as sent: compact JSON (indented, a word takes 86 characters instead of 49), keys sorted so
    /// nextWord and note come before the words. Sized by `ToolExecutor.transcriptPageBytes` to stay whole.
    static func transcriptText(_ page: ToolExecutor.TranscriptInfo) throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(page), as: UTF8.self)
    }
    private static func message(_ s: String) -> Payload { Payload(text: s, value: .object(["message": .string(s)])) }

    /// The argument names a tool declares, from its schema; nil for a tool that is not in the catalog.
    static func argumentNames(of tool: String) -> Set<String>? {
        guard let t = tools.first(where: { $0.name == tool }), case .object(let schema) = t.inputSchema,
              case .object(let props)? = schema["properties"] else { return nil }
        return Set(props.keys)
    }

    @MainActor
    static func call(_ name: String, _ a: [String: Value]) async throws -> Payload {
        // A misspelt or misremembered argument must fail loudly: silently ignored, `remove_texts {texts: […]}` answered
        // "Removed 0" and the agent carried on believing it had worked.
        if let known = argumentNames(of: name) {
            let unknown = a.keys.filter { !known.contains($0) }.sorted()
            if !unknown.isEmpty {
                throw MCPError.invalidParams("\(name) does not take \(unknown.map { "'\($0)'" }.joined(separator: ", ")); its arguments are \(known.sorted().joined(separator: ", "))")
            }
        }
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
        // The Assets library spans projects, so it needs none open.
        switch name {
        case "list_library":
            var kind: LibraryItem.Kind?
            if let k = s("kind")?.lowercased(), !k.isEmpty, k != "all" {
                guard let v = LibraryItem.Kind(rawValue: k == "images" ? "image" : k == "fonts" ? "font" : k) else { throw MCPError.invalidParams("kind must be video, audio, image or font") }
                kind = v
            }
            let items = AssetLibrary.shared.items(kind: kind, search: s("search")).prefix(max(1, i("limit") ?? 100))
            return try payload(items.map(LibraryInfo.init))
        case "add_to_library":
            let paths = list("paths"); guard !paths.isEmpty else { throw MCPError.invalidParams("'paths' must list at least one file") }
            let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let r = await AssetLibrary.shared.add(urls: urls, source: .upload, copy: b("copy"))
            if r.items.isEmpty, !r.failures.isEmpty { throw EditError.invalid(r.failures.joined(separator: "; ")) }
            struct Added: Codable { var items: [LibraryInfo]; var skipped: [String]? }
            return try payload(Added(items: r.items.map(LibraryInfo.init), skipped: r.failures.isEmpty ? nil : r.failures))
        default: break
        }
        // The UI driver works on whichever EditMax window is up, Home included, so it needs no open project.
        switch name {
        case "ui_layout":
            return try payload(try UIDriver.layout(prefix: s("prefix")))
        case "ui_drag":
            let from = try UIDriver.target(a["from"], dx: d("from_dx") ?? 0, dy: d("from_dy") ?? 0)
            let to = try UIDriver.target(a["to"], dx: d("to_dx") ?? 0, dy: d("to_dy") ?? 0)
            UIDriver.modifiers = UIDriver.flags(list("modifiers")); defer { UIDriver.modifiers = [] }
            let how = try await UIDriver.drag(from: from, to: to, steps: i("steps") ?? 12, holdMs: i("hold_ms") ?? 80)
            let path = "from \(from.place) to (\(Int(to.point.x)), \(Int(to.point.y)))"
            switch how {
            case .events(let n): return message("Dragged \(path) with \(n) mouse events")
            case .handler(let id): return message("Dragged \(path) by calling \(id)'s own move/trim code: EditMax is not the active app, which SwiftUI gestures need. Media drops, header reorders and clicks always use real events.")
            }
        case "ui_click":
            let t = try UIDriver.target(a["target"], dx: d("dx") ?? 0, dy: d("dy") ?? 0)
            UIDriver.modifiers = UIDriver.flags(list("modifiers")); defer { UIDriver.modifiers = [] }
            switch try await UIDriver.click(t, count: i("count") ?? 1) {
            case .events: return message("Clicked " + (t.id.map { "\($0) at " } ?? "") + t.place)
            case .handler(let id): return message("Clicked \(id) by calling its own tap code: EditMax is not the active app, which SwiftUI gestures need.")
            }
        case "ui_select":
            return message(try await UIDriver.select(try UIDriver.target(a["target"], dx: 0, dy: 0), option: s("option")))
        case "ui_key":
            let key = try req("key")
            let how = try await UIDriver.key(key, modifiers: list("modifiers"))
            return message((how == .unused ? "Pressed \(key), but " : "Pressed \(key) (") + how.rawValue + (how == .unused ? "" : ")"))
        case "ui_scroll":
            return message(try await UIDriver.scroll(a["target"], dx: d("dx"), dy: d("dy")))
        case "ui_screenshot":
            let shot = try await UIDriver.screenshot(maxWidth: i("max_width") ?? 1400)
            return Payload(text: "Window (\(shot.png.count) bytes PNG, \(shot.method))", value: nil, image: shot.png)
        // Fonts belong to the app, not to a project.
        case "list_fonts":
            return try payload(try await ToolExecutor.fontList(search: s("search"), category: s("category"), sort: s("sort"), source: s("source"), limit: i("limit")))
        case "install_font":
            let weights = a["weights"]?.arrayValue?.compactMap { $0.stringValue ?? $0.intValue.map(String.init) ?? $0.doubleValue.map { String(Int($0)) } } ?? s("weights").map { [$0] }
            return try payload(try await FontLibrary.shared.installGoogle(try req("family"), styles: weights))
        case "add_font_files":
            let paths = list("paths"); guard !paths.isEmpty else { throw MCPError.invalidParams("'paths' must list at least one font file") }
            let r = await FontLibrary.shared.addFontFiles(paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
            if r.files.isEmpty { throw EditError.invalid(r.failures.joined(separator: "; ")) }
            return try payload(r)
        case "list_archive":
            struct Item: Codable { var id, kind, name, was, deleted: String; var days_left: Int; var bytes: Int64 }
            let ar = AppArchive.shared
            return try payload(ar.entries.sorted { $0.archivedAt > $1.archivedAt }.map {
                Item(id: $0.id.short, kind: ($0.kind ?? .file).rawValue, name: $0.name, was: $0.original, deleted: ISO8601DateFormatter().string(from: $0.archivedAt), days_left: ar.daysLeft($0), bytes: $0.bytes)
            })
        case "restore_from_archive":
            let e = try AppArchive.shared.entry(matching: try req("item"))
            let url = try AppArchive.shared.restore(e.id)
            return message("Restored \(e.name) to \(url.path)")
        default: break
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
            let askedY = try d("y") ?? CaptionPresets.resolve(s("preset")).y
            var font: ToolExecutor.FontChoice?
            if let f = s("font") { font = try await FontLibrary.shared.resolve(f) }
            let t = try x.addText(try req("text"), start: try reqNum("start"), duration: try reqNum("duration"), fontSize: d("font_size"), colorHex: s("color"), x: d("x"), y: d("y"), preset: s("preset"), font: font)
            let moved = abs(t.y - askedY) > 0.001 ? " (moved to y \(String(format: "%.2f", t.y)) so it does not cover another text on screen at the same time)" : ""
            return message("Added text \(t.id.short) from \(t.start)s to \(t.end)s\(moved)")
        case "set_text_style":
            var font: ToolExecutor.FontChoice?
            if let f = s("font") { font = try await FontLibrary.shared.resolve(f) }
            return try payload(try x.setTextStyle(try req("text"), font: font, fontSize: d("font_size"), color: s("color")))
        case "get_transcript":
            let page = try await x.getTranscript(asset: s("asset"), clip: s("clip"), language: s("language"), from: d("from"), to: d("to"),
                                                 firstWord: i("first_word"), maxWords: i("max_words"))
            return Payload(text: try transcriptText(page), value: try? Value(page))
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
            return try payload(try await x.exportVideo(to: try req("path"), preset: ExportService.Preset.parse(s("preset")), chapters: b("chapters")))
        case "add_track":
            return try payload(try x.addTrack(kind: try req("kind"), name: s("name")))
        case "rename_track":
            return try payload(try x.renameTrack(try req("track"), to: try req("name")))
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
        case "export_timeline":
            return try payload(try await x.exportTimeline(to: try req("path"), format: try Interchange.Format.parse(s("format"))))
        case "auto_reframe":
            return try payload(try await x.autoReframe(try req("clip"), mode: s("mode"), sampleInterval: d("sample_interval"), strength: d("strength")))
        case "stabilize_clip":
            return try payload(try await x.stabilizeClip(try req("clip"), strength: d("strength"), remove: b("remove")))
        // MARK: Color
        case "set_color_wheels":
            return try payload(try x.setColorWheels(try req("clip"), layer: s("layer"), wheel: try req("wheel"), r: d("r"), g: d("g"), b: d("b"), master: d("master"), toward: s("toward"), amount: d("amount"), reset: b("reset")))
        case "set_color_curve":
            guard let raw = a["points"]?.arrayValue else { throw MCPError.invalidParams("'points' is required: [[x, y], ...], or [] to remove the curve") }
            let pts = raw.map { $0.arrayValue?.compactMap { $0.doubleValue ?? $0.intValue.map(Double.init) } ?? [] }
            return try payload(try x.setColorCurve(try req("clip"), layer: s("layer"), curve: try req("curve"), points: pts))
        case "capture_scopes":
            let (png, summary) = try await x.captureScopes(at: try reqNum("seconds"), maxWidth: i("max_width") ?? 1200)
            let p = try payload(summary)
            return Payload(text: p.text, value: p.value, image: png)
        case "add_grade_layer":
            return try payload(try x.addGradeLayer(try req("clip"), name: s("name"), index: i("index"), mix: d("mix"), enabled: a["enabled"]?.boolValue))
        case "update_grade_layer":
            let ch = ToolExecutor.LayerColorChange(exposure: d("exposure"), contrast: d("contrast"), saturation: d("saturation"), temperature: d("temperature"), tint: d("tint"),
                                                   shadows: d("shadows"), midtones: d("midtones"), highlights: d("highlights"), vibrance: d("vibrance"), lookMix: d("look_mix"), look: s("look"), reset: b("reset"))
            return try payload(try x.updateGradeLayer(try req("clip"), layer: try req("layer"), name: s("name"), enabled: a["enabled"]?.boolValue, mix: d("mix"), color: ch))
        case "remove_grade_layer":
            return try payload(try x.removeGradeLayer(try req("clip"), layer: try req("layer")))
        case "move_grade_layer":
            guard let index = i("index") else { throw MCPError.invalidParams("'index' is required") }
            return try payload(try x.moveGradeLayer(try req("clip"), layer: try req("layer"), to: index))
        case "match_color":
            return try payload(try await x.matchColor(try req("clip"), reference: try req("reference"), clipSeconds: d("clip_seconds"), referenceSeconds: d("reference_seconds"), mix: d("mix")))
        case "set_clip_finish":
            var values: [String: Double] = [:]
            for r in ToolExecutor.finishRanges { if let v = d(r.arg) { values[r.arg] = v } }
            return try payload(try x.setClipFinish(try req("clip"), values: values, reset: b("reset")))
        case "set_layer_mask":
            var ch = ToolExecutor.MaskChange(clear: b("clear"), shape: s("shape"), shapeInvert: a["shape_invert"]?.boolValue, subject: s("subject"), subjectFeather: d("subject_feather"), invert: a["invert"]?.boolValue)
            for r in ToolExecutor.shapeRanges { if let v = d(r.arg) { ch.shapeValues[r.arg] = v } }
            for r in ToolExecutor.qualifierRanges { if let v = d(r.arg) { ch.qualifierValues[r.arg] = v } }
            if let q = s("qualifier") {
                guard q.lowercased() == "none" else { throw MCPError.invalidParams("qualifier only takes none (pass hue_center, sat_low... to set one)") }
                ch.qualifierOff = true
            }
            return try payload(try x.setLayerMask(try req("clip"), layer: try req("layer"), ch))
        case "capture_matte":
            let (png, result) = try await x.captureMatte(try req("clip"), layer: try req("layer"), at: d("seconds"), maxWidth: i("max_width") ?? 640)
            let p = try payload(result)
            return Payload(text: p.text, value: p.value, image: png)
        // MARK: Effects
        case "set_chroma_key":
            return try payload(try await x.setChromaKey(try req("clip"), color: s("color"), tolerance: d("tolerance"), softness: d("softness"), spill: d("spill"), shrink: d("shrink"), edgeBlur: d("edge_blur"), time: d("time"), remove: b("remove")))
        case "key_matte":
            let (r, png) = try await x.keyMatte(try req("clip"), time: d("time"), maxWidth: i("max_width") ?? 960)
            var p = try payload(r); p.image = png; return p
        case "set_blend_mode":
            return try payload(try x.setBlendMode(try req("clip"), mode: try req("mode")))
        case "blur_faces":
            let ints = { (k: String) -> [Int]? in a[k]?.arrayValue.map { $0.compactMap { $0.intValue ?? $0.doubleValue.map { Int($0) } } } }
            return try payload(try await x.blurFaces(try req("clip"), style: s("style"), strength: d("strength"), expand: d("expand"), feather: d("feather"), exclude: ints("exclude"), only: ints("only"), reanalyse: b("reanalyse"), remove: b("remove")))
        case "blur_region":
            return try payload(try await x.blurRegion(try req("clip"), x: d("x"), y: d("y"), width: d("width"), height: d("height"), start: d("start"), end: d("end"), track: b("track"), style: s("style"), strength: d("strength"), feather: d("feather"), remove: s("remove")))
        case "set_text_animation":
            return try payload(try x.setTextAnimation(try req("text"), inKind: s("in"), inDuration: d("in_duration"), outKind: s("out"), outDuration: d("out_duration")))
        case "add_lower_third":
            return try payload(try x.addLowerThird(name: try req("name"), role: s("role"), template: s("template"), start: d("start"), duration: d("duration"), x: d("x"), y: d("y"), accent: s("accent"), color: s("color"), fontSize: d("font_size"), inKind: s("in"), outKind: s("out"), text: s("text")))
        case "set_project_color":
            return try payload(try x.setProjectColor(try req("color")))
        // MARK: Audio
        case "set_clip_compressor":
            return try payload(try x.setClipCompressor(try req("clip"), enabled: a["enabled"]?.boolValue, threshold: d("threshold"), ratio: d("ratio"), attack: d("attack"), release: d("release"), knee: d("knee"), makeup: d("makeup")))
        case "set_clip_limiter":
            return try payload(try x.setClipLimiter(try req("clip"), enabled: a["enabled"]?.boolValue, ceiling: d("ceiling"), release: d("release"), lookahead: d("lookahead")))
        case "set_clip_deesser":
            return try payload(try x.setClipDeEsser(try req("clip"), enabled: a["enabled"]?.boolValue, amount: d("amount"), frequency: d("frequency")))
        case "set_clip_hum_removal":
            return try payload(try await x.setClipHumRemoval(try req("clip"), enabled: a["enabled"]?.boolValue, frequency: s("frequency") ?? d("frequency").map { String(Int($0)) }, amount: d("amount"), harmonics: i("harmonics")))
        case "set_clip_mix":
            return try payload(try await x.setClipMix(try req("clip"), gain: d("gain"), pan: d("pan")))
        case "set_audio_crossfade":
            return try payload(try x.setAudioCrossfade(try req("clip"), duration: d("duration"), curve: s("curve"), remove: b("remove")))
        case "set_track_mix":
            return try payload(try await x.setTrackMix(try req("track"), gain: d("gain"), pan: d("pan"), solo: a["solo"]?.boolValue, mute: a["mute"]?.boolValue, bus: s("bus")))
        case "set_bus":
            return try payload(try x.setBus(try req("bus"), rename: s("rename"), gain: d("gain"), mute: a["mute"]?.boolValue, compressor: try numbers(a["compressor"], "compressor"), removeCompressor: b("remove_compressor"),
                                            limiter: try numbers(a["limiter"], "limiter"), removeLimiter: b("remove_limiter"), remove: b("remove")))
        case "set_master":
            return try payload(try x.setMaster(gain: d("gain"), limiter: try numbers(a["limiter"], "limiter"), removeLimiter: b("remove_limiter")))
        case "inspect_mix":
            return try payload(x.inspectMix())
        case "measure_loudness":
            return try payload(try await x.measureLoudness(clip: s("clip")))
        case "normalize_loudness":
            return try payload(try await x.normalizeLoudness(target: s("target") ?? d("target").map { String($0) }, ceiling: d("ceiling"), clip: s("clip")))
        // MARK: Editing
        case "roll_edit":
            return try payload(try x.rollEdit(try req("clip"), edge: s("edge"), delta: d("delta"), to: d("to")))
        case "slip_clip":
            return try payload(try x.slipClip(try req("clip"), delta: d("delta"), sourceIn: d("source_in")))
        case "slide_clip":
            return try payload(try x.slideClip(try req("clip"), delta: d("delta"), to: d("to")))
        case "set_split_edit":
            return try payload(try x.setSplitEdit(try req("clip"), lead: d("lead"), trail: d("trail"), neighbour: s("neighbour")))
        case "relink_media":
            return try payload(try await x.relinkMedia(asset: s("asset"), path: s("path"), folder: s("folder"), recursive: a["recursive"]?.boolValue ?? true, dryRun: b("dry_run")))
        case "consolidate_media":
            return try payload(try await x.consolidateMedia(folder: s("folder"), dryRun: b("dry_run")))
        case "detect_scenes":
            return try payload(try await x.detectScenes(clip: s("clip"), asset: s("asset"), sensitivity: d("sensitivity"), minScene: d("min_scene"), action: s("action")))
        case "insert_edit", "overwrite_edit":
            return try payload(try x.pointEdit(overwrite: name == "overwrite_edit", asset: try req("asset"), sourceIn: d("source_in"), sourceOut: d("source_out"), timelineIn: d("timeline_in"), timelineOut: d("timeline_out"), track: s("track")))
        case "match_frame":
            return try payload(try x.matchFrame(clip: s("clip"), time: d("time")))
        case "set_smooth_slow_motion":
            return try payload(try await x.setSmoothSlowMotion(try req("clip"), mode: try req("mode"), wait: b("wait")))
        default: throw MCPError.methodNotFound("Unknown tool \(name)")
        }
    }
}
