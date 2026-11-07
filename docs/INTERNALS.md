# EditMax internals

Notes for people working on the code. The [README](../README.md) covers what EditMax does and how to use it; this
file covers how it is built, the engine's rules, and the gotchas that cost time to find.

## Layout

| Directory | What lives there |
|---|---|
| `EditMax/Model` | `Project` (the Codable timeline plus its history), `EditMaxDocument` (`ReferenceFileDocument`; every mutation goes through `apply(label:origin:)`, which records a labeled snapshot), `DocumentRegistry` (open windows, Home hand-off) |
| `EditMax/Engine` | `ToolExecutor` (every edit, shared by the UI, the MCP server and the chat), `CompositionBuilder` + `Compositor` (AVComposition, Core Image on the GPU), `PlayerController`, `ExportService`, `MediaImporter`, `Captions`, `Cleanup`, `TranscriptEditing`, `Multicam`, `AutoReframe`, `Stabilizer`, `VoiceIsolation`, `Looks` (LUTs), `AudioTap`, `RenderCache` (proxies, nested sequences, templates), `Delivery`, `Interchange` (FCPXML, EDL) |
| `EditMax/MCP` | `MCPService` (MCP Swift SDK, stateless HTTP transport, bearer auth), `HTTPListener` (NWListener HTTP/1.1), `EditMaxTools` (catalog and dispatch), `UIDriver` (the `ui_*` tools) |
| `EditMax/Chat` | `CodemaxRunner` (NDJSON over `codemax serve`), `CodemaxInstaller`, `CodemaxUpdater`, `ChatSession`, `KeychainStore` |
| `EditMax/UI` | SwiftUI views; `Glass.swift` is the only place Liquid Glass APIs are called |
| `EditMax/App` | `EditMaxApp`, `AppDelegate` (`EditorState.swift`), `HomeWindow`, `ProjectLibrary`, `SplashScreen`, `AppSettings`, `AppUpdater` (Sparkle), `MenuBarIcon` + `MenuBarMenu` (the menu bar extra) |
| `agent/` | The API-key chat sidecar (Bun + TypeScript): Claude Agent SDK and Vercel AI SDK providers; compiled to `Vendor/editmax-agent` |
| `EditMaxTests/` | XCTest target hosted in the app, with a 2 s H.264 fixture |
| `scripts/` | `vendor-codemax.sh`, `vendor-agent.sh`, `make-icon.sh`, `icon/` |

## One implementation of every edit

`ToolExecutor` is the single implementation of every editing operation. The SwiftUI views, the MCP server and the
in-app chat all call it, so a human and an agent get identical behaviour, validation and history entries. Clips,
assets, tracks, texts and markers are addressed by name, by full UUID or by the first eight characters of one
(`UUID.short`), everywhere.

`EditMaxDocument.apply` snapshots the project before the change (the History tab's versions, capped at 200), pushes
an undo step (capped at 100) and bumps `revision`, which rebuilds the composition. Undo, redo and restore are
themselves recorded edits, so the History tab is a complete log. `coalesce: true` folds a run of same-labeled edits
within 1.5 s (a slider drag) into one undo step and one version. Analysis caches on the project (`transcripts`,
`motionPaths`) are left out of snapshots and kept across undo/redo/restore.

## Timeline rules

- A clip inserted at a time never stacks on another: it is a ripple insert across every track, like ripple delete.
  A clip under the time is split; every clip, text and marker from there on moves right. Appending (no time) goes
  after the last clip on the track.
- Inserting past the end of a source, placing audio-only media on a video track, moving a clip to a track of another
  kind, trimming before the source start and empty titles are refused with an error; nothing is silently clamped.
- New video tracks go in above the first audio track, so video stays above audio; the Text lane keeps its row.
  The top video row covers the rows below it in the picture; text always draws over the picture.
- `rippleDelete` removes a range from every track (splitting or trimming clips), drops text inside it and shifts
  later text and markers, so a separate voice track stays in sync.
- Transcripts are stored per asset and mapped through each clip's source offset and speed, so they stay valid after
  any ripple. `get_transcript` returns 2000 words a page (up to 10 000 with `max_words`): `firstWord` and `nextWord`
  are indices into all of the clip's or asset's words, the same ones `cut_transcript` takes, and `from`/`to` pick a
  stretch of time. An 18-hour talk is about 160 000 words, far more than one reply can hold.
- Texts never cover each other. `TextLayout` measures a text's box in the frame with the rasterizer's font and
  wrapping; a text added where another is already on screen moves to the nearest free band, below on a tie (the tool
  result and the inspector say so), `inspect_timeline` lists `textOverlaps` made by hand, the text inspector offers
  "Move clear", and the Text lane stacks concurrent bars into two sub-rows.

## Timeline drawing (long projects)

- The timeline is as wide as the project (18 h at 60 px/s is 3.9 million points), so nothing draws the full width.
  `TimelineViewport` holds the drawn span: the screen plus one screen either side, rounded out to 2048-pt tiles.
  Scrolling inside it changes nothing that SwiftUI observes; crossing a tile edge redraws once.
- The ruler, the grid, each clip's thumbnails and waveform and the trim/slip feedback draw only the part inside the
  drawn span, on the same grid as a full draw (ticks counted from 0, thumbnails from whole tiles, waveform columns
  from the clip start), so a slice is pixel-for-pixel the full picture. `LongTimelineTests` checks this.
- The playhead time (30 updates a second) is read only by the views that show it, through `PlayerReader`: the
  toolbar's play button and timecode, the playhead, the follow-the-playhead scroll and "Split at playhead". The
  timeline body itself never reads it, so a tick does not rebuild every clip.
- Measured at 18 h, 60 px/s: a playhead update went from 1.7 s to 37 ms (a 1-minute project: 38 ms); memory
  from about 3 GB to about 400 MB.
- Clips and texts get views only inside the drawn span, plus the selected ones (a drag keeps its bar). An 18-hour
  stream cut into 2000 clips cost 321 ms a playhead update before this, 48 ms after (one clip: 47 ms). Off-screen
  clips are therefore not in the UI driver's hidden list until the timeline scrolls to them.

## Picture and sound

EditMax's own compositor (`Compositor.swift`, Core Image on the GPU) draws every frame of the preview, the export and
`capture_frame`, so what plays is what exports. Each project track has A/B composition tracks so transitions can
overlap; the outgoing clip plays on underneath a transition, so it needs media past its out point (`set_transition`
reports when it does not).

Order of operations per clip: effects on the oriented source (face blur, then the green-screen key) → crop,
stabilization, transform → input (conversion) LUT at full strength → exposure, contrast, saturation, temperature,
tint, tone curve, vibrance → color wheels and curves → creative look (built-in or `.cube`, blended by mix) → grade
layers with their masks → finishing (noise reduction, sharpen, glow, vignette, grain) → opacity, fades and
transitions → blend mode onto the tracks below (`ColorPipeline.apply`, `Effects.composite`). Sources are decoded to
16-bit half floats (`kCVPixelFormatType_64RGBAHalf`), so 10-bit footage keeps its precision through the LUT. SDR
projects have no color management: an ungraded frame exports with the source's pixel values. HDR projects (HLG or
PQ, `set_project_color`) swap in HDR compositors (`ColorManagement.configure`); see [effects.md](effects.md#hdr).

Every feature added after the first release has its own page with the user view, the engine's design and its limits:
[color.md](color.md), [audio.md](audio.md), [editing.md](editing.md), [effects.md](effects.md). Read the page before
changing the feature. The rule they all keep: every new field decodes as "off", so a project saved before a feature
renders exactly as before (checked by rendering one project on the old and new code and comparing every pixel).

Keyframes: every transform, color, opacity, volume and speed value can be animated (linear, smooth, hold). Speed
keyframes are a speed ramp (0× = freeze); the clip's media use is the exact integral of the ramp, played as short
constant-rate pieces. A multicam clip is expanded into one piece per cut (`Clip.multicamPieces`) so ramps, keyframes,
transitions and fades keep working on it.

Audio: per-clip three-band EQ (200 Hz / 1 kHz / 6 kHz), high-pass, hum notches and noise gate, then de-esser,
compressor, gain, pan and limiter, then the track's strip (fader, pan, bus, master), all run through one
`MTAudioProcessingTap` per composition track (`AudioTap.swift`, `AudioMixPlan.attachTaps`), attached only when a clip
or the mixer asks for it. J/L-cut sounds go on lanes of their own (`SplitEditAudio`), one owner track per lane, with
that track's strip. Clip volume is one envelope per
clip (keyframes × fades × transition crossfade × ducking) emitted as back-to-back ramps. Voice isolation renders
Apple's on-device `AUSoundIsolation` over the asset once (cached in `Application Support/EditMax/isolated/`).

Loudness (`Loudness.measure`, used by measure and normalize) renders the mix as the export does and meters each buffer
as it is read (`Loudness.stream`); nothing is kept, so an 18-hour mix stays at a few MB instead of about 25 GB. A
reader that stops more than 0.1 s before the end of the sound throws `ShortRead`; `measure` reads once more, then
fails, so part of the sound is never reported as the whole. Hum detection reads only the minute it looks at
(`HumDetector.seconds`). Speed in an optimized build: metering 77 ns a frame, so about 4 min per 18 h plus decoding;
normalize measures 2 to 6 times. `render` still returns the whole mix as an array, for short spans and tests.

Masters (`ExportService.exportMaster`, `export_video preset: hevc10 | prores422hq | prores422 | prores4444`) go
through `AVAssetReader` + `AVAssetWriter` with `EditMaxCompositor10` (64RGBAHalf frames) at the project size, with
Rec.709 tags. HEVC Main 10: 4:2:0, `hvc1`, about 0.25 bits per pixel per frame, AAC sound, MP4. ProRes: `apch`, `apcn`
or `ap4h` (10-bit 4:2:2, 12-bit 4:4:4 for 4444) at Apple's own rates, no compression properties (VideoToolbox
refuses a bitrate for ProRes), 24-bit 48 kHz stereo PCM, QuickTime `.mov`. The container follows the preset:
`exportVideo` and `BatchExport` set the extension from `Preset.fileExtension`. HDR projects write Rec.2020 HLG or PQ
masters (PQ HEVC also carries mastering-display and light-level metadata; ProRes does not). Limits: proxies are 8-bit, and untagged 8-bit sources can shift by up to 2 levels on saturated colors versus an 8-bit decode.

Timeline export (`Interchange.swift`, `export_timeline`) writes an edit list, never pixels:
- FCPXML 1.10. The bottom video track is the primary storyline (gaps for holes, a `transition` that starts at the cut
  for each clip that dissolves in, as EditMax plays it: the outgoing clip's media past its out point fills it). Every
  other track is a connected `spine` anchored at sequence 0 on the first primary element (its `start`, since anchor
  offsets are in the parent's own time): video tracks on lanes 1, 2… (the top row highest), titles above them, audio
  tracks and detached multicam sound below 0. Times are whole frames at the project rate, as exact fractions
  (29.97 → `1001/30000s`). Asset starts come from the file's timecode track. A constant speed retimes the whole file
  with a two-point `timeMap` (handles stay usable); a ramp is sampled every half second. Volume → `adjust-volume`
  in dB, fades → `fadeIn`/`fadeOut` plus `adjust-blend` keyframes, transform → `adjust-transform` (FCP measures
  position in percent of the frame height with y up, and rotation counter-clockwise). Multicam is flattened to its
  cuts; nested sequences go as their rendered file. Captions go to an `.srt` beside it.
- CMX 3600 EDL of the bottom video track's picture, recorded from 01:00:00:00, non-drop. A dissolve is the outgoing
  clip's zero-length cut plus a `D` event; a constant speed adds an `M2` line; clip and file names go in comments.
- `Interchange.report` builds the result's `transferred` / `notTransferred` lists from the project itself (grades,
  LUTs, EQ, ducking, stabilization, other keyframes, crops, missing media…). The menu shows them in a sheet and the
  MCP tool returns them; keep them honest when adding a feature to either side.

Checked: both sample files in `InterchangeTests` validate against Apple's FCPXML 1.10 DTD (not in the repo: run the
tests with `TEST_RUNNER_EDITMAX_FCPXML_DTD=<path>` to turn the check on), and ffprobe reads the ProRes settings back
as `apch`/`ap4h` with `pcm_s24le`. Not yet checked: an import into DaVinci Resolve or Final Cut Pro.

Tested against DJI's official D-Log → Rec.709 cube on DJI's Inspire 3 sample (ProRes HQ and a 10-bit HEVC transcode):
the export matches ffmpeg's `lut3d` within 5 levels. DJI's cubes use tabs and CR line ends; the parser accepts any
whitespace and Latin-1 text.

## Cleanup and captions

`SilenceDetector` walks the cached waveform peaks (100/s) for runs under a threshold (default −38 dB below the loudest
peak) and keeps 0.15 s of air on each side. A moment is silent only when every audible clip playing there is quiet
for at least 0.6 s, so a pause in the speech stays where music runs underneath. Hidden and muted tracks are not
listened to but the ripple still cuts them; the tool result names them.

`Transcriber` runs Apple's on-device SpeechAnalyzer on macOS 26+ (the first run per language downloads its model) and
falls back to `SFSpeechRecognizer` on macOS 15–25 (on-device when the Mac has the model, otherwise Apple's servers one
minute at a time; the inspector says which). Words with timings are cached per asset on the project. `Captioner`
groups words into lines (per-preset word and character limits, pauses, sentence ends) and adds them as text overlays
with a shared group id. One renderer draws preview, export and `capture_frame`.

## File format

Projects are `.emx` (JSON; the older `.editmax` extension still opens). `formatVersion` is 2 (unchanged by the color,
audio, editing and effects features, whose fields all decode with defaults); files without it are
format 1, whose renderer drew tint the wrong way round, so on open every tint value, keyframe and history snapshot is
negated and the picture is unchanged. Every model field decodes with a default, so old files always open. Assets are
referenced by path plus a security-scoped bookmark, not copied.

The type is declared in `project.yml` (`io.openhorizon.editmax.project`). Opening goes through `NSDocumentController`,
which resolves the type from LaunchServices: a Mac whose database still holds an older EditMax build says "EditMax
cannot open files of this type" until that build is unregistered (`lsregister -u <old app>` then `lsregister -f <this
app>`; the tool is in `LaunchServices.framework/Support/`).

## The MCP server and the UI driver

`MCPService` listens on `127.0.0.1` only (`mcpPort`, default 19790) and requires `Authorization: Bearer <token>`; the
token is generated once and written with the port to `~/Library/Application Support/EditMax/mcp.json`. The transport is
the MCP Swift SDK's stateless HTTP transport, so any number of clients can share it. A call with an argument name the
tool does not declare is rejected with the list of names it takes; nothing is silently ignored.

The `ui_*` tools work the window itself (`UIDriver.swift`). Views mark themselves with `.uiFrame("area.name")`,
`.uiTap(id)` and `.uiDrag(id)`; each puts a zero-size AppKit probe (`UIProbeView`) behind the view. The registry keeps
weak references to the live probes and asks them at the moment of a call, so nothing it answers can be stale: a view
that is gone has no probe, a moved view is where its probe is now, and a tap or drag closure is the one from the view's
latest update (SwiftUI calls `updateNSView` on every redraw because a closure never compares equal). Call sites need no
`key:` to re-register; the argument is still accepted and ignored. Before this, a reordered grade-layer list ran the old
row's closure and deleted the wrong layer, removed track headers stayed registered, and frames lagged a move behind.

Frames are window points with the origin at the top-left of the editor window's content. Only what a user can see is
an element: the probe's rect clipped by every scroll view and clipping ancestor and by the window. A control scrolled
out of view is listed under `hidden` in `ui_layout` (and `ui_scroll {target: id}` with no dx/dy scrolls it into view);
a probe SwiftUI keeps hidden for reuse is not listed at all. Popovers and sheets are windows attached to the editor:
their elements are reported in the editor's points with `"window": "popover"`/`"sheet"`, and a click is posted to the
window that draws the element, at that window's own coordinates. `ui_click` and `ui_drag` fail, saying why, rather
than post a click that cannot land (an element scrolled away, a point outside the window). Not detected: a control
covered by another SwiftUI view in the same hosting view (the history banner under the preview buttons).

Events go through the app's own event queue (`NSApp.postEvent`) to EditMax's own windows, so nothing reaches another
app and the real cursor stays put. The driver never activates EditMax. SwiftUI gestures need the active app, so in the
background a click or drag calls the control's own `.uiTap`/`.uiDrag` handler when it has one and says so; plain
controls take posted events (`acceptsFirstMouse` is taught to the hosting view, the popover's included).

Menus: an open menu runs its own event loop and brings EditMax to the front. On macOS 26 a SwiftUI `Picker` (menu
style) or `Menu` has no `NSPopUpButton` behind it; on mouse-down it builds an NSMenu and pops it up through
`-[NSMenu _popUpMenuRelativeToRect:inView:width:flags:selectedItemIndexProvider:]`. `MenuCapture` replaces NSMenu's
pop-up methods for the length of one driver gesture with one that records the menu and shows nothing, then puts them
back (a menu that still starts tracking is closed at once). `ui_select {target, option}` presses the control that way
and runs the chosen item (`performActionForItem`), sets an AppKit `NSPopUpButton` or `NSSegmentedControl` directly,
and with no option lists the choices. In the background `ui_click` on a picker turns the caught menu into an error that
points at `ui_select` and lists the options. (A SwiftUI segmented picker bound to an `@Published` value logs SwiftUI's
"Publishing changes from within view updates" for a real click too; it is not the driver's.)

Keys: while a text field (an `NSTextView`, field editors included) is first responder, keys without ⌘ go to it with
`keyDown`, as for a user, and never to the editor's key handler (typing `r` in the media search once switched the tool
to Roll). Otherwise a key goes to the editor's handler (`UIRegistry.keyHandler`, set by `KeyMonitorView`), then the
window's own key equivalents (a default button, a SwiftUI `.keyboardShortcut`), then the focused control. A key without
⌘, ⌃ or ⌥ never reaches the menu bar (a plain `e` once ran Edit ▸ Emoji & Symbols, whose shortcut is fn-E); a ⌘ chord
does (posted when EditMax is active, `performKeyEquivalent` on the main menu when not).

`ui_screenshot` never asks for Screen Recording (a debug build is re-signed on every build, so macOS would forget the
grant). With it, only the editor window itself is captured (`desktopIndependentWindow`), never the display, not even
filtered to EditMax's windows: a display capture once photographed another app. A popover or sheet is in the picture
only when macOS draws it with the window, and the answer says when one is attached. Menus and other EditMax windows over it are
left out: captured one by one, a menu came back as a shrunken copy of the whole window. Without the permission, or when
capture fails, the layer tree is rendered and the answer carries the real reason (only a missing permission is called
one).

Things learned driving it: a single click on a Home card selects it, a double click opens; SwiftUI sliders ignore
posted events (use the `set_clip_*` tools); Form toggles take the click at their right edge; a window that was never
ordered in gets no posted events (tests order theirs in far off every display). A new SwiftUI drag gesture needs a
`.uiDrag(id)` handler (and a tap a `.uiTap`), or `ui_drag` can only report the fallback.

### Follow the agent

Every tool call goes through `AgentFollowDriver.run` (`MCP/FollowPlans.swift`). `FollowPlans.plans` says where each
tool's edit lands: the clip, text or project it selects, the inspector card (`InspectorAnchor`), a grade layer, a time
for the playhead, the mixer. `FollowPlans.none` lists the tools that change nothing worth following (reads, captures,
exports, the `ui_*` tools); `FollowPlansTests` fails on a tool in neither list. Before the edit the window moves
(`FollowUI.apply`, registered per window in `EditorRootView`) and waits 280 ms if it is on screen; the edit then runs
through `ToolExecutor` as before, animated (`EditMaxDocument.animateAgentEdits`, agent edits only); what the call
created is selected after. Cards opt in with `.revealAnchor(...)`; `RevealScroller` scrolls the inspector to the card
and outlines it for 1.6 s. Reveal state is a separate `RevealState` in the environment, so a card drawn on its own (the
tests do) needs nothing.

It stands aside while the user works: real mouse, key and scroll events (not the driver's own) set
`AgentFollow.lastUserInput`, and for 2.5 s after one, or while a button is held, edits apply without moving the window.
It never switches away from the Chat tab (the user chose to watch the conversation). In the focus layout (only the
player and the chat) only the playhead follows: no selection, inspector or mixer change waits for the user when focus
ends. It never moves a playing playhead, and is off in tests.
`ui_screenshot` waits for an edit's animation to finish. Settings ▸ Assistant has the switch (`followAgent`).

## UI conventions

- Every clickable gets `.pointer()` for the hand cursor, written inside `.disabled(...)` as `.pointer().disabled(x)`
  so a disabled control shows the not-allowed cursor, and a `.uiFrame("area.name")` id.
- Plain-style and icon buttons in bars and overlays get `.focusable(false)`.
- Sliders and continuous edits coalesce into one undo step.
- Menu items never gate on `@FocusedObject` state (the focused document goes nil whenever the editor window is not
  key); gate in the notification receiver instead.
- Liquid Glass only through `Glass.swift` (`liquidGlass`, `GlassGroup`, `glassButtonStyle`, `Color.glassSelection`,
  `BehindWindowMaterial`): real `glassEffect` on macOS 26, a material before it. Glass is used on the control layer
  only (toolbar, preview overlays, HUDs, transport pills, tab strips, chat input, Home chips); panels, inspectors, the
  timeline and lists stay opaque. The Settings window uses standard controls, no glass. `-noglass` on the command line
  forces the pre-26 path on any Mac.
- User-facing text says "agent runtime", never the runtime's internal name.
- Home is an `NSSplitViewController` whose sidebar is an `NSSplitViewItem(sidebarWithViewController:)` and whose
  window is non-opaque with a `.underWindowBackground` material behind the projects pane. It hides when a project
  opens and comes back when the last project window closes (`DocumentRegistry`), keeping its frame.

## Launch and the splash

The splash is the app icon on a Liquid Glass card, 2.2 s of pure SwiftUI motion (fades only with Reduce Motion). It
stays at least 2.2 s (5 s at most) and fades once the MCP server is listening; restored document windows are kept out
of sight meanwhile. It shows only for a launch that activated the app; a background launch (`open -g`) gets none.
Flags: `-nosplash`, `-splash-preview`, `-splash-loop`, `-splash-t <seconds>` (freeze at that moment), `-splash-render
<png>`.

A launch with nothing to restore goes to Home. `AppDelegate` answers `applicationShowsOpenPanelInsteadOfUntitledFile:`
with no and handles `applicationOpenUntitledFile` by showing Home; the empty untitled document `DocumentGroup` makes
at launch is closed 0.3 s in. Under XCTest (`AppDelegate.isTesting`) none of this runs.

## Chat backends

**Agent (default).** `codemax serve` speaks NDJSON over stdin/stdout and drives the chosen agent over its own
interactive protocol (ACP for Claude Code, OpenCode, Cursor, Grok; the Codex app-server for Codex). EditMax's policy
answers every permission request: calls on the `editmax` MCP server are allowed; file edits, shell commands and
questions are refused. First launch installs the runtime for the terminal too (`~/Library/Application
Support/EditMax/bin/codemax`, linked from `~/.local/bin`) only when none is on the PATH. Claude Code's ACP adapter is
fetched by `bunx` on first use, so that agent needs `bun` and internet the first time.

**API key.** The sidecar in `agent/` speaks the same NDJSON lines, so one Swift runner drives both. Providers: the
Claude Agent SDK (the installed Claude Code harness with only the `editmax` MCP server; it always runs on an
Anthropic API key, never on a Claude subscription login, which Anthropic's terms do not allow for apps built on the SDK:
the sidecar refuses to start it without a key, drops `CLAUDE_CODE_OAUTH_TOKEN` from its environment, and the app
treats its key as required whatever the sidecar reports; the Agent backend is the way to use a subscription) and Claude / OpenAI / Google / xAI through the Vercel AI SDK with the MCP tools pulled through
`@ai-sdk/mcp`, a 40-step tool loop. Keys live in the login keychain, reach the sidecar once per session over stdin
and are redacted from every log. Switching backends keeps the transcript; the first message after a switch carries a
digest of the earlier turns.

**Runtime updates.** `CodemaxUpdater` checks the runtime's latest GitHub release at launch and every 12 hours:
download `codemax-darwin-<arch>`, verify `.sha256`, health-check (`--version` and a `serve` handshake within 20 s),
swap it in and keep the previous copy. A copy that never says ready, or earns two strikes within ten minutes (crash,
failed agent start, protocol error), is rolled back to the previous or the bundled one and the chat retries. State in
`bin/update-state.json`. `EDITMAX_UPDATE_URL=<json> EDITMAX_UPDATE_NOW=1` point it at a local fake release.

## Releases

`scripts/release.sh 0.2.0` cuts a release on a Mac; nothing is built on GitHub. It reads `SIGN_IDENTITY` and
`NOTARY_PROFILE` from the environment or a git-ignored `.release.env`, requires a clean `main` in sync with
`origin/main`, runs `scripts/package.sh` with the version and a build number (the commit count), and stops unless
`build/release/notarized` exists. Then it stamps the version into `project.yml`, commits, tags `v0.2.0`, pushes, and
publishes a GitHub release with `EditMax-<version>.dmg`, `EditMax-<version>.zip`, `SHA256SUMS` and `appcast.xml`,
with notes generated from the commits. The website's Download button hands out the latest release, which is why an
unnotarized build is never published.

App updates (`AppUpdater`, Sparkle 2.10.1). `SUFeedURL` is `releases/latest/download/appcast.xml`, which GitHub
redirects to the newest release's asset, so a release without `appcast.xml` would break updates for everyone:
`release.sh` writes it (one item: the zip, `sparkle:version` = the build number, which Sparkle compares, signed with
`sign_update --account editmax`) and fails rather than publish without it. `SUPublicEDKey` in `project.yml` is the
public half of the key in the login keychain (backed up outside the repo, in `~/.editmax-sparkle`); a lost key means a
key rotation before any installed copy can update again. Defaults: daily checks (`SUEnableAutomaticChecks`) and
background download with install on quit (`SUAutomaticallyUpdate`); Settings ▸ General binds to the updater's own
`automaticallyChecksForUpdates` / `automaticallyDownloadsUpdates`. When a background download is ready, Sparkle calls
`updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` on `AppUpdaterDelegate`, which returns true and hands
the block to `UpdatePrompt`: a glass popup (a borderless `NSPanel` that never becomes key and has no Return shortcut,
so typing is never taken over; it hides while EditMax is in the background, waits for it to come to the front, and
waits while `BusyWork` counts an export or an agent reply, even after Install Now is clicked) with Install Now (autosaves every open project, then calls the block: quit, install,
relaunch) and Remind Me Later: a 60 s tick shows the popup again once 2 h have passed while EditMax is active, or posts
a `UNUserNotification` (category with an Install Now action; `UpdateNotifications`, permission asked at the first Later)
once 6 h have passed while it is not; install on quit still stands. The offered version is kept in `EditMaxUpdateOffered`;
the first activation on that version shows an "installed" card after the splash; an activation still on an older
version (the quit did not install it) calls `checkForUpdatesInBackground()` so Sparkle resumes the download and the
popup returns. `SparkleInstallTests` (opt-in,
`TEST_RUNNER_EDITMAX_SPARKLE_TEST=1`, run from a derived-data folder outside `~/Desktop`: TCC blocks launchd's
`Autoupdate` there) installs a signed 2.0 of a stand-in app from a local feed through the real Sparkle and Install Now. Debug builds show it with
`-EditMaxUpdatePromptDemo YES`. The updater does not start in Debug builds (they
would "update" to the release) or under XCTest; `EDITMAX_UPDATES=1` starts it in a Debug build. `package.sh` signs
Sparkle's `Installer.xpc`, `Downloader.xpc` (keeping its entitlements), `Autoupdate` and `Updater.app` before the
framework and the app, and ships Sparkle's MIT text as `Licenses/Sparkle-LICENSE`.

Quitting during an export: `AppDelegate.applicationShouldTerminate` asks `QuitGuard`, which quits at once unless
`BusyWork` counts an export (`ExportService.export` / `exportMaster`, so agent exports too). Then an `NSAlert`: Quit When
Done returns `.terminateCancel` and polls every 0.5 s until no export runs, then calls `NSApp.terminate` again (the export
pill shows "EditMax quits when it's done" with Don't Quit); Keep Working cancels; Quit Now quits and the export stops.

The menu bar extra is a SwiftUI `MenuBarExtra` (`.menu` style) bound to `@AppStorage("showMenuBarIcon")`. Its icon is
drawn in code (`MenuBarIcon`, a template image of the app icon's striped triangle with wider gaps) so it follows the
menu bar's light, dark and highlighted states.

`package.sh` builds the Release configuration unsigned, copies `LICENSE`, `COMMERCIAL.md`, `THIRD-PARTY-NOTICES.md`,
codemax's AGPL text and Sparkle's MIT text into `Contents/Resources/Licenses`, then signs inside out with the hardened runtime: the two
Bun executables in `Resources/bin` with `scripts/signing/bun-runtime.entitlements` (JavaScriptCore's JIT needs them;
without them codemax dies with "Ran out of executable memory"), then the app. It checks that the bundled codemax still
starts. With a Developer ID identity (`SIGN_IDENTITY`) and notary credentials (`APPLE_ID`, `APPLE_TEAM_ID`,
`APPLE_APP_PASSWORD` in CI, or `NOTARY_PROFILE` naming a profile saved once with `xcrun notarytool store-credentials`
on a Mac) it notarizes the app and staples it, builds and signs the DMG, notarizes and staples that too,
and runs `spctl` on both; a rejection prints Apple's log and fails the job. Without them everything is signed ad hoc
with the same runtime flags, so a local run (`scripts/package.sh`, output in `build/release/`) exercises the same
entitlements. The version stamp is undone when the script ends. `CFBundleVersion` is the workflow's run number.

In CI the identity comes from five repository secrets, named at the top of the workflow; the certificate is imported
into a throwaway keychain that is deleted after the job. The release notes carry the quarantine workaround only for a
build that was not notarized.

GitHub counts every download of a release asset; the README badge shows the total, and
`gh api repos/SkidGod4444/editmax/releases --jq '.[] | "\(.tag_name): \([.assets[].download_count] | add)"'` breaks it
down per release.

## Logs and diagnostics

`~/Library/Application Support/EditMax/logs/editmax.log` is the session as JSON lines: every interaction (`ui-click`
with the element id, or `near` and `distance` when the click hit no registered element but one was within 24 points;
`ui-drag` with `ms`, `updates`, `maxLateMs` (how late the latest move was delivered, so a control lagging behind the
mouse shows as a number), `maxGapMs`, `playing` and `laggy`; `ui-hang` whenever the main thread stops answering for
150 ms, one line per episode with its worst delay; `ui-key`, `ui-menu`, `ui-typing` as a burst marker that never holds the characters),
every edit (label, origin, project), every MCP call (arguments capped at 500 characters with free text replaced by its
length; transcript tools log only lengths), `chat-send`/`chat-stop` (backend and length only), and engine events.
Events the driver posted carry `synthetic: true`. Prompts and keys are never written; secrets are redacted at write
time. `codemax-protocol.log` holds every line exchanged with the runtime and the sidecar (redacted). Both rotate at 5
MB. The Agents tab's "Export diagnostics…" zips them with the versions for a bug report.

## Icon and signing

`EditMax/Resources/AppIcon.svg` is the source (a play triangle cut into three beveled metal strips on a dark plate whose
shape comes from a real macOS icon's alpha mask, `scripts/icon/plate_mask.raw`; `scripts/icon/build_svg.py` rebuilds
it). `scripts/make-icon.sh` renders it with headless Chrome into `AppIcon.icns`, `ProjectDoc.icns` and the copies in
`docs/`. Finder caches document icons per bundle version: after changing `ProjectDoc.icns`, bump `CFBundleVersion`,
run `lsregister -f` on the built app, delete `$(getconf DARWIN_USER_CACHE_DIR)com.apple.iconservices` and `killall
iconservicesagent`.

Debug builds are signed with the Apple Development certificate pinned by hash in `project.yml`, so macOS keeps the
Screen Recording and keychain grants across rebuilds (ad-hoc signing makes every build a new app). On another Mac,
replace the hash with one from `security find-identity -v -p codesigning`, or with `"-"` for ad-hoc.

## Tests and CI

`EditMaxTests/` runs inside the app (`TEST_HOST`), so it sees the real model, engine and executor; the app skips its
splash, Home, MCP server and updater under XCTest, and runs as an accessory app (no Dock icon, no menu bar item), so a
test run does not put extra EditMax windows on screen. The rendering tests skip on CI (`CI` in the environment) and
run on every developer Mac.

Random -11800 / -12780 render failures were a real bug, not the machine: an `AVAssetTrack` does not retain its
`AVAsset`, and `AVMutableComposition` does not retain the assets it reads from, so an asset freed after
`insertTimeRange` (the base black movie, an isolated-voice file, a J/L-cut source) made a later read fail at random.
`CompositionBuilder.Output.sources` now holds every asset the composition reads; any one-off render must keep its
`Output` alive while it reads (`defer { withExtendedLifetime(out) {} }`), and the player keeps its last one.
`BlankVideo` is written to a temporary file and moved into place, so two builds never read a half-written movie. `.github/workflows/test.yml` runs the Swift suite on `macos-26` with the newest Xcode on the runner
and the Bun suite on Ubuntu. CI has no runtime source, so `scripts/vendor-codemax.sh` writes a stub when
`EDITMAX_STUB_VENDOR=1`.

The UI sweep is scripted by hand through the MCP driver before a release (`ui_layout`, `ui_click`, `ui_key`,
`ui_drag`, model checks through `inspect_timeline`); it needs a display and a running app and is not in CI.
