# EditMax

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
- Document model (`.editmax` JSON), multi-window, assets sidebar with import and drag-and-drop
- Timeline: video/audio tracks, clip move/split/trim/delete, speed, volume, opacity, close gaps, text overlays
- Live preview with AVPlayer + Core Animation overlays; frame stepping
- Export to H.264/AAC MP4 (`File > Export Video…`, ⌘E, or the `export_video` tool), verified with ffprobe
- MCP server on `http://127.0.0.1:19790/mcp` (port and token in `~/Library/Application Support/EditMax/mcp.json`), 22 tools
- Captions: on-device transcription with word timings (Apple SpeechAnalyzer on macOS 26+; SFSpeechRecognizer on macOS 15–25, on-device
  where the Mac has the model, else Apple's servers), six text presets, one click or one tool call
- Timeline: frame thumbnails and a waveform band in video clips, full waveforms in audio clips (peaks cached per file in
  `~/Library/Application Support/EditMax/waveforms/`), pinned track headers, lane grid, follows the playhead, add-track buttons, hide/mute per track
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

Not yet built: transitions, color grading, silence and filler-word removal, keyframes, project templates,
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
`remove_captions`.

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
