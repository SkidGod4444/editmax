# Assets and the notch drawer

Assets is one place for every video, sound, picture and font you have used in EditMax, across all your projects. The
notch drawer lets you add files to it from any app, without switching to EditMax. How it is built is in
[internals-assets.md](internals-assets.md).

## Assets on Home

Home's sidebar has two places: **Projects** (where Home opens) and **Assets**.

Assets shows every file as a card: a frame of the video, the picture, a waveform for sound, or "Aa" set in the font
itself. Under each card is its name, length or size, and the projects it is used in ("Used in Goa trip, Launch
video"). A file that has been moved or deleted shows **Missing** and where it used to be.

- **Filter** by kind: All, Video, Audio, Images, Fonts.
- **Search** by name.
- **Add Files…** picks files to add. Dropping files onto Assets adds them too.
- **Reveal in Finder** and **Remove from Assets** are on each card when you point at it, and on its right-click menu.
  Removing asks first. It takes the file out of the list; a file EditMax copied in, and that no project uses, goes to
  the Trash.
- **Drag a card out** to the Finder, or into an open project to use it.

### What gets added

- Everything you import into any project (the + button, dropping files on the media panel or the timeline, and the
  `import_media` tool).
- Files you drop on Assets, on the notch drawer, or add from the drawer's Downloads row.

Files dropped on Assets or on the drawer are **copied** into the Assets folder inside your projects folder (Movies ▸
EditMax Projects ▸ Assets by default). That way they stay when Downloads or the Desktop gets cleaned. Files you import
into a project are not copied; Assets points at them where they are. Adding the same file twice does nothing.

Footage on an external drive (an SSD, a camera card, a camera that shows up as a drive) is **never copied**, wherever you
add it: it is used where it is, so it does not fill your Mac's disk. The add says which drive it was left on. A camera
card (a drive with a `DCIM` folder) is then the only copy of that footage, so the message says to back it up.

When the drive is unplugged, its clips go offline: the preview plays the rest of the timeline with a gap where they are,
a line at the top of the window says how many clips went offline, and an export says which drive to plug in. Plug it back
in and they play again, also when the Mac mounts it under another name ("Untitled 1"). Ejecting the drive while EditMax
plays from it works: EditMax lets go of its files first.

"Used in" is kept right on its own: opening and saving a project records what it uses, a file taken out of a project
drops that project from its list, and moving a project to the Trash drops it everywhere.

## Assets in the editor

The media panel on the left has two tabs: **Project** (this project's media, as before) and **Library** (everything
in Assets, with search). In Library, a check mark shows what this project already has. Drag a row onto the timeline to
use it, or double-click it to add it to the project. Fonts are not listed there.

## The notch drawer

On a Mac with a notch, EditMax puts a drawer in the notch at the top of the screen. On a screen without one it is a
small bar at the top centre. Folded, it is black and reads as part of the notch; open, it is Liquid Glass (a dark
frosted panel when Liquid Glass is off in Settings ▸ General).

- **Drag files onto the notch** from the Finder, a browser or any app. The drawer opens: drop the files on "Drop to add
  to Assets". It says what happened ("Added 2 files to Assets") and folds back when you move away.
- **Point at the notch** to open it without dragging.
- **New in Downloads**: when a video, sound, picture or font finishes downloading, the drawer peeks out for a few
  seconds with its name and an **Add** button. The open drawer lists the last few downloads; scroll sideways for more.
  Add copies one into Assets, or drag it straight into a project or the Finder. Files still downloading, and files
  that were in Downloads before EditMax started, are not shown.
- **Open the drawer** in the EditMax menu bar menu opens it too.

Adding from the drawer only adds to Assets. It never changes the project you have open, what is selected, or which
panel you are looking at, and it never brings EditMax to the front.

### Settings

In **Settings ▸ Files**:

- **Notch drawer** (on by default) shows or hides the drawer.
- **Watch Downloads** (on by default) lists new downloads in the drawer. The first time, macOS asks whether EditMax may
  see your Downloads folder. If you say no, the drawer says so; you can allow it later in System Settings ▸ Privacy &
  Security ▸ Files and Folders.

## For agents (MCP)

- `list_library` lists Assets: `kind` (video, audio, image, font), `search`, `limit` (default 100). Each entry has
  `id`, `name`, `path`, `kind`, `duration`, `used_in` (project names) and `missing` when the file is gone. It works
  with no project open.
- `add_to_library` adds files by `paths`. They are referenced where they are unless `copy` is true. It answers with
  the items and any files it skipped.

Neither one changes the open project or the editor's view.
