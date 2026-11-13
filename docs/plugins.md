# Plugins

A plugin gives EditMax's agent more to work with. It can hold two things:

- **Skills**: playbooks for a kind of job, written in plain Markdown. "Turn a long talk into a Short", "clean up
  podcast audio", "grade from flat footage". The agent sees each skill's name and what it is for, and reads the
  whole skill when your request matches.
- **Tools**: MCP servers, which are programs or web services that give the agent abilities EditMax does not have
  itself, such as generating a voiceover or finding stock footage.

## Install one

1. Open **Settings ▸ Plugins** (⌘, then Plugins).
2. Under the hub, press **Install** beside a plugin. Or press **Add from This Mac…** and choose a plugin folder,
   a `.zip` of one, or a single `SKILL.md` file.
3. Read the review sheet. It lists every skill, and for every tool the exact command it runs on your Mac or the
   address it calls.
4. Press **Install and Turn On**.

Your next chat message uses it. If a chat was already going, that message starts a new session that has the plugin
and is given a digest of the conversation so far.

A plugin that needs something from you, like an API key, says so in its row. Press **Details**, enter it and press
**Save**. It is kept in your login keychain.

The toggle beside a plugin turns it off without removing it. **Details ▸ Remove…** deletes it and its saved settings.

## What is in the hub

| Plugin | Skills |
|---|---|
| **Shorts Factory** | `long-to-short` cuts one vertical Short out of a long talk; `hook-rework` rebuilds the first three seconds |
| **Podcast Polish** | `clean-dialogue` cleans speech and sets loudness; `chapters-from-transcript` adds chapters from what is said |
| **Cinematic Grade** | `balance-then-look` grades from ungraded footage by the numbers; `match-a-sequence` makes shots cut together match |

Ask for the job in your own words ("make a short from the best moment of this"); the agent picks the skill.

## What a plugin is allowed to do

Read this before installing a plugin from someone you do not know.

- **A skill is instructions.** The agent follows it the way it follows you, inside the same limits: it can still
  only use EditMax's tools and the tools of plugins you turned on.
- **A plugin's tools run without asking each time.** That is the difference from the rest of the chat, where
  anything but EditMax's own tools is refused. Turning a plugin on is the permission.
- **A tool that "runs a command on your Mac" is a program with your account's access.** It can read your files and
  use the network. Treat it like any app you install.
- **What the agent reads can reach a plugin's tools.** The agent may pass parts of your timeline or transcript to
  them as part of the job.
- A plugin that is off gives the agent nothing: no skills, no tools.
- Hub files are checked against the hub's checksums before they are installed. That proves they are the files the
  hub lists, not that they are safe; the review sheet is where you decide.

## With an agent you connected yourself

Claude Code, Codex, Cursor and other agents connected over MCP can read your skills too: `list_skills` names them
and `read_skill` loads one. A plugin's own tools are given to the in-app chat only; to use them from your own
agent, add that MCP server to the agent's configuration.

## Make a plugin

A plugin is a folder. The smallest one is a single skill:

```
my-plugin/
  plugin.json
  skills/
    punchy-captions/
      SKILL.md
```

`plugin.json`:

```json
{
  "name": "my-plugin",
  "title": "My Plugin",
  "version": "1.0.0",
  "description": "One line on what it adds.",
  "author": "You"
}
```

`skills/punchy-captions/SKILL.md`:

```markdown
---
name: punchy-captions
description: Word-by-word captions for Shorts. Use when the user asks for captions on a vertical video.
---

1. `remove_silence`, then `remove_words`, before any captions.
2. `add_captions` with preset bold and max_words 3.
3. `capture_frame` to check they sit inside the safe zone.
```

- The `description` is all the agent sees until it reads the skill, so say what the skill does **and when to use
  it**.
- Write steps, name the tools in backticks, and give numbers. The tools are listed in
  [working-with-agents.md](working-with-agents.md#the-tools); the agent sees each one's parameters.
- A skill can have more files beside `SKILL.md` (for example `references/lut-list.md`). Mention them in the skill;
  the agent reads one with `read_skill` and `file`.

### Add tools

Put the MCP servers in `.mcp.json` beside `plugin.json`, in the shape every MCP client uses:

```json
{
  "mcpServers": {
    "speech": {
      "command": "uvx",
      "args": ["some-speech-mcp@1.4.2"],
      "env": { "SPEECH_API_KEY": "${SPEECH_API_KEY}" }
    },
    "stock": {
      "type": "http",
      "url": "https://example.com/mcp",
      "headers": { "Authorization": "Bearer ${STOCK_TOKEN}" }
    }
  }
}
```

- `${NAME}` is a setting. EditMax asks the person for it in Details and keeps it in the keychain; an environment
  variable of that name is used when nothing was entered. `${NAME:-value}` gives a default and makes it optional.
- `${CLAUDE_PLUGIN_ROOT}` is the plugin's own folder, for a server shipped inside the plugin.
- Pin versions (`package@1.4.2`). A server named `editmax` is refused.
- To label a setting, add `"settings": [{ "key": "SPEECH_API_KEY", "label": "Speech API key", "help": "From your account page", "secret": true }]`
  to `plugin.json`.

A Claude Code plugin (`.claude-plugin/plugin.json`, `skills/`, `.mcp.json`) installs as it is. Its commands, hooks
and agents are ignored.

### Publish to the hub

Open a pull request that adds your plugin under [`hub/plugins/`](../hub/README.md); Settings ▸ Plugins links there
too. The hub's README has the steps and the review rules; a plugin with tools gets a code review. Once it is merged,
it shows up in everyone's hub list.

