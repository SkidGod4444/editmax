# Assets and the notch drawer

Assets holds every video, sound, picture and font you have used in EditMax, across all your projects. Open it from
Home's sidebar, or in a project from the media panel's **Library** tab. The notch drawer adds files from any app.

## Find a file you used before

In Home ▸ Assets, each file is a card with its picture, name, length or size, and the projects that use it ("Used in
Goa trip, Launch video"). Filter by kind (Fonts opens the [font library](fonts.md)), search by name, and drag a card
into an open project or to the Finder. Point at a card for **Reveal in Finder**. "Used in" stays current as you open,
save and delete projects.

## Add files

- Everything you import into a project is added. Assets points at these files where they are.
- **Add Files…**, dropping files on Home ▸ Assets, and the notch drawer **copy** files into the Assets folder (Movies ▸
  EditMax Projects ▸ Assets by default), so a Downloads or Desktop clean-up does not lose them.
- Footage on an external drive or camera card is never copied, so it does not fill your Mac's disk. The message names
  the drive, and reminds you to back up a camera card, since it holds the only copy.

Adding the same file twice does nothing.

## Use Assets in a project

The **Library** tab lists Assets (without fonts); a check mark shows what this project already has. Drag a row onto
the timeline, or double-click it to add it to the project. The minus button takes a file out of this project with any
clips that use it, asking first if there are clips. It stays in Assets, and ⌘Z undoes it.

## Add a file from the notch

1. Drag files from the Finder, a browser or any app onto the notch. On a Mac without a notch, use the small bar at the
   top centre of the screen.
2. Drop them on **Drop to add to Assets**. The drawer confirms ("Added 2 files to Assets") and folds away.

Pointing at the notch, or **Open the drawer** in the EditMax menu bar menu, opens it too. The drawer never changes the
open project or brings EditMax to the front. **Settings ▸ Files ▸ Notch drawer** turns it off.

## Add a recent download

The open drawer's **New in Downloads** row shows the videos, sounds, pictures and fonts downloaded in the last day.
Click **Add** to copy one into Assets, or drag it into a project. The drawer never opens by itself for a download.

macOS asks whether EditMax may see Downloads the first time you open the drawer. If you said no, allow it in System
Settings ▸ Privacy & Security ▸ Files and Folders. **Settings ▸ Files ▸ Watch Downloads** turns the row off.

## Delete files from Assets

Click a card's trash button, or right-click ▸ **Delete from Assets…**; **Select** deletes several. EditMax asks first
and says what will happen:

- A copy EditMax made goes to the Archive, where Home ▸ Archive can restore it for 30 days (or the time set in
  Settings ▸ Files). Projects that still use it show it as missing.
- A file Assets points at stays where it is.
- A font is uninstalled from EditMax, and its files go to the Archive.

In the editor's Library tab, deleting also takes the file and its clips out of the open project.

## When a drive is unplugged

Its clips go offline: the preview leaves a gap, a line at the top of the window counts them, and an export names the
drive to plug in. Plug it back in, even under another name ("Untitled 1"), and they play again. You can eject a drive
while EditMax plays from it.

In Assets, a file on an unplugged drive shows **Missing**. A file you delete or move in the Finder leaves the list.

## For agents

- `list_library`: Assets, filtered by `kind` (video, audio, image, font), `search` and `limit` (default 100). Items
  have `id`, `name`, `path`, `kind`, `duration`, `used_in` and `missing`.
- `add_to_library`: adds files by `paths`, referenced in place unless `copy` is true.
- `import_media`: puts an item in a project, by its path.

The library tools work with no project open and never change the open project or the editor's view.
