# Projects, updates and settings

## Projects

- **Home** lists your projects, kept in `~/Movies/EditMax Projects`. Pick a format and press **New project**, or
  double-click a project to open it.
- A project is one `.emx` file. It saves by itself as you work.
- Media is linked, not copied into the project. If you move or rename a file, it shows as missing until you relink it;
  see [editing](editing.md). **Consolidate** copies everything a project uses into one folder first.
- **Help ▸ Welcome Tour** plays the first-launch demo again.

## Updates

From 0.2.0 on, EditMax updates itself. Once a day it checks for a new release, downloads it in the background, then
asks:

- **Install Now:** EditMax saves your projects and restarts.
- **Remind Me Later:** it asks again every 2 hours while you use EditMax, and sends a Mac notification every 6 hours
  while it runs in the background. Either way, it installs the next time you quit, and says so when you next open it.

The popup never appears during an export or an agent reply, and never takes the keyboard. **Settings ▸ General** can
make it ask before downloading, or check only when you choose **EditMax ▸ Check for Updates…**.

Updates are signed: EditMax installs only a release signed with the project's update key and Developer ID.

**On 0.1.1 or older?** Those versions have no updater. Download the latest version once from the
[releases page](https://github.com/SkidGod4444/editmax/releases/latest).

Every release also has a zip and a `SHA256SUMS` file; `shasum -a 256 -c SHA256SUMS` checks the download.

## Menu bar

The EditMax icon at the top right of the screen opens a new project, Home or one of your five most recent projects,
shows whether agents can reach EditMax, and checks for updates. **Settings ▸ General** hides it.

## Settings

**Settings** (⌘,) holds the library folder, splash screen, appearance, Liquid Glass, the menu bar icon, updates, chat
defaults, API keys, the agent runtime's automatic updates, the MCP port and token, logs and diagnostics.
