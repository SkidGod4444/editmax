# Assets library and the notch drawer

How the Assets library and the notch drawer are built. The user's view is in [assets.md](assets.md); the app-wide
rules (UI conventions, the UI driver, Follow the agent) are in [INTERNALS](INTERNALS.md) and apply here too.

## The library (`Engine/AssetLibrary.swift`)

`AssetLibrary.shared` is a `@MainActor` `ObservableObject` holding `[LibraryItem]`, saved as JSON at
`~/Library/Application Support/EditMax/library.json` (`indexURL`). Copies live in `storeDirectory`, the `Assets`
folder inside the projects folder (`ProjectLibrary.directory`). Under XCTest both default to a per-process temp folder,
and the library tests point them at their own folder in `setUp`, so a test never touches the user's library.

- `add(urls:source:copy:)` takes the kind from the extension (`kind(of:)`), then probes media with
  `MediaImporter.probe`, so a sound-only `.mp4` is `audio`. With `copy` it copies into the store under a unique name and keeps the source in `original`, except a file on an
  external, removable or network drive (`keepsInPlace`, volume resource keys), which is always referenced in place.
  `DriveWatcher` (App/DriveWatcher.swift) follows mounts and unmounts: `drivesChanged` repoints items by bookmark,
  open projects relink and rebuild the player, the preview drops clips whose files are offline
  (`Relink.removingClips`), an export throws from `Relink.requireOnline`, and a DiskArbitration unmount-approval callback
  makes the players release that drive's files (waiting up to 2 s for them to close) so an eject is not refused. A file already
  in the library (same `path`, or same `original` for a copy) is returned as is, never added twice.
- `addFiles(_:source:copy:)` wraps `add` and returns `LibraryAddResult` with the one-line message the UI shows
  ("Added 2 files to Assets", "Already in Assets", "… 1 could not be added").
- `items(kind:search:)` is what the views and `list_library` read.
- `remove(_:)` drops an item; it trashes the file only when it is a copy in the store (`isCopy`) that no project uses.

### Used in

A project has no stable id in the file (`EditMaxDocument.id` is new on every open), so the key for "Used in" is
`AssetLibrary.projectID(for: fileURL)`: the first 16 bytes of SHA-256 of the standardized path, as a UUID. It matches
`ProjectLibrary.Entry.id` (also the path).

| When | Call | Effect |
| --- | --- | --- |
| `import_media` (all UI import paths go through it) | `document.noteLibraryUse(imported)` | registers the files and adds this project |
| editor opens (`EditorRootView.onAppear`) | `noteLibraryUse()` → `syncUse` | records every asset; drops this project from items it no longer uses |
| save (`fileWrapper`) and autosave | same | same |
| project renamed or moved (`fileURL` changes) | `forgetProject(old)`, then `syncUse` | the key follows the path |
| project trashed from Home | `forgetProject` | removed from every item |

A project without a file yet (`fileURL == nil`) registers its imports with no "Used in"; the first save adds it.
Fonts are not pruned by `syncUse`: a font's use is not an `Asset` in the project.

## Views (`UI/LibraryViews.swift`)

- `LibraryAssetsPane`: Home's Assets place (`HomeModel.place == .assets`). Kind filter, search, grid of `LibraryCard`,
  drop zone (drops copy, source `.upload`), remove confirmation.
- `LibraryPanelList`: the editor media panel's Library tab (`AssetsSidebar.Mode.library`). Double-click imports
  through `ToolExecutor.importMedia`, so it is one undo step like any import.
- `LibraryThumbnails`: one cache for both. Video frames reuse `ProjectLibrary.poster`; fonts are drawn from a
  `CTFontDescriptor` made from the file without registering it with the system.
- `LibraryDrag`: drags carry an `NSURL` (`public.file-url`). The timeline and media panel already accept file URLs
  (import, then place), so dragging from Assets needs no new drop path.

## The notch drawer (`App/NotchDrawer.swift`)

`NotchDrawerPanel` is an `NSPanel` with `.borderless` + `.nonactivatingPanel`, `canBecomeKey/Main == false`,
`hidesOnDeactivate = false`, level `.mainMenu + 3`, and `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary,
.ignoresCycle]`. It is shown with `orderFrontRegardless()`, so it never activates EditMax or takes key from the editor.
The hosting view returns `acceptsFirstMouse == true` so a click works while another app is active, and a tracking
area with `.activeAlways` reports hover.

`NotchGeometry` finds the notch from `NSScreen.safeAreaInsets.top` and the widths of `auxiliaryTopLeftArea` /
`auxiliaryTopRightArea`; with no notch it is a 120×8 pill at the top centre of the main screen. Values for the
1352×878 MacBook screen (tested in `NotchDrawerTests`): notch x 593.5, width 165, height 28.5; collapsed panel 217 wide
(notch + 20 each side + ears); open drawer 440×189.5. It is recomputed on `didChangeScreenParametersNotification`.

States are `collapsed`, `open` and `peek`. The panel is resized to the open size before the shape grows and back to
the collapsed size after it has folded (420 ms), so the collapsed panel covers only the notch and never blocks clicks
on the menu bar. Hover opens after 140 ms; leaving folds after 0.45 s, postponed while a drag is over it or a mouse
button is down. A new download peeks for 4 s.

`handleDrop` and `addDownload` only call `AssetLibrary.addFiles` (copy, source `.drawer` / `.download`) and set the
drawer's message. They touch no document, `EditorState` or window; `testADropChangesNoProjectAndNoView` holds that.

The drawer starts 2 s after launch, after the splash has gone (`SplashScreen.afterDismiss`), and never under XCTest.
Settings ▸ Files ▸ Notch drawer and Watch Downloads (`AppSettings.notchDrawer` / `.watchDownloads`, both default on,
both off under XCTest) call `NotchDrawer.applySettings()`.

### UI driver

The drawer's frames are not registered with the UI driver (`FrameProbe` skips `NotchDrawerPanel`): its coordinates are
screen coordinates, not the editor window's. Its controls are handler-only ids instead: `drawer.open` (also the menu
bar item "Open the drawer"), `drawer.close`, `drawer.add.<file name>` and `drawer.peek.add`.

## Downloads (`App/DownloadsWatcher.swift`)

A `DispatchSource` vnode watch (`O_EVTONLY`; write, rename, delete, extend) on `~/Downloads`. `start()` lists the
folder once; only names that appear after that are considered. `isCandidate` skips dotfiles, `~$` files, folders
(Safari's `.download` package), partial extensions (`crdownload`, `download`, `part`, `partial`, `tmp`, `temp`,
`opdownload`, `filepart`, `aria2`, `!ut`, `dtapart`) and any kind `AssetLibrary.kind(of:)` does not take. A candidate
is reported once its size is above zero and the same on two checks a second apart, so a file still being written
waits. A browser's rename from `.crdownload` to the final name counts as a new file.

Reading `~/Downloads` triggers macOS's Files and Folders prompt the first time. If the listing fails, `denied` is set
and the drawer says how to allow it; opening the drawer tries again.

## Tests

- `LibraryHookTests`: an import registers; save records and drops; reopening keeps one entry per project; trash
  forgets; copies are made once; `list_library` / `add_to_library` with and without a project, and bad arguments.
- `NotchDrawerTests`: geometry; a drop with real video, PNG, WAV and text files; a drop changes no project or view;
  the Downloads filter, size settling, the real folder watch, and the peek and Downloads list.
- `LibraryPreviewTests`: PNGs of Assets, the editor Library tab, the drawer states and Settings, written to
  `$EDITMAX_PREVIEW_DIR/library` (skipped without it). Liquid Glass does not draw in an offscreen `cacheDisplay`, so
  the glass toast shows only its text there.
