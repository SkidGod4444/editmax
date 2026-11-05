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
        Tool(name: "list_history", description: "Named snapshots recorded before each edit (newest first), by user, agent or system.",
             inputSchema: schema(["limit": int("Max entries (default 50)"), "project": projectArg]), annotations: .init(readOnlyHint: true)),
        Tool(name: "restore_snapshot", description: "Restore the project to the state captured by a history snapshot. The current state is snapshotted first, so this is always reversible.",
             inputSchema: schema(["snapshot": str("Snapshot id prefix from list_history"), "project": projectArg], required: ["snapshot"])),
        Tool(name: "set_playhead", description: "Move the playhead in the user's window to a time, optionally start playback. Use it to show the user a moment you are talking about.",
             inputSchema: schema(["seconds": num("Timeline time"), "play": .object(["type": "boolean", "description": "Start playing from there (default false)"]), "project": projectArg], required: ["seconds"])),
        Tool(name: "capture_frame", description: "Render the frame at a timeline time as a PNG image so you can see what the viewer sees (video, images and text).",
             inputSchema: schema(["seconds": num("Timeline time"), "max_width": int("Image width in pixels (default 960)"), "project": projectArg], required: ["seconds"]), annotations: .init(readOnlyHint: true)),
        Tool(name: "export_video", description: "Render the whole timeline to an H.264/AAC MP4 at the project resolution. Blocks until done; expect roughly real time or faster.",
             inputSchema: schema(["path": str("Absolute output path ending in .mp4"), "preset": str("high (default), medium (720p) or low (480p)"), "project": projectArg], required: ["path"])),
        Tool(name: "add_track", description: "Add a video or audio track. New tracks go to the bottom row; the top row covers the rows below it in the picture.",
             inputSchema: schema(["kind": str("video or audio"), "name": str("Optional name (default V2, A2…)"), "project": projectArg], required: ["kind"])),
        Tool(name: "move_track", description: "Move a track to another row (0 = top). The top row covers the rows below it in the picture.",
             inputSchema: schema(["track": str("Track name or id prefix"), "row": int("Target row, 0 = top"), "project": projectArg], required: ["track", "row"])),
        Tool(name: "set_project_settings", description: "Change output resolution, frame rate or project name.",
             inputSchema: schema(["width": int("Pixels"), "height": int("Pixels"), "fps": num("Frames per second"), "name": str("Project name"), "project": projectArg])),
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
            let preset = ExportService.Preset.allCases.first { $0.rawValue.lowercased().hasPrefix((s("preset") ?? "high").lowercased()) } ?? .high
            return try payload(try await x.exportVideo(to: try req("path"), preset: preset))
        case "add_track":
            return try payload(try x.addTrack(kind: try req("kind"), name: s("name")))
        case "move_track":
            return try payload(try x.moveTrack(try req("track"), toRow: Int(try reqNum("row"))))
        case "set_project_settings":
            try x.setProjectSettings(width: i("width"), height: i("height"), fps: d("fps"), name: s("name")); return message("Settings updated")
        default: throw MCPError.methodNotFound("Unknown tool \(name)")
        }
    }
}
