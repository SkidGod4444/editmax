# The EditMax hub

The plugins EditMax offers in **Settings ▸ Plugins**. The app reads `index.json` from this folder on `main`, so a
plugin merged here is one every EditMax user can install.

- `plugins/<id>/` is one plugin: a `plugin.json`, skills in `skills/<name>/SKILL.md`, and optionally MCP servers
  in `.mcp.json`. [docs/plugins.md](../docs/plugins.md) describes the format.
- `index.json` lists every plugin with the SHA-256 of each of its files. It is generated; never edit it by hand:

  ```sh
  python3 scripts/build-hub.py          # rewrite hub/index.json
  python3 scripts/build-hub.py --check  # fail when it is out of date (the test suite runs this check too)
  ```

## Adding a plugin

1. Add `hub/plugins/<id>/` (lower-case letters, digits and hyphens), with a `version` in its `plugin.json`.
2. Run `python3 scripts/build-hub.py` and commit the plugin with the new `index.json`.
3. Raise the `version` whenever the files change, so installed copies offer **Update**.

## Review rules

- **A skill** is text the agent follows. Every tool and parameter it names must exist. The test suite checks tool
  names against the catalog; it cannot check parameters or numbers, so before a skill is merged, run each of its
  steps against EditMax on real footage. The first six skills were checked that way, and it caught a missing
  required parameter, a step that left a gap and one that shrank the picture. It must not tell the agent to ignore the user, hide what it did, or send project
  content anywhere.
- **A plugin with an MCP server is code that runs on other people's Macs**, with their account's access, and its
  tools run without asking each time once the plugin is on. Review it like a dependency: who publishes the
  package, what it reads and sends, a pinned version of the command (`npx -y package@1.2.3`, never a bare
  `package` or `@latest`), and no secrets in the file (use `${NAME}` settings). When in doubt, leave it out.
