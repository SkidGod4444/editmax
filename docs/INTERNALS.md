# EditMax internals

Notes for people working on the code. The [README](../README.md) covers what EditMax does and how to use it; this
file covers how it is built, the engine's rules, and the gotchas that cost time to find.

## Layout

| Directory | What lives there |
|---|---|
| `EditMax/Model` | `Project` (the Codable timeline plus its history), `EditMaxDocument` (`ReferenceFileDocument`; every mutation goes through `apply(label:origin:)`, which records a labeled snapshot), `DocumentRegistry` (open windows, Home hand-off) |
| `EditMax/Engine` | `ToolExecutor` (every edit, shared by the UI, the MCP server and the chat), `CompositionBuilder` + `Compositor` (AVComposition, Core Image on the GPU), `PlayerController`, `ExportService`, `MediaImporter`, `Captions`, `Cleanup`, `TranscriptEditing`, `Multicam`, `AutoReframe`, `Stabilizer`, `VoiceIsolation`, `Looks` (LUTs), `AudioTap`, `RenderCache` (proxies, nested sequences, templates), `Delivery` |
| `EditMax/MCP` | `MCPService` (MCP Swift SDK, stateless HTTP transport, bearer auth), `HTTPListener` (NWListener HTTP/1.1), `EditMaxTools` (catalog and dispatch), `UIDriver` (the `ui_*` tools) |
| `EditMax/Chat` | `CodemaxRunner` (NDJSON over `codemax serve`), `CodemaxInstaller`, `CodemaxUpdater`, `ChatSession`, `KeychainStore` |
| `EditMax/UI` | SwiftUI views; `Glass.swift` is the only place Liquid Glass APIs are called |
| `EditMax/App` | `EditMaxApp`, `AppDelegate` (`EditorState.swift`), `HomeWindow`, `ProjectLibrary`, `SplashScreen`, `AppSettings` |
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
  any ripple.

## Picture and sound

EditMax's own compositor (`Compositor.swift`, Core Image on the GPU) draws every frame of the preview, the export and
`capture_frame`, so what plays is what exports. Each project track has A/B composition tracks so transitions can
overlap; the outgoing clip plays on underneath a transition, so it needs media past its out point (`set_transition`
reports when it does not).

Order of operations per clip: input (conversion) LUT at full strength → exposure, contrast, saturation, temperature,
tint, tone curve, vibrance → creative look (built-in or `.cube`, blended by mix) → transform → fades and transitions.
Sources are decoded to 16-bit half floats (`kCVPixelFormatType_64RGBAHalf`), so 10-bit footage keeps its precision
through the LUT. There is no color management: an ungraded frame exports with the source's pixel values.

Keyframes: every transform, color, opacity, volume and speed value can be animated (linear, smooth, hold). Speed
keyframes are a speed ramp (0× = freeze); the clip's media use is the exact integral of the ramp, played as short
constant-rate pieces. A multicam clip is expanded into one piece per cut (`Clip.multicamPieces`) so ramps, keyframes,
transitions and fades keep working on it.

Audio: per-clip three-band EQ (200 Hz / 1 kHz / 6 kHz), high-pass and noise gate run through an
`MTAudioProcessingTap` (`AudioTap.swift`), attached only when a clip asks for it. Clip volume is one envelope per
clip (keyframes × fades × transition crossfade × ducking) emitted as back-to-back ramps. Voice isolation renders
Apple's on-device `AUSoundIsolation` over the asset once (cached in `Application Support/EditMax/isolated/`).

10-bit delivery (`export_video preset: hevc10`): HEVC Main 10, 4:2:0, `hvc1`, Rec.709 tags, about 0.25 bits per pixel
per frame, through `AVAssetReader` + `AVAssetWriter` with `EditMaxCompositor10`. Limits: SDR only (no HLG/PQ tags),
MP4 only, proxies are 8-bit, and untagged 8-bit sources can shift by up to 2 levels on saturated colors versus an
8-bit decode.

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

Projects are `.emx` (JSON; the older `.editmax` extension still opens). `formatVersion` is 2; files without it are
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
the MCP Swift SDK's stateless HTTP transport, so any number of clients can share it.

The `ui_*` tools work the window itself. Views register with `.uiFrame("area.name")` (`UIDriver.swift`); frames are
converted through AppKit into window points, so controls inside split views and sheets are addressable. `ui_click` and
`ui_drag` post events through the app's own event queue (`NSApp.postEvent`), so nothing reaches another app and the
real cursor stays put. SwiftUI gestures need the active app: when EditMax is behind another app it is activated for
that one gesture and the previous app gets focus straight back; when macOS refuses, the tools fall back to the
control's own tap, drag or key handler and say so. `ui_screenshot` uses ScreenCaptureKit filtered to the one window
(it asks for Screen Recording once; without it, the layer tree is rendered instead).

Things learned driving it: a single click on a Home card selects it, a double click opens; SwiftUI sliders ignore
posted events (use the `set_clip_*` tools); Form toggles take the click at their right edge.

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
Claude Agent SDK (the installed Claude Code harness with only the `editmax` MCP server; a key bills the API, no key
uses Claude Code's login) and Claude / OpenAI / Google / xAI through the Vercel AI SDK with the MCP tools pulled through
`@ai-sdk/mcp`, a 40-step tool loop. Keys live in the login keychain, reach the sidecar once per session over stdin
and are redacted from every log. Switching backends keeps the transcript; the first message after a switch carries a
digest of the earlier turns.

**Runtime updates.** `CodemaxUpdater` checks the runtime's latest GitHub release at launch and every 12 hours:
download `codemax-darwin-<arch>`, verify `.sha256`, health-check (`--version` and a `serve` handshake within 20 s),
swap it in and keep the previous copy. A copy that never says ready, or earns two strikes within ten minutes (crash,
failed agent start, protocol error), is rolled back to the previous or the bundled one and the chat retries. State in
`bin/update-state.json`. `EDITMAX_UPDATE_URL=<json> EDITMAX_UPDATE_NOW=1` point it at a local fake release.

## Logs and diagnostics

`~/Library/Application Support/EditMax/logs/editmax.log` is the session as JSON lines: every interaction (`ui-click`
with the element id, `ui-drag`, `ui-key`, `ui-menu`, `ui-typing` as a burst marker that never holds the characters),
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
splash, Home, MCP server and updater under XCTest. Four engine tests render the fixture; they skip on CI (`CI` in the
environment) because GitHub's macOS VMs render intermittently (-12780 inside a composition while a probe of the same
render succeeds), and run on every developer Mac. `.github/workflows/test.yml` runs the Swift suite on `macos-26` with the newest Xcode on the runner
and the Bun suite on Ubuntu. CI has no runtime source, so `scripts/vendor-codemax.sh` writes a stub when
`EDITMAX_STUB_VENDOR=1`.

The UI sweep is scripted by hand through the MCP driver before a release (`ui_layout`, `ui_click`, `ui_key`,
`ui_drag`, model checks through `inspect_timeline`); it needs a display and a running app and is not in CI.
