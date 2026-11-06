# Editing features: notes for README and INTERNALS

Each feature below has two paragraphs. **README** is for users. **INTERNALS** is for whoever changes the code. Existing projects play exactly as before: every new field decodes with a default of off. `Project.currentFormat` is unchanged.

## Roll, slip and slide trims

**README.** The timeline toolbar has four trim tools. Each also has a key: **A** select, **R** roll, **Y** slip, **U** slide.
- **Roll** moves a cut between two clips. One clip gets longer and the other shorter.
- **Slip** keeps a clip where it is and shows earlier or later media inside it.
- **Slide** moves a clip between its neighbours. The neighbours shrink or grow to fill the space.

While you drag, the timeline shows the change: the old edges, the new frames and a tag with the amount. When a move would run out of media, the tag turns orange and says how far the move can go. EditMax never clamps a trim silently. Agents use `roll_edit`, `slip_clip` and `slide_clip`.

**INTERNALS.** The engine lives in `Engine/Trims.swift`. `MediaRoom` gives each clip's spare media at its head and tail, in source seconds. It counts J/L sound slack, and stills have unlimited room. `rollLimits`, `slipLimits` and `slideLimits` return `MoveLimits` with the reason for each limit. The mutating `rollEdit`, `slipClip` and `slideClip` throw rather than clamp. The tools are in `Engine/EditingTools.swift`. The UI lives in `UI/TrimTools.swift`:
- `TrimToolPicker` (ids `timeline.tool.*`).
- `BarEditing`, the drag state that `TimelineBar` receives as `editing:`.
- `TrimFeedback`, the overlay.

`TimelineView.swift` has only small hooks into these.

## J and L cuts

**README.** A J cut starts a clip's sound before its picture. An L cut lets the sound run on after the picture ends. Set them in the inspector's **Split edit** card (Lead and Trail), or with `set_split_edit`.
- Where a split sound runs under a neighbour, both sounds play.
- Choose **Neighbour: Trim** to cut the neighbour's sound so the two meet instead.

The timeline draws the extra sound as green tongues under the clip, labelled "J 1.00 s" or "L 1.00 s". Splitting, ripple-deleting and trimming a clip keep its J and L at their own edges. A lead or trail that would need media the file does not have is refused.

**INTERNALS.** The model is `Clip.audioLead` / `audioTrail`, in timeline seconds. A negative value means the sound starts later or stops earlier than the picture. The code is in `Engine/SplitEdits.swift`:
- `soundClip()` builds the synthetic sound clip. Keyframes are shifted, and its source in is `audioIn - sourceOffset(lead)`.
- `cutSoundHead` / `cutSoundTail` serve `Clip.split` and `rippleDelete`.
- `checkSplitEditMedia` guards trims and speed changes.

In `CompositionBuilder`, a clip with a split edit skips the plain audio slot. `SplitEditAudio.insert` then lays each split sound on its own audio composition lane, scheduled greedily by interval, with the same volume envelope, ducking and EQ taps. The transition tail goes through `next`.

## Relink and consolidate media

**README.** When a project opens with files that are not at their paths, a sheet lists them. Their clips play black and silent until the files are found.
- The sheet first follows the bookmark each file got at import, which finds a file moved or renamed on the same disk.
- **Search Folder…** looks through a folder and its subfolders. It matches by file name, then checks duration (within a frame) and picture size. It also finds a renamed file when exactly one file has the same type, duration and size.
- **Locate…** picks one file by hand.

The media panel marks missing files with **MISSING** and shows a warning button above the list. **File ▸ Consolidate Media…** copies every file the timeline uses into one folder and points the project at the copies. Originals are only ever read: nothing is moved, renamed or deleted. Agents use `relink_media` and `consolidate_media`. `list_assets` reports `missing: true`.

**INTERNALS.** The engine is `Engine/Relink.swift`:
- `isMissing` (never true for a nested sequence).
- `bookmarkTarget`.
- `find`: bookmark, then same name, then the duration/size tie-break, then a renamed file. Ambiguous candidates are reported, never guessed.
- `check`: refuses another media kind, or a file shorter than `usedDuration`, the furthest source second the timeline plays from the asset, J/L sound included.
- `repoint`: keeps the asset id, so clips follow it.
- `usedFiles`: clips, multicam angles and their sound, media inside nested sequences, and `.cube` LUTs given by path.
- `plan`: a unique name per file ("name 2.mov"). A same-name, same-size file already in the folder is reused.
- `perform`: copies only, off the main thread.

Repointing is one undoable edit. Waveform and thumbnail caches are refreshed for repointed assets. UI: `UI/RelinkSheet.swift` (`EditingSheets` modifier on `EditorRootView`, `EditingCommands`, ids `relink.*` and `media.relink`).

## Scene cut detection

**README.** In the inspector's **Scenes** card, **Find Scene Cuts** reads the clip's media once and finds hard cuts, the places where the shot changes. The card shows a curve with the cuts marked and a sensitivity slider that updates instantly. Two actions follow:
- **Split at Scene Cuts** splits the clip at every cut.
- **Add Markers** puts a "Scene N" marker at each cut.

Dissolves and fades are not reported as cuts. Agents use `detect_scenes` with `action: none | split | markers`.

**INTERNALS.** The code is `Engine/SceneDetection.swift`. AVAssetReader asks the decoder for about 96 px wide BGRA frames, and the code samples a grid if the decoder ignores the size. Each frame gets two signatures:
- A 4×4×4 RGB histogram with soft (trilinear) binning. Hard bins produced false cuts when a flat colour's exposure drifted across a bin edge.
- A 4×4 brightness grid.

The difference between frames is `0.8·L1/2 + 0.2·min(1, 3·mean grid change)`. A frame is a cut when its difference is all of these:
- a local peak;
- above `max(floor, median + k·MAD)` of the previous second;
- at least `min_scene` after the previous cut.

Sensitivity s maps to `floor = 0.12 + 0.38(1−s)` and `k = 2 + 8(1−s)`. `applySceneCuts` maps source times to timeline times through the clip's speed by bisection (`Clip.localTime(ofSource:)`). It splits or marks in one edit. The test uses a generated video with known cuts, motion and brightness drift.

## Source viewer, three/four-point edits, match frame

**README.** Right-click a file in the media panel and choose **Open in Source Viewer**. The viewer takes over the preview area, and a **Source / Timeline** switch in its corner flips back (⌥⌘S). Scrub the bar, play, and use **Mark In** / **Mark Out**.
- **Insert** (key **,**) puts the marked range at the playhead and pushes later clips right on every track.
- **Overwrite** (key **.**) replaces what is there, on one track only.
- If the timeline has in and out marks too, the source is fit to that range by changing its speed (four-point edit).
- **F** (match frame) opens the frame under the playhead in the source viewer, marked with that clip's range.

Agents use `insert_edit`, `overwrite_edit` (any three points; four means fit to fill, 0.1–10×) and `match_frame`.

**INTERNALS.** Layout choice: a single viewer switched between source and timeline, the way Final Cut does it, rather than two side-by-side monitors. The preview area is the only large picture and windows go down to 1000 px wide. Two monitors would halve both pictures and crowd the transport, so the switch keeps the picture as large as before. `UI/SourceViewer.swift` holds:
- `SourceMonitor`, one per document, with its own AVPlayer.
- `SourceViewerHost`, an overlay on `PreviewView` (ids `source.*`).
- `SourceActions`, shared by the buttons and keys.

The engine is `Engine/SourceEdits.swift`:
- `EditPoints.resolve`: three points fix the fourth. It refuses ranges past the media, shorter than a frame, before 0, or a speed outside 0.1–10×.
- `insertEdit`: uses `Project.makeRoom`, now internal instead of private, the same ripple-every-track insert as `insertClip(at:)`.
- `overwriteEdit` / `liftRange`: one track only. Clips across an edge are cut with `Clip.split`, so keyframes and J/L stay with their pieces.
- `topClip`: tracks are stored top row first.

## Smooth slow motion

**README.** For a clip slower than 1×, the inspector's **Smooth slow motion** card chooses how in-between frames are made:
- **Repeat** shows each frame several times, as before.
- **Blend** cross-fades the two neighbouring frames.
- **Optical flow** draws new frames along the motion, using Apple's VideoToolbox frame-rate conversion (macOS 15.4+). Where that is unavailable it falls back to blend and says so.

The clip is rendered once in the background and cached. The preview switches to the render when it is ready, and the export waits for it. The sound is untouched. Agents use `set_smooth_slow_motion` (`off | blend | optical_flow`, with `wait`).

On a test clip with fast motion at 0.25×, measured against a true 120 fps render:

| Method | PSNR |
|---|---|
| Repeat | 26.5 dB |
| Blend | 29.0 dB (visible double image) |
| Optical flow | 33.8 dB (some smearing where the object leaves the frame) |

With slow motion (2 px per frame), blend (41.3 dB) and flow (41.0 dB) tie, both well above repeat (36.4 dB).

**INTERNALS.** The code is `Engine/FrameInterpolation.swift`, following the `IsolatedAudio` pattern:
- `InterpolatedVideo.shared` with `ensure`, a debounced `schedule`, `ensureAll` (called by `ExportService`) and `@Published version` (`PlayerController` rebuilds on it).
- A job renders the clip's source range at `min(240, fps / slowest speed)` frames per source second into `Application Support/EditMax/interpolated/<asset hash>-<in ms>-<out ms>-<fps>-<method>.mov`. File time 0 is the source in.
- A trim or speed change makes a new key, so a stale render never plays. The builder schedules the missing render itself during preview builds.
- In `CompositionBuilder` the swap is a few lines: when `InterpolatedVideo.ready` has a file, the video segments read from it, shifted by `Segment.reading(from:)`. Audio still comes from the original.
- Rendering uses a CIContext without colour management. The source's colour tags are copied to the writer and the attachments to each buffer; without this, every frame shifted by about 20 dB.
- Blend is `CIDissolveTransition`. Flow is `VTFrameRateConversionParameters` with one phase per call (`FlowInterpolator`).
- Speed ramps use their slowest speed for the frame rate.

## Interchange

`Interchange.report` gains two `notTransferred` lines:
- "J and L cuts on N clips: the sound is cut with the picture". FCPXML split audio (`audioStart` / `audioDuration` on asset-clips) is not written yet.
- "Smooth slow motion on N clips: plays as repeated frames; turn on the other app's frame blending or optical flow".
