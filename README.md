<p align="center">
  <img src="docs/icon-256.png" width="128" alt="EditMax icon">
</p>

<h1 align="center">EditMax</h1>

<p align="center">
  A native macOS video editor that your coding agent can drive.<br>
  Cut, grade, caption and export by hand, by chat, or from Claude Code, Codex and Cursor.
</p>

<p align="center">
  <a href="https://github.com/SkidGod4444/editmax/releases/latest"><img src="https://img.shields.io/github/v/release/SkidGod4444/editmax?label=release&color=0A84FF" alt="Latest release"></a>
  <a href="https://github.com/SkidGod4444/editmax/releases"><img src="https://img.shields.io/github/downloads/SkidGod4444/editmax/total?color=30D158" alt="Downloads"></a>
  <a href="https://github.com/SkidGod4444/editmax/actions/workflows/test.yml"><img src="https://github.com/SkidGod4444/editmax/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-PolyForm%20Noncommercial-orange" alt="License: PolyForm Noncommercial 1.0.0"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black" alt="macOS 15+">
  <img src="https://img.shields.io/badge/MCP-115%20tools-blue" alt="115 MCP tools">
</p>

<p align="center">
  <img src="docs/looks.jpg" width="920" alt="One frame of a surf clip in three bands: as shot, with the Teal and Orange look, and in Black and White">
  <br>
  <sub>One surf clip graded three ways in EditMax: as shot, Teal &amp; Orange, and Black &amp; White.</sub>
</p>

- **A real editor.** Tracks, trims, keyframes, color, sound, captions, multicam and 10-bit export. What you see in the
  preview is what exports.
- **Your agent works the same timeline.** Every edit, yours or the agent's, follows the same rules, and ⌘Z undoes
  either.
- **Bring your own agent.** Claude Code, Codex, Cursor and more, with their own logins, or an API key. Any
  [MCP](https://modelcontextprotocol.io) client can connect.
- **Private.** No account. Your footage, words and file names are never sent to us; see [Privacy](#privacy).

## Install

You need macOS 15 or later on an Apple silicon Mac (M1 or later). Intel Macs are not supported. Liquid Glass and
on-device SpeechAnalyzer captions need macOS 26; everything else works on 15.

1. Download `EditMax-<version>.dmg` from the [latest release](https://github.com/SkidGod4444/editmax/releases/latest).
2. Open it and drag EditMax to Applications.
3. Open EditMax. A short demo shows it being used; press Esc to skip it.

EditMax is signed and notarized by Apple, so it opens like any other app, and it updates itself. **On 0.1.1?** That
version has no updater: download the latest version once. More in [docs/app.md](docs/app.md).

## Your first edit

1. On **Home**, pick a format and press **New project**.
2. Drag videos, audio or images from the Finder into the **Media** list. Double-click one to add it to the timeline.
3. Cut on the timeline: drag a clip to move it, drag its edge to trim, press **S** to split at the playhead.
4. Select a clip and adjust it in the **Inspector**: transform, color, look, audio, transitions and captions.
5. Choose **File ▸ Export Video…** (⌘E).

Projects save by themselves. Your media is linked, not copied, so keep the files where they are.

## Edit with an agent

**In the app:** open the **Chat** tab and say what you want, like *"pick the three best moments, put a dissolve
between them and add a title that says Golden Hour."* It uses a coding agent already on your Mac, so there is
nothing to sign up for.

**From Claude Code, Codex or Cursor:** the **Agents** tab has the setup command with your token filled in. For
Claude Code:

```sh
claude mcp add --transport http editmax http://127.0.0.1:19790/mcp \
  --header "Authorization: Bearer <token>"
```

While the agent works, the window follows it: the clip it edits is selected and the setting it changes comes into
view. More in [docs/working-with-agents.md](docs/working-with-agents.md).

## What it can do

| | |
|---|---|
| **[Editing](docs/editing.md)** | Video and audio tracks, ripple edits, roll, slip and slide trims, J and L cuts, a source viewer, scene detection, markers, multicam synced by audio, nested sequences, proxies, keyframes, speed ramps, smooth slow motion, stabilization, auto-reframe for vertical |
| **[Color](docs/color.md)** | Exposure, white balance, curves, color wheels, masks that find a person, shot match, six looks or your own LUTs, scopes, before and after |
| **[Effects](docs/effects.md)** | Green-screen key, 19 blend modes, face blur that follows faces, animated titles and lower thirds, transitions, grain, glow, vignette, HDR output |
| **[Sound](docs/audio.md)** | EQ, noise gate, compressor, limiter, de-esser, hum removal, voice isolation, a mixer with buses, one-click loudness for YouTube, music that ducks under speech |
| **[Speech](docs/editing.md)** | On-device transcription, captions in six styles, remove silences and filler words, cut by editing the transcript |
| **[Assets](docs/assets.md) and [fonts](docs/fonts.md)** | Everything you imported in one place, a drop zone in the notch, all of Google Fonts |
| **[Export](docs/export.md)** | MP4, 10-bit HEVC and ProRes, SDR or HDR, batch export for every social format, YouTube chapters, FCPXML and EDL for Resolve and Final Cut |
| **[Agents](docs/working-with-agents.md)** | 115 MCP tools for all of the above plus the window itself, and an in-app chat |

**New in 0.2.0:** color wheels, curves and masks, effects and HDR, a mixer, pro trims, Assets and the notch, Google
Fonts, Follow the agent, the welcome demo, automatic updates and smoother long projects. See the
[release notes](https://github.com/SkidGod4444/editmax/releases/tag/v0.2.0).

## Privacy

After you press **Agree** on the card at first launch, EditMax sends crash reports and feature counts to
[PostHog](https://posthog.com) (US cloud). They are how problems get found and fixed, so they are part of using
EditMax. **Settings ▸ General ▸ Privacy** shows the state.

**What is sent:**
- **Crashes:** where EditMax crashed (the functions on each thread), at the next launch.
- **Failures:** an export, a render or the agent runtime failing, as an error code only, never its text.
- **Counts:** EditMax started, a project opened, an export finished or failed, a transcript finished, a chat message
  sent. Each carries only fixed choices and rough sizes: the export preset, the video length in bands (under a minute,
  1–10 min, 10–60 min, 1–3 h, longer), the clip count in bands, and which chat backend.
- **About the Mac:** the EditMax and macOS versions, the Mac model (like "MacBook Pro", never its name), language,
  time zone, screen size, and whether it is on Wi-Fi.
- **The IP address** the reports come from, which PostHog keeps with each one. EditMax turns off PostHog's lookup of a
  place from it, so no city or country is stored.

**Never sent:** your footage, sound or pictures, file and folder names, project names, transcripts, captions, titles,
chat messages, API keys, or anything you type. Your user name is removed from file paths in crash reports. There is no
account: each Mac gets a random ID that says nothing about you. Development builds, tests and CI send nothing.

The MCP server listens on this Mac only and needs a token. Transcription runs on your Mac. Prompts and keys never
reach the logs. What your agent asks to read, like the timeline or a frame, goes to that agent's provider.

## License

Free for personal use, noncommercial organizations and noncommercial open source, under the
[PolyForm Noncommercial License 1.0.0](LICENSE). Using it at a company, for client work or for videos that earn money
needs a commercial license: see [COMMERCIAL.md](COMMERCIAL.md). Bundled components keep their own licenses, listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

**Want to build it or help?** See [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

EditMax is made by **Saidev Dhal**. The agent runtime is [our open-source agent runtime](https://github.com/SkidGod4444/codemax-cli), the
MCP server uses the [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), and the API-key chat uses the
[Claude Agent SDK](https://docs.claude.com/en/api/agent-sdk) and the [Vercel AI SDK](https://sdk.vercel.ai). The surf
footage is from Pexels, cut and graded in EditMax; sources are in [web/public/reel/CREDITS.md](web/public/reel/CREDITS.md).

© 2026 Saidev Dhal.
