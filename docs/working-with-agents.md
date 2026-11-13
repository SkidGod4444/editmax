# Work with an agent

An agent can do anything in EditMax that you can do by hand, on the same timeline. Chat with one inside the app, or
connect the agent you already use, like Claude Code, Codex or Cursor.

<p align="center">
  <img src="demo-frames.jpg" width="920" alt="Three frames of the cut: a title over a city at dusk, apartment towers from above, fields at the edge of town">
  <br>
  <sub>A cut an agent made in nine tool calls: three aerial shots, a Teal &amp; Orange look, two dissolves, fades and a title.</sub>
</p>

## Chat inside the app

1. Open the **Chat** tab in the inspector.
2. Type what you want, for example:

   > Pick the three best moments, put a cross dissolve between them, warm it up with the Teal & Orange look,
   > add a title that says Golden Hour, and show me the result.

The agent reads the timeline, makes the edits, renders a frame to check its work, then moves your playhead to it.

The chat uses a coding agent already installed on your Mac (Claude Code, Codex, OpenCode, Cursor, Grok or
Antigravity) with that agent's own login, so there is nothing to sign up for.

**Prefer an API key?** Switch the chat header to **API key**, pick a provider (Claude, OpenAI, Google Gemini, xAI
Grok, or the Claude Agent SDK) and paste a key. Keys are kept in your login keychain. The Claude Agent SDK always uses
an Anthropic API key, not a Claude subscription; to use your subscription, chat through Claude Code instead.

**Focus layout** (⌥⌘F) hides everything but the player and the chat, so you can direct while you watch.

## Connect your own agent

Any MCP client can drive EditMax. The **Agents** tab has copy-ready setup for Claude Code, Codex and a JSON config,
with your token filled in. For Claude Code:

```sh
claude mcp add --transport http editmax http://127.0.0.1:19790/mcp \
  --header "Authorization: Bearer <token>"
```

The port and token are also in `~/Library/Application Support/EditMax/mcp.json`. The menu bar icon shows whether
agents can reach EditMax.

## Teach it more

[Plugins](plugins.md) add skills (how to do a kind of job, such as turning a long talk into a Short) and tools (MCP
servers, such as a voice generator). Install them in **Settings ▸ Plugins**, from the hub or from a folder. An agent
you connected yourself reads the skills too, with `list_skills` and `read_skill`.

## Watch it work

While an agent edits, **Follow the agent** shows you where each change lands: the clip is selected, the playhead moves
onto it, the inspector scrolls to the setting that changes, and the mixer opens for a mix change. It waits while you
use the mouse or keyboard. Turn it off in Settings.

## Undo anything

Every change, yours or the agent's, is saved as a version first. ⌘Z undoes the agent's work like your own. The
**History** tab lists every version with a line saying what changed and who made it; restoring one is itself an edit,
so you can undo that too.

## What keeps it safe

- The agent can only use EditMax's tools, plus the tools of [plugins](plugins.md) you turned on. In the in-app chat,
  file edits, shell commands and questions back to you are refused.
- A plugin's tools run without asking each time, and a plugin can run a program on your Mac. You see each command
  and address before you install one; a plugin that is off gives the agent nothing.
- An edit that would hide or lose something (stacking clips, trimming a clip to nothing, audio on a video track) is
  refused with a reason, not quietly adjusted.
- The MCP server listens on this Mac only (`127.0.0.1`) and needs the token.
- What the agent reads, like the timeline, the transcript or a frame, goes to that agent's provider, as with any agent.

## The tools

There are 118 tools; the main ones are below by area. An agent usually starts with `inspect_timeline` and `list_assets`, edits, checks its work with
`capture_frame`, and points you at the result with `set_playhead`. Clips, assets and tracks can be referred to by name,
full id, or the first eight characters of an id.

| Area | Tools |
|---|---|
| Inspect | `list_projects`, `inspect_timeline`, `list_assets`, `list_history`, `capture_frame`, `frame_stats`, `inspect_sequence`, `describe_video` |
| Cut | `import_media`, `insert_clip`, `split_clip`, `move_clip`, `trim_clip`, `remove_clips`, `close_gaps`, `ripple_delete`, `add_track`, `move_track`, `set_playhead`, `roll_edit`, `slip_clip`, `slide_clip`, `set_split_edit`, `insert_edit`, `overwrite_edit`, `match_frame`, `detect_scenes`, `relink_media`, `consolidate_media` |
| Picture | `set_clip_transform`, `set_clip_fades`, `set_transition`, `set_keyframe`, `remove_keyframe`, `auto_reframe`, `stabilize_clip`, `set_smooth_slow_motion` |
| Color | `set_clip_color`, `set_color_wheels`, `set_color_curve`, `add_grade_layer`, `update_grade_layer`, `remove_grade_layer`, `move_grade_layer`, `set_layer_mask`, `capture_matte`, `match_color`, `capture_scopes`, `set_project_color` |
| Effects | `set_chroma_key`, `key_matte`, `set_blend_mode`, `blur_faces`, `blur_region`, `set_clip_finish` |
| Sound | `set_clip_properties`, `set_clip_audio`, `set_clip_compressor`, `set_clip_limiter`, `set_clip_deesser`, `set_clip_hum_removal`, `set_clip_mix`, `set_audio_crossfade`, `set_track_mix`, `set_bus`, `set_master`, `inspect_mix`, `measure_loudness`, `normalize_loudness`, `set_ducking` |
| Speech | `get_transcript`, `search_transcript`, `cut_transcript`, `add_captions`, `remove_captions`, `detect_silence`, `remove_silence`, `remove_words` |
| Text and markers | `add_text`, `add_lower_third`, `set_text_animation`, `remove_texts`, `add_marker`, `remove_marker` |
| Structure | `nest_clips`, `unnest_clip`, `make_multicam`, `cut_angle`, `set_multicam`, `sync_angles`, `make_proxies`, `list_templates`, `apply_template`, `save_template`, `set_project_settings` |
| Deliver | `export_video`, `export_timeline`, `export_chapters`, `export_batch` |
| Safety | `restore_snapshot` |
| Skills | `list_skills`, `read_skill` |
| The window | `ui_layout`, `ui_click`, `ui_drag`, `ui_key`, `ui_scroll`, `ui_screenshot` |

Your agent sees the full list, with each tool's parameters, when it connects.

## Limits

The in-app chat needs one of the agents above installed on the Mac, or an API key.
