# Plugins: internals

User page: [plugins.md](plugins.md). Code: `EditMax/Plugins/` (`Plugin`, `PluginStore`, `PluginHub`),
`EditMax/UI/PluginsSettings.swift`, and the hooks in `ChatSession`, `CodemaxRunner`, `EditMaxTools` and the sidecar
(`agent/src/engine.ts`).

## Shape

- A plugin is a folder under `Application Support/EditMax/plugins/<id>/`. `state.json` beside the folders holds,
  per id, `enabled`, `source` ("hub" or "file") and the install date. A folder with no entry is off.
- `Plugin.load` reads `plugin.json` (EditMax's) or `.claude-plugin/plugin.json` (Claude Code's; the root one wins),
  `skills/<name>/SKILL.md` plus a root `SKILL.md`, and MCP servers from the manifest's `mcpServers` or `.mcp.json`.
  Names are slugs (`[a-z0-9-]`); `PluginStore.reload` makes skill and server names unique across every installed
  plugin, on or off, so a name never changes when another plugin is toggled.
- Nothing in the runtime (`../codemax-cli`) changed: `codemax serve` and the sidecar already took a list of MCP
  servers. The runtime that runs may be a downloaded release, so the feature may not depend on a newer one.

## How skills reach the agent

Not through the agents' own skill loading: the runtime starts every agent isolated (no user settings, plugins or
skills), the Claude Agent SDK path runs with `settingSources: []`, and file reads are refused. So:

1. `PluginStore.instructions()` appends an index to the chat's instructions: one line per skill (name and
   description, at most 80 skills, 240 characters each), with the order to call `read_skill` first.
2. `read_skill` (and `list_skills`) are tools of EditMax's own MCP server. That one path serves every backend and
   every agent connected from outside.

`read_skill` returns the Markdown as written (the `---` header removed), not JSON, cut at 60 000 characters, then
the skill's other files. `file` is resolved with symlinks followed and must stay inside the skill's folder
(`PluginTests.testReadSkillNeverLeavesTheSkillsFolder`).

## How servers reach the agent

`ChatSession` passes `PluginStore.activeServers()` to `CodemaxRunner.configure`, which sends EditMax's server first,
then the plugins', with an explicit `allow` of every name.

- **Every tool of every named server is allowed without a question.** `codemax serve`'s policy and the sidecar's
  `allowed()` both match by server name. That is why a plugin is only ever turned on by the person, after the
  review sheet (`PluginReviewSheet`) has shown each command and address as written. A folder dropped into the
  plugins directory by hand is off, and its toggle asks first when it has servers.
- A server that still needs a required setting is left out (`missingSettings`), so a half-configured plugin never
  reaches the agent.
- stdio servers get `PATH` set to `CodemaxRunner.spawnPATH` unless the plugin sets one (the app's environment has
  no Homebrew or `~/.local/bin`, where `npx` and `uvx` live), and the plugin's folder as `cwd`. ACP has no `cwd`
  for a server, so a plugin that ships its own server refers to it with `${CLAUDE_PLUGIN_ROOT}`.
- The sidecar's Vercel AI SDK path used to skip stdio servers; `connectMcpServers` now starts them with
  `@ai-sdk/mcp/mcp-stdio`. A tool name two servers share goes to the first, which is EditMax's.
- Measured with the bundled runtime 0.1.25 and Claude Code: a stdio plugin server's tool was called with the
  plugin's environment and auto-allowed, and a shell command in the same turn was still refused. A server whose
  command does not exist does not fail `configure` or the turn, and Claude Code reports nothing, so Settings shows
  "Not found on this Mac" itself (`missingCommands`). `CodemaxRunner` now passes on any notice that names an MCP
  server (Codex sends one at `warn`).

## Sessions

A session's instructions and servers are fixed at `configure`. On `.editmaxPluginsChanged`, `ChatSession` marks the
session stale; the next `send()` forgets the configured session, sets `handoffPending` (the same digest a backend
switch uses) and adds a note. Nothing is torn down mid-turn.

## The runtime updater

A failed `configure` or a `protocol` / `crashed` turn counts as a strike against an updated runtime, and two roll
it back. A plugin's server must never cause that:

- a `configure` that fails with plugin servers attached is retried once without them, with a note, before any
  strike is counted;
- a turn error while `sessionPlugins` is not empty counts no strike. The runtime process dying still does
  (`CodemaxRunner.didExit`), which a plugin cannot cause.

## Secrets

Setting values live in the login keychain (service `io.openhorizon.editmax.plugins`, account `<plugin>/<key>`);
tests use `MemoryPluginSecrets`, and under XCTest `PluginStore.shared` is a temporary folder. The whole `configure`
line is written to the protocol log, and a key can sit in an argument or an address as easily as in `env`, so
`PluginStore.registerSecrets` hands every resolved value (the person's, or the environment's) to
`DebugLog.setExtraSecrets`, and `redact` removes them by value before the pattern rules run. One gap is known: a
value is matched whole, so if an agent's streamed reply happens to repeat a secret and the stream splits it across
two chunks, each half is logged (seen only with a test server that echoes its own key back). Telemetry gets
`plugin_installed` with the source and the counts, never a name.

## Installing

`stage(from:)` unpacks into `plugins/.staging/<uuid>/` (a folder is copied, a zip goes through `ditto -x -k`, a
lone `.md` becomes a one-skill plugin), drops `.git` and `__MACOSX`, descends into a zip's single wrapping folder,
refuses a tree over 500 MB or 20 000 files or one with a link that leaves it, and reads it. `commit` moves it into
place (replacing the same id; keychain values stay) and records the entry; `discard` deletes it.

## The hub

`hub/index.json` lists each plugin with the SHA-256 and size of every file; `scripts/build-hub.py` writes it and
`--check` verifies it. The app reads `raw.githubusercontent.com/SkidGod4444/editmax/main/hub/index.json` (or the
address in the `pluginHubURL` default, a developer's override that is not in Settings; https or file only), downloads the listed files into a temporary folder, verifies every
hash, refuses a path with `..`, a leading `/` or odd characters, and gives the folder to `stage`, so a hub plugin
passes the same review sheet. Limits: 500 files, 10 MB a file, 50 MB a plugin, 4 MB for the index.

The checksums prove a download is what the index lists. They do not make a plugin trustworthy: whatever is merged
to `main` under `hub/` is installable by every user, so `hub/README.md` sets the review rules, and
`PluginTests.testTheRepositorysHubIsCurrentAndNamesRealTools` fails when the index is stale, when a skill names a
tool that does not exist, or when a hub plugin gains a server without that test being changed on purpose.

## How the first skills were checked

Every step of the six hub skills was run against the app on a 64-second talk with pauses and filler words, plus two
other clips for the grades: each tool call as the skill writes it. That found three mistakes the name check cannot
see: `update_grade_layer` without its required `layer`, a `trim_clip` that left a gap at the head, and a scale
keyframe of 1.0 that shrank a reframed clip (its scale was 3.16). It also froze the app: two callers waiting on one
voice-isolation render looped on the finished task without yielding (`IsolatedAudio.ensure`), fixed with a yield and
covered by `testTwoCallersOfOneRenderBothReturn`. Then the in-app chat (Claude Code) was given one sentence, "Make a
short from the best moment of this talk": it read `long-to-short` first and made 29 tool calls with no error, ending
with a 1080 × 1920, 21-second cut at -14 LUFS with a hook title and 27 caption lines. A plugin with a stdio server and
a secret setting was installed through Settings and called from the same chat.

## Limits

- A plugin's servers are given to the in-app chat only. An agent connected from outside reads the skills but must
  add the servers to its own configuration.
- Claude Code plugins' commands, hooks, agents and LSP servers are ignored.
- No automatic updates: a newer hub version shows **Update**, which goes through the review sheet again.
- A remote server that needs an OAuth sign-in cannot sign in from the chat; only header or key authentication works.
