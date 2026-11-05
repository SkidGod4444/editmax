# EditMax

<img src="docs/icon-256.png" width="128" align="right" alt="EditMax icon">

Native macOS AI video editor (Swift / SwiftUI / AVFoundation). Working name chosen 2026-11-05.

Inspired by Palmier Pro's architecture (an editor that exposes itself to coding agents over a local MCP server),
with these deliberate differences:

- **Agent-agnostic, no bundled runtime.** Palmier ships a 143 MB OpenCode binary and needs an account.
  EditMax exposes its tools over MCP to any client (Claude Code, Codex, Cursor, Claude Desktop) and has an
  in-app chat that drives the coding agents you already use (Claude Code, Codex, OpenCode, Cursor, Grok,
  Antigravity) through the bundled `codemax` runtime, with their own logins. An Anthropic API key is optional.
  No account, no backend.
- **Labeled snapshot before every edit**, by user or agent, with one-click restore (History tab and
  `restore_snapshot` tool). Restoring is itself an edit, so nothing is ever lost.
- **Loopback-only MCP server with a bearer token.** Any process on the Mac cannot drive the editor without the token.
- **Agents can see the picture.** `capture_frame` returns a PNG of any timeline moment; `set_playhead` shows the user.

## Status (2026-11-05)

Working:
- Document model (`.editmax` JSON), multi-window, media panel with import; drag media (or Finder files) onto a timeline lane to place a clip at that time, double-click to append
- Timeline: video/audio tracks, clip move/split/trim/delete, speed, volume, opacity, close gaps, text overlays
- Undo/redo (⌘Z, ⇧⌘Z, toolbar arrows) over every edit, the agent's included; the History tab stays the full log with restore points
- Picture: EditMax's own compositor (`EditMax/Engine/Compositor.swift`, Core Image on the GPU) draws every frame of the preview, the export
  and `capture_frame`, so what plays is what exports. Per clip: transform (scale, position, rotation, crop), color (exposure, contrast,
  saturation, temperature, tint), fades in/out (picture and sound), transitions into a clip (cross dissolve, dip to black, wipes; the
  outgoing clip plays on underneath, so it needs media past its out point), stills on video tracks, titles. Each project track has A/B
  composition tracks so transitions can overlap. No color management: an ungraded frame exports with the source's pixel values.
- Timeline: snapping to clip and text edges, markers, in/out points and the playhead (⌥ drags free); ⇧/⌘-click multi-select with group
  move; markers (M) on the ruler; in/out points (I, O, X) with "Delete range" (ripples every track); transition and fade marks on clips
- Keyframes: every transform, color, opacity, volume and speed value can be animated. The diamond next to a slider adds a keyframe
  at the playhead (the first one starts the animation from the plain value); once animated, dragging the slider writes a keyframe.
  Linear, smooth (ease in/out) and hold easing; `[` and `]` jump between keyframes; yellow diamonds on the clip bar. Speed keyframes
  are a speed ramp (0× = freeze frame); the clip's media use is the exact integral of the ramp, played as short constant-rate pieces.
  Tools: `set_keyframe`, `remove_keyframe`; `inspect_timeline` lists keyframes per clip on timeline times.
- Color: besides exposure/contrast/saturation/temperature/tint, a five-point tone curve (shadows, midtones, highlights), vibrance,
  and looks: six built-in LUTs generated in code (Teal & Orange, Black & White, Film Fade, Cool Blue, Warm Vintage, High Contrast)
  or any `.cube` 3D LUT (bigger than Core Image's limit = resampled), blended by a mix amount; all keyframeable. Scopes (luma
  waveform + RGB histogram of the frame on screen) toggle from the preview's corner button; `frame_stats` gives the agent the same
  numbers (mean RGB, luma mean/median, crushed-black and clipped-white fractions, histogram).
- Audio: per-clip three-band EQ (200 Hz / 1 kHz / 6 kHz), high-pass and noise gate through an `MTAudioProcessingTap`
  (`EditMax/Engine/AudioTap.swift`, only attached when a clip asks for it); automatic ducking of one track under another's
  clips with attack/release (Project inspector → Ducking, `set_ducking`); clip volume is one envelope per clip (keyframes ×
  fades × transition crossfade × ducking) emitted as back-to-back ramps. Audio-only timelines export.
- Log footage (DJI D-Log, S-Log, V-Log…): `set_clip_color input_lut` (inspector: Look → Input LUT) takes the camera's
  conversion `.cube` and applies it before every other control at full strength, so exposure and the tone curve work on
  a Rec.709 image; the creative look still runs last. Sources are decoded to 16-bit half floats
  (`kCVPixelFormatType_64RGBAHalf`), so 10-bit footage keeps its precision through the LUT: on a 10-bit ramp stretched
  ×6 the exported staircase matches the ideal (RMS 0.95 vs 0.93, max step 2) where the 8-bit decode had steps of 9.
  Versions: the History tab lists every edit as a version (newest first, the project as it was *after* that edit, with a
  line saying what changed: "red.mp4: color: exposure 0 → 2"). Click a row to see that version in the preview (an orange
  banner marks it; any edit returns to the live project), Restore to make it current again (itself an edit, so nothing is
  lost); the bottom row is the original. The MCP `list_history` entries carry the same `changes` line; they are the
  "before" snapshots, so to return to the state after an edit, restore the entry just above it.
  Chat replies render Markdown (headings, lists, tables, code). Agent-harness errors are reworded for the person editing
  ("The agent stopped before finishing its last step…"); the raw text stays in the debug log.
  The agent's system prompt (`ChatSession.agentInstructions`) makes it an expert editor: method, cutting, color order
  (conversion LUT first, creative look last), sound, captions, delivery, and the honest list of what EditMax cannot do.
  Focus layout: the ▯▯ button on the preview or ⌥⌘F hides the media list, inspector and timeline and shows just the player
  (with a transport bar: play/pause, frame steps, scrubber) beside the chat, for directing the agent while watching. Same
  button, "Back to editor" or ⌥⌘F returns.
  Full-screen preview: the ⤢ button on the preview, ⇧⌘F, or double-click the picture; Esc, double-click or ⇧⌘F leaves.
  It is a borderless window on the editor's screen showing the same player, so play/scrub/edits stay live. A transport
  bar (play/pause, scrubber, time, leave) sits at the bottom and hides 2.5 s after the mouse rests; the editor's keys
  (space, J/K/L, arrows, I/O) work there too.
  Switching the chat between Agent and API key keeps the transcript on screen; the first message after the switch carries
  a digest of the earlier user/assistant turns (not tool output) so the new session can carry on.
  Tested with DJI's official D-Log to Rec.709 cube on DJI's Inspire 3 D-Log sample (ProRes HQ and a 10-bit HEVC
  Main 10 transcode of it): EditMax's export matches ffmpeg's `lut3d` within 5 levels. DJI's cubes use tabs after
  `LUT_3D_SIZE` and CR line ends; the parser accepts any whitespace and Latin-1 text.
  10-bit delivery: `export_video preset: hevc10` (export panel: Format → HEVC 10-bit) writes HEVC Main 10, 4:2:0,
  `hvc1`, Rec.709 tags, at about 0.25 bits per pixel per frame (1080p30 ≈ 15 Mb/s ceiling; simple content comes out
  far smaller), through `AVAssetReader` + `AVAssetWriter` with `EditMaxCompositor10` (16-bit half-float frames). The
  audio mix (volume keyframes, ducking, EQ/gate taps) is rendered by `AVAssetReaderAudioMixOutput` to AAC 192 kb/s.
  Limits: SDR only (no HLG/PQ transfer tags, no D-Gamut), MP4 container only, proxies are 8-bit so the preview with
  proxies on can band where the export does not, and untagged 8-bit sources shift by up to 2 levels on saturated colors
  versus the old BGRA decode (VideoToolbox rounds the two conversions differently).
- App icon: `EditMax/Resources/AppIcon.svg` is the source (a play triangle cut into three beveled metal strips on a
  dark plate whose shape, corner curve and shadow come from a real macOS app icon's alpha mask, `scripts/icon/plate_mask.raw`,
  so it sits level with Apple's icons; `scripts/icon/build_svg.py` rebuilds the SVG). `scripts/make-icon.sh`
  renders it with headless Chrome and rebuilds `EditMax/Resources/AppIcon.icns` (`CFBundleIconFile` in `project.yml`),
  `EditMax/Resources/ProjectDoc.icns` (the `.editmax` document icon from `scripts/icon/doc.html`, `CFBundleTypeIconFile` /
  `UTTypeIconFile`) and the README copies in `docs/`. The preview's empty state and the About panel use the same icon.
  Finder caches document icons per bundle version: after changing `ProjectDoc.icns`, bump `CFBundleVersion`, run
  `lsregister -f` on the built app, delete `$(getconf DARWIN_USER_CACHE_DIR)com.apple.iconservices` and
  `killall iconservicesagent`, or `.editmax` files keep the generic page icon.
- Signing: debug builds are signed with the Apple Development certificate pinned by hash in `project.yml`, so macOS keeps
  the Screen Recording and keychain grants across rebuilds (ad-hoc signing made every build a new app). On another Mac,
  replace the hash with one from `security find-identity -v -p codesigning` or with `"-"` for ad-hoc.
- Proxies: 960×540 copies of video files for smooth preview (`make_proxies`, Project inspector → Proxies); the export and
  `capture_frame` always use the originals. Templates: built-in formats (YouTube 16:9, Shorts 9:16, Square, 4K, Cinema, 4:5)
  and projects saved as templates in Application Support (`list_templates`, `apply_template`, `save_template`).
- Multicam: `make_multicam` folds clips of the same moment into one clip whose angles are lined up by audio
  (`AngleSync`, cross-correlation of the loudness envelopes; falls back to the timeline placement when the match is
  weak), `cut_angle` switches the picture at a time, the sound always comes from one angle (`set_multicam`), `flatten`
  turns it back into clips. The builder expands a multicam clip into one piece per cut (`Clip.multicamPieces`), so
  speed ramps, keyframes, transitions and fades on the clip keep working. Inspector: angle buttons cut at the playhead;
  timeline: numbered cut lines.
- Nested sequences: `nest_clips` folds clips into a sub-project (`Project.sequences`) rendered once per content hash
  into Application Support/EditMax/nested (`SequenceRenderer`); the clip plays that file, so grading, speed, fades,
  transitions and keyframes apply to the group; `unnest_clip` expands it back; `inspect_sequence` lists its contents.
  Sequence assets have kind `sequence` and get thumbnails and waveforms like video.
- Keys: Space, J/K/L shuttle (repeat to double, up to 8×), ←/→ frame (⇧ = 10), Home/End, S split, ⌫ delete, M, I/O/X, ⌘T transition,
  ⌘= / ⌘- zoom, ⌘Z / ⇧⌘Z. Letter keys never fire while a text field has the focus.
- Grouped inspectors: a clip shows its thumbnail, name, split/delete, timing and reset-able sliders; a text shows text, style, size, a color picker and position; the project inspector adds titles at the playhead. Right-click menus on media rows (add, reveal, remove), track headers (mute, hide, delete) and bars (split, show, style, delete); empty-state hints in the preview and timeline
- Live preview with AVPlayer + Core Animation overlays; frame stepping
- Export to H.264/AAC MP4 (`File > Export Video…`, ⌘E, or the `export_video` tool), verified with ffprobe
- MCP server on `http://127.0.0.1:19790/mcp` (port and token in `~/Library/Application Support/EditMax/mcp.json`), 56 tools
- Cleanup: remove silence (from the waveform) and filler words (from the transcript) with ripple deletes across every track
- Captions: on-device transcription with word timings (Apple SpeechAnalyzer on macOS 26+; SFSpeechRecognizer on macOS 15–25, on-device
  where the Mac has the model, else Apple's servers), six text presets, one click or one tool call
- Timeline: frame thumbnails and a waveform band in video clips, full waveforms in audio clips (peaks cached per file in
  `~/Library/Application Support/EditMax/waveforms/`), pinned track headers (drag one onto another to reorder, the Text lane too; the top video row covers the rows below it in the picture, as in other editors, and text always draws over the picture), lane grid, follows the playhead, add-track buttons, hide/mute per track
- Agents tab with copy-ready commands for Claude Code, Codex and generic JSON config
- Chat tab, two backends:
  - **Agent (default).** The bundled `codemax serve` runs the agent you pick (Claude Code, Codex, OpenCode, Cursor,
    Grok, Antigravity) over its interactive protocol with EditMax's MCP server as its only allowed tool source. No API
    key. Verified end to end with Claude Code and Codex (import, insert, title, playhead; shell and file writes refused).
  - **API key (optional).** EditMax's own sidecar (`agent/`, bundled as `editmax-agent`): the Claude Agent SDK driving
    the installed Claude Code (a key is optional there), or Claude / OpenAI / Google / xAI through the Vercel AI SDK.
    Keys per provider in the login keychain. Verified end to end with the Claude Agent SDK; the Vercel providers are
    verified with a mock model and up to the provider's 401 (no real key was available).
- codemax auto-update: the latest GitHub release is installed on its own after a health check, rolled back when it breaks
- Debug logs (`~/Library/Application Support/EditMax/logs/`) and “Export diagnostics…” in the Agents tab

Not yet built: keyframes (animated transform/color), speed ramps, LUTs, audio ducking, multicam, project templates,
asset copying into a project bundle (assets are referenced by path + security bookmark).

## Build

Requires Xcode 27 and `xcodegen` (`brew install xcodegen`). Re-run `xcodegen generate` after adding files.

```sh
scripts/vendor-codemax.sh   # builds ../codemax-cli with bun into Vendor/codemax (bundled by Xcode)
scripts/vendor-agent.sh     # builds agent/ (the API-key sidecar) with bun into Vendor/editmax-agent
xcodegen generate
xcodebuild -project EditMax.xcodeproj -scheme EditMax -configuration Debug \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build
open build/DerivedData/Build/Products/Debug/EditMax.app
```

## Connect an agent

Open the Agents tab in the inspector and copy the command for your client, for example:

```sh
claude mcp add --transport http editmax http://127.0.0.1:19790/mcp --header "Authorization: Bearer <token>"
```

Tools: `list_projects`, `inspect_timeline`, `list_assets`, `import_media`, `insert_clip`, `split_clip`, `move_clip`,
`trim_clip`, `remove_clips`, `set_clip_properties`, `close_gaps`, `add_text`, `remove_texts`, `list_history`,
`restore_snapshot`, `set_playhead`, `capture_frame`, `export_video`, `set_project_settings`, `get_transcript`, `add_captions`,
`remove_captions`, `detect_silence`, `remove_silence`, `remove_words`, `ripple_delete`, `add_track`, `move_track`, `ui_layout`,
`ui_drag`, `ui_click`, `ui_screenshot`.

## Driving the real UI

An agent can work the window itself, not only the model: `ui_layout` lists what is on screen with ids and window
coordinates (media rows, track headers and their mute/hide toggles, lanes, clip and text bars with their trim handles,
toolbar and inspector buttons, the ruler); `ui_drag` and `ui_click` post mouse events to EditMax's own window through the
app's event queue (`NSApp.postEvent`, so nothing can reach another app and the real cursor stays put; SwiftUI gestures need the active app, so when
EditMax is behind another app it is activated for that one gesture, keystrokes arriving meanwhile are dropped rather than
applied, and the previous app gets the focus straight back; macOS refuses that activation while another app is being used, and then
`ui_drag` applies the move or trim through the bar's own code, `ui_click` calls the bar's or media row's own tap code, and
`ui_key` hands the key to the editor's key handler, each saying so in its result; the driver never activates the app, so the user's focus is never taken; ⇧/⌘/⌥ go in `modifiers`); `ui_key` presses
Space, J/K/L, arrows, I/O/M/S/X, ⌫ and ⌘ chords; `ui_scroll` scrolls the inspector or a list; `ui_screenshot`
returns the window's own pixels as a PNG through ScreenCaptureKit, filtered to that one window (never the screen around
it; macOS asks for the Screen Recording permission once; without it the tool falls back to rendering the window's layer
tree, which misses some inspector controls, and says so). Verified: moving and trimming bars, dropping a media row on a lane, reordering
headers, clicking toolbar buttons. Views register themselves with `.uiFrame("id")` (`EditMax/MCP/UIDriver.swift`).

## Cleanup

Inspector → Cleanup, or the tools. `SilenceDetector` walks the cached waveform peaks (100/s) for runs under a threshold
(default −38 dB below the loudest peak), keeps 0.15 s of air on each side. A moment counts as silent only when every
audible clip playing there is quiet (at least 0.6 s of it), so a pause in the speech stays where music or a second voice
runs underneath; pass `clip` to cut one clip's own pauses instead. Hidden and muted tracks are not listened to (the inspector and the
tool result name them) but the ripple still cuts them, so mute deliberately before cleanup. `remove_words` takes the
transcript's word timings for fillers (um, uh, hmm, er…; pass your own list). Both end in `Project.rippleDelete`, which
removes the range from every track (splitting or trimming clips), drops text inside it and shifts later text, so a video
with a separate voice track stays in sync. `ripple_delete` exposes the same cut for any range. Do cleanup before captions.

## Captions

Inspector → Captions → pick a style → “Add captions”, or ask the agent. `Transcriber` runs Apple's on-device SpeechAnalyzer on macOS 26+
(the first run per language downloads its model, nothing is uploaded); on macOS 15–25 it falls back to SFSpeechRecognizer,
on-device when the Mac has that language's model and otherwise through Apple's speech servers one minute at a time (the
inspector says which; the system asks for the speech-recognition permission once). Either way it caches the words with timings on the
project per asset (`Project.transcripts`, saved with the file, left out of history snapshots). `Captioner` groups the words
into lines (per-preset word and character limits, pauses, sentence ends), maps them through each clip's trim and speed to
timeline seconds, and adds them as text overlays with a shared group id. Presets (`CaptionPresets`): title, subtitle
(translucent band), boxed, bold (uppercase, yellow, stroked), outline, minimal; one renderer draws preview, export and
`capture_frame`. Tools: `get_transcript`, `add_captions`, `remove_captions`; `add_text` takes a `preset` too.

## In-app chat

**Agent backend (default, no key).** EditMax ships `codemax` inside the app (`Contents/Resources/bin/codemax`) and runs
it as `codemax serve`, a terminal-free mode that speaks NDJSON over stdin/stdout. codemax drives the chosen agent over
the same interactive protocol it uses in a terminal (ACP for Claude Code, OpenCode, Cursor, Grok; the Codex app-server
for Codex), so every permission request still exists; EditMax's policy answers them: calls on the `editmax` MCP server
are allowed, file edits, shell commands and questions are refused. When an agent runs out of quota, codemax hands the
task to the next installed agent with a brief. The agent picker lists what is installed; the Agents tab shows the same.

First launch installs codemax for the terminal too: a copy at `~/Library/Application Support/EditMax/bin/codemax` and a
link at `~/.local/bin/codemax`, only when no `codemax` is already on your PATH (an existing one is never touched).
Claude Code's ACP adapter is fetched by `bunx` on first use, so the Claude agent needs `bun` on the Mac and internet the
first time. Debug: `EDITMAX_CODEMAX_LOG=/path/file` logs every line exchanged with codemax.

**API key backend (optional).** Chat tab → “API key”. Pick a provider, type a model id (empty = the provider's default)
and paste the key for that provider (key icon; stored in the login keychain; `ANTHROPIC_API_KEY` and friends in the
environment win). Providers, all through EditMax's bundled sidecar `editmax-agent` (source in `agent/`, a bun project
compiled with `bun build --compile`; it speaks the same NDJSON lines as `codemax serve`, so one Swift runner drives both):

- **Claude Agent SDK**: the installed Claude Code's own harness (`claude` on PATH), started with no built-in tools and
  only the `editmax` MCP server; a key bills the API, no key uses Claude Code's login.
- **Claude API, OpenAI, Google Gemini, xAI Grok**: the Vercel AI SDK with that provider's model, the `editmax` MCP tools
  pulled through `@ai-sdk/mcp`, a 40-step tool loop. Any model id the provider knows.

The policy is the same as for agents: only `editmax` tools, everything else refused. Keys reach the sidecar once per
session over stdin and are redacted from every log. `cd agent && bun test` runs the sidecar's tests (mock model).

**codemax updates.** `CodemaxUpdater` checks the latest codemax GitHub release at launch and every 12 hours and installs
it without asking: download `codemax-darwin-<arch>` into `~/Library/Application Support/EditMax/bin/`, verify the
`.sha256`, health-check it (`--version` must print the release's version, `serve` must answer `agents` within 20 s),
then swap it in, keeping the previous copy as `codemax.prev`. A release that fails the check is deleted and never
retried. After the swap, an updated copy earns strikes for a crash, for failing to start an installed agent (the
`configure` request), and for a turn that ends in a protocol error; a copy that never says ready, or two strikes within
ten minutes, is rolled back to the previous copy or the bundled one (every build ships its own codemax as the floor), and
the chat retries the agent with the restored copy, so one message recovers. Quota, login and "not installed" errors are
the user's, not codemax's, and never count. State in `bin/update-state.json`; “Check now” and the
status are in the Agents tab. Releases come from codemax's `release.yml` workflow (tag `vX.Y.Z` → binaries attached;
v0.1.21 was the first). Verified against the real releases: an app bundling 0.1.21 installed 0.1.22 from GitHub on
its own and chatted through it; a build that bundles 0.1.22 then took over and dropped the updated copy. Tests: `EDITMAX_UPDATE_URL=<json>
EDITMAX_UPDATE_NOW=1` point the updater at a local fake release.

**Debug logs.** `~/Library/Application Support/EditMax/logs/editmax.log` (NDJSON events: codemax and sidecar launches,
exits and crashes, installs, updates, MCP start) and `codemax-protocol.log` (every line exchanged with codemax and the
sidecar, prefixed `api` for the sidecar; tokens and keys redacted), 5 MB each with one rotation. The Agents tab's
“Export diagnostics…” zips both with codemax's own `~/.codemax/debug.log` and the versions to the Desktop for a bug
report; “Reveal logs” opens the folder. `EDITMAX_CODEMAX_LOG=/path/file` moves the protocol log.

## Layout

- `EditMax/Model` — `Project` (Codable timeline + history), `EditMaxDocument` (ReferenceFileDocument, `apply(label:origin:)` snapshots), `DocumentRegistry`
- `EditMax/Engine` — `ToolExecutor` (every edit, shared by UI, MCP and chat), `CompositionBuilder` (AVComposition + overlays), `PlayerController`, `ExportService`, `MediaImporter`
- `EditMax/MCP` — `MCPService` (MCP Swift SDK stateless HTTP transport + bearer auth), `HTTPListener` (NWListener HTTP/1.1), `EditMaxTools` (catalog + dispatch)
- `EditMax/Chat` — `CodemaxRunner` (NDJSON over `codemax serve`), `CodemaxInstaller` (first-launch install), `ClaudeAPI` (SSE client), `ChatSession`, `KeychainStore`
- `scripts/vendor-codemax.sh` — builds `../codemax-cli` with bun and places the binary in `Vendor/` (gitignored); the Xcode copy phase bundles it
- `EditMax/UI` — SwiftUI views

Naming note: editmax.app is an existing AI video tool and editmax.com is a resale domain.
Free at time of check: editmax.io, editmax.ai, editmax.dev, editmax.video, npm `editmax`.
